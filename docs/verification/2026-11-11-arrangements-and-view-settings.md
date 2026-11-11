## 2026-11-11: Arrangements and view settings

The thread list's two arrangements, "Needs you first" and "By environment", and the three view settings stored per account and synced through the hub (D-206). Commits d1d4dcd (hub), 08569c6 and 1e8366d (coordinator), 4f92eee (phone mirror), 953ea60 and d91b9fb (model and menu), 082dd4e (Needs you first), d4c4b62 (By environment), bc1988e (merge of origin/main, which brought D-205), and 1c0fb65 (a hub test relaxed, below). Every gate ran on this branch (`blove/arrangements`) one at a time, with nothing else building or testing in this checkout.

### Gates

- `swift build`: `Build complete!`, exit 0. Run before commit 1c0fb65, which touched one hub test file only; no Swift source changed after.
- `swift test`: `Test run with 1644 tests in 199 suites passed after 272.395 seconds.` Exit 0, no failure and no recorded issue, so nothing was rerun. Run before 1c0fb65.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean, exit 0. Run before 1c0fb65.
- Hub, from `Hub/` under zsh, `source <(./scripts/test-db.sh) && cargo test --workspace --locked`:
  - **First run, on the merged tree (bc1988e): failed.** 6 of the 11 tests in `Hub/crates/b4hub-db/tests/environment_history_controls.rs` failed (`pending_18_preserves_disabled_nonforced_flags`, `pending_18_preserves_disabled_forced_flags`, `pending_18_non_super_owner_preserves_two_orgs_forced`, `pending_18_preserves_enabled_nonforced_flags`, `concurrent_public_runners_hold_lock_through_commit`, `repeatable_read_waits_for_writer_before_capture`), each with `Err(ControlFailure { stage: "one complete legitimate ledger through eighteen" })`. Those D-205 controls required the migration ledger to be exactly versions 1 to 18 with 18 rows, and this branch adds migration `0019_view_settings.sql`, so the ledger is 1 to 19. It was the control that was out of date, not the migration code under test. Cargo stopped at that binary.
  - **Commit 1c0fb65** (`test(hub): the migration-18 controls allow later migrations`) changed only `complete_ledger` in that file: the ledger must run from 1 with no gaps and reach at least 18, with no extra or failed rows. The check on version 18 itself (frozen checksum, execution time) is unchanged.
  - **Rerun on 1c0fb65: passed.** 30 test result lines, 535 tests passed, 0 failed, exit 0. `./scripts/test-db.sh --stop`: "server stopped".
- `cargo fmt --all -- --check`: clean, exit 0 (run after 1c0fb65; it also passed before).
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings, exit 0 (run after 1c0fb65; it also passed before).
- `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'`: `** BUILD SUCCEEDED **` (after 1c0fb65).
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`: `** BUILD SUCCEEDED **` (after 1c0fb65; this compiles the widget). The iOS layout UI tests (`Tests/iOSLayout`) were not run here; CI runs them.
- `Scripts/docs-index.sh --check`: `196 decisions and 116 verification records are well formed` (run after these files were added). `--next` then printed `D-207`, since this tree holds D-206 and the highest on `origin/main` is D-205.

### What the tests cover

- Hub: a phone may insert and update the four `viewSettings` columns, deletes are refused, unknown values are stored untouched, `ORG_TABLES` includes the table, migration 0019 is pinned, and `changes.json` decodes with the two new entries (`b4hub-db/tests/changes.rs`, `b4hub-core` unit tests).
- Coordinator store: lenient reads, one-row sets that name only the given columns, a no-op set that publishes nothing, a first insert that carries and clocks only the columns it sets, remote apply by column clock, an insert never applying a null, `viewSettings.changed` on pull (`ViewSettingsStoreTests`, `RemoteApplyTests`, `HubPullTests`, `ViewSettingsTests`).
- Phone mirror: schema 8, the same partial-insert and no-null rules, the outbox, and the commands the mirror serves (`MirrorViewSettingsTests`, `MirrorMigrationTests`).
- Model: optimistic writes, rollback of only the refused field, a set's answer applying only its own field, an overtaken read dropped, rebase of the arrival tracker on an arrangement or Show archived change, and Tiny shown as Collapsed on a device that relays through the hub (`ViewSettingsModelTests`, `AttentionModelTests`).
- Layout: `ListLayout` for both arrangements, every quiet-thread mode, the 24 pt gaps, the archived block, group ordering and the most urgent mark (`ListLayoutTests`, `ThreadListTests`).

### Snapshots looked at

Rendered with `B4APP_SNAPSHOT_DIR=<dir under $TMPDIR> swift test --filter SnapshotTests` on 1c0fb65: `Test run with 13 tests in 2 suites passed after 109.347 seconds.` PNGs opened and looked at (light unless noted; the dark ones were opened where named):

- `macQuietThreads-small-light.png`: Needs you first. Four top-list rows (approve ring-dot, approve solid dot, failed cross, finished small dot), a wide gap, then the lower list with two working rows (lime arcs) and three quiet rows with no mark. No headings and no Pinned group.
- `macQuietThreads-tiny-light.png`: the same threads with the lower list in smaller type and tighter rows (20 pt), the working marks smaller.
- `macQuietThreads-collapsed-open-light.png`: the collapsed row "5 more, 2 working" with the orbit mark, opened in place, with the five stowed threads listed under it.
- `macQuietThreads-hidden-light.png`: the top list only, and one muted "2 working" row with the arc pinned above the profile footer.
- `macSidebarGroupsByEnvironment-archived-light.png`: By environment. Headings "b4app", "Marketing site" and "No folder" in small muted type, their threads under each in state order, and a final block "Old spike" after a gap, with no heading. No quiet-threads row.
- `macSidebarGroupsByEnvironment-collapsed-dark.png`: By environment with "b4app" collapsed: the heading shows its most urgent mark (the approve ring) at the trailing edge, and "Marketing site" and "No folder" stay open.
- `iosGroupsByEnvironment-light.png`: the phone's By environment: the same headings and rows at the phone's wider rows and margins, with the archived "Old spike" after a gap.
- `iosQuietThreads-collapsed-open-dark.png`: the phone's collapsed row "5 more, 2 working" opened in place, in dark.

Other renders in the folder (`macQuietThreads-hidden-open`, `-hidden-onlyQuiet`, `iosQuietThreads-hidden`, the `-dark` pairs, `macSidebarGroupsByEnvironment-light` and the existing sheets) were produced by the same passing run and not each opened.

### Not checked

- The collapsed row opening and closing with a real pointer (Mac: it closes when the pointer leaves the sidebar) and with a second tap (phone).
- The hidden row above the footer in the running app (seen only in a render).
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
- The phone keeps "New Environment…" and an "Edit Environment" submenu at the foot of its menu; the Mac heading keeps its Rename, Add Folder and Delete context menu. An empty hand-made environment has no heading, so it cannot be renamed or deleted on the Mac until the environment-form plan. Under "Needs you first" the Mac has no environment headings.
- The hub keeps one `view` row per org (D-206's known limit; lifting it needs a per-user key).
- This branch relaxed a D-205 control (1c0fb65) so later migrations can exist; D-205's decision is not amended.
- Deploy order: the hub (migration 0019) and both apps must be on this version for the settings to sync (`docs/compatibility.md`).

### Follow-ups

A fix wave follows and will update this record: Hidden with working threads pads an empty view on the Mac; the opened collapsed row's state survives the stowed set emptying and an arrangement change; a dropped settings read is not retried; settings load after threads, so the list can draw once with defaults. The remaining deferred minors are listed in D-206.
