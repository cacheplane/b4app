## 2026-11-18: only the reader's own send returns the transcript to the end

D-254, hill climb defect 15. Branch `blove/scrolled-back-reader-stays` from `main` f0ff88e3. `WorkspaceUI` only: `WorkspaceModel.swift` and `SendState.swift` (the count), `TranscriptView.swift` (the rule), `ThreadsView.swift` (passing the count). No coordinator, adapter, wire, hub or mirror change.

### Cause

Read from the code, then reproduced by the test:

- `TranscriptView` had `.onChange(of: detail.turns.count)`: when the count rose while the view was held, it released the hold and scrolled to the end. Nothing in it could tell whose turn it was.
- On the Mac `pending` is always nil, so that rule was the only thing that took the reader to the end after their own send. The phone had `.onChange(of: pending?.id)` as well, which fires both when a send is made and when it is cleared.

### Tests

- `TranscriptScrollTests.aTurnFromAnotherDeviceDoesNotMoveAReaderWhoScrolledBack` (the real `TranscriptView` in a 720 by 480 window): a reader 300 pt back from the end, then a thirteenth turn with its message. With the old rule put back beside the new one it failed on both expectations: the hold was released and the view had moved 369 pt. With the old rule gone it passes: the hold stays and the view's origin is unchanged.
- `TranscriptScrollTests.sendingAMessageReleasesTheHold` now raises `sent` with the new turn, as the model does, and still ends released and at the end.
- `OwnSendTests` (three tests, `ScriptedTransport`): a send is counted at the press, while its reply is still held; an empty composer sends and counts nothing; a turn that arrives in a reload is not counted. The first failed before the count was raised (0, expected 1).

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 525 tests in 68 suites passed.
- `swift test --skip` the same: 1532 tests in 170 suites passed.
- `Scripts/docs-index.sh --check`: passed.

### Untested

- The transcript in the running app, on the Mac or the phone: no turn was started from a second device while a first was scrolled back.
- The phone's path through the view. The hosted tests are macOS; the phone's count is raised in `relaySend`, which no test here drives.
- A thread's first message (`startThread`): it opens a new thread, which starts at its end, and raises no count.
