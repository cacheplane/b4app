# Density and the sidebar setting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split today's four-way "Small, Tiny, Collapsed, Hidden" into a synced density setting (normal or dense, a "Dense" switch on a new Settings → Display page) and a three-way sidebar setting (Shown, Collapsed, Hidden), with the Mac's sidebar drawing quiet rows tight when dense.

**Architecture:** The synced `viewSettings` row gains one text column, `density` (`normal`, `dense`). The existing `quietThreads` column is kept and now holds `shown`, `collapsed` or `hidden`. `ViewSettings` reads the old values leniently (`tiny` with no density is dense and shown; `small` is shown), and each store's migration also converts its stored row, so a device may be updated before or after another. The hub goes first for each flavour: a hub without the column does not store a pushed density. The list layout stops carrying row size; the views take it from the model.

**Tech Stack:** Swift (`WorkspaceProtocol`, `WorkspaceStorage`, `Coordinator`, `WorkspaceMirror`, `WorkspaceUI`), PostgreSQL migrations for the coordinator store and the hub, SQLite for the mirror, Rust for the hub.

**Spec:** `docs/superpowers/specs/2026-11-12-density-and-user-settings-design.md`, Part 2. Part 1 is pull request 187 and must be on main first. Parts 3 and 4 follow in their own plans.

## Departures from the design, for the owner to see

1. **The Display page ships on the Mac only in this part.** On the phone nothing changes with density until the dense thread (part 3), and a switch that does nothing is worse than no switch. Part 3 adds the page to the phone. The setting itself syncs to the phone now.
2. **The switch's description says only what is true in this part:** "Tighter rows for the threads that don't need you." Parts 3 and 4 extend the sentence as they land.
3. **The old values are also understood when read**, not only converted by the hub. The hub's change log keeps old entries, and a device that replays them (a newly paired phone) would otherwise read `tiny` as the default and lose "dense".
4. **"By environment" is unchanged at either density.** Its groups mix threads that need you with ones that do not, and today's Tiny does not apply there either.
5. **`quietThreads` is reused** for the three-way value; only `density` is a new column.

## Global Constraints

- Start from main with pull request 187 merged. `git fetch` first; if it is not merged, stop and report.
- Other sessions merge to main while this runs. Before each task, `git fetch` and look at `git log HEAD..origin/main` and `gh pr list` for the same files or a taken migration number; stop and report a clash. Known: draft pull request 180 holds a hub `0020` and edits hub files; another session's unmerged work has a coordinator `0014_connection_commands`.
- Migration names: hub `Hub/crates/b4hub-db/migrations/0021_density.sql`; coordinator `Sources/WorkspaceStorage/SQL/0014_density.sql`; mirror schema version 9. Never edit an applied migration (D-178). Numbers must be consecutive on main (the hub's `environment_history_controls` and the store's guard tests check it): if main has taken one of these numbers, take the next and use it everywhere.
- A hub migration leaves each table's `relforcerowsecurity` as it found it (read the flag, lift it, restore it; copy the shape of `0020_user_settings_rows.sql`).
- Stored values, exact: `density` is `normal` or `dense`; `quietThreads` is `shown`, `collapsed` or `hidden`. Defaults for a missing row, a null or an unknown value: normal, shown.
- Conversion, the same in all three stores and in the lenient read:

  | Stored `quietThreads` | `density` becomes | `quietThreads` becomes |
  |---|---|---|
  | `small` | `normal` | `shown` |
  | `tiny` | `dense` | `shown` |
  | `collapsed` | `normal` | `collapsed` |
  | `hidden` | `normal` | `hidden` |
  | null or no row | left null | left null |

  A row whose `density` is already set keeps it; only `quietThreads` is rewritten.
- `density` is phone-writable and merges by clock, like the row's other columns. The lists that name the row's columns stay equal across `SyncColumns.phoneWritable` (Swift), the coordinator's trigger function, `b4hub-core`'s `TableSpec` and `writable.rs` (both lists and its test), and `Hub/API.md`.
- `Tests/Fixtures/sync/changes.json` is not changed: it holds wire shapes, and many tests in both languages count its entries.
- A device never rewrites a stored value because it cannot draw it. After this part no such value exists: delete `ViewSettings.shown(on:)`, `ViewSettings.Device`, `WorkspaceModel.shownSettings` and the "Shown collapsed on this device" note; callers read `viewSettings`.
- `WorkspaceUI` talks only to `WorkspaceClient`. No colour beyond what the list uses, no uppercase, Reduce Motion respected. The phone's rows stay 44 pt at either density.
- Copy, exact: page title "Display"; switch label "Dense"; its description "Tighter rows for the threads that don't need you." (typographic apostrophe, `\u{2019}`); menu group "Threads that don't need you" with items "Shown", "Collapsed", "Hidden".
- Gates: `swift build`; `swift test` for the suites each task names, and the full `swift test` once in Task 6 (known machine-specific failures: `PostgresServerTests` when an installed app is present, `MirrorSyncTests` timeouts under load; report any other); `swift format lint --strict --recursive Sources Tests Apps Package.swift`; from `Hub/`, `source <(./scripts/test-db.sh) && cargo test --workspace --locked --no-fail-fast`, `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`; `Scripts/docs-index.sh --check`. Report the counts a command printed, never "all pass" from memory. One `cargo test` per checkout at a time.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.

## Review Focus

1. **A device holds or receives the old value `tiny` with no density** (a replayed log, an older build still running). Expected: it draws dense and shown, and choosing Collapsed there keeps dense. Tests in Tasks 1, 2 and 3.
2. **The owner's stored setting on each store when the migration runs.** Expected: each of the four old values converts by the table, with no entry added to the change log or outbox and no clock moved backwards. Tests in Tasks 2, 3 and 4.
3. **Two devices change different settings at once** (one sets density, the other the sidebar setting). Expected: both land; neither insert clears the other's column. Tests in Tasks 2 and 4.
4. **Dense with Collapsed or Hidden, then the stowed rows are opened.** Expected: the revealed rows, and the selected row kept out of the stow, are tight on the Mac; the top list is not. Test in Task 5.
5. **The phone with density dense.** Expected: every row is 44 pt, nothing is stowed that Shown would show, and the sidebar setting's menu has three items with no note. Test in Task 5.

---

### Task 1: the settings type

**Files:**
- Modify: `Sources/WorkspaceProtocol/ViewSettings.swift`, `Sources/WorkspaceProtocol/Commands.swift` (`ViewSettingsSet.Params`)
- Modify, to keep the build green with no change in behaviour: `Sources/WorkspaceUI/ListLayout.swift`, `Sources/WorkspaceUI/SidebarView.swift` (`ViewOptions`), `Sources/WorkspaceUI/WorkspaceModel.swift`, and any caller of the deleted API
- Test: `Tests/WorkspaceProtocolTests/ViewSettingsTests.swift`, `Tests/WorkspaceUITests/ListLayoutTests.swift`, and the UI tests that named `.small` or `.tiny`

**Interfaces:**
- Produces, in `ViewSettings`:
  - `public enum Density: String, Codable, Sendable, CaseIterable { case normal, dense }`
  - `public enum QuietThreads: String, Codable, Sendable, CaseIterable { case shown, collapsed, hidden }`
  - `public var density: Density` (default `.normal`); `quietThreads` default `.shown`
  - `public init(arrangement: Arrangement = .needsYouFirst, quietThreads: QuietThreads = .shown, showArchived: Bool = false, density: Density = .normal)`
  - `public init(arrangement: String?, quietThreads: String?, showArchived: Bool?, density: String? = nil)` — the lenient read
  - `public static func impliedDensity(storedQuietThreads: String?, storedDensity: String?) -> Density?` — `.dense` when the stored density is nil or unknown and the stored `quietThreads` is `tiny`; otherwise nil
  - `Codable`: encodes and decodes `density` beside the other three keys, leniently
- Produces, in `ViewSettingsSet.Params`: `public var density: ViewSettings.Density?`, last in the initialiser with default nil.
- Removes: `ViewSettings.shown(on:)`, `ViewSettings.Device`, `WorkspaceModel.shownSettings`, `ViewOptions.note(_:onPhone:)`.

Lenient read rule: `density` is the stored density when it is `normal` or `dense`; otherwise `impliedDensity(...) ?? .normal`. `quietThreads` is the stored value when it is one of the three; `small` and `tiny` read as `.shown`; anything else is `.shown`.

Until Task 5 the layout keeps its shape: in `ListLayout.build`, `.shown` gives `.rows(rest, tiny: settings.density == .dense)`. The phone used to turn Tiny into Collapsed; it now gets `tiny: true` rows, which the phone's list already draws at full height (confirm in `ThreadListView`'s phone branch; if it does not, pass `false` there).

- [ ] **Step 1: Write the failing tests** in `ViewSettingsTests.swift`:

```swift
@Test func oldValuesReadAsDensityAndTheSidebarSetting() {
  func read(_ quiet: String?, _ density: String? = nil) -> ViewSettings {
    ViewSettings(arrangement: nil, quietThreads: quiet, showArchived: nil, density: density)
  }
  #expect(read("small") == ViewSettings())
  #expect(read("tiny") == ViewSettings(density: .dense))
  #expect(read("collapsed") == ViewSettings(quietThreads: .collapsed))
  #expect(read("hidden") == ViewSettings(quietThreads: .hidden))
  #expect(read("shown", "dense") == ViewSettings(density: .dense))
  // A stored density wins over what an old value implies.
  #expect(read("tiny", "normal") == ViewSettings())
  #expect(read(nil) == ViewSettings())
  #expect(read("nonsense", "nonsense") == ViewSettings())
}

@Test func onlyAnUnconvertedTinyImpliesDense() {
  #expect(ViewSettings.impliedDensity(storedQuietThreads: "tiny", storedDensity: nil) == .dense)
  #expect(ViewSettings.impliedDensity(storedQuietThreads: "tiny", storedDensity: "normal") == nil)
  #expect(ViewSettings.impliedDensity(storedQuietThreads: "small", storedDensity: nil) == nil)
  #expect(ViewSettings.impliedDensity(storedQuietThreads: "collapsed", storedDensity: nil) == nil)
  #expect(ViewSettings.impliedDensity(storedQuietThreads: nil, storedDensity: nil) == nil)
}

@Test func densityRoundTripsThroughJSON() throws {
  let settings = ViewSettings(quietThreads: .hidden, density: .dense)
  let data = try JSONEncoder().encode(settings)
  #expect(try JSONDecoder().decode(ViewSettings.self, from: data) == settings)
  let old = Data(#"{"arrangement":"needsYouFirst","quietThreads":"tiny","showArchived":false}"#.utf8)
  #expect(try JSONDecoder().decode(ViewSettings.self, from: old) == ViewSettings(density: .dense))
}
```

Replace the tests of `shown(on:)` with nothing; delete them.

- [ ] **Step 2: Run** `swift test --filter ViewSettingsTests` — expected: does not compile (`density` not found).
- [ ] **Step 3: Implement** the type, the params field, and the compile-through edits. `ViewOptions.title(_:)` for the sidebar setting returns "Shown", "Collapsed", "Hidden".
- [ ] **Step 4: Update the UI tests** that used `.small` or `.tiny` to the new values with the same meaning (`.tiny` becomes `density: .dense`), and delete assertions about the phone's fallback and its note.
- [ ] **Step 5: Run** `swift build`, then `swift test --filter WorkspaceProtocolTests` and `swift test --filter WorkspaceUITests`, and the lint — expected: pass (report counts).
- [ ] **Step 6: Commit** `feat: density and a three-way sidebar setting in ViewSettings`.

---

### Task 2: the coordinator's store

**Files:**
- Create: `Sources/WorkspaceStorage/SQL/0014_density.sql`
- Modify: `Sources/WorkspaceStorage/ViewSettingsStore.swift`, `Sources/Coordinator/Router.swift` (`.viewSettingsSet`), `Sources/WorkspaceProtocol/HybridClock.swift` (`SyncColumns.phoneWritable`)
- Test: `Tests/WorkspaceStorageTests/ViewSettingsStoreTests.swift`, `OrganisationSchemaTests.swift`, `EnvironmentHistoryGuardTests.swift` (the migration count, the last name, the pending list), `RemoteApplyTests.swift`, `Tests/CoordinatorTests/CoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1's `Density`, `impliedDensity`, lenient initialiser, `Params.density`.
- Produces: `setViewSettings(arrangement:quietThreads:showArchived:density:)` on the store (new last parameter, default nil); `"density"` in `SyncColumns.phoneWritable["viewSettings"]`.

The migration, in this order:
1. `ALTER TABLE "viewSettings" ADD COLUMN "density" text;`
2. `CREATE OR REPLACE FUNCTION b4app_record_change()`: the body of `0013_view_settings.sql` copied whole, with `'density'` added to the `viewSettings` clocked list and nothing else changed.
3. The conversion by the table in Global Constraints, with `SET LOCAL b4app.replaying = 'on'` before it and `RESET` after, so no change is logged and no clock is claimed. If the migrator does not run a file in one transaction, wrap the conversion in a `DO` block that uses `set_config('b4app.replaying', 'on', true)`.

The store's write rule: when a call sets `quietThreads` and not `density`, and `ViewSettings.impliedDensity(storedQuietThreads:storedDensity:)` for the stored row is non-nil, the same statement also writes that density. A row that does not exist yet has nothing to imply.

- [ ] **Step 1: Write the failing tests** in `ViewSettingsStoreTests.swift`:
  - `densityIsStoredAndReadBack`: `setViewSettings(density: .dense)` on an empty store returns and re-reads `ViewSettings(density: .dense)`; the change log holds one insert whose value has `density` and not `quietThreads`.
  - `aSidebarChangeOnAnUnconvertedRowKeepsDense`: write the row by SQL under replay as `quietThreads = 'tiny'`, `density` null; `viewSettings()` reads dense and shown; `setViewSettings(quietThreads: .collapsed)` returns `ViewSettings(quietThreads: .collapsed, density: .dense)` and the row holds `density = 'dense'`.
  - `theMigrationConvertsEachOldValue`: for each row of the table, migrate a fresh store to 0013, insert the old row under replay, run the remaining migrations, and expect the stored texts by the table, the change log unchanged in length, and `columnClocks` unchanged.
  - In `OrganisationSchemaTests`, the existing check that the trigger's clocked lists equal `SyncColumns.clocked` must pass with `density` in both.
- [ ] **Step 2: Run** `swift test --filter WorkspaceStorageTests` — expected: the new tests fail (no `density` column or parameter).
- [ ] **Step 3: Implement** the migration, the store, `SyncColumns`, and pass `params.density` in the router.
- [ ] **Step 4: Update** `EnvironmentHistoryGuardTests` (count 14, last name `0014_density`, pending lists) and any coordinator test that lists the row's columns.
- [ ] **Step 5: Run** `swift test --filter WorkspaceStorageTests` and `swift test --filter CoordinatorTests`, and the lint — expected: pass (report counts and any failure by name).
- [ ] **Step 6: Commit** `feat(store): density column, converted from the old sidebar values`.

---

### Task 3: the phone's mirror

**Files:**
- Modify: `Sources/WorkspaceMirror/MirrorSchema.swift` (version 9, the header comment), `MirrorWrites.swift` (`setViewSettings`), `MirrorTransport.swift` (`.viewSettingsSet`), and the mirror's read of the row
- Test: `Tests/WorkspaceMirrorTests/MirrorMigrationTests.swift`, `MirrorViewSettingsTests.swift`, `MirrorStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2 (`SyncColumns` already lists `density`).
- Produces: `MirrorStore.setViewSettings(arrangement:quietThreads:showArchived:density:)`; `MirrorSchema.version == 9`.

Version 9: add `"density" TEXT` to `"viewSettings"`, then convert the stored row by the table with plain `UPDATE`s. A schema migration writes no outbox entry; assert that. Unpushed outbox entries that carry an old value are left as they are (the hub stores them and every reader understands them).

The mirror's write rule is the store's: setting `quietThreads` on a row that implies a density also writes it, as one more `LocalChange` update in the same transaction.

- [ ] **Step 1: Write the failing tests:**
  - `MirrorMigrationTests`: a version 8 file holding `quietThreads = 'tiny'` opens at version 9 with `density = 'dense'`, `quietThreads = 'shown'`, and an empty outbox; the other three values by the table.
  - `MirrorViewSettingsTests`: `setViewSettings(density: .dense)` on an empty mirror inserts the row and queues one insert carrying `density` only; a pulled update of `quietThreads` to `tiny` on a row with no density reads as dense and shown; then `setViewSettings(quietThreads: .hidden)` reads back `ViewSettings(quietThreads: .hidden, density: .dense)` and queues updates for both columns.
- [ ] **Step 2: Run** `swift test --filter WorkspaceMirrorTests` — expected: the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter WorkspaceMirrorTests` and the lint — expected: pass (report counts; `MirrorSyncTests` timeouts under load are known, rerun those alone).
- [ ] **Step 5: Commit** `feat(mirror): schema 9 adds density and converts the old sidebar values`.

---

### Task 4: the hub

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0021_density.sql`
- Modify: `Hub/crates/b4hub-core/src/change.rs` (the `viewSettings` `TableSpec` columns and its test), `Hub/crates/b4hub-core/src/writable.rs` (both lists and the test), `Hub/crates/b4hub-db/tests/migrations_frozen.rs` (pin), `Hub/crates/b4hub-db/tests/migrate.rs` (the applied-count assertions, 20 becomes 21), `Hub/API.md` (*View settings* and the column lists)
- Test: `Hub/crates/b4hub-db/tests/migrate.rs`, `Hub/crates/b4hub-db/tests/changes.rs`

**Interfaces:**
- Consumes: part 1's stored id `view:<userId>` (`b4hub_core::change::stored_row_id`).

The migration: add `"density" text`; convert every row by the table; for each row whose `density` it set, insert a `column_clocks` entry for (`viewSettings`, the row's id, `density`) with the hlc of that row's `quietThreads` clock, or skip it when there is none (`ON CONFLICT DO NOTHING`). `changes` is left alone. Forced row security is lifted on `"viewSettings"` and `column_clocks` and restored as found.

- [ ] **Step 1: Write the failing tests:**
  - `migrate.rs`, `density_is_split_from_the_sidebar_setting`: with the shape of `settings_rows_move_to_their_users` (run as the non-superuser owner; use `migrate_before(&pool, "0021")`), seed four orgs whose `view:<user>` rows hold `small`, `tiny`, `collapsed`, `hidden`, each with a `quietThreads` clock, and a fifth with a row whose `quietThreads` is null. Expect the stored texts by the table, a `density` clock equal to the `quietThreads` clock for the first four and none for the fifth, `changes` untouched, and both tables' force flags as before. Then, as the `tiny` org's device: a `density` update with a clock below the carried one loses, one above it stores `normal`.
  - `changes.rs`, `a_phone_may_write_density`: a phone inserts `view` with `{"id":"view","density":"dense"}` and a Mac inserts `view` with `{"id":"view","quietThreads":"collapsed"}`; the stored row has both; a phone update of `density` to `normal` is accepted.
- [ ] **Step 2: Run** `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --locked --test migrate --test changes` — expected: the new tests fail.
- [ ] **Step 3: Implement** the migration, the spec, the writable lists; pin the file's SHA-256.
- [ ] **Step 4: Update `Hub/API.md`:** the `density` row in the *View settings* table (`normal` (the default) or `dense`), `quietThreads` values `shown` (the default), `collapsed`, `hidden`, a sentence that `small` and `tiny` are old values every reader understands, and `viewSettings.density` in each list of phone-writable and clocked columns.
- [ ] **Step 5: Run** the three hub gates with `--no-fail-fast` — expected: every suite ok; report the suite, passed and failed counts.
- [ ] **Step 6: Commit** `feat(hub): migration 0021 adds density to the settings row`.

---

### Task 5: the sidebar, the menu and the Display page

**Files:**
- Modify: `Sources/WorkspaceUI/ListLayout.swift` (`Lower.rows` loses `tiny`), `ThreadListView.swift` (the Mac's lower list, the opened Collapsed and Hidden rows, the selected row beside them), `SidebarView.swift` (`ViewOptions`, the picker), `WorkspaceModel.swift` (`SettingsPage`, `setDensity`, `tightQuietRows`), `SettingsView.swift` (the page's body and toolbar cases)
- Create: `Sources/WorkspaceUI/DisplaySettingsView.swift`
- Test: `Tests/WorkspaceUITests/ListLayoutTests.swift`, `ViewSettingsModelTests.swift`, `SnapshotTests.swift`, and a new `Tests/WorkspaceUITests/DisplaySettingsTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `ListLayout.Lower.rows([ConversationThread])` (no `tiny`)
  - `WorkspaceModel.setDensity(_ density: ViewSettings.Density) async` (through `setViewSetting`, as `setQuietThreads` is)
  - `WorkspaceModel.tightQuietRows: Bool` — `viewSettings.density == .dense && !relaysThroughHub`
  - `SettingsPage.display`, title "Display", second in `allCases` on macOS (after `.account`), absent on iOS
  - `struct DisplaySettingsView: View` with `init(model: WorkspaceModel)`

Where tight rows are drawn on the Mac when `tightQuietRows`, under "Needs you first": the lower list's rows; the rows shown by opening the Collapsed row; the rows shown by opening the Hidden row; the selected thread's row when it is kept out of the stow. Never the top list, never "By environment", never the archived rows, never the phone.

The Display page: one row built from the form parts in `Theme/LLAForm.swift` that the other pages use, with a `Toggle` labelled "Dense" and the description under it. The toggle's binding reads `model.viewSettings.density == .dense` and calls `setDensity`. VoiceOver reads the label and the description as one switch.

- [ ] **Step 1: Write the failing tests:**
  - `ListLayoutTests`: `.shown` builds `.rows(rest)` whatever the density; `.collapsed` and `.hidden` are unchanged by density.
  - `ViewSettingsModelTests`: `setDensity(.dense)` shows at once, sends `ViewSettingsSet.Params(density: .dense)` and nothing else, and survives a slow read as the other setters do; `tightQuietRows` is true for dense on a Mac model and false on a relayed (phone) model.
  - `DisplaySettingsTests`: `SettingsPage.allCases` on macOS is `[.account, .display, .connections, .servers, .remoteAccess, .diagnostics]`; `SettingsPage.display.title == "Display"`; `ViewOptions.quietThreads` titles are "Shown", "Collapsed", "Hidden".
  - `SnapshotTests`: the Display page in light and dark; the sidebar at dense with Shown, and at dense with Collapsed opened, asserting through the row frames (or the existing helper for row heights) that quiet rows are `LLA.Metrics.threadRowTiny` high and top-list rows are `LLA.Metrics.threadRow`.
- [ ] **Step 2: Run** `swift test --filter WorkspaceUITests` — expected: the new tests fail.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift build`, `swift test --filter WorkspaceUITests`, the lint, and `xcodebuild build` for `B4App-macOS` and `B4App-iOS` (after `./Scripts/generate-project.sh`) — expected: pass (report counts).
- [ ] **Step 5: Commit** `feat(ui): a Dense switch on Settings, Display; the sidebar setting is Shown, Collapsed, Hidden`.

---

### Task 6: records and the full gates

**Files:**
- Create: `docs/decisions/D-NNN-density-and-the-sidebar-setting.md`, `docs/verification/<date>-density-and-the-sidebar-setting.md`
- Modify: `AGENTS.md` (the `viewSettings` line: `density`, hub `0021`, coordinator `0014`, mirror schema 9, the Display page; drop `ViewSettings.shown(on:)`), `docs/milestones.md`, `docs/compatibility.md`

- [ ] **Step 1: Run every gate** in Global Constraints on the finished tree, saving each full log under `$TMPDIR`, and note the printed counts.
- [ ] **Step 2: Take the decision number** with `Scripts/docs-index.sh --next` and write the decision as one bullet in the log's style (read D-213 first): the owner's two settings and the conversion table; the five departures at the top of this plan, each as the builder's call; the lenient read and the write rule that keeps dense; what is not done (the phone's Display page, the dense thread, the dense composer; unpushed old values in an outbox are left; "By environment" has no tight rows). It amends D-208.
- [ ] **Step 3: Write the verification record** with the gate counts as run, what failed on the way, and what was not checked (no hosted hub migrated; nothing run in an app unless it was; no device-to-device sync tried).
- [ ] **Step 4: Run** `Scripts/docs-index.sh --check` — expected: passes.
- [ ] **Step 5: Commit** `docs: density and the sidebar setting (D-NNN)`.

---

## Deploying (after merge, each step with the owner's go-ahead)

Merging deploys the beta hub and runs `0021` there. Then the Beta Mac and a TestFlight build; prod is separate. Because old values are understood when read, an older Mac or phone still running against an updated hub keeps working: it writes `small`, `tiny`, `collapsed` or `hidden`, and current devices read them. An older build reads `shown` as its default, Small, which is the same thing. Before installing a Local or Beta Mac build, compare the installed app's bundled `SQL/*.sql` with this build's: a store that already holds another session's `0014` is refused.
