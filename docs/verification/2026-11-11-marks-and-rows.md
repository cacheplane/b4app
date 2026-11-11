## 2026-11-11: Marks and rows

The thread list's six states, one mark per state, the single-line row, the arrival trace and the Mac's top bar (D-204). Commits 1a8904d (states), 8c2592d (Medium font and lime), 566f6b4 (the mark), e6be925 (the row), c3f4f96 (the arrival trace) and 5fa4471 (the top bar), then 705425b (the review's fix wave: the open thread acknowledged, the Mac hover fill, tracker baselines for the owner's own actions, the constant-speed lap, the view-options filter indicator and target, the glance order, the snapshot harness, and the approval-kind tests). Every gate below ran on this branch (`blove/marks-and-rows`) one at a time, with nothing else building or testing in this checkout.

### Gates

- `swift build`: `Build complete!`, exit 0.
- `swift test`, after the fix wave: `Test run with 1581 tests in 193 suites passed after 90.719 seconds.` Exit 0, no failing test and no recorded issue, so there was nothing to rerun. (Before the fix wave: 1568 tests in 193 suites passed.)
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean, exit 0.
- Hub, from `Hub/` (run before the fix wave; neither the wave nor any marks-and-rows commit changes `Hub/` or `Tests/Fixtures/sync`, so it was not rerun): `source <(./scripts/test-db.sh) && cargo test --workspace --locked`: 29 test binaries, 515 tests passed, 0 failed; then `./scripts/test-db.sh --stop` stopped the cluster. (A first attempt ran the command from `bash` 3.2, where `source <(...)` does not take effect, so `DATABASE_URL` was unset and 21 database tests failed with "DATABASE_URL must be set"; that was my invocation, not the code. The run above is from `zsh`.)
- `cargo fmt --all -- --check`: clean, exit 0.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings.
- `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'`: `** BUILD SUCCEEDED **`, again after the fix wave.
- `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`: `** BUILD SUCCEEDED **` (this compiles the widget), again after the fix wave.
- `Scripts/docs-index.sh --check`: `193 decisions and 111 verification records are well formed` (run after these files were added). `--next` then printed `D-205`; the highest on `origin/main` is D-203.
- `Hub/` is unchanged by this work; the Rust gates confirm it.

### What the tests cover

- States and badge (`Attention` tests, `MirrorNotifications` tests, the `attention.json` fixture in both suites): the nine-step state rule, approve over reply, failed read or not, cancelled as finished, the order (state, pin, activity, id), and the unchanged badge count.
- Font and colour (`ThemeTests`): the Medium face resolves and falls back; the lime.
- Mark and acknowledgement (`ThreadMarkTests`, `ReasonLineTimeTests`): the six marks' labels and motion rules, Reduce Motion, the approve pulse stopping once the thread was opened.
- Row (`ThreadRowTests`, `ThreadListTests`, `DetailMinimumSizeTests`): the five quiet-fade steps and their edges, act-level titles medium, the spoken label keeping what the row no longer shows, the 240 pt sidebar.
- Arrivals (`ArrivalTrackerTests`, `AttentionModelTests`): first load, filter change and rebuild trace nothing; entering the top list traces; one lap at a time; the timings as numbers. The light's position is linear in time along the perimeter and covers exactly two laps by 3.5 s, and a segment crossing the path's start is two pieces that together are its length. Mark as Unread, a mark-read rollback and unarchiving a top-list thread do not trace, and another thread's live trace survives each; a thread whose environment disappears while the "No folder" filter is on does not trace on the next event (`ArrivalTracker.record`).
- The open thread (`AttentionModelTests`): it stays acknowledged when new activity arrives and after another thread is selected; a selected thread whose detail is not on screen is not acknowledged by new activity.
- Hover fill (`ThreadRowTests`): none, 60% under the pointer, full when selected.
- The glance (`MirrorGlanceTests`): three read failures and two unread finished threads give a glance whose first two rows are the finished threads.
- Approval kinds (`ActivityQueryTests`, `MirrorActivityTests`): a pending `file_change_approval` counts as an approval in the Postgres query and in the mirror.
- Top bar (`MacTopBarTests`): each button's title, symbol, identifier, shortcut and enabled state, and which buttons show with the sidebar visible and hidden; view options' symbol and ink with and without an active filter (`face(filtered:)`), and when the model counts a filter active (a connection picked, or archived threads shown). The task's smoke run (`Scripts/test-macos-smoke.sh`, recovery tests at 900 by 600) read the real window's accessibility tree: View options, Search and New thread in the bar, no "more toolbar items" control. I did not re-run it for this record.

### Snapshots looked at

Rendered after the fix wave with `B4APP_SNAPSHOT_DIR=<dir under $TMPDIR> swift test --filter SnapshotTests`: `Test run with 13 tests in 2 suites passed after 72.699 seconds.` PNGs opened and looked at:

- `rowShowsEachStateMark-light.png` and `-dark.png`: one row per state in display order, touching, 28 pt pitch. Approve is a ring around a dot, reply a large solid dot, failed a red-brown cross (salmon in dark), finished a small dot (this row is selected, so its fill spans the row with rounded corners), working a faint ring with a short lime arc, quiet no mark and a muted title. A long reply title truncates with an ellipsis before the mark. Act-level titles are medium weight, working and quiet are regular. Below a rule, a gallery of the marks still, then approve acknowledged (no pulse ring), then the six animated, caught at one instant. Distinct in shape, so it reads without colour.
- `macSidebarGroupsByEnvironment-light.png` and `-dark.png`: the real sidebar at 240 pt with groups b4app (5), Marketing site (2), Docs (0, "No threads."), No folder (1) and a pinned thread on top. Titles start at the same x everywhere, marks sit at the trailing edge, no pin glyph or runtime mark. "Pinned" and the first pinned row are clear, with no line across them. Before the fix wave this render showed a hairline across the content: the harness bridged the sidebar's `.toolbar` into its offscreen window (a 52 pt top inset whose edge cut the first row), and, without that, the window's title bar still drew a scroll view's top edge at 32 pt, under "Pinned" (it showed in `macSidebarCollapsedEnvironment` too, which has no toolbar). The harness now sets `host.sceneBridgingOptions = []` for the offscreen renders and renders the lists in a window with no title bar (`SnapshotWindow(untitled:)`). The real layout was never affected.
- `macSidebarCollapsedEnvironment-light.png` and `-dark.png`: the collapsed b4app header shows one solid dot (its most urgent state) before the count 4; no line under "Pinned".
- `arrivalTraceAtItsMoments-light.png` and `-dark.png`: nine frozen rows, the light now a short stroke on the edge, solid ink at its leading end and fading to nothing over its tail. 0.25 s sliding: a short stroke on the bottom edge near the right end, the row drawn low; 0.6 s and 2.4 s: a stroke along the bottom edge left of centre; 1.2 s lap 1: a stroke on the top edge left of centre; 1.2 s with no lap and 5 s show the hairline only; 9.25 s a fainter hairline; 0.25 s with Reduce Motion the hairline only; 10 s no outline. These are stills of a pure function of time, not the motion.
- `search-light.png`: the search palette over a real-coordinator window. Rows carry the approve target (the open thread) and the working arc; the sidebar's selected row shows the approve target too. The window toolbar is not in this render.
- `sidebar-light.png`: the same window without the palette. The selected "Release notes draft" row has its fill and a full hairline border, with the light a short dark stroke on its top edge left of centre (the arrival trace caught mid-lap); the approve target at the trailing edge; the pinned working thread above. The band above "Pinned" ends in a line across the sidebar only, above the content (this render keeps its title bar).
- `ios-list-dock-light.png`: the iOS list as drawn by macOS (Mac metrics): title and mark per row, approve absent here, reply, failed cross, finished dot, two working arcs, quiet rows without marks, filter and search icons in the header. This is not the phone's layout.
- Greyscale renders of the first two files were checked in Task 4 (`sips`) and the shapes stayed distinct.

### On-screen check (Local app, real Codex)

Done on 2026-11-11 with the Local flavour app packaged from this branch (Developer ID, not notarized), installed in `/Applications`, against the owner's local data, in light appearance, driven in the background through accessibility (so nothing here involved a real pointer or key press).

- **Top bar.** After the traffic lights: View options, Search, New thread, then the system's Hide Sidebar, with no overflow menu. Their accessibility frames are 28 by 28 each (View options at x 105, Search 137, New thread 169), which closes the review's open question about the view-options target.
- **Rows.** Thread rows report frames of 224 by 28 starting 8 pt inside the sidebar, touching, with titles on one edge and marks on the other. A read failed thread shows a medium-weight title and the red cross; quiet threads are muted with no mark; the selected row has the raised fill.
- **Working.** A thread running `sleep 25` showed the track ring with the lime arc, and the arc was at a different angle in successive captures, so it orbits.
- **Finishing while not open.** When that thread finished with another thread selected, its mark became the small ink dot and a hairline border appeared around the row (the arrival). The captures were stills taken within a second of each other, so the slide and the point of light were not seen.
- **Search.** File > Search… opened the palette, whose rows carry the same marks (cross, dot).
- **Sidebar hidden.** The main view's toolbar showed Show Sidebar, Search and New thread, and no View options; showing the sidebar again restored the three buttons there.

### Not checked

- Motion judged in motion: the approve pulse (no approval was pending), the working shimmer, the arrival slide, and the lap and its speed. The orbit was seen moving only as differing stills.
- ⌘N and ⌘K as key presses. The File menu holds "New Thread" and "Search…", and Search… was invoked from the menu; the key equivalents themselves were not pressed.
- The Mac hover fill (background control has no pointer) and the view-options icon with a filter active.
- Dark appearance and Reduce Motion in the running app.
- The phone and the widget on a device or in the Simulator: margins, the three-line wrap at accessibility sizes, `ScaledMetric` marks, the slide inside a list cell (a `List` cell may clip its 12 pt slide), and the widget's rendering. Both apps compile (the iOS scheme builds the widget).
- A hosted hub or push notification run: nothing in `Hub/` changed.

### Deviations from the plan

- A turn waiting for the user with no pending request shows as reply but does not count toward the badge, so the badge is unchanged (`countsTowardBadge`).
- The Medium font is the unmodified static file from the designer's repository; Google Fonts ships only a variable font.
- The hover fill's colour (`surfaceRaised` at 60%) came from the review; the design names none.
- ⌘N and ⌘K are File menu commands; "New Environment…" left the Mac sidebar; the Mac sidebar is fixed at 240 pt and the iPad's is not.

### Follow-ups

The fix wave (705425b) closed the review's findings. Left: the on-screen checks under "Not checked", and the deferred minors listed in D-204.
