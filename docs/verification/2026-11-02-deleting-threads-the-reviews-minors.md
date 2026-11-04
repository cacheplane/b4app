## 2026-11-02: Deleting threads, the review's minors (D-138)

Branch `blove/delete-threads-minors`. Each fix was test-first: the test failed, then passed with the fix.

**Gates**
- `swift format lint --strict` was clean; `swift test` passed 1217 tests in 154 suites.
- Hub: `cargo fmt --check` and `clippy -D warnings` were clean. `cargo test --workspace --locked --no-fail-fast` passed every `b4hub-db` and `b4hub-core` test, the new one included. Across two full runs, four timing tests failed once each and passed when re-run alone: `profile_sets_onboarded_and_renames_org` (at sqlx's test-database setup), `pull_over_real_tcp_does_not_miss_a_push_in_the_gap`, `held_answer_expires_after_sixty_seconds`, and the relay's `presence_is_sent_when_the_queue_has_room_again`. The last one also failed alone, but it fails on a clean `origin/main` checkout too (3 of 4 runs there, every run here), on a Mac busy with other worktrees' builds. It was already listed as flaky above.

**New tests**
- Adapters: `invalidParamsWithoutNotFoundAreNotAlreadyGone` (Codex, `FAKE_CODEX_DELETE_INVALID`), `aRoutelessNotFoundIsUnsupportedWhenTheThreadStillExists` (B4, `FAKE_B4_DELETE_404`), and for Claude `removesTheSessionFromEveryProjectFolder`, `anUnreadableRootIsNotAlreadyGone` (mode 000) and `aMissingRootIsNotAlreadyGone`.
- Hub: `clearing_the_delete_mark_is_refused`: a null `userDeletedAt` from the phone or the Mac is rejected `cannot_clear` however new its clock, and a newer insert carrying null leaves the mark.
- Mac: `aPulledNullNeverClearsTheDeleteMark` (`RemoteApplyTests`).
- UI: `confirmationCopyLeavesOutARuntimeSignedInAsSomeoneElse`.
- Coordinator: `aSweepSkipsAThreadAnotherSweepFinished` (a slow sweep's stale due list no longer deletes the second thread twice), `theBackoffDoublesFromThirtySecondsAndCapsAtAnHour`, and `aPulledPhoneDeleteIsSweptToTheRuntime` (a phone's mark pulled through `HubSync` from `FakeHubAPI`, then the sweep, then Codex's `thread/delete`). The last two cover behaviour that was already right, so they passed at once.
- The `COLLATE "C"` on `nextAttemptAt` has no failing test: the timestamps are fixed-width ISO strings, which sort the same under any collation.
