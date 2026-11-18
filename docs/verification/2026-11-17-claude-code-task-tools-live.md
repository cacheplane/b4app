## 2026-11-17: Claude Code task lists, live

The first live check of D-243 and D-246 on Claude Code, and D-247's two fixes. The live part ran through the installed Local build (`main` 167bd71d, Developer ID signed, not notarized) and its CLI, on Claude Code 2.1.282 with the owner's plan sign-in. Real inference, at the owner's request. Branch `blove/claude-task-tools-and-seeding` from `main` 167bd71d.

### Live, before the fixes

- **A thread with no folder.** Asked to keep a three-task list, the model answered that the session had no task list tool. No `taskList` item.
- **What the CLI offers.** `claude -p --output-format stream-json --verbose` in a clean environment listed 33 tools in `system/init`, with `Task` and `TaskStop` and no task list tool. With `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` it listed 37, adding `TaskCreate`, `TaskGet`, `TaskList` and `TaskUpdate`. `CLAUDE_CODE_ENABLE_TASKS=1` changed nothing. `TodoWrite` was offered in neither.
- **A thread in a folder whose `.claude/settings.json` sets the variable.** One turn made Alpha, Beta and Gamma and moved two of them: one `taskList` item, `tasks:<the first TaskCreate's tool use id>`, holding Alpha completed, Beta in progress, Gamma pending. `thread show --reconcile` left one item with the same id. A second turn (two updates and a new task, Delta) wrote a second item holding all four; a reconcile left two.
- **The shapes.** `TaskCreate` input `{ subject, description }`, result `Task #1 created successfully: Alpha`; `TaskUpdate` input `{ taskId, status }`, result `Updated task #1 status`; numbers counted up across turns. As D-243 read them from the 2.1.227 transcript. The tools arrived deferred: the first turn ran `ToolSearch` for them, drawn as a tool row.
- **After `coordinator restart`.** A turn that updated two earlier tasks ended `completed` and wrote no `taskList` item. A reconcile then added the right list as an item with no turn.
- **The cause, checked.** After another restart, a reconcile first (which reads history, and so learns the projects folder) and then a turn: the turn wrote its item live, with the right list.

### The fixes

Each failed before the change and passes after:

- `ClaudeStreamTests.childEnvironmentAsksForTheTaskTools`: the child environment had no `CLAUDE_CODE_ENABLE_TODO_TOOLS`.
- `ClaudeSeededTasksTests.anAdapterThatHasReadNoHistoryStillSeedsAResumedSession`: a second adapter on the fake's session, with no history read, sent a `TaskUpdate` turn and emitted no list.

### Checks

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test --filter '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 524 passed.
- `swift test --skip '^(WorkspaceStorageTests|CoordinatorTests)\.'`: 1516 passed.
- `Scripts/docs-index.sh --check`: passes.

### Untested

- The fixes in the running app: the installed build predates them. The variable's effect was observed on the CLI, not through a build that sets it.
- `TodoWrite` live: 2.1.282 does not offer it.
- A failed task tool, a stopped turn, and a transcript long enough for the seed read to matter.
- The row in the app's window at either density, and VoiceOver.
- Codex and B4 plans live.
- The two `xcodebuild` app builds were not run for this change.
