## 2026-11-15: a Claude Code reconcile adds no rows

D-238, for defect 12 of `docs/research/2026-11-14-agent-chat-hill-climb.md`. Branch `blove/claude-reconcile-duplicates` from `main` da5231a1. `ClaudeAdapter`, `WorkspaceStorage` and tests: no hub, mirror, wire or UI change, and no migration.

### The defect, on main

- `ContinuityTests.reconcilingAClaudeThreadAddsNoSecondCopyOfItsRows` (the coordinator over `fake-claude.py`, which writes a transcript: one finished turn, then `thread.reconcile`): continuity came back `missing` with the transcript on disk. The adapter had a scope from the inspection and no projects folder.
- With `ensureAccount` reading the folder and nothing else changed: continuity `available`, and four rows where there were two ("hello there", "Hello from fake Claude.", each twice). A second reconcile kept the four.

### After

- The same test: two rows, the same row ids, after one reconcile and after a second.
- `ClaudeTurnTrackerTests.transcriptBlocksAreNamedAsTheStreamNamesThem`: a message of a thinking block, a text block and a tool call gets `msg_2#0`, `msg_2#1` and the tool's id from the stream and from a transcript of one block a line; a line with no message id keeps the `uuid` form.
- `SnapshotMergeTests.theAppsOwnMessageIsFoundUnderTheIdHistoryGivesIt`: the live user row takes the history's id and is found by it on the next merge; an assistant item with another id and the same text is inserted, not matched.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`, as CI runs it: `WorkspaceStorageTests` and `CoordinatorTests`, 516 tests in 67 suites passed; everything else, 1455 tests in 162 suites passed.
- `Scripts/docs-index.sh --check`: passes with this record and D-238.
- The app builds (`xcodebuild`) were not run here; no app or UI source changed.

### Not checked

- A live Claude Code session through the coordinator: `B4APP_LIVE_CLAUDE` was not run, so the transcript's shape is known from the fixture and from one transcript on the owner's Mac read for its shape only.
- Whether Claude Code writes the `uuid` the app sends with a message (the merge does not depend on it), and a transcript with sub-agent lines.
- The app on screen: no view changed.

### Carried from D-237

The 2026-11-15 record of D-237 lists "Show earlier" pressed in the running app as not checked. It has since passed on the hosted runner: `ReadingSmokeTests.testALongThreadShowsEarlierRowsOnRequest` in the "macOS recovery smoke tests" check of pull request 210 at commit d847db3c. It has not been run on this Mac.
