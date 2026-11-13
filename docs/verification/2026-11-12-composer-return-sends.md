## 2026-11-12: Return sends from the composer

D-219: the Mac's composer sends on Return and adds a line on Shift-, Option- or Control-Return, never adds a line when nothing can be sent, leaves Return to an input method while it composes, and stops at three lines with the text scrolling inside the field. Branch `blove/composer-enter-send`, from `main` cf19047. Research: `docs/research/2026-11-12-composer-enter-key-conventions.md`.

### Gates

- `swift test --filter "ComposerKeyTests|ComposerTextViewTests"`: 6 pass. `ComposerKeyTests` covers each command's action and that nothing sends while composing. `ComposerTextViewTests` hosts `ComposerField` in a window:
  - **Height:** the field is one line empty and stops at three lines with twelve lines typed. The field is no taller than at three lines, the text view scrolls inside, and the last line is in view. That still holds after six more blank lines (the case that spilled out). Clearing the draft brings it back to one line.
  - **Keys and focus:** focus lands in the text view. Return calls the caller and leaves the text alone; `insertNewlineIgnoringFieldEditor:` and `insertLineBreak:` add plain line feeds.
  - **Real key events** through `keyDown`: Return and keypad Enter send, Shift-, Option- and Control-Return add lines, and Command-Return sends.
  - **Input method:** with marked text, the delegate leaves `insertNewline:` to the text system and nothing sends.
- A first version of the key-event test posted events to `NSApp` and pumped `nextEvent`. After it, the next test's `setMarkedText` made the test process exit with status 0 mid-run, with no summary. The editor now reads the key event its own `keyDown` received, not `NSApp.currentEvent`, and the test hands events to `keyDown`; the six tests pass together.
- Rendered with `B4APP_SNAPSHOT_DIR=… swift test --filter ComposerTextViewTests/theFieldStops`, light and dark, and looked over by eye:
  - `composerEmpty` and `composerOneLine`: typed text starts where the placeholder does.
  - `composerFull`: three lines inside the box, the last three of twelve.
  - The `SnapshotTests` shell and `newThreadComposer` show the field with the turn note and the picker row aligned to its text.
- `swift test`: 1710 tests, 8 failing, all in `MirrorSyncTests`, timeouts waiting on its fake hub while two `xcodebuild` runs shared the machine. Run alone, `MirrorSyncTests` passes 23/23. `SnapshotTests`, `ComposerTurnNoteTests`, `NewThreadDraftTests` and `DetailMinimumSizeTests` pass (72).
- `swift format lint --strict`, `Scripts/docs-index.sh --check`, and `xcodebuild` of `B4App-macOS` (Debug) and of `B4App-iOS` for the Simulator.

### Not checked

- **The running app:** not typed into. Access to the installed Beta app was declined, and the Local app can't open its data until #188 merges.
- **A real input method:** Japanese, Pinyin or Korean were not typed. The test sets marked text directly, so the claim that the input method consumes the committing Return before the command handler rests on AppKit's documented order and the research.
- **The phone:** its field is unchanged and its layout tests were not run. Whether a hardware keyboard's Return sends on an iPad through the Send button's shortcut was not tried, nor whether the phone's vertical `TextField` overflows past three lines.
