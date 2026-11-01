# M8b Organisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac and the iPhone Simulator show one thread list in attention order (pinned, needs input, unread reply, working, quiet), organised by projects, and the phone's edits to titles, pins, archive, drafts, read state, and project names converge with the Mac's through the Compose hub.

**Architecture:** Projects and the read marker are new synced data written by the coordinator's `SessionService`; the attention band is computed, never stored, by one pure function in `WorkspaceProtocol` from an `activity` summary each store derives from the synced turns and requests. Every change carries a hybrid logical clock; a fixed list of phone-writable columns merges last-writer-wins on the Mac, the hub, and the mirror. The phone writes through an outbox in `WorkspaceMirror`; the coordinator's `HubSync` gains a pull loop whose `applyRemote` takes only phone-writable values. The hub gains clocks, per-change rejection, ownership, byte-limited pages, pruning with a snapshot, and a devices list.

**Tech Stack:** Swift 6.2 package (WorkspaceProtocol, WorkspaceStorage on libpq, WorkspaceSync, WorkspaceMirror on system SQLite3, Coordinator, WorkspaceUI), Rust 1.93.1 hub (axum 0.8, sqlx 0.8; no new crates), Compose `postgres:17`, the iPhone 17 Pro Simulator.

**Spec:** `docs/superpowers/specs/2026-10-31-m8b-remote-workspace-design.md`, section "M8b, organisation" and "Calls made after the builder check" (approved by the owner 2026-10-31). It amends `docs/superpowers/specs/2026-10-31-m8-hub-design.md`; read both.

## Global Constraints

- Display order: **pinned first**, then bands **needs input → unread reply → working → quiet**; within a band, `lastActivityAt` descending, ties by thread `id` ascending. Pinned threads are ordered among themselves by the same rule.
- Band rules, evaluated in this order: needs input = at least one `runtimeRequests` row with `state = 'pending'`; working = latest turn (by `createdAt`, ties by `id`) has `status != 'terminal'`; unread = latest turn is terminal and its `id != threads.readTurnId`; quiet = everything else, including no turn.
- `lastActivityAt` = max(`threads.createdAt`, latest turn `updatedAt`, latest request `updatedAt`). Never `threads.updatedAt`.
- HLC text: 12 lowercase hex digits of epoch milliseconds, 4 lowercase hex digits of counter, `-`, device id (example `0192e0f1a2b3-0000-01a194cf-0d12-7418-b3b5-5559dbee2441`). Compared as plain strings. Clamp: an incoming HLC more than 300 000 ms ahead of the receiver's wall clock is rewritten to the receiver's milliseconds with counter `0000` and the original device id.
- Phone-writable (merge last-writer-wins on every store): `threads.title`, `threads.pinned`, `threads.archived`, `threads.readTurnId`, `projects.name`, and `drafts.threadId`, `drafts.text`, `drafts.updatedAt`. Clocked but Mac-only: `threads.projectId`. Every other column is Mac-only and applies as in M8a.
- Hub write rule by platform: a `macos` device may write any column; an `ios` or `cli` device only the phone-writable list. A refused change is reported as `rejected: [{deviceSeq, code: "column_not_writable"}]` and covered by `acceptedThrough`; a value over `MAX_PAYLOAD_BYTES` is reported the same way with `code: "payload_too_large"` instead of a 413.
- Owner = `device_id` of a row's latest insert (`owner_device_id` on the hub, `ownerDeviceId` in the mirror).
- Pull pages stop at 1000 rows or 8 MiB (8 388 608 bytes) of `value` JSON, whichever comes first, always at least one row. Retention: `B4HUB_RETENTION_DAYS`, default 30; `serve` prunes every 24 h.
- `threads.context` is never rewritten. Project folder paths are `SessionService.canonicalDirectory(_:)` forms. An empty project name displays as the folder's last path component (first folder by `createdAt`).
- Drafts are cleared by setting `text` to `''`, never deleted except by thread cascade.
- Unimplemented phone commands throw `WorkspaceError(.unsupportedCapability)` naming "the Mac" (project create, update, delete) or `M8c` (turns, thread create).
- `WorkspaceUI` imports only `WorkspaceClient` and `WorkspaceProtocol`; UI-only state (collapsed sections) may use `@SceneStorage`; nothing else uses `UserDefaults`.
- Status dot colours: needs input `LLA.Color.warning`, unread `LLA.Color.accent`, working `LLA.Color.success`, quiet `LLA.Color.muted` (add a token to `Sources/WorkspaceUI/Theme/` only if one of these is missing, with D-036's palette rules).
- `Tests/Fixtures/sync/changes.json` and the new `Tests/Fixtures/sync/attention.json` are cross-language or cross-store contracts: edit them only with every suite that reads them.
- Gates per task: `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `swift build`, the task's `swift test --filter …`; for hub tasks `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`, `cargo test --workspace --locked` (from `Hub/`, with `Hub/scripts/test-db.sh` providing `DATABASE_URL`). Full `swift test` and both `xcodebuild` builds before the last task's commit.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on branch `feat/m8b-organisation` from `main` in a worktree; PR to `main`.

## Review Focus

1. **A phone whose clock is behind** (edits stamped ten minutes in the past, made later in real time than a Mac edit) loses to the Mac's edit, which is the documented LWW behaviour; a phone clock **ahead** by more than five minutes is clamped so it cannot win every future conflict. Pinned in Task 1 (`clampsAClockFarAhead`) and Task 5 (`push_clamps_a_clock_far_ahead`).
2. **Two raw working directories with one canonical form** (`~/repos/b4app`, `/Users/blove/repos/b4app/`, or a symlink to it) must land in one project, and a thread whose folder no longer exists must still get a project at backfill rather than failing the migration. Pinned in Task 4.
3. **A pending request on an older turn** while the latest turn is terminal and read still puts the thread in needs input; an `expired` request does not. Pinned in Task 1's fixture.
4. **Renaming a project to the empty string** restores its folder-name display on both devices rather than showing a blank header. Pinned in Task 4 and Task 9.
5. **A mirror whose schema migration fails while the outbox holds unsent edits** keeps the file and reports the error instead of rebuilding and dropping the edits. Pinned in Task 9.

---

## File structure

Swift (new):
- `Sources/WorkspaceProtocol/Attention.swift`: `AttentionBand`, `ThreadActivity`, `Attention.band(of:)`, `Attention.ordered(_:)`.
- `Sources/WorkspaceProtocol/HybridClock.swift`: `HLC` value, `HybridClock` (thread-safe), `SyncColumns` (phone-writable and clocked lists).
- `Sources/WorkspaceProtocol/Projects.swift`: `Project`, `ProjectFolder`, project commands, `thread.markRead`.
- `Sources/WorkspaceStorage/SQL/0004_organisation.sql`, `Sources/WorkspaceStorage/Projects.swift` (project queries), `Sources/WorkspaceStorage/RemoteApply.swift` (`applyRemote`).
- `Sources/Coordinator/ProjectService.swift` (auto-projects, folder moves, backfill), `Sources/Coordinator/HubSync/HubPull.swift` (pull loop).
- `Sources/WorkspaceMirror/MirrorMigrations.swift`, `Sources/WorkspaceMirror/MirrorWrites.swift` (outbox and local writes).
- `Sources/WorkspaceUI/ThreadListView.swift` (grouped and flat lists, status dot), `Sources/WorkspaceUI/ProjectSheets.swift` (Mac new/rename/add-folder sheets).
- `Tests/Fixtures/sync/attention.json`; tests in the existing targets named per task.

Hub (new): `Hub/crates/b4hub-core/src/hlc.rs`, `Hub/crates/b4hub-core/src/writable.rs`, `Hub/crates/b4hub-db/migrations/0003_organisation.sql`, `Hub/crates/b4hub-db/src/prune.rs`, `Hub/crates/b4hub-db/src/snapshot.rs`, `Hub/crates/b4hub/src/routes/snapshot.rs`.

Modified throughout: `Sources/WorkspaceProtocol/{Domain.swift, Commands.swift, Events.swift}`, `Sources/WorkspaceStorage/{WorkspaceDatabase.swift, ChangeLog.swift}`, `Sources/Coordinator/{SessionService.swift, Router.swift, Coordinator.swift, HubSync/HubSync.swift, HubSync/SyncFilter.swift}`, `Sources/WorkspaceSync/{Wire.swift, HubAPI.swift, HTTPHubAPI.swift, FakeHubAPI.swift}`, `Sources/WorkspaceMirror/{MirrorSchema.swift, MirrorStore.swift, MirrorSync.swift, MirrorTransport.swift}`, `Sources/WorkspaceUI/{WorkspaceModel.swift, WorkspaceRootView.swift, ThreadsView.swift, NewThreadSheet.swift, DiagnosticsView.swift}`, `Apps/iOS/B4App/MirrorHost.swift`, `Hub/crates/b4hub-core/src/change.rs`, `Hub/crates/b4hub-db/src/{changes.rs, devices.rs, migrate.rs}`, `Hub/crates/b4hub/src/{serve.rs, cli.rs, routes/changes.rs, routes/devices.rs}`, `Hub/API.md`, `Tests/Fixtures/sync/changes.json`, `docs/{decisions.md, milestones.md, verification.md, compatibility.md}`.

---

### Task 1: Attention, clocks, and the shared column lists (WorkspaceProtocol)

**Files:**
- Create: `Sources/WorkspaceProtocol/Attention.swift`, `Sources/WorkspaceProtocol/HybridClock.swift`, `Tests/Fixtures/sync/attention.json`
- Modify: `Sources/WorkspaceProtocol/Domain.swift` (`ConversationThread` gains `projectId: String?`, `readTurnId: String?`, and two computed-on-read fields that are never database columns, `activity: ThreadActivity?` and `ownerDeviceName: String?` (only the mirror fills the latter), all defaulting to nil in `init`)
- Test: `Tests/WorkspaceProtocolTests/AttentionTests.swift`, `Tests/WorkspaceProtocolTests/HybridClockTests.swift`

**Interfaces:**
- Produces: `public enum AttentionBand: Int, Codable, Sendable, Comparable { case needsInput = 0, unread = 1, working = 2, quiet = 3 }` (raw value is display rank). `public struct ThreadActivity: Codable, Sendable, Equatable { latestTurnId: String?; latestTurnStatus: TurnStatus?; latestTurnOutcome: TurnOutcome?; pendingRequests: Int; lastActivityAt: String }`. `public enum Attention { static func band(of: ConversationThread) -> AttentionBand; static func ordered(_: [ConversationThread]) -> [ConversationThread] }` (a thread with `activity == nil` is quiet with `lastActivityAt = createdAt`). `public struct HLC: Comparable, Codable, Sendable { let rawValue: String; var millis: UInt64; var counter: UInt16; var deviceId: String; init?(rawValue:); init(millis:counter:deviceId:); func clamped(toWall: UInt64) -> HLC }`. `public final class HybridClock: Sendable { init(deviceId: String, wall: @Sendable () -> UInt64 = epochMillis); func next() -> HLC; func observe(_: HLC); var deviceId: String { get set } }`. `public enum SyncColumns { static let phoneWritable: [String: Set<String>]; static let clocked: [String: Set<String>]; static func isPhoneWritable(table:column:) -> Bool }` with the exact lists from Global Constraints (`clocked` = phone-writable plus `threads.projectId`). The spec places the Swift list in `WorkspaceSync`; it lives in `WorkspaceProtocol` instead because `WorkspaceStorage` needs it and does not import `WorkspaceSync`. `ConversationThread`'s new fields are optional so existing rows and JSON decode unchanged; `activity` and `ownerDeviceName` are never database columns.

- [ ] **Step 1: Write the fixture and failing tests**

`attention.json` is `{ "threads": [ConversationThread…], "turns": [Turn…], "runtimeRequests": [RuntimeRequest…], "expected": { "bands": {threadId: "needsInput"|…}, "order": [threadId…] } }` with at least: a pinned quiet thread; a thread whose older turn has a pending request and latest turn terminal and read (needsInput, Review Focus 3); a thread with only an `expired` request and a running turn (working); a failed latest turn not read (unread); a completed turn read (quiet); a thread with no turns (quiet); two unread threads ordered by turn `updatedAt`; one thread whose `updatedAt` is the newest of all but whose activity is oldest (proves `updatedAt` is ignored).

```swift
@Test func fixtureBandsAndOrder() throws {
  let f = try AttentionFixture.load()            // test helper: decodes the file and computes `activity`
  for t in f.threadsWithActivity { #expect(Attention.band(of: t) == f.expectedBand[t.id]) }
  #expect(Attention.ordered(f.threadsWithActivity).map(\.id) == f.expectedOrder)
}
@Test func hlcSortsByMillisThenCounterThenDevice() {
  #expect(HLC(millis: 1, counter: 9, deviceId: "b") < HLC(millis: 2, counter: 0, deviceId: "a"))
  #expect(HLC(millis: 2, counter: 0, deviceId: "a") < HLC(millis: 2, counter: 0, deviceId: "b"))
  #expect(HLC(rawValue: "0192e0f1a2b3-0000-dev")?.millis == 0x0192e0f1a2b3)
  #expect(HLC(rawValue: "not-a-clock") == nil)
}
@Test func nextIsMonotonicWhenTheWallStandsStillOrGoesBack() { /* wall returns 100, 100, 90: three next() strictly increasing */ }
@Test func observeAdvancesPastARemoteClock() { /* observe(millis: 500, counter: 3) at wall 100 → next() > that remote */ }
@Test func clampsAClockFarAhead() {
  let far = HLC(millis: 1_000_000, counter: 7, deviceId: "p")
  #expect(far.clamped(toWall: 600_000) == HLC(millis: 600_000, counter: 0, deviceId: "p"))
  #expect(HLC(millis: 800_000, counter: 7, deviceId: "p").clamped(toWall: 600_000).millis == 800_000) // within 5 min
}
@Test func phoneWritableListIsExact() { /* SyncColumns.phoneWritable equals the Global Constraints list; clocked adds only threads.projectId */ }
```

The fixture helper computes `activity` in Swift (a reference implementation used only by tests); Tasks 3 and 9 run the same file through SQL.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "AttentionTests|HybridClockTests"` — Expected: compile failure (types missing).

- [ ] **Step 3: Implement** `Attention.swift`, `HybridClock.swift` (a `Mutex<(millis, counter)>`; `next()` = max(wall, last.millis) with counter reset or incremented; `observe` takes the max), and the `ConversationThread` fields.

- [ ] **Step 4: Run to verify pass**, then `swift test --filter WorkspaceProtocolTests` (existing round-trip tests still pass with the optional fields).

- [ ] **Step 5: Commit** — `git commit -m "feat(protocol): attention bands, hybrid logical clock, phone-writable columns"`

---

### Task 2: Local schema, clocks in the change log, project and read columns (WorkspaceStorage)

**Files:**
- Create: `Sources/WorkspaceStorage/SQL/0004_organisation.sql`
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`write` sets `b4app.hlc`; `clock` property), `Sources/WorkspaceStorage/ChangeLog.swift` (`ChangeRecord.hlc: String`, `syncedTables` adds `("projects","id")`, `("projectFolders","id")` after `connections`)
- Test: `Tests/WorkspaceStorageTests/OrganisationSchemaTests.swift`

**Interfaces:**
- Consumes: `HybridClock`, `SyncColumns.clocked` (Task 1).
- Produces: tables `projects("id" text PK, "name" text NOT NULL DEFAULT '', "manual" boolean NOT NULL DEFAULT false, "createdAt" text NOT NULL, "updatedAt" text NOT NULL)`, `projectFolders("id" text PK, "projectId" text NOT NULL REFERENCES "projects" ON DELETE CASCADE, "path" text NOT NULL UNIQUE, "createdAt" text NOT NULL)`, `threads."projectId" text REFERENCES "projects" ON DELETE SET NULL`, `threads."readTurnId" text`, `changes."hlc" text NOT NULL`, `columnClocks("table" text, "rowId" text, "column" text, "hlc" text NOT NULL, PRIMARY KEY ("table","rowId","column"))`. Change-log triggers on `projects` and `projectFolders` (`'id'`). The trigger stores `hlc := coalesce(nullif(current_setting('b4app.hlc', true), ''), lpad(to_hex(wall),12,'0') || '-0000-' || device)` and, for an insert or an update of a clocked column (the list is a SQL array literal in the trigger, matching `SyncColumns.clocked`), upserts `columnClocks` with that `hlc`. Existing `changes` rows are backfilled with the same wall-derived form. `WorkspaceDatabase.clock: HybridClock` (device id kept equal to `deviceId`); `write` sets `b4app.hlc` to `clock.next().rawValue` on every write transaction (also when the device is `local`).

- [ ] **Step 1: Failing tests**

```swift
@Test func everyChangeCarriesAClockAndOneTransactionSharesIt() throws {
  let db = try WorkspaceDatabase.temporary()
  /* insert a connection and a thread in one write, rename the thread in a second; the two first rows share an hlc, the rename's is greater */
}
@Test func clockedColumnsRecordTheirClock() throws {
  /* insert thread → columnClocks has title/pinned/archived/readTurnId/projectId at the insert's hlc; update title → only title's clock advances; update continuity → no clock row for continuity */
}
@Test func migrationBackfillsOldChangesAndKeepsReplayWorking() throws { /* existing ChangeLogTests still pass; a pre-0004 row has hlc "<12 hex>-0000-local" */ }
```

- [ ] **Step 2: Run** `swift test --filter OrganisationSchemaTests` — Expected: FAIL (no column `hlc`).
- [ ] **Step 3: Implement** the migration and the `write`/`ChangeRecord` changes. `ConversationThread` writes ignore `activity` (confirm `insert`/`update` use catalog columns; add a test assertion if they do not).
- [ ] **Step 4: Run** `swift test --filter "WorkspaceStorageTests"` — Expected: PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(storage): hybrid clocks in the change log, column clocks, projects schema"`

---

### Task 3: Activity, projects, read marker, and draft clearing queries (WorkspaceStorage)

**Files:**
- Create: `Sources/WorkspaceStorage/Projects.swift`, `Sources/WorkspaceProtocol/Projects.swift` (types only; Task 4 adds the commands)
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`listThreads`, `thread(id:)` fill `activity`; `markRead`; `clearDraft`)
- Test: `Tests/WorkspaceStorageTests/ActivityQueryTests.swift`, `Tests/WorkspaceStorageTests/ProjectStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 types and fixture, Task 2 schema.
- Produces on `WorkspaceDatabase`: `listProjects() -> [Project]`; `project(id:) -> Project?`; `project(folderPath:) -> Project?`; `insertProject(_: Project, folders: [String]) -> Project`; `renameProject(id:name:) -> Project?` (a Mac write: bumps `projects.updatedAt`); `moveFolder(path:toProject:)`; `removeFolder(path:)`; `deleteProject(id:)`; `setThreadProject(threadIds: [String], projectId: String?)`; `markRead(threadId:turnId: String?) -> ConversationThread?` (nil clears the marker, "mark as unread"; a non-nil id writes only if it is a terminal turn of the thread created no earlier than the current marker's turn; otherwise returns the thread unchanged; never bumps `threads.updatedAt`); `clearDraft(threadId:)` (update `text = ''`, `updatedAt = now`, no delete). `Project` and `ProjectFolder` come from Task 4's protocol file, so create `Sources/WorkspaceProtocol/Projects.swift` here with `public struct Project { id, name, manual, createdAt, updatedAt, folders: [ProjectFolder], displayName: String }` and `ProjectFolder { id, projectId, path, createdAt }` (`displayName` computed on read: `name` if non-empty, else the last path component of the oldest folder, else `"Untitled project"`). `activity` is computed in one SQL query joined to `listThreads` (lateral subqueries for latest turn and latest request, a count of pending requests); `ThreadFilter` gains `projectId: String?`.

- [ ] **Step 1: Failing tests**

```swift
@Test func activityMatchesTheSharedFixture() throws {
  /* load attention.json into a temporary database (insert rows), listThreads(includeArchived: true), feed Attention; bands and order equal expected */
}
@Test func markReadIgnoresAnOlderTurn() throws { /* turns t1 < t2 terminal; markRead(t2) then markRead(t1) → readTurnId == t2 */ }
@Test func clearDraftKeepsTheRow() throws { /* saveDraft then clearDraft → draft(threadId:)?.text == "" ; changes show an update, not a delete */ }
@Test func displayNameFallsBackToTheFolder() throws { /* project name "" with folder /x/b4app → "b4app"; rename "Site" → "Site"; rename "" → "b4app" (Review Focus 4) */ }
@Test func aFolderBelongsToOneProject() throws { /* insert second project with the same path → protocolInvalid */ }
```

- [ ] **Step 2: Run** `swift test --filter "ActivityQueryTests|ProjectStoreTests"` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; then `swift test --filter WorkspaceStorageTests`.
- [ ] **Step 5: Commit** — `git commit -m "feat(storage): thread activity, projects, read marker, drafts cleared not deleted"`

---

### Task 4: Projects in the coordinator, `thread.markRead`, commands and events

**Files:**
- Create: `Sources/Coordinator/ProjectService.swift`
- Modify: `Sources/WorkspaceProtocol/Projects.swift` (commands), `Sources/WorkspaceProtocol/Commands.swift` (methods, `isMutation`), `Sources/WorkspaceProtocol/Events.swift` (`projectChanged = "project.changed"`), `Sources/Coordinator/SessionService.swift` (thread create assigns a project; send clears instead of deletes the draft), `Sources/Coordinator/Router.swift`, `Sources/Coordinator/Coordinator.swift` (run the backfill once at start, after migrations)
- Test: `Tests/CoordinatorTests/ProjectServiceTests.swift`, additions to `Tests/CoordinatorTests/RouterTests.swift`

**Interfaces:**
- Consumes: Task 3's storage API, `SessionService.canonicalDirectory`.
- Produces: commands `project.list` (`Result { projects: [Project] }`), `project.create { name: String, folders: [String] }`, `project.update { projectId, name?, addFolders?, removeFolders? }`, `project.rename { projectId, name }`, `project.delete { projectId }` (manual only; `protocolInvalid` otherwise), `thread.markRead { threadId, turnId: String? }` (nil marks unread; `Result = ThreadCreate.Result`). Event `project.changed` with `payload["projectId"]`. `ProjectService` (an actor or a struct over `WorkspaceDatabase`, builder's choice) with `projectId(forThread: ConversationThread, connection: Connection) throws -> String?` (harness: canonical `context`; local B4: the managed server's `projectPath` via `connection.localServerId`; remote B4: nil), `ensureProject(folder: String) throws -> Project`, `backfill() throws -> Int` (idempotent: only threads with `projectId IS NULL`), and the folder-move rules from the spec (moving a folder into a manual project deletes an automatic project left empty and rewrites `projectId` of its threads; removing a folder from a manual project gives it a new automatic project when threads use it).

- [ ] **Step 1: Failing tests**

```swift
@Test func newThreadsShareAProjectAcrossSpellings() async throws {
  /* create threads in "~/x/app", "/Users/…/x/app/", and a symlink to it (temp dirs) → one project, displayName "app"; threads.context keeps each raw spelling (Review Focus 2) */
}
@Test func backfillHandlesAMissingFolder() async throws { /* a thread whose context dir was deleted → backfill() assigns a project named by its last component, no throw (Review Focus 2) */ }
@Test func movingAFolderIntoAManualProjectMovesItsThreads() async throws { /* auto project P(app); create manual M with app → threads.projectId == M, P deleted, project.changed published */ }
@Test func localB4ThreadsUseTheServerProjectAndRemoteHaveNone() async throws { /* FakeB4Project managed server → its project; remote B4 connection → projectId nil */ }
@Test func markReadAndClearedDraftThroughTheRouter() async throws { /* thread.markRead with the latest terminal turn → readTurnId set, thread.updated published; turn.send leaves drafts row with text "" */ }
@Test func renameToEmptyRestoresTheFolderName() async throws { /* project.rename "" → project.list displayName == folder name (Review Focus 4) */ }
```

- [ ] **Step 2: Run** `swift test --filter "ProjectServiceTests|RouterTests"` — FAIL.
- [ ] **Step 3: Implement**; register the new methods in `Router` the way `threadUpdate` is; `isMutation` true for all but `project.list`.
- [ ] **Step 4: Run** — PASS; then `swift test --filter CoordinatorTests`.
- [ ] **Step 5: Commit** — `git commit -m "feat(coordinator): projects, thread.markRead, drafts cleared on send"`

---

### Task 5: Hub clocks, ownership, write rule, per-change rejection, scrubbing

**Files:**
- Create: `Hub/crates/b4hub-core/src/hlc.rs`, `Hub/crates/b4hub-core/src/writable.rs`, `Hub/crates/b4hub-db/migrations/0003_organisation.sql`
- Modify: `Hub/crates/b4hub-core/src/change.rs` (`Change.hlc: Option<String>`, `StoredChange.hlc: String`, `TableSpec`s for `projects` and `projectFolders`, `threads` columns `projectId`, `readTurnId`), `Hub/crates/b4hub-db/src/changes.rs` (`push` returns `PushOutcome`), `Hub/crates/b4hub-db/src/devices.rs` (`AuthedDevice.platform: Platform`), `Hub/crates/b4hub/src/routes/changes.rs` (response body), `Tests/Fixtures/sync/changes.json`, `Hub/API.md`
- Test: `Hub/crates/b4hub-core/src/hlc.rs` (unit), `Hub/crates/b4hub-db/tests/changes.rs` (additions)

**Interfaces:**
- Produces: `hlc::Hlc` (parse, `Ord` by string, `clamped(now_ms)`, `derived(wall, device_id)` = `"{wall:012x}-0000-{device}"`); `writable::is_phone_writable(table, column) -> bool`, `writable::CLOCKED: &[(&str, &str)]` (identical lists to Swift's `SyncColumns`); `push(...) -> Result<PushOutcome { accepted_through: i64, rejected: Vec<Rejected { device_seq: i64, code: &'static str }> }>`; wire response `{"acceptedThrough": n, "rejected": [{"deviceSeq": n, "code": "column_not_writable"}]}` (`rejected` omitted when empty, so an M8a client still decodes it). Migration: `changes.hlc text` backfilled with the derived form then `NOT NULL`; `owner_device_id uuid` on all materialised tables backfilled from each row's latest insert; materialised `projects`, `"projectFolders"` (Mac column names, RLS forced, same policy); `threads."projectId"`, `threads."readTurnId"`; `column_clocks(org_id, "table", row_id, "column", hlc, PRIMARY KEY (org_id, "table", row_id, "column"))` with RLS. Apply rules: clamp first (`hlc` stored clamped; `tracing::info!` on a clamp); a non-`macos` device's change to a non-writable column, or an insert of a table other than `drafts`, is rejected (not appended); a clocked column applies only when the change's `hlc` > `column_clocks.hlc` (then updates the clock); an insert counts per clocked column at its `hlc`; `connections` `authReference`, `localServerId`, `target` are set NULL on every insert and update regardless of the value; `owner_device_id` is set on insert only; a value over `MAX_PAYLOAD_BYTES` is rejected per change (`payload_too_large`) instead of the route's 413 (the 32 MiB body limit stays).

- [ ] **Step 1: Failing tests** (`#[sqlx::test(migrations = false)]`, using `common::migrated`)

```rust
#[test] fn hlc_orders_and_clamps() { /* same cases as Swift HybridClockTests incl. 300_000 ms boundary */ }
async fn phone_title_edit_applies_and_later_mac_edit_wins(pool) { /* enroll mac + ios; mac inserts thread (hlc t1); ios updates title (t2); mac updates title (t3) → threads.title == mac's */ }
async fn stale_phone_edit_loses(pool) { /* mac title at t5, ios title at t3 pushed later → title stays mac's; change row still appended */ }
async fn phone_cannot_write_mac_only_columns(pool) { /* ios update threads.continuity and insert into turns → rejected with column_not_writable; acceptedThrough covers them; mac's push of the same works */ }
async fn push_clamps_a_clock_far_ahead(pool) { /* ios hlc = now + 1h → stored hlc millis <= now + 1s */ }
async fn connection_secrets_are_scrubbed_even_if_sent(pool) { /* mac inserts connection with target "/usr/bin/codex", authReference "secret:x" → hub row has both NULL; update of target → NULL */ }
async fn owner_is_the_latest_inserter(pool) { /* mac A inserts thread; mac B (rejoin) re-inserts → owner_device_id == B; ios update does not change owner */ }
async fn oversized_value_is_rejected_not_413(pool) { /* 3 MiB value → 200 with rejected payload_too_large */ }
async fn fixture_changes_still_decode_and_apply(pool) { /* existing test over Tests/Fixtures/sync/changes.json, now with hlc fields and the new entries */ }
```

`changes.json` gains `hlc` on every entry plus: a phone `threads.title` update, an older phone title update that must lose, a `drafts` update setting `text` to `""`, and a `threads.readTurnId` update. Update the Swift decode test in the same commit (`Tests/WorkspaceSyncTests/WireFixtureTests.swift` or its M8a equivalent) to expect `hlc`.

- [ ] **Step 2: Run** `cargo test --workspace --locked` — FAIL.
- [ ] **Step 3: Implement**; regenerate `Hub/.sqlx` offline metadata (`cargo sqlx prepare --workspace`).
- [ ] **Step 4: Run** the three cargo gates and `swift test --filter WorkspaceSyncTests` — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(hub): clocks and last-writer-wins, ownership, phone write rule, per-change rejection"`

---

### Task 6: Hub pages, pruning, snapshot, devices, and the role check

**Files:**
- Create: `Hub/crates/b4hub-db/src/prune.rs`, `Hub/crates/b4hub-db/src/snapshot.rs`, `Hub/crates/b4hub/src/routes/snapshot.rs`
- Modify: `Hub/crates/b4hub-db/src/changes.rs` (byte-limited `pull`; `HORIZON` constant replaced by `org_sync_horizons`), `Hub/crates/b4hub-db/migrations/0003_organisation.sql` (add `org_sync_horizons(org_id uuid PK REFERENCES orgs, horizon bigint NOT NULL DEFAULT 0)`, RLS), `Hub/crates/b4hub-db/src/migrate.rs` (`connected_role_is_privileged` follows role membership), `Hub/crates/b4hub/src/{serve.rs, cli.rs, routes/changes.rs, routes/devices.rs}`, `Hub/API.md`
- Test: `Hub/crates/b4hub-db/tests/{changes.rs, migrate.rs}`, `Hub/crates/b4hub/tests/changes.rs`

**Interfaces:**
- Produces: `pull` stops at 1000 rows or `MAX_PAGE_BYTES = 8 * 1024 * 1024` summed `value_bytes`, at least one row, `more = true` when stopped early. `prune::prune(db, org_id, older_than: Duration) -> Result<i64 /*new horizon*/>` deletes `changes` with `hub_seq <= horizon` where horizon = max `hub_seq` older than the cutoff, and records it. A pull with `after < horizon` → 410 `resync_required`. `GET /v1/snapshot` → `{ "changes": [StoredChange as synthetic inserts with hubSeq = 0, deviceId = owner, hlc = max clock of the row], "clocks": [{"table","rowId","column","hlc"}], "next": i64 }` read in one `REPEATABLE READ` transaction, scoped to the user, tables in dependency order. `GET /v1/devices` → `{ "devices": [{ "id", "name", "platform", "lastSeenAt", "revokedAt" }] }` for the authenticated user. `serve` runs a prune task every 24 h for every org with `B4HUB_RETENTION_DAYS` (default 30; a non-integer is a configuration error, exit 2). `b4hub prune --older-than-days N [--org slug]` runs it once (admin URL). `connected_role_is_privileged` is true when the role, or any role it is a member of with `INHERIT`, is superuser, `BYPASSRLS`, or owns a hub table (`pg_has_role(current_user, r.oid, 'USAGE')` over `pg_roles`).

- [ ] **Step 1: Failing tests**

```rust
async fn pages_stop_at_eight_mib(pool) { /* five 2 MiB-ish values → first page has 4 rows (≤ 8 MiB) and more == true; a single 9 MiB-row case is impossible (2 MiB cap) so also assert a page of 1001 tiny rows stops at 1000 */ }
async fn stale_cursor_gets_resync_and_snapshot_restores(pool) { /* push 10, prune with cutoff after all → pull after=3 → 410; snapshot → rows equal materialised tables, next == max hub_seq; pull after=next → empty */ }
async fn snapshot_is_user_scoped(pool) { /* second user's rows absent */ }
async fn devices_lists_the_users_devices(pool) { /* two devices, one revoked → both listed, revokedAt set on one; other user's devices absent */ }
async fn serve_refuses_a_role_that_inherits_superuser(pool) { /* CREATE ROLE weak LOGIN; GRANT postgres TO weak → connected_role_is_privileged == true */ }
```

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement**; add `snapshot` and `devices` routes in `serve::router`; document both and the new response fields in `Hub/API.md`. **Step 4: Run** the three cargo gates — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(hub): byte-limited pages, pruning with snapshot resync, devices list, inherited-role check"`

---

### Task 7: Wire types and the fake hub (WorkspaceSync)

**Files:**
- Modify: `Sources/WorkspaceSync/{Wire.swift, HubAPI.swift, HTTPHubAPI.swift, FakeHubAPI.swift}`
- Test: `Tests/WorkspaceSyncTests/` (existing files plus `FakeHubWritesTests.swift`)

**Interfaces:**
- Produces: `SyncChange.hlc: String?` and `StoredChange.hlc: String` (decode a missing `hlc` on `StoredChange` as the derived form so an old fixture still reads); `PushResponse.rejected: [RejectedChange]` (`deviceSeq: Int`, `code: String`, default `[]`); `SnapshotResponse { changes: [StoredChange]; clocks: [ColumnClock]; next: Int }`, `ColumnClock { table, rowId, column, hlc }`; `DeviceInfo { id, name, platform, lastSeenAt: String?, revokedAt: String? }`. `HubAPI` gains `snapshot() async throws -> SnapshotResponse` and `devices() async throws -> [DeviceInfo]`. `FakeHubAPI`: `me()` echoes the last enroll request's `deviceName` and `platform`; `push` applies `SyncColumns` rejection for a fake device whose platform is not `macos` (`setPlatform(_:)`), returning `rejected`; `setSnapshot(_:)`, `setDevices(_:)`, and `setFailNext` for `resync_required` keep working.

- [ ] **Step 1: Failing tests** — `meEchoesTheEnrollRequest`, `pushReportsRejectedPhoneColumns`, `storedChangeWithoutHlcDerivesOne`, `httpHubAPIDecodesSnapshotAndDevices` (with the existing `URLProtocol` stub).
- [ ] **Step 2: Run** `swift test --filter WorkspaceSyncTests` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(sync): clocks, rejections, snapshot and devices on the wire; the fake hub echoes me()"`

---

### Task 8: The coordinator pulls (`applyRemote`, `HubPull`)

**Files:**
- Create: `Sources/WorkspaceStorage/RemoteApply.swift`, `Sources/Coordinator/HubSync/HubPull.swift`
- Modify: `Sources/WorkspaceStorage/ChangeLog.swift` (`replay` gets a savepoint per change and skips a failing one), `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`HubLink.cursor` read and `setHubCursor(_:)`), `Sources/Coordinator/HubSync/HubSync.swift` (start and stop `HubPull`; `drain` handles `rejected`; stamp `hlc` on `SyncChange`), `Sources/Coordinator/HubSync/SyncFilter.swift` (pass `hlc` through; `projects`, `projectFolders` allowed)
- Test: `Tests/WorkspaceStorageTests/RemoteApplyTests.swift`, `Tests/CoordinatorTests/HubPullTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 7.
- Produces: `WorkspaceDatabase.applyRemote(_ changes: [RemoteChange], ownDeviceId: String, macDeviceIds: Set<String>, cursor: Int) throws -> RemoteApplied` where `RemoteChange { deviceId, hlc, table, rowId, op, column, value }` and `RemoteApplied { touchedThreadIds: Set<String>, touchedProjectIds: Set<String>, touchedDraftThreadIds: Set<String>, applied: Int, skipped: Int }`; one transaction with `b4app.replaying = 'on'`, advancing `hubLink.cursor` to `cursor`. Rules (the spec's "narrow merge"): skip changes from `ownDeviceId` and from any id in `macDeviceIds`; accept only updates of `SyncColumns.phoneWritable` columns on existing `threads`/`projects` rows, and inserts or updates of `drafts` whose thread exists; each accepted column applies only if its `hlc` is greater than `columnClocks`, then advances the clock; the database's `clock.observe` is called with every received `hlc`. `HubPull` (actor): long-poll loop like `MirrorSync` (`limit` 1000, `wait` 25, backoff 2 s → 60 s), refreshes `devices()` at most once a minute to know `macDeviceIds` (`platform == "macos"`), on `resync_required` fetches `snapshot()` and runs its changes and clocks through `applyRemote` from `next`, and after each batch publishes `thread.updated` per touched thread, `project.changed` per touched project, and a `thread.updated` for a touched draft's thread. `HubSync.drain` counts `rejected` in `hubLink.lastError` (`"2 changes refused by the hub: column_not_writable"`) and still marks them synced.

- [ ] **Step 1: Failing tests**

```swift
@Test func remoteTitleAppliesAndOlderLoses() throws { /* local title at hlc L; remote title at L+1 applies; remote at L-1 skipped */ }
@Test func remoteRowsNeverOverwriteLocalMacColumns() throws {
  /* local connection with target and a thread with nativeScope "/x"; applyRemote of a snapshot-like insert carrying target "" and nativeScope "scope:…" from an old mac device id → both unchanged (builder-check call 1) */
}
@Test func ownAndOtherMacChangesAreSkipped() throws { /* … */ }
@Test func remoteDraftInsertCreatesTheRow() throws { /* phone inserts drafts row for an existing thread → draft text visible; for a missing thread → skipped */ }
@Test func replaySkipsAMissingParentInsteadOfFailing() throws { /* a turns insert whose thread is absent, between two good changes → 2 applied */ }
@Test func pullAppliesPhoneEditsAndPublishes() async throws { /* FakeHubAPI with an ios device's title update → database title changes, thread.updated observed, hubLink.cursor advanced */ }
@Test func staleCursorResyncsFromSnapshotWithoutLosingLocalRows() async throws { /* setFailNext resync_required → snapshot applied; local connection target intact */ }
@Test func rejectedChangesAreRecordedAndDoNotStall() async throws { /* fake rejects one → markSynced through all, lastError names the count */ }
```

- [ ] **Step 2: Run** `swift test --filter "RemoteApplyTests|HubPullTests|HubSyncTests"` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS, plus `swift test --filter CoordinatorTests`.
- [ ] **Step 5: Commit** — `git commit -m "feat(coordinator): pull other devices' edits with a narrow last-writer-wins merge"`

---

### Task 9: The mirror's schema v2, outbox, clocks, and activity (WorkspaceMirror store)

**Files:**
- Create: `Sources/WorkspaceMirror/MirrorMigrations.swift`, `Sources/WorkspaceMirror/MirrorWrites.swift`
- Modify: `Sources/WorkspaceMirror/MirrorSchema.swift` (version 2), `Sources/WorkspaceMirror/MirrorStore.swift`
- Test: `Tests/WorkspaceMirrorTests/MirrorMigrationTests.swift`, `MirrorWritesTests.swift`, `MirrorActivityTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3 (types), 7 (wire).
- Produces: `MirrorSchema.migrations: [(version: Int, statements: [String])]`; v2 adds `projects`, `projectFolders`, `devices("id" TEXT PK, "name", "platform", "lastSeenAt", "revokedAt")`, `outbox`, `columnClocks`, `threads."projectId"`, `threads."readTurnId"`, and an `ownerDeviceId TEXT` column on `connections`, `threads`, `projects`. `MirrorStore.init(path:)` migrates forward in one transaction; when the file's `user_version` is newer than known or a migration throws, it throws `MirrorStoreError.needsRebuild(outboxEmpty: Bool)`; `MirrorStore.rebuild(path:)` deletes and recreates the file (the host calls it only when `outboxEmpty`). `apply` honours `columnClocks` for `SyncColumns.clocked` (same rule as Task 8), sets `ownerDeviceId` from an insert's `deviceId`, observes every `hlc` on the store's `HybridClock`, and its `AppliedBatch` adds the `threadId` of every touched `turns` and `runtimeRequests` row to `touchedThreadIds` and gains `touchedProjectIds`. `threads(…)` and `thread(id:)` fill `activity` with SQLite queries equivalent to Task 3, and `ownerDeviceName` from `ownerDeviceId` joined to `devices`. Local writes (`MirrorWrites.swift`): `updateThread(id:title:pinned:archived:) -> ConversationThread?`, `markRead(threadId:turnId:)` (same guard as Task 3), `saveDraft(threadId:text:) -> Draft`, `renameProject(id:name:) -> Project?`, each applying to the mirror, stamping one `clock.next()`, updating `columnClocks`, and appending outbox rows; `outbox(limit:) -> [SyncChange]`, `removeOutbox(through deviceSeq: Int)`, `outboxCount: Int`; `projects() -> [Project]`, `devices() -> [DeviceInfo]`, `saveDevices(_:)`, `applySnapshot(_: SnapshotResponse)` (clears rows except `outbox`, applies changes and clocks, sets cursor to `next`).

- [ ] **Step 1: Failing tests**

```swift
@Test func v1FileMigratesInPlaceKeepingRowsAndCursor() throws { /* create a v1 file with M8a's DDL and fixture rows → open → user_version 2, rows and cursor intact */ }
@Test func failedMigrationWithPendingEditsKeepsTheFile() throws { /* v3 file with an outbox row → init throws needsRebuild(outboxEmpty: false); file untouched (Review Focus 5) */ }
@Test func activityMatchesTheSharedFixture() throws { /* attention.json applied as inserts → bands and order equal expected */ }
@Test func localEditAppliesAtOnceAndQueues() throws { /* updateThread(title:) → thread(id:).title changed, outbox has one change with hlc and deviceSeq 1 */ }
@Test func pulledOlderEditLosesToALocalEdit() throws { /* local title at clock C; apply a stored update at C-1 → title unchanged */ }
@Test func ownChangeComingBackIsANoOp() throws { /* push then apply the same change as StoredChange → no visible change, no duplicate */ }
@Test func turnsAndRequestsTouchTheirThread() throws { /* apply a turns insert → touchedThreadIds contains its threadId */ }
@Test func renameProjectToEmptyShowsFolderName() throws { /* Review Focus 4, mirror side */ }
@Test func snapshotKeepsTheOutbox() throws { /* outbox row, applySnapshot → rows replaced, outbox intact, cursor == next */ }
```

- [ ] **Step 2: Run** `swift test --filter WorkspaceMirrorTests` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(mirror): schema v2 migrations, outbox, column clocks, activity"`

---

### Task 10: The mirror syncs and answers writes (MirrorSync, MirrorTransport, iOS host)

**Files:**
- Modify: `Sources/WorkspaceMirror/MirrorSync.swift`, `Sources/WorkspaceMirror/MirrorTransport.swift`, `Apps/iOS/B4App/MirrorHost.swift`
- Test: `Tests/WorkspaceMirrorTests/MirrorSyncTests.swift`, `MirrorTransportTests.swift` (additions)

**Interfaces:**
- Consumes: Task 9.
- Produces: `MirrorSync` pushes the outbox (`outbox(limit: 500)`) before each pull and after a local write (`MirrorSync.nudge()`), removes through `acceptedThrough`, records `rejected` like Task 8, refreshes `devices()` at most once a minute, and on `resync_required` calls `snapshot()` then `applySnapshot` (replacing M8a's `clearRows()`). `MirrorTransport` answers `thread.update`, `draft.save`, `thread.markRead`, `project.list`, `project.rename` from `MirrorWrites`, emits `thread.updated` / `project.changed` for its own writes, then calls an `onLocalWrite` closure the host wires to `MirrorSync.nudge()`; `project.create|update|delete` throw `unsupportedCapability` naming "the Mac"; `thread.create`, `turn.*`, `request.respond` keep naming M8c. `publish` emits `project.changed` for `touchedProjectIds` and `thread.updated` for the widened `touchedThreadIds`. `diagnostics.read`'s `sync` section gains `pendingUploads: Int` and `refusedUploads: Int` (additive optional fields on `SyncDiagnostic`). `MirrorHost` handles `needsRebuild(outboxEmpty: true)` by rebuilding and starting from a snapshot, and `outboxEmpty: false` by showing the error in Diagnostics and not syncing.

- [ ] **Step 1: Failing tests** — `outboxIsPushedThenPulledBack`, `offlineEditsWaitAndDrainWhenTheHubReturns` (fake `setFailNext` transport errors twice), `resyncUsesTheSnapshot`, `transportRenamesAndPublishes`, `transportRefusesProjectCreateNamingTheMac`, `diagnosticsCountsPendingUploads`. Use the 30 s `eventually` helper from PR #19's version of `MirrorSyncTests` (merge `main` first if #19 has landed; otherwise copy its rule).
- [ ] **Step 2: Run** `swift test --filter WorkspaceMirrorTests` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS; `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` after `./Scripts/generate-project.sh`.
- [ ] **Step 5: Commit** — `git commit -m "feat(mirror): push the outbox, resync from a snapshot, answer the phone's writes"`

---

### Task 11: The model: attention order, projects, read marking (WorkspaceUI model)

**Files:**
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift`
- Test: `Tests/WorkspaceUITests/WorkspaceModelTests.swift` (additions), `Tests/WorkspaceUITests/AttentionModelTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4 (commands and events).
- Produces on `WorkspaceModel`: `projects: [Project]` (loaded with threads, refreshed on `project.changed`); `projectFilter: ProjectFilter` (`.all`, `.project(String)`, `.other`, `.archived`); `orderedThreads: [ConversationThread]` (search, connection filter, project filter, then `Attention.ordered`, pinned first); `pinnedThreads` and `projectSections: [ProjectSection]` (`ProjectSection { id: String /* project id or "other" */, title: String, threads: [ConversationThread] }`, sections ordered by their best thread's band then its `lastActivityAt`, excluding pinned threads, which only appear in `pinnedThreads`); `band(of:) -> AttentionBand` and `reasonLine(for:) -> String` ("Waiting for your approval" / "Has a question for you" by request kind, "Replied 3m ago", "Failed 3m ago", "Working", "Read"); `markUnread(id:)` (sends `thread.markRead` with `turnId: nil`); `renameProject(id:name:)`, `createProject(name:folders:)`, `addFolder(projectId:path:)`, `deleteProject(id:)`. Read marking: when `openThread(id:)` loads a detail whose latest terminal turn differs from `readTurnId`, and when a `turn.finished` event arrives for the open thread, the model sends `thread.markRead` once per turn id. Activity updates: on `turn.*`, `runtime_request.*`, and `thread.updated` events the model refetches that thread (`thread.read`) so its `activity` is current. The open thread's draft reloads on `thread.updated` when `composerText` has not changed in the last 2 s (the "composer not focused" rule, my plan-level call). The old `filtered(archived:)` sort by `updatedAt` is removed; `visibleThreads`/`archivedThreads` become `orderedThreads` with the archived filter.

- [ ] **Step 1: Failing tests** (with the existing fake transport helpers)

```swift
@Test func ordersPinnedThenBandsThenActivity() async throws { /* threads with activity from attention.json → orderedThreads ids == expected order */ }
@Test func projectSectionsExcludePinnedAndRiseWithUrgency() async throws { /* project with a needsInput thread sorts first; pinned thread not in any section */ }
@Test func openingAnUnreadThreadMarksItRead() async throws { /* openThread → transport saw thread.markRead {threadId, turnId: latest} once; opening again sends nothing */ }
@Test func aReplyArrivingWhileOpenIsMarkedRead() async throws { /* turn.finished for open thread → one markRead */ }
@Test func projectFilterNarrowsTheList() async throws { /* .project(P) shows only P's threads; .other shows projectId nil; .archived shows archived */ }
@Test func remoteDraftReloadsOnlyWhenIdle() async throws { /* composerText edited 0.5 s ago → not replaced; after 2 s → replaced */ }
```

- [ ] **Step 2: Run** `swift test --filter "WorkspaceModelTests|AttentionModelTests"` — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(ui): attention order, projects, and read marking in the model"`

---

### Task 12: The lists and project sheets (WorkspaceUI views)

**Files:**
- Create: `Sources/WorkspaceUI/ThreadListView.swift`, `Sources/WorkspaceUI/ProjectSheets.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceRootView.swift` (`SidebarView` uses `ThreadListView`; `ThreadRow` shows the status dot, project name, and reason line; context menu adds "Mark as Unread"), `Sources/WorkspaceUI/ThreadsView.swift` (header shows "on <device name>" when the transport reports one — see below), `Sources/WorkspaceUI/NewThreadSheet.swift` (shows the chosen folder's project or "New project"), `Sources/WorkspaceUI/DiagnosticsView.swift` (pending and refused uploads)
- Test: `Tests/WorkspaceUITests/SnapshotTests.swift` (new cases), `Tests/WorkspaceUITests/IdealSizeTests.swift` (still passes)

**Interfaces:**
- Consumes: Task 11.
- Produces: `ThreadListView(model:)` renders, on macOS, a "Pinned" section then a collapsible section per `projectSections` entry (`DisclosureGroup`-style header with the project title and a thread count; collapsed ids in `@SceneStorage("collapsedProjects")` as a comma-joined string); header context menu: Rename…, Add Folder…, Delete Project (manual only); a "New Project…" row at the end. On iOS (`#if os(iOS)`), a flat list of `pinnedThreads + orderedThreads` with a filter `Menu` in the toolbar (All projects, each project's `displayName` in `projects` order by latest activity, Other when present, Archived, then the connection choices below a divider) and swipe actions Pin/Unpin, Archive, Mark as Unread. Status dot: an 8 pt circle in the band colour (Global Constraints), with an accessibility label of the band name. No band headings. "on <device>" in the thread header and a connection's detail reads `ConversationThread.ownerDeviceName` (Task 1), which only the mirror fills (Task 9, from `ownerDeviceId` and its `devices` table); on the Mac it is nil and nothing is shown.

- [ ] **Step 1: Snapshot cases** (`B4APP_SNAPSHOT_DIR` opt-in as today): `macSidebarGroupsByProject`, `macSidebarCollapsedProject`, `iosListFlatWithFilter`, `iosListFilteredToProject`, `rowShowsEachBandDot`. They render without crashing in the default run and write PNGs when the variable is set.
- [ ] **Step 2: Run** `swift test --filter "SnapshotTests|IdealSizeTests"` — FAIL (views missing). **Step 3: Implement** within LLA (`LLAFont`, `LLA.Space`, `LLA.Color`); keep `ScrollView` + stacks in the Mac sidebar (the `List` problem noted in `SidebarView`), and no `.frame(maxHeight: .infinity)` inside split-view columns. **Step 4: Run** — PASS; render with `B4APP_SNAPSHOT_DIR=$TMPDIR/snaps` and look at the PNGs.
- [ ] **Step 5: Commit** — `git commit -m "feat(ui): attention-ordered lists, project sections and filter, status dots, project sheets"`

---

### Task 13: Documentation, full gates, and the live exit

**Files:**
- Modify: `docs/decisions.md` (new 2026-11-01 block: D-047 projects and attention order; D-048 clocks, the phone-writable list, the narrow merge, ownership and the platform write rule; D-049 pruning, snapshot, byte-limited pages; amend D-043's limits and D-046's "Unimplemented behaviour" sentence by a short "Amended by D-048" note rather than rewriting them), `docs/milestones.md` (M8b items with `implemented` / `fixture-tested` / `live-tested`; move the fixed M8a known limitations), `docs/verification.md` (the live run's table), `docs/compatibility.md` (hub API additions; minimum client protocol unchanged at 1), `Hub/API.md` (final check), `AGENTS.md` (only if a module rule changed)
- Test: none new.

- [ ] **Step 1: Full gates.** `swift format lint --strict --recursive Sources Tests Apps Package.swift`; `swift build`; `swift test`; from `Hub/` the three cargo gates; `./Scripts/generate-project.sh`; both `xcodebuild build` commands. Expected: all pass.
- [ ] **Step 2: Hub.** From `~/repos/b4app/Hub` with `DOCKER_HOST=unix://$HOME/.docker/run/docker.sock` and a throwaway `DOCKER_CONFIG` containing `{}`: `docker compose build && docker compose up -d` from the branch's `Hub/` (copy `~/repos/b4app/Hub/.env` beside it if building from the worktree, then bring the main checkout's stack down first so one stack owns the volume). Expected: `curl localhost:8080/readyz` shows `"migrations":"current"`.
- [ ] **Step 3: Mac.** Rebuild the packaged app from the branch: `./Scripts/package.sh`, quit the app, `agent-workspace coordinator restart`, reopen. Expected: `agent-workspace hub status` shows `unsynced 0`, and `agent-workspace coordinator status` shows a pid started after the restart.
- [ ] **Step 4: Simulator.** Build and install the iOS app on the iPhone 17 Pro Simulator (enrollment survives). Run the spec's M8b exit items 1 and 2 with a fixture approval (or a real Codex command approval) and record each with timings; then item 3, the live convergence run: stop the hub (`docker compose stop hub`), rename the same thread and edit the same draft on both (the Mac's edit later), start the hub, and confirm both show the Mac's values. Screenshot the Simulator list and the Mac sidebar into the PR description.
- [ ] **Step 5: Restore.** Bring the stack back up from `~/repos/b4app/Hub` on `main` after the PR merges, and rebuild the packaged app from `main` with the same dev loop. Until then, leave the branch build running and say so in the PR.
- [ ] **Step 6: Commit and PR.** `git commit -m "docs: M8b decisions, milestones, verification"`; push; `gh pr create --base main` with the exit evidence and the decisions list; end the body with the attribution line.
