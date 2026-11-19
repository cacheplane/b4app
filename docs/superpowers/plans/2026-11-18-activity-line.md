# The Activity Line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One transcript on the Mac and the phone in which a turn's work is one line with a working mark and a clock, opening to one-line step rows, sub-agents that open the same way, and a step's output one level further in; no tool cards.

**Architecture:** `DenseTranscript` stays the one projection from `DisplayItem` and `Turn` rows to a flat list of entries; it gains a line that carries state and time, and step entries with a depth. Views only draw entries. Two facts the app lacks arrive as payload fields: `endedAt`, stamped by `SessionService`, and `parentNativeItemId`, written by the Claude Code adapter. Nothing is migrated and the hub is untouched.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing; `WorkspaceUI`, `WorkspaceProtocol`, `Coordinator`, `ClaudeAdapter`.

**Spec:** `docs/superpowers/specs/2026-11-18-activity-line-design.md`

**Branch:** a new branch cut from `blove/b4app-chat-ui-rendering-2710a2` (pull request 230, the streaming foundation), or from `main` once that has merged. Not this branch.

## Global Constraints

- `swift build` and `swift test --filter <suite>` pass for every suite a task touches; `swift format lint --strict --recursive Sources Tests Apps Package.swift` passes before each commit.
- Tests use Swift Testing (`@Test`, `#expect`), fixtures and fake executables. No live provider call in an ordinary test.
- `Sources/WorkspaceUI` imports only `WorkspaceProtocol`, `WorkspaceClient`, `StreamingMarkdown` and system frameworks.
- The projection reads `DisplayItem` and `Turn` rows only. A streamed token and the clock's tick never re-run it (`DenseTranscript.projections(of:)` is the counter).
- No animation on opening or closing (`withAnimation(.none)`), and nothing moves on a turn that is not running. The working mark is `ThreadMark(state: .working)`.
- The closed line is one line high at ordinary type sizes, cut at its tail; at accessibility sizes it stacks, as `StepsLineRow` does today.
- Words, exactly: `Working`, `Waiting for you`, `Stopping`, `Show`, `Hide`, `Show working`, `Hide working`, `Thought`, `Agent`, `N steps` / `1 step`, `N failed`, `N declined`. Only `N failed`, a failed step's cross and its title are in `LLA.Color.danger`.
- Clock: `0:00`, `0:42`, `1:15`, `1:00:00`. Duration: `1s` (also for 0), `8s`, `59s`, `1m`, `1m 12s`, `59m 59s`, `1h`, `1h 4m`.
- Payload field names: `endedAt`, `parentNativeItemId`.
- Sub-agents nest to four levels; deeper children are drawn at the fourth.
- Never edit `docs/roadmaps/`. Decision and gate record files follow `AGENTS.md` ("Decisions and gate records"); take the decision number with `Scripts/docs-index.sh --next` when the pull request is opened.
- Secrets never appear in arguments, payloads, logs or fixtures. A recorded run is scrubbed of paths under the home directory, session ids and account details before it is committed.

## Review Focus

1. A child item arrives before its parent's item, or its parent never arrives: it is drawn where it stands at the turn's level, and takes its place under the parent on the projection after the parent exists. Never dropped. (Task 6)
2. Two sub-agents run at once and their children interleave by sequence: each child is under its own parent, in sequence order within it. (Task 6)
3. An opened turn with several hundred steps: the 150-row window counts step rows, and a window cut that falls inside an opened turn still begins at a row that draws on its own; the turn's line is not required to be in the window. (Task 3)
4. The Mac's and the phone's clocks differ, so a turn's or step's `createdAt` is in the reader's future: the clock reads `0:00` and a duration is never negative. (Task 2)
5. Accessibility type sizes: a step row stacks and wraps its title rather than cutting it to an ellipsis beside the time. (Task 3)

---

### Task 1: One transcript

Removes normal density from the transcript. After this task every thread draws as dense draws today; nothing else changes.

**Files:**
- Modify: `Sources/WorkspaceUI/DenseTranscript.swift` (delete `plain`), `Sources/WorkspaceUI/TranscriptView.swift` (drop `dense` from `TranscriptView` and `TranscriptContent`, and the `onChange(of: dense)` handler), `Sources/WorkspaceUI/ThreadsView.swift:122`, `Sources/WorkspaceUI/WorkspaceModel.swift:1269` (delete `denseThread`), `Sources/WorkspaceUI/DisplaySettingsView.swift`, `Sources/WorkspaceUI/SettingsView.swift` (the phone's page list)
- Delete: `Tests/WorkspaceUITests/PlainTranscriptTests.swift`
- Modify tests: `DenseTranscriptViewTests.swift`, `TranscriptCorpusTests.swift`, `SnapshotTests.swift`, `MarkdownViewTests.swift`, `StreamingTickTimingTests.swift`, `TaskListRowTests.swift`, `ThreadListHeightTests.swift`, and any phone-only assertion on the Display page

**Interfaces:**
- Produces: `TranscriptView(detail:streams:pending:pendingStatus:folds:)`, `TranscriptContent(detail:streams:pending:pendingStatus:folds:)`; `DenseTranscript.entries(items:turns:open:)` is the only projection.

- [ ] **Step 1: Change the settings tests first.** On the Mac, `DisplaySettingsView.denseDescription == "Tighter rows for the threads that don\u{2019}t need you, and a composer without its pickers."`. On the phone (`#else` branches), the page list is `[.account, .connections, .servers, .diagnostics]` and no Dense switch exists. `ViewSettings.density` still defaults to `.normal` (assert it, so the default is pinned).
- [ ] **Step 2: Run them; they fail.** `swift test --filter DisplaySettings` (and the suite that holds the page list).
- [ ] **Step 3: Remove `dense` from the views and the model, delete `plain`, change the description, drop the phone's Display page.** `SettingsPage.display` stays for the Mac.
- [ ] **Step 4: Port the tests.** Every `dense: true` case keeps its assertions with the parameter gone. Every `dense: false` or `@Test(arguments: [true, false])` case that pins behaviour both densities shared (scroll hold, following, the row window, streaming, "a token does not re-run the grouping") runs once against the one transcript. Cases that pin normal density's own drawing (a tool card per step, the running line after the last item, a pinned height against normal content) are deleted; list each deleted case by name in the task report.
- [ ] **Step 5: Run.** `swift build` and `swift test --filter 'DenseTranscript|TranscriptCorpus|Snapshot|MarkdownView|TaskListRow|ThreadListHeight|DisplaySettings'`. Expected: pass.
- [ ] **Step 6: Commit.** `feat(ui): the transcript has one form; the density setting no longer changes it`

---

### Task 2: The line

**Files:**
- Create: `Sources/WorkspaceUI/ActivityTime.swift`, `Tests/WorkspaceUITests/ActivityTimeTests.swift`
- Modify: `Sources/WorkspaceUI/DenseTranscript.swift`, `Sources/WorkspaceUI/TranscriptView.swift`, `Tests/WorkspaceUITests/DenseTranscriptTests.swift`, `Tests/WorkspaceUITests/DenseTranscriptViewTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum ActivityTime {
    static func clock(_ seconds: Int) -> String        // negative reads as 0
    static func duration(_ seconds: Int) -> String     // negative and 0 read as "1s"
    static func seconds(from start: String, to end: String) -> Int?   // two Timestamp strings; nil if either does not parse
    static func seconds(since start: String, now: Date) -> Int        // 0 when start is in the future or does not parse
  }
  extension DenseTranscript {
    struct ActivityLine: Equatable, Sendable {
      enum State: Equatable, Sendable { case running, waiting, stopping, ended }
      var group: String
      var folded: [DisplayItem]
      var counted: Int, failed: Int, declined: Int
      var state: State
      var runningName: String?       // running only
      var startedAt: String?         // the turn's createdAt, while not ended
      var duration: Int?             // seconds, ended only
      var text: String?              // "Waiting for you" | "Stopping" | name | "Working" | "N steps" | nil
      var failedText: String?        // "N failed", as StepsLine has today
      var declinedText: String?      // "N declined"
      var durationText: String?      // ActivityTime.duration, ended with a count
      var canOpen: Bool              // !folded.isEmpty
      var marked: Bool               // state is .running or .stopping
      func action(open: Bool) -> String?   // nil when !canOpen
      func spoken(open: Bool) -> String
    }
  }
  ```
  `Entry` becomes `.item`, `.line(ActivityLine)`, `.note`; `.running`, `RunningLine` and `StepsLine` are gone. `ActivityLineRow(line:open:toggle:)` replaces `StepsLineRow` and `RunningLineRow`; its accessibility identifier is `activity-line`.

- [ ] **Step 1: Write `ActivityTimeTests`.** `clock`: 0 → `0:00`, 42 → `0:42`, 75 → `1:15`, 3_599 → `59:59`, 3_600 → `1:00:00`, -5 → `0:00`. `duration`: 0 → `1s`, 8 → `8s`, 59 → `59s`, 60 → `1m`, 72 → `1m 12s`, 3_599 → `59m 59s`, 3_600 → `1h`, 3_840 → `1h 4m`, -3 → `1s`. `seconds(since:now:)` with a start one minute after `now` is 0 (Review Focus 4).
- [ ] **Step 2: Write the projection tests** in `DenseTranscriptTests`, as one table of turn status and items against the line:
  - `submitting`, no items → line, `text == "Working"`, `marked`, `canOpen == false`, `startedAt == turn.createdAt`.
  - `running`, only a streaming `agentMessage` → the line is present (this replaces `aRunningTurnWithNothingYetHasNoStepsLine`'s neighbours and D-246's plan-only rule: a running turn always has exactly one line), then the message.
  - `running`, a plan row with a step in progress and nothing else → the line is present.
  - `running`, steps with one `inProgress` → its name; `waiting_for_user` → `Waiting for you`, `marked == false`; `stopping` → `Stopping`, `marked`.
  - terminal, 6 counted, 1 failed, `createdAt`/`updatedAt` 72 s apart → `text == "6 steps"`, `failedText == "1 failed"`, `durationText == "1m 12s"`, `state == .ended`, `startedAt == nil`.
  - terminal, only an answer → no line. `reconciling` → ended words, `durationText == nil`. A history group → a count, `durationText == nil`.
  - terminal, reasoning only → `text == nil`, `action(open: false) == "Show working"`, `durationText == nil`.
- [ ] **Step 3: Run; they fail to compile.**
- [ ] **Step 4: Audit `updatedAt`.** Read every caller of `WorkspaceDatabase.updateTurn` and of any other writer of a turn row (the sync apply included). If none can change a turn whose status is `terminal`, the ended duration is `updatedAt − createdAt`. If one can, the end is the latest of the turn's items' `endedAt` (else `createdAt`), and a turn with no item has no duration. Write which it is, with the callers found, in the task report; Task 8 records it.
- [ ] **Step 5: Implement `ActivityTime`, `ActivityLine` and the projection change** in `layout(key:items:turn:isOpen:)`: a running turn always gets the line; an ended one only when something folds.
- [ ] **Step 6: Implement `ActivityLineRow`.** Mark (when `marked`), the segments as `StepsLineRow` draws them, a trailing clock or duration, then the action word. The clock is drawn by a `TimelineView(.periodic(from: .now, by: 1))` that wraps only the clock's `Text`, in monospaced digits; nothing else in the row or above it reads the time. Label: `spoken(open:)`, with the elapsed time in words while running.
- [ ] **Step 7: View tests.** The row of a running turn is `LLA.Metrics.row` high at a 320 pt width with a 200-character step name. Over three seconds of a running turn with a hosted transcript, `DenseTranscript.projections(of:)` does not change. An ended line contains no `TimelineView` (assert through a test seam the row exposes, e.g. `static func ticks(_ line:) -> Bool`).
- [ ] **Step 8: Run** `swift test --filter 'ActivityTime|DenseTranscript'`; pass. **Commit:** `feat(ui): a turn's line carries the working mark and the time`

---

### Task 3: Step rows

**Files:**
- Create: `Sources/WorkspaceUI/StepRowView.swift`, `Tests/WorkspaceUITests/StepRowTests.swift`
- Modify: `Sources/WorkspaceUI/DenseTranscript.swift`, `Sources/WorkspaceUI/TranscriptView.swift` (delete `ToolCard`, `CollapsibleCard`; `TranscriptRow`'s `.tool` and non-message `.assistant` cases), `Sources/WorkspaceUI/ToolEvidence.swift` only if a helper is needed, the tests above

**Interfaces:**
- Consumes: `ActivityLine`, `ActivityTime`, `ToolEvidence.detail(of:)`, `DenseTranscript.title(of:)`.
- Produces:
  ```swift
  extension DenseTranscript {
    struct StepRow: Equatable, Sendable, Identifiable {
      enum Kind: Equatable, Sendable { case step, agent(steps: Int), thought, message, plan, other }
      enum Mark: Equatable, Sendable { case done, running, failed, declined, unfinished, none }
      var item: DisplayItem          // settled
      var depth: Int                 // 1...4
      var kind: Kind
      var mark: Mark
      var title: String
      var startedAt: String?         // a running step's createdAt
      var duration: Int?             // nil until Task 4
      var opens: Bool                // has output to draw (step, thought) or children (agent)
      var id: String { item.id }
      var spoken: String             // "Running, swift test, 24 seconds"
    }
  }
  ```
  `Entry` gains `.step(StepRow)`. An opened group emits its folded items as `.step` entries at depth 1 in sequence order, where it emitted `.item` before; the items a closed group shows are still `.item`. `TranscriptFolds.open` holds group keys and item ids; `toggle(_:)` is unchanged. `StepRowView(row:streams:open:toggle:)`.

- [ ] **Step 1: Projection tests.** An opened ended turn with a command (completed), a file change (failed), a declined command, a step left `inProgress`, a `reasoning` item, an interim `agentMessage`, a plan row and an unknown tool-role type yields, in sequence order, rows of kinds `.step, .step, .step, .step, .thought, .message, .plan, .other` with marks `.done, .failed, .declined, .unfinished, .none, .none, .none, .none`. In a running turn the open step's mark is `.running` and its `startedAt` is its `createdAt`. A step whose `ToolEvidence.detail` has no input, output, exit code, change or raw text has `opens == false`. `.thought`'s title is `Thought`.
- [ ] **Step 2: Window test (Review Focus 3).** An opened turn of 400 steps with `shown: 150`: the window holds 150 entries or begins at the user's message within reach, every entry in it is drawable on its own, and `hidden` plus the window's count equals the total.
- [ ] **Step 3: Run; fail. Implement the projection.**
- [ ] **Step 4: Implement `StepRowView` and wire `TranscriptContent`.** One line: mark, title (mono for `commandExecution` and for a `toolUse` with a command or path, as the card's title was), time at the right. Indent `depth` steps under a 1 pt `LLA.Color.rule` line at the left. Pressing a row that `opens` toggles its item id in `folds` with no animation; opened, a `.step` draws what `ToolCard`'s body drew (the same views, no `LLACard`, indented under the row), and a `.thought` draws its text as the old reasoning card's body did. `.message` draws `MarkdownText(document: streams.document(for: item), streaming: false)`, `.plan` draws `TaskListRow`. At accessibility sizes the row stacks and the title wraps (Review Focus 5).
- [ ] **Step 5: View tests.** Opening a step in a thread taller than the window holds the view (`folds.holds`) and leaves the pressed row's top where it was (±0.5 pt). A step row at an accessibility size is taller than one line and its title is not cut. An item id left in `folds.open` after its item is gone changes nothing. No `LLACard` is in an opened turn (assert `ToolCard` and `CollapsibleCard` no longer exist by their removal; the build is the check).
- [ ] **Step 6: Run** `swift test --filter 'StepRow|DenseTranscript|TranscriptCorpus|Snapshot'`; pass. **Commit:** `feat(ui): an opened turn draws one row per step; the tool cards are gone`

---

### Task 4: A step's end time

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift` (the `.toolCompleted` write, near `environmentItem`), `Tests/CoordinatorTests/SessionTests.swift`, `Sources/WorkspaceUI/DenseTranscript.swift`, `Tests/WorkspaceUITests/DenseTranscriptTests.swift`

**Interfaces:**
- Produces: a tool item written for `.toolCompleted` has `payload.endedAt` (a `Timestamp` string). `StepRow.duration` is `ActivityTime.seconds(from: item.createdAt, to: endedAt)` for a row that is not running.

- [ ] **Step 1: Session tests.** With a fake runtime that starts and completes a tool: the stored item's `payload["endedAt"]` parses as a timestamp not before the item's `createdAt`, and `createdAt` equals the started write's. A started-only item has no `endedAt`. After a reconcile of the same thread the live row still has its `endedAt`.
- [ ] **Step 2: Run; fail. Stamp the field** in the session service, for `.toolCompleted` only, whatever the item's final status (completed, failed, declined).
- [ ] **Step 3: Projection tests.** `duration` is 18 for an 18-second step, `nil` without `endedAt`, `nil` when `endedAt` does not parse, and never negative.
- [ ] **Step 4: Implement, run** `swift test --filter 'SessionTests|DenseTranscript'`; pass. **Commit:** `feat: a finished step records when it ended, and its row shows how long it took`

---

### Task 5: Claude Code sub-agent frames, recorded and carried

This task starts with a live run. If no recording can be made (no login, no network), stop this task and Task 6's Claude-dependent tests, report it, and go on to Task 7: nothing here is built on a guessed shape.

**Files:**
- Create: `Tests/ClaudeAdapterTests/Fixtures/subagent-run.jsonl` (the scrubbed recording), a mode in `Tests/ClaudeAdapterTests/Fixtures/fake-claude.py` that replays it
- Modify: `Sources/ClaudeAdapter/ClaudeEvents.swift`, `Tests/ClaudeAdapterTests/ClaudeSessionTests.swift` (or the events suite beside it), `docs/compatibility.md` (the Claude Code version recorded)

**Interfaces:**
- Produces: every item `ClaudeEvents` writes from a frame whose `parent_tool_use_id` is a string carries `payload.parentNativeItemId` with that value, on every write of the item (started, completed, failed, declined). The parent's own item has `nativeItemId` equal to it. A sub-agent's text deltas emit no `.messageDelta`.

- [ ] **Step 1: Record.** With `B4APP_LIVE_CLAUDE=1`, run one turn that makes Claude Code start exactly one sub-agent which runs at least two tools and replies (for example: "Use a sub-agent to list the Swift files under Sources/StreamingMarkdown and count them."), capturing the raw `stream-json` frames. Scrub home paths, session ids, uuids that name the account, and any token count that is not needed. Write into the task report: the sub-agent tool's name, which frame types carry `parent_tool_use_id` (`assistant`, `user`, `stream_event`), and whether the sub-agent's final text is also the parent call's tool result.
- [ ] **Step 2: Write the adapter tests against the recording.** Each sub-agent tool use, tool result, text and thinking item has `parentNativeItemId` equal to the parent call's id, on its started and its completed event. The parent call's item has none. No `.messageDelta` is emitted for a sub-agent's text. The session's task list is still untouched by a sub-agent's task tools (the existing test).
- [ ] **Step 3: Run; fail. Implement.** Keep the parent id with the per-tool state (`toolUses`) so `toolItem` re-emits it. If `stream_event` frames do not carry the parent id, do not emit a started item from the partial path for a tool whose completed frame turns out to be a child: hold it until the completed frame, and say so in the report.
- [ ] **Step 4: A coordinator test** with the replay mode: after the turn, and again after a reconcile, the thread has each child row once, with its field.
- [ ] **Step 5: Run** `swift test --filter 'Claude|SessionTests'`; pass. **Commit:** `feat(claude): a sub-agent's items name the call that started it`

---

### Task 6: Sub-agent rows

**Files:**
- Modify: `Sources/WorkspaceUI/DenseTranscript.swift`, `Sources/WorkspaceUI/StepRowView.swift`, `Tests/WorkspaceUITests/DenseTranscriptTests.swift`, `Tests/WorkspaceUITests/StepRowTests.swift`

**Interfaces:**
- Consumes: `payload.parentNativeItemId`, `DisplayItem.nativeItemId`, `StepRow.Kind.agent(steps:)`.
- Produces: within a thread, an item whose `parentNativeItemId` equals another item's `nativeItemId` is that item's child. Children are removed from their turn's own level before the answer, the counts and the running name are worked out. A parent with children, a `toolUse` named `Task` or `Agent`, and a `collabAgentToolCall` are `.agent` rows titled `Agent: <input.description>` (`Agent` alone without one), followed by ` · N steps` when it has counted children (`1 step` for one). An `.agent` row whose id is in `open` is followed by its children as rows at `depth + 1` (capped at 4), in sequence order, each expanded the same way.

- [ ] **Step 1: Projection tests.**
  - A running turn: `Task` call, three children (two tools, one `agentMessage`), then a top-level command. Closed line names `Agent: find the slow query` while the call is in progress, not the child. Ended: the line counts 2 steps (the call and the command), the sub-agent's message is not the answer, and no child appears at the turn's level.
  - Opened turn, closed agent: one `.agent(steps: 2)` row at depth 1, `opens == true`. Agent opened: its three children at depth 2 after it, kinds `.step, .step, .message`.
  - Two agents with interleaved children: each child under its own parent, in sequence order (Review Focus 2).
  - A child whose parent is not in the thread: a depth-1 row where it stands; add the parent item and project again: it is under the parent, and appears once (Review Focus 1).
  - A child whose `turnId` differs from its parent's is under the parent.
  - Five levels of nesting: the fifth level's rows have depth 4.
  - A `collabAgentToolCall` and a childless `Task`: `.agent(steps: 0)`, title without a count, `opens` only if the call has output.
  - A failed child does not count in the turn's `failed`; the agent row's own mark is the call's.
- [ ] **Step 2: Run; fail. Implement the tree** (one pass building `children: [String: [DisplayItem]]` keyed by parent native id, before `layout`), then the expansion.
- [ ] **Step 3: View.** An agent row draws `Show` / `Hide` at its right like the line; opened and with output, the call's own output is drawn after its children, as a step's output is. View test: opening an agent inside an opened turn holds the view and indents its children one more level than the agent row (compare leading edges).
- [ ] **Step 4: Run** `swift test --filter 'DenseTranscript|StepRow'`; pass. **Commit:** `feat(ui): a sub-agent is a row that opens to its own steps`

---

### Task 7: Captures

**Files:**
- Modify: `Tests/WorkspaceUITests/SnapshotTests.swift` (the transcript cases), `docs/screenshots/`

- [ ] **Step 1: Add capture cases** from fixtures: a running closed line; just sent (`Working`); an opened running turn with an open sub-agent and a running child; an opened step with output; an ended line with a failure; light and dark, Mac and phone widths. Names `transcript-activity-<case>-<mac|phone>-<light|dark>.png`.
- [ ] **Step 2: Delete the captures that show cards or normal density** (`transcript-running-line-normal.png`, `transcript-plan-normal.png`, the `-normal-` markdown captures, and any other that the new transcript makes false); regenerate the ones that remain true in the new form.
- [ ] **Step 3: Read each new capture** and check it against the design's sketches: one line closed, the rule and indent, danger only on the failure. Report anything that differs. **Commit:** `test(ui): captures of the activity line`

---

### Task 8: Records

**Files:**
- Create: `docs/decisions/D-NNN-the-activity-line.md`, `docs/verification/2026-11-18-the-activity-line.md` (dated the day it is written)
- Modify: `AGENTS.md` (the Layout bullets that describe `ThreadState`/density and `DenseTranscript`), `docs/milestones.md`, `docs/research/2026-11-14-agent-chat-hill-climb.md` (defect 11's row), `docs/compatibility.md` if Task 5 did not

- [ ] **Step 1: Write the decision**: one transcript; the line (always while running, mark, clock, `Stopping`, the ended duration and which end time Task 2's audit chose); step rows and the cards' removal; `endedAt`; `parentNativeItemId` and what the recording showed; the density setting's scope and unchanged default; the phone's Display page; what old threads and history show. It amends D-223, D-239, D-246, D-218 and D-208. List every call made without the owner.
- [ ] **Step 2: Write the gate record**: what was run and its result, each deleted test by name, and what was not checked (the mark and clock in the running app, VoiceOver, a phone in the hand, a live Codex sub-agent, and Task 5 if it was not recorded).
- [ ] **Step 3: Run** `Scripts/docs-index.sh --check` and the format lint; pass. **Commit:** `docs: the activity line's decision and gate record`
