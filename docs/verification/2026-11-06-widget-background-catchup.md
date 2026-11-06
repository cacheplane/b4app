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
