## 2026-11-11: Arrangements and view settings

The thread list's two arrangements, "Needs you first" and "By environment", and the three view settings stored per account and synced through the hub (D-208). Commits d1d4dcd (hub), 08569c6 and 1e8366d (coordinator), 4f92eee (phone mirror), 953ea60 and d91b9fb (model and menu), 082dd4e (Needs you first), d4c4b62 (By environment), bc1988e (merge of origin/main, which brought D-205), 1c0fb65 (a hub test relaxed, below), and the review's fix wave, f60422e (view settings from another Mac; two hub tests) and 46c6041 (the stowed rows). The gates below were rerun on the fix wave's tree (f60422e and 46c6041, before this record's update), replacing the earlier result lines; the account of the first hub failure is kept. Every gate ran on this branch (`blove/arrangements`) one at a time, with nothing else building or testing in this checkout.

### Gates

- `swift build`: `Build complete! (11.90s)`, exit 0.
- `swift test`: `Test run with 1649 tests in 199 suites failed after 401.718 seconds with 9 issues.`, at a machine load average near 70. Both failing suites are untouched by this branch:
  - `MirrorSyncTests` (8 issues, each "timed out waiting for …"): rerun alone, `Test run with 23 tests in 1 suite passed after 1.328 seconds.`
  - `PostgresServerTests.locatorFindsTheFetchedTreeAndRejectsIncompleteDirectories` (1 issue): it expects no Postgres to be found with `HOME=/nonexistent`, but this machine now has `/Applications/Agent Workspace.app/Contents/SharedSupport/postgres/bin` installed, which the locator finds. Rerun alone it fails the same way (`Test run with 5 tests in 1 suite failed after 12.588 seconds with 1 issue.`). It depends on the machine, not on this branch; neither the test nor `PostgresLocator` changed here.
  - Focused, after the fix wave: `swift test --filter "RemoteApplyTests|HubPullTests"`: `Test run with 30 tests in 2 suites passed after 50.353 seconds.`; `swift test --filter ListLayoutTests`: `Test run with 18 tests in 1 suite passed`.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean, exit 0.
- Hub, from `Hub/` under zsh, `source <(./scripts/test-db.sh) && cargo test --workspace --locked`:
  - **First run, on the merged tree (bc1988e): failed.** 6 of the 11 tests in `Hub/crates/b4hub-db/tests/environment_history_controls.rs` failed (`pending_18_preserves_disabled_nonforced_flags`, `pending_18_preserves_disabled_forced_flags`, `pending_18_non_super_owner_preserves_two_orgs_forced`, `pending_18_preserves_enabled_nonforced_flags`, `concurrent_public_runners_hold_lock_through_commit`, `repeatable_read_waits_for_writer_before_capture`), each with `Err(ControlFailure { stage: "one complete legitimate ledger through eighteen" })`. Those D-205 controls required the migration ledger to be exactly versions 1 to 18 with 18 rows, and this branch adds migration `0019_view_settings.sql`, so the ledger is 1 to 19. It was the control that was out of date, not the migration code under test. Cargo stopped at that binary.
  - **Commit 1c0fb65** (`test(hub): the migration-18 controls allow later migrations`) changed only `complete_ledger` in that file: the ledger must run from 1 with no gaps and reach at least 18, with no extra or failed rows. The check on version 18 itself (frozen checksum, execution time) is unchanged.
  - **Rerun on 1c0fb65: passed.** 30 test result lines, 535 tests passed, 0 failed, exit 0.
  - **On the fix wave (f60422e): one unrelated failure, then passed.** The first run failed `events_go_only_to_watchers` in `b4hub/tests/relay.rs` (77 passed, 1 failed; untouched by this branch) and cargo stopped at that binary. Rerun alone, `cargo test -p b4hub --test relay --locked`: `test result: ok. 78 passed; 0 failed`. Then `cargo test --workspace --locked --no-fail-fast`: 30 test result lines, 537 tests passed (the two new `changes.rs` tests among them; `changes.rs` itself `50 passed`), 0 failed, exit 0. `./scripts/test-db.sh --stop`: "server stopped".
- `cargo fmt --all -- --check`: clean, exit 0 (on the fix wave).
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: `Finished` with no warnings, exit 0 (on the fix wave).
- `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'`: `** BUILD SUCCEEDED **` (on the fix wave).
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`: `** BUILD SUCCEEDED **` (on the fix wave; this compiles the widget). The iOS layout UI tests (`Tests/iOSLayout`) were not run here; CI runs them.
- `Scripts/docs-index.sh --check`: `docs-index: 196 decisions and 116 verification records are well formed` (rerun after the fix wave's record updates). `--next` then printed `D-207`, since this tree holds D-208 and the highest on `origin/main` is D-205.

### The owner's changes (6c0b71d)

Six changes the owner asked for after looking at the running app (D-208, "The owner's changes"). Run on 6c0b71d's tree, one at a time:

- `swift build`: `Build complete! (13.98s)`.
- Focused: `swift test --filter "ListLayoutTests|ThreadListTests|MacTopBarTests|AttentionModelTests"`: `Test run with 84 tests in 4 suites passed after 3.992 seconds.`
- `swift test`: `Test run with 1660 tests in 199 suites failed after 208.578 seconds with 1 issue.` The one issue is `PostgresServerTests.locatorFindsTheFetchedTreeAndRejectsIncompleteDirectories` (it finds the Postgres in `/Applications/Agent Workspace.app`, as above); rerun alone: `Test run with 5 tests in 1 suite failed after 11.794 seconds with 1 issue.` `MirrorSyncTests` passed in the full run.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean, exit 0.
- `xcodebuild build ... -scheme B4App-macOS -destination 'platform=macOS'`: `** BUILD SUCCEEDED **`; `-scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`: `** BUILD SUCCEEDED **`.
- Snapshots: `B4APP_SNAPSHOT_DIR=<new dir under $TMPDIR> swift test --filter "SnapshotTests/quietThreadsInEachMode|SnapshotTests/macSidebarGroupsByEnvironment"`: `Test run with 2 tests in 1 suite passed after 67.832 seconds.` Looked at: `macQuietThreads-collapsed-selected-light.png` (the top list, the 24 pt gap, the selected quiet thread "Mirror outbox review" with its fill as an ordinary row, then "4 more, 2 working"), `macQuietThreads-collapsed-selected-open-light.png` (the same, opened: the four stowed rows beneath "4 more", the selected one not repeated), `iosQuietThreads-collapsed-selected-light.png` (the phone's list, the same order), `macQuietThreads-hidden-open-light.png` and `macSidebarGroupsByEnvironment-archived-light.png`. Rows are 29 pt apart (58 px at 2x: 28 pt rows and the 1 pt gap); a heading's first row follows it with no gap, and the 24 pt and 8 pt section gaps are unchanged. The gap is space; no line is drawn. The phone renders are drawn on the Mac, so they use the Mac's row heights.
- Tests added: the selected thread never stowed (counts, once, no Collapsed row when alone, Small and Tiny unchanged) and the hold in the layout (`ListLayoutTests`); the hold in the model: a finished thread opened and read keeps its slot, selecting another releases it with no arrival traced, the composer, a new selection, archiving and sign-out release it, under Collapsed it is not stowed until released, a new approval moves it up, and under By environment it keeps its place in its group, with `Attention.state(of:)` and the badge count on the real state (`AttentionModelTests`); the view-options label and the Environments order (`MacTopBarTests`); the row gap (`ThreadListTests`).

### What the tests cover

- Hub: a phone may insert and update the four `viewSettings` columns, deletes are refused, unknown values are stored untouched, two partial inserts with disjoint columns (the later one older) keep both, a phone update of `id` is recorded but never renames the row, `ORG_TABLES` includes the table, migration 0019 is pinned, and `changes.json` decodes with the two new entries (`b4hub-db/tests/changes.rs`, `b4hub-core` unit tests).
- Coordinator store: lenient reads, one-row sets that name only the given columns, a no-op set that publishes nothing, a first insert that carries and clocks only the columns it sets, remote apply by column clock, an insert never applying a null, another Mac's insert and update applying on the feed and the snapshot path while its other tables stay skipped, this Mac's own echo changing nothing and publishing nothing, an older Mac clock losing, `viewSettings.changed` on pull (`ViewSettingsStoreTests`, `RemoteApplyTests`, `HubPullTests`, `ViewSettingsTests`).
- Phone mirror: schema 8, the same partial-insert and no-null rules, the outbox, and the commands the mirror serves (`MirrorViewSettingsTests`, `MirrorMigrationTests`).
- Model: optimistic writes, rollback of only the refused field, a set's answer applying only its own field, an overtaken read dropped, rebase of the arrival tracker on an arrangement or Show archived change, and Tiny shown as Collapsed on a device that relays through the hub (`ViewSettingsModelTests`, `AttentionModelTests`).
- Layout: `ListLayout` for both arrangements, every quiet-thread mode, the 24 pt gaps, the archived block, group ordering and the most urgent mark, the stowed rows closing on an arrangement or mode change or an empty stowed set (`stowing`, `keepsStowedOpen`), and "No threads yet." never above archived rows (`saysNoThreadsYet`) (`ListLayoutTests`, `ThreadListTests`).

### Snapshots looked at

Rendered with `B4APP_SNAPSHOT_DIR=<dir under $TMPDIR> swift test --filter SnapshotTests` on 1c0fb65: `Test run with 13 tests in 2 suites passed after 109.347 seconds.` PNGs opened and looked at (light unless noted; the dark ones were opened where named):

- `macQuietThreads-small-light.png`: Needs you first. Four top-list rows (approve ring-dot, approve solid dot, failed cross, finished small dot), a wide gap, then the lower list with two working rows (lime arcs) and three quiet rows with no mark. No headings and no Pinned group.
- `macQuietThreads-tiny-light.png`: the same threads with the lower list in smaller type and tighter rows (20 pt), the working marks smaller.
- `macQuietThreads-collapsed-open-light.png`: the collapsed row "5 more, 2 working" with the orbit mark, opened in place, with the five stowed threads listed under it.
- `macQuietThreads-hidden-light.png`: the top list only, and one muted "2 working" row with the arc pinned above the profile footer.
- Fix wave, `B4APP_SNAPSHOT_DIR=<new dir under $TMPDIR> swift test --filter "SnapshotTests/quietThreadsInEachMode|ListLayoutTests"`: `Test run with 19 tests in 2 suites passed after 29.136 seconds.` `macQuietThreads-hidden-open-light.png`: the four top-list rows, a 24 pt gap, then the two working threads ("Release checklist", "Pricing page research", lime arcs) as the scrolling list's last rows, and the "2 working" row alone at the bottom, outside the scroll view. `macQuietThreads-hidden-light.png` again: the top list, no gap or padding below it, and "2 working" above the profile footer.
- `macSidebarGroupsByEnvironment-archived-light.png`: By environment. Headings "b4app", "Marketing site" and "No folder" in small muted type, their threads under each in state order, and a final block "Old spike" after a gap, with no heading. No quiet-threads row.
- `macSidebarGroupsByEnvironment-collapsed-dark.png`: By environment with "b4app" collapsed: the heading shows its most urgent mark (the approve ring) at the trailing edge, and "Marketing site" and "No folder" stay open.
- `iosGroupsByEnvironment-light.png`: the phone's By environment: the same headings and rows at the phone's wider rows and margins, with the archived "Old spike" after a gap.
- `iosQuietThreads-collapsed-open-dark.png`: the phone's collapsed row "5 more, 2 working" opened in place, in dark.

Other renders in the folder (`macQuietThreads-hidden-open`, `-hidden-onlyQuiet`, `iosQuietThreads-hidden`, the `-dark` pairs, `macSidebarGroupsByEnvironment-light` and the existing sheets) were produced by the same passing run and not each opened.

### On-screen check (Local app, real Codex)

Done on 2026-11-11 with the Local flavour app packaged from this branch (Developer ID, not notarized), installed in `/Applications`, and the Compose hub rebuilt from this branch (hub migration 0019 and store migration 0013 applied to the owner's local data). The app was driven in the background through accessibility, which cannot open pop-up menus or hover, so each setting was changed by sending `viewSettings.set` to the coordinator's socket as a second client; the app followed every change from the `viewSettings.changed` event.

- **Needs you first, Small (the default).** The failed thread and the finished thread on top, a 24 pt gap (rows at y 60 and 88, the next at 140), then the quiet rows; with a thread running, it led the lower list with the orbit.
- **Collapsed.** One muted row, "2 more". Pressing it listed the two stowed threads beneath it.
- **Tiny.** The lower rows report frames 224 by 20; the top rows stay 28.
- **Hidden.** With nothing running, only the top list and no gap or row beneath. With a thread running `sleep 40`, a "1 working" row with the orbit sat just above the profile footer (frame y 596, the footer at 635); pressing it listed the working thread in the list after a 24 pt gap.
- **By environment.** Headings "b4app" and "No folder", 28 pt, 8 pt between groups, threads in state order. Collapsing "b4app" left its heading with the red cross of its failed thread at the trailing edge; pressing it again expanded it.
- **Sync.** The local hub's `viewSettings` table holds one row (`view`) with the last values set, and `column_clocks` has one clock each for `arrangement`, `quietThreads`, `showArchived` and `updatedAt`.

Seen while checking, since changed by the owner's changes (6c0b71d):

- The view-options button's accessibility label read "View options" on the new-thread screen and "Filter" once a thread was open (now "View options" always on the Mac).
- With Hidden, the open thread was a working one and so was not in the sidebar until the "1 working" row was pressed (the selected thread is now never stowed).

### On-screen check of the owner's changes (Local app, real Codex)

Done on 2026-11-11 with the Local app repackaged from commit eb73a25, driven in the background through accessibility.

- **Row gap.** Consecutive rows report frames 29 pt apart (y 112, 141, 170, 199) at 28 pt high: a 1 pt gap, no drawn line. The 24 pt gap between the top list and the lower list is unchanged (a top row at y 60, the first lower row at 112).
- **The thread being read keeps its place.** A test thread finished while another thread was open and arrived second in the top list (y 89) with its dot and the arrival hairline. Opening it marked it read: its dot went and its title turned quiet, and it stayed at y 89 with the selection fill. Selecting another thread moved it to the head of the lower list.
- **The label.** The view-options button's accessibility label read "View options" both on the new-thread screen and with a thread open.

Not seen in this pass: the selected thread drawn above the Collapsed row, the Hidden row's opened threads scrolling into view, the "Environments" submenu and its sheets (pop-up menus cannot be opened in the background), and anything on the phone, including the hold ending when the list is shown again.

### Not checked

- The six owner's changes of 2026-11-11 (6c0b71d) were not seen in the running app: the view-options button's label with VoiceOver, the scroll as Hidden's rows open (and with Reduce Motion), the "Environments" submenu and its sheets, the 1 pt gaps on a device, the selected row under Collapsed and Hidden, and a thread holding its place as it is read and then released. Menus, scrolling and the pointer cannot be rendered; the layout, the hold and the labels are tested, and the gaps and the selected row were seen in renders only.

- The view-options menu itself (its items, the disabled quiet-thread items under By environment), since pop-up menus could not be opened; the archived block (the local data has no archived thread); the phone following a change made on the Mac.

- The collapsed row opening and closing with a real pointer (Mac: it closes when the pointer leaves the sidebar) and with a second tap (phone).
- The hidden row above the footer in the running app (seen only in a render), and its opened working rows scrolling with many of them (the render shows two, not a scroll).
- Heading hover on the Mac (the name turning ink, the chevron, the new-thread button).
- The phone's long press ("New thread here"), tap to collapse, the 44 pt headings, and the Tiny note in its menu.
- Two real devices syncing a setting through a hub (the hub, the coordinator and the mirror are tested against fakes and fixtures, not together).
- The iOS layout UI tests (`Tests/iOSLayout`; CI runs them).
- A hosted hub, the packaged apps, dark appearance and Reduce Motion in the running app.

### Deviations from the plan

- The fixture change and both suites landed together in Task 1 (the Swift side needed only test changes then).
- A first insert of the settings row carries and clocks only the columns it sets, on the Mac (migration 0013's trigger, for `viewSettings` only) and on the phone, and a pulled insert never applies a null. This is what lets two devices' different offline choices both survive.
- A set's answer applies only its own field and an overtaken read is dropped.
- The fallback (Tiny shown as Collapsed) applies to every device that relays through the hub: the phone and the iPad.
- The phone keeps "New Environment…" and an "Edit Environment" submenu at the foot of its menu; the Mac heading keeps its Rename, Add Folder and Delete context menu, and the Mac's view options have an interim "Environments" submenu with the same actions for every environment, so they are reachable under either arrangement and for an environment without live threads. Under "Needs you first" the Mac has no environment headings.
- The hub keeps one `view` row per org (D-208's known limit; lifting it needs a per-user key).
- This branch relaxed a D-205 control (1c0fb65) so later migrations can exist; D-205's decision is not amended.
- Deploy order: the hub (migration 0019) and both apps must be on this version for the settings to sync (`docs/compatibility.md`).

### Follow-ups

The fix wave (f60422e, 46c6041) closed the review's findings: view settings written by one Mac now reach another, Hidden pads nothing on the Mac and its opened rows scroll, the opened stowed rows close on an arrangement or mode change or an empty stowed set, "No threads yet." is not printed above archived rows, and the hub gained the two tests. Still open: a dropped settings read is not retried (only a set that changes nothing, made during the first-connect read, leaves the other fields on defaults until the next snapshot); settings load after threads, so the list can draw once with defaults. The remaining deferred minors are listed in D-208.
