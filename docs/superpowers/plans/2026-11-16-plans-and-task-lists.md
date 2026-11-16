# Plans and Task Lists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent's plan or task list is one row per turn in the transcript, updated in place, the same for Codex, Claude Code and B4.

**Architecture:** Each adapter turns its runtime's shape into one `taskList` display item per turn under a fixed native item id; `SessionService` already replaces an item's payload when its native id arrives again, so nothing new is stored or synced. The snapshot merge is changed so a live row that history does not name keeps its place. `DenseTranscript` settles and places the row and a new view draws it.

**Tech Stack:** Swift 6.3, Swift Testing, SwiftUI; Python fixtures for the fake runtimes.

**Spec:** `docs/superpowers/specs/2026-11-16-plans-and-task-lists-design.md`. Read it first; this plan argues from it.

## Global Constraints

- Work on a new branch `blove/plans-and-task-lists` cut from `origin/main` (fetch first; other sessions merge to main).
- Item `type` is `taskList`, `role` is `tool`, payload `status` is `completed`. Step statuses are exactly `pending`, `inProgress`, `completed`; an unknown status is stored as `pending`.
- Native item id is `tasks:<native turn id>` for Codex and B4. For Claude Code it is `tasks:<id of the tool use that first changed the list in that turn>`, because the live turn id and the transcript share no turn identity but both know tool use ids.
- `WorkspaceProtocol` stays Foundation-only. `WorkspaceUI` gains no runtime or tool names beyond removing ones it has.
- `ExitPlanMode`, Codex's text `plan` item, command output deltas and sub-agents are out of scope.
- No live runtime is run. Record live behaviour as untested.
- Before each commit: `swift format lint --strict --recursive Sources Tests Apps Package.swift`. Tests run CI-style with `export B4APP_TEST_POSTGRES_DIR=/tmp/b4pg`: `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`, then `swift test --skip '^(WorkspaceStorageTests|CoordinatorTests)\.'`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`. Do not push or open a pull request until the owner asks.
- Docs are plain prose in the repository's style; take the decision number with `Scripts/docs-index.sh --next` only when the pull request is opened.

## Review Focus

Each line has a test in the task named.

1. A history load of a Codex or B4 thread must leave the list row inside its turn, not at the end of the thread (Task 1).
2. A reconcile of a Claude Code thread whose turn wrote a list must add no row (Task 6).
3. A Claude Code session resumed after its process exited must still apply a `TaskUpdate` to a task made earlier (Task 5).
4. A `TaskCreate` whose result is an error, or whose result text has no `Task #<n>`, must add no step and must not break later calls (Task 5).
5. A turn that ended with a step in progress must not show that step as running or done (Task 7).

---

### Task 1: An unmatched live row keeps its place through a snapshot merge

**Files:**
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`mergeSnapshotItems`, the loop `for row in cached where !usedRows.contains(row.id)`)
- Test: `Tests/WorkspaceStorageTests/ConversationStorageTests.swift` (`SnapshotMergeTests`)

**Interfaces:**
- Produces: no signature change. Behaviour: after a merge, an unmatched live row stands directly after the row that preceded it in the stored order, or first when none did.

- [ ] **Step 1: Write the failing tests** in `SnapshotMergeTests`, using the suite's existing helpers for a database, live rows and `snapshot(_:_:_:)`:

  - `anUnmatchedLiveRowStaysAfterTheRowBeforeIt`: live rows in order `u1` (user, native id `u1`), `tasks:t1` (tool, type `taskList`), `a1` (assistant, native id `a1`), `u2`, `a2`; merge a snapshot of `u1, a1, u2, a2`. Expect native ids in sequence order `["u1", "tasks:t1", "a1", "u2", "a2"]`.
  - `anUnmatchedLiveRowThatStoodFirstStaysFirst`: live `x` (no match), `u1`; snapshot `u1`. Expect `x` before `u1`.
  - `twoUnmatchedLiveRowsInARowKeepTheirOrder`: live `u1`, `x`, `y`, `a1`; snapshot `u1, a1`. Expect `u1, x, y, a1`.
  - `aSnapshotRowInsertedWhereALiveRowStoodDoesNotMoveIt`: live `u1`, `x`; snapshot `u1, a1`. Expect `u1, x, a1`.

- [ ] **Step 2: Run** `swift test --filter SnapshotMergeTests`. Expected: the four new tests fail (the row is last).

- [ ] **Step 3: Implement.** Replace the append of unmatched live rows with an insertion: walk `cached` in order, remembering the id of the previous cached row that survives (matched or live); insert each unmatched live row into `ordered` directly after that row's position, or at index 0. Deleting unmatched snapshot rows is unchanged.

- [ ] **Step 4: Run** `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`. Expected: all pass, including the D-238 cases untouched.

- [ ] **Step 5: Commit** `fix(storage): a live row history does not name keeps its place`.

### Task 2: The shared list payload

**Files:**
- Create: `Sources/WorkspaceProtocol/TaskList.swift`
- Test: `Tests/WorkspaceProtocolTests/TaskListTests.swift` (use the existing protocol test target; if its folder has another name, put the file beside its other tests)

**Interfaces:**
- Produces:

```swift
public struct TaskList: Equatable, Sendable {
  public static let itemType = "taskList"
  public enum Status: String, Sendable { case pending, inProgress, completed }
  public struct Step: Equatable, Sendable {
    public var text: String
    public var status: Status
    public init(text: String, status: Status)
  }
  public var steps: [Step]
  public var explanation: String?
  public init(steps: [Step], explanation: String? = nil)

  /// "in_progress" and "inProgress" are inProgress, "completed" is completed, anything else pending.
  public static func status(_ native: String?) -> Status
  public static func nativeItemId(turn: String) -> String        // "tasks:<turn>"
  /// The stored item: type, steps, explanation when set, status "completed".
  public var payload: JSONValue { get }
  /// Nil unless the payload's type is taskList.
  public init?(payload: JSONValue)
  public var completedCount: Int { get }
}
```

- [ ] **Step 1: Write the failing tests:** `statusesAreReadLeniently` (`"in_progress"`, `"inProgress"`, `"completed"`, `"done"` → pending, `nil` → pending); `thePayloadRoundTrips` (two steps and an explanation; `TaskList(payload: list.payload) == list`, `payload["status"] == "completed"`, `payload["type"] == "taskList"`); `anotherItemIsNotAList` (`TaskList(payload: ["type": "toolUse"]) == nil`); `theIdNamesTheTurn` (`"tasks:t1"`).
- [ ] **Step 2: Run** `swift test --filter TaskListTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** the type above.
- [ ] **Step 4: Run** the same filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(protocol): the task list an adapter writes`.

### Task 3: Codex writes the list

**Files:**
- Modify: `Sources/CodexAdapter/CodexEvents.swift` (the `switch method` in the translator; add a case before `default`)
- Modify: `Tests/CodexAdapterTests/Fixtures/fake-codex.py` (a prompt containing "plan" sends two `turn/plan/updated` notifications before its reply: first all pending, then the first step completed and the second in progress)
- Test: `Tests/CodexAdapterTests/CodexEventsTests.swift`

**Interfaces:**
- Consumes: `TaskList` (Task 2).
- Produces: for `turn/plan/updated`, one `.toolCompleted` event, `itemId` `tasks:<turnId>`, payload `["item": list.payload, "role": "tool", "type": "taskList"]`, with the event's `turnId` set as other turn events have it.

- [ ] **Step 1: Write the failing tests:** `aPlanUpdateIsTheTurnsList` (params `turnId: "t1"`, `explanation: "Why"`, `plan` of `Read`/`completed`, `Write`/`inProgress`, `Ship`/`pending`; expect one event, kind `.toolCompleted`, `nativeIds["itemId"] == "tasks:t1"`, and `TaskList(payload: item)` equal to those three steps with the explanation); `aPlanUpdateWithNoStepsWritesNothing` (empty `plan`, no row for this turn yet → `[]`); `anEmptyPlanAfterAListClearsIt` (a list, then an empty `plan` for the same turn → one event whose steps are empty); `aNullExplanationIsLeftOut`.
- [ ] **Step 2: Run** `swift test --filter CodexEventsTests`. Expected: the new tests fail with no events.
- [ ] **Step 3: Implement** the case. The translator needs to remember which turns have a list (a `Set<String>`) to tell the two empty cases apart; follow how the translator holds other per-turn state.
- [ ] **Step 4: Run** `swift test --filter CodexAdapterTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat(codex): a plan update is the turn's task list`.

### Task 4: B4 writes the list

**Files:**
- Modify: `Sources/B4Adapter/B4TurnTranslator.swift` (add a case for `.unknown("plan_update", let data)` before the general `.unknown(let name, let data)` case)
- Test: `Tests/B4AdapterTests/B4TranslatorTests.swift`

**Interfaces:**
- Consumes: `TaskList` (Task 2).
- Produces: for `plan_update` with a `todos` array, one `.toolCompleted` event, `itemId` `tasks:<turnId>`, item payload `list.payload`, step text from `content`. No `capabilityIndex` is used for it.

- [ ] **Step 1: Write the failing tests:** `aPlanUpdateIsTheTurnsList` (todos `step one`/`pending`, `step two`/`in_progress`; expect item id `tasks:<turn>` and statuses pending, inProgress); `twoPlanUpdatesNameTheSameItem`; `aPlanUpdateWithoutTodosIsStillAGenericRow` (data `{}` → today's row of type `plan_update`); `anotherNamedEventIsUnchanged`.
- [ ] **Step 2: Run** `swift test --filter B4TranslatorTests`. Expected: the first two fail.
- [ ] **Step 3: Implement** the case. Update any existing test that pins `plan_update` as a generic row to the new shape.
- [ ] **Step 4: Run** `swift test --filter B4AdapterTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat(b4): plan_update is the turn's task list`.

### Task 5: Claude Code folds its task tools into the list

**Files:**
- Create: `Sources/ClaudeAdapter/ClaudeTaskFold.swift`
- Modify: `Sources/ClaudeAdapter/ClaudeEvents.swift` (`ClaudeTurnTracker`: `beginTurn`, the two `tool_use` cases in `streamEvent` and `assistant`, `toolResults`; and `snapshotItems`)
- Modify: `Sources/ClaudeAdapter/ClaudeAdapter.swift` (`startSession`, when `resume` is true)
- Modify: `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` (a prompt containing "todo" sends a `TodoWrite` use and result; one containing "tasks" sends two `TaskCreate` uses with results `Task #1 created successfully: …`, `Task #2 …`, then a `TaskUpdate` of task 1 to `in_progress`)
- Test: `Tests/ClaudeAdapterTests/ClaudeEventsTests.swift`

**Interfaces:**
- Consumes: `TaskList` (Task 2).
- Produces:

```swift
struct ClaudeTaskFold: Sendable {
  static let toolNames: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
  /// A new turn: the next change starts a new item.
  mutating func beginTurn()
  /// A tool use by one of `toolNames`. Returns the turn's item when the list changed (TodoWrite).
  mutating func use(id: String, name: String, input: JSONValue) -> SnapshotItem?
  /// The result of a use given to `use`. Returns the turn's item when the list changed.
  mutating func result(toolUseId: String, text: String, isError: Bool) -> SnapshotItem?
  /// Whether `use` was given this id (its result is the fold's, not a tool row's).
  func owns(toolUseId: String) -> Bool
}
extension ClaudeTurnTracker {
  /// Rebuild the session's list from its transcript; emits nothing.
  public mutating func seedTasks(transcriptLines: [String])
}
```

  The returned `SnapshotItem` has `role` `tool`, `type` `taskList`, `payload` `TaskList.payload`, and `nativeItemId` `tasks:<id of the tool use that first changed the list since beginTurn>`.

  Rules, from the spec: `TodoWrite` replaces the list from `todos` (`content`, `status`) at `use`. `TaskCreate` adds a pending step at `result`, text `subject`, id parsed from the result text by the pattern `Task #(\d+)`; no match or an error adds nothing. `TaskUpdate` at `result` (not an error) sets status and, when `subject` is given, text on the step with `taskId`; status `deleted` removes it; an unknown id changes nothing. `TaskList` and `TaskGet` change nothing. A call that changes nothing returns nil.

- [ ] **Step 1: Write the failing fold tests** (a new `@Suite struct ClaudeTaskFoldTests` in `ClaudeEventsTests.swift`): `aTodoWriteIsTheList`; `aSecondTodoWriteInTheTurnNamesTheSameItem` (ids equal, `tasks:toolu_1`); `aNewTurnStartsANewItemWithTheWholeList` (after `beginTurn`, a `TaskUpdate` returns id `tasks:<that use>` and all steps); `createdTasksAppearWhenTheirResultsArrive` (`use` returns nil, `result` returns one pending step); `anUpdateChangesItsTask` (`in_progress` → inProgress, then `completed`); `aDeletedTaskIsRemoved`; `aFailedCreateAddsNothing`; `aCreateResultWithNoNumberAddsNothing` and a later create still works; `anUpdateOfAnUnknownTaskChangesNothing`; `listingTasksChangesNothing`.
- [ ] **Step 2: Run** `swift test --filter ClaudeTaskFoldTests`. Expected: fails to compile.
- [ ] **Step 3: Implement** `ClaudeTaskFold`.
- [ ] **Step 4: Run** the same filter. Expected: pass.

- [ ] **Step 5: Write the failing tracker and history tests:**
  - `aTodoWriteEmitsTheListAndNoToolRow`: feed the tracker an assistant frame with a `TodoWrite` use and the user frame with its result; expect exactly one event with item type `taskList`, none of type `toolUse`. Include the streamed form: a `content_block_start` for a `TodoWrite` tool use emits nothing.
  - `taskToolsEmitTheListAsItGrows`: the fixture's "tasks" frames; expect list events with 1, 2 and 2 steps, the last with step 1 in progress, all under one item id.
  - `otherToolsAreUnchanged`: a `Bash` use still emits `toolUse` rows.
  - `aSeededTrackerAppliesAnUpdateToAnEarlierTask`: `seedTasks` with transcript lines holding two creates and results, then `beginTurn`, then a live `TaskUpdate` of task 1; expect one list event with two steps, the first in progress.
  - `historyFoldsTheSameCallsUnderTheSameIds`: run the same frames live and as transcript lines through `snapshotItems`; the `taskList` items' native ids and final payloads are equal, and the snapshot holds no `toolUse` item for a fold tool.
  - `historyStartsANewItemAtEachTurn`: a transcript with a user text line between two `TodoWrite` calls yields two `taskList` items.
- [ ] **Step 6: Run** `swift test --filter ClaudeEventsTests`. Expected: the new tests fail.
- [ ] **Step 7: Implement.** The tracker holds a `ClaudeTaskFold`; `beginTurn` calls the fold's. A `tool_use` whose name is in `toolNames` goes to the fold and emits no tool row (in both the stream and the assistant-frame paths); a result the fold owns goes to the fold. A returned item becomes a `.toolCompleted` event with that item id. In `snapshotItems`, a user line that carries text (a string, or a `text` block) calls `beginTurn`; a returned item replaces the snapshot item with the same native id or is appended. `seedTasks` runs the same walk and discards the items.
- [ ] **Step 8:** In `ClaudeAdapter.startSession`, when `resume` is true and `projectsDirectory` and `Self.transcript(sessionId:under:)` give a file, read it and call `seedTasks` on the new tracker before the pump starts. A file that cannot be read leaves the tracker empty.
- [ ] **Step 9: Run** `swift test --filter ClaudeAdapterTests`. Expected: pass.
- [ ] **Step 10: Commit** `feat(claude): TodoWrite and the task tools are the turn's task list`.

### Task 6: One row through the coordinator

**Files:**
- Test: `Tests/CoordinatorTests/SessionTests.swift`

**Interfaces:**
- Consumes: the fixtures' "plan", "todo" and "tasks" prompts (Tasks 3 to 5).

- [ ] **Step 1: Write the tests**, modelled on the existing fake-runtime turn tests and on `ContinuityTests.reconcilingAClaudeThreadAddsNoSecondCopyOfItsRows`:
  - `aCodexPlanIsOneRowUpdatedInPlace`: a "plan" turn; the thread has exactly one `taskList` item, its steps are the second update's, and its sequence is lower than the reply's.
  - `aB4PlanIsOneRow`: the fake B4 "plan" route; one `taskList` item, no item of type `plan_update`.
  - `aClaudeTaskListIsOneRowPerTurn`: a "tasks" turn; one `taskList` item with two steps and no `toolUse` item named `TaskCreate` or `TaskUpdate`.
  - `reconcilingAClaudeThreadWithAListAddsNoRow`: after a "todo" turn, write the transcript the fixture would have written, reconcile, and expect the same item ids and count as before.
  - `loadingCodexHistoryLeavesTheListInItsTurn`: after a "plan" turn, load history; the `taskList` item still stands before that turn's reply.
- [ ] **Step 2: Run** `swift test --filter '^CoordinatorTests\.'`. Expected: pass if Tasks 1 to 5 are right. A failure here is a defect in those tasks: fix it there, with a test at that level.
- [ ] **Step 3: Commit** `test(coordinator): a task list is one row through a turn and a reconcile`.

### Task 7: The projection and the row

**Files:**
- Modify: `Sources/WorkspaceUI/DenseTranscript.swift` (`settled`, `layout`, `title(of:)`, and remove `TodoWrite`, `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet` from `workingToolNames`)
- Create: `Sources/WorkspaceUI/TaskListRow.swift`
- Modify: `Sources/WorkspaceUI/TranscriptView.swift` (`TranscriptRow`, case `.tool`: a `taskList` item draws `TaskListRow`)
- Test: `Tests/WorkspaceUITests/DenseTranscriptTests.swift`, `PlainTranscriptTests.swift`, `TranscriptCorpusTests.swift`, `SnapshotTests.swift`; new `Tests/WorkspaceUITests/TaskListRowTests.swift`

**Interfaces:**
- Consumes: `TaskList` (Task 2).
- Produces:

```swift
/// What the row draws for one step once the turn's state is applied.
enum TaskStepMark: Equatable { case done, running, pending, unfinished, unknown }
struct TaskListDisplay: Equatable {
  var header: String                 // "Plan · 2 of 4"
  var explanation: String?
  var steps: [(text: String, mark: TaskStepMark)]   // Equatable by hand or a small struct
  var accessibilityHeader: String    // "Plan, 2 of 4 done"
  init?(item: DisplayItem)           // nil unless a taskList with at least one step
}
struct TaskListRow: View { init(display: TaskListDisplay) }
```

  `DenseTranscript.settled` rewrites a `taskList` item's steps when the turn is not running: each `inProgress` step's status becomes `stopped`, or `unknown` while the turn is reconciling, as it does for a tool's own status today. `TaskListDisplay` maps `completed` → done, `inProgress` → running, `pending` → pending, `stopped` → unfinished, `unknown` → unknown.

- [ ] **Step 1: Write the failing projection tests:**
  - Dense, `aRunningTurnShowsItsListAfterTheStepsLine`: a running turn with a user message, a command and a `taskList`; entries are the message, the steps line, then the list item; the line's `counted` is 1.
  - Dense, `anEndedTurnFoldsItsList`: the same turn completed with an answer; the list is in the line's `folded` and not among the entries; `counted` is 1.
  - Dense, `aRunningTurnWithOnlyAListHasNoStepsLineForIt`: user message and list only; entries are the message and the list (decide and pin whether the running line of D-239 also stands; it should, after the list, since nothing else says the turn is working).
  - Plain, `aListStandsWhereItWasWritten`.
  - Both, `aStepInProgressWhenTheTurnEndedIsUnfinished` (completed turn and stopped turn) and `aStepInProgressWhileReconcilingIsUnknown`; a running turn leaves it `inProgress`.
  - `aListIsNotACountedStep`; `title(of:)` for a list is `"Plan"`.
- [ ] **Step 2: Write the failing display tests** in `TaskListRowTests`: header `"Plan · 2 of 4"` and `"Plan, 2 of 4 done"`; marks for each status; `nil` for an empty list and for another item type; the explanation is carried.
- [ ] **Step 3: Run** `swift test --filter 'DenseTranscriptTests|PlainTranscriptTests|TaskListRowTests'`. Expected: fail.
- [ ] **Step 4: Implement** the projection changes and `TaskListDisplay`.
- [ ] **Step 5: Implement `TaskListRow`:** the header in the small strong style, the explanation as one muted line, then one line per step: a mark (the working `ThreadMark` for running, drawn marks from the theme for the others, hidden from accessibility) and the text, at most two lines, muted when done. Accessibility: the header reads `accessibilityHeader`; each step reads its text and state ("done", "in progress", "not started", "unfinished", "unknown"). Identifier `task-list`. An item whose display is nil draws nothing. Use `LLA` spacing and colours as `RunningLineRow` and `ToolCard` do.
- [ ] **Step 6:** Add a scripted thread with a list to `TranscriptCorpusTests` (ledger rows for both densities) and to `SnapshotTests.denseThreads` as `thread-normal-plan`, `dense-thread-plan-running` and `thread-normal-plan-stopped`.
- [ ] **Step 7: Run** `swift test --skip '^(WorkspaceStorageTests|CoordinatorTests)\.'`, then `B4APP_SNAPSHOT_DIR=<scratch dir> swift test --filter "ListSnapshotTests/denseThreads"` and look at the three captures in light and dark. Expected: tests pass; the row reads as in the spec's sketch.
- [ ] **Step 8:** Build both apps: `./Scripts/generate-project.sh`, then `xcodebuild build -project B4App.xcodeproj -scheme B4App-macOS -destination 'platform=macOS'` and `-scheme B4App-iOS -destination 'generic/platform=iOS Simulator'`. Expected: both succeed.
- [ ] **Step 9: Commit** `feat(ui): a turn's task list is a row`.

### Task 8: Records

**Files:**
- Create: `docs/decisions/D-NNN-a-plan-is-one-row-per-turn.md` (number from `Scripts/docs-index.sh --next` when the pull request is opened; until then keep the file out of the commit or use the next free number and expect to rename)
- Create: `docs/verification/<date>-a-plan-is-one-row-per-turn.md`
- Create: `docs/screenshots/transcript-plan-{normal,dense-running,stopped}.png` from Task 7's captures
- Modify: `docs/compatibility.md` (the three message shapes and where each was read), `docs/milestones.md`, `docs/research/2026-11-14-agent-chat-hill-climb.md` (row 10: the plans half dealt with by the decision, command output deltas still open)

- [ ] **Step 1: Write the decision**, one bullet in the log's style: what was chosen (the spec's approach A), the item, the three mappings, the merge change and that it amends how D-031's merge places unmatched live rows, the calls listed in the spec, and what is untested (every live runtime; B4 history; the running app and VoiceOver).
- [ ] **Step 2: Write the verification record:** the gates run with their counts, the captures, and an explicit Untested list.
- [ ] **Step 3: Update** the three existing documents.
- [ ] **Step 4: Run** `Scripts/docs-index.sh --check`, the lint, and both test groups. Expected: all pass.
- [ ] **Step 5: Commit** `docs: a plan is one row per turn`.
