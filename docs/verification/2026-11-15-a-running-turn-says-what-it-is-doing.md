## 2026-11-15: a running turn says what it is doing

D-239, for defect 7 of `docs/research/2026-11-14-agent-chat-hill-climb.md`. Branch `blove/running-line-normal-density` from `main` da5231a1. `WorkspaceUI` and its tests only: no coordinator, adapter, hub, store, mirror or wire change, and no migration.

### Before

- `DenseTranscript.plain` gave a running turn its items and nothing else; `DenseTranscript.entries` gave a running turn with only the user's message that message alone (`aRunningTurnWithNothingYetHasNoLine` asserted it). No capture of the base was taken: the base draws the same rows without the line.

### After

- Normal density: a running turn's rows end in `running-<turn id>`, reading "Working", the newest open step's name ("swift test", the first line of a two-line command), or "Waiting for you"; ended turns, a turn whose outcome is unknown, and history have none; two running turns each have their own, and one with no items has it at the end.
- Dense: the line is drawn before the turn's first item and not once a steps line or a reply stands there.
- Captures, 720 by 560 pt at 2x from `ListSnapshotTests.denseThreads`: `docs/screenshots/transcript-running-line-normal.png` (a running turn with an open step and a streaming reply, light), `transcript-running-line-sent-dark.png` (normal density before the first item, dark), `transcript-running-line-sent-dense.png` (dense before the first item, light). Each was read after it was written: the mark and the words stand under the last row, muted, in both schemes.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`, as CI runs it: `WorkspaceStorageTests` and `CoordinatorTests`, 514 tests in 67 suites passed; everything else, 1461 tests in 162 suites passed.
- `xcodebuild build` of `B4App-macOS` and of `B4App-iOS` for the Simulator: both succeeded.
- `Scripts/docs-index.sh --check`: passes with this record and D-239.

### Not checked

- The running app, on the Mac or the phone: the app journeys were not run (UI Automation Mode on this Mac is disabled until the owner enables it), and no journey reads the line yet.
- VoiceOver on the line, the mark's motion and Reduce Motion (a capture is one frame), accessibility text sizes.
- A live runtime: the turn statuses came from scripted details.
