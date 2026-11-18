## 2026-11-17: a turn that ended with no outcome

D-251, hill climb defect 13. Branch `blove/turn-with-no-outcome` from `main` 7f0482ff. One view type in `WorkspaceUI` (`TurnNoteRow` in `TranscriptView.swift`) and a comment in `DenseTranscript.swift`. No coordinator, adapter, wire, hub or mirror change.

### Cause

Read from the code, then pinned by the test:

- `TurnNoteRow.text` was `turn.outcome == .cancelled ? "Turn stopped." : "Turn failed."`, and its colour followed the same test, so a nil outcome was a red "Turn failed.".
- `DenseTranscript.hasNote` draws the note for any terminal turn that is not `completed`, at both densities.
- The other readers of an outcome treat none as not failed: `Attention.state(of:)`, `turn_reason` in `Hub/crates/b4hub-core/src/push.rs`, and the thread detail line in `ThreadsView`.
- Adapters: Codex, Claude Code and B4 each set an outcome on every finished turn they emit, so the state comes from sync order or an unknown value, not from a local turn.

### Test

`DenseTranscriptViewTests.aTurnThatEndedWithNoOutcomeIsNotDrawnAsFailed`. Against the old rule (with `isFailure` added as "not cancelled" so it built) it failed on two expectations: the text was "Turn failed." and it was a failure. After the change it passes, with `failed` still a failure and `cancelled` still "Turn stopped.".

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 524 tests in 68 suites passed.
- `swift test --skip` the same: 1517 tests in 167 suites passed.
- `Scripts/docs-index.sh --check`: passed.

### Untested

- The note on screen, on the Mac or the phone.
- The state itself in a running app: no turn was made terminal with no outcome through a real sync. How often a reader meets it is not measured.
