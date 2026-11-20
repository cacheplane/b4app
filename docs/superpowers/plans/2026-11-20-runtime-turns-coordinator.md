# Runtime turns in the coordinator (change 2 of 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The coordinator can hold a turn the runtime started itself, keeps each turn's `openWork` true to its agent items, closes open work when a session is gone, and can stop open work when no turn is running. No adapter emits the new events yet, so behaviour is unchanged until changes 3 and 4.

**Architecture:** Everything is in `SessionService`'s event projection and two commands. A `turn.acknowledged` event marked `origin: "runtime"` makes a turn row when the thread has no unfinished turn. Turn-state events that name an unknown native turn id no longer fall back to the active turn. An agent item's start or end recounts its turn's `openWork`. `AgentAdapter` gains `stopOpenWork`, which `turn.interrupt` calls. The Mac's model stops treating any finished turn as the thread's running one.

**Tech Stack:** Swift 6, swift-testing, PostgreSQL through `WorkspaceStorage`. Tests use `Harness` and `InjectingAdapter` in `Tests/CoordinatorTests/SessionTests.swift` (the fake Codex runtime plus events the test hands it).

**Spec:** `docs/superpowers/specs/2026-11-19-runtime-turns-and-open-work-design.md` (sections "The model", "One unfinished turn", "An agent's life", "Coordinator"). Change 1 (D-259, pull request 240) added the fields this plan writes.

## Global Constraints

- A runtime turn row: `operationId` `runtime:<nativeTurnId>`, `nativeTurnId` set, `status` `.running`, `submission` `.acknowledged`, `origin` `"runtime"`, no user message.
- The trigger is a `turn.acknowledged` event whose payload has `origin` equal to the string `runtime`. Nothing infers a runtime turn from anything else.
- A thread has at most one unfinished turn. A runtime acknowledgement that arrives while one exists makes no row and is logged.
- Turn-state events (`turn.acknowledged`, `turn.state_changed`, `turn.finished`) that name a native turn id the store does not know apply to the active turn only when that turn has no native id yet. Otherwise they change no turn. Item events keep today's fallback, so nothing drawn is lost. An event that names no turn id keeps today's fallback.
- An agent item is a display item whose payload has `agent` true. It is open while its payload `status` is `inProgress`. `openWork` of a turn is the number of its open agent items. `SessionService` is the only writer, and writes only when the number changes. Writing it moves the turn's `updatedAt`, on purpose.
- `stopped` is the payload `status` of an agent closed because its session is gone or it was stopped.
- `AgentAdapter.stopOpenWork(_:)` has a default that throws `WorkspaceError(.unsupportedCapability)` naming changes 3 and 4 (AGENTS.md: never a mocked success).
- Nothing in `Sources/ClaudeAdapter`, `Sources/CodexAdapter`, `Sources/B4Adapter`, `Hub/`, `Sources/WorkspaceMirror` or the transcript views changes in this plan.
- Before each commit: `swift format lint --strict --recursive Sources Tests Apps Package.swift`. If a test target fails to link on stale objects after a signature change, delete `.build/arm64-apple-macosx/debug/*Tests.build`.
- The decision file takes its number from `Scripts/docs-index.sh --next` when its task runs, and is renamed if main takes the number before the pull request merges. D-259 is on main and is not edited.

## Review Focus

1. A runtime acknowledgement arriving twice for the same native turn id (a replay, a reconnect): one row, never two, and no error from the unique `operationId`. Test in Task 1.
2. An agent item whose turn cannot be found (no turn id, no active turn): stored as today, counted nowhere, no crash. Test in Task 2.
3. An agent item completed twice, or completed without ever being seen started: the count never goes below zero and never double-counts. Test in Task 2.
4. A session that exits while a runtime turn is running and an earlier turn has open work: the running turn goes to reconciling as today, and the open work is closed. Test in Task 3.
5. Stop on a thread whose adapter cannot stop open work: the owner gets the error, and the active turn, if any, was still interrupted. Test in Task 4.

---

### Task 1: Runtime turn rows and the turn-state guard

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift` (`environment(_:)`, the turn lookup at about line 1313 and the `.turnAcknowledged` and `.turnFinished` cases)
- Modify: `Tests/CoordinatorTests/SessionTests.swift` (make `InjectingAdapter` internal, not `private`)
- Create: `Tests/CoordinatorTests/RuntimeTurnTests.swift`

**Interfaces:**
- Consumes: `Turn.origin`, `Turn.openWork` (change 1); `Harness`, `InjectingAdapter`, `EventCollector`.
- Produces: the lookup rule and the runtime row, which Tasks 2 to 4 rely on. A helper in the test file, used by later tasks: `func runtimeAck(_ connection: Connection, _ thread: ConversationThread, turn: String) -> AdapterEvent` (kind `.turnAcknowledged`, `nativeIds` `threadId` and `turnId`, payload `["origin": "runtime", "status": "inProgress"]`), and `func injecting() async throws -> (Harness, AsyncStream<AdapterEvent>.Continuation)` wrapping the `Harness.start(adapterFactory:)` pattern of `aLateAcknowledgementLeavesAnEndedTurnAlone`.

- [ ] **Step 1: Write the failing tests** in `RuntimeTurnTests.swift`, suite `RuntimeTurnTests`. Each starts a Codex thread, sends "hello there" and waits for that turn to finish, as the existing injecting tests do.

  - `aRuntimeAcknowledgementMakesATurnRow`: inject `runtimeAck(turn: "rt-1")`. The thread then reads two turns; the new one has `origin == "runtime"`, `operationId == "runtime:rt-1"`, `nativeTurnId == "rt-1"`, `status == .running`, `submission == .acknowledged`. The published `turn.acknowledged` event carries that turn in its payload, and the thread has no new user item.
  - `aRuntimeTurnTakesItsItemsAndItsEnd`: after the acknowledgement, inject a `message.completed` item naming turn `rt-1` (role `assistant`, type `agentMessage`, text "done"), then `turn.finished` naming `rt-1` with payload `["outcome": "completed", "origin": "task-notification"]`. The item's `turnId` is the runtime turn's; the turn is `.terminal`, `.completed`, and its `origin` is `"task-notification"`.
  - `aRepeatedRuntimeAcknowledgementMakesOneRow`: the same acknowledgement injected twice gives two turns in all, not three, and no error is recorded.
  - `aRuntimeAcknowledgementDuringAnUnfinishedTurnMakesNoRow`: acknowledge `rt-1`, then `rt-2` while `rt-1` runs. Still two turns. An item naming `rt-2` is stored with `rt-1`'s turn id (the item fallback). A `turn.finished` naming `rt-2` leaves `rt-1` running.
  - `aFinishNamingAnUnknownTurnEndsNoTurn`: with `rt-1` running, `turn.finished` naming turn `zz` leaves `rt-1` `.running` and the first turn's `updatedAt` unchanged.
  - `anAcknowledgementWithoutOriginMakesNoRow`: a `turn.acknowledged` naming an unknown turn with no `origin` in its payload leaves one turn.
  - `anEventNamingNoTurnStillJoinsTheActiveTurn`: with `rt-1` running, an item event with no `turnId` is stored with `rt-1`'s turn id.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter RuntimeTurnTests`
Expected: FAIL (one turn where two are expected; `rt-1` ended by the unknown finish).

- [ ] **Step 3: Change the lookup in `environment(_:)`**

The turn is found by native turn id as today. When that finds nothing, the fallback to `db.activeTurn(threadId:)` applies if the event names no turn id, or the event is an item event (`messageStarted`, `messageCompleted`, `messageDelta`, `toolStarted`, `toolCompleted`), or the active turn has no `nativeTurnId` yet. For any other event naming an unknown id, `turn` stays nil; log it once at `.info` with the event kind and the native id.

- [ ] **Step 4: Make the runtime row in the `.turnAcknowledged` case**

Before the existing handling: if the payload's `origin` is `"runtime"`, the thread is known, the event names a native turn id, and no row has it, then, when `db.activeTurn(threadId:)` is nil, insert the row of Global Constraints and set `turn` and `event.turnId` to it, with the turn in the published payload under `turn` as the existing case does. When an unfinished turn exists, insert nothing and log at `.error` (the adapters' folding should have prevented it). Publish through the existing path so the event reaches clients once.

- [ ] **Step 5: Carry the origin's kind at the finish**

In `.turnFinished`, inside the existing `updateTurn` closure: if the row's `origin` is not nil and the payload has a string `origin`, set it.

- [ ] **Step 6: Run the tests**

Run: `swift test --filter "RuntimeTurnTests|SessionTests"`
Expected: PASS, including `aLateAcknowledgementLeavesAnEndedTurnAlone` unchanged.

- [ ] **Step 7: Commit**

```bash
git add Sources/Coordinator/SessionService.swift Tests/CoordinatorTests
git commit -m "feat(coordinator): a turn the runtime starts gets a turn row, and a stray finish ends no turn"
```

---

### Task 2: The open-work count

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift` (the item cases of `environment(_:)`; a new private `recountOpenWork(turnId:thread:)`)
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` only if a query for one turn's display items is missing (`displayItems(threadId:)` filtered in Swift is acceptable)
- Test: `Tests/CoordinatorTests/RuntimeTurnTests.swift`, suite `OpenWorkTests`

**Interfaces:**
- Consumes: Task 1's helpers.
- Produces: `private func recountOpenWork(turnId: String, thread: ConversationThread) async throws` (counts, writes on change, publishes `turn.state_changed` with the turn); a test helper `func agent(_ kind: EventKind, _ connection: Connection, _ thread: ConversationThread, id: String, turn: String?, status: String) -> AdapterEvent` (type `toolUse`, role `tool`, item `["agent": true, "title": "Look", "status": status]`).

- [ ] **Step 1: Write the failing tests.** Each uses the first, finished turn's native id (`h.read(thread).turns.first?.nativeTurnId`) as the agents' turn.

  - `anAgentStillRunningIsOpenWork`: `tool.started` for agent `a1` gives the turn `openWork == 1`; a `turn.state_changed` carrying it is published; `ThreadList` gives the thread `activity.openWork == 1` and `Attention.state(of:)` `.working` although the turn is terminal.
  - `openWorkFollowsEachAgent`: start `a1` and `a2` (2), complete `a1` with status `completed` (1), complete `a2` with status `failed` (0). The turn's `updatedAt` is later after each change.
  - `anAgentCompletedTwiceCountsOnce` and `anAgentSeenOnlyAtItsEndCountsNothing`: the count never passes below zero and ends at zero.
  - `aStepThatIsNotAnAgentIsNotOpenWork`: a `tool.started` without `agent` leaves `openWork` 0 and the turn's `updatedAt` unchanged.
  - `anAgentWithNoTurnCountsNowhere`: on a thread with no active turn, an agent event with no turn id is stored, and no turn's `openWork` changes.
  - `aRunningTurnsAgentCountsToo`: acknowledge runtime turn `rt-1`, start an agent naming it: `rt-1` has `openWork == 1` while `.running`.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter OpenWorkTests`
Expected: FAIL (`openWork` stays 0).

- [ ] **Step 3: Implement `recountOpenWork` and call it**

After `environmentItem` stores a `toolStarted` or `toolCompleted` item whose payload has `agent` true and whose stored `turnId` is not nil, call `recountOpenWork` for that turn. It counts the turn's display items with `agent` true and `status` `inProgress`, and, when the count differs from the row's `openWork`, writes it with `db.updateTurn` and publishes the updated turn with the existing `publishTurn(.turnStateChanged, …)`. The item's own event is published first, as today.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "OpenWorkTests|RuntimeTurnTests|SessionTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Coordinator Sources/WorkspaceStorage Tests/CoordinatorTests
git commit -m "feat(coordinator): a turn's open work is the count of its agents still running"
```

---

### Task 3: Closing open work when the session is gone

**Files:**
- Modify: `Sources/Coordinator/SessionService.swift` (`start()`, `environmentConnectionChanged(_:)`; a new private `closeOpenWork(threadId:reason:)`)
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (a query for the turns with `openWork > 0`, all threads or one)
- Test: `Tests/CoordinatorTests/RuntimeTurnTests.swift`, suite `OpenWorkEndsTests`

**Interfaces:**
- Consumes: Task 2's `recountOpenWork` and `agent` helper.
- Produces: `public func turnsWithOpenWork(threadId: String? = nil) throws -> [Turn]` on `WorkspaceDatabase`; `private func closeOpenWork(threadId: String, reason: String) async throws`, which Task 4 does not call (a stop closes through the adapter's events).

- [ ] **Step 1: Write the failing tests**

  - `aSessionThatExitsClosesItsOpenWork`: one open agent on the finished turn; inject `connection.changed` with `transport` `disconnected` and the thread's native id in `nativeIds` (the per-thread exit shape `environmentConnectionChanged` handles). The agent item's payload `status` is `stopped` with an `endedAt`; a `tool.completed` event for it is published; the turn's `openWork` is 0.
  - `aConnectionThatDropsClosesEveryThreadsOpenWork`: the same with no thread id (the whole connection), two threads each with an open agent: both end at 0.
  - `aRunningTurnGoesToReconcilingAndEarlierOpenWorkIsClosed`: an open agent on the finished turn and a running runtime turn `rt-1`; after the per-thread exit, `rt-1` is `.reconciling` (as today) and the first turn's `openWork` is 0.
  - `startUpClosesOpenWorkLeftBehind`: a second coordinator started on the first one's data directory, the way the existing start-up test of reconciling turns does it (find it by searching `Tests/CoordinatorTests` for a test that restarts the service and expects `.reconciling`; reuse its restart helper). After the restart the agent is `stopped` and `openWork` is 0. If no restart helper exists, test `start()` directly on a `SessionService` built over a database that already holds the rows, as that test file builds one.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter OpenWorkEndsTests`
Expected: FAIL (`openWork` stays 1).

- [ ] **Step 3: Implement**

`closeOpenWork` takes each turn of the thread with `openWork > 0`; for each of its open agent items it sets payload `status` to `stopped` and `endedAt` to now with `db.updateDisplayItem`, publishes a `tool.completed` event carrying the stored item (the shape `completeStreamedItems` publishes for a message), then calls `recountOpenWork`. `environmentConnectionChanged` calls it for the thread on a per-thread exit and for every thread of the connection with open work on a connection exit, with reason `runtime_exited`. `start()` calls it for every turn `turnsWithOpenWork()` returns, with reason `coordinator_started`, after the existing reconciling loop; a failure is logged and does not stop start-up, as the loop's is.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "OpenWorkEndsTests|OpenWorkTests|RuntimeTurnTests|SessionTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Coordinator Sources/WorkspaceStorage Tests/CoordinatorTests
git commit -m "feat(coordinator): open work is closed as stopped when its session is gone"
```

---

### Task 4: Stop reaches open work

**Files:**
- Modify: `Sources/WorkspaceProtocol/Adapter.swift` (`AgentAdapter`, its default extension)
- Modify: `Sources/Coordinator/SessionService.swift` (`turnInterrupt(_:)`, about line 1074)
- Test: `Tests/CoordinatorTests/RuntimeTurnTests.swift`, suite `StopOpenWorkTests`

**Interfaces:**
- Produces: on `AgentAdapter`, `func stopOpenWork(_ ref: NativeSessionRef) async throws`, with the default implementation throwing `WorkspaceError(.unsupportedCapability, "Stopping background agents arrives with the Claude Code and Codex adapter changes of the runtime turns design.")`. A test adapter `StoppingAdapter` in the test file: wraps an `InjectingAdapter`, forwards everything, and records `stopOpenWork` calls in an actor (`calls: [NativeSessionRef]`), optionally throwing.

- [ ] **Step 1: Write the failing tests**

  - `stopWithNoTurnStopsOpenWork`: an open agent on the finished turn, no active turn. `turn.interrupt` on the thread returns without error, the result's turn is the turn holding the open work, and the adapter recorded one `stopOpenWork` for the thread's session ref. The turn is not changed by the call itself (the agents close when the adapter's events say so).
  - `stopWithNeitherIsRefusedAsBefore`: no active turn and no open work: `notFound`, message "No turn is active on this thread."
  - `stopWithATurnAndOpenWorkStopsBoth`: a running runtime turn `rt-1` and an open agent on the earlier turn: the adapter saw one `interrupt` naming `rt-1` and one `stopOpenWork`, and the result's turn is `rt-1`'s.
  - `stopSaysSoWhenTheAdapterCannotStopOpenWork`: the same with an adapter whose `stopOpenWork` is the protocol's default: the command throws `unsupportedCapability`, and the `interrupt` of `rt-1` was still made.
  - `stopWithOnlyATurnDoesNotCallStopOpenWork`: a running turn and no open work: `interrupt` only.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter StopOpenWorkTests`
Expected: build failure (`stopOpenWork` is not a member), then FAIL.

- [ ] **Step 3: Add `stopOpenWork` to the protocol** with its default, and a doc comment: it stops every background agent the session still runs; the agents' ends arrive as ordinary item events.

- [ ] **Step 4: Change `turnInterrupt`**

Read the active turn and whether the thread has open work (`turnsWithOpenWork(threadId:)`). With neither, throw as today. With an active turn, interrupt it and update and publish it exactly as today. Then, with open work, call `adapter.stopOpenWork(ref)`; an error from it is thrown after the active turn's update has been stored and published. The result's turn is the active turn's when there is one, else the newest turn with open work.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter "StopOpenWorkTests|SessionTests|RelayExecutorTests|ThreadDeleteTests"`
Expected: PASS (the other adapters in the test targets inherit the default).

- [ ] **Step 6: Commit**

```bash
git add Sources/WorkspaceProtocol/Adapter.swift Sources/Coordinator/SessionService.swift Tests/CoordinatorTests
git commit -m "feat(coordinator): Stop reaches background agents when no turn is running"
```

---

### Task 5: The Mac's model keeps a running turn through another turn's end

**Files:**
- Modify: `Sources/WorkspaceUI/WorkspaceModel.swift` (`apply(_:)` at about line 1870, `applyToDetail` at about line 1914)
- Test: `Tests/WorkspaceUITests/WorkspaceModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks. This is the design's second guard; with one unfinished turn per thread it should never matter, and it turns a future ordering mistake into a visible one.

- [ ] **Step 1: Write the failing tests**, built the way the file's existing tests build a model and hand it events:

  - `aTurnEndingDoesNotClearAnotherTurnThatIsRunning`: the model holds running turn `A` for a thread; a `turn.finished` event carrying terminal turn `B` of the same thread leaves `activeTurns[threadId]?.id == "A"`, and the thread's Stop state is untouched.
  - `aTurnEndingClearsItself`: a `turn.finished` carrying `A` clears it, as today.
  - `aTurnEndingKeepsTheLiveTextOfAnotherRunningTurn`: with the thread open, `A` running and text streaming for one of its messages, a `turn.finished` for `B` leaves that stream live; a `turn.finished` for `A` ends it, as today.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter WorkspaceModelTests`
Expected: the first and third FAIL.

- [ ] **Step 3: Implement**

In `apply(_:)`: a non-terminal turn sets `activeTurns[threadId]` as today; a terminal turn clears it, and `stopStates`, only when the entry is that same turn or there is none. In `applyToDetail`: after the turn is upserted, a `turn.finished` ends the live text only when it leaves no turn running in the detail (`current.activeTurn == nil`); the existing second condition stays as it is.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "WorkspaceModelTests|DenseTranscriptViewTests|SendStateTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WorkspaceUI/WorkspaceModel.swift Tests/WorkspaceUITests/WorkspaceModelTests.swift
git commit -m "fix(ui): one turn's end does not clear another turn that is running"
```

---

### Task 6: Records

**Files:**
- Create: `docs/decisions/D-NNN-runtime-turns-in-the-coordinator.md`
- Create: `docs/verification/<date verified>-runtime-turns-in-the-coordinator.md`
- Modify: `docs/milestones.md`, `AGENTS.md` (the Layout bullet on `SessionService`: it is also the only maker of runtime turn rows and the only writer of `openWork`)

- [ ] **Step 1: Write the decision**, in the log's style (read `docs/decisions/D-259-open-work-and-origin.md` first). It records: the runtime row and its trigger; one unfinished turn per thread, which settles D-259's open point ("amends D-259"), with the recordings that showed turns never overlap and the fold that changes 3 will build; the turn-state guard and why item events keep the fallback; the open-work count and that writing it moves `updatedAt`; that the coordinator closes open work on a reported exit and at start-up, and that an adapter's own restart is the adapter's to report (change 3); `stopOpenWork` and its default; that Stop on a thread interrupts the turn and the open work.
- [ ] **Step 2: Write the gate record**: commands run and their summary lines, the tests added, and under "Not checked": anything in the running app, since no adapter emits a runtime acknowledgement or an agent item yet; Stop against a real runtime.
- [ ] **Step 3: Run** `Scripts/docs-index.sh --check`, the full `swift test`, and the format lint. Expected: PASS. Record exactly what ran.
- [ ] **Step 4: Commit**

```bash
git add docs AGENTS.md
git commit -m "docs: runtime turns in the coordinator (D-NNN)"
```
