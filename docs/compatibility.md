# Compatibility manifest

Recorded on 2026-10-30 (M0 baseline, updated for M1 the same day, M2 to M6 and M8a on 2026-10-31, M8b on 2026-11-01). Update whenever a pinned version, a verified behavior, or a known limit changes. "Verified" means exercised on the target Mac or against the real published artifact; "reviewed" means read in source or docs only.

## Target machine

| Item | Value |
| --- | --- |
| Hardware | Apple Silicon (arm64) |
| macOS | 26.5 (Darwin 25.5.0) |
| Xcode | 26.6 (17F113), Swift 6.3.3 |
| XcodeGen | 2.46.0 |
| Node (for B4 servers only) | v24.20.0 at `~/.nvm/versions/node/v24.20.0/bin/node` (found on `PATH` by `NodeLocator`, or without a shell through the nvm layout, D-040; `B4APP_NODE_PATH` overrides) |
| Code-signing identity | none installed (`security find-identity -v -p codesigning`: 0 valid); packages are signed ad hoc (D-039) |
| Fonts bundled | Hanken Grotesk Regular and SemiBold (OFL, from the LiveLoveApp repository), JetBrains Mono variable (OFL); registered per process with CoreText |
| App version | 0.1.0 (`CoordinatorVersion.current`, stamped into the bundle by `Scripts/package.sh`) |
| Rust | 1.93.1 (`Hub/rust-toolchain.toml`, `profile = "minimal"` with `rustfmt` and `clippy`; `rust-version` 1.93.1 in the workspace manifest); used by the hub only |
| Docker | 27.4.0 (Docker Desktop) on the build Mac; builds ran `linux/arm64` only (`linux/amd64` unverified); the Mac's `docker-credential-desktop` hangs, so builds and Compose runs used a throwaway `DOCKER_CONFIG` containing `{}` |
| iOS Simulator | iOS 26.5, iPhone 17 Pro; the data-protection Keychain needs a signed build (`CODE_SIGNING_ALLOWED=NO` fails with -34018), so the Simulator run used Xcode's ad hoc "Sign to Run Locally" |
| PostgreSQL | 17.11 (zonky `embedded-postgres-binaries-darwin-arm64v8` 17.11.0, SHA-256 pinned in `Scripts/fetch-postgres.sh`; server, initdb, pg_ctl, libpq, PL/pgSQL, dict_snowball; 62 MB after thinning); the cluster listens only on a Unix socket in the runtime directory |

Xcode 27 (Swift 6.4) requires macOS 26.6; the package uses `swift-tools-version: 6.2` so either toolchain builds it.

## Pinned dependencies

| Package | Version | Used for |
| --- | --- | --- |
| GRDB.swift | 7.11.1 | SQLite with WAL, migrations, Codable records |
| swift-nio | 2.104.0 | Unix socket server and client |
| swift-nio-extras | 1.35.x | `LineBasedFrameDecoder` for NDJSON |
| swift-subprocess | 1.0.2 | Running `codex`, `claude`, and `node` with bounded output and timeouts |
| swift-argument-parser | 1.8.2 | `agent-workspace` CLI |

Exact resolved versions are in `Package.resolved`. The iOS mirror links the system `sqlite3`; no package provides it.

## Hub (M8a)

Pinned exactly (`=`) in `Hub/Cargo.toml` `[workspace.dependencies]`, resolved in the committed `Hub/Cargo.lock`; builds and tests run `--locked`.

| Crate | Version | Used for |
| --- | --- | --- |
| axum | 0.8.9 (`http1`, `tokio`, `json`) | HTTP routes |
| tokio | 1.54.1 | runtime, signals, timers |
| sqlx | 0.8.6 (`runtime-tokio`, `tls-rustls-ring`, `postgres`, `migrate`, `uuid`, `macros`, `json`) | PostgreSQL, migrations, `#[sqlx::test]` |
| serde / serde_json | 1.0.229 / 1.0.154 | wire types |
| clap | 4.6.7 | `serve`, `migrate`, `seed`, `enroll` |
| tracing / tracing-subscriber | 0.1.44 / 0.3.23 | logs (`B4HUB_LOG`) |
| uuid | 1.29.0 (`v7`, `serde`) | hub-minted ids |
| sha2, hmac | 0.10.9, 0.12.1 | token and code hashes; SCRAM-SHA-256 verifier for `b4hub_app` |
| base64, getrandom | 0.22.1, 0.4.3 | token encoding and randomness |
| thiserror, url, percent-encoding | 2.0.21, 2.5.8, 2.3.2 | errors, `DATABASE_URL` handling |
| tower, http-body-util, hyper, hyper-util | 0.5.3, 0.1.5, 1.12.0, 0.1.21 | in-process route tests and the HTTP test client (dev) |

| Item | Value |
| --- | --- |
| Hub protocol | `minClientProtocol` 1 (unchanged by M8b: the new fields are additive and the hub ships before the clients); `Hub/API.md` is the wire reference |
| Builder image | `rust:1.93.1-slim-bookworm@sha256:5b9332190bb3b9ece73b810cd1f1e9f06343b294ce184bcb067f0747d7d333ea` (index digest) |
| Runtime image | `debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3` (index digest); runs as uid 10001, `STOPSIGNAL SIGTERM`, `HEALTHCHECK` on `/readyz` |
| Build cache | `cargo-chef` 0.1.78 (`cargo install --locked --version 0.1.78` in the `chef` stage; latest on crates.io on 2026-11-01); a source-only change reuses the dependency `cook` layer (checked on `linux/arm64`) |
| RDS CA bundle | `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`, fetched at image build on 2026-11-01 (114 certificates, 174,560 bytes), installed at `/etc/ssl/certs/rds-global-bundle.pem`; `Hub/scripts/check-image.sh <image>` asserts it, uid 10001, and that `b4hub` links no libssl (`libssl3` is on the image only as a dependency of `curl`) |
| Compose database | `postgres:17`, not digest-pinned (the index digest seen on 2026-10-31 was `sha256:31ba9c94a03ada9988f2bb493a22a75eef3a185884533e5cdbcd498ea835b08f`); CI's `hub` job uses a `postgres:17` service on Ubuntu |
| Test database | the zonky PostgreSQL 17.11 from `./Scripts/fetch-postgres.sh`, started by `Hub/scripts/test-db.sh` on 127.0.0.1:54329 |
| Architectures | `linux/arm64` built and run on the build Mac; `linux/amd64` not built (both base digests are multi-platform indexes, so nothing in the Dockerfile is architecture-specific, but that is reasoning, not a check) |

### Hub and storage additions (M8b)

No dependency, toolchain, or image changed in M8b. What changed is the contract between the hub, the Mac, and the phone; every addition is backward compatible with an M8a client, which is why `minClientProtocol` stays 1.

| Item | Value |
| --- | --- |
| `hlc` on `Change` and `StoredChange` | A hybrid logical clock, `<12 hex ms>-<4 hex counter>-<device id>`, compared as plain strings. Optional on upload (the hub derives `<wall>-0000-<device>`); always present on the feed; a malformed value rejects that change (`invalid_clock`). A clock more than 300,000 ms ahead of the hub is rewritten to the hub's time |
| `rejected` on the `POST /v1/changes` response | `[{deviceSeq, code}]` with `column_not_writable`, `payload_too_large`, or `invalid_clock`; omitted when empty, so an M8a client decodes the response unchanged. A value over 2 MiB is no longer a 413 (only a body over 32 MiB is) |
| `GET /v1/snapshot` | The user's mirror as synthetic `insert` changes in dependency order, the per-column `clocks`, and `next`; one `REPEATABLE READ` read, unpaged. Answers a client that got `410 resync_required` |
| `GET /v1/devices` | The user's devices with `id`, `name`, `platform`, `lastSeenAt`, `revokedAt` |
| `GET /v1/changes` paging | A page stops at 1000 changes or 8 MiB (8,388,608 bytes) of stored `value_bytes`, whichever is first, never fewer than one change; an uncut page's `next` is the org's highest `hubSeq`. `410 resync_required` is now answered for any cursor below the org horizon |
| Retention | `B4HUB_RETENTION_DAYS` (default 30; a whole number of at least 1, else exit 2); `serve` prunes at start and every 24 h; `b4hub prune --older-than-days N [--org slug]` |
| Hub migration | `0003_organisation.sql` (`changes.hlc`, `received_at`, `value_bytes`; `owner_device_id` on every materialised table; `projects`, `projectFolders`, `column_clocks`, `org_sync_horizons`; `threads."projectId"` and `"readTurnId"`). Run it with `migrate` before starting a new `serve`; `/readyz` reports `"migrations":"current"` afterwards. It backfills `value_bytes` and `owner_device_id` with full-table updates |
| Hub write rule | A `macos` device may write any column. An `ios` or `cli` device may `update` `threads.title|pinned|archived|readTurnId`, `projects.name`, `drafts.threadId|text|updatedAt`, and `insert` `drafts` rows; nothing else, and no deletes |
| Local migration | `0004_organisation.sql` (`projects`, `projectFolders`, `threads.projectId` and `readTurnId`, `changes.hlc` backfilled from `wall`, `columnClocks`, the new trigger function), followed by the Swift backfill of automatic projects. A JSON-lines `db backup` precedes it (the pinned build has no `pg_dump`, D-041). Rows that existed before it have no column clocks |
| Archive version | `3` (`db backup`/`db restore`): adds `projects`, `projectFolders`, `columnClocks`, and the new thread and change columns. Versions 1 and 2 are still read; an archive newer than the build is refused |
| iOS mirror schema | `user_version` 2 (`projects`, `projectFolders`, `devices`, `outbox`, `columnClocks`, `ownerDeviceId`, `threads.projectId` and `readTurnId`, `syncState.refusedUploads`), reached by ordered migrations from v1; a file the app cannot migrate is rebuilt only with an empty outbox |
| New cross-language fixtures | `Tests/Fixtures/sync/conflicts.json` (read by the Swift and Rust suites) and `Tests/Fixtures/sync/attention.json` (read by the coordinator's store and the mirror's store); `changes.json` gained `hlc` on every entry and nothing else, so M8a's count-based assertions stay valid |
| Test database | Unchanged. Rust suite: 117 tests; Swift suite: 517 tests |

## Provider runtimes

| Runtime | Installed on target Mac | Published | Verified behavior | Limits and gates |
| --- | --- | --- | --- | --- |
| Codex CLI (`@openai/codex`) | 0.166.0 at `/opt/homebrew/bin/codex` (Homebrew cask, upgraded from a broken 0.128.0 install on 2026-10-30) | 0.166.0 (2026-10-29) | Live: `codex app-server` handshake, `account/read` (ChatGPT, `promax`), `account/login/start`, `thread/start`, `thread/resume`, `thread/turns/list`, `turn/start` with streamed `item/*` notifications, a tool turn (`commandExecution`), `turn/interrupt` ending as `interrupted`, reopen with history. Schema generated with `codex app-server generate-json-schema --out <dir>` from this binary and hand-typed (D-010). | Adapter minimum: 0.166.0. App-server is labelled experimental; regenerate the schema and re-run `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` after every upgrade. A real `item/commandExecution/requestApproval` round trip was exercised on 2026-10-31 through the live test only: the owner's configuration is `approval_policy = "never"` with `danger-full-access`, so the test asks `thread/start` for `approvalPolicy: on-request` and `sandbox: workspace-write` (both honored in the response) and a network command then needs approval; the app itself never passes a policy (D-012). Not exercised live: `item/fileChange/requestApproval`, `item/tool/requestUserInput`, sign-in completion from a signed-out state. |
| Claude Code | 2.1.282 at `~/.local/bin/claude` | Agent SDK 0.3.314 (bundles 2.1.314) | `claude auth status --json` parsed live; the stream-json `initialize` handshake, `--session-id`, `system/init` (with `claude_code_version`, `apiKeySource`, `capabilities`), the replayed `user` frame, a synthetic `assistant` error frame, a `result` with `subtype: success` and `is_error: true`, and `--resume` of an unknown id were all recorded live on 2026-10-31 while the Mac was signed out. Through the coordinator, `connection add --kind claude` reports `ready / auth_required` and `thread new` refuses with `auth_required`. | Adapter minimum: 2.1.200. The control protocol is undocumented (D-002); re-diff on CLI upgrades. **No inference turn has run live yet**: the Mac was signed out all day. Run `claude auth login`, then `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`. Fixture coverage mirrors the Codex suite. |
| B4 (`@b4run/cli`) | Not on PATH; the trusted project is `~/repos/b4app-live-check` (0.15.8 project-installed, one `/chat#agent` route on `gpt-5-mini`; the M3 scratch project copied out of `/tmp` on 2026-10-31), registered as the managed server `research`; `~/repos/hashbrown` has 0.14.0 (workflow routes only) | 0.15.8 (2026-10-30), Node `>=24` | Live on 2026-10-31 against `b4 dev` 0.15.8 serving a `gpt-5-mini` `agent()` route with `workspace/`: `POST /threads`, streamed turns, `tool_call_args`/`tool_call`/`step`/`tool_result`, `usage`, a real `permission-request` interrupt for `ls -la` parked and answered with `once` through `request respond`, `POST /cancel` → `cancelled`, `GET /state` history, `GET /turns` reconciliation; through the adapter (`B4Live`), the coordinator, and the CLI. Fixture-verified beyond that: stream drop with reattach, server restart with stores preserved, coordinator restart while parked, bearer middleware 401, unknown route 404. | Adapter minimum: 0.15.7 (also the managed-server minimum, read from the project's `node_modules/@b4run/cli/package.json`). Only `agent` routes converse (D-023). A parked prompt survived a real `b4 dev` restart on `.b4/*.sqlite` plus a coordinator restart. Managed (M4, live on 2026-10-31 with 0.15.8): `b4 routes --json --cwd <project>` printed `{ appRoot, routes: [{ id, pathname, kind, entryFile, routeDir, segments }] }` with an absolute `entryFile`; `b4 start --host 127.0.0.1 --port N` answered `/healthz` in about one second and printed `b4 start listening on …`; `b4 dev --port N --env-file P` printed `Loaded … variable(s)` and `B4.run dev ready at …` in under two seconds and forwarded SIGTERM to its runtime child; a `restart` kept `.b4` and the thread's history. Not exercised live: a remote HTTPS endpoint with a real endpoint credential, approval grants, `detached capacity`, a project whose `b4.config.ts` `env` differs from the file passed. |

## Protocol observations captured for adapters

- Codex app-server (verified live on 0.166.0): newline-delimited JSON-RPC without the `jsonrpc` field; `initialize` then `initialized`; the server emits `configWarning`, `remoteControl/status/changed`, and `account/updated` right after the handshake and clients must ignore unknown methods. `account/read` distinguishes `chatgpt` from `apiKey`. A turn echoes the user message as an `item/started` + `item/completed` `userMessage` pair before the agent items; reasoning arrives as a `reasoning` item. `turn/completed.turn.status` is `completed | interrupted | failed`. Notification params for `thread/status/changed` use `{ type, activeFlags }`. Generated schema policy strings are `untrusted | on-request | never` and `read-only | workspace-write | danger-full-access`.
- Claude Code (recorded live on 2.1.282, 2026-10-31): write `control_request initialize` before any user message and wait for its `control_response`; the user's `SessionStart` hooks run first and emit `system/hook_started` / `system/hook_response`; `command_lifecycle` frames bracket each turn; `system/init` arrives per turn with `apiKeySource` (`none` for plan login) and `capabilities`; `--replay-user-messages` echoes the input as a `user` frame with `isReplay: true`; a synthetic `assistant` frame carries `error` (for example `authentication_failed`) and `is_api_error_message`; `result` may be `subtype: success` with `is_error: true` and `terminal_reason: api_error`; `--resume` of an unknown id emits one `result error_during_execution` and exits 1. Strip `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`; never pass `--bare`; `AskUserQuestion` arrives through `can_use_tool`; end a session by closing stdin after `interrupt`.
- B4 (source-verified and live-verified on 0.15.8, 2026-10-31; see `docs/research/2026-10-30-b4-runtime.md`): the live server also emits `usage` once per model call (summed into `turn.finished.usage`), `step` display updates keyed by `toolCallId` (folded into the tool card), `tool_call_args` before `tool_call`, and `tool_result.output` as a serialized `ToolMessage` (its `content` is the result); `GET /turns` nests the list under `turns.turns`; no thread-list endpoint and no run id, so the app names turns by their ordinal in `GET /threads/:id/turns` (D-019); `done` carries several outcomes; `interrupted` means cancelled or parked and `GET /pending_interrupts` tells them apart (D-020); a permission prompt is `interrupt { interruptId, type: "permission-request", kind, detail, grant? }` answered with `POST /resume { resume: [{ interruptId, status, payload?, grant? }], route }` whose response is a second SSE stream (D-021); `GET /runs/stream` reattaches and sends only frames after the attach; `runs/stream` checks route before middleware, so an unknown route is a 404 and a rejected credential a 401 on the first turn, never on the health check; no built-in endpoint auth, so the health check cannot verify a secret.

## Hosted hub infrastructure (Terraform)

| Item | Version |
| --- | --- |
| Terraform | 1.17.1 (`Infra/.terraform-version`, `required_version >= 1.17.1, < 2.0.0`) |
| `hashicorp/aws` provider | 6.71.0, pinned exactly in `Infra/bootstrap/versions.tf` and `.terraform.lock.hcl` (darwin_arm64, linux_amd64, linux_arm64 hashes) |
| TFLint | 0.65.0 with the bundled `terraform` ruleset 0.15.0 (`recommended`); the AWS ruleset is not enabled |

`Infra/bootstrap` was verified with `terraform validate`, `tflint`, and `terraform test` against a mocked provider only; it has not been applied to a real account.

## Known limits of the shell

- Codex, Claude Code, attached B4 endpoints, and managed local B4 servers have conversation paths. Managed servers: one owned instance per registered project, source or development mode, loopback only, logs on disk with redaction on read, ownership by pid plus start time plus argv (D-025); a registration cannot be removed yet, a port cannot change once a route connection exists (D-027), `server stop` refuses while a turn is running unless `--force` (D-030), nothing is auto-started, and the Quit choice of spec 10.3 is M5 (Quit keeps servers running). Model selection, `turn/steer`, image input, importing native threads, Claude hook callbacks, MCP messages, elicitation forms, console (API) billing sign-in, B4 client tool calls, non-agent B4 routes, custom header names for B4 endpoint auth, and persisted credential labels are not implemented.
- A B4 endpoint secret is one bearer value per connection; `credential add` returns a `secret:` reference and nothing lists stored credentials yet. Stop on a parked B4 turn declines its prompt (D-021). A B4 server that restarts mid-run loses the run; the app marks that turn `failed` and the thread is usable again.
- Claude Code 2.1.282 answers an `interrupt` control request with a `result` frame that has `is_error` set and terminal reason `aborted_streaming`; the adapter maps a requested stop to `cancelled` (verified live 2026-10-31). Claude `allow_always` is sent as a plain allow (D-018); Claude history comes from the transcript file (D-017); a Claude process exit ends its turn as failed (D-016).
- Runtime request kinds the app cannot present (`item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/call`, token refresh, attestation) are declined automatically with a valid response and shown as resolved.
- A turn whose `codex app-server` process exits stays `reconciling` until the thread is reopened and Codex reports the turn's final status; the composer refuses a new turn until then.
- The packaged app installs a per-user LaunchAgent plist (`~/Library/LaunchAgents`, D-042) that runs the bundled coordinator, which starts the PostgreSQL cluster; an Xcode-run app or a failed bootstrap falls back to in-process hosting. `SMAppService` is not used while builds are ad hoc: launchd pins the managed program's hash and a rebuild leaves it unspawnable. The coordinator has no idle shutdown. `coordinator restart` and the app's Coordinator menu replace a coordinator left behind by an upgrade.
- iOS reads a SQLite mirror of what the hub holds (D-046) and, since M8b, writes titles, pins, archive, read markers, project names, and drafts through an outbox (D-049). It still cannot create or edit projects, send turns, or answer approvals; the relay is M8c. Turns and runtime requests now publish their thread live. The shell still shows Mac wording on the phone ("Coordinator connected"), with a one-line "Not synced since …" banner above it while pulls fail; a phone whose pulls succeed cannot tell that the Mac is asleep (presence is M8c), and the thread header shows the Mac's working directory (`threads.context`).
- On macOS the Keychain is the file-based login keychain; the macOS data-protection keychain needs a provisioning profile, which needs a signing identity (D-008, D-039). On iOS the token lives in the data-protection keychain, which works with ad hoc signing (the M8a Task 9 Simulator run used Xcode's "Sign to Run Locally"); only an unsigned build fails, with -34018.
- The store is a private PostgreSQL cluster per Mac (D-041); the schema is `0001_init`, `0002_changes`, `0003_hub`, and `0004_organisation`; backups are JSON-lines archives from `db backup`, not `pg_dump`; a pre-0.2 `workspace.sqlite` is imported once and retired. Sync is M8a's push plus M8b's pull and phone writes (D-043 to D-050): a Mac that ran `hub join` pushes its change log and applies the phone's edits of titles, pins, archive, read markers, project names, and drafts (a narrow merge, never a row copy); everything else is Mac-only. Compose publishes the hub on `127.0.0.1:8080` only (plain HTTP on the loopback interface; the Simulator shares the Mac's loopback). `database.restore` fails with `invalid input syntax for type json` on an archive whose change log holds an `update` of a scalar jsonb value (found during M8a, not fixed; see `docs/verification.md`).
- Packaging is ad hoc: the app runs on the Mac that built it. Developer ID signing and notarisation are untested (no certificate). Removing a registration and changing a server's port are still missing.
