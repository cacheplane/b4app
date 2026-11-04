## 2026-11-02: Flaky CI tests now await events

Branch `fix/flaky-tests-await-events`. These are tests that failed on `main` or a PR and passed on rerun. Each now waits for the event it depends on instead of a fixed time, or a fixed time that a loaded runner can outlast:

- **`HTTPHubAPITests.appendFeedsAReaderAndALongPollWakesForIt`.** `FakeHubAPI`'s long poll used to re-read every 10 ms. It now parks until something can change its answer: `append`, a push, `setFailNext`, `revokeSelf`, its deadline, or cancellation. `untilPulling()` lets the test append once the pull is parked, replacing a 50 ms sleep.
- **`ClaudeSessionTests.resumesKnownSessionsAndReportsMissingOnes`.** A real race in `ClaudeSession`. A missing session is recognised by its stderr line, which could arrive after the exit was seen, giving `endpoint_unavailable`. The read loop now awaits stderr's end (`waitForStderrEnd()`, bounded at 2 s for a grandchild that keeps it open) before reporting the exit. `aMissingSessionIsRecognisedWhenStderrTrailsTheExit` reproduces it deterministically: `fake-claude.py` `missing-late` writes the line from a grandchild 300 ms after exiting. It fails without the fix.
- **`ManagedProcessTests.portsAllocateAndDetectInUse`** (failed twice). A just-released port can go to a parallel test's connection. The test now checks "free" on the first of up to five allocations that stayed free, then holds the port with its own listener.
- **`ManagedProcessTests.terminateGroupKillsAGrandchild`.** It already waited on the grandchild's exit event, but its 10 s guard sat under a 30 s sleep. The sleep is now 600 s and the guard 120 s, so a missed signal still fails and a slow runner doesn't. A `defer` kills a leftover sleeper.
- **Rust `instances::readiness_reports_a_stale_heartbeat`** (and the claim-takeover test, which pauses the same way). A heartbeat write already past the pause check could land after the pause and refresh the instance. `InstancesState::settle()` returns once no write is in progress, and the tests await it after pausing.
- **Already fixed on `main`:** `MirrorSyncTests.failuresAreRecordedAndRetriedWithBackoff` (`3e3427a`) and `request_log::a_503_is_a_warning_…` (`828e6f9`).

`swift test` passes 864 tests; lint, `cargo fmt` and `cargo clippy` are clean.
