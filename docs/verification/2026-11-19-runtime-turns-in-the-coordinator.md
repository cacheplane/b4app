## 2026-11-19: runtime turns in the coordinator (D-263)

The second part of the runtime turns design: the coordinator makes a row for a turn the runtime starts, keeps each turn's open work, closes open work when its session is gone, and stops it. Built on `blove/runtime-turns-coordinator`. No adapter emits a runtime acknowledgement or an agent item yet, so the running app behaves as before.

### Commands

- `swift test --filter CoordinatorTests`: `Test run with 392 tests in 50 suites passed after 82.338 seconds.`
- `swift test --filter WorkspaceStorageTests`: `Test run with 170 tests in 23 suites passed after 25.476 seconds.`
- `swift test --filter WorkspaceUITests`: `Test run with 832 tests in 85 suites passed after 68.370 seconds.`
- `swift test` (full, one process): `Test run with 2323 tests in 263 suites passed after 119.198 seconds.` No test failed in any run, so no re-run was needed.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: no output, exit 0.
- `Scripts/docs-index.sh --check`: `docs-index: 247 decisions and 161 verification records are well formed`, exit 0.

### Tests added

- `Tests/CoordinatorTests/RuntimeTurnTests.swift`, 30 tests in four suites.
  - `RuntimeTurnTests`: a runtime acknowledgement makes a row, takes its items and its end, is repeated without a second row, makes no row during an unfinished turn, and without `origin` makes none; a finish naming an unknown turn ends no turn; an event naming no turn, and a request naming an unknown turn, still join the active turn; two threads can each hold a runtime turn with the same native id; a refused runtime turn's finish does not end an unacknowledged turn.
  - `OpenWorkTests`: a running agent is open work, the item is published before the turn's count, the count follows each agent, an agent completed twice counts once, an agent seen only at its end counts nothing, a step that is not an agent is not counted, an agent with no turn counts nowhere, and a running turn's agent counts.
  - `OpenWorkEndsTests`: a session exit closes its open work, an agent already closed is not rewritten, a connection drop closes every thread's open work, a running turn goes to reconciling and earlier open work is closed, start-up closes open work left behind, start-up does not close an agent opened after it, and a close does not overwrite an agent that ended meanwhile.
  - `StopOpenWorkTests`: Stop with no turn stops open work, with neither is refused as before, with a turn and open work stops both, says so when the adapter cannot stop open work, and with only a turn does not call `stopOpenWork`.
- `Tests/WorkspaceUITests/WorkspaceModelTests.swift`, 3 tests: `aTurnEndingDoesNotClearAnotherTurnThatIsRunning`, `aTurnEndingClearsItself`, `aTurnEndingKeepsTheLiveTextOfAnotherRunningTurn`.
- `Tests/CoordinatorTests/SessionTests.swift`: one line changed in an existing test.

### Review

Each of the five code tasks had a task review. Task 1 had one fix round: the operation id was made per thread, the fallback was kept for requests, and refused runtime ids are remembered. Task 3 had two: the start-up close takes its list at start-up, and each agent is read again before it is stopped; then a fixture race, where the fake Codex's trailing idle status satisfied a wait early, found through a one-off failure of `theItemIsPublishedBeforeTheTurnsCount` and fixed in the fixture, followed by ten clean runs of the three suites. Deferred minors still open are listed in D-263, "Known gaps". One more gap, found in the records review: quit and log-out do not stop open work on a thread that has no running turn. The session's process ending is what ends those agents. On quit the coordinator cancels its event pumps before the adapters are disposed, so no exit event is handled, and the agents are closed as stopped only at the next start-up.

### Fixes after the whole-change review

The whole-change review found four code faults, one weak test, a wrong comment, and gaps in the records.

- A turn's `openWork` could stay above 0 with no agent in progress. Start-up now recounts every turn with open work, and an item event recounts its turn when that turn's count is above 0 even without the `agent` flag. New tests: `aCompletionWithoutTheAgentFlagStillClosesTheCount` and `startUpHealsACountWithNoOpenAgent` (the second writes `openWork` 1 to the turn's row through the harness's database before the restart).
- Stop read the open work before the interrupt and skipped `stopOpenWork` when the interrupt threw. It now reads the open work again after the interrupt, and calls `stopOpenWork` after a failed interrupt, throwing the interrupt's error. New test: `stopStillStopsOpenWorkWhenTheInterruptFails`.
- Deleting a thread now calls `stopOpenWork` when the thread has open work. New test: `deletingAThreadAsksItsOpenWorkToStop` in `ThreadDeleteTests` (the fake Codex runs no agents, so the test writes the turn's count to its row).
- `aTurnEndingDoesNotClearAnotherTurnThatIsRunning` waited on a turn its first iteration had already delivered. Each iteration now sends a turn of its own. With the guard in `WorkspaceModel.apply` bypassed for `turn.state_changed` (a temporary edit, reverted), the new test failed at both expectations and the old one passed three times.
- The comment on `refusedRuntimeTurns` now says when the set is dropped.

All four new coordinator tests failed before their fixes and passed after.

Commands, after the fixes:

- `swift test --filter "RuntimeTurnTests|OpenWorkTests|OpenWorkEndsTests|StopOpenWorkTests"`, five runs in a row: `Test run with 33 tests in 4 suites passed` after 10.486, 12.264, 9.138, 9.353 and 8.024 seconds.
- `swift test --filter CoordinatorTests`: `Test run with 396 tests in 50 suites passed after 73.233 seconds.`
- `swift test --filter WorkspaceUITests`: `Test run with 832 tests in 85 suites passed after 64.826 seconds.`
- `swift test` (full, one process): `Test run with 2327 tests in 263 suites passed after 118.241 seconds.` No test failed, so no re-run was needed.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: no output, exit 0.
- `Scripts/docs-index.sh --check`: `docs-index: 247 decisions and 161 verification records are well formed`, exit 0.

### Not checked

- Anything in the running app. No adapter emits a runtime acknowledgement or an agent item yet, so no thread can show a runtime turn or open work.
- Stop against a real runtime. Only the default `stopOpenWork` and the test adapters' versions were run.
- The phone.
