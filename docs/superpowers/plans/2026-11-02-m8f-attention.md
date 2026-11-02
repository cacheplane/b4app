# M8f Attention on the Phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The hub notifies the phone when a thread needs Brian or has replied, tapping the notification opens the thread, and a home-screen widget shows the top three threads in attention order.

**Architecture:** The hub decides inside the push transaction which applied `runtimeRequests` and `turns` rows notify, records each once in `notifications_sent`, and after the commit hands one message per target iOS device to a `PushSender` (`spool` writes `.apns` files that `Scripts/sim-push.sh` feeds to `xcrun simctl push`; `apns` is a stub that refuses to start). The iOS app registers its token, opens `b4app://thread/<id>` from a tap or a widget row, and moves its mirror into the App Group container, which a WidgetKit extension reads read-only.

**Tech Stack:** Rust (axum, sqlx, PostgreSQL with row-level security), Swift 6 (SwiftUI, UserNotifications, WidgetKit, system SQLite), XcodeGen, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-10-31-m8b-remote-workspace-design.md`, sections "M8f, attention on the phone" and "Constraints". Read `AGENTS.md` for commands and layout rules.

## Global Constraints

- Notification body is exactly one of: `Waiting for your approval`, `Has a question for you`, `Replied`, `Turn failed`. Never transcript text, command text, or paths.
- Notification title is the thread's title (empty title: `Untitled thread`), cut to 100 characters.
- Notify the user's iOS devices other than the one whose push caused the change, once per request id or turn id, idempotent across retries through `notifications_sent`.
- The payload sets `content-available` and carries the thread id; tapping opens the thread through `b4app://thread/<id>`.
- `PushSender` trait in `b4hub`; `spool` writes `.apns` JSON with the `Simulator Target Bundle` key into `B4HUB_PUSH_SPOOL_DIR`; `apns` fails with a clear unsupported error and never pretends to send.
- App Group id `group.com.cacheplane.b4app`; widget target `B4App-iOSWidget`, small and medium sizes; "as of HH:MM" when the data is older than five minutes.
- No `UIApplication` or WidgetKit code in `WorkspaceMirror`; app and extension specifics stay in `Apps/iOS` and `Apps/iOSWidget`. `WorkspaceUI` talks only to `WorkspaceClient`. `SessionService` stays the only writer of turns, display items, and runtime requests.
- App Group id, URL scheme, and entitlements live in `project.yml` (the sign-in branch rebases its flavour changes over them).
- Secrets and push tokens never appear in logs, JSON results, or UI.
- Hub migration is `0011_push.sql` (0005 and 0007 belong to the sign-in branch; 0009 and 0010 to PRs #45 and #46). Decisions are D-110 onward (sign-in holds D-088 to D-109).
- Gates: `swift build`, `swift test`, `swift format lint --strict --recursive Sources Tests Apps Package.swift`; from `Hub/`: `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` (after `source <(./scripts/test-db.sh)`); both `xcodebuild` app builds.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Decisions this plan settles (recorded in Task 9)

- **D-110 Notification rules.** A `runtimeRequests` row whose `state` is `pending` after the batch notifies: kinds `command_approval`, `file_change_approval`, `tool_permission`, `unknown` say "Waiting for your approval"; `user_question`, `elicitation` say "Has a question for you". A `turns` row whose `status` is `terminal` notifies when its `outcome` is `completed` ("Replied") or `failed` ("Turn failed"); `cancelled` never notifies (Brian stopped it), and a terminal turn with no outcome yet waits for the batch that sets it. A turn notifies only when its `updatedAt` is within 10 minutes of the hub's clock, so a Mac's first join or a rejoin uploading history does not flood the phone; requests have no age limit (a pending one is still actionable). The `notifications_sent` row is written in the push transaction whether or not a sender is configured or the phone has a token, so delivery is at most once.
- **D-111 Push token registration.** `POST /v1/devices/self/push-token` with `{"token": hex, "environment": "sandbox"|"production", "bundleId": reverse-DNS}`, `ios` devices only, 204; one row per device in `push_tokens`, replaced on each call. The bundle id comes from the phone, so the hub needs no per-flavour configuration. The token is never logged. The phone sends it on every `didRegisterForRemoteNotifications` while linked and after each enrollment; `environment` is `sandbox` in Debug builds and `production` otherwise.
- **D-112 The sender.** `B4HUB_PUSH_SENDER` is `none` (default), `spool` (needs `B4HUB_PUSH_SPOOL_DIR`), or `apns`, which refuses to start `serve` with "APNs delivery is not built yet (the deploy slice)". Delivery runs on a spawned task after the commit, so the push response never waits on it; a failed delivery is logged with the device id and reason only. Spool files are written to a `.tmp` name and renamed to `<ms>-<uuid>.apns`, so the watcher never reads a partial file.
- **D-113 Payload and tap.** `{"aps": {"alert": {"title", "body"}, "sound": "default", "content-available": 1, "thread-id": <threadId>}, "threadId": <id>, "reason": "approval"|"question"|"replied"|"failed"}`; the spool adds `"Simulator Target Bundle"`. The payload carries no URL: the app builds `<its scheme>://thread/<id>` and sends taps and widget rows through the one `onOpenURL` path. In the foreground a notification shows unless its thread is open and on screen.
- **D-114 The mirror in the App Group.** The app and the widget read the group id and the URL scheme from the Info.plist keys `B4AppAppGroup` and `B4AppURLScheme`, set in `project.yml`. On launch, a `mirror.sqlite` (with its `-wal` and `-shm`) in `<Application Support>/b4app` moves to `<group container>/b4app` when the group has none; when both exist the group's file wins and the old one stays where it is; when the group container is unavailable the app keeps the old location and the widget shows its "Open Agent Workspace" state.
- **D-115 The widget.** Top three non-archived threads by `Attention.ordered` (pinned first), each with its `AttentionDot`, title, and project name (none for a thread without a project). Small: three rows, one tap target that opens the first thread. Medium: each row a `Link`. Data age is the link's `lastSyncAt`; past five minutes it shows "as of <localized short time>". The timeline holds an entry now and one at the moment the data turns stale, and asks for a reload 15 minutes later; the app reloads timelines after every batch that touched threads or projects.

## Review Focus

- A Mac joining (or rejoining) and uploading old finished turns: no "Replied" storm (Task 2 test `history_upload_does_not_notify`).
- A turn whose `status` and `outcome` arrive in separate pushes: one notification, after the second (Task 2 `outcome_in_a_later_batch_notifies_once`).
- A retried batch, and a later update to an already-notified turn: no second notification (Task 2 `retry_and_later_update_do_not_renotify`).
- A notification tapped on a cold launch, before the model has connected: the thread still opens (Task 7 `requested_thread_opens_after_connect`).
- Both an old and a group `mirror.sqlite`, or no group container: nothing deleted, the app still opens (Task 6 `move_keeps_both_when_group_has_one`, `missing_group_falls_back`).

---

### Task 1: Hub rules and payload, with a shared push fixture

**Files:**
- Create: `Hub/crates/b4hub-core/src/push.rs`, `Tests/Fixtures/sync/push.json`
- Modify: `Hub/crates/b4hub-core/src/lib.rs` (add `pub mod push;`)

**Interfaces:**
- Produces (Rust, `b4hub_core::push`):
  - `pub enum Reason { Approval, Question, Replied, Failed }` with `fn as_str(&self) -> &'static str` (`approval`, `question`, `replied`, `failed`) and `fn body(&self) -> &'static str` (the four phrases).
  - `pub fn request_reason(kind: &str, state: &str) -> Option<Reason>`
  - `pub fn turn_reason(status: &str, outcome: Option<&str>, recent: bool) -> Option<Reason>`
  - `pub const TURN_RECENCY_SECS: i64 = 600;`
  - `pub fn alert_title(thread_title: Option<&str>) -> String` (trimmed; empty or none → `Untitled thread`; cut to 100 chars on a char boundary)
  - `pub fn payload(thread_id: &str, title: &str, reason: Reason) -> serde_json::Value` (D-113 shape, no simulator key)
  - `pub fn spool_payload(thread_id: &str, title: &str, reason: Reason, bundle_id: &str) -> serde_json::Value` (adds `"Simulator Target Bundle": bundle_id`)
- Produces (fixture): `Tests/Fixtures/sync/push.json` = `{"requests": [{"kind","state","reason"|null}], "turns": [{"status","outcome"|null,"recent","reason"|null}], "titles": [{"input"|null,"expected"}], "payloads": [{"threadId","title","reason","bundleId","expected": <full spool payload>}]}`. Covers every request kind × `pending`/`resolved`/`expired`, every turn status with each outcome and recent true/false, a 150-character title, an empty title, a title with an emoji at the cut. Task 5 decodes `payloads[*].expected` in Swift.

- [ ] **Step 1: Write the fixture and the failing table test** `push::tests::fixture_cases` in `push.rs` that `include_str!("../../../../Tests/Fixtures/sync/push.json")`, and asserts every `requests`, `turns`, `titles`, and `payloads` entry against the functions above (payload compared as `serde_json::Value`).
- [ ] **Step 2:** `cd Hub && cargo test -p b4hub-core push` → fails to compile (module missing).
- [ ] **Step 3: Implement `push.rs`** per the interfaces; rules exactly as D-110.
- [ ] **Step 4:** `cargo test -p b4hub-core push` → PASS; `cargo clippy -p b4hub-core --all-targets -- -D warnings` clean.
- [ ] **Step 5: Commit** `feat(hub): notification rules and the push payload`.

### Task 2: Push tokens, the ledger, and detection in the push transaction

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0011_push.sql`, `Hub/crates/b4hub-db/src/push.rs`, `Hub/crates/b4hub-db/tests/push.rs`
- Modify: `Hub/crates/b4hub-db/src/changes.rs` (collect touched rows; detect before commit; `PushOutcome.notifications`), `Hub/crates/b4hub-db/src/lib.rs`, `Hub/crates/b4hub-db/src/prune.rs` (prune `notifications_sent` older than the retention window), `Hub/crates/b4hub-db/tests/rls.rs` (the two new tables isolate by org)

**Interfaces:**
- Consumes: Task 1's `request_reason`, `turn_reason`, `alert_title`, `Reason`, `TURN_RECENCY_SECS`.
- Produces:
  - Migration: `push_tokens (org_id uuid NOT NULL REFERENCES orgs, device_id uuid PRIMARY KEY REFERENCES devices, token text NOT NULL, environment text NOT NULL CHECK (environment IN ('sandbox','production')), bundle_id text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())` and `notifications_sent (org_id uuid NOT NULL REFERENCES orgs, kind text NOT NULL CHECK (kind IN ('request','turn')), row_id text NOT NULL, user_id uuid NOT NULL, thread_id text NOT NULL, reason text NOT NULL, sent_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (org_id, kind, row_id))`, both with `ENABLE`/`FORCE ROW LEVEL SECURITY` and the `tenant_isolation` policy used in `0004_relay.sql`. A header comment says why 0011.
  - `b4hub_db::push::save_token(db: &Db, auth: &AuthedDevice, token: &str, environment: &str, bundle_id: &str) -> Result<()>` (upsert on `device_id`).
  - `pub struct Notification { pub device_id: Uuid, pub token: String, pub environment: String, pub bundle_id: String, pub thread_id: String, pub title: String, pub reason: Reason }` (Debug must not print `token`: implement `Debug` by hand).
  - `PushOutcome` gains `pub notifications: Vec<Notification>`.
- Detection, inside `changes::push` after the apply loop and before `tx.commit()`: keep the row ids of every change that returned `Applied::Yes` on `turns` and `runtimeRequests`; for each, read the row (scoped by `org_id` and `user_id`) with its thread's `title`; for turns compute `recent` in SQL as `CASE WHEN "updatedAt" ~ '^\d{4}-\d{2}-\d{2}T' THEN "updatedAt"::timestamptz > now() - make_interval(secs => $n) ELSE false END`; apply the rule; for a reason, `INSERT INTO notifications_sent ... ON CONFLICT DO NOTHING RETURNING 1`; for each newly inserted row, one `Notification` per `push_tokens` row joined to a `devices` row of the same user with `platform = 'ios'`, `revoked_at IS NULL`, and `id <> auth.device_id`.

- [ ] **Step 1: Write the failing tests** in `b4hub-db/tests/push.rs` (copy the `migrated`/seed helpers from `tests/changes.rs`; enroll one `macos` and two `ios` devices; save tokens for both phones):
  - `pending_request_notifies_each_other_phone`: Mac pushes a thread and a `command_approval` request `pending` → two notifications, body reason `Approval`, title = thread title, none for the Mac.
  - `question_kinds_say_question`: `user_question` → `Reason::Question`.
  - `completed_and_failed_turns_notify_cancelled_does_not`.
  - `history_upload_does_not_notify`: a terminal completed turn with `updatedAt` one hour old → none, and no ledger row.
  - `outcome_in_a_later_batch_notifies_once`: push `status=terminal` (no outcome) → none; push `outcome=completed` → one per phone; push again → none.
  - `retry_and_later_update_do_not_renotify`: resend the same batch (same `device_seq`) → none; an update to `updatedAt` of that turn → none.
  - `revoked_or_tokenless_phones_get_nothing`: a revoked phone and a phone without a token are skipped; the ledger row is still written.
  - `phone_push_does_not_target_itself`: a phone's own push (a draft) never notifies; covered by targeting rule, assert with a phone-authed push of a `drafts` insert → empty.
  - `save_token_replaces`: second `save_token` for the device leaves one row with the new token.
  - In `tests/rls.rs`: another org's tenant transaction sees no `push_tokens` or `notifications_sent` rows.
- [ ] **Step 2:** `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --test push` → FAIL (missing module/columns).
- [ ] **Step 3: Implement** the migration, `push.rs`, the detection in `changes.rs`, and the prune line.
- [ ] **Step 4:** `cargo test -p b4hub-db` → PASS (all existing tests too); clippy clean.
- [ ] **Step 5: Commit** `feat(hub): push tokens and a notifications ledger, decided in the push transaction`.

### Task 3: The sender, the push-token route, delivery, and Compose

**Files:**
- Create: `Hub/crates/b4hub/src/push.rs`, `Hub/crates/b4hub/src/routes/push_token.rs`, `Hub/crates/b4hub/tests/push.rs`
- Modify: `Hub/crates/b4hub/src/lib.rs`, `Hub/crates/b4hub/src/routes.rs`, `Hub/crates/b4hub/src/serve.rs` (`AppState.push: Option<Arc<dyn PushSender>>`, route), `Hub/crates/b4hub/src/routes/changes.rs` (spawn delivery after commit), `Hub/crates/b4hub/src/cli.rs` (settings `B4HUB_PUSH_SENDER`, `B4HUB_PUSH_SPOOL_DIR`; build the sender in `serve_command`), `Hub/compose.yaml`, `Hub/.env.example`, `Hub/API.md`, `.gitignore` (`Hub/push-spool/`)

**Interfaces:**
- Consumes: Task 1 `payload`, `spool_payload`; Task 2 `save_token`, `Notification`, `PushOutcome.notifications`.
- Produces:
  - `pub trait PushSender: Send + Sync { fn send<'a>(&'a self, message: &'a Notification) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>>; fn name(&self) -> &'static str; }`
  - `#[derive(Debug, thiserror::Error)] pub enum PushError { #[error("push sender unsupported: {0}")] Unsupported(&'static str), #[error("spool write failed: {0}")] Io(#[from] std::io::Error) }`
  - `pub struct SpoolSender { dir: PathBuf }` with `pub fn new(dir: PathBuf) -> Result<SpoolSender, PushError>` (creates the directory) — writes `spool_payload(...)` pretty JSON to `<dir>/.<name>.tmp`, then renames to `<dir>/<unix ms>-<uuid v4>.apns`.
  - `pub struct ApnsSender;` with `pub fn new() -> Result<ApnsSender, PushError>` returning `Err(PushError::Unsupported("APNs delivery is not built yet (the deploy slice)"))`, and a `send` that returns the same error.
  - `pub fn deliver(sender: Arc<dyn PushSender>, notifications: Vec<Notification>)` — spawns one task that sends each in order and logs failures (`device`, `reason`, error) without the token.
  - Route `POST /v1/devices/self/push-token`: `AuthedDevice`, `WritesAllowed`, body `{token, environment, bundleId}` (`deny_unknown_fields`); 403 `forbidden` for a non-`ios` device; 400 `invalid_request` unless `token` is 32–512 hex characters, `environment` is `sandbox`/`production`, and `bundleId` matches `^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$`; 204 on success. Use the existing `ApiError` constructors (add `forbidden` only if none exists).
  - Settings: `push_sender() -> Result<PushChoice, ConfigError>` where `PushChoice { None, Spool(PathBuf), Apns }`; `spool` without `B4HUB_PUSH_SPOOL_DIR` is a `ConfigError` naming that variable; an unknown value names `B4HUB_PUSH_SENDER`.
  - Compose `hub` service: `B4HUB_PUSH_SENDER: spool`, `B4HUB_PUSH_SPOOL_DIR: /spool`, volume `${B4HUB_PUSH_SPOOL_HOST_DIR:-./push-spool}:/spool`.
- [ ] **Step 1: Write the failing tests** in `b4hub/tests/push.rs` (router through `tower::ServiceExt::oneshot`, helpers as in `tests/changes.rs`; a test-only `RecordingSender` holding an `Arc<Mutex<Vec<(Uuid, String, Reason)>>>`):
  - `push_token_requires_an_ios_device` (Mac → 403), `push_token_validates_fields` (bad hex, short token, bad environment, bad bundle id, unknown field → 400), `push_token_saves` (204).
  - `a_pending_request_reaches_the_sender_once`: phone registers a token; Mac pushes thread + pending request → the recorder sees one message within 2 s; the same push again → still one.
  - `spool_writes_a_simulator_file`: `SpoolSender` on a temp dir; after delivery, exactly one `*.apns` file, no `.tmp` left, JSON equal to `spool_payload` with the phone's bundle id.
  - `apns_refuses`: `ApnsSender::new()` is `Err(Unsupported)`.
  - In `cli.rs` unit tests: `push_sender` parses `none`/unset, `spool` with and without dir, `apns`, and garbage.
- [ ] **Step 2:** `cargo test -p b4hub --test push` → FAIL.
- [ ] **Step 3: Implement**; `serve_command` logs `push sender: <name>` at start and refuses `apns` with the unsupported message as a `CliError`; document the route, payload, and the two variables in `API.md` and `.env.example`.
- [ ] **Step 4:** full hub gate: `cargo fmt --all -- --check`, clippy `-D warnings`, `cargo test --workspace --locked` → PASS.
- [ ] **Step 5: Commit** `feat(hub): PushSender with a Simulator spool, the push-token route, and delivery after commit`.

### Task 4: `Scripts/sim-push.sh`

**Files:** Create `Scripts/sim-push.sh` (executable).

- Usage: `Scripts/sim-push.sh [spool dir]` (default `Hub/push-spool` relative to the repo root). Every 0.5 s, for each `*.apns` file oldest first: `xcrun simctl push booted "$file"`; on success move it to `<dir>/sent/`, on failure to `<dir>/failed/` and print the error. Prints one line per file (name and the `reason` from the JSON via `plutil -extract reason raw`). `set -euo pipefail`; exits with a message when `xcrun simctl` is missing; Ctrl-C stops it.
- [ ] **Step 1:** write it; `shellcheck Scripts/sim-push.sh` if installed (skip with a note if not).
- [ ] **Step 2:** manual check: copy a `payloads[0].expected` from `push.json` into a temp spool dir with a `.apns` name, run the script with a booted Simulator, see the file move to `sent/`.
- [ ] **Step 3: Commit** `feat(scripts): sim-push.sh feeds the hub's spool to the booted Simulator`.

### Task 5: Swift wire side: thread links, the payload, and token registration

**Files:**
- Create: `Sources/WorkspaceProtocol/ThreadLink.swift`, `Tests/WorkspaceProtocolTests/ThreadLinkTests.swift`
- Modify: `Sources/WorkspaceSync/HTTPHubAPI.swift` (or the file holding `HTTPHubAPI`), `Tests/WorkspaceSyncTests/HTTPHubAPITests.swift`

**Interfaces:**
- Produces (`WorkspaceProtocol`, Foundation only):
  - `public enum ThreadLink { public static let host = "thread"; public static func url(threadId: String, scheme: String) -> URL; public static func threadId(from url: URL, scheme: String) -> String?; public static func threadId(fromNotification userInfo: [AnyHashable: Any]) -> String? }` — the id is percent-encoded as one path segment; `threadId(from:)` refuses another scheme or host, an empty or multi-segment path, a query, user, port, or fragment.
  - `public enum PushReason: String, Codable, Sendable { case approval, question, replied, failed }` and `public static func reason(fromNotification:) -> PushReason?` on `ThreadLink`.
- Produces (`WorkspaceSync`): `HTTPHubAPI.registerPushToken(_ token: String, environment: String, bundleId: String) async throws` → `POST /v1/devices/self/push-token`, JSON body `{"token","environment","bundleId"}`, expects 204. Not added to the `HubAPI` protocol (only the iOS app calls it; fakes stay unchanged).
- [ ] **Step 1: Write the failing tests:** `ThreadLinkTests` — round trip with an id containing `/` and spaces; refusals listed above; `b4app://pair?...` is not a thread link; every `payloads[*].expected` in `Tests/Fixtures/sync/push.json` (load it the way `AttentionTests` loads `attention.json`) yields its `threadId` and `reason`. `HTTPHubAPITests.registerPushTokenPostsBody` — method, path, body, and that a 403 surfaces as `HubError` with code `forbidden`.
- [ ] **Step 2:** `swift test --filter 'ThreadLinkTests|HTTPHubAPITests'` → FAIL.
- [ ] **Step 3: Implement.** Also update the `PairLink.isPairLink` doc comment that mentions "a later `b4app://thread/<id>`" to point at `ThreadLink`.
- [ ] **Step 4:** tests PASS; `swift format lint --strict` on the touched files.
- [ ] **Step 5: Commit** `feat(protocol): thread links and push-token registration`.

### Task 6: The mirror in the App Group, read-only opens, and the glance

**Files:**
- Create: `Sources/WorkspaceMirror/MirrorLocation.swift`, `Sources/WorkspaceMirror/MirrorGlance.swift`, `Tests/WorkspaceMirrorTests/MirrorLocationTests.swift`, `Tests/WorkspaceMirrorTests/MirrorGlanceTests.swift`
- Modify: `Sources/WorkspaceMirror/MirrorStore.swift` (read-only open)

**Interfaces:**
- Produces:
  - `public enum MirrorLocation { public static let fileName = "mirror.sqlite"; public static func groupDirectory(appGroup: String) -> URL?` (`containerURL(forSecurityApplicationGroupIdentifier:)` + `b4app`, created with `completeUntilFirstUserAuthentication`); `public enum Move: Equatable { case nothingToMove, moved, keptGroupCopy }`; `public static func move(from old: URL, to new: URL) throws -> Move` (directories; moves `mirror.sqlite`, `-wal`, `-shm` that exist; never deletes) }`.
  - `MirrorStore.openReadOnly(path: String) throws -> MirrorStore` — `SQLITE_OPEN_READONLY`, `PRAGMA query_only = 1`, no migration; throws `MirrorStoreError.needsRebuild(outboxEmpty: true)` when `user_version` differs from `MirrorSchema.version`; a missing file throws `WorkspaceError(.endpointUnavailable, …)`.
  - `public struct GlanceRow: Sendable, Equatable, Codable { public var threadId: String; public var title: String; public var projectName: String?; public var band: AttentionBand; public var pinned: Bool }`
  - `public struct Glance: Sendable, Equatable { public var linked: Bool; public var rows: [GlanceRow]; public var asOf: Date?; public static let staleAfter: TimeInterval = 300; public static let reloadAfter: TimeInterval = 900; public func isStale(at now: Date) -> Bool; public func staleLabel(at now: Date) -> String?` (`"as of " + asOf.formatted(date: .omitted, time: .shortened)` when stale, else nil) `; public func entryDates(now: Date) -> [Date]` (`[now]`, plus `asOf + staleAfter` when that is after `now`) `; public func reloadDate(now: Date) -> Date` (`now + reloadAfter`) `}`
  - `public enum MirrorGlance { public static func load(store: MirrorStore, limit: Int = 3) throws -> Glance; public static func load(path: String, limit: Int = 3) -> Glance }` — the path form opens read-only and answers `Glance(linked: false, rows: [], asOf: nil)` on any failure. Rows: `store.threads(includeArchived: false, connectionId: nil, query: nil)` → `Attention.ordered` → first `limit`; `projectName` from `store.projects()` by `projectId` (`displayName`); `asOf` from `store.link()?.lastSyncAt` via `Timestamp.date(from:)`; `linked` = a link is stored.
- [ ] **Step 1: Write the failing tests:**
  - `MirrorLocationTests`: `moves_all_three_files`; `nothing_to_move`; `move_keeps_both_when_group_has_one` (old and new contents both intact, result `.keptGroupCopy`); `missing_group_falls_back` (documented by `groupDirectory(appGroup:)` returning nil for an unknown group in the macOS test process — assert nil).
  - `MirrorGlanceTests`: seed a temp-file store from `Tests/Fixtures/sync/attention.json` (as `MirrorActivityTests` does) → `load(store:)` rows equal the first three of `Attention.ordered` with the fixture's pinned threads first and project names resolved; `load(path:)` over the same file (closed writer first) gives the same rows; read-only store refuses a write (`saveLink` throws); unlinked file → `linked == false`; missing file → unlinked empty glance; staleness: `asOf` 4 min ago → not stale, `entryDates` has two dates, the second at `asOf + 300`; 6 min ago → stale, label starts with `as of `, one date; `reloadDate` is `now + 900`.
- [ ] **Step 2:** `swift test --filter 'MirrorLocationTests|MirrorGlanceTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** PASS; whole `swift test --filter WorkspaceMirrorTests` still passes.
- [ ] **Step 5: Commit** `feat(mirror): App Group location, read-only opens, and the widget's glance`.

### Task 7: Opening a requested thread, and a public status dot

**Files:**
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift`, `Sources/WorkspaceUI/WorkspaceRootView.swift`, `Sources/WorkspaceUI/ThreadListView.swift` (`AttentionDot` public with `public init(band:)`)
- Test: `Tests/WorkspaceUITests/ThreadOpenRequestTests.swift`

**Interfaces:**
- Produces:
  - `WorkspaceModel.requestOpenThread(_ id: String)` — sets `public private(set) var pendingThreadOpen: String?` and increments `public private(set) var detailRequest: Int`; when `link == .ready` it opens at once (`openThread(id:)`) and clears the pending id; otherwise `connect()` opens it right after `link = .ready` and clears it.
  - `WorkspaceRootView` `.onChange(of: model.detailRequest) { compactColumn = .detail }`.
  - `public struct AttentionDot: View { public init(band: AttentionBand) }`.
- [ ] **Step 1: Write the failing tests** (use the fake transport the other `WorkspaceUITests` use, e.g. in `MirrorModelTests`/`WorkspaceModelTests`): `requested_thread_opens_after_connect` (request before `connect()` → after `settledLink()`, `selectedThreadId` and `detail?.thread.id` equal the id, `pendingThreadOpen == nil`); `requested_thread_opens_at_once_when_ready`; `detail_request_counts_each_request` (two requests for the same id → `detailRequest == 2`).
- [ ] **Step 2:** `swift test --filter ThreadOpenRequestTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** PASS; `swift test` (whole suite) PASS.
- [ ] **Step 5: Commit** `feat(ui): open a thread a notification or widget asked for`.

### Task 8: The iOS app and the widget extension

**Files:**
- Modify: `project.yml`, `Apps/iOS/B4App/B4AppiOS.swift`, `Apps/iOS/B4App/MirrorHost.swift`
- Create: `Apps/iOS/B4App/AppDelegate.swift`, `Apps/iOS/B4App/AppGroup.swift`, `Apps/iOSWidget/AttentionWidget.swift`, `Apps/iOSWidget/AttentionWidgetBundle.swift`

**Interfaces:**
- Consumes: Task 5 `ThreadLink`, `HTTPHubAPI.registerPushToken`; Task 6 `MirrorLocation`, `MirrorGlance`, `Glance`; Task 7 `requestOpenThread`, `AttentionDot`.
- `project.yml`:
  - `B4App-iOS` gets `info.properties` `B4AppAppGroup: group.com.cacheplane.b4app`, `B4AppURLScheme: b4app`, `UIBackgroundModes: [remote-notification]`; `entitlements: { path: Apps/iOS/B4App/B4App.entitlements, properties: { aps-environment: development, com.apple.security.application-groups: [group.com.cacheplane.b4app] } }`; dependency `- target: B4App-iOSWidget` (embedded).
  - New target `B4App-iOSWidget`: `type: app-extension`, `platform: iOS`, sources `Apps/iOSWidget` and `Apps/Shared/Assets.xcassets`, `info.path: Apps/iOSWidget/Info.plist` with `CFBundleDisplayName: Agent Workspace`, version keys as the app, `B4AppAppGroup`, `B4AppURLScheme`, `NSExtension: { NSExtensionPointIdentifier: com.apple.widgetkit-extension }`; entitlements file `Apps/iOSWidget/B4AppWidget.entitlements` with the same application group; settings `PRODUCT_BUNDLE_IDENTIFIER: com.cacheplane.b4app.ios.widget`, `"CODE_SIGN_IDENTITY[sdk=iphonesimulator*]": "-"`, `TARGETED_DEVICE_FAMILY: "1,2"`; package products `WorkspaceMirror`, `WorkspaceProtocol`, `WorkspaceUI`. A comment says the group id, scheme, and entitlements are here so flavour builds can override them.
- `AppGroup.swift`: `enum AppInfo { static var appGroup: String?; static var urlScheme: String }` reading the two Info.plist keys (`urlScheme` falls back to `b4app`). The widget has its own copy of this five-line reader (a target cannot share an app file without a module).
- `MirrorHost`:
  - Store path: `MirrorLocation.groupDirectory(appGroup:)` when available, after `MirrorLocation.move(from: <old Application Support>/b4app, to: group)`; log the `Move` outcome; fall back to the old directory when the group is nil.
  - `publish(_:)` calls `WidgetCenter.shared.reloadAllTimelines()` when the batch touched threads or projects; `logOut()` reloads too.
  - `pushToken: String?` (hex, in memory only); `func received(pushToken: Data)` stores the hex and, when linked, calls `registerPushToken` (environment `#if DEBUG` `sandbox` else `production`, bundle id `Bundle.main.bundleIdentifier`); `connect(...)` sends it after enrollment; failures are logged without the token.
  - `func requestNotifications()` — called from `wire(_:)`: `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`, then `UIApplication.shared.registerForRemoteNotifications()` regardless of the answer.
  - `func backgroundRefresh() async -> Bool` — nudges the sync loop, waits up to 8 s for the next `publish`, reloads timelines, returns whether a batch arrived.
  - `func open(threadId: String)` — `model?.requestOpenThread(threadId)`; `func isOnScreen(threadId:) -> Bool` from `model.selectedThreadId` and `model.isDetailOnScreen`.
- `AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate` via `@UIApplicationDelegateAdaptor` in `B4AppiOS`: sets the notification delegate in `didFinishLaunching`; token success → `MirrorHost.shared.received(pushToken:)`; failure → log; `didReceiveRemoteNotification(_:fetchCompletionHandler:)` → `backgroundRefresh()` → `.newData`/`.noData`; `willPresent` → `[]` when `isOnScreen(threadId:)` else `[.banner, .list, .sound]`; `didReceive` → build `ThreadLink.url(threadId:scheme: AppInfo.urlScheme)` and post it to the app's open path (an `@Observable` `pendingURL` on `MirrorHost` that `B4AppiOS` consumes with `.onChange`, or `UIApplication.shared.open` of the URL; pick the in-process one).
- `B4AppiOS.open(_:)`: a `ThreadLink.threadId(from:scheme:)` match while linked → `host.open(threadId:)`; otherwise the existing pair-link handling.
- Widget: `AttentionWidget: Widget` (`StaticConfiguration`, kind `AttentionWidget`, `.supportedFamilies([.systemSmall, .systemMedium])`, display name "Threads", description "The threads that need you, most urgent first."); `GlanceProvider: TimelineProvider` building entries from `MirrorGlance.load(path:)` at `<group>/b4app/mirror.sqlite`, `entryDates`, and `.after(reloadDate)`; the view uses `LLA.Color`/`LLAFont` (call `LLAFonts.register()` once), `AttentionDot`, a one-line title, a muted project name, the stale label in the footer, "Open Agent Workspace to pair with your Mac" when unlinked, "No threads yet" when empty; small uses `.widgetURL` of the first row, medium wraps each row in `Link`; `.containerBackground(LLA.Color.bg, for: .widget)`.
- [ ] **Step 1:** `./Scripts/generate-project.sh`, then both builds: `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` and `-scheme B4App-macOS -destination 'platform=macOS'` → BUILD SUCCEEDED (the macOS app is untouched but must still build).
- [ ] **Step 2:** run the app in the iPhone 17 Pro Simulator against the Compose hub: it opens with existing data (moved mirror), the permission prompt appears, `xcrun simctl get_app_container booted com.cacheplane.b4app.ios groups` lists the group and its `b4app/mirror.sqlite`.
- [ ] **Step 3:** `swift format lint --strict --recursive Sources Tests Apps Package.swift` clean.
- [ ] **Step 4: Commit** `feat(ios): notifications, thread links, the mirror in the App Group, and the attention widget`.

### Task 9: Live gate, documents, and the pull request

**Files:** Modify `docs/decisions.md`, `docs/milestones.md`, `docs/verification.md`, `docs/compatibility.md` (Xcode `simctl push` and the WidgetKit availability used), `AGENTS.md` (Layout: `Apps/iOSWidget`, `Hub/crates/b4hub/src/push.rs`, `Scripts/sim-push.sh`, `push.json` among the shared fixtures).

- [ ] **Step 1: Live gate** (record every command and observed result in `docs/verification.md` under "M8f attention"): rebuild the Compose hub (`docker compose build && docker compose up -d` in `Hub/`), start `Scripts/sim-push.sh`, run the Simulator app linked to the hub, allow notifications, confirm a `push_tokens` row exists (count only, never print the token), send the app to the background, then on a scratch Mac coordinator joined to the same hub (`B4APP_RUNTIME_DIR`/`B4APP_DATA_DIR` under `$TMPDIR`, a fake Codex connection from `Tests/CodexAdapterTests/Fixtures/fake-codex.py` that asks for a command approval) produce a pending approval. Measure: the hub's push log line time to the `sim-push.sh` line time (≤ 5 s). Tap the notification (computer use on the Simulator, or `xcrun simctl openurl booted b4app://thread/<id>` as a fallback that is reported as such) → the thread opens. Add the widget to the home screen (small and medium) → it lists the top three; after the next notification it updates. Screenshots to the scratchpad, sent to the user. Do not touch `dist/`. Anything only Brian can do (APNs key, a real device, the App Group and Push capabilities on the Developer portal before the next TestFlight upload) is listed as `blocked`.
- [ ] **Step 2: Documents:** D-110 to D-115 (as above, with any calls the build surfaced, D-116 onward) under a new "2026-11-02 (M8f)" section at the top of `docs/decisions.md`, noting the renumber rule if sign-in lands first; `docs/milestones.md` M8f entry with each item `implemented`/`fixture-tested`/`live-tested`/`blocked` and the test counts; `AGENTS.md` layout lines.
- [ ] **Step 3: Final gates:** `git fetch origin && git merge origin/main` (renumber decisions if needed), all Global Constraints gates, both app builds.
- [ ] **Step 4:** push the branch, `gh pr create` against `main` (body: summary, decisions, gate results, blocked items, ending with the Claude Code line), `gh pr merge <N> --auto --merge`.
