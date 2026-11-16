## 2026-11-16: a plan is one row per turn

D-243, for the plans half of defect 10 of `docs/research/2026-11-14-agent-chat-hill-climb.md`. Branch `blove/plans-and-task-lists` from `main` ff03e7b1. It changes `WorkspaceProtocol` (a new type), the three adapters, `WorkspaceStorage` (the snapshot merge) and `WorkspaceUI`. No migration, and no hub, mirror or wire change: the item syncs as any display item does.

### Before

- Codex: `CodexEventTranslator` returned no event for `turn/plan/updated`.
- Claude Code: `TodoWrite`, `TaskCreate`, `TaskUpdate`, `TaskList` and `TaskGet` were `toolUse` rows, live and in history.
- B4: `plan_update` was a generic row of type `plan_update` holding the event's data.
- The merge put a live row the snapshot did not name after every snapshot item. Three new `SnapshotMergeTests` cases failed on that before the change.

### After

- Each runtime's list is one `taskList` item per turn, replaced in place: `aCodexPlanIsOneRowUpdatedInPlace`, `aB4PlanIsOneRow`, `aClaudeTodoListIsOneRowAndAReconcileAddsNone` and `aClaudeTaskListIsOneRowPerTurnAndSurvivesARestartAndAReconcile` (`TaskListSessionTests`, through the coordinator with the fake runtimes).
- A reconcile of a Claude Code thread whose turns wrote lists returns the same item ids and the same lists.
- A Claude Code session whose process was started again (a folder added to its environment) applies a `TaskUpdate` to a task the earlier process made. The test fails with the transcript seeding switched off; that was checked by switching it off.
- A live row history does not name stays after the row of its turn that stood before it; with none, it goes last as before (`SnapshotMergeTests`, four cases, and the earlier cases unchanged).
- The row: "Plan · 2 of 4", the explanation, a mark and the text for each step. A step in progress when its turn ended is unfinished at both densities, and unknown while the turn is reconciling. Dense draws the row while the turn runs and folds it afterwards. An emptied list draws nothing (`TaskListRowTests`, twelve cases; one `TranscriptCorpusTests` ledger).
- Captures, 720 by 560 pt at 2x from `ListSnapshotTests.denseThreads`, each read after it was written: `docs/screenshots/transcript-plan-normal.png` (a running turn, light), `transcript-plan-dense-running.png` (dense, the list drawn under the steps line while the turn runs, light), `transcript-plan-stopped.png` (the turn stopped, the open step a dash, dark).

### Found on the way

- The fake Claude Code counted tool use ids from one in every process, so after a restart the second turn's list landed on the first turn's row. The fixture now makes its task tool ids unique across launches, as real ids are taken to be.
- The plan for this work would have kept an unmatched live row first when nothing stood before it. That would put a turn history has not caught up with ahead of older history a merge brings, so the row is anchored only to a row of its own turn.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`, as CI runs it: `WorkspaceStorageTests` and `CoordinatorTests`, 524 tests in 68 suites passed. Everything else: the first run reported one issue in 1506 tests and its name was not captured; three further runs each passed 1506 tests in 166 suites. The failure is unexplained. Other commands were running on the machine during the first run.
- `xcodebuild build` of `B4App-macOS` and of `B4App-iOS` for the Simulator: both succeeded.
- `Scripts/docs-index.sh --check`: passes with this record and D-243.

### Untested

- Every live runtime. Codex's shape is from the 0.166.0 schema, Claude Code's from a transcript recorded on 2.1.227 (the installed version is 2.1.282), B4's from the fake server. In particular: that Claude Code's stream carries the task tools' results as `tool_result` blocks with the text the transcript shows, that tool use ids are unique across a resumed session, and that a transcript has no user text line in the middle of a turn (the history import starts a new list item at each).
- B4 history: whether `GET /state` returns the list. A B4 row is live-only until that is known.
- The running app on the Mac or the phone, VoiceOver on the row, the working mark's motion, and accessibility text sizes. The app journeys were not run.
- Old Claude Code threads: a reconcile adds the list row beside the raw tool rows an earlier build stored. Read from the code, not run.
