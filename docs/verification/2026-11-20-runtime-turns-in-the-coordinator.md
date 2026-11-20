## 2026-11-20: runtime turns in the coordinator (D-262)

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

Each of the five code tasks had a task review. Task 1 had one fix round: the operation id was made per thread, the fallback was kept for requests, and refused runtime ids are remembered. Task 3 had two: the start-up close takes its list at start-up, and each agent is read again before it is stopped; then a fixture race, where the fake Codex's trailing idle status satisfied a wait early, found through a one-off failure of `theItemIsPublishedBeforeTheTurnsCount` and fixed in the fixture, followed by ten clean runs of the three suites. Deferred minors still open are listed in D-262, "Known gaps".

### Not checked

- Anything in the running app. No adapter emits a runtime acknowledgement or an agent item yet, so no thread can show a runtime turn or open work.
- Stop against a real runtime. Only the default `stopOpenWork` and the test adapters' versions were run.
- The phone.
