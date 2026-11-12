# Arrangements and synced view settings: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sidebar has two arrangements, "Needs you first" and "By environment", a setting for how threads that don't need you are drawn, and "Show archived"; all three are stored per account on the hub and apply on every device.

**Architecture:** The three settings live in one new synced table, `viewSettings`, with a single row per account. It travels through the existing change log exactly as `drafts` does (a phone may insert and write it; every column merges by hybrid clock), so offline edits and conflicts need no new mechanism. `WorkspaceUI` reads and writes it through `WorkspaceClient` (the coordinator on the Mac, the mirror on the phone). The list is rebuilt from a pure `ListLayout` value computed from the threads, the environments, and the settings; the Mac's "Pinned" group and the phone's environment filter go away.

**Tech stack:** Rust hub (one migration, table spec, writable columns), PostgreSQL store migration, the phone's SQLite mirror schema, the shared fixture `Tests/Fixtures/sync/changes.json`, Swift (`WorkspaceProtocol`, `Coordinator`, `WorkspaceMirror`, `WorkspaceUI`).

**Spec:** `docs/superpowers/specs/2026-11-10-thread-list-and-environments-design.md` ("Two arrangements", "Settings sync", "Sidebar chrome" for the view-options menu, "Builder's calls" for pinning). This is plan 4 of 6; it builds on plan 3 (D-204, `ThreadState`, `ThreadMark`, `ThreadRow`, `ArrivalTracker`, the view-options button) and must start from a tree that has it.

## Global constraints

- No backwards compatibility: the Mac's "Pinned" group, the phone's environment filter, and per-device storage of these three settings are removed, not kept beside the new ones.
- Never edit an applied migration (D-178). One new migration in each store: the hub's `0019_view_settings.sql`, the coordinator's `0013_view_settings.sql`, and mirror schema version 8.
- `Tests/Fixtures/sync/changes.json` changes only together with both suites that decode it. The hub's `PHONE_WRITABLE` / `CLOCKED` lists and Swift's `SyncColumns` change together.
- The stored value is never rewritten by a device that falls back. A device shows its fallback and leaves the row alone.
- What the composer remembers (last place, runtime, model) and which groups are collapsed stay per device.
- Shape and order carry meaning; colour rules from plan 3 are unchanged. Text never blinks. With Reduce Motion on, nothing new animates.
- All measurements are points on a 4 pt grid: 24 between the top list and the lower list, 8 between groups, 28 pt rows and headings on the Mac, 44 pt minimum on the phone. No uppercase.
- The badge and notifications do not change.
- `WorkspaceUI` talks only to `WorkspaceClient`. Secrets never appear in arguments, results, or logs.
- Before each commit: `swift build`, the task's tests, `swift format lint --strict --recursive Sources Tests Apps Package.swift`; hub tasks also `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` from `Hub/`; UI tasks also build both apps.
- Decision and verification files follow AGENTS.md; take the decision number with `Scripts/docs-index.sh --next` when the pull request opens.

## Planner's decisions

1. **One row.** Table `viewSettings`, key `id`, the row's id is always the literal `view`. Columns: `id`, `arrangement`, `quietThreads`, `showArchived`, `updatedAt`.
2. **Values.** `arrangement`: `needsYouFirst` (default) or `byEnvironment`. `quietThreads`: `small` (default), `tiny`, `collapsed`, `hidden`. `showArchived`: boolean, default false. A missing row, a null column, or a value this build does not know reads as the default; an unknown value is left in the row untouched.
3. **Who writes.** Any device. The phone may insert the row (as it may insert a draft) and write `arrangement`, `quietThreads`, `showArchived`, and `updatedAt`; all four merge by clock. The row is never deleted.
4. **One row per org on the hub.** The hub keys synced rows by `(org_id, key)` and applies an upsert only for the row's own user, so in an org with several users only the first user's `view` row is stored and the others' devices do not sync these settings with each other. Every account today is a single-user org. This is recorded as a known limit; lifting it needs a per-user key.
5. **Fallbacks.** A table in code (`ViewSettings.shown(on:)`): `tiny` shows as `collapsed` on the phone; everything else shows as stored. The phone's menu lists Tiny with the note "Shown collapsed on this device".
6. **"Needs you first".** Top list (approve, reply, failed, finished; newest first inside each), a 24 pt gap, then the lower list (working, then quiet, newest first) drawn per `quietThreads`. A pinned thread sorts first within its own state; there is no Pinned group.
7. **Lower list modes.** Small: plan 3's rows. Tiny (Mac): 20 pt rows, 11 pt type, 8 pt marks. Collapsed: one row, "9 more, 2 working" (the count of stowed threads; ", N working" and the orbit mark only when something is running); activating it opens the lower list in place, and it closes again when the pointer leaves the sidebar on the Mac, or on a second tap on the phone. Hidden: nothing below the top list except, while agents are running, one muted row pinned above the profile footer, "2 working" with the orbit; activating it shows those working threads in place. Collapsed and Hidden stow working threads too.
8. **"By environment".** One heading per environment that has live threads, then its threads in state order; "No folder" last. Groups sort by name (case-insensitive, then id); the order does not change with thread states. A collapsed group shows its most urgent thread's mark at the trailing edge. `quietThreads` does not apply; the menu shows it disabled.
9. **Headings.** A 28 pt row (44 on the phone), the name at 12 pt, weight 500, muted. On the Mac, hovering turns it ink and shows a collapse chevron beside the name and a new-thread button at the right, which opens the composer with that environment (or "No folder") preselected. The edit button waits for the environment-form plan. On the phone, a tap collapses or expands; a long press offers "New thread here".
10. **Archived.** With "Show archived" on, archived threads are a final block after a 24 pt gap, in both arrangements, newest first, with no heading.
11. **The menu.** View options, top to bottom: Arrange (Needs you first, By environment), Threads that don't need you (Small, Tiny, Collapsed, Hidden), Show archived, Connections (today's connection filter). The phone's menu is the same and loses its environment filter; `EnvironmentFilter` is deleted.
12. **Writes are optimistic.** The UI shows the new value at once and sends it; a refused write puts the old value back and shows the existing sidebar error line.
13. **Collapsed groups** stay in `collapsedEnvironments` (per device), as today.

## Review focus

1. Two devices change different settings while offline: both changes survive (per-column clocks). They change the same one: the later clock wins on every device. Tasks 1–3.
2. A device on an older build, or a value from a newer one (`quietThreads: "micro"`): reads as the default, is not rewritten, and nothing fails to decode. Tasks 2 and 4.
3. Tiny stored from the Mac: the phone shows Collapsed, and changing another setting on the phone leaves `tiny` in the row. Tasks 3 and 4.
4. Collapsed and Hidden never hide a thread that needs the user: a stowed thread that becomes approve, reply, failed, or finished appears in the top list at once (and traces). Task 5.
5. Empty cases: no threads; only quiet threads with Hidden (an empty list with no dead space and no "0 working"); an environment whose threads are all archived (no heading). Tasks 5 and 6.

---

### Task 1: The hub stores and relays `viewSettings`

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0019_view_settings.sql`
- Modify: `Hub/crates/b4hub-core/src/change.rs` (table list and `TableSpec`s), `Hub/crates/b4hub-core/src/writable.rs`, `Hub/crates/b4hub-db/src/changes.rs` (`refusal`: a phone may insert into `viewSettings`), `Hub/crates/b4hub-db/src/accounts.rs` (the table list near line 752 used when an account is removed or merged), `Hub/crates/b4hub-db/tests/migrations_frozen.rs`, `Hub/API.md`
- Modify: `Tests/Fixtures/sync/changes.json`
- Test: `Hub/crates/b4hub-db/tests/changes.rs`, the hub test that reads `changes.json`, `Hub/crates/b4hub-db/tests/rls.rs`

**Interfaces:**
- Produces: hub table `"viewSettings"` (`"id" text`, `"arrangement" text`, `"quietThreads" text`, `"showArchived" boolean`, `"updatedAt" text`, plus the tenancy and soft-delete columns every synced table has; primary key `(org_id, "id")`; row-level security as `drafts`). `PHONE_WRITABLE` and `CLOCKED` gain `("viewSettings", c)` for `id`, `arrangement`, `quietThreads`, `showArchived`, `updatedAt`.

- [ ] **Step 1: Write the failing tests** in `changes.rs`:

```rust
async fn a_phone_may_insert_and_update_view_settings(pool: PgPool)
async fn view_settings_columns_merge_by_clock(pool: PgPool)        // older hlc on quietThreads loses; a newer one on arrangement from another device wins; both survive
async fn a_mac_and_a_phone_both_inserting_view_end_with_one_row(pool: PgPool)
async fn view_settings_are_pulled_by_the_users_other_devices(pool: PgPool)
async fn a_phone_may_not_delete_view_settings(pool: PgPool)
async fn another_org_never_sees_view_settings(pool: PgPool)        // in rls.rs
```

- [ ] **Step 2: Run them; expect failures** (`cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --locked view_settings`).
- [ ] **Step 3: Write the migration**, modelled on `drafts` in `0002_sync.sql` and every later migration that touched all synced tables (soft delete in `0009`, owned rows, any per-table lists in functions): `viewSettings` must have each column and policy those gave `drafts`. Pin the file in `migrations_frozen.rs`.
- [ ] **Step 4: Add the table spec, the writable and clocked columns, the phone-insert rule, and the account table list.**
- [ ] **Step 5: Fixture.** Append to `changes.json` an insert of the `view` row from a Mac and an `update` of `quietThreads` from a phone; update the hub test that decodes the fixture and its counts.
- [ ] **Step 6: `API.md`.** Add `viewSettings` to the synced tables, its columns, and the phone-writable list; state decision 4's limit.
- [ ] **Step 7: Run** the whole hub suite, `cargo fmt`, `cargo clippy`; expect all pass. (The Swift suites that read `changes.json` are updated in Task 2; say in the report whether `swift test` was run and what failed, if anything.)
- [ ] **Step 8: Commit** `feat(hub): sync a per-account view settings row`.

### Task 2: The coordinator's store and the wire type

**Files:**
- Create: `Sources/WorkspaceProtocol/ViewSettings.swift`, `Sources/WorkspaceStorage/SQL/0013_view_settings.sql`, `Sources/WorkspaceStorage/ViewSettingsStore.swift`
- Modify: `Sources/WorkspaceProtocol/HybridClock.swift` (`SyncColumns`), `Sources/WorkspaceStorage/ChangeLog.swift` (`syncedTables`), `Sources/WorkspaceStorage/Export.swift` (the archive table list), the remote-apply code that lists per-table columns, `Sources/WorkspaceProtocol/Commands.swift`, `Sources/Coordinator/Router.swift` (two methods, both in `Router.needsAccount`)
- Test: create `Tests/WorkspaceProtocolTests/ViewSettingsTests.swift`, `Tests/WorkspaceStorageTests/ViewSettingsStoreTests.swift`; update `ChangeLogTests.swift`, `RemoteApplyTests.swift`, and the Swift tests that decode `changes.json`

**Interfaces:**
- Produces:

```swift
public struct ViewSettings: Codable, Sendable, Equatable {
  public enum Arrangement: String, Codable, Sendable, CaseIterable { case needsYouFirst, byEnvironment }
  public enum QuietThreads: String, Codable, Sendable, CaseIterable { case small, tiny, collapsed, hidden }
  public var arrangement: Arrangement      // default .needsYouFirst
  public var quietThreads: QuietThreads    // default .small
  public var showArchived: Bool            // default false
  public static let rowId = "view"
  public enum Device: Sendable { case mac, phone }
  /// What this device draws for the stored values (decision 5). Never written back.
  public func shown(on device: Device) -> ViewSettings
}
```

  - Decoding is lenient per field: a missing, null, or unknown value is that field's default.
  - Commands `viewSettings.get` (no params → `ViewSettings`) and `viewSettings.set` (params: optional `arrangement`, `quietThreads`, `showArchived`; only the given fields are written → the resulting `ViewSettings`), and event `viewSettings.changed`.
  - On `WorkspaceDatabase`: `viewSettings() throws -> ViewSettings`, `setViewSettings(arrangement:quietThreads:showArchived:) throws -> ViewSettings` (inserts the `view` row when missing, writes only the given columns and `updatedAt`).

- [ ] **Step 1: Write the failing tests:**

```swift
// ViewSettingsTests
@Test func defaultsWhenEverythingIsMissing()
@Test func anUnknownValueReadsAsTheDefault()            // {"quietThreads":"micro"} → .small, no throw
@Test func tinyShowsAsCollapsedOnThePhoneOnly()
@Test func shownNeverChangesTheOtherFields()
// ViewSettingsStoreTests
@Test func readingWithNoRowGivesDefaultsAndWritesNothing()
@Test func settingOneFieldWritesOnlyThatColumn()        // the change log has one insert, then one update for that column plus updatedAt
@Test func aRemoteChangeToOneColumnKeepsTheOthers()     // remote apply: quietThreads from a phone; arrangement set locally survives
@Test func anOlderRemoteClockLoses()
@Test func anUnknownStoredValueSurvivesALocalWriteToAnotherField()
@Test func viewSettingsSurviveBackupAndRestore()
```

- [ ] **Step 2: Run them; expect a compile failure.**
- [ ] **Step 3: Migration `0013`:** the table (`"id" TEXT PRIMARY KEY`, the four columns as nullable text/boolean), its change-log trigger as `drafts` has, and the recreated `b4app_record_change()` column list with a `viewSettings` case (follow the most recent migration that recreated it, `0011_environments.sql`).
- [ ] **Step 4: Implement the type, `SyncColumns`, `syncedTables`, the store functions, the export list, and remote apply.** Publish `viewSettings.changed` from the coordinator when a local `set` or a remote apply changes the row.
- [ ] **Step 5: The two commands and the router entries.**
- [ ] **Step 6: Run** `swift test --filter "ViewSettings|ChangeLogTests|RemoteApplyTests|WorkspaceSyncTests|WorkspaceStorageTests"`; expect all pass, including the tests that decode `changes.json`.
- [ ] **Step 7: Commit** `feat(storage): the account's view settings, synced`.

### Task 3: The phone's mirror

**Files:**
- Modify: `Sources/WorkspaceMirror/MirrorSchema.swift` (version 8: the table; add it to the synced table list), `Sources/WorkspaceMirror/MirrorStore.swift` (read, optimistic write through the outbox as drafts are written), the mirror's client transport that serves `WorkspaceClient` commands (answer `viewSettings.get` / `viewSettings.set` and emit `viewSettings.changed`)
- Test: `Tests/WorkspaceMirrorTests/` (schema, outbox, and transport tests)

**Interfaces:**
- Consumes: `ViewSettings`, the command names from Task 2.
- Produces: the phone answers the same two commands and event the coordinator does.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func aFreshMirrorReadsDefaults()
@Test func settingOnThePhoneQueuesOneOutboxChangePerColumn()   // insert of the row when missing, then column updates
@Test func aPulledChangeUpdatesTheMirrorAndEmitsChanged()
@Test func tinyFromTheMacStaysTinyInTheMirror()                 // stored value is tiny; shown(on: .phone) is collapsed
@Test func changingShowArchivedOnThePhoneLeavesTinyStored()
@Test func upgradingFromVersion7KeepsExistingRows()
```

- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement schema version 8, the store functions, and the transport's two commands.**
- [ ] **Step 4: Run** `swift test --filter WorkspaceMirrorTests`; build the iOS app.
- [ ] **Step 5: Commit** `feat(mirror): view settings on the phone`.

### Task 4: The model and the view-options menu

**Files:**
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (load on connect, apply `viewSettings.changed`, the three setters, remove `showArchived` as local state and `environmentFilter`), `Sources/WorkspaceUI/EnvironmentSections.swift` (delete `EnvironmentFilter`), `Sources/WorkspaceUI/SidebarView.swift` (`MoreMenu` contents on both platforms), `Sources/WorkspaceUI/TopBar.swift` (`viewOptionsFiltered` is true only for a connection filter)
- Test: create `Tests/WorkspaceUITests/ViewSettingsModelTests.swift`; update the tests that use `environmentFilter` or `showArchived`

**Interfaces:**
- Consumes: Tasks 2 and 3's commands and event.
- Produces: `WorkspaceModel.viewSettings: ViewSettings` (the stored values), `WorkspaceModel.shownSettings: ViewSettings` (`viewSettings.shown(on:)` for this platform), `func setArrangement(_:) async`, `func setQuietThreads(_:) async`, `func setShowArchived(_:) async`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func settingsLoadOnConnect()
@Test func aChangeFromAnotherDeviceUpdatesTheModel()
@Test func aSetShowsAtOnceAndIsSent()                    // optimistic; the recorded command has only that field
@Test func aRefusedSetPutsTheOldValueBack()
@Test func thePhoneShowsCollapsedForTinyAndSendsNothing() // reading alone never writes
@Test func choosingTinyOnThePhoneStoresTiny()             // the menu lists it; the phone still shows collapsed
@Test func quietThreadsIsDisabledByEnvironment()          // a pure function the menu uses
@Test func signingOutForgetsTheSettings()
```

- [ ] **Step 2: Run them; expect a compile failure.**
- [ ] **Step 3: Implement the model members.** Changing the arrangement or "Show archived" rebases the arrival tracker (as a filter change does).
- [ ] **Step 4: Rebuild the menu** per decision 11 on both platforms. Tiny carries "Shown collapsed on this device" on the phone. Remove the environment picker and its "Edit" and "New Environment…" entries from the phone's menu only if they have another home; if they do not, keep "New Environment…" and "Edit" under a divider at the foot of the phone's menu and say so in the report (the environment-form plan moves them).
- [ ] **Step 5: Run** `swift test --filter WorkspaceUITests`; build both apps. The list still draws as before in this task, except that an environment can no longer be filtered to.
- [ ] **Step 6: Commit** `feat(ui): arrangement and quiet-thread settings in view options`.

### Task 5: "Needs you first"

**Files:**
- Create: `Sources/WorkspaceUI/ListLayout.swift`
- Modify: `Sources/WorkspaceUI/ThreadListView.swift` (draw from `ListLayout`; delete the Mac's Pinned group and `FlatThreadRows`' own ordering), `Sources/WorkspaceUI/Theme/ThreadMark.swift` and `LLATheme.swift` (the tiny metrics), `Sources/WorkspaceUI/WorkspaceModel.swift` (expose the layout)
- Test: create `Tests/WorkspaceUITests/ListLayoutTests.swift`; update `ThreadListTests.swift`, `AttentionModelTests.swift`, `SnapshotTests.swift`

**Interfaces:**
- Consumes: `shownSettings`, `Attention.ordered`, `ThreadState`, `ThreadRow`.
- Produces:

```swift
struct ListLayout: Equatable {
  struct Group: Equatable, Identifiable { var id: String; var title: String; var environmentId: String?; var threads: [ConversationThread] }
  enum Lower: Equatable {
    case rows([ConversationThread], tiny: Bool)
    case collapsed(count: Int, working: Int, threads: [ConversationThread])
    case hidden(working: [ConversationThread])
  }
  enum Body: Equatable {
    case needsYouFirst(top: [ConversationThread], lower: Lower)
    case byEnvironment([Group])
  }
  var body: Body
  var archived: [ConversationThread]     // empty unless showArchived
  static func build(threads: [ConversationThread], environments: [WorkEnvironment], settings: ViewSettings) -> ListLayout
  static func collapsedLabel(count: Int, working: Int) -> String   // "9 more", "9 more, 2 working"
  static func hiddenLabel(working: Int) -> String?                  // "2 working"; nil for 0
}
```

  - `LLA.Metrics.threadRowTiny = 20`, `markTiny = 8`, and an 11 pt row font; `ThreadRow` takes a `tiny: Bool`.

- [ ] **Step 1: Write the failing tests** in `ListLayoutTests.swift`:

```swift
@Test func theTopListIsApproveReplyFailedFinishedNewestFirst()
@Test func aPinnedThreadSortsFirstWithinItsStateOnly()
@Test func theLowerListIsWorkingThenQuiet()
@Test func collapsedStowsWorkingAndQuietAndCountsBoth()        // .collapsed(count: 9, working: 2, ...)
@Test func collapsedLabels()                                    // "9 more", "9 more, 2 working", and count 1 → "1 more"
@Test func hiddenKeepsOnlyWorkingAndIsNilLabelWithNone()
@Test func aStowedThreadThatNeedsYouIsInTheTopList()            // state change moves it; it is not in the stowed threads
@Test func archivedAreABlockOnlyWhenShown()
@Test func nothingButQuietWithHiddenIsAnEmptyBody()
@Test func tinyAppliesOnlyToTheLowerList()
```

- [ ] **Step 2: Run them; expect a compile failure.**
- [ ] **Step 3: Implement `ListLayout.build`** for the needs-you-first body and the archived block (the by-environment body returns groups in Task 6; until then build it from today's sections so the app keeps working).
- [ ] **Step 4: Draw it.** Top rows, a 24 pt gap (only when both parts are non-empty), then the lower list per its case. The Collapsed row uses the row's geometry, muted 13 pt text, the orbit mark at the trailing edge when `working > 0`, and the accessibility label of its text plus "Show threads that don't need you"; activating it shows the stowed rows beneath it until the pointer leaves the sidebar (Mac) or it is tapped again (phone). The Hidden row sits just above the profile footer on the Mac and at the foot of the list on the phone. The archived block follows a 24 pt gap.
- [ ] **Step 5: Render the snapshots** (opt-in PNGs) for Small, Tiny, Collapsed (closed and open), and Hidden, light and dark; look at each and describe them in the report.
- [ ] **Step 6: Run** `swift test --filter "ListLayoutTests|ThreadListTests|AttentionModelTests|ArrivalTrackerTests"`; build both apps.
- [ ] **Step 7: Commit** `feat(ui): the needs-you-first arrangement`.

### Task 6: "By environment"

**Files:**
- Modify: `Sources/WorkspaceUI/ListLayout.swift`, `Sources/WorkspaceUI/EnvironmentSections.swift` (replaced by `ListLayout.Group`; delete what is unused), `Sources/WorkspaceUI/ThreadListView.swift` (the heading and group views), `Sources/WorkspaceUI/WorkspaceModel.swift` (`openNewThread(environmentId:)` or its existing equivalent for a preselected place)
- Test: `Tests/WorkspaceUITests/ListLayoutTests.swift`, `ThreadListTests.swift`, `SnapshotTests.swift`

**Interfaces:**
- Consumes: Task 5's `ListLayout`, `CollapsedEnvironments` (per device), `ThreadMark`, the composer's preselected-place entry point (`NewThreadDraft(model:environmentId:)`; "No folder" is `selectNoFolder()`).
- Produces: `ListLayout.Group.mostUrgent: ThreadState?` (the first thread's state, for a collapsed heading's mark); a heading view with the hover actions of decision 9.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func groupsSortByNameAndNoFolderIsLast()
@Test func groupOrderDoesNotChangeWhenAThreadNeedsYou()
@Test func anEnvironmentWithNoLiveThreadsHasNoGroup()          // all archived, or none
@Test func threadsInsideAGroupAreInStateOrder()
@Test func aCollapsedGroupReportsItsMostUrgentState()
@Test func aThreadWhoseEnvironmentIsUnknownIsUnderNoFolder()
@Test func newThreadFromAHeadingPreselectsItsEnvironment()     // and "No folder" preselects no folder
```

- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement the by-environment body** and delete `EnvironmentSection`'s builder.
- [ ] **Step 4: Draw the groups:** 8 pt between groups; the heading per decision 9; a collapsed group shows `ThreadMark` for `mostUrgent` at the trailing edge (acknowledged only when every thread in that state is, as plan 3's collapsed header does). On the phone: tap toggles, long press offers "New thread here".
- [ ] **Step 5: Render the snapshots** for the grouped arrangement, with one group collapsed over a thread that needs approval; look at them and describe them in the report.
- [ ] **Step 6: Run** `swift test --filter "ListLayoutTests|ThreadListTests|WorkspaceUITests"`; build both apps.
- [ ] **Step 7: Commit** `feat(ui): the by-environment arrangement`.

### Task 7: Records and gates

**Files:**
- Create: `docs/decisions/D-NNN-arrangements-and-view-settings.md`, `docs/verification/YYYY-MM-DD-arrangements-and-view-settings.md`
- Modify: `docs/milestones.md`, `docs/compatibility.md` (the hub and both apps must be on this version for the settings to sync; an older hub records and skips `viewSettings` changes), `AGENTS.md` (Layout: `viewSettings` is synced; `ListLayout` builds the list)

- [ ] **Step 1: Write the decision.** One bullet in the log's style covering the thirteen planner's decisions. It amends D-048 (the Pinned group and bands in sections) and D-053 (the sidebar's sections), states the fallback table, and states decision 4's limit and what lifting it would take.
- [ ] **Step 2: Run every gate** one at a time and record each result line: `swift build`, `swift test`, the format lint, the hub's tests with `cargo fmt` and `cargo clippy`, both `xcodebuild` builds, `Scripts/docs-index.sh --check`.
- [ ] **Step 3: Record what was looked at** (the rendered snapshots by name) and what was not: the collapsed row opening and closing with a real pointer, the hidden row above the footer in the running app, two real devices syncing a setting through a hub, and the phone's menu and long press.
- [ ] **Step 4: Update `docs/milestones.md`.**
- [ ] **Step 5: Commit** `docs: record arrangements and view settings`.
