# Compatibility manifest

Recorded on 2026-10-30 (M0 baseline, updated for M1 the same day, M2 to M6 and M8a on 2026-10-31, M8b on 2026-11-01, hosted-hub tooling, M8c, sign-in, M8f, and M8f APNs on 2026-11-02). Update whenever a pinned version, a verified behavior, or a known limit changes. "Verified" means exercised on the target Mac or against the real published artifact; "reviewed" means read in source or docs only.

## Target machine

| Item | Value |
| --- | --- |
| Hardware | Apple Silicon (arm64) |
| macOS | 26.5 (Darwin 25.5.0) |
| Xcode | 26.6 (17F113), Swift 6.3.3 |
| XcodeGen | 2.46.0 |
| macOS recovery smoke | XCUITest on macOS 26.5 / Xcode 26.6, with a test-only app, separate real coordinator and ephemeral PostgreSQL, and fixture provider. Requires an active desktop session; the test runner opts out of App Sandbox. See [verification](verification/2026-11-09-macos-recovery-smoke.md). |
| B4 runtime integration | Node 24.20.0; published `@b4run/cli`, `core`, `sdk` and `langchain` 0.15.8; `@copilotkit/aimock` 1.47.0. Exact npm dependency graph in `Tests/B4Runtime/package-lock.json`. The real CLI, agent, tool executor and SQLite persistence run against a simulated loopback model provider; this is fixture integration, not live-model or installed-app evidence. See [trial](verification/2026-11-09-b4-aimock-trial.md) and [workspace smoke gate](verification/2026-11-09-real-b4-workspace-smoke.md). The macOS smoke suite reuses these pins through a test-owned supervisor; no runtime package enters the shipped app. |
| Node (for B4 servers only) | v24.20.0 at `~/.nvm/versions/node/v24.20.0/bin/node` (found on `PATH` by `NodeLocator`, or without a shell through the nvm layout, D-040; `B4APP_NODE_PATH` overrides) |
| Code-signing identity | none installed (`security find-identity -v -p codesigning`: 0 valid); packages are signed ad hoc (D-039) |
| Fonts bundled | Hanken Grotesk Regular and SemiBold (OFL, from the LiveLoveApp repository), Hanken Grotesk Medium (500; OFL; the static `fonts/ttf/HankenGrotesk-Medium.ttf` from the designer's repository, https://github.com/marcologous/hanken-grotesk, taken unmodified from `https://raw.githubusercontent.com/marcologous/hanken-grotesk/master/fonts/ttf/HankenGrotesk-Medium.ttf` on 2026-11-11, SHA-256 `d14c46b4c5e9e65d2ce5fbc01e0dd3b342c8cdac624ef1e5174ef11c40dfea6b`; TrueType, family "Hanken Grotesk", weight class 500, PostScript name `HankenGrotesk-Medium`; the licence in the file and in `OFL-HankenGrotesk.txt` is the SIL OFL 1.1; Google Fonts ships only a variable font, `ofl/hankengrotesk`), JetBrains Mono variable (OFL); registered per process with CoreText |
| App version | 0.1.0 (`CoordinatorVersion.current`, stamped into the bundle by `Scripts/package.sh`) |
| Rust | 1.93.1 (`Hub/rust-toolchain.toml`, `profile = "minimal"` with `rustfmt` and `clippy`; `rust-version` 1.93.1 in the workspace manifest); used by the hub only |
| Docker | 27.4.0 (Docker Desktop) on the build Mac; builds ran `linux/arm64` only (`linux/amd64` unverified); the Mac's `docker-credential-desktop` hangs, so builds and Compose runs used a throwaway `DOCKER_CONFIG` containing `{}` |
| iOS Simulator | iOS 26.5, iPhone 17 Pro; the data-protection Keychain needs a signed build (`CODE_SIGNING_ALLOWED=NO` fails with -34018), so the Simulator run used Xcode's ad hoc "Sign to Run Locally" |
| Simulator notifications (M8f) | `xcrun simctl push <device> <file>` from Xcode 26.6 delivers a `.apns` file carrying `Simulator Target Bundle`; with `content-available` it wakes the app as a background fetch, so Debug builds declare the `fetch` background mode beside `remote-notification` (D-128; Release declares only `remote-notification`). The Simulator registers an 80-byte (160 hex) device token. WidgetKit extensions and App Group containers work with ad hoc "Sign to Run Locally" Simulator builds |
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
| axum | 0.8.9 (`http1`, `tokio`, `json`, and since M8c `ws`) | HTTP routes and the relay's WebSocket upgrade |
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
| Test database | the zonky PostgreSQL 17.11 from `./Scripts/fetch-postgres.sh`, started by `Hub/scripts/test-db.sh` on 127.0.0.1, one cluster per checkout on a port from 54400 to 55399 |
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
| Archive background refresh (2026-11-06) | Applied archive/unarchive updates send an additive silent APNs refresh through the existing phone catch-up path, including quiet threads without notification ledger entries. One per eligible other phone per batch; an existing alert/withdrawal covers that recipient. No schema, entitlement or minimum OS change. APNs delivery and widget rendering remain best effort. Validation and release state: `docs/verification/2026-11-06-archive-background-wake.md`; production deployment and physical retest pending. |
| iPhone background catch-up (2026-11-06) | The app waits for a fresh sync cycle to apply and publish the final page (`more=false`), including after a snapshot; pending refreshes and remaining pages disable long polling. Overlapping wakes repeat catch-up when needed within the shared time budget. No hub protocol, schema, entitlement or minimum OS change. Fixture validation and production build are recorded in `docs/verification/2026-11-06-widget-background-catchup.md`; J initially failed; K/L/M subsequently passed, including untethered and locked-idle trials. The earlier failure remains unexplained. |
| Retention | `B4HUB_RETENTION_DAYS` (default 30; a whole number of at least 1, else exit 2); `serve` prunes at start and every 24 h; `b4hub prune --older-than-days N [--org slug]` |
| Hub migration | `0003_organisation.sql` (`changes.hlc`, `received_at`, `value_bytes`; `owner_device_id` on every materialised table; `projects`, `projectFolders`, `column_clocks`, `org_sync_horizons`; `threads."projectId"` and `"readTurnId"`). Run it with `migrate` before starting a new `serve`; `/readyz` reports `"migrations":"current"` afterwards. It backfills `value_bytes` and `owner_device_id` with full-table updates |
| Hub write rule | A `macos` device may write any column. An `ios` or `cli` device may `update` `threads.title|pinned|archived|readTurnId`, `projects.name`, `drafts.threadId|text|updatedAt`, and `insert` `drafts` rows; nothing else, and no deletes |
| Local migration | `0004_organisation.sql` (`projects`, `projectFolders`, `threads.projectId` and `readTurnId`, `changes.hlc` backfilled from `wall`, `columnClocks`, the new trigger function), followed by the Swift backfill of automatic projects. A JSON-lines `db backup` precedes it (the pinned build has no `pg_dump`, D-041). Rows that existed before it have no column clocks |
| Archive version | `3` (`db backup`/`db restore`): adds `projects`, `projectFolders`, `columnClocks`, and the new thread and change columns. Versions 1 and 2 are still read; an archive newer than the build is refused |
| iOS mirror schema | `user_version` 2 (`projects`, `projectFolders`, `devices`, `outbox`, `columnClocks`, `ownerDeviceId`, `threads.projectId` and `readTurnId`, `syncState.refusedUploads`), reached by ordered migrations from v1; a file the app cannot migrate is rebuilt only with an empty outbox |
| New cross-language fixtures | `Tests/Fixtures/sync/conflicts.json` (read by the Swift and Rust suites) and `Tests/Fixtures/sync/attention.json` (read by the coordinator's store and the mirror's store); `changes.json` gained `hlc` on every entry and nothing else, so M8a's count-based assertions stay valid |
| Test database | Unchanged. Rust suite: 117 tests; Swift suite: 517 tests |

### Hub link (M8c)

The relay link adds WebSocket support to the hub. Pinned exactly (`=`) in `Hub/Cargo.toml`, resolved in the committed `Hub/Cargo.lock`.

| Crate | Version | Used for |
| --- | --- | --- |
| axum | 0.8.9, `ws` feature added | the `GET /v1/devices/self/link` upgrade; brings `tungstenite` 0.29.0 and `sha1` 0.10.7 into the hub |
| tokio-tungstenite | 0.29.0 (dev dependency; the version axum's `ws` resolves to, so there is one copy of `tungstenite`) | the fake Macs and phones in the relay tests |
| futures-util | 0.3.34 (`sink`, `std`; dev dependency, the version already in the lock) | `SinkExt`/`StreamExt` on the test sockets |
| tokio `test-util` | 1.54.1 (dev dependency feature) | `tokio::time::pause()` in the relay tests |

Locking `tokio-tungstenite` and `tungstenite` also adds `data-encoding` 2.11.1 and a second `rand` line (0.9.5, with `rand_chacha` 0.9.0, `rand_core` 0.9.5, `getrandom` 0.3.4, `r-efi` 5.3.0, `wasip2` 1.0.4, `wit-bindgen` 0.57.1) beside the existing `rand` 0.8.8 that `sqlx` uses; no existing version moved.

| Item | Value |
| --- | --- |
| Link protocol | `protocol` 1 and `minClientProtocol` 1 in `hello`; a device names its protocol in `B4-Protocol` (missing counts as 1) |
| Close codes | 1001 shutdown; 4000 replaced; 4001 revoked; 4002 `client_too_old`; 4003 silent for 30 s (`Hub/API.md`, "Link") |
| Swift test-only packages | `NIOWebSocket` and `NIOHTTP1` (both from swift-nio 2.104.0, already pinned) are linked only by the `WorkspaceSyncTests` target (`Package.swift`), for the fake hub in `URLSessionLinkTests`; no shipped target links them. The shipped link uses `URLSessionWebSocketTask` (`URLSessionHubLinkConnection`), so the phone adds no dependency |
| Rust test-only crates | `tokio-tungstenite` 0.29.0 and `futures-util` 0.3.34 (both `[dev-dependencies]` of `b4hub`, pinned `=` in the workspace manifest and in `Hub/Cargo.lock`), and tokio's `test-util` feature; none is in the release binary's own code (`tungstenite` 0.29.0 and `sha1` 0.10.7 are, through axum's `ws`) |
| Hub API additions | `GET /v1/devices/self/link` (WebSocket upgrade; `429 rate_limited` after 10 upgrades a minute) and `POST /v1/pairing-codes` (`macos` devices only, `404` for others; ten codes per user per hour, then `429 rate_limited`). `DELETE /v1/devices/self` now also withdraws that device's unused pairing codes. The error table gains the HTTP `429 rate_limited` and six codes that appear only on the link (`device_offline`, `command_expired`, `relay_timeout`, `link_replaced`, `client_too_old`, `watch_limit`); a Mac's own codes such as `stale_runtime_request` pass through unchanged. `Hub/API.md` "Link" and "POST /v1/pairing-codes" are the reference |
| Hub migration | `0004_relay.sql`: `connections."projectId"` (nullable, no foreign key), `enrollment_codes.created_by_device_id`, and `pairing_mints` (with row-level security). Run `migrate` before starting the new `serve` |
| Mac-only column | `connections.projectId` is written by `macos` devices only (a phone's write is refused as `column_not_writable`), unscrubbed, and holds a project id already on the hub, never a path |
| Local store, mirror | No local PostgreSQL migration. The iOS mirror is `user_version` 3 (adds the index `displayItems("threadId","nativeItemId")` and `connections.projectId`), reached by the ordered migrations from v1 or v2 |
| New cross-language fixture | `Tests/Fixtures/sync/relay.json`, one example of every relay frame, decoded by `b4hub-core` and by `RelayWireTests`; `changes.json` gained `connections[].projectId` |
| Minimum client protocol | Still `1`. The link is new rather than changed, so no M8a or M8b client can mis-speak it, and a device that does not send `B4-Protocol` counts as 1 |

**Upgrade order: the hub first, then the Macs, then the phones.** Every addition is backward compatible in that direction; the reverse order loses nothing permanently but gives a degraded app until the hub catches up:

- A Mac on M8c against a hub from before M8c has no link to open (`GET /v1/devices/self/link` is a `404`), so its `RelayLink` retries with backoff (only a `401` stops it) and the Mac reads as reconnecting; "Pair iPhone…" gets a `404` and shows an error. Nothing else is affected: sync works as before.
- Its pushes carry `connections.projectId`. A hub without migration `0004` does not refuse that: `b4hub-core`'s table spec for `connections` has no `projectId` column, so an insert's extra key is ignored when the row is materialised, an `update` of that column is skipped (counted, not rejected, and `acceptedThrough` still covers it), and the change is still recorded with its whole value in the feed. The push neither fails nor blocks (a Rust test pins that unknown update columns are skipped, `b4hub-db/tests/changes.rs`). The cost: a connection row pushed while the hub was old has no `projectId` in the hub's tables, and so none in a snapshot, until that column next changes on the Mac (the backfill does not re-push a value that is already set). A phone that pulls the feed still receives the value.
- A phone on M8c against an old hub can sync and read as before but cannot link or pair, because the Mac cannot mint a code.
- A Mac that has not been updated never opens a link, so a new hub shows it offline and the phone's sends to it are refused with `device_offline`.

### Hub operability additions (M8e Part A)

Feature flags on two already-pinned crates, one crate already in the lock used from a second place, and one new transitive crate; nothing else changed.

| Item | Value |
| --- | --- |
| axum features | `matched-path` added (the `request` span's `path` is the matched route pattern) |
| tracing-subscriber features | `json` added, which pulls `tracing-serde` 0.2.0 (new in the lock) and `serde_json` |
| b4hub-db | now depends on `serde` (derive) for the `hub_settings` value |
| Hub migration | `0006_settings.sql` (`hub_settings`: `key`, `value jsonb`, `updated_at`; not tenant-scoped; `migrate` revokes writes from `b4hub_app`). `0004` and `0005` are reserved for the relay and accounts branches |
| sqlx 0.8.6 migration ordering | Verified in `Hub/crates/b4hub-db/tests/migrate.rs` (`sqlx_applies_a_lower_numbered_migration_added_later`) and by reading `Migrator::run_direct`: the migrator applies every embedded migration whose version the `_sqlx_migrations` ledger lacks, in version order, with no "newer than the latest applied" check, so `0004` and `0005` apply cleanly after `0006` is already in a database. The reverse is refused: a binary that lacks a version the ledger holds fails with `VersionMissing` (and a changed file with `VersionMismatch`), so a hub built from a branch without `0006` must not run `migrate` against a database that has it; merge order between branches is otherwise free. Two consequences for `0004` and `0005`: a production database will have applied `0006` before them while a fresh database applies them in number order, so they must not depend on or touch anything `0006` creates (in particular no blanket `GRANT ... ON ALL TABLES` or similar that would undo the `hub_settings` revoke; `migrate` re-applies that revoke after every run, and `0006` applies it itself when the role exists, but a later migration must not widen it); and the `grant_table_access` statement array in `migrate.rs` plus the `[1, 2, 3, 6]` and 4-row ledger assertions in `b4hub-db/tests/migrate.rs` will conflict textually for those branches |
| New environment | `B4HUB_LOG_FORMAT` (`text`, `json`; default by terminal), `B4HUB_TRUST_X_FORWARDED_FOR` (`1` or `true` on, `0`, `false`, or unset off; the sign-in limits read the same setting), `B4HUB_MAINTENANCE_POLL_MS` (default 5000) |
| New wire | `X-Request-Id` on every response; `503 maintenance` with `Retry-After: 30`; `"maintenance": "read_only"` on `/readyz`; all additive, `minClientProtocol` stays 1 |
| Test database | Unchanged. Rust suite: 135 tests |

### Hub instances (M8e Part B)

No new crates and no new features: `uuid`'s `v7` and `tokio`'s `sync`/`time` were already enabled.

| Item | Value |
| --- | --- |
| Hub migration | `0008_instances.sql` (`hub_instances`: `instance_id`, `started_at`, `heartbeat_at`, `public_url`; `user_links`: `user_id`, `instance_id`, `claimed_at`; hub-internal, no RLS, `b4hub_app` reads and writes). `0005` and `0007` are reserved for the sign-in branch |
| New environment | `B4HUB_HEARTBEAT_MS` (default 5000; the liveness window is four heartbeats; every instance of one hub must agree) |
| New wire | `409 relocated` (`details.instanceId`) at `GET /v1/devices/self/link`; `Set-Cookie: b4hub-instance=<id>` on accepted upgrades and `/readyz`; `"relay"` and `"instances"` on `/readyz`; a `maintenance` reply error over the link; all additive, `minClientProtocol` stays 1 |
| Swift | `ErrorCode.relocated`; `HubLinkConnection.open(url:token:protocolVersion:cookies:)` (defaulted for existing conformers) and `HubLinkSocket.responseCookies` (defaulted) |
| AWS ALB | application-cookie stickiness on `b4hub-instance`, 3600 s, enabled when `task_count > 1`; `deregistration_delay` 5 s when `task_count > 1` (60 s otherwise) |

### Hub sign-in additions (passkeys)

New crates, pinned exactly like the rest:

| Crate | Version | Used for |
| --- | --- | --- |
| webauthn-rs | 0.6.2 (`danger-allow-state-serialisation`, `conditional-ui`) | passkey registration and discoverable sign-in; ceremony state is serialised into `auth_ceremonies` |
| webauthn-rs-proto | 0.6.2 | the registration options' `authenticatorSelection` (resident key and user verification required), which `webauthn-rs` does not re-export |
| uuid | 1.29.0, now also `v4` | random ceremony ids and passkey user handles |
| p256 | 0.14.0 (`ecdsa`, `std`; dev only) | the tests' software authenticator (`crates/b4hub/tests/common/authenticator.rs`); the same version webauthn-rs already pulls in |

webauthn-rs 0.6 verifies with RustCrypto (`crypto-glue`, `p256` 0.14), not OpenSSL: `cargo tree -i openssl-sys` matches nothing, so the image needs no `libssl`. `webauthn-authenticator-rs` 0.6.2 was not used: its `SoftPasskey` refuses resident keys and needs an allow-list, so it cannot answer a discoverable sign-in.

| Item | Value |
| --- | --- |
| Hub environment | `serve` now requires `B4HUB_WEBAUTHN_RP_ID` (a bare domain; the origin is `https://<rp id>`) and `B4HUB_SECRET_KEY` (32 bytes, base64), and reads `B4HUB_SIGNUP` (`open`/`closed`, default `closed`), `B4HUB_TRUST_X_FORWARDED_FOR` (`1`/`true`, `0`/`false`), and the `B4HUB_APPLE_*` set (all or none). A missing or malformed one exits 2. The secrets also take `_FILE` forms (below). Compose passes `B4HUB_WEBAUTHN_RP_ID` (default `local.b4.run`), `B4HUB_SIGNUP` (default `closed`; `.env.example` sets `open`), and `B4HUB_SECRET_KEY` (required) to `hub` only |
| Routes | `GET /v1/auth/config`, `POST /v1/auth/passkey/begin`, `POST /v1/auth/passkey/finish` (the account routes are under "accounts and the wire" below); errors `signup_closed` (403), `ceremony_expired` (400), `credential_rejected` (401), `rate_limited` (429, `details.retryAfterMs` and `Retry-After`) |
| Rate limits | In memory per process, a fixed one-minute window per client (an IPv4 address or an IPv6 /64): 20 begins, 10 finishes, shared by the `/v1/auth/` and `/v1/me/` passkey and Apple routes; at most 100,000 tracked clients per limit, swept once a minute |
| Logging | The pool disables sqlx's statement logging (SQL text never reaches the log), and a filter layer separate from `B4HUB_LOG` drops every event from a target starting with `webauthn` (webauthn-rs logs responses and challenges at DEBUG and TRACE), so no `B4HUB_LOG` directive can re-enable it |
| Hub protocol | `minClientProtocol` stays 1: the routes are new and nothing existing changed shape |

### Hub sign-in additions (Sign in with Apple)

New crates, pinned exactly like the rest:

| Crate | Version | Used for |
| --- | --- | --- |
| jsonwebtoken | 11.1.0 (default features off; `use_pem`, `rust_crypto`) | verifying Apple identity tokens (`RS256`, which Apple's key set uses, and `ES256`) and signing the ES256 client secret with the `.p8` key. `rust_crypto` is RustCrypto (`p256` 0.13, `rsa` 0.9); the default `aws_lc_rs` backend was left off. The hub only verifies RSA signatures, so `rsa`'s timing advisory (RUSTSEC-2023-0071, private-key operations) does not apply |
| reqwest | 0.12.28 (default features off; `rustls-tls`) | calls to Apple's `/auth/keys`, `/auth/token`, `/auth/revoke`: rustls 0.23 with `ring` and the bundled `webpki-roots`, so no OpenSSL and no system trust store. 0.13.5 is newer, but its `rustls` feature uses `aws-lc-rs` |
| percent-encoding | 2.3.2 (already a workspace pin) | the authorize URL's query (`%20`, never `+`) |
| sha2 | 0.10.9, now a normal dependency of `b4hub` | the nonce Apple is handed and the handoff verifier |

`cargo tree -e normal -i openssl-sys` still matches nothing.

| Item | Value |
| --- | --- |
| Hub environment | New: `B4HUB_APPLE_SERVICES_ID` (optional; must be one of `B4HUB_APPLE_AUDIENCES`; set without the other `B4HUB_APPLE_*` it exits 2): the web flow's client id. `apple.web` needs it and `B4HUB_PUBLIC_URL`. `B4HUB_APPLE_BASE_URL` stays tests-only. A `B4HUB_APPLE_PRIVATE_KEY` that does not sign exits 2. The hosted hubs set `B4HUB_APPLE_SERVICES_ID=com.cacheplane.b4app.signin` |
| Hub environment (D-140) | New: `B4HUB_APPLE_CALLBACK_SCHEME`, `b4app`, `b4app-beta`, or `b4app-local`: the one app scheme the web flow hands back to. Required with `B4HUB_APPLE_SERVICES_ID` and refused without it (either alone, or a value off the list, exits 2), so a hub release with it must ship with the variable set wherever the web flow is on. Begin refuses any other scheme (`400 invalid_request`). The hosted hubs set `b4app-beta` (test) and `b4app` (prod); chart 0.3.0 adds `hub.apple.callbackScheme` |
| Hub environment (D-160) | New: `B4HUB_APPLE_CALLBACK_URL`, an https URL on the flavour's site (for example `https://b4.run/app/auth/apple`), as the alternative to `B4HUB_APPLE_CALLBACK_SCHEME`: exactly one with the web flow. Begin takes `httpsCallback` and answers `callback`; a URL hub refuses a Mac app older than D-160. The hosted hubs stay on the scheme until a Mac build with D-160 is out. Chart 0.4.0 adds `hub.apple.callbackUrl`. `ASWebAuthenticationSession`'s https callback needs macOS 14.4 (the app targets 26) |
| Routes | `POST /v1/auth/apple/begin`, `POST /v1/auth/apple/native`, `GET /v1/auth/apple/start`, `POST /v1/auth/apple/callback`, `POST /v1/auth/handoff`, `POST /v1/me/apple`, `POST /v1/me/apple/native`, `POST /v1/me/apple/handoff`; all `404 not_found` without Apple configured. New error `apple_linked` (409), also Swift's `ErrorCode.appleLinked` |
| Hub migration | `0007_apple_handoffs.sql`: `auth_handoffs.org_id` and `user_id` become nullable (a sign-in's handoff names no account until it is redeemed) and `pending bytea` holds the callback's verified result, sealed to the handoff's code hash. Additive; run `migrate` before a new `serve` |
| Outbound | `https://appleid.apple.com` only, 10 s per call, no redirects followed |
| Refresh tokens at rest | AES-256-GCM under `B4HUB_SECRET_KEY`, nonce first, the identity row's id as associated data; the plaintext is `{"clientId", "refreshToken"}`. Task 6's format (no associated data, the bare token) was never written outside tests |
| Hub protocol | `minClientProtocol` stays 1 |

### Hub sign-in additions (accounts and the wire)

| Item | Value |
| --- | --- |
| Crates | `aes-gcm` 0.11.1 (default features off; `aes`, `alloc`; already in the lock through webauthn-rs) seals Apple refresh tokens and pending handoffs under `B4HUB_SECRET_KEY`; `getrandom` 0.4.3 moved from a dev dependency of `b4hub` to a normal one, for the seal's nonce |
| Hub migrations | `0005_accounts.sql` (`users.email` nullable, `full_name`, `onboarded_at`, `deleted_at`; `orgs.personal` and `owner_user_id`; `user_identities`, `auth_ceremonies`, `auth_handoffs`, none with row-level security; existing users backfilled as onboarded, D-097) and `0007_apple_handoffs.sql` (above). Run `migrate` before a new `serve`; a database that already has `0006` and `0008` applies them in number order (`b4hub-db/tests/migrate.rs` expects `[1, 2, 3, 4, 5, 6, 7, 8]`) |
| Account routes | `GET /v1/me` gains `userId`, `user.fullName`, `onboarded`, and `identities`; new `PUT /v1/me/profile`, `POST /v1/me/passkeys/begin` and `/finish`, `DELETE /v1/me/identities/{id}`, `DELETE /v1/sessions/self`, `DELETE /v1/me`; `POST /v1/enroll` takes an optional bearer that asks for a merge. New errors `last_identity`, `merge_refused` (with `details.reason`: `same_account`, `shared_org`, `has_mac`), and `shared_org`, all `409` |
| Session answer | `userId` (`users.id`) beside `deviceId`, `token`, `org`, `user`, `needsOnboarding`; Swift decodes it as optional, so an older hub still signs in (the Mac registers a `device:<id>` placeholder until `/v1/me` names the user, D-099) |
| `POST /v1/enroll` body | Gains `deviceId?` and `candidateDeviceIds?`, as in a sign-in's `device` (D-096, amended at the live gate). **A hub older than this refuses either with `400 invalid_request`**, so a Mac or phone that has had a device at that hub cannot join it by code; the code is not used up |
| `device` in a sign-in request | `{deviceName, platform, deviceId?, candidateDeviceIds?}`; up to 32 UUIDs, `deviceId` first (D-096). **A hub older than this refuses `candidateDeviceIds` with `400 invalid_request`** (`deny_unknown_fields`), so a Mac or phone that knows more than one device at a hub cannot sign in to it; a client that knows one sends only `deviceId` |
| Maintenance | the sign-in and account write routes answer `503 maintenance` (D-103); `GET /v1/auth/config`, `GET /v1/me`, and `GET /v1/auth/apple/start` do not |
| Secrets from files | `B4HUB_SECRET_KEY_FILE`, `B4HUB_APPLE_TEAM_ID_FILE`, `B4HUB_APPLE_KEY_ID_FILE`, `B4HUB_APPLE_PRIVATE_KEY_FILE` (D-112); the chart's `secrets.useFileVars` defaults to on and the Compose production profile mounts `secret_key`; the development `Hub/compose.yaml` passes `B4HUB_SECRET_KEY` itself |
| Cross-language fixture | `Tests/Fixtures/sync/auth.json`, read by `AuthWireTests` and the hub's `auth_fixture` test (one example of each sign-in and account request and answer, captured from the hub's own test authenticator, and the `merge_refused` envelope) |
| Hub protocol | `minClientProtocol` stays 1; every field is additive |
| Test database | Unchanged. Rust suite: 379 tests on the sign-in head; Swift suite: 1113 tests in 142 suites |

**Upgrade order for sign-in: the hub first, then the Macs, then the phones.** A Mac or phone on this build against an older hub cannot sign in at all (the `/v1/auth/` routes are `404`), and one that knows several devices there is refused for `candidateDeviceIds`. An older Mac against this hub keeps syncing with its enrollment token, and an older phone keeps its mirror; neither can sign in or out the new way. The owner's local hub is rebuilt from this branch before the apps at the live gate.

### Hub push through APNs (M8f APNs)

No new crate. `reqwest` 0.12.28 gains the `http2` feature (`default-features = false`, `rustls-tls`, `http2`), which brings `h2` 0.4.20, `fnv` 1.0.7, and `tokio-util` 0.7.20 into `Hub/Cargo.lock`; `jsonwebtoken` 11.1.0 (above) signs the provider token. `cargo tree -e normal -i openssl-sys` still matches nothing.

| Item | Value |
| --- | --- |
| Outbound | `https://api.sandbox.push.apple.com` for `sandbox` tokens and `https://api.push.apple.com` for `production` tokens, port 443, HTTP/2 over TLS (ALPN `h2`), 10 s connect and 15 s request timeouts, no redirects, HTTP/2 pings every 60 s. The sandbox host was exercised live from the Compose hub (status 200 with an `apns-id`); the production host was not (iPhone gate pending) |
| Provider token | ES256 JWT (`kid` key id, `iss` team id, `iat`) from the team-scoped `.p8` APNs key `34GWB4MSB5`, reused 50 minutes (Apple refuses one older than an hour and rate-limits minting more often than every 20 minutes) |
| Request headers | `apns-topic` the token's bundle id; `apns-push-type` `alert` (priority 10, expires in 4 hours) or `background` (priority 5, expires in 15 minutes); `apns-collapse-id` the notification key on alerts (Apple allows 64 bytes; a longer key is sent without one) |
| Answers handled | 200 delivered; 410, 400 `BadDeviceToken`, and 400 `DeviceTokenNotForTopic` delete the token; 403 `ExpiredProviderToken` and `InvalidProviderToken` re-mint and retry once; 429, 5xx, and a transport failure retry once after 500 ms. These come from Apple's documentation and a fake APNs; only 200 was seen live |
| Hub environment | `B4HUB_PUSH_SENDER=apns` needs `B4HUB_APNS_KEY_ID`, `B4HUB_APNS_TEAM_ID`, and `B4HUB_APNS_PRIVATE_KEY` (each also `_FILE`); `serve` exits 2 naming the variable on a missing or bad value. Compose: `B4HUB_APNS_KEY_HOST_PATH` is mounted at `/run/secrets/apns.p8` |
| Hub migration | `0013_push_withdrawal.sql`: `notifications_sent.withdrawn_at`, a partial index of outstanding notifications per thread, and `(org_id, user_id, "threadId")` indexes on `turns` and `runtimeRequests`. Additive; run `migrate` before a new `serve` |
| Payload limit | APNs refuses a payload over 4 KB: a withdrawal naming about 90 or more keys would be refused, and the phone's backstop covers it |
| Simulator | Xcode 26.6 (17F113), iOS 26.5 (23F77) runtime, "M8f iPhone 17 Pro". Apple's push to a Simulator is delivered (the registered token is 80 bytes and accepted by the sandbox host), but SpringBoard drops `content-available` ("only supported on-device"), so a Simulator app is never woken by a real APNs push; only `xcrun simctl push` wakes it (D-128, D-148) |
| iPhone | `embedded.mobileprovision` is present in development and ad hoc builds and stripped from TestFlight and App Store builds; the app reads its `aps-environment` (`development` is sent as `sandbox`) and sends `production` when there is none (D-145). Not yet verified on a device |

## Sign-in on the Mac and iPhone

Both apps' deployment target is 26.0 (`project.yml`, `Package.swift`). The account calls are in `Sources/WorkspaceUI/SignIn/` (`PasskeyCeremony.swift`, `AppleCeremony.swift`); everything else goes through the coordinator or `MirrorAccount`. Availability below is from the macOS 26.5 SDK's headers and Swift interfaces (Xcode 26.6). "Reviewed" throughout: none of these has been run against a hub on a device yet (live gate pending).

| API (AuthenticationServices) | Available | Used for |
| --- | --- | --- |
| `ASAuthorizationPlatformPublicKeyCredentialProvider` | macOS 12.0, iOS 15.0 | passkey assertion (with `.preferImmediatelyAvailableCredentials`) and registration (attestation `none`), both apps |
| `ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest.excludedCredentials` | macOS 13.5, iOS 17.4 | the hub's `excludeCredentials`, so a device that already holds the account's passkey refuses (`.matchedExcludedCredential`) |
| `ASAuthorizationAppleIDProvider` | macOS 10.15, iOS 13.0 | the iPhone's native Sign in with Apple sheet (`.fullName`, `.email`, the hub's hashed nonce); the Mac never uses it (Developer ID apps cannot) |
| `ASWebAuthenticationSession`, through SwiftUI's `WebAuthenticationSession` | macOS 10.15, iOS 12.0 (`WebAuthenticationSession` macOS 13.3, iOS 16.4; the `.customScheme` callback macOS 14.4, iOS 17.4) | the Mac's Apple web flow, an ephemeral session returning to `b4app`, `b4app-beta`, or `b4app-local` |
| `ASCredentialUpdater` | macOS and iOS 26.0, deprecated in 26.2 | on 26.0 and 26.1: `reportUnknownPublicKeyCredential` (an orphan passkey, D-105) and `reportPublicKeyCredentialUpdate` (the rename after onboarding) |
| `ASCredentialDataManager` | macOS and iOS 26.2 | the same two calls on 26.2 and later |

| Item | Value |
| --- | --- |
| Entitlements | Mac app: `com.apple.developer.associated-domains` = `webcredentials:<site domain>`, generated by `package.sh` (the Xcode build's entitlements stay empty, so an unsigned or ad hoc Mac build cannot use passkeys). iPhone: `webcredentials:` and `applinks:` for the site domain, plus `com.apple.developer.applesignin` on prod and beta; the local build adds `?mode=developer` and runs only in the Simulator |
| Association file | served per host by `cacheplane/b4run` (`/.well-known/apple-app-site-association`), listing each flavour's Mac and iPhone app ids; fetched live from `b4.run`, `test.b4.run`, and `local.b4.run` |
| Mac account registry | the `registry` database in the coordinator's cluster (`<name>_registry` beside a non-default database), migrated by its own list in `Sources/WorkspaceStorage/SQL/registry/`: `0001_registry.sql` (`accounts`: `id`, `hub_user_id`, `hub_url`, `device_id`, `database`, `display_name`, `org_name`, `token_ref`, `last_signed_in_at`, `active`; unique `(hub_url, hub_user_id)`, one active row) and `0002_account_state.sql` (`needs_onboarding`, `hub_session_left_open`). Each account's store is `workspace_<16 hex>` with the existing migrations; the adopted one keeps the name `workspace`. Both migrators refuse a database migrated by a newer build (`incompatible_version`) |
| Mac data | per flavour: `~/Library/Application Support/b4app`, `b4app-beta`, `b4app-local`; the local flavour moves a pre-flavour `b4app` once (D-094) |
| iPhone data | the mirror folder and Keychain service per flavour (`b4app`, `b4app-beta`, `b4app-local`), plus `device.json` beside the mirror (up to 8 device ids per hub); links carry a `flavor` marker; no mirror schema change (still `user_version` 3) |
| Protocol | new commands `account.status`, `account.passkeyBegin`, `account.passkeyFinish`, `account.appleStart`, `account.appleFinish`, `account.appleLinkStart`, `account.appleLinkFinish`, `account.completeProfile`, `account.logout`, `account.dismissNotice`, `account.identities`, `account.addPasskeyBegin`, `account.addPasskeyFinish`, `account.removeIdentity`, `account.delete`; event `account.changed`; errors `signed_out` and `work_running` (coordinator only) and the hub's sign-in codes; `HubStatus.Result.notice`; `HubPair.Result.link`. An app on this build treats a coordinator that answers `account.status` with `unsupported_capability` or `method_unknown` as signed in (D-111) |
| CLI | `agent-workspace account status [--json]` and `account logout [--stop-work]`; every store command exits 4 while signed out |
### Hub keeps synced rows (D-089)

| Item | Value |
| --- | --- |
| Hub migration | `0009_soft_delete.sql` (`deleted_at timestamptz` on `connections`, `projects`, `projectFolders`, `threads`, `turns`, `displayItems`, `runtimeRequests`, `drafts`; hub-only, never sent). `0005` and `0007` stay reserved for the sign-in branch |
| Wire | Unchanged: a `delete` is still in the feed, the snapshot leaves deleted rows out, `Tests/Fixtures/sync/changes.json` is untouched, and no client changes |

## Provider runtimes

| Runtime | Installed on target Mac | Published | Verified behavior | Limits and gates |
| --- | --- | --- | --- | --- |
| Codex CLI (`@openai/codex`) | 0.166.0 at `/opt/homebrew/bin/codex` (Homebrew cask, upgraded from a broken 0.128.0 install on 2026-10-30) | 0.166.0 (2026-10-29) | Live: `codex app-server` handshake, `account/read` (ChatGPT, `promax`), `account/login/start`, `thread/start`, `thread/resume`, `thread/turns/list`, `turn/start` with streamed `item/*` notifications, a tool turn (`commandExecution`), `turn/interrupt` ending as `interrupted`, reopen with history. Schema generated with `codex app-server generate-json-schema --out <dir>` from this binary and hand-typed (D-010). | Adapter minimum: 0.166.0. App-server is labelled experimental; regenerate the schema and re-run `B4APP_LIVE_CODEX=1 swift test --filter CodexLive` after every upgrade. A real `item/commandExecution/requestApproval` round trip was exercised on 2026-10-31 through the live test only: the owner's configuration is `approval_policy = "never"` with `danger-full-access`, so the test asks `thread/start` for `approvalPolicy: on-request` and `sandbox: workspace-write` (both honored in the response) and a network command then needs approval; the app itself never passes a policy (D-012). Not exercised live: `item/fileChange/requestApproval`, `item/tool/requestUserInput`, sign-in completion from a signed-out state. |
| Claude Code | 2.1.282 at `~/.local/bin/claude` | Agent SDK 0.3.314 (bundles 2.1.314) | `claude auth status --json` parsed live; the stream-json `initialize` handshake, `--session-id`, `system/init` (with `claude_code_version`, `apiKeySource`, `capabilities`), the replayed `user` frame, a synthetic `assistant` error frame, a `result` with `subtype: success` and `is_error: true`, and `--resume` of an unknown id were all recorded live on 2026-10-31 while the Mac was signed out. Through the coordinator, `connection add --kind claude` reports `ready / auth_required` and `thread new` refuses with `auth_required`. | Adapter minimum: 2.1.200. The control protocol is undocumented (D-002); re-diff on CLI upgrades. **No inference turn has run live yet**: the Mac was signed out all day. Run `claude auth login`, then `B4APP_LIVE_CLAUDE=1 swift test --filter ClaudeLive`. Fixture coverage mirrors the Codex suite. |
| B4 (`@b4run/cli`) | Not on PATH; the trusted project is `~/repos/b4app-live-check` (0.15.8 project-installed, one `/chat#agent` route on `gpt-5-mini`; the M3 scratch project copied out of `/tmp` on 2026-10-31), registered as the managed server `research`; `~/repos/hashbrown` has 0.14.0 (workflow routes only) | 0.15.8 (2026-10-30), Node `>=24` | Live on 2026-10-31 against `b4 dev` 0.15.8 serving a `gpt-5-mini` `agent()` route with `workspace/`: `POST /threads`, streamed turns, `tool_call_args`/`tool_call`/`step`/`tool_result`, `usage`, a real `permission-request` interrupt for `ls -la` parked and answered with `once` through `request respond`, `POST /cancel` → `cancelled`, `GET /state` history, `GET /turns` reconciliation; through the adapter (`B4Live`), the coordinator, and the CLI. Fixture-verified beyond that: stream drop with reattach, server restart with stores preserved, coordinator restart while parked, bearer middleware 401, unknown route 404. | Adapter minimum: 0.15.7 (also the managed-server minimum, read from the project's `node_modules/@b4run/cli/package.json`). Only `agent` routes converse (D-023). A parked prompt survived a real `b4 dev` restart on `.b4/*.sqlite` plus a coordinator restart. Managed (M4, live on 2026-10-31 with 0.15.8): `b4 routes --json --cwd <project>` printed `{ appRoot, routes: [{ id, pathname, kind, entryFile, routeDir, segments }] }` with an absolute `entryFile`; `b4 start --host 127.0.0.1 --port N` answered `/healthz` in about one second and printed `b4 start listening on …`; `b4 dev --port N --env-file P` printed `Loaded … variable(s)` and `B4.run dev ready at …` in under two seconds and forwarded SIGTERM to its runtime child; a `restart` kept `.b4` and the thread's history. Not exercised live: a remote HTTPS endpoint with a real endpoint credential, approval grants, `detached capacity`, a project whose `b4.config.ts` `env` differs from the file passed. |

## Protocol observations captured for adapters

- Codex 0.166.0 archived resume (verified live 2026-11-04, no inference): `thread/resume` returns `-32600` with ``session <id> is archived. Run `codex unarchive <id>` to unarchive it first.`` The rollout remains in `archived_sessions`. This rejection does not establish missing history; the adapter reports `protocol_invalid` with `reason: native_session_archived`, preserving the native message and recovery command. Only responses identifying the requested thread's missing history map to `native_session_missing`; unrelated RPC failures retain their original error.
- Codex app-server (verified live on 0.166.0): newline-delimited JSON-RPC without the `jsonrpc` field; `initialize` then `initialized`; the server emits `configWarning`, `remoteControl/status/changed`, and `account/updated` right after the handshake and clients must ignore unknown methods. `account/read` distinguishes `chatgpt` from `apiKey`. A turn echoes the user message as an `item/started` + `item/completed` `userMessage` pair before the agent items; reasoning arrives as a `reasoning` item. `turn/completed.turn.status` is `completed | interrupted | failed`. Notification params for `thread/status/changed` use `{ type, activeFlags }`. Generated schema policy strings are `untrusted | on-request | never` and `read-only | workspace-write | danger-full-access`.
- Claude Code (recorded live on 2.1.282, 2026-10-31): write `control_request initialize` before any user message and wait for its `control_response`; the user's `SessionStart` hooks run first and emit `system/hook_started` / `system/hook_response`; `command_lifecycle` frames bracket each turn; `system/init` arrives per turn with `apiKeySource` (`none` for plan login) and `capabilities`; `--replay-user-messages` echoes the input as a `user` frame with `isReplay: true`; a synthetic `assistant` frame carries `error` (for example `authentication_failed`) and `is_api_error_message`; `result` may be `subtype: success` with `is_error: true` and `terminal_reason: api_error`; `--resume` of an unknown id emits one `result error_during_execution` and exits 1. Strip `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`; never pass `--bare`; `AskUserQuestion` arrives through `can_use_tool`; end a session by closing stdin after `interrupt`.
- B4 (source-verified and live-verified on 0.15.8, 2026-10-31; see `docs/research/2026-10-30-b4-runtime.md`): the live server also emits `usage` once per model call (summed into `turn.finished.usage`), `step` display updates keyed by `toolCallId` (folded into the tool card), `tool_call_args` before `tool_call`, and `tool_result.output` as a serialized `ToolMessage` (its `content` is the result); `GET /turns` nests the list under `turns.turns`; no thread-list endpoint and no run id, so the app names turns by their ordinal in `GET /threads/:id/turns` (D-019); `done` carries several outcomes; `interrupted` means cancelled or parked and `GET /pending_interrupts` tells them apart (D-020); a permission prompt is `interrupt { interruptId, type: "permission-request", kind, detail, grant? }` answered with `POST /resume { resume: [{ interruptId, status, payload?, grant? }], route }` whose response is a second SSE stream (D-021); `GET /runs/stream` reattaches and sends only frames after the attach; `runs/stream` checks route before middleware, so an unknown route is a 404 and a rejected credential a 401 on the first turn, never on the health check; no built-in endpoint auth, so the health check cannot verify a secret.

- Plan usage (settings connections, D-082; checked 2026-11-02): Codex 0.166.0 answers `account/rateLimits/read` (params may be null) with `{ rateLimits: { primary, secondary, planType, rateLimitReachedType, credits }, ordinaryUsageAllowed, … }`, each window `{ usedPercent, windowDurationMins, resetsAt (epoch s) }`, and pushes `account/rateLimits/updated { rateLimits }`; live on the owner's `promax` account it reported only `primary` with a 10080-minute window. Claude Code 2.1.282 emits `{"type":"rate_limit_event","rate_limit_info":{status, rateLimitType, utilization, resetsAt, isUsingOverage, unifiedWindows}}` during a turn (not on demand); `unifiedWindows` is marked `@internal` in its bundled schema and live carried only `seven_day` for the owner's plan login. If a later Claude Code drops `unifiedWindows`, the card falls back to the one window `rateLimitType` names.

- Deleting threads (D-119, D-120): Codex 0.166.0 `thread/delete` takes `{ threadId }` (required) and answers `{}` (`codex app-server generate-json-schema`, checked 2026-11-02); an older Codex answers method-not-found (`-32601`), recorded as unsupported. B4 0.15.8 `DELETE /threads/:id` answers `204` (fixture `fake-b4.py`; `404` for an unknown thread, `405` for a server without the route). Claude Code 2.1.282 has no delete command; b4app removes `<sessionId>.jsonl` and `<sessionId>/` from the session's project folder, as the Claude desktop app does. Mac migration `0008_thread_delete`, hub `0011_thread_delete`, mirror schema version 5; a hub without 0011 refuses a phone's `userDeletedAt` and must not run against a database that has it. Since D-138: a Codex error counts as already gone only when its message says "not found"; a B4 `404` is confirmed with `GET /threads/:id` (a `200` there means the server has no delete route, recorded as unsupported); Claude transcripts are removed from every project folder holding one; and the hub answers `cannot_clear` to an update that nulls `userDeletedAt`.

- Usage on the phone (D-118): hub migration `0010_connection_usage` adds the synced table `connectionUsage` (with the hub-only `deleted_at` of D-089, applied after `0009_soft_delete`); Mac migration `0007_connection_usage`; mirror schema version 4. A hub binary without 0010 must not run `migrate` against a database that has it (sqlx `VersionMissing`).

- Model and permission per thread (new-thread composer, D-183): Codex 0.166.0 `turn/start` takes `model`, `approvalPolicy`, and `sandboxPolicy` per turn (the "Read only", "Auto", and "Full access" presets; `writableRoots` only under `workspaceWrite`), and `model/list` (first page, `includeHidden: false`) lists the models offered; fixture-tested against `fake-codex.py`, and live-tested on codex-cli 0.166.0 on 2026-11-04 (`model/list` answered; under "Auto" a write to the second folder landed, under "Read only" it did not; `docs/verification/2026-11-04-new-thread-composer-live.md`). Claude Code: `--model=<alias>` (one argument) and `--permission-mode` at launch, `--add-dir` per extra folder (a change of the folder set restarts the process), and the `set_model` and `set_permission_mode` control requests between turns (a change to `bypassPermissions` restarts the process with `--resume` and the flag instead, since Claude Code switches into it only when launched in it); fixture-tested against `fake-claude.py`, and live-tested on Claude Code 2.1.282 on 2026-11-04 (a Haiku session read a file through `--add-dir`; `acceptEdits`, `plan`, and Sonnet were accepted by the running process; the switch to `bypassPermissions` restarted it with `--resume` and kept the conversation). Mac migration `0009_thread_runtime_choice`, hub `0017_thread_runtime_choice`, mirror schema version 6; a hub without 0017 refuses a phone's `model` and `permission` writes and must not run against a database that has it.
- Runtime commands (D-209): Claude Code 2.1.282 lists its commands in the `initialize` control response (`commands`: `name`, `description`, `argumentHint`, sometimes `aliases` and `builtin`), and `system/init` repeats the names as `slash_commands`; the list can be short when `initialize` is answered before plugins load (94 and then 75 for one folder, recorded live 2026-11-11). A `user` message whose text is `/name` runs that command: a local one (`/context`) answered with `command_lifecycle` frames, one `assistant` frame with model `<synthetic>`, a replayed `user` frame whose `content` is a string of `<command-name>` tags, and a `result` with zero cost; an unknown name is sent to the model as text. An `initialize` with no message after it writes no transcript, though `SessionStart` hooks run. Codex 0.166.0 has no command list; `review/start` takes `{ threadId, target }` (`uncommittedChanges`, `baseBranch`, `commit`, or `custom` with `instructions`) and answers `{ turn, reviewThreadId }`, and `thread/compact/start` takes `{ threadId }` and answers `{}` (`codex app-server generate-json-schema`, checked 2026-11-11; fixture-tested against `fake-codex.py`, not run live). Mac migration `0014_connection_commands`, hub `0020_connection_commands`, mirror schema version 9; a hub without 0020 records a `connections.commands` change in the feed and skips applying it (as it does any column it does not know), so its snapshot never has the list; deploy the hub before a Mac build that writes it.
- Row ownership after a device change (D-184): Mac migration `0010_owned_rows` adds `hubLink.ownedAs`; a Mac whose hub device changed re-announces its `connections`, `projects`, and `threads` as inserts with the oldest clock, which current hubs and mirrors already merge (no hub or mirror change). An older Mac build refuses a database migrated to 0010.

## Hosted hub infrastructure (Terraform)

| Item | Version |
| --- | --- |
| Terraform | 1.17.1 (`Infra/.terraform-version`, `required_version >= 1.17.1, < 2.0.0`) |
| `hashicorp/aws` provider | 6.71.0, pinned exactly in `Infra/bootstrap/versions.tf` and `.terraform.lock.hcl` (darwin_arm64, linux_amd64, linux_arm64 hashes) |
| TFLint | 0.65.0 with the bundled `terraform` ruleset 0.15.0 (`recommended`); the AWS ruleset is not enabled |

`Infra/bootstrap` (9 tests) and `Infra/modules/hub` (49 tests) were verified with `terraform validate` of the roots, `tflint`, and `terraform test` against mocked providers only; nothing has been planned or applied in a real account.

### Hosted hub tooling (pinned in the workflows and scripts)

Read from `.github/workflows/hub-chart.yml`, `ci.yml`, `Infra/`, and `Hub/chart/b4hub/examples`. Only the pins marked in the last column ran on GitHub; the rest ran locally or against mocks.

| Item | Pin | Where, and what ran |
| --- | --- | --- |
| Helm | 4.2.2 (`HELM_VERSION: v4.2.2`) | `hub-chart.yml`; lint and install ran on GitHub (run 41389901877) |
| helm-unittest | 1.2.1 (tarball sha256-checked) | `hub-chart.yml`; 47 tests passed on GitHub |
| helm-docs | 1.14.2 (sha256-checked) | `hub-chart.yml` README freshness check; ran on GitHub |
| chart-testing (`ct`) | 3.15.0, with yamllint 1.37.1 and yamale 6.0.0 | `hub-chart.yml`; ran on GitHub |
| kubeconform | 0.8.0 (sha256-checked), schemas for Kubernetes 1.31.0 | `hub-chart.yml`; ran on GitHub |
| CRD schema catalog | `datreeio/CRDs-catalog` commit `27233a506de0085e71c7f9702597806a7f95eb24` (HTTPRoute, ServiceMonitor) | `hub-chart.yml` `CRD_SCHEMAS` |
| kind | 0.31.0 in CI (the newest release with a Kubernetes 1.31 node image); 0.32.0 locally | `helm/kind-action` v1.15.1 in `hub-chart.yml` |
| kind node image | `kindest/node:v1.31.14@sha256:6f86cf509dbb42767b6e79debc3f2c32e4ee01386f0489b3b2be24b0a55aac2b`, kubectl v1.31.14 | `hub-chart.yml` install job |
| CloudNativePG operator chart | `cloudnative-pg` 0.29.1 (operator 1.30.1) | `hub-chart.yml` install job via `.github/scripts/chart-kind-test.sh`. CloudNativePG 1.30 lists Kubernetes 1.31 as "tested, but not supported": it works in the install test; move the test cluster to 1.34 or later when the chart's floor allows |
| PostgreSQL for the hosted hubs | 17 (RDS `engine_version = "17"`, major only; minor upgrades are automatic) | `Infra/modules/hub/rds.tf`; asserted by the mocked `terraform test`, not applied |
| PostgreSQL in the self-hosting examples | 17 (`postgres:17` in `Hub/deploy/compose/compose.yaml`; `ghcr.io/cloudnative-pg/postgresql:17` in the CNPG example) | Compose first boot ran locally; the CNPG cluster ran in kind on GitHub |
| bats | 1.14.0 (sha256-checked tarball) | `ci.yml` lint job; `bats Infra/scripts/tests` runs 39 tests against stubs |
| actionlint | 1.7.12 (sha256-checked) | `ci.yml` lint job |
| `curlimages/curl` | 8.22.0 (digest-pinned) | `hub-chart.yml` install job probe |
| cargo-chef | 0.1.78 | See the Hub (M8a) table |

## Known limits of the shell

- A phone start with no folder (`thread.start` with `deviceId` and no `environmentId`) needs a hub that routes it by device; an older hub answers `not_found`.
- Codex, Claude Code, attached B4 endpoints, and managed local B4 servers have conversation paths. Managed servers: one owned instance per registered project, source or development mode, loopback only, logs on disk with redaction on read, ownership by pid plus start time plus argv (D-025); a registration cannot be removed yet, a port cannot change once a route connection exists (D-027), `server stop` refuses while a turn is running unless `--force` (D-030), nothing is auto-started, and the Quit choice of spec 10.3 is M5 (Quit keeps servers running). `turn/steer`, image input, importing native threads, Claude hook callbacks, MCP messages, elicitation forms, console (API) billing sign-in, B4 client tool calls, non-agent B4 routes, custom header names for B4 endpoint auth, and persisted credential labels are not implemented.
- A B4 endpoint secret is one bearer value per connection; `credential add` returns a `secret:` reference and nothing lists stored credentials yet. Stop on a parked B4 turn declines its prompt (D-021). A B4 server that restarts mid-run loses the run; the app marks that turn `failed` and the thread is usable again.
- Claude Code 2.1.282 answers an `interrupt` control request with a `result` frame that has `is_error` set and terminal reason `aborted_streaming`; the adapter maps a requested stop to `cancelled` (verified live 2026-10-31). Claude `allow_always` is sent as a plain allow (D-018); Claude history comes from the transcript file (D-017); a Claude process exit ends its turn as failed (D-016).
- Runtime request kinds the app cannot present (`item/permissions/requestApproval`, `mcpServer/elicitation/request`, `item/tool/call`, token refresh, attestation) are declined automatically with a valid response and shown as resolved.
- A turn whose `codex app-server` process exits stays `reconciling` until the thread is reopened and Codex reports the turn's final status; the composer refuses a new turn until then.
- The packaged app installs a per-user LaunchAgent plist (`~/Library/LaunchAgents`, D-042) that runs the bundled coordinator, which starts the PostgreSQL cluster; an Xcode-run app or a failed bootstrap falls back to in-process hosting. `SMAppService` is not used while builds are ad hoc: launchd pins the managed program's hash and a rebuild leaves it unspawnable. The coordinator has no idle shutdown. `coordinator restart` and the app's Coordinator menu replace a coordinator left behind by an upgrade.
- iOS reads a SQLite mirror of what the hub holds (D-046) and, since M8b, writes titles, pins, archive, read markers, project names, and drafts through an outbox (D-049). Since D-180 it also creates, edits, and deletes projects through the relay. Since M8c it sends turns, answers approvals, stops turns, and starts threads in a project's folders through the relay (D-054 to D-059, D-075 to D-080) while its Mac is linked; a send to an offline Mac is refused, and the live gate for that is pending. Turns and runtime requests now publish their thread live. The shell still shows Mac wording on the phone ("Coordinator connected"), with a one-line "Not synced since …" banner below the navigation bar while pulls fail. A relay connection wakes the mirror's retry and its recovery pull checks without waiting for new changes; only a successful pull clears the failure. Since M8c the phone knows whether its Mac is linked (presence, with the disconnect notice after 60 s), and the thread header shows the Mac's working directory (`threads.context`).
- On macOS the Keychain is the file-based login keychain; the macOS data-protection keychain needs a provisioning profile, which needs a signing identity (D-008, D-039). On iOS the token lives in the data-protection keychain, which works with ad hoc signing (the M8a Task 9 Simulator run used Xcode's "Sign to Run Locally"); only an unsigned build fails, with -34018.
- The store is a private PostgreSQL cluster per Mac (D-041); the schema is `0001_init`, `0002_changes`, `0003_hub`, and `0004_organisation`; backups are JSON-lines archives from `db backup`, not `pg_dump`; a pre-0.2 `workspace.sqlite` is imported once and retired. Sync is M8a's push plus M8b's pull and phone writes (D-043 to D-050): a Mac that ran `hub join` pushes its change log and applies the phone's edits of titles, pins, archive, read markers, project names, and drafts (a narrow merge, never a row copy); everything else is Mac-only. Compose publishes the hub on `127.0.0.1:8080` only (plain HTTP on the loopback interface; the Simulator shares the Mac's loopback). `database.restore` fails with `invalid input syntax for type json` on an archive whose change log holds an `update` of a scalar jsonb value (found during M8a, not fixed; see `docs/verification/2026-10-31-db-restore-of-a-store-with-updates.md`).
- Packaging is ad hoc: the app runs on the Mac that built it. Developer ID signing and notarisation are untested (no certificate). Removing a registration and changing a server's port are still missing.

## Documentation recording format

`agent-workspace docs-record` writes private `b4app-docs-private-v1` recordings from fresh B4 threads. The website normalizes these into public turn capture version 1. This authoring capability is fixture-tested; it is not a general transcript export or a production-release acceptance result. Current request-resolution events do not expose the decision, so a recording cannot claim which choice was made from resolution alone.

Documentation capture qualification (2026-11-06): the recorder at `b3930da` observed two real Navlog turns through the installed beta 0.1.0 coordinator, using the workspace B4 runtime at `dd4271cbe` and `gpt-5-mini`. The beta executable digest and unavailable app-source revision are documented in the verification record; the recorder revision is not substituted for the installed app source.

## Pending environment migration safety (D-205)

The public Hub migrator preserves opaque JSONB values and their recorded byte counts while pending migration `0018_environments.sql` renames structural references. Its native preservation transaction restores original RLS/FORCE settings and commits before releasing the migration lock. The published SQL, checksum and migration number stay unchanged. Custom deferred triggers that conflict with the required RLS DDL are refused with rollback.

This prevention applies while Hub migration 18 is pending. Repairing an already upgraded database requires trustworthy original values. The local workspace Store's migration-11 prevention is recorded below under D-206; coordinated protocol-client qualification remains separate work. Source and native-test evidence, including its base and limits, is recorded in [the verification record](verification/2026-11-11-hub-environment-history-preservation.md).

## Pending Store migration 11 preservation (D-206)

The migration runner protects opaque native JSON values while pending `0011_environments.sql` renames structural references. Published SQL, including `0012_app_folders.sql`, stays unchanged. It requires the canonical public schema, authentic ledger and native types; active row filtering and conflicting shadow objects refuse atomically, while allowed inactive RLS flags are preserved. The original regression and 24 new cases passed in real PostgreSQL CI. Already upgraded history requires trusted preimages for repair. Final PR acceptance requires all seven CI jobs; coordinated protocol-client qualification and activation remain separate. See [the Store verification record](verification/2026-11-11-store-environment-history-preservation.md).

## View settings (D-208)

The thread list's arrangement, its quiet-thread mode and Show archived are one synced row, `viewSettings` (id `view`). Hub migration `0019_view_settings.sql`, coordinator migration `0013_view_settings.sql` and iOS mirror schema version 8 add it. The hub (migration 0019) and both apps must be on this version for the settings to sync. An older hub records and skips `viewSettings` changes (counted as skipped, covered by `acceptedThrough`); an older app ignores the table. Deploy the hub first: run `migrate`, then `serve`, then update the Mac and the phone. The hub goes first because an older hub records a `viewSettings` change in the feed without storing the row, so live sync between devices works but a later snapshot or resync would lack the settings. The hub keeps one `view` row per org, so in an org with several users only the first user's row is stored; every account today is a single-user org (D-208).
