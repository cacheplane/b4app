# Marks and rows: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every thread row shows one of six states with its own mark, on the new 28 pt single-line row, with the arrival trace and the Mac's new top bar.

**Architecture:** The four-band `AttentionBand` is replaced by a six-case `ThreadState` in `WorkspaceProtocol`, fed by one new count in `ThreadActivity` (`pendingApprovals`) that the coordinator's store and the phone's mirror both compute. `WorkspaceUI` gets a `ThreadMark` view that replaces `AttentionDot` everywhere (list, search, widget), a rewritten `ThreadRow`, a small pure `ArrivalTracker`, and toolbar buttons in place of the Mac's "New thread" and "Search" rows. The list's containers (the Mac's Pinned group and environment sections, the phone's flat list) are unchanged; the two arrangements are the next plan.

**Tech stack:** Swift and SwiftUI (`WorkspaceProtocol`, `WorkspaceStorage`, `WorkspaceMirror`, `WorkspaceUI`, the iOS widget). No hub change, no migration, no fixture change.

**Spec:** `docs/superpowers/specs/2026-11-10-thread-list-and-environments-design.md` ("Thread states and marks", "The row and the grid", "Sidebar chrome"). This is plan 3 of 6; plans 1 (D-202) and 2 (D-203) come first and must be merged before this one starts.

## Global constraints

- No backwards compatibility: `AttentionBand`, `Attention.band(of:)`, and `AttentionDot` are removed, not aliased.
- Shape carries the meaning; colour only reinforces it. The list must read correctly in greyscale. Only two things are coloured: the failed cross (LLA danger, `#962E1F` light, `#E07A6A` dark) and the working arc (lime `#B4CE37` in both modes). The cobalt accent no longer appears in the list.
- Text never blinks. Marks may move. With Reduce Motion on: no slide, no lap, no shimmer, no pulse; the orbit is a still ring with a lime arc; an arrival shows the hairline only.
- All measurements are points on a 4 pt grid. No uppercase. Hanken Grotesk 13/16 for row titles.
- The badge and notifications do not change: `needsYouCount`, the hub's badge SQL, and `Tests/Fixtures/sync/attention.json` give the same numbers as before for the same data.
- `WorkspaceUI` talks only to `WorkspaceClient`; `WorkspaceProtocol` stays Foundation-only.
- The accessibility identifiers `thread-row`, `new-thread-toolbar`, and `sidebar-search` keep their names (UI tests use them).
- Before each commit: `swift build`, the task's tests, `swift format lint --strict --recursive Sources Tests Apps Package.swift`. Tasks that touch `WorkspaceUI` or the widget also build both apps (`xcodebuild`, as in AGENTS.md) before the commit.
- Decision and verification files follow AGENTS.md; take the decision number with `Scripts/docs-index.sh --next` when the pull request opens.

## Planner's decisions

1. **Six states.** `ThreadState`: `approve`, `reply`, `failed`, `finished`, `working`, `quiet`, raw values 0–5 in that order (the display order). Computed by `Attention.state(of:)`:
   1. no `activity` → `quiet`
   2. `pendingApprovals > 0` → `approve` (approve wins when both kinds are pending)
   3. `pendingRequests > 0` → `reply`
   4. no latest turn → `quiet`
   5. latest turn status `waiting_for_user` → `reply`
   6. latest turn not terminal → `working`
   7. latest turn outcome `failed` → `failed`, read or not
   8. latest turn is not `readTurnId` → `finished`
   9. otherwise `quiet`
2. **Failed and cancelled.** Only `TurnOutcome.failed` is failed. A cancelled turn (the user stopped it) is finished, then quiet once read. This is the spec's guess, adopted.
3. **Approvals.** `pendingApprovals` counts pending requests of kind `command_approval`, `file_change_approval`, or `tool_permission`. `user_question`, `elicitation`, and `unknown` are replies.
4. **Top list.** `ThreadState.isTopList` is true for the first four; `isActLevel` for the first three.
5. **Order.** `Attention.ordered` sorts by state, then pinned first, then newest activity, then id. A pin no longer lifts a thread above a more urgent state. The Mac's separate "Pinned" group stays as it is until the arrangements plan.
6. **Badge.** `needsYouCount` counts `approve`, `reply`, and `finished`, plus `failed` only while its latest turn is unread. That is exactly today's "needs input or unread".
7. **Acknowledged approve.** The approve pulse stops once the thread has been opened on this device since its latest activity. `WorkspaceModel` keeps this in memory (`acknowledgedActivity: [threadId: lastActivityAt]`), never synced or stored.
8. **Quiet fade.** By the age of `lastActivityAt`: under 1 day 1.0, under 3 days 0.9, under 7 days 0.82, under 14 days 0.76, otherwise 0.72.
9. **Arrivals.** One trace at a time. A thread that arrives while another is tracing gets the slide and the hairline but no lap. Nothing traces on the first load, on a filter change, or when the list is rebuilt after sign-in.
10. **The pin glyph and the runtime mark leave the row** on both platforms (the spec: no runtime mark, no second line; the mark now owns the trailing edge). Both stay in the row's spoken label and the context menu.
11. **Sidebar width.** The Mac sidebar column is fixed at 240 pt. Its container is whatever the system draws today; this plan does not restyle it.
12. **View options button.** The Mac's "More" menu moves, contents unchanged, to a top-bar icon button (`line.3.horizontal.decrease`), where the arrangements plan will replace its contents. "New Environment…" leaves the sidebar; nothing replaces it (an environment is made when a folder is first used).
13. **Weight 500.** `HankenGrotesk-Medium.ttf` (the static Medium instance, OFL, from the Hanken Grotesk release on Google Fonts) is added to the bundle. Its source URL and SHA-256 go in `docs/compatibility.md`.

## Review focus

1. A coordinator or mirror row without `pendingApprovals` (an older build, a cached snapshot): it must decode as 0 and show reply, never fail to decode. Task 1.
2. The badge: a read failed thread shows a cross but is not counted; `attention.json` still passes untouched. Task 1.
3. First load and filter changes: no row slides or traces; a thread that goes working → finished → read quickly traces at most once. Task 5.
4. Reduce Motion, greyscale, and accessibility text sizes: every state is still told apart by shape and by its spoken label; the title wraps to three lines at accessibility sizes as today. Tasks 3 and 4.
5. The font fails to register: titles fall back to the system font at medium weight rather than regular. Task 2.

---

### Task 1: Six thread states

**Files:**
- Modify: `Sources/WorkspaceProtocol/Attention.swift`
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`threadWithActivity`, near line 349), `Sources/WorkspaceMirror/MirrorStore.swift` (the activity query near line 237)
- Modify: `Sources/WorkspaceMirror/MirrorNotifications.swift` (`needsYouCount`), `Sources/WorkspaceMirror/MirrorGlance.swift`
- Modify (callers, compile only, no visual change yet): `Sources/WorkspaceUI/WorkspaceModel.swift`, `EnvironmentSections.swift`, `ThreadListView.swift`, `SearchPalette.swift`, `Apps/iOSWidget/AttentionWidget.swift`
- Test: `Tests/WorkspaceProtocolTests/AttentionTests.swift`, `Tests/WorkspaceStorageTests/ActivityQueryTests.swift`, `Tests/WorkspaceMirrorTests/MirrorActivityTests.swift`, `MirrorGlanceTests.swift`, and the mirror's badge tests

**Interfaces:**
- Produces:
  - `ThreadActivity.pendingApprovals: Int` (initialiser default 0; decodes as 0 when the key is absent).
  - `public enum ThreadState: Int, Codable, Sendable, Comparable, CaseIterable { case approve, reply, failed, finished, working, quiet }` with `var isActLevel: Bool`, `var isTopList: Bool`.
  - `Attention.state(of thread: ConversationThread) -> ThreadState`, `Attention.ordered(_:)` (decision 5), `Attention.countsTowardBadge(_ thread: ConversationThread) -> Bool` (decision 6).
  - `WorkspaceModel.state(of:)` replaces `band(of:)`. `MirrorGlance` rows carry `state: ThreadState`.
- In this task the UI keeps drawing `AttentionDot`, fed by a private mapping from `ThreadState` inside `ThreadListView.swift` (approve and reply → the old needs-input dot, failed and finished → unread, working, quiet). Task 3 deletes the dot and the mapping.

- [ ] **Step 1: Write the failing protocol tests** in `AttentionTests.swift`, one per rule of decision 1 plus:

```swift
@Test func approveWinsWhenBothKindsArePending()          // pendingRequests 2, pendingApprovals 1 → .approve
@Test func aQuestionAloneIsReply()                        // pendingRequests 1, pendingApprovals 0 → .reply
@Test func aTurnWaitingForTheUserWithNoRequestIsReply()
@Test func aFailedTurnStaysFailedAfterItIsRead()          // readTurnId == latestTurnId, outcome failed → .failed
@Test func aCancelledTurnIsFinishedThenQuiet()
@Test func activityWithoutPendingApprovalsDecodesAsZero() // JSON with no key
@Test func orderIsStateThenPinThenRecency()               // a pinned quiet thread sorts below an unpinned finished one
@Test func aReadFailureDoesNotCountTowardTheBadge()
@Test func anUnreadFailureCountsTowardTheBadge()
```

- [ ] **Step 2: Run them; expect a compile failure** (`swift test --filter AttentionTests`).
- [ ] **Step 3: Implement `ThreadState` and the three `Attention` functions; delete `AttentionBand` and `band(of:)`.**
- [ ] **Step 4: Write the failing query tests.** In `ActivityQueryTests.swift` and `MirrorActivityTests.swift`: a thread with one pending `command_approval` and one pending `user_question` reads `pendingRequests == 2`, `pendingApprovals == 1`; an answered approval is not counted; a `tool_permission` is counted.
- [ ] **Step 5: Add `'pendingApprovals'` to both activity queries**, counting pending requests whose `kind` is one of the three in decision 3.
- [ ] **Step 6: Update the callers** so everything compiles on `ThreadState`; `needsYouCount` uses `Attention.countsTowardBadge`. `EnvironmentSection`'s rank uses the section's most urgent state.
- [ ] **Step 7: Run** `swift test --filter "AttentionTests|ActivityQueryTests|WorkspaceMirrorTests|AttentionModelTests|ThreadListTests"`; expect all pass, including the unchanged `attention.json` checks. Build both apps.
- [ ] **Step 8: Commit** `feat(protocol): six thread states in place of four bands`.

### Task 2: Weight 500 and the two mark colours

**Files:**
- Create: `Sources/WorkspaceUI/Resources/Fonts/HankenGrotesk-Medium.ttf`
- Modify: `Sources/WorkspaceUI/Theme/LLAFonts.swift`, `Sources/WorkspaceUI/Theme/LLATheme.swift`, `docs/compatibility.md`
- Test: `Tests/WorkspaceUITests/ThemeTests.swift`

**Interfaces:**
- Produces: `LLAFonts.sansMedium` (the PostScript name); `LLAFont.sans(_:weight:relativeTo:)` and `sans(fixed:weight:)` return the Medium face for `.medium`; `LLAFont.rowMedium`; `LLA.Color.working` (`0xB4CE37` in light and dark); a fixed 12 pt weight-500 muted style is not needed yet.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theMediumFaceIsBundledAndRegisters()      // LLAFonts.register(); LLAFonts.isAvailable(LLAFonts.sansMedium)
@Test func mediumWeightUsesTheMediumFace()            // the face chosen for .medium is sansMedium, for .regular sansRegular, for .semibold sansSemiBold
@Test func workingIsTheSameLimeInBothModes()          // LLA.Palette.working light == dark == 0xB4CE37
```

- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Add the font file** (decision 13) and record its source and SHA-256 in `docs/compatibility.md`. Check the file's license text matches the bundled `OFL-HankenGrotesk.txt`.
- [ ] **Step 4: Implement the font and colour members.** When registration fails, `.medium` falls back to `.system(size:weight: .medium)` (review focus 5); add a test for the fallback using the existing `register(bundle:)` seam with a bundle that has no fonts.
- [ ] **Step 5: Run** `swift test --filter ThemeTests`; expect all pass.
- [ ] **Step 6: Commit** `feat(theme): Hanken Grotesk Medium and the working lime`.

### Task 3: The mark

**Files:**
- Create: `Sources/WorkspaceUI/Theme/ThreadMark.swift`
- Modify: `Sources/WorkspaceUI/ThreadListView.swift` (delete `AttentionDot` and Task 1's mapping), `SearchPalette.swift`, `Apps/iOSWidget/AttentionWidget.swift`, `Sources/WorkspaceUI/WorkspaceModel.swift` (`reasonLine`, `acknowledgedActivity`)
- Test: create `Tests/WorkspaceUITests/ThreadMarkTests.swift`; extend `SnapshotTests.swift` (opt-in PNG renders), update `ReasonLineTimeTests.swift`

**Interfaces:**
- Consumes: `ThreadState`, `LLA.Color.working`, `LLA.Color.danger`.
- Produces:
  - `public struct ThreadMark: View { public init(state: ThreadState, acknowledged: Bool = false, animated: Bool = true) }` drawn in a 12 pt box (a `@ScaledMetric` relative to `.body`, so it grows with the text). `animated: false` is for the widget.
  - `ThreadMark.Motion`: `static func pulses(state:acknowledged:reduceMotion:) -> Bool`, `static func orbits(state:reduceMotion:) -> Bool`.
  - `ThreadState.spokenLabel: String`: "Needs your approval", "Needs your reply", "Failed", "Finished", "Working", "Quiet".
  - `WorkspaceModel.isAcknowledged(_ thread: ConversationThread) -> Bool`; `openThread(id:)` records the thread's `lastActivityAt`.

**Geometry, in the mark's own 12 by 12 box (scale with the box):**

| State | Drawing | Colour |
|---|---|---|
| approve | filled dot r 2.25 inside a ring r 4.75, stroke 1.5; while pulsing, a second ring r 4.75 scales .5 → 1.3 and fades to 0 over 1.25 s ease-out, repeating | ink |
| reply | filled dot r 4 | ink |
| failed | two strokes, (2.6, 2.6)→(9.4, 9.4) and (9.4, 2.6)→(2.6, 9.4), width 1.8, round caps | danger |
| finished | filled dot r 2.5 | ink |
| working | track ring r 3.25, stroke 1.5, ink at 22%; arc r 3.25, stroke 1.75, dash 6.4 / 14, round caps, one turn per 1.4 s linear | arc `LLA.Color.working` |
| quiet | nothing (the box keeps its size) | — |

- [ ] **Step 1: Write the failing tests** in `ThreadMarkTests.swift`:

```swift
@Test func onlyApprovePulsesAndOnlyUntilAcknowledged()
@Test func nothingMovesUnderReduceMotion()            // pulses and orbits false for every state
@Test func onlyWorkingOrbits()
@Test func everyStateHasItsOwnSpokenLabel()           // six distinct, non-empty labels
@Test func openingAThreadAcknowledgesIt()             // model.isAcknowledged true after openThread
@Test func newActivityClearsTheAcknowledgement()      // lastActivityAt changes → false again
```

- [ ] **Step 2: Run them; expect a compile failure.**
- [ ] **Step 3: Implement `ThreadMark`** from the table, with `Canvas` or `Shape`s; the orbit and pulse run only while the two `Motion` functions say so, and reset when they stop (follow the phase-reset pattern in today's `AttentionDot.task(id:)`). The accessibility label is `spokenLabel`; quiet is hidden from accessibility.
- [ ] **Step 4: Replace every `AttentionDot`** (list rows, the search palette, the widget with `animated: false`) and delete it. `reasonLine` switches on `ThreadState`: failed says "Failed" with its relative time whether or not it was read.
- [ ] **Step 5: Extend `SnapshotTests`** (the opt-in PNG renderer: `B4APP_SNAPSHOT_DIR=<dir> swift test --filter SnapshotTests`, nothing is compared against a baseline) so its sidebar has at least one thread in each of the six states. Render light and dark, look at each PNG, and say in the report what each shows. The renderer draws one still, so motion is not judged here.
- [ ] **Step 6: Run** `swift test --filter "ThreadMarkTests|SnapshotTests|ReasonLineTimeTests|WorkspaceMirrorTests"`; build both apps.
- [ ] **Step 7: Commit** `feat(ui): one mark per thread state`.

### Task 4: The row

**Files:**
- Modify: `Sources/WorkspaceUI/ThreadListView.swift` (`ThreadRow`), `Sources/WorkspaceUI/Theme/LLATheme.swift` (row metrics), `Sources/WorkspaceUI/WorkspaceRootView.swift:83` (column width)
- Create: `Sources/WorkspaceUI/Theme/RowEffects.swift` (`QuietFade`, the working shimmer)
- Test: create `Tests/WorkspaceUITests/ThreadRowTests.swift`; update `ThreadListTests.swift`, `SnapshotTests.swift`, and the iOS layout harness if it names what changes

**Interfaces:**
- Consumes: `ThreadMark`, `LLAFont.rowMedium`, `WorkspaceModel.state(of:)`, `isAcknowledged`.
- Produces:
  - `enum QuietFade { static func opacity(ageInDays: Double) -> Double }` (decision 8).
  - `extension View { func workingShimmer(active: Bool) -> some View }`.
  - `LLA.Metrics.sidebarWidth: CGFloat = 240`, `LLA.Metrics.threadRow: CGFloat` (28 on the Mac, 44 on the phone), `LLA.Metrics.mark: CGFloat = 12`.
  - `ThreadRow.titleWeight(for: ThreadState) -> Font.Weight` (medium for act level, regular otherwise).

**The Mac row:** 28 high, no gap between rows. The fill (selection, hover) spans x 8–232 of the 240 pt sidebar with radius 8. The title starts at x 16. The mark's 12 pt box sits at x 212–224, with at least 8 between title and mark. One line, truncating with an ellipsis. No leading dot, no runtime mark, no pin glyph. Selection is `LLA.Color.surfaceRaised`.

**The phone row:** the same content and order; minimum height 44; Dynamic Type; the title may wrap to three lines at accessibility sizes, as today.

**Title treatment by state:** act level (approve, reply, failed): weight 500, ink. Finished: 400, ink. Working: 400, with the shimmer. Quiet: 400, muted, at `QuietFade` opacity.

**Shimmer:** the title is drawn with a horizontal gradient: dimmed ink (ink mixed 78% over the surface colour) with a band of full ink at the centre, the gradient twice the title's width, sweeping once per 4 s ease-in-out, repeating. Brightness only; the text is never invisible. Off under Reduce Motion (plain ink).

- [ ] **Step 1: Write the failing tests** in `ThreadRowTests.swift`:

```swift
@Test func quietFadesInFiveSteps()          // 0.5 d → 1.0, 2 d → 0.9, 5 d → 0.82, 10 d → 0.76, 30 d → 0.72, and never below 0.72
@Test func actLevelTitlesAreMedium()         // approve, reply, failed → .medium; finished, working, quiet → .regular
@Test func theRowSpeaksWhatItNoLongerShows() // accessibility label still has "Pinned", the connection label, and the state's spoken label
@Test func macRowMetricsAreOnTheGrid()       // threadRow 28, sidebarWidth 240, mark 12 (macOS only)
```

- [ ] **Step 2: Run them; expect a compile failure.**
- [ ] **Step 3: Implement the metrics, `QuietFade`, and the shimmer.**
- [ ] **Step 4: Rewrite `ThreadRow`'s label** to the layouts above. The button, its actions, the context menu, the rename and delete alerts, and the identifiers are unchanged. Fix the sidebar column at 240.
- [ ] **Step 5: Render the sidebar snapshots again** (light and dark) and look at each PNG. Make a greyscale copy of the light one (`sips -s format png --matchTo '/System/Library/ColorSync/Profiles/Generic Gray Profile.icc'`) and confirm in the report that the six states can still be told apart.
- [ ] **Step 6: Run** `swift test --filter "ThreadRowTests|ThreadListTests|SnapshotTests"`; build both apps; run the iOS layout tests the repository's CI runs if the harness was touched.
- [ ] **Step 7: Commit** `feat(ui): the single-line thread row`.

### Task 5: The arrival trace

**Files:**
- Create: `Sources/WorkspaceUI/ArrivalTracker.swift`, `Sources/WorkspaceUI/Theme/ArrivalTrace.swift`
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (feed the tracker where the thread list is replaced or updated), `Sources/WorkspaceUI/ThreadListView.swift` (`ThreadRow` applies the effect)
- Test: create `Tests/WorkspaceUITests/ArrivalTrackerTests.swift`

**Interfaces:**
- Produces:
  - `struct ArrivalTracker { mutating func update(_ states: [String: ThreadState], at now: Date) -> [Arrival]; func arrival(for threadId: String, at now: Date) -> Arrival? }` where `struct Arrival: Equatable { var threadId: String; var at: Date; var laps: Bool }`. An arrival is a thread whose state was not top-list (or that was not in the last update) and is top-list now. The first `update` after `reset()` records states and returns nothing. `laps` is false when another arrival's lap window (3.5 s) is still open. An arrival expires 10 s after `at`.
  - `mutating func reset()`: called on sign-in, sign-out, and whenever the filter or the connection filter changes.
  - `WorkspaceModel.arrival(for: ConversationThread) -> Arrival?`.
  - `extension View { func arrivalTrace(_ arrival: Arrival?, reduceMotion: Bool) -> some View }`.

**The effect:** the row slides in from 12 pt below over about 0.5 s, ease-out. Over the row's rounded edge (radius 8) a 0.5 pt inset hairline at 30% ink appears; a point of light (a short conic-gradient highlight on the same edge) laps it twice in about 3.5 s in all; the hairline fades out by 10 s. With `laps == false` or Reduce Motion: no slide under Reduce Motion, no lap in either case, the hairline only.

- [ ] **Step 1: Write the failing tests** in `ArrivalTrackerTests.swift`:

```swift
@Test func theFirstUpdateTracesNothing()
@Test func enteringTheTopListIsAnArrival()            // working → finished
@Test func movingWithinTheTopListIsNotAnArrival()     // finished → approve
@Test func aNewThreadAlreadyInTheTopListIsAnArrival() // absent → reply, after the first update
@Test func aSecondArrivalWithinTheLapWindowDoesNotLap()
@Test func anArrivalExpiresAfterTenSeconds()
@Test func resetForgetsEverything()                    // the update after reset traces nothing
@Test func leavingAndReenteringTracesAgain()           // finished → quiet → finished: two arrivals
```

- [ ] **Step 2: Run them; expect a compile failure.**
- [ ] **Step 3: Implement `ArrivalTracker`** as a pure value type with no timers; callers pass `now`.
- [ ] **Step 4: Feed it from the model** (one call per thread-list change, using `model.now()`), call `reset()` at the three places named above, and add model tests: a filter change produces no arrivals; a thread finishing while the list is showing produces one.
- [ ] **Step 5: Implement the view effect and apply it in `ThreadRow`.** The row asks the model for its arrival; when the arrival expires the effect is gone without a layout change.
- [ ] **Step 6: Run** `swift test --filter "ArrivalTrackerTests|AttentionModelTests|ThreadListTests"`; build both apps.
- [ ] **Step 7: Commit** `feat(ui): trace a thread's arrival in the top of the list`.

### Task 6: The Mac's top bar

**Files:**
- Modify: `Sources/WorkspaceUI/SidebarView.swift` (remove `actionRows`' "New thread" and "Search" rows and the "New Environment…" row; `MoreMenu` becomes a toolbar button), `Sources/WorkspaceUI/ThreadsView.swift` or `WorkspaceRootView.swift` (the main view's toolbar when the sidebar is hidden)
- Test: `Tests/WorkspaceUITests/` (the sidebar and command tests that name these rows), the macOS UI or snapshot tests that open the sidebar

**Interfaces:**
- Consumes: `model.openNewThread()`, `model.showSearch`, `model.newThreadEntryReason`, the existing `MoreMenu` contents.
- Produces: no new model API. Top bar, left to right after the traffic lights and a flexible space: view options (`line.3.horizontal.decrease`, identifier `view-options`, muted), search (`magnifyingglass`, `sidebar-search`, ⌘K, muted), new thread (`square.and.pencil`, `new-thread-toolbar`, ⌘N, ink), then the system's sidebar toggle.

- [ ] **Step 1: Write or update the failing tests:** the sidebar has no "New thread", "Search", or "New Environment…" row; ⌘N and ⌘K still work; new thread is disabled with `newThreadEntryReason` as its help text when that reason is set; with the sidebar hidden, search and new thread are in the main view's toolbar and the view-options button is not.
- [ ] **Step 2: Run them; expect failures.**
- [ ] **Step 3: Implement the toolbar** in the sidebar column and the hidden-sidebar toolbar in the main view. The view-options button opens the same menu `MoreMenu` shows today. The phone is unchanged: its docked "New thread" composer and its navigation-bar icons already match the spec.
- [ ] **Step 4: Remove what is now unused** on the Mac (`SidebarActionRow` if nothing else uses it, the Mac-only create-environment entry point). The phone's create-environment sheet is left for the environment-form plan.
- [ ] **Step 5: Render the Mac sidebar snapshot again and look at it**; run `swift test --filter WorkspaceUITests`; build both apps.
- [ ] **Step 6: Commit** `feat(ui): new thread and search move to the Mac's top bar`.

### Task 7: Records and gates

**Files:**
- Create: `docs/decisions/D-NNN-marks-and-rows.md`, `docs/verification/YYYY-MM-DD-marks-and-rows.md`
- Modify: `docs/milestones.md`, `AGENTS.md` (Layout: `ThreadState`, `ThreadMark`, the widget shares the mark)

- [ ] **Step 1: Write the decision.** One bullet in the log's style covering the thirteen planner's decisions. It amends D-036 (one accent: the list no longer uses it; lime and danger are the only colours), D-048 (bands), D-053 (row content), and D-126 (the widget's dot is now the shared mark). State the three LLA rules the owner knowingly bent (motion on several rows, one gradient, per the spec's Constraints).
- [ ] **Step 2: Run every gate** one at a time and record each result line: `swift build`, `swift test`, the format lint, the hub's tests with `cargo fmt` and `cargo clippy` (nothing in `Hub/` changes; they confirm it), both `xcodebuild` builds, `Scripts/docs-index.sh --check`.
- [ ] **Step 3: Record what was looked at.** The rendered snapshots, by name and what each shows. Animation timing cannot be judged from stills: record the orbit, pulse, shimmer, slide, and lap as not checked in motion, for the on-screen pass that follows.
- [ ] **Step 4: Update `docs/milestones.md`.**
- [ ] **Step 5: Commit** `docs: record marks and rows`.
