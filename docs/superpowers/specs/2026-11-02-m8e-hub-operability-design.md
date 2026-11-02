# M8e: hub operability for the hosted deployment

Date: 2026-11-02. Owner: Brian Love. Status: Part A built (D-073, D-074; `docs/verification.md` "Hub operability, Part A"); Part B designed, waiting for M8c and sign-in. The owner asked for the hosted-hub follow-ups to be completed without pausing (2026-11-02), so decisions below are the implementer's calls unless marked as the owner's, and are recorded in `docs/decisions.md` at commit.

This document designs the hub-side items that `docs/deployment-architecture.md` ("What this project asks of the hub") assigned to M8e. It is split into two parts: **Part A** needs nothing that is not on `main` and is built now; **Part B** depends on the M8c relay (`origin/feat/m8c-relay`, not merged) and on the sign-in branch (`origin/blove/sign-in`, not merged) and is designed here, built after those land. The hub's conventions hold: `Hub/API.md` is the wire reference, B4's error envelope, no secret in a log line, fixture tests over a throwaway PostgreSQL (`Hub/scripts/test-db.sh`).

## Intent

A one-person operator runs the hub on ECS with CloudWatch Logs and alarms (D-068 to D-071). Today a log line cannot be tied to the request that produced it, the device that made the request is not named, and the only way to stop the hub from accepting writes during an incident is to scale it to zero. Part A gives every log line a request id and the authenticated device id, makes the log JSON when it is not going to a terminal, and adds a maintenance mode that refuses writes while reads and `/readyz` continue, switchable without a redeploy and visible to every instance.

## Part A (built now)

### A1. Request-scoped logging

- **Request id.** A middleware on every route (including `/healthz` and `/readyz`) mints a fresh UUIDv7 request id. An inbound `X-Request-Id` never replaces it (as built, 2026-11-02, controller ruling: no shipped deployment strips the header, so honouring it would let a client choose the id it is logged under); when the inbound value is well-formed (1 to 64 printable ASCII characters, no whitespace) it is recorded as the separate span field `client_request_id`. The hub's id is set on the response as `X-Request-Id`, stored in request extensions, and carried by a `tracing` span named `request` with fields `request_id`, `method`, `path` (the matched route pattern, never the raw URL with query string), `client_request_id`, and an empty `device_id` field. `main` still gains `Settings::trust_proxy()` reading `B4HUB_TRUST_X_FORWARDED_FOR` for the sign-in branch's client-address handling.
- **Device id.** The `AuthedDevice` extractor records `device_id` (the UUID, never the token) on the current span after a successful authentication. Unauthenticated requests leave it empty.
- **Completion line.** The middleware emits one event at the end of every request with `status` and `elapsed_ms`: `warn` for a 503 (an intentional refusal), `error` for any other 5xx, `info` otherwise. No headers and no bodies are ever logged.
- **Format.** `B4HUB_LOG_FORMAT=text|json`; default `json` when stderr is not a terminal, `text` when it is, so local runs stay readable and ECS gets one JSON object per line (`tracing-subscriber` `json` feature, `flatten_event(true)`, `with_current_span(true)`, `with_span_list(false)`: the event's own fields are top-level and the `request` span's `request_id` and `device_id` sit under `span`). `B4HUB_LOG` keeps its meaning (the filter).
- **Secrets.** The existing redaction tests extend to the new fields: a test drives an authenticated request through a JSON subscriber writing to memory and asserts the bearer token appears nowhere while `request_id` and `device_id` do.

### A2. Maintenance mode

- **State.** A new table `hub_settings (key text primary key, value jsonb not null, updated_at timestamptz not null)`, not tenant-scoped (no `org_id`, no row-level security; readable by `b4hub_app`, writable by the owner role only). One key for now: `maintenance` with value `{"mode": "read_only", "message": "<optional operator text>", "since": "<timestamp>"}` or absent.
- **Switch.** `b4hub maintenance on [--message "<text>"]`, `b4hub maintenance off`, `b4hub maintenance status`, operator commands that connect with `DATABASE_ADMIN_URL` (like `seed` and `enroll`), so on AWS they run from the `hub-admin` task (`Infra/README.md` runbook 6) and on Compose from `docker compose run --rm migrate maintenance on`. No env var and no redeploy; every instance sees the same state.
- **Serve.** Each `serve` instance polls `hub_settings` every 5 s (and at start) on its ordinary pool and caches the result; a failed poll keeps the last known value and logs a warning. While `read_only`: `POST /v1/enroll`, `POST /v1/changes`, `DELETE /v1/devices/self`, and any future relay command answer `503` with `{"error":{"kind":"execution_error","message":"the hub is in maintenance: <message or 'writes are paused'>","details":{"code":"maintenance"}}}` and `Retry-After: 30`. Reads (`GET /v1/changes`, `/v1/snapshot`, `/v1/me`, `/v1/devices`) continue. `/readyz` stays `200` and gains `"maintenance": "read_only"` (absent otherwise); `/healthz` is unchanged.
- **Clients.** Swift models `details.code` as a free string on `HubError` (there is no `ErrorCode` enum), so a `503 maintenance` already decodes and reaches `lastError` as `Hub error 503 maintenance: …`; Part A adds `maintenance` to that type's documentation and nothing else.
- **Migration numbering.** M8c claims `0004_relay.sql` and sign-in `0005_accounts.sql` (both unmerged). This migration is `0006_settings.sql`. Verified (test `sqlx_applies_a_lower_numbered_migration_added_later` and `Migrator::run_direct` in sqlx 0.8.6): sqlx applies every migration the ledger lacks in version order and does not refuse a lower number that arrives after a higher one, so M8c and sign-in need not renumber. It does refuse the reverse (`VersionMissing`): a binary without `0006` must not run `migrate` against a database that has it. Recorded in `docs/compatibility.md`.

### A3. Not in Part A

The `*_FILE` variants for the sign-in secrets live in the sign-in branch's config code; the sign-in session was asked to add them there (2026-11-02). If they decline, M8e adds them after that branch merges, following `secret_url` in `cli.rs`.

## Part B (designed now, built after M8c merges)

### B1. `/readyz` exercises the relay

When the relay is enabled, `/readyz` opens a loopback WebSocket to its own `GET /v1/devices/self/link` with an internal probe principal accepted only from `127.0.0.1` (or an in-process call into the link acceptor, whichever the relay's code makes simpler), expects the `hello` frame within 2 s, and reports `"relay": "ok"`; a failure makes `/readyz` answer `503 not_ready` with `"relay": "failed"`. Details are fixed once the relay's acceptor exists.

### B2. Cross-instance relay routing (amends D-057 when built)

Goal: two or more `serve` instances behind the ALB, any of which may hold a device's link, with commands and live progress reaching the right link.

- The change log stays the only durable state. Routing state stays in memory per instance, plus a shared presence table `device_links (device_id primary key, instance_id, connected_at, last_frame_at)` written on link open/close and refreshed with the once-a-minute `last_seen_at` throttle.
- Each instance holds one dedicated, non-pooled `LISTEN` connection (sqlx `PgListener`) on channel `b4hub_relay`, reconnecting with backoff.
- A command for a device whose link is on another instance is forwarded as a NOTIFY hint `{ "to": <instance_id>, "kind": "command", "id": <command id> }` with the command body in a short-lived `relay_commands` row (TTL 60 s); the owning instance delivers it and writes the reply to `relay_replies`, notifying the originator. Payloads never ride in NOTIFY (8000-byte limit).
- Live `message.delta` fan-out across instances is the open question: (a) a `watch` is answered with a redirect hint plus ALB target-group stickiness so the watcher's link lands on the host's instance, or (b) a durable relay of deltas. The deployment design's "next" tier prefers (a).
- Deadlines, holds, idempotency, and limits from D-055 and D-057 are unchanged; `last_seen_at` becomes the latest `last_frame_at` across instances.

## Verification

- A1: middleware unit tests (id shape, header honoured only behind a trusted proxy, response header, route pattern not raw path, no query string), the extractor recording `device_id`, and the redaction test. `cargo fmt`, `clippy -D warnings`, `cargo test --workspace --locked` against the throwaway PostgreSQL.
- A2: black-box tests over the loopback listener: `maintenance on` makes `POST /v1/changes` answer `503 maintenance` with `Retry-After`, `GET /v1/changes` still answers, `/readyz` is `200` with `"maintenance": "read_only"`, `maintenance off` restores writes within one poll interval; `b4hub_app` cannot write `hub_settings`.
- Docs: `Hub/API.md` (error row, `/readyz` field, `X-Request-Id`, `B4HUB_LOG_FORMAT`), `docs/decisions.md`, `docs/milestones.md` M8e lines, `Infra/README.md` runbook 9.
