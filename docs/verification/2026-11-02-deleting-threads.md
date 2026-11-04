## 2026-11-02: Deleting threads (D-119, D-120)

Branch `blove/delete-threads`, stacked on `blove/phone-usage`.

**Gates**
- `swift format lint --strict` was clean.
- `swift test` passed: 902 tests in 134 suites (after the review's fix pass).
- Hub: `cargo test --workspace --locked` passed 249 tests on two consecutive runs; `cargo fmt --check` and `clippy -D warnings` were clean. After merging the updated `blove/phone-usage` (with the soft-delete work, D-089), 250 passed. The relay suite (`b4hub --test relay`, which this branch does not touch) failed one or two timing tests per run, a different one each time: `presence_is_sent_when_the_queue_has_room_again`, `interrupt_is_held_and_delivered_on_reconnect`, `watching_tells_the_mac_the_full_set`. One earlier run also had a flaky `b4hub-db` `settings` failure that did not recur.
- Both `xcodebuild` builds (macOS, iOS Simulator) succeeded.

**New tests**
- Storage: `ThreadDeleteStoreTests`. A deleted thread leaves every list; the mark keeps its first time and is logged; the runtime-delete record and its backoff; the Diagnostics counts. `OrganisationSchemaTests` pins `userDeletedAt` as a clocked column of the change trigger.
- Adapters: `CodexDeleteTests`, `ClaudeDeleteTests` and `B4DeleteTests`. These cover deleted, already gone and unsupported for each runtime. For Claude, only the one session's `.jsonl` and folder go; `../x`, `a/b`, `.` and `s1.jsonl` are refused and touch nothing.
- Coordinator: `ThreadDeleteTests`.
  - A Codex delete hides the thread and reaches `thread/delete`.
  - A running B4 turn is interrupted before the `DELETE`.
  - A phone's delete is swept later.
  - An unreachable B4 is retried after its backoff and then done.
  - A server without the route is final.
  - A late event for a deleted thread publishes nothing. Disabling that guard fails the test.
  - After merging sign-in (#49): `aRetryWaitsFromTheFailedTry`. CI ran a delete against a stopped B4 server that hung for 70 s instead of being refused, and the retry was then due at once; the wait now counts from the failed try. `thread.delete` is gated on a signed-in account (`Router.needsAccount`).
  - From the review's fix pass: `aPhonesDeleteStopsTheRunningTurn` (a delete pulled from the phone interrupts the running B4 turn before the `DELETE`, and nothing is left in active work), `aReconcilingTurnOfADeletedThreadIsEnded`, and `deletingAnswersBeforeASlowRuntimeDelete` (the command answers in under 3 seconds while the runtime delete takes 5).
- Hub: `a_phone_marks_a_thread_deleted_and_the_row_stays`. A phone's mark is applied by clock, an older Mac write does not clear it, and the row and its turns stay. Also the `writable.rs` lists and the `0011` migration guards.
- Mirror: `MirrorDeleteTests`. A phone delete hides the thread, makes it unreadable, and queues one `userDeletedAt` update; a repeat queues nothing; a pulled mark hides it too. The schema version 5 migration guards are covered as well.
- UI: `ThreadDeleteDiagnosticsTests` (the Diagnostics "Deleted threads" counts by runtime) and `ThreadDeleteModelTests`. Deleting the open thread closes it and discards the unsent text; the confirmation copy covers each runtime, a disabled connection and a running turn; a late turn event keeps the thread gone.

**Checked by hand:** Codex 0.166.0's generated schema has `ThreadDeleteParams { threadId }` and an empty `ThreadDeleteResponse`.

**Not run before merge**
- **The alert and the iPhone swipe on screen.** SwiftUI alerts don't render in the offscreen snapshot harness.
- **The Simulator check against the owner's Compose hub.** That hub needs `0011`, so it waits until this merges and the hub is rebuilt from main.
- **A live delete in real Codex, Claude Code or B4.** The fixtures stand in for all three.
