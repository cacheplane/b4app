## 2026-11-19: An answered turn is running again (D-257)

- **Found on screen.** Local build from main (99bf5ec5), test thread on Claude Code with permission Ask: after "Allow once" the header and composer row said "Waiting for you" for several seconds.
- **Live probe.** Claude Code 2.1.282 run directly with `CLAUDE_CODE_SDK_READS_SESSION_STATE=1` and `--permission-prompt-tool=stdio`, one Bash call of `sleep 6 && touch probe.txt`, answered after 3 s: `control_response` at 5.37 s, then `system task_started` at 9.51 s, `task_notification` at 12.55 s and the tool result at 12.57 s. No `session_state_changed` frame in the run. Real inference, one turn.
- **Red.** `anAnsweredTurnIsRunningBeforeTheRuntimeSaysSo` against the old `requestRespond`: the turn read back `waiting_for_user` after the answer, and no `turn.state_changed` with `source: "answer"` arrived.
- **Green.** The same test passes with the change.
- **Gates.** `swift test` in CI's two processes: 529 tests in 68 suites (`WorkspaceStorageTests`, `CoordinatorTests`) passed; of 1738 tests in 187 suites, one failed, `DenseTranscriptViewTests.openingATurnLeavesItsLineWhereItWas`, timed out waiting while another checkout's build was running on the machine. That suite, which this change does not touch, then passed three runs in a row (33 tests each). `swift format lint --strict` and `Scripts/docs-index.sh --check` clean.
- **Not checked.** The fix on screen in a rebuilt app; Codex and B4 live (their fixture tests pass); the phone, which learns of the turn through the same event and the synced turn row.
