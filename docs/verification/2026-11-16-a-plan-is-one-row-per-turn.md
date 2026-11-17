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

### The branch's review

A fresh reviewer read the whole branch against the design. It found no fault in the merge, the settling or the row, and two in the Claude Code path, both fixed with a test that failed first:

- Live and history disagreed on where a turn's item ends. A turn Claude Code starts itself is never begun by the app, so its list landed on the turn before it; and a compaction summary, a user line with text in the middle of a turn, made history start a second item. The reviewer counted both kinds of line in real transcripts on this Mac. The live fold now ends an item when the turn's result arrives, and history does not treat a summary as a turn (`aTurnClaudeCodeStartsItselfGetsItsOwnItem`, `aCompactionSummaryDoesNotStartANewItem`).
- A sub-agent's `TodoWrite` would have replaced the session's list. Task tools in a frame with `parent_tool_use_id` are now ignored (`aSubAgentsTaskToolsAreNotTheSessionsList`). Whether 2.1.282 sends such frames on its stream is not known.

Left as they are, by choice: a failed `TodoWrite` still replaces the list, since it is applied when the call is seen; the fold's set of seen tool use ids grows for the life of a session; a resume reads the whole transcript before the first turn; a dense running turn with only a list whose steps are all pending or all done shows nothing working.

### Gates

- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift test`, as CI runs it: `WorkspaceStorageTests` and `CoordinatorTests`, 524 tests in 68 suites passed. Everything else: 1509 tests in 166 suites passed on the final code. Before the review's fixes, the first run of that group reported one issue in 1506 tests and its name was not captured; three further runs each passed. That failure is unexplained. Other commands were running on the machine during it.
- `xcodebuild build` of `B4App-macOS` and of `B4App-iOS` for the Simulator: both succeeded.
- `Scripts/docs-index.sh --check`: passes with this record and D-243.

### Untested

- Every live runtime. Codex's shape is from the 0.166.0 schema, Claude Code's from a transcript recorded on 2.1.227 (the installed version is 2.1.282), B4's from the fake server. In particular: that Claude Code's stream carries the task tools' results as `tool_result` blocks with the text the transcript shows, that tool use ids are unique across a resumed session, and that a transcript's only user text lines in the middle of a turn are compaction summaries (the history import starts a new list item at every other one; a message queued while a turn runs has not been looked at).
- B4 history: whether `GET /state` returns the list. A B4 row is live-only until that is known.
- The running app on the Mac or the phone, VoiceOver on the row, the working mark's motion, and accessibility text sizes. The app journeys were not run.
- Old Claude Code threads: a reconcile adds the list row beside the raw tool rows an earlier build stored. Read from the code, not run.
