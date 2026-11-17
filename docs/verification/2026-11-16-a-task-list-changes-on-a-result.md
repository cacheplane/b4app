## 2026-11-16: a task list changes on a result

D-245, the four minors D-243's review left. Branch `blove/task-list-minors` from `main` da8b4cf4. It changes `ClaudeAdapter` (the fold, the tracker, the resume) and `WorkspaceUI` (the dense projection). No migration and no wire change.

### Before

Each of these failed against main before the change:

- `ClaudeTaskFoldTests.aTodoWriteIsTheListOnceItsResultArrives`, `aFailedTodoWriteKeepsTheList` and `ClaudeTaskListTrackerTests.aFailedTodoWriteEmitsNothing`: a `TodoWrite` replaced the list at its tool use, so a failed one had already replaced it and emitted a row.
- `ClaudeTaskFoldTests.aResultEndsTheFoldsHoldOnItsToolUse` and `listingTasksChangesNothing`: the fold still owned a tool use after its result.
- `TaskListRowTests.aRunningTurnWhoseListHasNoStepInProgressSaysItIsWorking`: a dense running turn whose list was all pending or all done drew the list and nothing that said working.

### After

- The tests above pass. Existing `TodoWrite` tests now send the result as Claude Code does; the fake Claude already did.
- `ClaudeSeededTasksTests.aSessionsTranscriptGivesItsList` covers the read a resume now does off the actor (a transcript gives its list; no transcript and no projects directory give nothing). It was written with the change and never failed: the change moves where the read runs, and no test observes which executor ran it.
- The refusal the tracker forgets for a task tool use has no test: nothing observable depends on it.

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 524 passed.
- `swift test --skip '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 1514 passed.
- `Scripts/docs-index.sh --check`: passes.

### Untested

- No live Claude Code session: that a `TodoWrite` result always follows its use in the stream and the transcript is read from the 2.1.227 transcript and the fake, not observed here.
- The running app at dense with a plan whose steps are all pending.
- The two `xcodebuild` app builds were not run for this change.
