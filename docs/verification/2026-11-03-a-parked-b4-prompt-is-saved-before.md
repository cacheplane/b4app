## 2026-11-03: A parked B4 prompt is saved before the fixture discloses it

A fixture-only change. No test or assertion changed.

- **`B4AdapterSessionTests.aParkedPromptSurvivesAServerRestart`.** It failed once in a filtered parallel run on PR #79's branch at `fe0789d`, with "timed out waiting for event; saw []" after 64 s. The test stops the fake B4 server as soon as the adapter reports `runtimeRequestOpened`. `fake-b4.py`'s "approve" run sent the `interrupt` frame *before* it marked the thread `interrupted` and wrote `FAKE_B4_STATE`. A stop that landed between the two left the restarted server with the thread still `busy` and turn-1 `working`. Reconcile then reported `.known(.failed)`, not `.parked`, and the wait for the reopened prompt saw no events. A 2 s sleep between the frame and the save reproduced it every time, with the same message after 64 s and `.known(.failed) == .parked` at line 260. The real server commits a park before it discloses it (b4 T-018, `crates/b4-http/tests/approval_durable_disclosure_tcp.rs`), so the fixture now saves first and emits after. The same 2 s sleep placed after the frame no longer fails the test.

Runs (10 CPU burners throughout, test bundle run 4 at a time through `swiftpm-testing-helper` so the runs share no SwiftPM lock):
- **Old fixture:** 0 failures in 100. The natural window is narrow; the sleep above is the reproduction.
- **New fixture:** 0 failures in 200, alongside 3 full `swift test` runs (1302 tests). The test passed in each of the 3.
- **Before that:** `swift test --filter "B4AdapterTests|CoordinatorTests"` passed, 346 tests.

Under that load, the full runs failed in places that this fixture change does not touch (open, not fixed here):
- **`B4AdapterSessionTests.aDroppedStreamReattachesWithoutResubmitting`** (line 241, `deltas != "Part one. Part two."`). The "drop" run emits "Part two." 1 s after the drop. A reattach to a live run gets only frames emitted after it attaches, and a reattach after `done` gets none. The test therefore assumes the adapter reattaches within 1 s, and its backoff (250, 500, 750 ms) under load does not promise that.
- **`FakeHubLinkConnection.nextSocket()`** calls `preconditionFailure` when it is cancelled. When a test passes its 120 s limit (`HubLinkRelayTests.expiredOrUndatedCommandIsRefused`), swift-testing cancels it and the whole test process crashes (`HubLinkConnection.swift:317`). That was an earlier run with the single runs going through `swift test` too. Fixed since: the entry above.
- Load timeouts in `MirrorSyncTests` (six), `PairLinkTests.aSwitchKeepsTheNewSignInBeforeEndingTheOldSession`, and `PairingTests.pairIsRoutedAndNeverReplayedFromTheOperationCache` (15 s `diagnostics.read`).
