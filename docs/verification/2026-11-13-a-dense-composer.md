## 2026-11-13: a dense composer

D-224: with Dense on, the Mac's composer, in a thread and on the new-thread screen, draws one muted line saying where and with what the next message runs ("b4app · Claude Code · Opus") where the row of pickers was; the choices are changed from the command palette or `/` in the field, and "Choose folder…" (`/browse`) is a new command. Branch `blove/dense-composer` from `main` f8a28e0; gates on 4cdf08c. UI only: no hub, store, mirror or wire change, and no migration. The phone and the iPad keep their pickers.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`: 1889 tests in 221 suites passed. The dense composer's own tests are `ComposerSummaryTests` (the line's words and VoiceOver's sentence for a draft and a thread: the place, a chosen folder, no folder, remote B4, a permission that is not the default, no connection), `DenseComposerTests` (hosted views read through the accessibility tree: the line and no pickers at dense, the pickers and no line at normal, "Starting…" in the line's place, a failed start and a blocked reason under it, a long place cut with the rest whole) and the new cases in `PaletteTests` ("Choose folder…": where it is offered, when it is refused, `/browse`, a folder row's path).
- `xcodebuild build` for `B4App-macOS` and for `B4App-iOS` on the generic Simulator: both `BUILD SUCCEEDED`.
- `./Scripts/test-ios-layout.sh`: 16 of 16 passed on "B4App Layout 819684910" (iPhone 17 Pro), unchanged, since the phone keeps its pickers.
- `Scripts/docs-index.sh --check`: 214 decisions and 131 verification records are well formed (before this record).
- Snapshots (`ListSnapshotTests.denseComposers`, light and dark): a dense thread composer, the same with a permission that is not the default, the dense new-thread screen, "Starting…", a failed start, a blocked reason, a long place at 420 pt, and the normal new-thread screen for comparison. All sixteen images were looked at when drawn. The line's first letter is under the field's first letter, the long place is cut in its middle with the runtime and permission whole, and the failure is the only colour.

### An earlier run

The first full run, on 14b92aa, had one failure in 1888 tests: `MirrorSyncTests.recoveryChecksAQuietHubWithoutWaitingForNewChanges` timed out after 61 s "waiting for the recovery pull". It is the phone's sync, which this change does not touch. Run alone on 4cdf08c the suite's 23 tests passed in under a second, and the full run on 4cdf08c passed. It was not looked into further and was not checked on `main`.

### Reviews

Each of the four tasks was reviewed against its brief, and the branch once as a whole. What they found and what was done:

- "Choose folder…" reported success and did nothing when the new-thread screen was not showing. It is now refused with "Open a new thread first." (`newThreadViewIsShowing`), and on iOS.
- A failed start would have hidden the line until the next Send, while the place is being changed to fix it. Only "Starting…" takes the line's row now; a failure sits under the line. This departs from the design, which gave a failed send the row (D-224).
- Cancelling the folder panel opened from the palette could leave nothing focused. The cursor returns to the field however the panel closes.
- VoiceOver would have said "Bypass permissions permissions". It says the permission's label alone, and reads the place's " · " as a comma.
- Two folders with the same name looked alike in "Choose where it starts…". A folder's row carries its path.

Left as they are: the rule for when the new-thread screen shows is written in `ThreadsView` and again in the model, held together by comments; its loading branch has no test; the middle cut is shown by a snapshot, not asserted; `HostedScreen` turns the accessibility tree on for the whole test process while one is alive.

### Not checked

- The running app at dense: nothing here was looked at on a real screen.
- The folder panel opened from the palette or `/browse`, and where the cursor is after it closes or is cancelled. The focus handling was changed for it and has no test.
- VoiceOver itself. The label is read from the accessibility tree in a test window.
- The narrowest window on a real screen, where a long connection label is cut at its end.
- The iOS-only branches of the tests, which `swift test` does not compile.
