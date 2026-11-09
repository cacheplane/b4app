## 2026-11-09: Starting a thread and changing its runtime from the phone, live (D-183, D-184)

The two checks the 2026-11-04 record left not run. The Compose hub was rebuilt from `main` at `29a2c88` (hub migration `0017_thread_runtime_choice` applied; database backed up first with `pg_dumpall`). The Local Mac app was packaged from `main` plus #135 (D-184) and #149 (`B4APP_FLAVOR=local B4APP_SKIP_NOTARIZE=1`, Developer ID identity), with its LaunchAgent reloaded onto the new coordinator. The Local iPhone app was a Debug build of the same tree on the iPhone 17 Pro Simulator (iOS 26.4). The turns spent real inference on the owner's Codex account (codex-cli 0.166.0).

| Check | Result |
| --- | --- |
| The hub moves the Mac's rows to its current device (D-184) | Pass. Every connection, project, and thread of the account is owned by `01a19d4c` (the Mac's device since 2026-11-04); the earlier device `01a1988c` owns nothing. The phone's mirror shows the same owners. |
| iPhone: the "New thread" field opens a start in the Mac's project | Pass after a relaunch (see below). The pushed screen offered b4app, As configured, and Codex · Default with no reason under the field. |
| iPhone: Send starts the thread on the Mac and opens it | Pass. "Reply with exactly the single word: phone": the hub relayed `thread.start` (3,981 ms), the thread opened titled from the message ("Codex · b4app · on Brian's MacBook Pro (2)"), and Codex answered "phone". |
| iPhone: a thread's permission, changed from the phone, reaches the hub | Pass. Read only from the in-thread menu (Codex's own words: Full access, Auto, Read only, As configured) wrote `permission = read-only`; the hub's `0017` accepts the phone's write. |
| iPhone: a thread's model, changed from the phone, reaches the hub | Pass. The menu listed the nine models the Mac read with `model/list`; GPT-6-Luna wrote `model = gpt-6-luna`. |
| The Mac runs the next turn with the phone's choices | Pass. Codex's session log: the first turn ran on the owner's defaults (`gpt-6-astra`, approval `never`, `danger-full-access`); the second, sent from the phone, ran on `gpt-6-luna`, `on-request`, `read-only`. Asked to write `/tmp/b4-phone-readonly-check.txt`, Codex asked to run the command instead (the request reached the phone); denied from the phone, the turn completed and the file was never written. |

**Found and fixed in the same pull request**
- **The phone kept a connection's old owner until relaunched.** On first launch the list showed "Add a ready connection on your Mac first" although the mirror held three ready connections owned by the project's Mac. `MirrorTransport.publish` emitted `connection.changed` with only the status and sign-in, and the model replaces a connection only from the whole row in `payload["connection"]` (which the coordinator's events carry). So the re-announced owner (D-184), like a rename or a new model list, stayed in the mirror and never reached the screen. The mirror now carries the row (`MirrorTransportTests.aConnectionChangeCarriesTheWholeRow`, red without the fix). A relaunch, which reads the mirror whole, was the workaround here.
- **"A turn is waiting_for_user."** The line above the phone's composer printed the status's raw value while the approval was pending. It now uses the thread header's words ("The turn is waiting for you. Your draft stays here until it finishes."; `ComposerTurnNoteTests`).

**Also seen, not changed:** a tool card's badge shows the runtime's own item status as sent (Codex's `inProgress`), on the Mac too.

**Not exercised live:** a Claude thread's model or permission changed from the phone (the Codex path above and the Claude adapter's live test of the same overrides, 2026-11-04, cover the two halves).
