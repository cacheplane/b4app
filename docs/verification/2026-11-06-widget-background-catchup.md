## 2026-11-06: Widget background catch-up

### Physical trigger and scope

On production TestFlight 2611060126, fresh approval H's notification and badge arrived with Low Power Mode off and the widget visible, but H appeared in the widget only after opening B4 from its app icon. H's subsequent background approval-dot update passed. Fresh reply I's notification also disappeared while the iPhone stayed locked after reading it on the Mac. These observations are distinct; the original device-side cause of H's initial stale widget remains unconfirmed. Full owner reports are in `2026-11-05-iphone-notification-thread-catchup.md`.

### Reproduced defect

The shipped background refresh waits for the next `AppliedBatch`, then reloads the widget and suspends sync. A first partial page or snapshot can release that waiter while the new thread is on a later page. The hub already reports `more`; no wire change is needed.

A test-first extraction of that existing first-batch completion into the sync's refresh boundary produced an executable regression: the file-backed mirror parked at cursor 1 rather than 13, and the real `MirrorGlance.load(path:)` reader returned no thread instead of the new needs-input row. The test hub splits after one row despite a 1000-row request, modeling a byte-limited partial page. An empty feed also timed out because there was no batch. Two tests failed with five assertions; `/tmp/b4-widget-red.log` holds the local proof. This is a controlled fixture reproduction, not a capture of the owner's phone executing its background handler.

Naive sharing of one host task was separately tested and failed late-wake regressions: a wake arriving during cleanup inherited an older pull's result, and an expired overall budget incorrectly reported success. `/tmp/b4-widget-coordinator-red.log` records two tests with four failed assertions.

### Correction

- `MirrorSync.refresh(waitingAtMost:)` registers a generation before nudging. Only a cycle begun after that request, after applying and publishing a final `more=false` page, completes it. Pending refreshes and remaining pages bypass long polling. Snapshot publication alone does not complete a refresh.
- Stop, cancellation, authorization failure and timeout release refresh waiters exactly once. The account retains ownership of resuming and suspending its loop.
- `MirrorRefreshCoordinator` shares host work while tracking every wake, including arrivals during notification reconciliation or parking. A late arrival repeats the whole cycle within one overall eleven-second budget; it cannot claim catch-up from an older read. The active task is cleared atomically with its final generation check.
- The host retains its ordered resume and park, final widget reload and notification reconciliation. Safe diagnostics record background refresh conditions/outcome and widget timeline row counts, not notification payloads, titles or secrets.

This closes a reproduced premature-completion path. iOS still controls background execution and WidgetKit scheduling; a fixture pass cannot guarantee an immediate device refresh.

### Validation and release

Design and concurrency review approved the generation-aware approach after identifying and correcting the late-joiner gap. Independent code review and a follow-up review of the clock/test changes found no important actionable issues.

| Check | Result |
| --- | --- |
| First-batch red reproduction | 2 tests failed with 5 assertions before the fix |
| Naive host coalescing red reproduction | 2 tests failed with 4 assertions before the generation guard |
| Final focused sync, coordinator and notification navigation suites | 46 tests passed |
| Full Swift package suite | 1,421 tests in 172 suites passed, 128.624 seconds |
| Final `swift build` | Passed |
| Strict recursive Swift format lint | Passed |
| Final macOS app build | Passed (arm64) |
| Final iOS app/widget Simulator build | Passed with normal local signing (also compiled with signing disabled while investigating the earlier tooling stall) |
| Documentation and whitespace checks | Passed; rerun after the final record update before commit |

The earlier full-suite runs exposed test synchronization problems: short real-time budgets expired while unrelated SwiftUI rendering occupied the executor, and the existing notification timeout test could advance its fake clock before the retry sleeper registered. The coordinator tests now freeze/advance an injected monotonic clock, sync tests assert nonpolling and catch-up state with a generous hang guard, and the navigation test waits for its retry sleeper. Production deadlines are unchanged. The final full-suite result above includes these corrections.

Two local iOS build attempts stalled in Xcode's build-description/tooling phase and were cancelled. A Simulator compile with signing disabled then passed, followed by the normal signed Simulator build. These are compile/sign checks, not an on-device background-widget integration. CI native builds must also pass before merge. No production hub deployment is required.

The production TestFlight archive will be built from the clean merged commit after green CI. Build/Apple readiness evidence is kept under `.build/verification/2026-11-06-widget-background-catchup/`; the owner still needs to retest a fresh thread with the widget visible and B4 in the background. Fixture catch-up results do not replace that device gate.

### Merged production TestFlight release

PR #143 merged as `785983b67eca4906153d56f1629cf11f008964ee` after all four CI jobs passed. The fresh native attempt passed all 25 UI tests with no failures, skips or expected failures. The first native attempt passed 24 cases and reached the final assertions of the remaining case before XCTest failed its explicit fixture-app termination during cleanup. Its activity tree and result bundle were preserved; independent review confirmed the changed background runtime paths were not exercised by that fixture. The isolated local rerun of that case passed, and only its disposable Simulator was removed and verified absent.

Production TestFlight **0.1.0 (2611061754)** was uploaded from the clean merged checkout, whose tree exactly matched the fully tested PR tree. The exported app and widget both report build 2611061754 and flavour `prod`, built against iPhoneOS26.5. Exported entitlement checks and Apple app validation passed. Apple subsequently reported `VALID` and `IN_BETA_TESTING`, confirming internal TestFlight availability.

The first archive attempt stalled in a local Xcode compiler-information query while Clang was blocked writing output, before any upload. A temporary process-local `XCODE_XCCONFIG_FILE` selected an I/O adapter only for that exact installed-SDK metadata query. It preserved both output streams byte for byte and delegated ordinary compilation to the original Apple compiler with unchanged arguments; C and C++ smoke objects matched byte for byte. Independent review approved the adapter, and the production archive then completed. The source and signing configuration were unchanged. Adapter, output checks, source-tree comparison, CI results and Apple readiness evidence are retained under `.build/verification/2026-11-06-widget-background-catchup/`.

The owner also confirmed Background App Refresh is currently enabled globally and for B4 with Low Power Mode off. This records the current setting, not its timing during the original H failure. The updated-build device result is recorded below.

### Updated-iPhone retest: fresh J still absent in the background

The owner installed production TestFlight 2611061754, opened B4 to the Threads list, returned Home with the widget visible and Low Power Mode off, and requested a fresh approval. Background App Refresh had been confirmed enabled globally and for B4. “Phone push J — new-thread widget refresh retest” requested the real Bash permission for `curl -sI --max-time 15 https://example.org`. The Mac verified pending request `f0448d89-b4f2-49aa-9e1d-10a6b0a095e6` and no unsynced changes; the request was left unanswered.

The owner reported J never appeared in the widget, while its notification arrived and the app badge increased to 2. Record fresh-thread background widget appearance as failed on 2611061754. PR #143 closes the fixture-proven first-page completion defect but did not resolve this observed device failure. Notification and badge delivery alone do not prove the app's background handler, mirror catch-up or widget timeline ran. Device-side diagnostic evidence is required before proposing another correction. J remains pending.

The owner then opened B4 from its app icon, stayed on the Threads list without opening J, and returned Home. J appeared in the widget with a blue dot. This confirms foreground mirror publication and widget display work for this thread; it does not establish whether the earlier background wake or catch-up ran. J remains unanswered.

The first device-log collection attempts did not provide usable evidence: the scoped command-line collector required local administrator authentication, and Console streaming with the B4 subsystem filter showed no messages even during the known-good foreground refresh. An empty, uncalibrated capture cannot establish that the background handler did not run. Device connectivity and live capture must be verified before the next controlled background test.

### USB diagnostic: fresh K background wake and timeline observed

After the owner connected the phone by USB, CoreDevice reported a paired, wired, booted phone and an active connection. The owner opened B4 to the Threads list, returned Home, and left J unanswered. That unchanged foreground visit emitted no matching Console messages. A fresh K approval was then triggered while the owner stayed Home. J correctly held the original test directory lock, so the empty first K attempt was archived and K was started in its own disposable directory; J was left untouched.

For “Phone push K — USB background diagnostic”, the production CLI verified pending tool-permission request `85218db3-b510-47a7-9cc6-cdca3f2840a3` in thread `8d3afc33-f1db-48a5-a700-e003b84f766c`, with no unsynced changes. B4-filtered Console captured a background refresh at 10:40:41.414434 PST with Low Power Mode false and Background App Refresh status 2 (`available`, verified against the installed UIKit header). The app logged badge 3 at 10:40:42.625014 and successful mirror catch-up at 10:40:43.200704. The widget extension logged a linked, non-stale timeline with three rows at 10:40:56.052437, approximately 14.64 seconds after the background wake, and another at 10:40:56.134622. Console displays near-identical paired rows for these events; they are not counted as separate wakes. This calibrates the app and widget log capture and proves those stages ran for K, but not retroactively for J. The owner confirmed K appeared with a blue dot without opening B4 or tapping its notification. Record this USB-connected background appearance test as passed; both approvals remain unanswered. J failed untethered on the same build, so K does not establish that the original failure is resolved. A controlled untethered repeat is next; USB/charging is a changed condition, not a proven cause.

### Untethered diagnostic: fresh L passed

After instructions to unplug USB, keep Low Power Mode off, and stay Home with the widget visible and B4 in the background, the owner confirmed “Go”. “Phone push L — untethered widget diagnostic” was created in a separate disposable directory at 11:21:16 PST. The production CLI verified pending tool-permission request `61f97096-7e96-47ac-9a81-c680e4072aa7` in thread `793360e4-fdfa-4a3b-bf5a-b2861c6d1977`, with no unsynced changes. J and K were left unanswered. The owner observed L without opening B4 or tapping its notification and confirmed it appeared with a blue dot. Record fresh-thread background widget appearance as passed for this untethered trial. No usable device-side log capture is recorded for L. J, K and L remain unanswered. K passed over USB and L passed untethered on the same production build, so USB is not established as a necessary condition. J’s earlier untethered failure remains unexplained; these subsequent passes do not establish reliable background delivery or resolve that failure.

### Locked-idle diagnostic: fresh M passed

The owner explicitly confirmed the iPhone was unplugged, locked from the Home Screen, and had Low Power Mode off, and asked for a five-minute wait before M. The idle period was recorded at 12:55:01 PST; no thread or hub change was created during the wait. After more than five minutes, “Phone push M — locked idle widget diagnostic” was created at 13:00:23 PST in a separate disposable directory. The production CLI verified pending tool-permission request `1a57d7f5-5f1f-41f5-a8fb-9b49bf0d32f7` in thread `6ed74bc5-bfdf-485a-9eeb-8f1b6994c69f`, with no unsynced changes. J/K/L were untouched. The owner was asked to leave M’s notification untapped, unlock to Home without opening B4, and observe the widget for up to 30 seconds, leaving all approvals unanswered. The owner reported “Notification arrived; M has a blue dot”. Record this untethered, locked-idle background appearance trial as passed. No device-side log capture is claimed for M. K, L and M are three subsequent fresh-thread appearance passes on build 2611061754, respectively USB-connected, untethered on Home, and untethered after more than five minutes locked idle. These are successful physical retests, while J’s earlier failure remains unexplained; reliable background execution is not established by this small sample. All four J/K/L/M approvals remain unanswered.

### M resolved on the Mac: withdrawal and widget update passed

The owner asked to resolve M on the Mac to check notification removal and the widget update. Before responding, the production CLI verified M’s exact thread, turn and pending request identity, its answerable Bash permission, and the command `curl -sI --max-time 15 https://example.org`. M was allowed once; J/K/L were untouched. The CLI then verified the request was absent from the pending-request view, the turn was terminal with outcome `completed`, and there were no unsynced changes. The reply was not opened on either device.

The owner was asked to check M’s original approval notification separately from any new “Replied” notification, and check that M no longer has a blue approval dot, without opening B4 or tapping a notification. The widget has three rows and J/K/L still need approval, so M dropping below those rows is an expected update. The owner confirmed M’s original approval notification disappeared without opening B4 or tapping it. Record background approval-notification withdrawal as passed for M. The owner then confirmed J/K/L occupy all three widget rows and M is no longer displayed, without opening B4. This is the expected attention-order update after M’s approval resolves: the three remaining pending approvals outrank M’s completed reply. Record M’s background widget update as passed as well. J/K/L remain unanswered; M’s reply remains unread.

### Phone push test cleanup: J/K/L resolved and all tests archived

At the owner’s request, J/K/L’s thread, turn and pending-request identities were rechecked, along with their answerable Bash permission and exact command `curl -sI --max-time 15 https://example.org`. Each was allowed once. All three turns then reached terminal outcome `completed`, with no pending requests.

The seven remaining active Phone push tests G–M were verified terminal with no pending requests and archived. A–F and the empty superseded K attempt were already archived. A fresh inventory confirmed zero active Phone push test threads and 14 archived Phone push test threads, including the empty K attempt; all seven newly archived IDs were present in the archive listing. Hub status showed zero unsynced changes. Unrelated threads were not changed. This is an archive, preserving test history. The owner checked without opening B4 and reported the Phone push tests are still visible. Record archive removal from the background widget as failed, despite verified Mac archive state and zero unsynced changes.

Source investigation found a distinct archive wake gap: `Hub/crates/b4hub-db/src/push.rs` decides alerts only from touched turns/requests, and withdraws ledger rows for resolved requests, read turns or deleted threads. An archive-only thread update does none of these, so it creates no APNs message through `routes/changes.rs`. `Sources/WorkspaceMirror/MirrorGlance.swift` excludes archived threads but reads only the existing local mirror; the widget timeline cannot pull hub changes itself. `MirrorHost.publish` requests a widget reload after a batch touching threads, which requires the app to sync first. This is a concrete missing wake path; no device log capture is claimed for the archive event. The owner was asked to open B4 from its icon, stay on Threads, then return Home to test whether foreground sync removes the archived rows. The owner initially reported the widget still showed the tests after that foreground visit, so the missing archive wake alone did not explain the full observation. A Mac recheck still confirmed zero active tests, 14 archived tests, and no unsynced changes. On a subsequent comparison, the owner confirmed “Gone from both now”: the normal active Threads list and widget both cleared. Record cleanup as complete, with delayed foreground propagation; the exact delay and the boundary responsible for that delay were not measured. No source fix has been made for the archive wake gap.
