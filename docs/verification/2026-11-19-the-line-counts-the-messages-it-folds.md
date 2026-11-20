## 2026-11-19: The line counts the messages it folds (D-261)

- **Found on screen.** Local build from main (2d5395f7), a fresh Codex thread: a finished turn drew `1 step · 17s`, `Show` and `done`; the turn's first message (a heading, a table, a nested list, a code block and six lines) was behind the line.
- **Measured.** The Local app's store held 8 interim messages in 21 ended turns, all from test threads (median 281 characters); too few to choose a size rule from.
- **Red.** With the field added and counting nothing: `theLineCountsTheMessagesItFolds` (0 for 2), `foldedMessagesAloneAreNamedAndNotShowWorking` (`Show working`), and the two changed expectations failed, 10 issues in all.
- **Green.** `DenseTranscriptTests`, `DenseTranscriptViewTests` and `TranscriptScrollTests` pass (107 tests). One expectation written wrong on the way: a line that folds only a message has no duration.
- **The note.** Red: `aFailedTurnWhoseLineSaysFailedHasNoNote` (closed and open), `aTurnsNoteFollowsItsTurn` and the corpus scenario, 4 issues. Green after the change, 119 tests in the four transcript suites.
- **Gates.** `swift test` in CI's two processes: 529 tests in 68 suites (`WorkspaceStorageTests`, `CoordinatorTests`) and 1748 tests in 187 suites, all passed. `swift format lint --strict` and `Scripts/docs-index.sh --check` clean.
- **On screen.** The Local app built from this branch: the Codex test turn that read `1 step · 17s` reads `1 message · 1 step · 17s`, with `Show` and `done`.
- **Not checked.** A failed turn without its note on screen (no failed turn with a failed step was to hand; tests only); the phone; VoiceOver. The captures under `docs/screenshots` were not regenerated: none of their fixtures folds a message, and `transcript-activity-failed-closed-*` still show the note.
