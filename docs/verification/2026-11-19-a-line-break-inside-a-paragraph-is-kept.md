## 2026-11-19: A line break inside a paragraph is kept (D-256)

- **Found on screen.** Local build from main (99bf5ec5), test thread on Claude Code: a stored reply of the numbers 1 to 120, one per line (120 lines in `thread show --json`), drew as four wrapped lines.
- **Red.** With the tests rewritten and the old join in place: `linesSetApartByLineBreaksStayApart` (`"p "1 2 3""` for `1\n2\n3`), `paragraphsAreSplitByBlankLinesAndALineBreakInOneIsKept`, and `MarkdownViewTests.aLineBreakInAParagraphIsALine` (20 pt for `one\ntwo` against 44 pt for a hard break) failed; `aHardBreaksMarkerIsDroppedAndItsLineBreakKept` passed before and after.
- **Green.** After the change, 15 further expectations in `StreamingMarkdownTests` failed for spelling a joined paragraph with a space and were updated to the line break; no other test changed.
- **Gates.** `swift test` in CI's two processes: 528 tests in 68 suites (`WorkspaceStorageTests`, `CoordinatorTests`) and 1738 tests in 187 suites, all passed. `swift format lint --strict` and `Scripts/docs-index.sh --check` clean.
- **Not checked.** The fix on screen in a rebuilt app; the phone; a code span or emphasis that spans a line break (now holds the line break, no test).
