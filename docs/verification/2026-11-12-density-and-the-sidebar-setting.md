## 2026-11-12: density and the sidebar setting

D-218: the settings row's four-way "Small, Tiny, Collapsed, Hidden" is split into density (normal or dense, a "Dense" switch on the Mac's Settings, Display page) and a three-way sidebar setting (Shown, Collapsed, Hidden). Branch `blove/display-settings`, with `main` 4228e3c merged in (per-user settings rows, D-213, and the list follow-ups, D-211).

### Gates

Run on the merged tree, each log saved and the counts read from it:

- `swift test`: 1737 tests in 206 suites passed (run again after the last fix below; 1731 before it).
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- Hub, from `Hub/` after `source <(./scripts/test-db.sh)`: `cargo test --workspace --locked --no-fail-fast`, 30 suites, 545 passed, 0 failed; `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` clean.
- `xcodebuild build` for `B4App-macOS` (`platform=macOS`) and `B4App-iOS` (`generic/platform=iOS Simulator`), after `./Scripts/generate-project.sh`: both `BUILD SUCCEEDED`.
- `Scripts/docs-index.sh --check`: passed.

The tests that carry the change:

- `ViewSettingsTests`: each old stored value reads as its density and sidebar setting; a stored density wins over what `tiny` implies; density round-trips through JSON, and JSON from before the split still decodes.
- `ViewSettingsStoreTests` and `MirrorMigrationTests`, `MirrorViewSettingsTests`: the Mac store's migration 0014 and the mirror's schema 9 convert each old value and add nothing to the change log or the outbox and move no clock; replacing an unconverted `tiny` through the sidebar setting also writes dense; a stored density this build does not know is kept.
- Hub `tests/migrate.rs` `density_is_split_from_the_sidebar_setting` (run as the non-superuser owner, five organisations, one table left unforced to show each row-security flag is put back as found; a carried clock still beats an older write) and `tests/changes.rs` `a_phone_may_write_density`.
- `ThreadListHeightTests`: the real Mac list is measured at normal and at dense. Quiet rows, the rows opened from Collapsed and from Hidden, and the selected row beside a stow are 8 pt shorter each; the top list, "By environment", archived rows and the "N more" row are the same height. Swapping two row places in the view, or dropping the size at one call site, was tried and failed these tests.
- `ViewSettingsModelTests`: `setDensity` shows at once, sends only `density`, is put back when refused, and survives a slow read; a phone model at dense has no tight rows.
- `ListSnapshotTests` (it runs by default; writing its images is opt-in, `B4APP_SNAPSHOT_DIR`): the Display page and the dense sidebar in four arrangements were rendered in light and dark and looked at: quiet rows are tight, top and archived rows are not, the switch and its description draw.

Failed on the way, and what was done:

- The first full hub run on the merged tree had 3 failures, all in `b4hub`'s `request_log` unit tests (a captured log field read as null). This branch does not touch that code. The same tests passed three times alone and the full suite passed on the next run (545, 0 failed). It is recorded here as a flake, not fixed.
- During the hub task, `pull_pages_and_long_polls` failed once on a timing bound (woke after 1.14 s against 1 s) and passed on the rerun.
- Review of the Mac store found that replacing `tiny` would overwrite a stored density this build does not know; both stores now apply the rule only when no density is stored.
- Review of the UI found that no test was tied to what the views draw; `ThreadListHeightTests` was added.
- The whole-branch review found that a device replaying the hub's change log applied an old `tiny` and then a later sidebar change, and ended at normal density while the hub held dense. Both pull paths (`RemoteApply`, `MirrorApply`) now keep the density the replaced `tiny` implied, logging nothing and claiming no clock (`aPulledSidebarChangeKeepsTheDensityTinyImplied`, `aPulledDensityBeforeTheSidebarChangeIsKept`, `aPulledSidebarChangeKeepsAnUnknownDensity`, in both suites). The same review corrected the records on mixed versions: the hub goes first for each flavour, and an older build's choice between Small and Tiny is not taken up once a density is stored. The hub was not changed after its gates above.

### Not checked

- Nothing was run in an app. The Local app on this Mac holds another build's store migration `0014`, which this build's store would refuse. The switch, the menu and the tight rows were seen only in rendered snapshots.
- VoiceOver on the Dense switch (that it reads the label and the description as one switch) was not checked.
- No hosted hub was migrated with `0021`. The beta hub runs `0020` from D-213's merge.
- Two devices syncing density through a hub was not tried; the phone's side is covered by the mirror's tests and the fake hub only.
- The iOS layout UI tests (`./Scripts/test-ios-layout.sh`) were not run locally.
- Pull request 188 holds the same three migration numbers (hub `0021`, store `0014`, mirror schema 9). If it merges first, this branch's migrations are renumbered and these gates are run again.
