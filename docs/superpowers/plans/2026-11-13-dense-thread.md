# Dense thread Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With Dense on, a thread shows each turn as the user's message, one line for the agent's work, and the answer. While the turn runs the line names what the agent is doing; once it has ended the line counts the steps. The line opens to show the work in place.

**Architecture:** A pure function, `DenseTranscript.entries`, turns a thread's items and turns into the list of things to draw (items, lines, turn notes); it has no SwiftUI in it and carries every rule about what is a step, an answer, a failure, or a running turn. `TranscriptView` draws that list when `dense` is true and is today's code, untouched, when it is false. Which turns are open is view state, never stored. The phone gets the Display page, since Dense now changes something there.

**Tech Stack:** Swift 6, SwiftUI (macOS 26, iOS 26), Swift Testing. UI only: no hub, store, mirror or wire change, and no migration.

**Spec:** `docs/superpowers/specs/2026-11-12-density-and-user-settings-design.md`, "Part 3: a dense thread", as amended on 2026-11-13 (the amendment is in the spec, under part 3), and the Display page line of part 2. Part 4 (the composer) is not in this plan: in dense the composer keeps its pickers.

**Research:** `reports/Rendering agent progress in threads.md` (not committed) is why this plan was revised on 2026-11-13. The seven changes it led to are calls 1 to 7 below.

**Base:** `main` after pull request 189 (D-218) has merged. Branch `blove/dense-thread`.

## Global Constraints

- Normal density is today's transcript, unchanged: the `dense == false` path keeps the existing body, order and scroll behaviour, and a test pins its height against the same content before and after.
- `WorkspaceUI` talks only to `WorkspaceClient`. Nothing here reads a store or the hub. Every rule reads `DisplayItem` and `Turn` rows only, so the phone draws the same thing as the Mac.
- LLA: no colour beyond what the transcript already uses (ink, muted, danger), no uppercase, no animation on open or close (`withAnimation(.none)`, as `CollapsibleCard`), no spinner and no ticking clock on the line.
- The phone keeps 44 pt touch targets (`LLA.Metrics.row`) and Dynamic Type; the line is one line cut at its tail at ordinary sizes and wraps at accessibility sizes.
- Dense never hides: a pending approval or question (drawn by `RuntimeRequestList`, outside the transcript, untouched), "Turn failed." and "Turn stopped.", the unknown-outcome notice, the phone's pending message.
- Whether a turn is open is `@State`, reset when another thread is shown; it is never written to `LocalPreferences`, the store or the hub.
- Exact copy. Ended: `4 steps`, `1 step`, `4 steps, 1 failed`, `4 steps, 1 declined`, `4 steps, 1 failed, 1 declined`. Running: the running step's name, or `Working`; `Waiting for you`. Actions: `Show`, `Hide`, `Show working`, `Hide working`. "N failed" is in `LLA.Color.danger`; everything else in `LLA.Color.muted`, `LLAFont.small`. `3 steps so far` is gone.
- Decision and verification records follow AGENTS.md; take the decision number with `Scripts/docs-index.sh --next` when the pull request is opened.
- Gates: `swift format lint --strict --recursive Sources Tests Apps Package.swift`, `swift test`, both `xcodebuild` builds, `Scripts/docs-index.sh --check`. The controller reruns them and quotes counts from the saved log.

## The plan's own calls

Each is recorded in the decision entry. Calls 1 to 7 came from the research and replace what the first version of this plan said.

1. **A running turn's line names what the agent is doing; it does not count.** The name is that of the turn's newest counted step whose status is `inProgress`: B4's `payload.label` when it has one, otherwise the title its card draws. With no step in progress the line reads `Working`. A turn whose status is `waiting_for_user` reads `Waiting for you` (it covers an approval and a question). The count appears when the turn ends.
2. **Messages fold when the turn ends, not while it runs.** While a turn runs, every `agentMessage` of the turn is drawn after the line, in order. When it has ended, the answer is the turn's last `agentMessage` with no counted step after it; the earlier messages are folded with the steps.
3. **A counted step is a tool call, by type.** Role `tool` and type one of `commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `webSearch`, `imageView`, `toolCall`, or `toolUse` whose `payload.name` is not `TodoWrite`. Every other `tool`-role item (B4's `plan_update` and its other named events, Codex's `enteredReviewMode` and `functionCallOutput`, a type this list does not know) is working: folded, shown when opened, not counted, and never part of the answer test.
4. **Declined is not failed.** `failed` counts steps whose status is `failed`; `declined` counts those whose status is `declined`, and is drawn muted.
5. **A turn that is not running never shows a running step.** In a turn that has ended, and in a group read from history, a step still `inProgress` is drawn with its status as `stopped` (the card's badge is muted), and it is counted as a step.
6. **Items with no turn are grouped at user messages.** A turnless `user` item starts a group of its own (key `h-<item id>`); any other turnless item joins the group of the item before it, whether that is a turn or a history group. A history group is drawn as an ended turn with no note. Turnless items before the first group are drawn as they are.
7. **Opening a turn holds the view until the reader goes back to the end.** From a toggle until the reader scrolls to the end, sends a message, or shows another thread, the transcript neither pins its bottom edge nor follows the stream.
8. **A turn whose outcome is unknown (`reconciling`) is drawn as ended**: the count, no name, its steps left as they are. The unknown-outcome notice already says what happened.
9. **Order within a turn:** the user's message, the line, then the messages the closed turn shows, the turn's system items, then the turn's note. Opened, everything the turn holds besides its user and system items is drawn after the line in sequence order, so the messages stand where the agent wrote them.
10. **A turn's items are gathered where its first item stands**, so a turn never has two lines.
11. **The Display page's description** becomes, on the Mac, "Tighter rows for the threads that don’t need you, and answers without the steps in a thread." and on the phone "Answers without the steps in a thread." The composer is added to it by part 4.

Left out on purpose, each a follow-up: elapsed time and "Worked for 1m 12s" on the line, the failed step's name and reason under the closed line, a checklist drawing of plan and todo items, the 300 ms no-flash window, and anything that needs the adapters or the store (the turn's failure reason, step durations, sub-agent grouping).

## Review Focus

1. A turn ends while the reader is on its answer: the earlier messages fold above it and the answer must not move (the bottom edge is pinned) nor lose its identity (same `id`). Task 1's `messagesFoldWhenTheTurnEnds`, Task 2's id assertion, Task 3's `theAnswerStaysPutWhenItsTurnEnds`.
2. A thread read from history, and one with both history items and live turns: every user message gets one line, no item is drawn twice, none is dropped. Task 1's `aThreadFromHistoryIsGroupedAtUserMessages` and `everyItemIsDrawnExactlyOnceWhenEverythingIsOpen`.
3. A turn id on items that `detail.turns` does not contain (a thread read mid-change): drawn as ended, no note, no crash. Task 1's `aTurnTheListDoesNotKnowIsDrawnAsEnded`.
4. Opening a turn near the bottom of a long thread while another turn streams: the line must not move, then or as text arrives. Task 3's scroll tests.
5. A running step with a long or many-line command: the line stays one line and the name is cut. Task 1's `theNameIsTheLabelThenTheCardTitleCutAt120`, Task 2's snapshot.

---

### Task 1: What a dense thread draws

**Files:**
- Create: `Sources/WorkspaceUI/DenseTranscript.swift`
- Modify: `Sources/WorkspaceUI/TranscriptView.swift` (`ToolCard.title` becomes a call to `DenseTranscript.title(of:)`, nothing else)
- Test: `Tests/WorkspaceUITests/DenseTranscriptTests.swift`

**Interfaces:**
- Consumes: `DisplayItem`, `Turn` (`WorkspaceProtocol`).
- Produces:

```swift
/// What a thread draws at dense density, in order. No SwiftUI.
enum DenseTranscript {
  enum Entry: Equatable, Identifiable, Sendable {
    case item(DisplayItem)   // drawn by TranscriptRow, as at normal density
    case line(StepsLine)     // the turn's line
    case note(Turn)          // "Turn failed." / "Turn stopped."
    var id: String           // item.id, "steps-<group>", "note-<turnId>"
  }

  struct StepsLine: Equatable, Sendable {
    var group: String         // the turn id, or "h-<user item id>" for a history group
    var folded: [DisplayItem] // what the closed line hides, in sequence order
    var counted: Int          // counted steps, whatever their status
    var failed: Int           // counted steps whose status is "failed"
    var declined: Int         // counted steps whose status is "declined"
    var running: Bool
    var waiting: Bool         // running, and the turn's status is waiting_for_user
    var runningName: String?  // running only: the newest inProgress counted step's name
    /// Running: "Waiting for you", else the name, else "Working".
    /// Ended: "4 steps" / "1 step", or nil when nothing is counted.
    var text: String? { get }
    var failedText: String? { get }    // "1 failed"
    var declinedText: String? { get }  // "1 declined"
    /// "Show" / "Hide"; "Show working" / "Hide working" when `text` is nil.
    func action(open: Bool) -> String
    /// text, failedText, declinedText and the action, joined by ", ".
    func spoken(open: Bool) -> String
  }

  /// The title a tool item's card draws (moved from `ToolCard`, unchanged).
  static func title(of item: DisplayItem) -> String
  /// Call 3.
  static func isCountedStep(_ item: DisplayItem) -> Bool
  /// `open` holds the groups whose lines are open.
  static func entries(items: [DisplayItem], turns: [Turn], open: Set<String>) -> [Entry]
}
```

Rules, beyond "The plan's own calls":

- A turn is running when `turns` holds it with status `submitting`, `running`, `waiting_for_user` or `stopping`. Everything else is ended: `terminal`, `reconciling`, a turn id `turns` does not hold, a history group.
- A turn's note is emitted when it is terminal with an outcome other than `completed`.
- The name (call 1) is the first line of `payload.label` when that is a non-empty string, otherwise of `title(of:)`; trimmed, and cut to 120 characters ending in `…` when longer.
- A group with nothing to fold has no line. An ended group whose folded items hold no counted step has `text == nil` ("Show working"). A running group with anything folded always has text.
- Call 5 rewrites `payload["status"]` to `"stopped"` on the `.item` entry and in `folded`; the stored item is not touched and its `id` is unchanged.
- Inside a group, `user` items come first, `system` items after the closed turn's messages.
- Terminal turns with a note and no items are appended after everything else, in `turns` order.

- [ ] **Step 1: Write the failing tests** in `DenseTranscriptTests` (a `@Suite struct`, fixtures built with a local `item(_ id:, turn:, role:, type:, status:, seq:, payload:)` helper and `Turn(id:threadId:operationId:status:outcome:)`). Each asserts the full `entries(...)` result as a list of ids, plus the line's fields it names:

  - `anEndedTurnIsMessageLineAnswer`: user, reasoning, three `commandExecution` (one `failed`), an interim `agentMessage`, a `toolUse`, a final `agentMessage` → ids `[u1, steps-t1, a2]`; `counted == 4`, `failed == 1`, `text == "4 steps"`, `failedText == "1 failed"`, `declinedText == nil`, `action(open: false) == "Show"`, `spoken(open: false) == "4 steps, 1 failed, Show"`, `folded` ids are the six folded items in order.
  - `oneStepIsSingular`: `text == "1 step"`.
  - `aDeclinedStepIsCountedApartFromFailed`: one `declined`, one `failed`, two `completed` → `counted == 4`, `failed == 1`, `declined == 1`, `spoken(open: false) == "4 steps, 1 failed, 1 declined, Show"`.
  - `planAndCapabilityItemsAreNotSteps`: a `plan_update` (role tool, payload `event`), an `enteredReviewMode`, a `toolUse` named `TodoWrite`, a `functionCallOutput` and one `toolCall` → `counted == 1`, all five in `folded`. `isCountedStep` is true for each of the eight types in call 3 and false for role `assistant` with type `toolUse`.
  - `aTrailingCapabilityItemDoesNotHideTheAnswer`: user, `toolCall`, `agentMessage`, `plan_update` → `[u1, steps-t1, a1]`.
  - `aTurnWithOnlyAnAnswerHasNoLine`: `[u1, a1]`.
  - `reasoningAloneGetsShowWorking`: ended turn, reasoning and an answer → `text == nil`, `action(open: false) == "Show working"`, `action(open: true) == "Hide working"`.
  - `anOpenTurnDrawsEverythingInOrder`: `open: ["t1"]` over user, reasoning, tool, interim message, tool, answer → `[u1, steps-t1, r1, tool1, a1, tool2, a2]`; `action(open: true) == "Hide"`.
  - `aFailedTurnWithNoAnswerShowsItsLineAndNote`: `[u1, steps-t1, note-t1]`.
  - `aStoppedTurnWithAnAnswerEndsWithItsNote`: `[u1, steps-t1, a1, note-t1]`.
  - `aStoppedTurnsUnfinishedStepReadsStopped`: a cancelled turn with one `completed` and one `inProgress` tool → `counted == 2`, `running == false`, `text == "2 steps"`; opened, the second step's entry has `payload["status"] == "stopped"` and its own id.
  - `aRunningTurnNamesItsNewestRunningStep`: two completed tools, then two `inProgress` (`commandExecution` with command `swift test`, later a `toolUse` named `Read` with path `Package.swift`) → `running == true`, `text == "Read: Package.swift"`; with only the first in progress, `"swift test"`.
  - `theNameIsTheLabelThenTheCardTitleCutAt120`: a B4 `toolCall` with `label: "Searching b4"` → `"Searching b4"`; a command of 200 characters → 120 characters ending in `…`; a two-line command → its first line.
  - `aRunningTurnBetweenStepsReadsWorking`: every tool completed, turn running → `text == "Working"`, `action(open: false) == "Show"`; a failed step among them → `failedText == "1 failed"` as well.
  - `aTurnWaitingOnTheUserSaysSo`: status `waiting_for_user` with a tool `inProgress` → `waiting == true`, `text == "Waiting for you"`.
  - `aTurnWhoseOutcomeIsUnknownCounts`: status `reconciling`, one tool `inProgress` → `running == false`, `text == "1 step"`, the step's status still `inProgress`, no note.
  - `messagesStayWhileTheTurnRuns`: running turn of user, message m1, tool, message m2, tool (in progress) → `[u1, steps-t1, m1, m2]`; `folded` holds the two tools only.
  - `messagesFoldWhenTheTurnEnds`: the same items plus a final message m3, turn terminal and completed → `[u1, steps-t1, m3]`; m1 and m2 are in `folded`; m3's entry id is the id it had while streaming.
  - `aRunningTurnWithNothingYetHasNoLine`: user item only → `[u1]`; with a streaming message only → `[u1, m1]`.
  - `aThreadFromHistoryIsGroupedAtUserMessages`: eight items, all `turnId: nil` (user, tool, tool, message, user, reasoning, message, message), `turns` empty → `[u1, steps-h-u1, m1, u2, steps-h-u2, m3]`; the first line reads `2 steps`, the second `Show working`.
  - `aTurnlessItemJoinsTheGroupBeforeIt`: turn `t1`'s items, then a turnless `toolUse` and a turnless `agentMessage` (Claude items after `result`), turn terminal → one `steps-t1`, `counted` includes the late tool, the late message is the answer.
  - `turnlessItemsBeforeAnyGroupAreDrawnAsTheyAre`: a turnless system item and a turnless tool first, then a turn → both first, as `.item`, no line for them.
  - `systemItemsFollowTheirTurnsMessages`: a `contextCompaction` system item sequenced mid-turn → after the answer, before the note.
  - `twoTurnsEachGetTheirOwnLine`: ids unique across the list; a turnless item sequenced inside `t1` leaves one `steps-t1`.
  - `aTurnTheListDoesNotKnowIsDrawnAsEnded`: items carry `turnId: "ghost"`, `turns` is empty → line with `running == false`, no note.
  - `aTurnWithNoItemsKeepsItsNote`: `turns` holds a terminal `failed` turn, `items` is empty → `[note-t1]`.
  - `everyItemIsDrawnExactlyOnceWhenEverythingIsOpen`: for a mixed thread (history groups, an ended turn, a running turn, stray turnless items), with every group open the `.item` ids are exactly the input ids, each once.
  - `theCardTitleIsUnchanged`: `title(of:)` for a `commandExecution`, a two-file `fileChange`, an `mcpToolCall`, a `webSearch`, a `toolUse` with a path, a `toolCall` with input, and an unknown type gives today's strings.

- [ ] **Step 2: Run them and see them fail.** `swift test --filter DenseTranscriptTests` → does not compile (`DenseTranscript` undefined).
- [ ] **Step 3: Implement `DenseTranscript`** as declared above: one pass over `items` assigning each to a group, then one function that lays out a group. Move `ToolCard`'s title switch into `title(of:)` and call it from `ToolCard`.
- [ ] **Step 4: Run them and see them pass.** `swift test --filter DenseTranscriptTests` → 28 tests pass.
- [ ] **Step 5: Commit.** `feat(ui): what a dense thread draws for each turn`

### Task 2: Drawing the dense thread

**Files:**
- Modify: `Sources/WorkspaceUI/TranscriptView.swift` (the body; a new `StepsLineRow`)
- Modify: `Sources/WorkspaceUI/ThreadsView.swift:136-140` (`transcript(_:)` passes `dense`)
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (next to `tightQuietRows`)
- Test: `Tests/WorkspaceUITests/DenseTranscriptViewTests.swift` (new, macOS), `Tests/WorkspaceUITests/SnapshotTests.swift` (`ListSnapshotTests`)

**Interfaces:**
- Consumes: `DenseTranscript.entries(items:turns:open:)`, `StepsLine` (Task 1).
- Produces:

```swift
extension WorkspaceModel {
  /// Dense draws a thread as message, line, answer. Both platforms.
  var denseThread: Bool { viewSettings.density == .dense }
}

struct TranscriptView: View {
  let detail: ThreadDetail
  var pending: PendingSend? = nil
  var pendingStatus: String? = nil
  var dense = false
}

/// Which groups are open. Owned by `TranscriptView` as `@State`; an internal initializer argument
/// (defaulting to a new one) lets a test hold it.
@Observable final class TranscriptFolds {
  var open: Set<String>
  func toggle(_ group: String)
  func reset()
}

/// The turn's line: a plain button. Identifier "steps-line"; one accessibility element whose label
/// is `line.spoken(open:)`.
struct StepsLineRow: View {
  let line: DenseTranscript.StepsLine
  let open: Bool
  let toggle: () -> Void
}
```

  `TranscriptView` calls `folds.reset()` in `.onChange(of: detail.thread.id)`. When `dense`, the `ForEach(detail.items)` and the `ForEach` of turn notes are replaced by one `ForEach` over `DenseTranscript.entries(items: detail.items, turns: detail.turns, open: folds.open)`: `.item` → `TranscriptRow` with the same `liveText` lookup and `.id(item.id)`; `.line` → `StepsLineRow(...).id(entry.id)`; `.note` → `TurnNoteRow`. The empty-thread text, the pending row, the unknown-outcome notice, the `"bottom"` marker and every `onChange` stay as they are for both densities. When `!dense` the body is exactly today's.

  `StepsLineRow` layout: an `HStack(spacing: LLA.Space.xs)` of the text (muted, `lineLimit(1)`, cut at the tail, and the only part that shrinks), `failedText` (danger), `declinedText` (muted), with ", " between the parts that are present, then the action word (muted, never cut), all `LLAFont.small`; `.frame(maxWidth: .infinity, minHeight: LLA.Metrics.row, alignment: .leading)`, `.contentShape(Rectangle())`, `.buttonStyle(.plain)`; at accessibility type sizes a `VStack` with no line limit, as `CollapsibleCard` does. No border, no fill, no icon, no spinner. A running line looks the same as an ended one; only its words differ.

- [ ] **Step 1: Write the failing tests.** In `DenseTranscriptViewTests` (`@Suite(.serialized) @MainActor`, `#if os(macOS)`, hosting views in `NSHostingView` at a fixed 720 pt width and reading `fittingSize.height` of a non-scrolling harness: extract the stack's content into an internal `TranscriptContent` view that `TranscriptView` wraps in its `ScrollView`, so the tests measure the content itself):

  - `normalDensityIsTodaysTranscript`: for a detail with a user message, a reasoning item, two tool items and an answer, `TranscriptContent(dense: false)` has the same height as a `VStack` of `TranscriptRow`s for those five items at the transcript's spacing and padding.
  - `denseIsShorterByTheFoldedSteps`: the same detail at `dense: true` is shorter than normal, and equals user row + `StepsLineRow` + answer row.
  - `anOpenTurnIsAsTallAsNormalPlusTheLine`.
  - `aThreadFromHistoryIsDenseToo`: the same five items with `turnId: nil` and no turns give the same dense height.
  - `aFailedTurnsNoteIsDrawnAtBothDensities`: the dense content contains the text "Turn failed." (found through the hosted view's accessibility children) for a terminal failed turn.
  - `theLineReadsAsOneElement`: `StepsLineRow`'s accessibility label is `"4 steps, 1 failed, Show"`; `"Show working"` when nothing is counted; `"swift test, Show"` for a running line.
  - `aLongRunningNameKeepsTheLineOneLineHigh`: a running line whose name is 120 characters is as tall as one reading `Working`, at 320 pt wide, and its action word is not cut (the row's accessibility label still ends in "Show").
  - `anAnswerKeepsItsRowWhenItsTurnEnds`: before and after the turn becomes terminal, the entry for the last message has the same `id`.
  - `openTurnsAreForgottenWithTheThread`: drive `TranscriptView` through a small `@Observable` test host that swaps `detail` to another thread and back; the turn is closed again.
  - In `ViewSettingsModelTests`: `denseThread` is true exactly when the stored density is dense, on a model with `accountSource == .host` as well as the Mac's.

- [ ] **Step 2: Run and see them fail** (`swift test --filter DenseTranscriptViewTests` → does not compile).
- [ ] **Step 3: Implement** `denseThread`, `TranscriptFolds`, `TranscriptContent`, `StepsLineRow`, the dense branch, and pass `dense: model.denseThread` from `ThreadDetailView.transcript(_:)`.
- [ ] **Step 4: Add the snapshots** to `ListSnapshotTests`, each from a scripted `ThreadDetail` (no live runtime) at 720 by 560: `dense-thread-closed`, `dense-thread-open`, `dense-thread-failed` (one failed and one declined step, a failed turn with no answer), `dense-thread-running` (a named running step over two interim messages, the second streaming), `dense-thread-waiting` ("Waiting for you"), `dense-thread-working` ("Show working"), `dense-thread-history` (three turnless exchanges), and `thread-normal` from the first detail for comparison.
- [ ] **Step 5: Run.** `swift test --filter "DenseTranscript|ViewSettingsModelTests|ListSnapshotTests"` → all pass. Then `B4APP_SNAPSHOT_DIR=<scratch> swift test --filter ListSnapshotTests` and look at the eight images in both appearances: the line is one muted line, "failed" is the only colour, nothing is clipped.
- [ ] **Step 6: Commit.** `feat(ui): a dense thread shows the message, one line for the work and the answer`

### Task 3: Opening a turn does not move it

**Files:**
- Modify: `Sources/WorkspaceUI/TranscriptView.swift` (the scroll anchors and the four `scrollTo("bottom")` handlers)
- Test: `Tests/WorkspaceUITests/DenseTranscriptViewTests.swift`

**Interfaces:**
- Consumes: `TranscriptFolds` (Task 2).
- Produces: `TranscriptFolds.holds: Bool` (true from a toggle until released) and `TranscriptFolds.release()`.

Today the transcript pins its bottom edge when its height changes and scrolls to the end whenever an item, a turn's end or streamed text arrives. Either would push an opened turn's line away, at once or as the next token lands. While `folds.holds`:

- the size-change anchor is the top: `.defaultScrollAnchor(folds.holds ? .top : .bottom, for: .sizeChanges)`;
- the handlers for `detail.items.count`, the terminal-turn count and `detail.liveText` do not scroll.

The hold is released, and the bottom pin and the following come back, when the reader scrolls to the end (`onScrollGeometryChange` reporting the content's end within 8 pt of the viewport's), when `pending?.id` changes or a turn is added to `detail.turns` (the reader sent something; scroll to the end as today), and on `reset()`. A toggle in a thread whose content still fits its viewport afterwards does not hold. The `.initialOffset` anchor is unchanged, and with nothing ever toggled the view behaves exactly as today at both densities.

- [ ] **Step 1: Write the failing tests** (macOS; each hosts a dense `TranscriptView` in a 720 by 480 window over a detail of twelve ended turns, each with four tool items, finds the `NSScrollView` under the host, scrolls to the end, and reads `contentView.bounds.origin.y` and the document height after a layout pass and one main-actor turn):

  - `openingATurnLeavesItsLineWhereItWas`: `folds.toggle` the last turn → the clip origin is unchanged (± 0.5 pt) and the document is taller. Toggle again: the origin is unchanged or clamped to the new end.
  - `aStreamDoesNotMoveAnOpenedTurn`: open the tenth turn while a thirteenth runs; grow `detail.liveText` and append an item → the origin is unchanged.
  - `scrollingBackToTheEndFollowsTheStreamAgain`: after that, scroll the clip view to the end, grow `liveText` → the view is at the new end and `folds.holds == false`.
  - `sendingAMessageReleasesTheHold`: after opening a turn, add a turn and its user item → the view is at the end.
  - `aShortThreadStillFollowsItsStream`: one turn that fits the window; open it (it still fits); grow `liveText` past the window's height → the view is at the end.
  - `theAnswerStaysPutWhenItsTurnEnds`: nothing toggled; a running turn with three interim messages and a streaming fourth, view at the end; make the turn terminal → the document is shorter and the distance from the last message's bottom edge to the viewport's bottom is unchanged (± 0.5 pt).
  - `withNothingToggledNormalDensityScrollsAsToday`: at `dense: false`, growing `liveText` keeps the view at the end.

- [ ] **Step 2: Run and see `openingATurnLeavesItsLineWhereItWas` and `aStreamDoesNotMoveAnOpenedTurn` fail** (the origin grows by the steps' height, then follows the stream).
- [ ] **Step 3: Implement** `holds`, `release()`, the conditional anchor, the guarded handlers and the geometry observer.
- [ ] **Step 4: Run and see all seven pass.** If the anchor swap does not hold the origin in the hosted test, use the other mechanism and keep the same tests: a `ScrollPosition` binding on the scroll view, the current offset recorded by `onScrollGeometryChange(for: CGFloat.self)` into `TranscriptFolds` (not observed), and after a toggle `position.scrollTo(y: recorded)`. Say in the report which one was needed.
- [ ] **Step 5: Commit.** `fix(ui): an opened turn stays where it is until the reader returns to the end`

### Task 4: The Display page on the phone

**Files:**
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift:28-41` (`SettingsPage.allCases`)
- Modify: `Sources/WorkspaceUI/DisplaySettingsView.swift` (description, header comment)
- Modify: `Sources/WorkspaceUI/SettingsView.swift:51` (comment only)
- Test: `Tests/WorkspaceUITests/DisplaySettingsTests.swift`, `Tests/WorkspaceUITests/DetailMinimumSizeTests.swift` (already runs over `SettingsPage.allCases`)

**Interfaces:**
- Produces: `SettingsPage.allCases` on iOS is `[.account, .display, .connections, .servers, .diagnostics]`; `DisplaySettingsView.denseDescription` is per platform, the two strings in call 11.

- [ ] **Step 1: Change the tests first.** `displayIsTheMacsSecondPage` becomes `displayIsTheSecondPageOnBothPlatforms` (the iOS list above, the Mac list unchanged); `theSwitchSaysDenseAndWhatItDoes` asserts the platform's string.
- [ ] **Step 2: Run and see them fail.**
- [ ] **Step 3: Implement.** The phone writes density through the same `model.setDensity`; `density` is already phone-writable (`SyncColumns.phoneWritable`). The switch row keeps `minHeight: 48`.
- [ ] **Step 4: Run** `swift test --filter "DisplaySettingsTests|DetailMinimumSizeTests|SnapshotTests"` → pass; then `xcodebuild build -project B4App.xcodeproj -scheme B4App-iOS -destination 'generic/platform=iOS Simulator'` → `BUILD SUCCEEDED`.
- [ ] **Step 5: Run** `./Scripts/test-ios-layout.sh`; a test that lists the phone's Settings pages by position is updated to the new list. Report the count.
- [ ] **Step 6: Commit.** `feat(ui): the phone has the Display page; Dense says what it changes in a thread`

### Task 5: Records and gates

**Files:**
- Create: `docs/decisions/D-NNN-a-dense-thread.md`, `docs/verification/2026-11-13-a-dense-thread.md` (the date is the day the gates ran)
- Modify: `AGENTS.md` (Layout: one sentence in the `viewSettings` bullet naming `Sources/WorkspaceUI/DenseTranscript.swift` and that the phone has the Display page), `docs/milestones.md`

- [ ] **Step 1: Write the decision**, amending D-218: what dense draws in a thread, the eleven calls above each with its reason (for calls 1 to 7, what the research found: the owner's b4run activity design and hashbrown name the running step and count only once the turn has settled; a bare count while running is what users of other tools complained about; a declined command is the user's refusal, not the agent's failure), what was left out and why, that the counted types for Codex's `dynamicToolCall`, `imageView` and `functionCallOutput` and Claude Code's `TodoWrite` are inferred from the adapters and not from a recorded run, that normal density is unchanged, that nothing is stored, that the composer keeps its pickers until part 4, and which scroll mechanism Task 3 ended on.
- [ ] **Step 2: Run every gate** on the final tree and save the logs: lint, `swift test` (quote "N tests in M suites"), both `xcodebuild` builds, `./Scripts/test-ios-layout.sh`, `Scripts/docs-index.sh --check`.
- [ ] **Step 3: Write the verification record:** the counts, where the eight snapshots were looked at, and plainly what was not checked: a real running turn in the app (the spec names it as the part most likely to need a look), a thread read from history on each runtime, scrolling in the running app, VoiceOver on the line, the phone on a device.
- [ ] **Step 4: Update `docs/milestones.md`** with a `fixture-tested` line for the dense thread.
- [ ] **Step 5: Commit.** `docs: the dense thread's decision, verification record and milestone`

## After the plan

- The owner looks at a running turn in the Local Mac app before the Beta build: the line naming each step as it starts, the interim messages folding when the turn ends, opening a turn while another streams, and a thread read from history. Installing needs the store-migration comparison first (the installed app's bundled `SQL/*.sql` against this build's).
- No hub deploy: this change has no migration and no wire change.
