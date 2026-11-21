## 2026-11-20: The Mac connects again after the coordinator restarts (D-265)

- **Found on screen.** Local build from main (4c30a194): three threads made from the CLI (in an existing folder, in a new folder, with no folder) were listed at once, so the cause was not the CLI. After `agent-workspace coordinator restart` with the app open, the app showed "Coordinator unavailable: Coordinator connection closed." with Retry, and a thread made from the CLI then was not listed. The 2026-11-19 report of "a CLI thread not listed until it has a turn" followed a restart the same way.
- **Red.** `LinkReconnectTests`: all three tests timed out waiting for a reconnect attempt (nothing connected again).
- **Green.** `LinkReconnectTests`, `WorkspaceModelTests`, `ThreadOpenRequestTests` and `AttentionModelTests` pass (71 tests).
- **Gates.** `swift test` in CI's two processes: 530 tests in 68 suites (`WorkspaceStorageTests`, `CoordinatorTests`) and 1770 tests in 191 suites, all passed. `swift format lint --strict` and `Scripts/docs-index.sh --check` clean.
- **On screen.** A Local build of this branch: with the app open, `agent-workspace coordinator restart`, then `thread new --no-folder` from the CLI. The app read "Coordinator connected" and listed the new thread, with no Retry pressed.
- **Not checked.** The phone; how long the notice shows during a slow restart; a coordinator that stays down (the attempts every 5 s were not watched).
