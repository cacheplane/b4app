# M8a Read-Only Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A thread created and run on the Mac appears, with its transcript, in the iOS Simulator within one poll interval, through a Rust hub running from Docker Compose on the same Mac.

**Architecture:** The hub (`Hub/`, Rust, axum + sqlx) owns orgs, users, devices, and a server-ordered copy of the Mac's change log under forced row-level security. The coordinator gains a `HubSync` actor that enrolls the Mac as a device and pushes its trigger-written change log over HTTPS. The iOS app gains `WorkspaceMirror`: a SQLite copy of the synced tables fed by the hub's change feed, exposed to the unchanged SwiftUI shell through an in-process `WorkspaceTransport` that answers the read commands and emits the events `WorkspaceModel` already applies.

**Tech Stack:** Rust 1.93.1 (edition 2021, matching `~/repos/b4`), axum 0.8, tokio, sqlx 0.8 (postgres, runtime-tokio, tls-rustls, offline metadata), clap, serde, tracing, uuid v7, sha2, rand, every crate pinned with `=` versions and `Cargo.lock` committed; Docker Compose with `postgres:17`; Swift 6.2 package targets `WorkspaceSecrets`, `WorkspaceSync`, `WorkspaceMirror` (Foundation, Security, system SQLite3; link on iOS); existing `WorkspaceStorage` on libpq for the Mac.

**Spec:** `docs/superpowers/specs/2026-10-31-m8-hub-design.md` (sections "Tenancy", "Identity and devices", "Sync", "The iOS app", "Packaging and operations", "Rust stack", slice "M8a", "Calls made after the builder check").

## Global Constraints

- Only threads created in the app sync; nothing is read from `~/.codex`, `~/.claude`, or a B4 server's history.
- Row-level security is enabled and forced on every tenant-scoped table from the first migration; the application role `b4hub_app` is not the table owner and has no `BYPASSRLS`; the policy is `org_id = NULLIF(current_setting('b4hub.org_id', true), '')::uuid`; each request transaction's first statement is `SELECT set_config('b4hub.org_id', $1, true)` with the org from the verified credential. Exception recorded in Task 2: `device_tokens` and `enrollment_codes` are looked up by the hash of a presented secret before the org is known and are the only tables without RLS.
- Two database URLs: `DATABASE_ADMIN_URL` (owner role; `migrate`, `seed`) and `DATABASE_URL` (`b4hub_app`; `serve`, `enroll`). `migrate` provisions `b4hub_app` from the password in `DATABASE_URL`.
- Hub-minted ids are UUIDv7; synced rows keep their client text ids with `(org_id, id)` primary keys; mirrored tables use the Mac schema's quoted camelCase column names plus `org_id`, `user_id`, `device_id`.
- The hub stores only the SHA-256 of a device token; the token is shown once; the enrollment code is eight characters from `BCDFGHJKLMNPQRSTVWXZ23456789`, expires in ten minutes, and is single-use. Revoking a device deletes its token rows and sets `devices.revoked_at`; uploaded history is kept.
- Before upload the coordinator blanks `connections.authReference`, `connections.localServerId`, and `connections.target` for every kind, never uploads `localServers`, and replaces a `displayItems.payload` over 1 MiB (1,048,576 bytes of its JSON) with `{"truncated": true, "bytes": n}`. The wire carries no device id; the hub attributes every change to the authenticated device, so pre-join rows recorded locally as `local` need no rewrite.
- Push: batches of 500 after local writes (debounced 250 ms), every 30 s, and on wake; rows are marked `synced` only after `acceptedThrough` covers them. Pull: `GET /v1/changes?after=<hubSeq>&limit=1000&wait=25`, cursor is the returned `next`; a cursor behind the retention horizon receives `resync_required` (M8a never prunes, so the horizon is 0).
- `WorkspaceUI` never imports `WorkspaceMirror`, `WorkspaceSync`, or `WorkspaceStorage`; the UI never touches sockets, files, or secrets; secrets never appear in arguments, JSON results, logs, or UI state. The enrollment code is read from the terminal with the existing `readSecret`, never from an argument.
- Unimplemented behaviour throws `WorkspaceError(.unsupportedCapability)` naming the slice (`M8b` for phone writes, `M8c` for the relay).
- In the Simulator the hub is `http://localhost:8080`; the clients refuse any non-HTTPS URL whose host is not `localhost`, `127.0.0.1`, or `::1`.
- Conventions carried over from the b4 Rust rewrite (`~/repos/b4`): exact `=` dependency pins, `Cargo.lock` committed, builds and tests run `--locked`; `[workspace.lints.rust] unsafe_code = "forbid"`, `rust-version = "1.93.1"`, `rust-toolchain.toml` with `profile = "minimal"` and `rustfmt`, `clippy` components; inbound request bodies carry `#[serde(deny_unknown_fields)]`; the error envelope is B4's, `{"error":{"kind":"request_error"|"execution_error","message":…,"details":{"code":…}}}`, and public errors never contain SQL, panics, or another tenant's data; the container runs as uid 10001 with `STOPSIGNAL SIGTERM` and a `HEALTHCHECK` on `/readyz`; on SIGTERM the hub fails `/readyz` first, stops admitting, drains open long-polls, and exits within `B4HUB_SHUTDOWN_WAIT_MS` (default 30000); configuration errors exit 2, everything else 1; environment names are `B4HUB_PORT` (default 8080), `B4HUB_SHUTDOWN_WAIT_MS`, `B4HUB_PUBLIC_URL`, `B4HUB_LOG`, `DATABASE_URL`, `DATABASE_ADMIN_URL`, and their `_FILE` variants.
- Authentication on protected routes happens before the body is read; the principal (org, user, device) comes only from the verified token; a missing resource and an inaccessible one both answer a generic 404 with the same body.
- A long-poll registers its waiter before the final emptiness check, so a push between the check and the wait cannot be missed.
- Gates: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked`; `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `swift build`, `swift test`; both app builds.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. The hub's Rust files are formatted by `rustfmt` defaults.

## Review Focus

1. A device token presented after `DELETE /v1/devices/self` (or after the row's `revoked_at` is set) must get 401, not a stale success from a cached lookup. Pinned in Task 3.
2. The same push batch sent twice (a retry after a lost acknowledgement) must not duplicate rows or advance `hub_seq` twice for one `device_seq`. Pinned in Task 4.
3. A hub URL that is not HTTPS and not loopback (for example `http://192.168.1.10:8080`) must be refused by `hub join` and by the iOS Connect screen before any request carries the code. Pinned in Tasks 7 and 9.
4. A change whose parent row has not arrived yet (a `displayItems` insert before its `threads` insert, which the per-device order prevents but a partial fixture can produce) must be skipped by the mirror without aborting the batch. Pinned in Task 8.
5. A connection row on the phone must never show the Mac's executable path or a `secret:` reference, including after an `update` change to those columns. Pinned in Tasks 7 and 8.

---

## File structure

Hub (new):

- `Hub/Cargo.toml` (workspace), `Hub/rust-toolchain.toml` (`channel = "1.93"`), `Hub/rustfmt.toml` (empty, defaults), `Hub/.sqlx/` (offline query metadata), `Hub/API.md`.
- `Hub/crates/b4hub-core/src/{lib.rs, ids.rs, tokens.rs, change.rs}`: pure domain code, no I/O. `ids::new_uuid() -> Uuid` (v7); `tokens::{new_token, hash_token, new_code, hash_code}`; `change::{Change, ChangeOp, MAX_PAYLOAD_BYTES}`.
- `Hub/crates/b4hub-db/src/{lib.rs, migrate.rs, tenant.rs, orgs.rs, devices.rs, changes.rs}` and `Hub/crates/b4hub-db/migrations/{0001_tenancy.sql, 0002_sync.sql}`: sqlx queries, `Db` pool wrapper, `tenant_tx`.
- `Hub/crates/b4hub/src/{main.rs, cli.rs, serve.rs, auth.rs, routes/{health.rs, enroll.rs, changes.rs, devices.rs}, error.rs, notify.rs}`: the binary.
- `Hub/Dockerfile`, `Hub/compose.yaml`, `Hub/scripts/test-db.sh`.

Swift (new): `Sources/WorkspaceSecrets/Secrets.swift` (moved from `WorkspacePlatform`), `Sources/WorkspaceSync/{Wire.swift, HubAPI.swift, HTTPHubAPI.swift, FakeHubAPI.swift, HubURL.swift}`, `Sources/WorkspaceMirror/{MirrorStore.swift, MirrorSchema.swift, MirrorTransport.swift, MirrorSync.swift}`, `Sources/Coordinator/HubSync/{HubSync.swift, SyncFilter.swift}`, `Sources/WorkspaceStorage/SQL/0003_hub.sql`, `Sources/AgentWorkspaceCLI/HubCommands.swift`, `Apps/iOS/B4App/{HubConnectView.swift, MirrorHost.swift}`, `Tests/Fixtures/sync/changes.json`, test targets `WorkspaceSyncTests`, `WorkspaceMirrorTests`.

Swift (modified): `Package.swift`, `Sources/WorkspacePlatform/Secrets.swift` (becomes a re-export), `Sources/WorkspaceProtocol/{Commands.swift, Domain.swift}`, `Sources/WorkspaceStorage/{WorkspaceDatabase.swift, ChangeLog.swift}`, `Sources/Coordinator/{Coordinator.swift, Router.swift, Diagnostics.swift}`, `Sources/AgentWorkspaceCLI/Main.swift`, `Sources/WorkspaceUI/{DiagnosticsView.swift, ConnectionsView.swift}`, `Apps/iOS/B4App/{B4AppiOS.swift, Info.plist}`, `project.yml`, `.github/workflows/ci.yml`, `AGENTS.md`, `docs/{decisions.md, compatibility.md, milestones.md, verification.md}`.

---

### Task 1: Hub workspace, migrations, `migrate`, `seed`, health

**Files:**
- Create: `Hub/Cargo.toml`, `Hub/rust-toolchain.toml`, `Hub/rustfmt.toml`, `Hub/crates/b4hub-core/src/{lib.rs,ids.rs}`, `Hub/crates/b4hub-db/src/{lib.rs,migrate.rs,orgs.rs}`, `Hub/crates/b4hub-db/migrations/0001_tenancy.sql`, `Hub/crates/b4hub/src/{main.rs,cli.rs,serve.rs,error.rs,routes/health.rs}`, `Hub/scripts/test-db.sh`
- Test: `Hub/crates/b4hub-db/tests/migrate.rs`, `Hub/crates/b4hub/tests/health.rs`

**Interfaces:**
- Produces: `b4hub_core::ids::new_uuid() -> uuid::Uuid` (v7). `b4hub_db::Db { pub pool: PgPool }` with `Db::connect(url: &str) -> Result<Db>`. `b4hub_db::migrate::run(admin_url: &str, app_url: &str) -> Result<()>`: applies `sqlx::migrate!()` as the admin, then creates or alters role `b4hub_app` with the password parsed from `app_url` (`LOGIN NOSUPERUSER NOBYPASSRLS`), idempotent and tolerant of a concurrent creator, and grants `SELECT, INSERT, UPDATE, DELETE` on all tables in `public` plus usage on sequences, with `ALTER DEFAULT PRIVILEGES` for future migrations. `b4hub_db::orgs::seed(db: &Db, org_slug, org_name, username, display_name, email) -> Result<SeedOutcome { org_id, user_id, created: bool }>`, idempotent on `(slug)` and `(org_id, username)`. `b4hub_db::migrate::status(db: &Db) -> Result<MigrationStatus { applied: Vec<i64>, pending: usize }>`. `b4hub::error::ApiError { kind: ErrorKind /*RequestError|ExecutionError*/, code: &'static str, message: String, status: StatusCode }` serialising as `{"error":{"kind":"request_error","message":…,"details":{"code":…}}}` (B4's envelope, so the Swift client decodes both services with one type). `GET /healthz` → 200 `{"ok":true}`; `GET /readyz` → 200 `{"ok":true,"migrations":"current","minClientProtocol":1}` or 503 with `details.code` `not_ready` (or `shutting_down` once SIGTERM arrived).
- CLI (clap): `b4hub serve [--bind 0.0.0.0:<B4HUB_PORT>]`, `b4hub migrate`, `b4hub seed --org <slug> --org-name <name> --user <username> --name <display> --email <email>`. Environment: `B4HUB_PORT` (default 8080), `B4HUB_SHUTDOWN_WAIT_MS` (default 30000), `B4HUB_PUBLIC_URL`, `B4HUB_LOG` (tracing filter, default `info`), `DATABASE_URL`, `DATABASE_ADMIN_URL`, and `_FILE` variants of the two URLs. A missing or malformed setting prints one line naming it and exits 2. `serve` installs a SIGTERM/SIGINT handler: `/readyz` turns 503 `shutting_down`, open long-polls return their current page, then the listener closes, all within `B4HUB_SHUTDOWN_WAIT_MS`.

Schema `0001_tenancy.sql`: `orgs(id uuid pk, slug text unique, name text, created_at timestamptz)`; `users(id uuid pk, org_id uuid references orgs, username text, display_name text, email text, created_at, unique(org_id, username))`; `devices(id uuid pk, org_id, user_id references users, name text, platform text check in ('macos','ios','cli'), created_at, last_seen_at timestamptz, revoked_at timestamptz)`; `device_tokens(id uuid pk, org_id, device_id references devices, token_hash bytea unique, created_at, revoked_at)`; `enrollment_codes(code_hash bytea pk, org_id, user_id, expires_at, used_at)`. RLS enabled and forced on `orgs` (policy `id = NULLIF(...)`), `users`, `devices`; not on `device_tokens` and `enrollment_codes` (lookup by presented hash; comment in the SQL says so). `b4hub_app` role creation is not in the migration (roles are cluster-global); `migrate::run` does it.

`Hub/scripts/test-db.sh`: starts a cluster from `.build/postgres` (run `./Scripts/fetch-postgres.sh` first) under `$TMPDIR/b4hub-test`, user `postgres`, trust auth, TCP on `127.0.0.1:54329`, prints `export DATABASE_URL=postgres://postgres@127.0.0.1:54329/postgres`; `--stop` stops it. `#[sqlx::test]` creates a fresh database per test from that URL.

- [ ] **Step 1: Scaffold the workspace (`Hub/Cargo.toml` with `[workspace.package] edition = "2021", rust-version = "1.93.1"`, `[workspace.lints.rust] unsafe_code = "forbid"`, `[workspace.lints.clippy] all = "warn"`, every dependency under `[workspace.dependencies]` with an exact `=` version; `rust-toolchain.toml` with `channel = "1.93.1"`, `profile = "minimal"`, `components = ["rustfmt", "clippy"]`) and the failing migration test**

```rust
// Hub/crates/b4hub-db/tests/migrate.rs
#[sqlx::test(migrations = false)]
async fn migrate_is_idempotent_and_provisions_the_app_role(pool: PgPool) {
    let admin = pool.connect_options(); // build URLs from the test pool's options
    let app_url = with_user_and_password(&admin, "b4hub_app", "pw-test");
    b4hub_db::migrate::run(&admin_url, &app_url).await.unwrap();
    b4hub_db::migrate::run(&admin_url, &app_url).await.unwrap(); // second run: no error
    let status = b4hub_db::migrate::status(&Db { pool: pool.clone() }).await.unwrap();
    assert_eq!(status.pending, 0);
    assert!(status.applied.contains(&1));
    let app = Db::connect(&app_url).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs").fetch_one(&app.pool).await.unwrap();
    assert_eq!(n, 0); // app role can read the table (RLS: no context → zero rows)
    let bypass: bool = sqlx::query_scalar("SELECT rolbypassrls FROM pg_roles WHERE rolname = 'b4hub_app'")
        .fetch_one(&pool).await.unwrap();
    assert!(!bypass);
}

#[sqlx::test(migrations = false)]
async fn seed_creates_once_and_is_idempotent(pool: PgPool) { /* run migrate, seed twice; second returns created == false and the same ids */ }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db`
Expected: compile error, `b4hub_db::migrate` not found.

- [ ] **Step 3: Implement the workspace, `0001_tenancy.sql`, `migrate::run`, `migrate::status`, `orgs::seed`, `ids::new_uuid`**

The role statement runs in its own transaction and swallows `duplicate_object` (SQLSTATE 42710) by retrying as `ALTER ROLE ... PASSWORD`.

- [ ] **Step 4: Run to verify it passes**

Run: `cargo test -p b4hub-db`
Expected: 2 passed.

- [ ] **Step 5: Write the failing health test**

```rust
// Hub/crates/b4hub/tests/health.rs
#[sqlx::test(migrations = false)]
async fn readyz_reports_current_after_migrate(pool: PgPool) {
    // migrate as in Task 1, build the router with b4hub::serve::router(AppState::new(app_db))
    // GET /healthz → 200 {"ok":true}; GET /readyz → 200 body contains "minClientProtocol":1
}
#[sqlx::test(migrations = false)]
async fn readyz_is_503_before_migrate(pool: PgPool) { /* no migrate; GET /readyz → 503, code "not_ready" */ }
```

- [ ] **Step 6: Run to verify it fails, implement `cli.rs`, `serve.rs` (`pub fn router(state: AppState) -> axum::Router`, `AppState { db: Db, notify: Notify (Task 4) }`), `routes/health.rs`, `error.rs`, run to verify it passes**

Run: `cargo test -p b4hub` → 2 passed. `cargo run -p b4hub -- --help` lists `serve`, `migrate`, `seed`. Add a third test, `shutdown_fails_readiness_then_exits_within_the_deadline`: start `serve` on an ephemeral port in a task, send the shutdown signal through the server's handle, assert `/readyz` is 503 `shutting_down` before the listener closes and that the task finishes within 2 s with `B4HUB_SHUTDOWN_WAIT_MS=2000`.

- [ ] **Step 7: Format, lint, commit**

```bash
cd Hub && cargo fmt && cargo clippy --all-targets -- -D warnings
git add Hub && git commit -m "feat(hub): Rust workspace with tenancy migration, migrate, seed, and health"
```

---

### Task 2: Tenant transactions and the RLS proof

**Files:**
- Create: `Hub/crates/b4hub-db/src/tenant.rs`
- Test: `Hub/crates/b4hub-db/tests/rls.rs`

**Interfaces:**
- Produces: `Db::tenant_tx(&self, org_id: Uuid) -> Result<Transaction<'_, Postgres>>` whose first statement is `SELECT set_config('b4hub.org_id', $1::text, true)`. `Db::untenanted_tx(&self)` for the two credential tables only. A test helper crate-internal to `b4hub-db` tests: `tests/common/mod.rs` with `async fn migrated(pool: &PgPool) -> (Db /*admin*/, Db /*app*/)` reused by Tasks 3 and 4.

- [ ] **Step 1: Write the failing tests**

```rust
#[sqlx::test(migrations = false)]
async fn app_role_sees_only_its_org(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let a = orgs::seed(&admin, "cacheplane", "cacheplane", "blove", "Brian Love", "b@example.test").await.unwrap();
    let b = orgs::seed(&admin, "other", "Other", "eve", "Eve", "e@example.test").await.unwrap();
    let mut tx = app.tenant_tx(a.org_id).await.unwrap();
    let names: Vec<String> = sqlx::query_scalar("SELECT username FROM users").fetch_all(&mut *tx).await.unwrap();
    assert_eq!(names, vec!["blove"]);
    // hand-written cross-tenant query under org A's context still yields nothing of B
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM users WHERE org_id = $1").bind(b.org_id).fetch_one(&mut *tx).await.unwrap();
    assert_eq!(n, 0);
}
#[sqlx::test(migrations = false)]
async fn no_context_sees_nothing_and_cannot_insert(pool: PgPool) {
    /* app pool, plain connection: SELECT count(*) FROM users == 0; INSERT INTO users (... org B ...) fails with 42501 */
}
#[sqlx::test(migrations = false)]
async fn owner_role_with_row_security_off_errors_instead_of_filtering(pool: PgPool) {
    /* admin: SET row_security = off; as a non-bypass role the SELECT errors; documents the export rule */
}
```

- [ ] **Step 2: Run to verify failure (no `tenant_tx`), implement `tenant.rs`, run to verify 3 passed, commit**

```bash
git commit -am "feat(hub): tenant transactions and the row-level security proof"
```

---

### Task 3: Device enrollment and bearer authentication

**Files:**
- Create: `Hub/crates/b4hub-core/src/tokens.rs`, `Hub/crates/b4hub-db/src/devices.rs`, `Hub/crates/b4hub/src/auth.rs`, `Hub/crates/b4hub/src/routes/{enroll.rs,devices.rs}`
- Modify: `Hub/crates/b4hub/src/cli.rs` (add `enroll --user <username> [--org <slug>]`)
- Test: `Hub/crates/b4hub-core/src/tokens.rs` (unit), `Hub/crates/b4hub/tests/enroll.rs`

**Interfaces:**
- Produces: `tokens::new_token() -> String` (32 random bytes, base64url, no padding), `tokens::hash_token(&str) -> [u8; 32]`, `tokens::new_code() -> String` (8 chars from `BCDFGHJKLMNPQRSTVWXZ23456789`), `tokens::hash_code(&str) -> [u8; 32]` (uppercased first). `devices::create_enrollment_code(db, org_id, user_id, ttl: Duration) -> Result<String>`; `devices::redeem(db, code, name, platform) -> Result<Enrolled { org_id, user_id, device_id, token, org_slug, org_name, username, display_name }>` or `DbError::InvalidCode`; `devices::authenticate(db, token) -> Result<Option<AuthedDevice { org_id, user_id, device_id }>>` (None when missing or `revoked_at` set on the token or the device); `devices::revoke_self(db, device_id)`; `devices::touch_last_seen(db, device_id)` at most once a minute (in-memory `last_touched` map). `auth::AuthedDevice` is an axum extractor (`FromRequestParts`) reading `Authorization: Bearer`; because it is a parts extractor it runs before any `Json` body extractor, so an unauthenticated request is refused without reading its body (asserted by a test that sends an invalid token with an invalid JSON body and gets 401, not 400). Request bodies (`EnrollRequest`, `PushRequest`) carry `#[serde(deny_unknown_fields)]`; an unknown field is 400 `invalid_request`. Routes: `POST /v1/enroll {code, deviceName, platform}` → 200 `{deviceId, token, org:{slug,name}, user:{username,displayName}}`, 401 `invalid_code`; `GET /v1/me` → `{deviceId, deviceName, platform, org, user, createdAt}`; `DELETE /v1/devices/self` → 204. CLI `b4hub enroll --user blove` prints `Enrollment code: XXXXXXXX (expires in 10 minutes)` on stdout; `--org` required when more than one org exists.

- [ ] **Step 1: Write the failing tests**

```rust
#[test] fn codes_use_the_unambiguous_alphabet_and_eight_chars() { /* 100 codes: len 8, chars ⊂ alphabet */ }
#[test] fn code_hash_ignores_case() { assert_eq!(hash_code("bcdf2345"), hash_code("BCDF2345")); }

#[sqlx::test(migrations = false)]
async fn enroll_then_me_then_revoke(pool: PgPool) {
    // seed; code = create_enrollment_code(..., 10 min); POST /v1/enroll → 200 with token; GET /v1/me with it → 200 user blove
    // POST /v1/enroll again with the same code → 401 invalid_code
    // POST /v1/enroll with an extra field {"code":…,"deviceName":…,"platform":…,"extra":1} → 400 invalid_request
    // GET /v1/me with a bad token and body "not json" → 401 (auth before body)
    // DELETE /v1/devices/self → 204; GET /v1/me → 401 unauthorized   (Review Focus 1)
    // the stored device_tokens.token_hash equals hash_token(token) and the token itself appears nowhere in the table
}
#[sqlx::test(migrations = false)]
async fn expired_code_is_rejected(pool: PgPool) { /* ttl = 0 s → 401 invalid_code */ }
```

- [ ] **Step 2: Run to verify failure, implement, run to verify 4 passed, commit**

```bash
git commit -am "feat(hub): one-time enrollment codes, device tokens, bearer auth, enroll command"
```

---

### Task 4: Change ingest, materialisation, and the long-poll feed

**Files:**
- Create: `Hub/crates/b4hub-core/src/change.rs`, `Hub/crates/b4hub-db/src/changes.rs`, `Hub/crates/b4hub-db/migrations/0002_sync.sql`, `Hub/crates/b4hub/src/routes/changes.rs`, `Hub/crates/b4hub/src/notify.rs`, `Tests/Fixtures/sync/changes.json`
- Test: `Hub/crates/b4hub-db/tests/changes.rs`, `Hub/crates/b4hub/tests/changes.rs`

**Interfaces:**
- Produces: `change::Change { device_seq: i64, wall: i64, table: String, row_id: String, op: ChangeOp, column: Option<String>, value: Option<serde_json::Value> }` with `#[serde(rename_all = "camelCase")]` (`deviceSeq`, `rowId`); `ChangeOp::{Insert, Update, Delete}` serialised lowercase; `change::MAX_PAYLOAD_BYTES: usize = 1_048_576`; `change::SYNCED_TABLES: [&str; 6] = ["connections","threads","turns","displayItems","runtimeRequests","drafts"]` with key columns (`drafts` keyed by `threadId`). `changes::push(db, auth: &AuthedDevice, batch: &[Change]) -> Result<i64 /*acceptedThrough*/>`: one tenant transaction; for each change `INSERT INTO changes ... ON CONFLICT (org_id, device_id, device_seq) DO NOTHING`, and only when inserted, materialise with the Mac's replay semantics (insert → upsert of the provided columns, update → set one column, delete → delete; unknown table or missing parent → skipped, counted in a `skipped` log line); `acceptedThrough` is the batch's max `device_seq` even for duplicates. `changes::pull(db, auth, after: i64, limit: usize) -> Result<Page { changes: Vec<StoredChange>, next: i64, more: bool }>` where `StoredChange` adds `hubSeq: i64, deviceId: Uuid` and is scoped to `user_id = auth.user_id`. `notify::Notifier` (per-org `tokio::sync::Notify`, single-replica; `wake(org_id)` after a push, `wait(org_id, Duration)`). The handler order is: take `notified = notifier.notified(org)` first, then query; if the page is empty, await that same `notified` with the timeout, then query once more. Taking the future before the query is what closes the lost-wakeup gap. Routes: `POST /v1/changes {changes:[Change]}` → 200 `{acceptedThrough}`; 413 `payload_too_large` when any value's serialised JSON exceeds `MAX_PAYLOAD_BYTES` (the client truncates first; the hub refuses rather than truncating); `GET /v1/changes?after=0&limit=1000&wait=25` → 200 `{changes, next, more}`; long-polls up to `wait` seconds (cap 25) when empty; `after` below the org's horizon (0 in M8a) → 410 `resync_required`.
- Schema `0002_sync.sql`: `changes(org_id uuid, hub_seq bigserial, device_id uuid, device_seq bigint, user_id uuid, wall bigint, "table" text, row_id text, op text check, "column" text, value jsonb, primary key (org_id, hub_seq), unique (org_id, device_id, device_seq))`; mirrored tables `connections`, `threads`, `turns`, `"displayItems"`, `"runtimeRequests"`, `drafts` with the Mac's quoted camelCase columns from `Sources/WorkspaceStorage/SQL/0001_init.sql` (all nullable except the key, since an insert carries whatever the row had) plus `org_id uuid not null, user_id uuid not null, device_id uuid not null`, primary key `(org_id, id)` (`(org_id, "threadId")` for drafts), index `(org_id, user_id)`; RLS enabled and forced on all seven.
- Fixture `Tests/Fixtures/sync/changes.json`: an array of 12 wire `Change` objects for one device: a `connections` insert (with `authReference: "secret:abc"`, `target: "/usr/local/bin/codex"`, `localServerId: null`), a `threads` insert, two `turns` inserts, four `displayItems` inserts (one with a 2 MiB `payload.text`), a `runtimeRequests` insert, a `threads` update of `title`, a `drafts` insert, a `drafts` delete. Both the Rust and Swift suites decode it; the Rust push test uses it after applying `SyncFilter` rules by hand (blank the three columns, truncate the big payload) since the hub rejects the raw file.

- [ ] **Step 1: Write the failing tests**

```rust
#[test] fn change_round_trips_camel_case() { /* serde: "deviceSeq", "rowId", "op":"insert" */ }
#[test] fn fixture_decodes() { let v: Vec<Change> = serde_json::from_str(include_str!("../../../../Tests/Fixtures/sync/changes.json")).unwrap(); assert_eq!(v.len(), 12); }

#[sqlx::test(migrations = false)]
async fn push_materialises_and_is_idempotent(pool: PgPool) {
    // enroll device D for blove; push filtered fixture → acceptedThrough == 12; threads row title == updated title; drafts row absent
    // push the same batch again → acceptedThrough == 12; count(*) FROM changes unchanged   (Review Focus 2)
}
#[sqlx::test(migrations = false)]
async fn pull_pages_and_long_polls(pool: PgPool) {
    // after=0 limit=5 → 5 changes, more == true, next == 5; after=5 → 7, more == false
    // after=12 wait=1 with a concurrent push of one change after 200 ms → returns within 1 s with that change
    // other user in the same org pulls → 0 changes
}
#[sqlx::test(migrations = false)]
async fn oversize_payload_is_refused(pool: PgPool) { /* raw fixture → 413 payload_too_large, nothing stored */ }
#[sqlx::test(migrations = false)]
async fn pull_over_real_tcp_does_not_miss_a_push_in_the_gap(pool: PgPool) {
    // bind the router on 127.0.0.1:0 with axum::serve; from a reqwest client: start GET /v1/changes?after=N&wait=5 and, 50 ms later, POST one change
    // the GET returns that change well before the 5 s wait; repeat 20 times with the push issued at 0 ms (before the GET's query runs) and assert every round returns within 1 s
}
```

- [ ] **Step 2: Run to verify failure, implement, run to verify 6 passed, regenerate `Hub/.sqlx` with `cargo sqlx prepare --workspace`, commit**

```bash
git commit -am "feat(hub): change ingest with idempotent device sequences, materialised tables, long-poll feed"
```

---

### Task 5: Image, Compose, API document, CI

**Files:**
- Create: `Hub/Dockerfile`, `Hub/compose.yaml`, `Hub/API.md`, `Hub/.dockerignore`
- Modify: `.github/workflows/ci.yml` (new job `hub` on `ubuntu-latest` with a `postgres:17` service: `rustup toolchain install 1.93.1 --profile minimal --component rustfmt --component clippy`, `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` with `SQLX_OFFLINE=true` for the build and `DATABASE_URL` for the tests)

**Interfaces:**
- `Hub/Dockerfile`: multi-stage; builder `rust:1.93.1-slim-bookworm` pinned by digest, `cargo build --release --locked --offline` after `cargo fetch --locked`; runtime `debian:bookworm-slim` pinned by digest with `curl` for the health check, a `b4hub` user and group with uid and gid 10001, `/usr/local/bin/b4hub` mode 0555, `USER 10001:10001`, `STOPSIGNAL SIGTERM`, `HEALTHCHECK --interval=5s --timeout=4s --start-period=5s --retries=3 CMD curl --fail --silent http://127.0.0.1:8080/readyz`, `ENTRYPOINT ["/usr/local/bin/b4hub"]`, `CMD ["serve"]`; `linux/arm64` and `linux/amd64` buildable. `Hub/compose.yaml`: services `db` (`postgres:17`, `POSTGRES_PASSWORD` from `.env`, volume `b4hub-db`), `migrate` (same image, command `migrate`, both URLs, `depends_on: db: condition: service_healthy`, `restart: "no"`), `hub` (command `serve`, only `DATABASE_URL`, port `8080:8080`, `depends_on: migrate: condition: service_completed_successfully`). `Hub/API.md` documents every route, error code, and the wire `Change` with the fixture as the example.

- [ ] **Step 1: Build the image and bring the stack up**

Run: `cd Hub && docker compose build && docker compose up -d && curl -fsS localhost:8080/readyz`
Expected: `{"ok":true,"migrations":"current","minClientProtocol":1}`.

- [ ] **Step 2: Seed and enroll through the containers**

Run: `docker compose run --rm hub seed --org cacheplane --org-name cacheplane --user blove --name "Brian Love" --email brian@brianflove.com` then `docker compose run --rm hub enroll --user blove`
Expected: `Enrollment code: ........ (expires in 10 minutes)`.

- [ ] **Step 3: Add the CI job, push the branch, confirm the `hub` job is green, commit**

```bash
git add Hub .github/workflows/ci.yml && git commit -m "build(hub): container image, Compose stack, API document, CI job"
```

---

### Task 6: `WorkspaceSecrets` split and the `WorkspaceSync` wire module

**Files:**
- Create: `Sources/WorkspaceSecrets/Secrets.swift`, `Sources/WorkspaceSync/{Wire.swift,HubAPI.swift,HTTPHubAPI.swift,FakeHubAPI.swift,HubURL.swift}`, `Tests/WorkspaceSyncTests/{WireTests.swift,HubURLTests.swift,HTTPHubAPITests.swift}`
- Modify: `Package.swift` (targets `WorkspaceSecrets` [Foundation, Security], `WorkspaceSync` [depends on `WorkspaceProtocol`], test target `WorkspaceSyncTests`; `WorkspacePlatform` depends on `WorkspaceSecrets`; `WorkspaceUI` unchanged), `Sources/WorkspacePlatform/Secrets.swift` (becomes `@_exported import WorkspaceSecrets` so no other file changes)

**Interfaces:**
- `WorkspaceSecrets`: `SecretRef`, `SecretStore`, `KeychainSecretStore`, `MemorySecretStore`, `KeychainError` move verbatim; `KeychainSecretStore` adds `#if os(iOS)` to its base query: `kSecUseDataProtectionKeychain: true` and, on `put`, `kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- `WorkspaceSync.Wire`: `public struct SyncChange: Codable, Sendable, Equatable { deviceSeq: Int, wall: Int, table: String, rowId: String, op: String, column: String?, value: JSONValue? }`; `public struct StoredChange: Codable, Sendable, Equatable { hubSeq: Int, deviceId: String, deviceSeq: Int, wall: Int, table: String, rowId: String, op: String, column: String?, value: JSONValue? }`; `EnrollRequest { code, deviceName, platform }`, `EnrollResponse { deviceId, token, org: OrgInfo{slug,name}, user: UserInfo{username,displayName} }`, `MeResponse { deviceId, deviceName, platform, org, user, createdAt }`, `PushResponse { acceptedThrough: Int }`, `PullResponse { changes: [StoredChange], next: Int, more: Bool }`, `HubErrorBody { error: { code: String, message: String } }`.
- `HubAPI`: `public protocol HubAPI: Sendable { func enroll(_ request: EnrollRequest) async throws -> EnrollResponse; func me() async throws -> MeResponse; func push(_ changes: [SyncChange]) async throws -> PushResponse; func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse; func revokeSelf() async throws }`. `public struct HubError: Error { kind: String, code: String, message: String, status: Int }` decoded from B4's envelope (`error.kind`, `error.message`, `error.details.code`), with `code` values passed through from the hub (`invalid_request`, `invalid_code`, `unauthorized`, `resync_required`, `payload_too_large`, `shutting_down`) and `transport` for URLSession failures.
- `HTTPHubAPI`: `public final class HTTPHubAPI: HubAPI { public init(baseURL: URL, token: @Sendable () async throws -> String?, session: URLSession = .shared) }`; the token closure is called per request, so the secret lives only in the caller's `SecretStore`. Request timeout `wait + 5` seconds on pull.
- `FakeHubAPI`: `public actor FakeHubAPI: HubAPI` with `enrollmentCodes: [String: EnrollResponse]`, `stored: [StoredChange]`, `pushed: [[SyncChange]]`, `failNext: HubError?`, and `append(_ changes: [StoredChange])` for tests feeding a reader.
- `HubURL`: `public enum HubURL { public static func validate(_ string: String) throws -> URL }` accepting `https://` anywhere and `http://` only for hosts `localhost`, `127.0.0.1`, `::1`; otherwise throws `WorkspaceError(.invalidArgument, "The hub URL must use https (http is allowed only for localhost).")`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func wireDecodesTheSharedFixture() throws {
  let url = Bundle.module.url(forResource: "changes", withExtension: "json")!  // copied resource from Tests/Fixtures/sync
  let changes = try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
  #expect(changes.count == 12)
  #expect(changes[0].table == "connections" && changes[0].op == "insert")
}
@Test func hubURLRejectsPlainHTTPOffLoopback() {
  #expect(throws: WorkspaceError.self) { try HubURL.validate("http://192.168.1.10:8080") }
  #expect(try HubURL.validate("http://localhost:8080").host == "localhost")
  #expect(try HubURL.validate("https://hub.example.test").scheme == "https")
}
@Test func httpAPIMapsHubErrorsAndSendsBearer() async throws {
  // URLProtocol stub: assert header "Authorization: Bearer t0k", respond 401 {"error":{"kind":"request_error","message":"...","details":{"code":"unauthorized"}}}
  // expect HubError(code: "unauthorized", status: 401)
}
```

- [ ] **Step 2: Run to verify failure (`swift test --filter WorkspaceSyncTests`), implement the move and the module, run to verify pass, run the whole suite (`swift test`) to prove the re-export kept every import working, lint, commit**

```bash
git commit -am "feat(sync): WorkspaceSecrets shared by both platforms; WorkspaceSync wire types, HTTP client, fake hub"
```

---

### Task 7: Coordinator `HubSync`, `hub.*` commands, CLI

**Files:**
- Create: `Sources/WorkspaceStorage/SQL/0003_hub.sql`, `Sources/Coordinator/HubSync/{HubSync.swift,SyncFilter.swift}`, `Sources/AgentWorkspaceCLI/HubCommands.swift`, `Tests/CoordinatorTests/HubSyncTests.swift`, `Tests/WorkspaceStorageTests/HubLinkTests.swift`
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (device id on every write session; `hubLink` accessors; `markSynced(through:)`), `Sources/WorkspaceProtocol/Commands.swift` (methods `hub.join`, `hub.status`, `hub.leave`; `HubJoin`, `HubStatus`, `HubLeave`), `Sources/Coordinator/{Coordinator.swift,Router.swift}` (construct and start `HubSync`; route the three methods), `Sources/AgentWorkspaceCLI/Main.swift` (register `HubCommand`), `Package.swift` (`Coordinator` depends on `WorkspaceSync`)

**Interfaces:**
- `0003_hub.sql` (scope: local only): `hubLink("id" integer primary key check ("id" = 1), "url" text not null, "deviceId" text not null, "deviceName" text not null, "tokenRef" text not null, "orgSlug" text not null, "username" text not null, "cursor" bigint not null default 0, "lastPushAt" text, "lastError" text, "joinedAt" text not null)`; `devices` gains nothing (the self row is inserted on join).
- `WorkspaceDatabase`: `public var deviceId: String` (default `"local"`; `write` and `read` run `SELECT set_config('b4app.device_id', $1, true)` first when it is not `local`); `public struct HubLink: Codable, Sendable, Equatable { url, deviceId, deviceName, tokenRef, orgSlug, username, cursor, lastPushAt, lastError, joinedAt }`; `hubLink() throws -> HubLink?`, `saveHubLink(_:) throws`, `clearHubLink() throws` (also resets every `changes.synced` to false); `markSynced(through seq: Int) throws`; `unsyncedChanges(limit: Int) throws -> [ChangeRecord]` (`WHERE NOT synced ORDER BY seq`).
- `SyncFilter` (pure, in Coordinator): `static func outbound(_ record: ChangeRecord) -> SyncChange?` applying the Global Constraints: drop tables outside `WorkspaceDatabase.syncedTables`; on `connections` inserts set `authReference` and `localServerId` to null and `target` to `""`; drop `connections` updates whose column is one of those three; on `displayItems` inserts whose `payload` JSON exceeds 1,048,576 bytes replace `payload` with `{"truncated": true, "bytes": n}`; `deviceSeq = record.seq`. The hub learns the device from the bearer token, so no device id is on the wire.
- `HubSync`: `public actor HubSync { init(database: WorkspaceDatabase, secretStore: any SecretStore, eventLog: EventLog, makeAPI: @Sendable (URL, @escaping @Sendable () async throws -> String?) -> any HubAPI = { HTTPHubAPI(baseURL: $0, token: $1) }); func start() async; func join(url: String, code: String, deviceName: String) async throws -> HubStatus.Result; func status() async throws -> HubStatus.Result; func leave() async throws; func pushNow() async throws -> Int /*rows accepted*/; func stop() }`. `start()` loads the link, sets `database.deviceId`, subscribes to `eventLog.subscribe()` as the write nudge (debounced 250 ms), runs a 30 s timer, and pushes on `SleepWatcher` wake. `join` validates with `HubURL.validate`, enrolls with platform `macos`, stores the token under `SecretRef.make()` in `secretStore`, writes `hubLink` and the `devices` self row, sets `database.deviceId`, then pushes. `leave` calls `revokeSelf()` (errors logged, not fatal), removes the secret, clears the link, resets `deviceId` to `local`.
- Commands: `HubJoin.Params { url: String, code: String, deviceName: String? }` (the code travels inside the local socket command, which is how `credential.add` already carries values; it is never logged); `HubStatus.Result { joined: Bool, url: String?, deviceId: String?, deviceName: String?, orgSlug: String?, username: String?, unsyncedChanges: Int, lastPushAt: String?, lastError: String? }`; `HubLeave` → `EmptyParams`/`HubStatus.Result`. All three are mutations except `hub.status`.
- CLI `agent-workspace hub join <url> [--name <device>]` (prompts `Enrollment code:` through `readSecret`), `hub status`, `hub leave`; `--json` as elsewhere.

- [ ] **Step 1: Write the failing storage tests**

```swift
@Test func hubLinkRoundTripsAndClearResetsSyncedFlags() throws { /* temporary(); save → read equal; insert a thread (change recorded); markSynced(through:); clearHubLink → unsyncedChangeCount == all */ }
@Test func deviceIdIsRecordedOnChanges() throws { /* db.deviceId = "dev-1"; insert a connection; changes(after: 0).last?.deviceId == "dev-1" */ }
```

- [ ] **Step 2: Run to verify failure, implement `0003_hub.sql` and the `WorkspaceDatabase` additions, run to verify pass, commit**

- [ ] **Step 3: Write the failing filter and sync tests**

```swift
@Test func filterBlanksConnectionSecretsAndPathsAndTruncatesBigItems() throws {
  // from the fixture-shaped ChangeRecords: connections insert → value.authReference == nil, localServerId == nil, target == ""
  // connections update of "target" → nil; of "label" → kept
  // displayItems insert with 2 MiB text → value.payload == {"truncated": true, "bytes": n}; "localServers" → nil   (Review Focus 5)
}
@Test func joinPushesTheBacklogAndMarksItSynced() async throws {
  // startIsolated coordinator with a FakeHubAPI injected through CoordinatorOptions.hubAPIFactory
  // add a fake connection and create a thread (backlog > 0); HubJoin(url: "http://localhost:8080", code: "BCDF2345")
  // expect fake.pushed.flatMap { $0 }.count == unsynced count before; database.unsyncedChangeCount() == 0; hubLink().deviceId == fake's deviceId
  // fake.failNext = HubError(code: "unauthorized") then insert a thread → status().lastError contains "unauthorized" and unsyncedChanges > 0
}
@Test func joinRefusesANonLoopbackHTTPURL() async throws { /* HubJoin(url: "http://192.168.1.10:8080") → WorkspaceError .invalidArgument; fake.enrollCalls == 0 */ }   // Review Focus 3
@Test func leaveRevokesAndForgets() async throws { /* after join: HubLeave → fake.revoked == true; status().joined == false; secretStore has no value for the old ref */ }
```

- [ ] **Step 4: Run to verify failure; add `hubAPIFactory: HubSync.APIFactory?` to `CoordinatorOptions` (passed to `HubSync` as `makeAPI`; `public typealias APIFactory = @Sendable (URL, @escaping @Sendable () async throws -> String?) -> any HubAPI`); implement `SyncFilter`, `HubSync`, the commands, router cases, and `HubCommands.swift`; run `swift test --filter "HubSync|HubLink"` to verify pass; run `swift test` whole; lint; commit**

```bash
git commit -am "feat(coordinator): HubSync pushes the change log to the hub; hub join|status|leave"
```

---

### Task 8: `WorkspaceMirror` store and transport

**Files:**
- Create: `Sources/WorkspaceMirror/{MirrorSchema.swift,MirrorStore.swift,MirrorTransport.swift,MirrorSync.swift}`, `Tests/WorkspaceMirrorTests/{MirrorStoreTests.swift,MirrorTransportTests.swift}`, `Tests/WorkspaceUITests/MirrorModelTests.swift`
- Modify: `Package.swift` (`WorkspaceMirror` depends on `WorkspaceProtocol`, `WorkspaceClient`, `WorkspaceSync`, `WorkspaceSecrets`, links `sqlite3`; test target `WorkspaceMirrorTests` with the fixture as a resource; `WorkspaceUITests` depends on `WorkspaceMirror`), `Sources/WorkspaceProtocol/Domain.swift` (`DiagnosticsReport.sync: SyncDiagnostic?` with `SyncDiagnostic { hubURL: String, deviceName: String, cursor: Int, lastSyncAt: String?, lastError: String? }`, optional so existing JSON decodes), `Sources/WorkspaceUI/DiagnosticsView.swift` (a "Sync" section when `report.sync != nil`), `Sources/WorkspaceUI/ConnectionsView.swift:107` (omit the row when `target.isEmpty`)

**Interfaces:**
- `MirrorStore`: `public final class MirrorStore: @unchecked Sendable { public init(path: String) throws; public static func inMemory() throws -> MirrorStore; public func apply(_ changes: [StoredChange]) throws -> AppliedBatch { touchedThreadIds: Set<String>, touchedItems: [DisplayItem], touchedConnectionIds: Set<String>, skipped: Int }; public func connections() throws -> [Connection]; public func threads(includeArchived: Bool, connectionId: String?, query: String?) throws -> [ConversationThread]; public func thread(id:) throws -> ConversationThread?; public func turns(threadId:) throws -> [Turn]; public func items(threadId:) throws -> [DisplayItem]; public func requests(threadId:) throws -> [RuntimeRequest]; public func draft(threadId:) throws -> Draft?; public var cursor: Int { get }; public func setCursor(_:) throws; public func link() throws -> MirrorLink?; public func saveLink(_:) throws; public func clearLink() throws }` with `MirrorLink { hubURL: String, deviceId: String, deviceName: String, tokenRef: String, orgSlug: String, username: String, lastSyncAt: String?, lastError: String? }`. Schema: the six tables as `STRICT` tables with the Mac's column names (`TEXT`/`INTEGER`, JSON as `TEXT`), `syncState(id INTEGER PRIMARY KEY CHECK (id = 1), cursor INTEGER, link TEXT) STRICT`; all statements serialised on one internal queue; file opened with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`, `PRAGMA journal_mode = WAL`, `PRAGMA synchronous = FULL`, `PRAGMA foreign_keys = ON`, `PRAGMA busy_timeout = 5000`. Replay semantics equal `WorkspaceDatabase.replay`: insert is upsert of the provided columns, update sets one column, delete deletes, a row whose parent is missing is skipped and counted. Rows decode through the same `Codable` types as the protocol (JSON built from the row like `Rows.decode`).
- `MirrorSync`: `public actor MirrorSync { init(store: MirrorStore, api: any HubAPI, onBatch: @Sendable (AppliedBatch) async -> Void); func run() async /* loop: pull(after: cursor, limit: 1000, wait: 25), apply, setCursor(next), onBatch; on resync_required: clear tables, cursor 0; on other errors: record lastError, back off 2 s doubling to 60 s */; func stop() }`.
- `MirrorTransport`: `public final class MirrorTransport: WorkspaceTransport { public init(store: MirrorStore, version: String) }`. On creation it enqueues a `HelloEnvelope` (`epoch` a fresh UUID, `sequence` 0, `coordinator: CoordinatorIdentity(version:, pid: current)`). It parses `CommandEnvelope` lines and answers: `system.ping`, `events.snapshot` (`activeTurns` always empty), `events.replay` (`epoch` match → empty list; else `desync`), `connection.list`, `thread.list`, `thread.read` (remembers `lastReadThreadId`), `draft.read`, `server.list` (`[]`), `workspace.activeWork` (empty), `diagnostics.read` (coordinator `version` = app version, `socketPath` `"mirror"`, `databasePath` the SQLite path, `runtimes` `[]`, `sync` from `link()` and `cursor`); every other method → `WorkspaceError(.unsupportedCapability, "Writing from this device arrives in M8b; sending turns through the hub in M8c.")`. `public func publish(_ batch: AppliedBatch)` emits `thread.updated` (with the row) per touched thread, `connection.changed` per touched connection (status and authStatus from the row), and `message.completed` with `displayItem` for each touched item whose `threadId == lastReadThreadId` (the model's `applyToDetail` upserts on that kind regardless of item type).

- [ ] **Step 1: Write the failing store tests**

```swift
@Test func applyingTheFixtureMaterialisesAndSkipsOrphans() throws {
  let store = try MirrorStore.inMemory()
  let changes = fixtureAsStored()  // hubSeq = index + 1
  let batch = try store.apply(changes)
  #expect(try store.threads(includeArchived: true, connectionId: nil, query: nil).first?.title == "Renamed")
  #expect(try store.items(threadId: "thread-1").count == 4)
  #expect(try store.draft(threadId: "thread-1") == nil)
  #expect(batch.touchedThreadIds == ["thread-1"])
  let orphan = StoredChange(hubSeq: 99, deviceId: "d", deviceSeq: 99, wall: 0, table: "displayItems", rowId: "x", op: "insert", column: nil, value: itemJSON(threadId: "missing"))
  #expect(try store.apply([orphan]).skipped == 1)   // Review Focus 4
}
@Test func applyIsIdempotentAndUpdatesOneColumn() throws { /* apply twice → same counts; a title update changes only title */ }
@Test func connectionRowsNeverCarrySecretsOrPaths() throws { /* apply an unfiltered connections insert and an update to authReference; connections().first: authReference == nil, target == "" (the store blanks defensively too) */ }  // Review Focus 5
```

- [ ] **Step 2: Run to verify failure, implement `MirrorSchema` and `MirrorStore`, run to verify pass, commit**

- [ ] **Step 3: Write the failing transport and model tests**

```swift
@Test func transportAnswersReadsAndRefusesWrites() async throws {
  let store = try MirrorStore.inMemory(); _ = try store.apply(fixtureAsStored())
  let transport = MirrorTransport(store: store, version: "0.2.0")
  let client = WorkspaceClient(transport: transport); _ = try await client.ready()  // init(transport:) exists
  #expect(try await client.request(ThreadList.self, .init()).threads.count == 1)
  #expect(try await client.request(ThreadRead.self, .init(threadId: "thread-1")).items.count == 4)
  await #expect(throws: WorkspaceError.self) { try await client.request(TurnSend.self, TurnSend.Params(threadId: "thread-1", text: "hi")) }  // code .unsupportedCapability, message mentions M8c
}

// Tests/WorkspaceUITests/MirrorModelTests.swift (macOS, no coordinator)
@MainActor @Test func modelShowsMirroredThreadsAndLiveItems() async throws {
  let store = try MirrorStore.inMemory()
  let transport = MirrorTransport(store: store, version: "0.2.0")
  let model = WorkspaceModel(transportProvider: { transport }); model.connect()
  try await waitUntil("ready") { model.link == .ready }
  transport.publish(try store.apply(Array(fixtureAsStored().prefix(2))))   // connection + thread
  try await waitUntil("thread listed") { model.threads.count == 1 }
  await model.openThread(id: "thread-1"); try await waitUntil("detail") { model.detail != nil }
  transport.publish(try store.apply(Array(fixtureAsStored()[2..<6])))      // turns + items
  try await waitUntil("items") { model.detail?.items.count == 4 }
  #expect(model.connections.first?.target == "")
}
```

- [ ] **Step 4: Run to verify failure; implement `MirrorTransport`, `MirrorSync`, the `DiagnosticsReport.sync` field, the view changes; run `swift test --filter "Mirror"` then `swift test`; lint; commit**

```bash
git commit -am "feat(mirror): SQLite mirror of the synced tables behind an in-process transport; sync diagnostics"
```

---

### Task 9: iOS app wiring, Connect screen, Simulator verification

**Files:**
- Create: `Apps/iOS/B4App/HubConnectView.swift`, `Apps/iOS/B4App/MirrorHost.swift`
- Modify: `Apps/iOS/B4App/B4AppiOS.swift`, `Apps/iOS/B4App/Info.plist` (`NSAppTransportSecurity` → `NSExceptionDomains` → `localhost` with `NSExceptionAllowsInsecureHTTPLoads`), `project.yml` (iOS target depends on `WorkspaceMirror`, `WorkspaceSync`, `WorkspaceSecrets`; ATS keys mirrored under `info.properties`)

**Interfaces:**
- `MirrorHost` (`@MainActor @Observable final class`): owns `MirrorStore` at `<Application Support>/b4app/mirror.sqlite` (directory created with `FileProtectionType.completeUntilFirstUserAuthentication`), `KeychainSecretStore(service: "b4app")`, `MirrorTransport`, and `MirrorSync`; `var isLinked: Bool`; `func connect(url: String, code: String, deviceName: String) async throws` (validate with `HubURL.validate`, `HTTPHubAPI.enroll` with platform `ios`, store the token under a new `SecretRef`, `saveLink`, start `MirrorSync` whose `onBatch` calls `transport.publish`); `func disconnect() async` (revoke, remove the secret, `clearLink`, stop sync); `static let transportProvider`.
- `HubConnectView`: fields Hub URL (default `http://localhost:8080` in `DEBUG`, empty otherwise), Enrollment code (`.textInputAutocapitalization(.characters)`, 8 chars), Device name (default `UIDevice.current.name`), a primary `LLAButtonStyle` "Connect" button, an inline error line using `LLA.Color.danger`; built from `LLA` tokens and `LLAField`/`LLAButtonStyle`; the code is held in `@State` and cleared after the request.
- `B4AppiOS`: shows `HubConnectView` while `!host.isLinked`, else `WorkspaceRootView(model:)` with `WorkspaceModel(transportProvider: host.transportProvider)`; a "Disconnect from hub" entry in the Diagnostics surface's toolbar is deferred; disconnect is reachable by deleting the app in M8a (noted in the verification record).

- [ ] **Step 1: Regenerate the project and build both apps**

Run: `./Scripts/generate-project.sh && xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1` and the macOS scheme.
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 2: End-to-end on this Mac (the M8a exit gate; recorded in `docs/verification.md`)**

1. `cd Hub && docker compose up -d`; seed and enroll as in Task 5 (two codes: one for the Mac, one for the phone).
2. `./Scripts/package.sh`, relaunch the app with `--register-agent`, `agent-workspace coordinator restart`, then `agent-workspace hub join http://localhost:8080` and enter the Mac's code. `agent-workspace hub status` shows `unsynced 0`.
3. Install and launch the iOS build on the booted iPhone 17 Pro simulator; enter `http://localhost:8080` and the phone's code; the thread list shows "First Codex thread".
4. On the Mac, create a thread on the fake or real Codex connection and send a turn. Within five seconds the Simulator shows the new thread and, when opened, its transcript, with no pull-to-refresh.
5. In `docker compose exec db psql`, `SELECT "authReference", "target", "localServerId" FROM connections;` shows NULL, empty, NULL for every row; `SELECT count(*) FROM changes;` equals the Mac's `db status` change count.
6. Negative: `agent-workspace hub join http://192.168.1.10:8080` is refused before any request; the Simulator's Connect screen shows the same refusal (Review Focus 3).

Take Simulator screenshots of the list and a transcript into `docs/screenshots/ios-mirror-{list,thread}.png`.

- [ ] **Step 3: Commit**

```bash
git add Apps project.yml docs/screenshots && git commit -m "feat(ios): connect to the hub and read the mirrored workspace"
```

---

### Task 10: Documentation and acceptance

**Files:**
- Modify: `AGENTS.md` (commands: `cd Hub && cargo test` after `source <(./scripts/test-db.sh)`, `docker compose up` for a local hub; layout: `Hub/`, `WorkspaceSecrets`, `WorkspaceSync`, `WorkspaceMirror`; the rule that `WorkspaceMirror` is the only module that opens SQLite and only the iOS app uses it), `docs/decisions.md` (D-043 Rust hub, D-044 own identity model with no bundled IdP, D-045 offline Mac refuses turns, D-046 iOS mirror and the `WorkspaceSecrets` split; the RLS exemption for the two credential tables inside D-043), `docs/compatibility.md` (Rust 1.93.1 and every pinned crate version, Docker version, the builder, runtime, and `postgres:17` image digests, Simulator runtime), `docs/milestones.md` (section "M8a: read-only mirror" with implemented, fixture-tested, live-tested items; M8b–M8e listed as blocked on M8a), `docs/verification.md` (section "2026-10-31: M8a read-only mirror" with the Task 9 evidence and the two Review Focus items that are only exercised live), `README.md` (a "Hub (optional)" section: Compose, seed, enroll, join).

- [ ] **Step 1: Write the documents, run every gate once more**

Run: `cd Hub && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test` then `swift format lint --strict --recursive Sources Tests Apps Package.swift && swift build && swift test`.
Expected: all green.

- [ ] **Step 2: Commit, open the PR, confirm both CI jobs**

```bash
git add AGENTS.md README.md docs && git commit -m "docs: M8a read-only mirror recorded; decisions D-043 to D-046"
gh pr create --title "feat: M8a read-only mirror (Rust hub, HubSync, iOS mirror)" --body "..."
```
