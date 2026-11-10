## 2026-11-09: Plan mode writes nothing, live, and the composer's deferred minors (D-183)

`main` at `29a2c88` plus this branch, on the owner's MacBook Pro. The live case spent real inference on the owner's Claude account (Claude Code 2.1.282, Haiku).

| Check | Result |
| --- | --- |
| Claude: a session in `plan`, asked to write a file, writes nothing | Pass (`ClaudeLiveTests.planModeWritesNothingLive`). The CLI asked only for `ExitPlanMode`, which the test denied, and `made.txt` was not created. This closes the question the 2026-11-04 record left open. |
| Claude: the same request in `acceptEdits` writes the file (the control) | Pass. The file was written with no approval asked, so the prompt does lead to a write and the plan run's empty folder is Plan mode's doing. 21 s for both sessions. |

**The deferred minors from the composer review, fixed here (fixture-tested):**
- The picker row's project label gave way first at a narrow width and could be cut to a sliver. It now keeps its own width up to 88 points (`keepsWidth`, `KeepsWidthTests`); the permission and the runtime truncate after that. The minimum-window measures (`DetailMinimumSizeTests`) still pass.
- "Choose folder…" compared the picker's path with the project folders exactly, so a project folder reached through a symlink started with no project. The draft now looks the folder up in the form the coordinator keys project folders by (symlinks resolved, no trailing slash; `NewThreadDraft.folderPath(of:)`).
- `WorkspaceModel.preferences` defaulted to `UserDefaults.standard`, so tests that did not replace it shared the test runner's defaults. A model now keeps its preferences in memory unless given some; the Mac and iPhone apps pass `UserDefaults.standard`.

**Automated:** `swift test` passes (1,460 tests in 181 suites); `swift format lint --strict` is clean.
