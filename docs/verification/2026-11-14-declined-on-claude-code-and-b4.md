## 2026-11-14: declined on Claude Code and B4, and a dot before Show

D-227: a tool call the app refused is stored `declined`, not `failed`, on Claude Code and B4, as Codex already does; the dense thread's line draws a `·` before `Show`; the detail column's rule is one `WorkspaceModel.detailPane`. Branch `blove/declined-steps` from `main` 5edf935, with `main` b3bd942 merged in; gates on 9ce244f except where said. No hub, store, mirror or wire change, and no migration: the status is a value in a display item's payload that Codex already stores.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`: 1897 tests in 221 suites, one failure, `KeepAwakeTests.settingsAreServedOverTheSocketAndDiagnosticsShowTheAssertion` ("diagnostics.read" timed out after 15 s), with the machine's load average at 42 from other sessions. The suite's 8 tests passed alone straight after. It is the coordinator's power assertion, which this change does not touch, and it has failed the same way on other branches. No full run on this branch was clean; see "Earlier runs".
- The change's own tests: `ClaudeEventsTests` (a marked tool use's error result is `declined`, another's is `failed`, a mark taken back leaves the result its own), `ClaudeSessionTests` (the fake Claude Code's denied tool ends `declined` with its output), `B4TranslatorTests` (a refused call the stream showed is closed `declined` and its later result stays so; one it never showed waits for its result), `B4AdapterSessionTests` (Deny and a decline close the prompt's call as `declined`, Allow closes nothing), `PaletteTests` (a thread still opening is not the new-thread screen). The Claude Code and B4 adapter suites, 116 tests, passed alone.
- `swift test --filter WorkspaceUITests`: 636 tests in 67 suites passed, twice, on 4daf129.
- `xcodebuild build` for `B4App-macOS` and for `B4App-iOS` on the generic Simulator: both `BUILD SUCCEEDED`, on f5e5606, before the dot moved into the action's text and before `main` was merged. Not rebuilt after; CI builds both.
- `./Scripts/test-ios-layout.sh`: 16 of 16 passed, 129 of 129 checkpoints, on "B4App Layout 819684910" (iPhone 17 Pro), also on f5e5606.
- `Scripts/docs-index.sh --check`: well formed.
- Snapshots (`ListSnapshotTests.denseThreads`): the running line reads "swift test --filter SyncTests · Show" and the failed one "3 steps, 1 failed, 1 declined · Show", light and dark. The running and failed images were looked at before and after the dot moved into the text; they are alike.

### Earlier runs

- The first full run, on f5e5606, had one failure: `DenseTranscriptViewTests.openingATurnLeavesItsLineWhereItWas` timed out "waiting for the transcript to settle". It passed alone three times and failed every time the whole UI target ran. The cause was this change: the dot was drawn as a view of its own in the line's row. Without the dot the UI target passed; with the dot as part of the action's text (4daf129) it passed twice. Why a third view in that row keeps the lazy stack from settling was not found.
- A second full run on f5e5606, with the load average above 30, had 10 issues: that test again, `MirrorSyncTests.resyncUsesTheSnapshot` (a timeout) and `CodexAdapterTests.acceptsCompatibleVersion`. The last two did not recur in the final run and were not looked into.

### Not checked

- Either runtime live. That Claude Code sends an error result for a tool use the app denied, and that B4's prompt names its `toolCallId`, is what the fakes do. What the real B4 sends after a denial was not seen.
- The running app: the dot on a real screen, and a refusal made in it on each runtime.
- The folder panel's focus handling, still without a test, and the middle cut of a long place, still shown only by a snapshot (D-224's list).
