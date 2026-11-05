## 2026-11-04: The new-thread composer and per-thread runtime choice, live (D-182, D-183)

`main` at `395ed67` (PR #128 merged) plus the two live cases added here, on the owner's MacBook Pro (macOS 26.5, Xcode 26.6). The Local app ran PR #128's build (packaged with `B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1` and the Developer ID identity), signed in to the Compose hub; the Local iPhone app on the iPhone 17 Pro Simulator ran the same branch's Debug build. The live cases spent real inference on the owner's Claude and Codex accounts.

| Check | Result |
| --- | --- |
| Claude: a session launched on Haiku with a second folder attached reads a file there | Pass (`ClaudeLiveTests.runtimeChoiceAppliesLive`, Claude Code 2.1.282). `marker.txt` in the extra folder answered "periwinkle" through `--add-dir`. |
| Claude: mode and model changes reach the running process | Pass. `acceptEdits`, then `plan` with Sonnet, were accepted as `set_permission_mode` and `set_model` control requests and the turns completed. Whether Plan mode then refuses an edit was not asked. |
| Claude: Bypass restarts with `--resume` and keeps the conversation | Pass. The switch to `bypassPermissions` relaunched the process with the flag; asked what word was in the file, it answered "periwinkle". 23 s for the four turns. |
| Codex: `model/list` | Pass (`CodexLiveTests.runtimeChoiceAppliesLive`, codex-cli 0.166.0). Nine models for the owner's account. |
| Codex: "Auto" makes the second folder writable | Pass. A write to `extra/auto.txt` landed with no approval asked. The owner's own configuration is `never` with full access, so the override narrowed it. |
| Codex: "Read only" refuses the same write | Pass. `extra/blocked.txt` was not created and no approval was asked. |
| Mac: the empty pane is the new-thread composer | Pass. "New thread" selected in the sidebar, "What should we work on?", the field ("Message Codex"), and the picker row (b4app; As configured; Codex · Default). |
| Mac: the sidebar footer at a short window | Pass after the fix in PR #128. At 1200 × 695 the profile footer had gone: the headline's `fixedSize(vertical:)` measured 1,110 pt at zero width and the split view outgrew the window (D-047). Without it the footer stays, and `DetailMinimumSizeTests.newThreadComposerFitsTheMinimumWindow` covers it. |
| Mac: Send creates the thread, runs the turn, and opens it | Pass. "Reply with exactly the single word: pong", Send: "Starting…", then the thread opened titled from the message, with Codex's reply "pong" and the in-thread row (b4app locked, As configured, Codex · Default). |
| iPhone: the list's header and bottom field; the pushed screen | Pass. The avatar leads the header, filter and search trail it, the "New thread" field sits at the bottom, and tapping it pushes "New thread" with the headline, the field, and the project picker. |
| iPhone: starting a thread | Not run. The screen said "No ready connection on your Mac can start a thread in this project." The hub holds the Mac's connections under its earlier device (`01a1988c…`) and the b4app project under the current one (`01a19d4c…`), and the phone offers only connections of the project's Mac. The same stale-owner problem the phone-projects record notes (2026-11-04); a follow-up, not this change. |

**Also found**
- **An intermittent test.** The full suite's occasional "2 issues" is `HubSyncTests.joinPushesTheBacklogAndMarksItSynced` (lines 459–460: the 401 not yet on the link, no unsynced rows). It passed five times alone; a race already on `main`.
- **A stale error after leaving a broken thread.** The "testing" thread's Codex session (`01a1a47c…`, made the day before) is no longer in `~/.codex/sessions`, so the thread shows "Continuation is unavailable" as it should. Opening the new-thread pane from it left that thread's error as a notice in the sidebar until the next thread opened.
- **The Local database.** This build's coordinator applied Mac migration `0009_thread_runtime_choice` to the Local account's database; builds without it refuse that database until they include PR #128. A backup taken first: `~/Library/Application Support/b4app-local/backups/workspace-2026-11-05T01-28-41.754Z.jsonl`.

**Not exercised live:** changing a thread's model or permission from the phone (the Compose hub runs an image without hub migration `0017`, which refuses those writes); a permission change mid-thread from the Mac's picker (menus cannot be opened by the background driver; the change itself is live-tested at the adapter above and fixture-tested through `thread.update`).

**Automated:** with both adapters now reporting `modelSelection` as supported, `swift test` passes (1,401 tests in 169 suites; one earlier filtered run hit the intermittent test above, which passed on rerun); `swift format lint --strict` and `Scripts/docs-index.sh --check` are clean.
