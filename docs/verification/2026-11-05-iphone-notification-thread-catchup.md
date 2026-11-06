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

The isolated iPhone fixture adds delayed-sync cold/warm navigation and Back-cancellation cases using the shipped workspace UI. These fixture results do not establish a physical notification-tap pass on a new build. The installed production build remains affected until a follow-up build is shipped and retested.

Complete UI results: `/tmp/b4app-notification-full-ui.xcresult`. Focused UI results: `/tmp/b4app-notification-ui.xcresult`. Current-main package log: `/tmp/b4app-notification-main-tests.log`.

Exported screenshots under `.build/verification/2026-11-05-notification-thread-catchup/` were visually inspected: the loading pane has visible Back navigation, a completed sync opens the requested thread, and Back remains on Home after the delayed row arrives. Fixture buttons exist only in the harness. Its legacy approval payload is unanswerable; these UI cases verify navigation, not approval execution.
