## 2026-11-05: Notification opens before a new thread reaches the iPhone mirror

### Physical report and reproduction

On production TestFlight 0.1.0 (2611052247), the owner received an approval notification for “Phone push A — approval test”. Tapping it reported that the thread did not exist, while opening the same thread from the list worked and showed its pending approval. Delivery is owner-confirmed; notification navigation failed. The production Mac's thread was not deleted, its turn was waiting for the user, and its approval remained pending.

The disposable folder has folder-local Claude Code permission rules and a real command approval for `curl -sI --max-time 15 https://example.com`. The production Mac coordinator was connected to `https://hub.b4.run` with no unsynced changes. No approval was answered by the test driver.

The model regression reproduces the timing with a real in-memory mirror and transport: connect with the connection row but no thread row, request a notification open, then apply the thread/approval changes. Before the fix, both a warm open and a cold launch reported `not_found`, discarded the open, and left the subsequently synced thread only in the list. The focused red run had six issues across these two cases (`/tmp/b4app-notification-red.log`).

### Correction and scope

Retain a notification or widget open while a phone mirror lookup is missing, retrying the local read for at most 15 seconds after the open starts. The detail pane shows “Loading thread…” and opens automatically when the row arrives. The event stream remains free to apply incoming changes. A timeout returns to the list with an availability/connection message rather than treating a stale cache as proof of deletion.

Back, opening another thread or draft, deletion, sign-out and disconnect cancel the running open. A pending ID survives a disconnected link so reconnect can resume it. Cancelled or superseded reads cannot publish into a different selection. Ordinary reads and Mac missing-thread errors retain their existing behavior.

Independent review identified a second path: with an old detail still loaded, snapshot refresh or reconciliation could perform an ordinary missing read for the new pending ID. A separate regression covers that case before correcting the shared read behavior.

### Validation

The additional snapshot regression failed with a raw `not_found` and lost selection before the shared missing-read policy was corrected (`/tmp/b4app-notification-snapshot-red.log`). Independent re-review found no remaining actionable issues.

| Check | Result |
| --- | --- |
| Current-main `swift build` | Pass, based on `1e997d8` |
| Complete current-main `swift test` | Pass: 1,411 tests in 170 suites, 78.320 seconds |
| Notification-open suite | All 13 tests pass in the complete run, including warm/cold cases, timeout, Back, a new draft, a newer request and snapshot refresh |
| Shipping iOS Simulator and macOS app builds | Pass |
| Focused Simulator notification tests | Pass: 2 tests, zero failures/skips, 48.359 seconds |
| Complete iPhone UI matrix | Pass: 25 tests, zero failures/skips, 588.511 seconds |
| Strict format, documentation structure and diff checks | Pass |

The isolated iPhone fixture adds delayed-sync cold/warm navigation and Back-cancellation cases using the shipped workspace UI. These automated checks are separate from the physical iPhone retest below.

Complete UI results: `/tmp/b4app-notification-full-ui.xcresult`. Focused UI results: `/tmp/b4app-notification-ui.xcresult`. Current-main package log: `/tmp/b4app-notification-main-tests.log`.

Exported screenshots under `.build/verification/2026-11-05-notification-thread-catchup/` were visually inspected: the loading pane has visible Back navigation, a completed sync opens the requested thread, and Back remains on Home after the delayed row arrives. Fixture buttons exist only in the harness. Its legacy approval payload is unanswerable; these UI cases verify navigation, not approval execution.

### Production TestFlight and physical iPhone pass

PR #139 merged at `00fe9caf18faff8434b9d98b776f76aeea96b0b3` with all four CI checks green. Production TestFlight 0.1.0 (2611060126) was built from that clean merge commit, validated and uploaded successfully, then confirmed `VALID` and `IN_BETA_TESTING`.

The owner installed the new build, opened the app once and locked the iPhone. A fresh production thread, “Phone push B — notification tap retest”, requested approval for `curl -sI --max-time 15 https://example.com`. The Mac reported a pending, answerable tool permission and no unsynced changes before the owner tapped the notification.

The owner reported: “It worked. The notification opened the correct thread, and Allow once completed the command.” A subsequent read from the production Mac confirmed the turn was terminal with outcome `completed` and no requests remained. Record delivery, tapping the fresh notification, opening the correct thread and answering from the iPhone as owner-reported `live-tested` on 2611060126.

This closes the missing-thread notification-tap regression.

### Approval withdrawal while the iPhone remains locked

A second fresh thread, “Phone push C — locked-phone withdrawal”, requested approval for `curl -sI --max-time 15 https://example.org`. The owner confirmed receiving its notification while the iPhone stayed locked and did not tap it. The test driver answered that specific pending request with Allow once through the production Mac CLI. The request resolved, the turn completed, and the Mac reported no unsynced changes.

The owner then confirmed: “yes, it disappeared”. Record automatic removal of the approval notification while the phone remained locked as owner-reported `live-tested` on production TestFlight 2611060126. No precise removal timing was reported.

### Unread reply notification, navigation and badge

“Phone push D — unread reply test” completed and was unread when checked. Its “Replied” notification arrived, but unlocking returned the owner to B4, the last foreground app, and cleared the notification before the intended tap and badge comparison. That attempt was inconclusive for those checks and was repeated from the Home Screen.

After the owner confirmed the iPhone was locked from the Home Screen, a fresh thread, “Phone push E — unread reply retry”, completed with `Phone reply test E complete.` and no tools or approval request. The production Mac reported its latest turn completed with no read turn before the owner's check.

The owner reported: “It worked. The notification opened the correct thread, and the badge count decreased by one (from 4 to 3) after I read the reply.” The production Mac subsequently reported the thread's read-turn ID matched that completed turn, confirming the phone's read synced back. Record unread-reply notification delivery, correct-thread navigation and the badge decrement from 4 to 3 as owner-reported `live-tested` on production TestFlight 2611060126.

### Reading a reply on the Mac: locked-phone withdrawal not observed

The owner locked the iPhone from the Home Screen, received the “Replied” notification for a fresh thread, “Phone push F — read reply on Mac”, and confirmed it was left untouched. The reply was complete and unread before the Mac opened it. The production Mac app then displayed the reply in a foreground window; its sidebar changed to Read, the read-turn ID matched the latest completed turn, and the Mac reported no unsynced changes.

The owner reported that the notification did not disappear while the iPhone stayed locked. Record this locked-phone reply-withdrawal check as failed on production TestFlight 2611060126; do not infer a pass from the server's read state.

Production CloudWatch logs show Apple accepted the alert at 20:19:35 PST and the matching withdrawal at 20:21:23 PST on 2026-11-05, both with status 200 for the same iPhone and `turn:74bed4dd-d3ae-4dad-9e7b-dcb39528bfbb`. Exported token-free records are under `.build/verification/2026-11-05-notification-thread-catchup/mac-read-withdrawal-apns.json`. This proves hub submission and Apple acceptance, not delivery to the device or execution of its background handler.

[Apple documents background updates as subject to throttling](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app), particularly when sent more than a few times per hour. Delayed background delivery is a possible explanation after these repeated tests; the device-side cause is not confirmed.

The owner then opened B4 from its app icon, stayed on the Threads list and did not open F. The owner confirmed F's notification disappeared. Record foreground reconciliation as owner-reported `live-tested` on 2611060126. The stale notification was removed without the owner reading F on the phone. This narrows the unresolved behavior to background delivery/execution; it does not prove which device-side step was delayed or skipped. The failed locked-phone case remains recorded separately, and immediate background removal must not be represented as guaranteed.

### Widget refresh and tap navigation

A fresh real approval in “Phone push G — widget test” was pending and fully synced to production. With the widget visible and B4 closed, the owner saw the older A, B and D test threads instead of G. At the owner's request, completed tests A–F were archived, preserving their history and leaving G as the only unarchived thread from this test series. None of those old tests was pinned. The Mac confirmed all archive changes synced and G still had one pending approval.

After 30 seconds on the Home Screen without opening B4, the widget still showed A, B and D. Record automatic background widget refresh as not observed in this run. The widget reads the phone's mirror and the app requests a timeline reload after relevant synced batches; these observations alone do not establish whether the phone's background sync or WidgetKit's timeline refresh was delayed.

The owner then opened B4 from its icon, checked the Threads list without opening G, and returned Home. The owner confirmed G appeared in both the app and widget. Tapping G directly in the widget opened the correct thread with its pending approval; the owner left it unanswered. Record widget refresh after the app came to the foreground and widget tap navigation as owner-reported `live-tested` on production TestFlight 2611060126.

For the state-update check, the owner returned to the Home Screen with the widget visible and B4 closed. The test driver answered G's exact pending request on the Mac with Allow once. The command completed, no pending requests remained, the latest reply was unread and all changes synced to production. The owner reported G's approval dot remained blue after more than 30 seconds without opening B4. Record this background post-resolution widget update as failed in this run. The foreground follow-up was not completed before the owner reported that Low Power Mode was enabled. Restoring G when the app opens may mark the reply read, so either a normal unread dot or a hollow read ring would correctly replace the stale approval indicator.

### Later-reported power condition and controlled retest

The owner subsequently reported that the iPhone was in Low Power Mode. [Apple states that Low Power Mode turns off Background App Refresh](https://support.apple.com/en-gb/101604). This is a plausible contributor to the delayed background notification and widget behavior; it does not establish the cause or prove when the mode was enabled during each earlier test. Preserve the observations above with this later-reported test condition.

For the controlled retest, the owner confirmed Low Power Mode was off and the Home Screen widget was visible. A fresh “Phone push H — widget normal-power retest” requested the same real Bash approval. The Mac verified pending request `b703d8b2-6333-4348-a571-d237ad730dae` and no unsynced changes. The owner reported receiving its notification and seeing app-icon badge 1, but the widget never updated. Record background widget appearance as failed in this run with Low Power Mode off. Notification and badge delivery do not prove that the app executed its background handler, synced its mirror, or that WidgetKit reloaded its timeline. Low Power Mode alone does not explain the reproduced stale widget.

For the foreground follow-up, the owner opened B4 from its icon, stayed on the Threads list without opening H and returned Home. The owner confirmed H appeared with its blue approval dot. Record foreground widget refresh as owner-reported `live-tested` with Low Power Mode off; background appearance still failed in the preceding check.

With the owner back on the Home Screen, the test driver verified H's exact pending request, thread, turn and Bash command, then answered Allow once through the production Mac CLI. The command completed with no pending requests, its reply remained unread and no unsynced changes remained. The owner confirmed the blue approval dot changed in response to the check with B4 remaining in the background. Record background post-resolution widget state update as owner-reported `live-tested` with Low Power Mode off on production TestFlight 2611060126; no precise transition timing was reported. This pass does not override the preceding failure to show newly created H before opening B4. The normal-power locked-phone reply withdrawal retest is recorded below.

### Normal-power Mac-read withdrawal retest

On 2026-11-06, with Low Power Mode off and the iPhone locked from the Home Screen, a fresh “Phone push I — read on Mac, normal power” completed with `Phone reply test I complete.` and no tools. Before the phone check, the Mac verified the reply was unread and no unsynced changes remained. The owner confirmed its “Replied” notification arrived, the iPhone was still locked and the notification was untouched.

At the owner's request, the test driver activated the production Mac app window and opened I. The app displayed the exact completed reply and its sidebar changed to Read. The production CLI then verified `readTurnId` matched completed turn `e3738671-cfbf-4d54-a5a3-6f93dc8ecc3d` and no unsynced changes remained. The owner confirmed: “It disappeared while still locked”. Record reply-notification withdrawal after reading on the Mac as owner-reported `live-tested` on production TestFlight 2611060126 with Low Power Mode off. This was reported in response to the 30-second check; exact removal timing was not reported. The earlier F failure remains a separate observation, and the new pass does not establish that Low Power Mode caused it.
