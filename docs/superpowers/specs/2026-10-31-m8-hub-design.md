# M8: the hub

Date: 2026-10-31. Owner: Brian Love. Status: draft for the owner's approval.

This document designs the hub (the remote, multi-tenant service that every device syncs with) and the first slice of it that gets built. It extends `2026-10-31-storage-and-sync-design.md`, whose "Sync model" and the D-041 amendments still hold, and it draws on `docs/research/reports/Multi-tenant hub and sync patterns.md` (cited below as "the research"). The spec's section 15 calls the iOS companion a follow-on that needs "an explicitly designed secure relay or reachable service"; this is that design.

## Intent

Brian wants to open the iPhone away from his Mac and see every Codex, Claude, and B4 thread he created in the app, organised and listed, read the transcripts, and eventually keep talking to the agents. The Mac is where the agents run; the hub is how the phone reaches what the Mac knows. In the long run the same hub is a product: a multi-tenant, multi-user service that a company deploys on its own infrastructure with Docker or a Helm chart and signs into with its own identity provider, and that cacheplane runs as a public cloud where anyone can create an account and an organisation.

The owner's direction, in his words where it matters:

- "The hub is a multi-tenant onprem solution that is deployable using docker, k8n via helm charts. We will support SSO and enterprise auth. For our public cloud, we'll deploy this and provide users the ability to auth and create their own account, orgs, manage users in orgs, etc. A client connects as a user."
- "For our starting purposes, we'll run it locally, have a single 'cacheplane' org and my user 'Brian Love' (username blove)."
- "I expect to see all of my codex, claude, and B4 threads organized and listed so I can continue to interact with the agents while away from my computer."
- "We are not ingesting threads created outside of those created in the app."
- "The backend should be written in rust."
- "If you send a message from the phone while the Mac is asleep you will not be able to send the message (refuse new turns)."
- "Not bundled" (no third-party identity provider in the on-prem image).
- "Much of this is longterm and in the roadmap. We don't need to build this all at first. We should start small and iterate and verify."
- First thing to see working end to end: "read-only in the iOS app since we can use the simulator for that."

## Goals, non-goals, anti-goals

Goals, for M8 as a whole:

1. One thread list and the same transcripts on every device a user signs into, for threads created in the app.
2. Continue a Mac-bound thread from the phone while that Mac is online, through the hub, with the Mac doing the work.
3. A hub that one team can deploy on-prem (Compose, Helm) and that cacheplane can run as a multi-tenant cloud, from the same image.
4. Enterprise sign-in (OIDC and SAML SSO per organisation, SCIM) and self-service accounts in the cloud, with the organisation model owned by the hub.

Non-goals:

- Importing threads from `~/.codex`, `~/.claude`, or a B4 server's own history. Only threads the coordinator created and owns are synced.
- Running an agent anywhere but the owning Mac. The hub never holds provider credentials and never calls Codex, Claude, or B4 itself.
- Moving a live Codex or Claude session to another machine. Hand-over, if it ever exists, is a fork, as every surveyed product does it.
- Syncing local-only state: local servers, process identities, paths, ports, the event log, diagnostics, secrets.
- A bundled identity provider in the on-prem image.

Anti-goals (what would make this a failure even if it technically works):

- A secret value, an executable path, or a pid crossing the wire or landing in a hub row.
- The phone showing a stale transcript as if it were live, or accepting a message that silently runs hours later.
- Cross-tenant reads being prevented only by application code. Row-level security is on from the first migration, including when there is one tenant.
- Two code paths, one for "single org on-prem" and one for the cloud.

## Constraints

- The repository rules hold: the UI never touches processes, sockets, files, or secrets; `SessionService` stays the only writer of turns, display items, and runtime requests on the Mac; unimplemented behaviour throws `unsupported_capability` naming its slice; ordinary tests use fixtures, live checks are opt-in.
- Each Mac keeps its private Postgres cluster as the coordinator's store (D-041). The hub is not the Mac's store; it is a mirror plus a router.
- The iOS app keeps a SQLite store of its own and syncs through the same change log (D-041 amendment). `WorkspaceStorage` stays coordinator-only; nothing on iOS imports it.
- The hub is Rust, one binary, one container image, external Postgres. Rust 1.93 stable is installed on the build Mac; the hub builds with the stable toolchain pinned in `Hub/rust-toolchain.toml`.
- The reference product's names stay redacted in anything committed here.

## The shape of the system

```
 iPhone ──HTTPS──┐                                ┌──HTTPS──► Mac coordinator ──unix socket──► app, CLI
 CLI (remote) ───┤──► hub (Rust) ◄── Postgres ◄──┤                │
 Mac coordinator ┘      │                          └── WebSocket ──┘ (relay, slice M8c)
                        └── own users, orgs, devices, tokens, change log, mirrored rows
```

Three kinds of client connect to the hub as a user, each as a registered device:

| Client | Local store | Writes | Reads |
| --- | --- | --- | --- |
| Mac coordinator | private Postgres | pushes its change log; executes relayed commands for threads it owns | pulls other devices' changes (titles, pins, drafts) |
| iOS app | SQLite | pins, archive, titles, drafts (slice M8b); turns through the relay (M8c) | pulls the change log into its mirror |
| CLI away from its Mac | none | the same as the phone, later | the same as the phone, later |

The hub holds, per organisation: users, memberships, devices, token families, the server-ordered change log, and materialised copies of the synced tables (so lists and exports are answerable without replaying). Postgres is the source of truth for durable history; anything live (a running turn's deltas) is relayed, not stored twice.

### Tenancy

One shared schema. Every tenant-scoped table carries `org_id uuid NOT NULL`; synced rows also carry `user_id` (the owner) and `device_id` (the origin). Row-level security is enabled and forced on every such table; the application role is not the table owner and has no `BYPASSRLS`. The policy form, from the research:

```sql
CREATE POLICY tenant ON threads TO b4hub_app
  USING (org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid);
```

Each request opens a transaction and its first statement is `SELECT set_config('b4hub.org_id', $1, true)` with the organisation from the verified credential, never from a header or body. Application queries still filter on `org_id` explicitly, so the planner hits the `(org_id, …)` index and RLS stays a backstop. Migrations run as the owner role with `row_security = off`, so a scoped query that would be filtered fails loudly instead of silently losing rows. Two roles, two URLs (my call): `DATABASE_ADMIN_URL` is the owner role, used only by `migrate` and `seed`; `DATABASE_URL` is `b4hub_app`, used by `serve` and `enroll`. `migrate` creates or updates `b4hub_app` from the password in `DATABASE_URL` and grants it table privileges, so an operator provisions one superuser-ish secret and the hub derives the rest; Compose hands both URLs to the `migrate` service and only the app URL to `hub`. The RLS acceptance test connects as `b4hub_app` explicitly (the `#[sqlx::test]` harness runs as the cluster's superuser, which bypasses policies), so role provisioning is part of the test database setup from the first migration. Hub-minted ids (orgs, users, devices) are UUIDv7 generated in Rust; synced rows keep the text ids the client minted, with `(org_id, id)` as the primary key.

The on-prem install is a tenant count of one. `b4hub seed` creates the organisation and the first user; the single-org deployment and the cloud run the same code, and the only deployment-specific question is "which org does this credential belong to".

### Identity and devices

The hub owns the account model. Nothing is bundled; a customer's identity provider is an attribute of their organisation that the hub brokers to, later.

Long-run model (slices M8d onward): organisations → verified domains → an optional OIDC or SAML connection per domain with an auto-redirect flag; memberships with roles; invitations; a `devices` table with one rotating refresh-token family per device so "sign out this device" is one revocation; the Mac and iPhone apps sign in with the authorization-code flow with PKCE through `ASWebAuthenticationSession`, the CLI with the device-authorization grant; access tokens carry `iss`, `aud` (the hub API), `sub`, exactly one `org_id`, that org's roles, `sid`, and `device_id`; SCIM for `/Users` and `/Groups` scoped to one organisation; identifier-first sign-in with email verification before any domain-based auto-join in the cloud.

First-slice model (M8a), which the long-run model extends rather than replaces: a device is enrolled with a one-time code. An operator runs `b4hub enroll --user blove` against the hub's database and gets an eight-character code that expires in ten minutes. The Mac (`agent-workspace hub join <url>`, code read from the terminal, never an argument) or the phone (a "Connect to hub" screen) posts the code with its device name and platform; the hub answers once with a device id and a device token. The hub stores only the token's SHA-256; the client stores the token in the Keychain through `SecretStore` and holds a reference. Every later request is `Authorization: Bearer <token>`. Revocation is deleting the device's token rows; the device row is kept with `revoked_at`, and the rows a device uploaded outlive it (`device_id` is a plain column, never a cascading foreign key), so history survives a rebuilt Mac or a lost phone. `hub leave` on the Mac revokes its token through the hub when reachable, clears the local cursor and `synced` flags, and a later `hub join` uploads everything again under the new device id as upserts, which the `(org_id, id)` keys make idempotent. This is the refresh-token family of the long-run model with one member and no expiry, and the tables (`devices`, `device_tokens`) are designed so sign-in flows add rows rather than rename columns.

### Sync

The Mac's change log (`0002_changes.sql`) is the unit of sync, unchanged in shape. Per device the hub keeps `(device_id, device_seq)` unique, so a retried upload is a no-op; per organisation it assigns `hub_seq`, a bigserial, which is the cursor every reader uses. The coordinator uploads in batches of 500 rows after local writes (debounced 250 ms), every 30 s, and on wake; a batch is acknowledged with `acceptedThrough`, and only then are those rows marked `synced` locally. The hub applies a batch in one transaction: append to `changes`, materialise into its copy of the table with the same semantics as `WorkspaceDatabase.replay` (insert is upsert, update sets one column, delete deletes, a row whose parent is missing is skipped).

Readers call `GET /v1/changes?after=<hub_seq>&limit=1000`, long-polling for up to 25 s when nothing is newer, and store the returned `next` as their cursor. A cursor older than the organisation's retention horizon receives `resync_required` and the client bootstraps again from zero. What a reader sees is derived from its credential on the server: in M8a, every change in the user's own rows; organisation-wide sharing is a later policy, not a client parameter.

Conflict handling is deliberately small because the data is. Turns, display items, and runtime requests are append-only facts with one writer (the owning Mac's `SessionService`), so they need idempotency and ordering, not merging. Titles, pins, archive flags, and drafts are the mutable surface; while the Mac is the only writer (M8a) there is nothing to merge. When the phone starts writing (M8b) those columns get a hybrid logical clock in the change row (`hlc text`, sortable, 48-bit milliseconds plus a 16-bit counter plus the device id) and last-writer-wins per column with the device id as tie-break, and the hub clamps clocks more than five minutes ahead of its own. Tombstones are kept for 30 days per organisation, after which a reader behind the horizon resyncs.

What crosses the wire, and what never does. The coordinator uploads rows from `connections`, `threads`, `turns`, `displayItems`, `runtimeRequests`, and `drafts`. Before upload it blanks `connections.authReference`, `connections.localServerId`, and `connections.target` for every kind (an executable path for Codex and Claude, a filesystem path or URL for B4; a remote B4 URL is also blanked in M8a and returns as a device-aware field in M8b), and it never uploads `localServers`, the event log, or diagnostics. `ConnectionsView` hides its path row when `target` is empty instead of saying the executable is missing, the one shared-UI change M8a makes. A `displayItems.payload` larger than 1 MiB is uploaded with the payload replaced by `{"truncated": true, "bytes": n}` so one tool dump cannot wedge the log (my call; the local transcript is untouched). Secrets never reach a synced table today because the store holds `SecretStore` references, and the upload path is audited for that in every slice's acceptance.

### The relay (slice M8c, designed here, not built first)

The coordinator holds one outbound WebSocket to `wss://<hub>/v1/devices/self/link`, authenticated with its device credential, with a 30 s heartbeat. The hub marks the device online while the socket is up and records `last_seen_at` when it drops. Commands flow down, addressed to a thread the device owns: `turn.send`, `turn.interrupt`, `request.respond`. The coordinator executes them exactly as if the local app had issued them, so `SessionService` stays the only writer and every existing rule about ambiguous acknowledgement and stale requests applies unchanged. Events flow up as the thread's ordinary change rows plus the live `message.delta` stream, which the hub fans out to any client currently watching that thread and does not persist (the completed item arrives as a change row).

Semantics, per the owner's decision: when the owning device is offline, a `turn.send` from any other device is refused with `device_offline`, carrying the device name and `last_seen_at`, and the phone shows the thread as "last seen on Brian's MacBook Pro at 14:02" rather than a dot. `turn.interrupt` and `request.respond` are held for at most 60 s for a device that was online within the last minute (a socket flap), then expire with the same error. When two surfaces answer the same runtime request, the first answer the hub records wins and the second receives `request_already_resolved`. Reconnect semantics follow the reference product's contract: on connect a client sends its last seen cursor; the hub answers with nothing new, a bootstrap snapshot, or a live stream starting after a captured high-watermark with the gap replayed first, so a reconnect never duplicates or drops a line.

### The iOS app

The iOS app gets no coordinator and no socket to the Mac. It gets a mirror: a SQLite database holding the synced tables, fed by `GET /v1/changes`, and an in-process `WorkspaceTransport` that answers the read-only commands from that database and emits the events the existing `WorkspaceModel` already understands. The UI code stays shared and unchanged. Concretely, a new Foundation-only module `WorkspaceMirror` (links the system `SQLite3` module; never `WorkspaceStorage`) provides:

- `MirrorStore`: `threads`, `connections`, `turns`, `displayItems`, `runtimeRequests`, `drafts` with the same column names as the Postgres schema, JSON columns as text, plus `syncState(cursor, hubURL, deviceId, lastSyncAt)`; `apply(_ changes: [ChangeRecord])` with the replay semantics above; the file lives in the app's Application Support directory with `FileProtectionType.completeUntilFirstUserAuthentication`.
- `HubClient`: enroll, pull changes, long-poll; the device token is read from the Keychain by reference and set as the bearer header inside this type only.
- `MirrorTransport: WorkspaceTransport`: answers `system.ping`, `events.snapshot`, `connection.list`, `thread.list`, `thread.read`, `draft.read`, `server.list` (always empty), and `diagnostics.read` (the report's `coordinator` describes the mirror itself, `runtimes` is empty, and a new optional `sync` section carries hub URL, device name, cursor, last sync time, and last error; `DiagnosticsReport` gains that optional field and `DiagnosticsView` renders it when present, an additive protocol change); after each applied batch emits `thread.updated` for every touched thread row, `message.completed` or `tool.completed` for each new or changed display item of the open thread, and `connection.changed` for connection rows. Everything else answers `unsupported_capability` naming M8b or M8c, so a tap on Send says exactly why it cannot work yet.
- A "Connect to hub" screen (hub URL, enrollment code, device name defaulting to the device's name) that lives in `Apps/iOS`, built from the public `LLA` tokens and controls, and talks to `WorkspaceMirror` directly; it is shown while the mirror has no credential. `WorkspaceUI` stays transport-neutral and never imports `WorkspaceMirror`. The code is held only for the enrollment request, like the existing login flows hold nothing after the Keychain write.
- Secrets on iOS: `SecretRef`, `SecretStore`, and the Keychain store move from `WorkspacePlatform` into a new Foundation-and-Security-only module `WorkspaceSecrets` that both `WorkspacePlatform` and `WorkspaceMirror` use, so a secret reference means the same thing on both platforms; on iOS the store is the data-protection keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. This amends the layout rule in `AGENTS.md` and is recorded with D-046.

In the Simulator the hub is `http://localhost:8080`; `NSAppTransportSecurity` allows insecure loads for `localhost` only, and the client refuses any other non-HTTPS URL.

### Packaging and operations

One image, `b4hub`, built by a multi-stage `Hub/Dockerfile` onto a distroless base, exposing one binary with subcommands:

- `b4hub serve` (port 8080, `DATABASE_URL` from the environment or `DATABASE_URL_FILE` for a mounted secret, `B4HUB_PUBLIC_URL`, `B4HUB_LOG`), with `GET /healthz` (process up) and `GET /readyz` (database reachable, migrations current).
- `b4hub migrate` (applies `Hub/migrations/*.sql` in order with `sqlx::migrate!`, as the owner role).
- `b4hub seed --org <slug> --org-name <name> --user <username> --name <display> --email <email>` (idempotent).
- `b4hub enroll --user <username>` (prints a one-time device code).

`Hub/compose.yaml` runs `postgres:17` with a named volume, a `migrate` service that runs the same image with `migrate` and exits, and `hub` depending on it. The Helm chart (M8e) uses the same image with a `pre-install,pre-upgrade` hook Job for `migrate`, an `existingSecret` for the database URL, and no bundled Postgres by default (CloudNativePG is the documented in-cluster option). The hub publishes its minimum supported client protocol version in `/readyz` and in the hello of every connection; clients older than it get `client_too_old` and a link to the release.

### Rust stack

My calls, open to override: edition 2021 (matching `~/repos/b4`); `axum` 0.8 with `tokio`; `sqlx` 0.8 (`postgres`, `runtime-tokio`, `tls-rustls`, offline query metadata checked in so CI builds without a database); `serde`/`serde_json`; `clap` for subcommands; `tracing` with JSON output; `uuid` with the v7 feature; `sha2` for token hashes; `tokio-tungstenite` through axum's WebSocket support for the relay. Tests use `#[sqlx::test]` against `DATABASE_URL`; on the Mac that is the same bundled Postgres the Swift tests boot (`Scripts/fetch-postgres.sh`, then a cluster under `$TMPDIR` started by `Hub/scripts/test-db.sh`), and in CI a `postgres:17` service container. `cargo fmt --check` and `cargo clippy -- -D warnings` gate like `swift format lint` does.

Layout: `Hub/Cargo.toml` is a workspace with `crates/b4hub` (the binary), `crates/b4hub-core` (domain, auth, sync application, pure functions testable without a server), `crates/b4hub-db` (sqlx queries, migrations), and `Hub/migrations/`. The HTTP API is described in `Hub/API.md` and the JSON shapes mirror the Swift `WorkspaceProtocol` types field for field, so one `ChangeRecord` serialises identically in both languages; a fixture file of change rows under `Tests/Fixtures/sync/` is decoded by both test suites.

### Conventions shared with the b4 Rust rewrite

`~/repos/b4` (the native Rust B4 runtime, surveyed 2026-10-31) is the other cacheplane Rust codebase, and the hub follows its engineering conventions so one toolchain and one set of habits serve both: edition 2021 on Rust 1.93.1 with a minimal pinned toolchain; exact `=` crate pins, `Cargo.lock` committed, `--locked` builds; `unsafe_code = "forbid"`; B4's error envelope (`error.kind`, `error.message`, `error.details.code`) so the Swift client decodes both services with one type; authentication before body parsing with a generic 404 for missing and inaccessible resources alike; `deny_unknown_fields` on request bodies; a non-root container with a `HEALTHCHECK` on `/readyz`, `STOPSIGNAL SIGTERM`, and a bounded drain (`B4HUB_SHUTDOWN_WAIT_MS`) that fails readiness first; configuration errors exit 2; black-box tests over a real loopback listener; subscribers registered before the snapshot cut, the rule b4 states as ATTACH-001, applied here to the long-poll in M8a and to the relay in M8c. What is deliberately not carried over: b4's requirements register, evidence classes, and hashed qualification receipts, which suit a runtime making crash-safety claims; the hub's `docs/verification.md` and `docs/milestones.md` entries are the proportionate record. Nothing is shared as code yet; `b4-contract` becomes reusable when the relay carries B4 remote threads.

## Slices

Each slice ships on its own, is verified on its own, and stops being a milestone name once its acceptance is recorded in `docs/milestones.md` and `docs/verification.md`.

**M8a, read-only mirror (build first).** The Rust hub with `migrate`, `serve`, `seed`, `enroll`; the tenancy tables and RLS; device enrollment with one-time codes; `POST /v1/changes` and `GET /v1/changes` with long-poll; the coordinator's `HubSync` (join, push, status, leave) with the device id introduced into the local `devices` table and the `b4app.device_id` session setting, which today is never set; `agent-workspace hub join|status|leave` and `hub.*` coordinator commands; the `WorkspaceMirror` module and the iOS "Connect to hub" screen; Compose for local use. Exit: with the hub running from Compose on the Mac, the packaged Mac app joined, and the Simulator app enrolled, a thread created and run on the Mac appears in the Simulator's list with its transcript within one poll interval, with no manual refresh; the hub's rows for that thread contain no secret value, path, or pid (checked by a test that uploads the real fixture connections); a second enrolled user in a second org cannot read the first user's rows even with the application role's credentials and a hand-written query (RLS test); `cargo test`, `swift test`, and both app builds pass in CI.

**M8b, the phone writes.** Pins, archive, titles, and drafts from the iOS app; HLC and per-column LWW; the coordinator pulls and applies other devices' changes; conflict tests with two devices editing offline then converging; device-aware connections in the UI ("on Brian's MacBook Pro", read-only). Exit: the storage design's M8 gate for organisation state.

**M8c, the relay.** The WebSocket link, `turn.send`/`turn.interrupt`/`request.respond` from the phone to the owning Mac, online and last-seen status, the offline refusal, live delta fan-out. Exit: a turn sent from the Simulator runs on the Mac and streams back; the same send with the coordinator stopped is refused with the device's last-seen time; a runtime request answered on both surfaces resolves once.

**M8d, accounts.** PKCE sign-in for the apps, device grant for the CLI, refresh-token families, self-registration with email verification, organisations and memberships, per-organisation OIDC brokering; the enrollment code becomes an operator fallback. Exit: Brian signs in on a fresh Mac and phone with a username and password or an upstream OIDC provider, and "sign out device" revokes exactly that device.

**M8e, deployable.** Helm chart, SAML through a maintained library, SCIM `/Users` and `/Groups`, tenant bundle export and import, the compatibility window published. Exit: a clean Kubernetes install from the chart with an external database passes the M8a and M8c acceptance.

## Decisions to record when M8a lands

- D-043 The hub is a Rust service in `Hub/` (one binary, `serve`/`migrate`/`seed`/`enroll`, axum and sqlx), not a Swift or B4 service; a Cargo workspace joins the repository and CI.
- D-044 The hub owns users, organisations, devices, and credentials and bundles no identity provider; enterprise SSO is brokered per organisation by the hub itself.
- D-045 A turn sent to a thread whose owning device is offline is refused, never queued; only interrupts and request answers are held, for 60 s.
- D-046 The iOS app reads a SQLite mirror fed by the hub's change log through an in-process `WorkspaceTransport`, so the SwiftUI shell is unchanged across platforms; only threads created in the app are ever synced. Secret references move to a `WorkspaceSecrets` module shared by both platforms.
- An M8 block appended to the roadmap after the M7 block, in the same form, so the owner's document carries the slices.

## Calls made after the builder check

A reviewer read this document as the engineer who would plan from it. Everything it asked had an answer the project already implied, so these were settled here rather than brought back as questions; the owner can overrule any of them while reading.

1. Two database roles and two URLs; `migrate` provisions the application role; the RLS test connects as that role.
2. `connections.target` is blanked for every connection kind before upload; the connections view hides an empty path.
3. The mirror answers `diagnostics.read` with an additive `sync` section; the enrollment screen lives in `Apps/iOS`; secret references move to a shared `WorkspaceSecrets` module.
4. Revoking a device keeps its uploaded history; `hub leave` and a later `hub join` re-upload idempotently.
5. (From the reviewer's checked list) pre-join change rows recorded as `'local'` are re-attributed to the enrolled device id at upload time; `enroll` takes `--org` once more than one exists.

## Left to the builder

- Exact Rust crate versions (pinned with `=`, newest stable when the task is executed, recorded in `docs/compatibility.md`), module layout inside the crates, and the error type.
- The SQLite schema's exact DDL on iOS, provided the column names match Postgres and `apply` matches `WorkspaceDatabase.replay` semantics, which the shared fixture tests enforce.
- How `HubSync` sits inside the coordinator (an actor beside `SessionService` that observes commits is the obvious shape) and how it is told about writes without the storage layer learning about the hub.
- The enrollment screen's layout, within the LLA visual system.
- Whether `GET /v1/changes` long-poll uses `LISTEN/NOTIFY` or a periodic check; either is acceptable for M8a if the Simulator sees a new turn within five seconds.
