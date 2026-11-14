## 2026-11-13: a dense thread

D-223: with Dense on, a thread draws each turn as the user's message, one line for the agent's work and the answer; the line names the running step while the turn runs and counts the steps once it has ended; the phone has the Display page. Branch `blove/dense-thread`, with `main` acef750 merged in; gates on cb9d44f. UI only: no hub, store, mirror or wire change, and no migration.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`: 1849 tests in 219 suites passed. The dense thread's own tests are `DenseTranscriptTests` (the rules: what is a step, the answer, a failure, a running turn, history groups) and `DenseTranscriptViewTests` with `TranscriptScrollTests` (hosted views: heights at both densities, the real scroll view held and released).
- `xcodebuild build` for `B4App-macOS` and for `B4App-iOS` on the generic Simulator: both `BUILD SUCCEEDED`.
- `./Scripts/test-ios-layout.sh`: 16 of 16 passed on "B4App Layout 819684910" (iPhone 17 Pro).
- `Scripts/docs-index.sh --check`: 213 decisions and 130 verification records are well formed (before this record).
- Snapshots (`ListSnapshotTests.denseThreads`, written with `B4APP_SNAPSHOT_DIR`, 720 by 560, light and dark): closed, open, failed (one failed and one declined step, a failed turn with no answer), running (a named step over two interim messages), waiting, working, history, and the normal transcript for comparison. All sixteen images were looked at when they were first drawn; the failed, open and history images were looked at again on the final tree. The line is one muted line, "1 failed" and "Turn failed." are the only colour, nothing is clipped.
- Reviews: each task had a spec and quality review; the whole branch had one more, whose findings (the line was not a button to assistive technology, an unlabelled B4 tool call named itself with a debug dump, the hold outlived a density switch, an empty last message was taken as the answer, four inaccurate sentences in D-223) were fixed and checked again.

### Not checked

- A real running turn in the app, on any runtime. The spec names this as the part most likely to need a look: the line naming each step as it starts, the interim messages folding when the turn ends, and opening a turn while another streams.
- A thread read from history on each runtime, and scrolling in the running app. In the hosted test window, after the view had followed a stream, scrolling to the very end by hand stopped the document growing as more text arrived; the same happened at the commit before the scroll change. Whether that is the offscreen window or a real fault is not known.
- The phone. Its page list and description are in `#else` branches that `swift test` (macOS only) does not run, and the layout tests never open Settings; they are covered by the iOS build and by reading. Whether the hold releases correctly under the phone's bottom bar and keyboard was not looked at in the Simulator.
- VoiceOver on the line. The hosted test window exposes no accessibility tree, so that the line is a button with its label is read from the code, not tested.
- The large-type layout of the line on a phone: macOS does not scale the line's font with the type size, so the test squeezes the row to 100 pt instead.
- The counted types for Codex's `dynamicToolCall`, `imageView`, `collabAgentToolCall` and `imageGeneration`, and the Claude Code tool names left out of the count, are inferred from the adapters and not from a recorded run.

### Seen along the way

- `KeepAwakeTests.settingsAreServedOverTheSocketAndDiagnosticsShowTheAssertion` timed out (`diagnostics.read`, 15 seconds) when the suite was run alone, twice, and in one of two full runs; it passed in the final full run. This change does not touch the coordinator. It was not checked on `main`.
