## 2026-11-11: Marks and rows

The thread list's six states, one mark per state, the single-line row, the arrival trace and the Mac's top bar (D-204). Commits 1a8904d (states), 8c2592d (Medium font and lime), 566f6b4 (the mark), e6be925 (the row), c3f4f96 (the arrival trace) and 5fa4471 (the top bar). Every gate below ran on this branch (`blove/marks-and-rows`) one at a time, with nothing else building or testing in this checkout.

### Gates

- `swift build`: `Build complete!`, exit 0.
- `swift test`: `Test run with 1568 tests in 193 suites passed after 116.255 seconds.` Exit 0, no failing test and no recorded issue. The timeouts seen in earlier runs (`MirrorSyncTests`, `ThreadOpenRequestTests`) and the `AppleSignInTests.appleSheetSaysItHasNoWindow` failure did not appear, so there was nothing to rerun.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean, exit 0.
- Hub, from `Hub/`: `source <(./scripts/test-db.sh) && cargo test --workspace --locked`: 29 test binaries, 515 tests passed, 0 failed; then `./scripts/test-db.sh --stop` stopped the cluster. (A first attempt ran the command from `bash` 3.2, where `source <(...)` does not take effect, so `DATABASE_URL` was unset and 21 database tests failed with "DATABASE_URL must be set"; that was my invocation, not the code. The run above is from `zsh`.)
- `cargo fmt --all -- --check`: clean, exit 0.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings.
- `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'`: `** BUILD SUCCEEDED **`.
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`: `** BUILD SUCCEEDED **` (this compiles the widget).
- `Scripts/docs-index.sh --check`: `193 decisions and 111 verification records are well formed` (run after these files were added). `--next` then printed `D-205`; the highest on `origin/main` is D-203.
- `Hub/` is unchanged by this work; the Rust gates confirm it.

### What the tests cover

- States and badge (`Attention` tests, `MirrorNotifications` tests, the `attention.json` fixture in both suites): the nine-step state rule, approve over reply, failed read or not, cancelled as finished, the order (state, pin, activity, id), and the unchanged badge count.
- Font and colour (`ThemeTests`): the Medium face resolves and falls back; the lime.
- Mark and acknowledgement (`ThreadMarkTests`, `ReasonLineTimeTests`): the six marks' labels and motion rules, Reduce Motion, the approve pulse stopping once the thread was opened.
- Row (`ThreadRowTests`, `ThreadListTests`, `DetailMinimumSizeTests`): the five quiet-fade steps and their edges, act-level titles medium, the spoken label keeping what the row no longer shows, the 240 pt sidebar.
- Arrivals (`ArrivalTrackerTests`, `AttentionModelTests`): first load, filter change and rebuild trace nothing; entering the top list traces; one lap at a time; the timings as numbers.
- Top bar (`MacTopBarTests`): each button's title, symbol, identifier, shortcut and enabled state, and which buttons show with the sidebar visible and hidden. The task's smoke run (`Scripts/test-macos-smoke.sh`, recovery tests at 900 by 600) read the real window's accessibility tree: View options, Search and New thread in the bar, no "more toolbar items" control. I did not re-run it for this record.

### Snapshots looked at

Rendered with `B4APP_SNAPSHOT_DIR=<dir under $TMPDIR> swift test --filter SnapshotTests`: `Test run with 13 tests in 2 suites passed after 83.114 seconds.` PNGs opened and looked at:

- `rowShowsEachStateMark-light.png` and `-dark.png`: one row per state in display order, touching, 28 pt pitch. Approve is a ring around a dot, reply a large solid dot, failed a red-brown cross (salmon in dark), finished a small dot (this row is selected, so its fill spans the row with rounded corners), working a faint ring with a short lime arc, quiet no mark and a muted title. A long reply title truncates with an ellipsis before the mark. Act-level titles are medium weight, working and quiet are regular. Below a rule, a gallery of the marks still, then approve acknowledged (no pulse ring), then the six animated, caught at one instant. Distinct in shape, so it reads without colour.
- `macSidebarGroupsByEnvironment-light.png` and `-dark.png`: the real sidebar at 240 pt with groups b4app (5), Marketing site (2), Docs (0, "No threads."), No folder (1) and a pinned thread on top. Titles start at the same x everywhere, marks sit at the trailing edge, no pin glyph or runtime mark. In the pinned area the "Pinned" header is drawn over a hairline and the first row sits right under it, partly cut at the top in this render; I did not look into it and note it here.
- `macSidebarCollapsedEnvironment-light.png`: the collapsed b4app header shows one solid dot (its most urgent state) before the count 4.
- `arrivalTraceAtItsMoments-light.png` and `-dark.png`: nine frozen rows. 0.25 s sliding (a bright sliver on the top edge); 0.6 s and 2.4 s show a lit run along the right edge and bottom (laps 1 and 2); 1.2 s lap 1 a short sliver on the bottom edge; 1.2 s with no lap and 5 s show the hairline only; 9.25 s a fainter hairline; 0.25 s with Reduce Motion the hairline only; 10 s no outline. These are stills of a pure function of time, not the motion.
- `search-light.png`: the search palette over a real-coordinator window. Rows carry the approve target (the open thread) and the working arc; the sidebar's selected row shows the approve target too. The window toolbar is not in this render.
- `sidebar-light.png`: the same window without the palette: the selected "Release notes draft" row has its fill and a hairline sliver along its top edge (the arrival trace), approve target at the trailing edge, the pinned working thread above.
- `ios-list-dock-light.png`: the iOS list as drawn by macOS (Mac metrics): title and mark per row, approve absent here, reply, failed cross, finished dot, two working arcs, quiet rows without marks, filter and search icons in the header. This is not the phone's layout.
- Greyscale renders of the first two files were checked in Task 4 (`sips`) and the shapes stayed distinct.

### Not checked

- All motion in the running app: the orbit, the approve pulse, the working shimmer, the arrival slide and the lap. Stills cannot judge timing, smoothness, or the lap's speed; the on-screen pass that follows should.
- ⌘N and ⌘K pressed in the running app, with the sidebar shown and hidden.
- The top bar with the sidebar hidden in the real app (a scratch hosting harness showed search and new thread only, with a limit: it has no system sidebar toggle).
- The phone and the widget on a device or in the Simulator: margins, the three-line wrap at accessibility sizes, `ScaledMetric` marks, the slide inside a list cell (a `List` cell may clip its 12 pt slide), and the widget's rendering. Both apps compile (the iOS scheme builds the widget).
- Hover (none exists), the Pinned header's render noted above, and a hosted hub or push notification run: nothing in `Hub/` changed.

### Deviations from the plan

- A turn waiting for the user with no pending request shows as reply but does not count toward the badge, so the badge is unchanged (`countsTowardBadge`).
- The Medium font is the unmodified static file from the designer's repository; Google Fonts ships only a variable font.
- No hover fill exists yet.
- The point of light uses a conic gradient, so it does not move along the edge at constant speed.
- ⌘N and ⌘K are File menu commands; "New Environment…" left the Mac sidebar; the Mac sidebar is fixed at 240 pt and the iPad's is not.

### Follow-ups

A fix wave follows and will update this record: the selected, open thread counts as acknowledged; a Mac hover fill; a constant-speed lap; "Mark as Unread" and a mark-read rollback rebase the tracker instead of tracing; `refreshEnvironments` feeds the arrival tracker; the view-options hit area (29 by 16) becomes 28 by 28. The remaining deferred minors are listed in D-204.
