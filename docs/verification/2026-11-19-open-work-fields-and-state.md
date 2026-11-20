## 2026-11-19: open work and origin, fields and rules (D-259)

The first part of the runtime turns design: `Turn.openWork` and `Turn.origin`, the state and band rules that read them, and the at-rest notification rule. Nothing writes either field yet, so every row carries no open work and the running app behaves as before. Built on `blove/live-activity-recordings` (commits d61271c3, e9bed438, 44c93d07, 3f0791cf, 862e61df, a5a9807a).

### Commands

- `swift test --filter "TurnCodingTests|AttentionTests|ActivityQueryTests|WorkspaceMirrorTests|AttentionModelTests|ThreadLinkTests"` at 19910a63: `Test run with 351 tests in 25 suites passed after 7.629 seconds.`
- `swift test` (full) at 19910a63: `Test run with 2283 tests in 258 suites passed after 113.699 seconds.` An earlier full run, before 19910a63, had 3 issues (see "Fixture-derived expectations").
- From `Hub/`, `source <(./scripts/test-db.sh) && cargo test --workspace --locked`: exit 0; 30 test binaries, 560 tests passed, 0 failed. The cluster was stopped afterwards with `./scripts/test-db.sh --stop`.
- `cargo fmt --all -- --check`: clean. `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings.
- `Scripts/docs-index.sh --check`: exit 0. Its output at the time was not kept; the fix wave's run below printed `docs-index: 244 decisions and 158 verification records are well formed`.
- Six tests have failed on this machine before, outside this change (`RecordingSessionTests.rejectsGapEpochAndAccountChanges` and five in `WorkspaceMirrorTests`); all six passed in the full run at 19910a63.

### Fixture-derived expectations

Three tests pinned values derived from `Tests/Fixtures/sync/attention.json`. The full run, made after the fixture gained its four open-work threads in commit 3f0791cf, found them failing (`Test run with 2283 tests in 258 suites failed ... with 3 issues`, the same three on a second run of their suites alone, so not load flakes). Commit 19910a63 updated them; no production code or fixture changed:

- `MirrorNotificationsTests.needsYouCountMatchesFixture` pinned 5; the fixture's needs-you threads are now 6, two `needsInput` plus four `unread`, `t-open-work-failed` among the unread (its hub band).
- `MirrorGlanceTests.loadsTheTopThreeInAttentionOrderWithEnvironmentNames` and `archivedThreadsAreLeftOut` pinned the glance's rows; `t-open-work-failed` is a failed thread and now ranks in them.

### Cases added

- `Tests/Fixtures/sync/attention.json`: four threads with open work, each with the expected hub band. `t-open-work-unread` (latest turn completed and unread, open work 2) is `working`; `t-open-work-earlier` (an earlier turn has open work 1, the latest has 0) is `working`; `t-open-work-read` (the latest turn is the read turn, open work 1) is `working`; `t-open-work-failed` (an earlier completed turn has open work 1, the latest turn failed with 0) is `unread` in the hub's bands, the failed exception, and `failed` in the Swift state rule. The fixture is read by the Swift rule, the mirror's query and the hub's SQL.
- `Tests/Fixtures/sync/push.json`: four turn cases with `atRest` (completed and not at rest gives no notification; failed and not at rest gives "failed"; completed, at rest, not recent gives none; running, not at rest gives none).
- Swift: `TurnCodingTests` (`aNullOpenWorkReadsAsZero`, `theFieldsRoundTrip`), `AttentionTests.openWorkKeepsAnEndedThreadWorking`, `ActivityQueryTests.openWorkIsSummedOverTheThreadsTurns`, `MirrorMigrationTests.version11AddsOpenWorkAndOriginToTurns`, `MirrorStoreTests` (`aTurnInsertFromAnOlderMacReadsAsNoOpenWork`, `aTurnInsertCarriesOpenWorkAndOrigin`), `MirrorActivityTests.openWorkIsSummedOverTheThreadsTurns`.
- Hub: `Hub/crates/b4hub-db/tests/push.rs` (the reply keyed by the latest turn, open work ending late, the already-read reply staying silent: `a_reply_already_read_does_not_alert_when_open_work_ends`, `a_newer_reply_than_the_read_turn_alerts_when_open_work_ends`; `read_withdraws_earlier_turns_once` now pushes its turns in separate batches), `changes.rs` (`a_turn_carries_open_work_and_origin`, `a_turn_without_the_new_columns_is_accepted`), `migrate.rs` and `migrations_frozen.rs` (migration `0023`).

### Review

Each of tasks 1 to 5 had a task review. Task 5 had one fix round: a proposed extra "already read" condition on the reply rule was withdrawn after the existing test `outcome_after_the_read_is_silent` showed the withdrawal already covers it. Minor findings deferred and still open: two over-long doc comment lines (`Sources/WorkspaceProtocol/Attention.swift`, `Sources/WorkspaceStorage/WorkspaceDatabase.swift`), one in `Tests/WorkspaceProtocolTests/AttentionTests.swift`, the open-work test table's parallel array in `AttentionTests.swift`, and the hub test `a_malformed_timestamp_costs_only_its_row`, which does not reach the timestamp cast.

### Whole-change review fix wave

A review of the whole change found one important code finding and several minor ones. All were fixed in commits 3491b299 (hub code and tests) and a003762b (Swift tidy-ups), with the records in the commit that holds this section.

- **A touched failed turn hid the later reply.** For a touched turn that was terminal, failed and recent, `subject` returned the failure only and never read the reply rule. When an earlier turn failed holding open work (its failure already sent) and later dropped its open work to 0, the only touched row was that turn, already in the ledger, so the later completed and unread reply was never sent although the thread was at rest. `subject` became `subjects` in `Hub/crates/b4hub-db/src/push.rs`: a touched turn yields its own failure, keyed by the touched row, and then the latest turn's reply under the existing conditions, each written to the ledger with its own key. When the touched turn is itself the latest and failed, only the failure applies. New tests `a_reply_is_not_lost_when_an_earlier_failed_turns_open_work_ends` and `a_failed_turn_and_the_reply_after_it_both_notify_in_one_push` failed before the change (`left: []` against `right: [("turn:R", Replied)]`, and `left: [("turn:T", Failed)]` against both) and pass after it. The four tests the plan named as must-pass-unchanged were not edited and pass.
- **`a_malformed_timestamp_costs_only_its_row`** used `"soon"`, which the shape check refuses before the cast. It now uses `2026-13-45T99:99:99Z`, which passes the check and fails the cast, and asserts that the well-formed turn in the other thread notifies.
- **Comments.** `prune.rs` no longer says a turn notifies only within ten minutes of its own update; it says a reply can notify again after the retention period. The `BANDS` and `Band` comments in `push.rs` cite `Attention.state(of:)`, of which the hub's four bands are a coarser reading, in place of `Attention.band(of:)`, which does not exist. The `subjects` comment and `Hub/API.md` describe both candidates.
- **Swift.** Three over-long doc comments were wrapped (`Attention.state(of:)`, `threadWithActivity`, the attention fixture's reference activity). `AttentionTests.openWorkKeepsAnEndedThreadWorking` now names each row's fields and gives each row an expected badge value; the approve and finished rows, whose badge was not checked before, expect `true`.
- **Records.** D-259 gained the rule as built, an open point on the latest turn by `createdAt`, a stop amending the design, the ledger retention consequence and the items deferred to the transcript change. The design's sentence on a stop and the D-259 deploy warning in `docs/compatibility.md` were updated.

Fresh results at a003762b plus these records:

- From `Hub/`, `source <(./scripts/test-db.sh) && cargo test --workspace --locked`: every binary `test result: ok`, 0 failed; `tests/push.rs` in `b4hub-db`: `test result: ok. 48 passed; 0 failed`. The cluster was stopped afterwards.
- `cargo fmt --all -- --check`: clean. `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings.
- `swift test --filter "AttentionTests|ActivityQueryTests|WorkspaceMirrorTests|AttentionModelTests|ThreadLinkTests|TurnCodingTests"`: `Test run with 351 tests in 25 suites passed after 6.644 seconds.`
- `swift test` (full): `Test run with 2283 tests in 258 suites passed after 108.322 seconds.` `RecordingSessionTests.rejectsGapEpochAndAccountChanges` and the `WorkspaceMirrorTests` suites passed in it.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: no output, exit 0.
- `Scripts/docs-index.sh --check`: `docs-index: 244 decisions and 158 verification records are well formed`, exit 0.

### Not checked

- Anything on a device or in the running app. No row carries open work until the coordinator change, so no thread state or notification could differ on screen.
- A hub that already holds data being migrated by `0023`; the tests migrate an empty database.
- The phone app migrating a schema 10 mirror outside the tests (`MirrorMigrationTests` covers it in process).
