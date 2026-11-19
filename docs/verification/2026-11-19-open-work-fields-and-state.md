## 2026-11-19: open work and origin, fields and rules (D-259)

The first part of the runtime turns design: `Turn.openWork` and `Turn.origin`, the state and band rules that read them, and the at-rest notification rule. Nothing writes either field yet, so every row carries no open work and the running app behaves as before. Built on `blove/live-activity-recordings` (commits d61271c3, e9bed438, 44c93d07, 3f0791cf, 862e61df, a5a9807a).

### Commands

- `swift test --filter "TurnCodingTests|AttentionTests|ActivityQueryTests|WorkspaceMirrorTests|AttentionModelTests|ThreadLinkTests"`: `Test run with 351 tests in 25 suites failed after 7.826 seconds with 3 issues.` The three issues are the ones listed under "Failures" below.
- `swift test` (full): `Test run with 2283 tests in 258 suites failed after 111.182 seconds with 3 issues.` The same three. The six tests that have failed on this machine under load before (`RecordingSessionTests.rejectsGapEpochAndAccountChanges` and five in `WorkspaceMirrorTests`) passed in this run.
- From `Hub/`, `source <(./scripts/test-db.sh) && cargo test --workspace --locked`: exit 0; 30 test binaries, 560 tests passed, 0 failed. The cluster was stopped afterwards with `./scripts/test-db.sh --stop`.
- `cargo fmt --all -- --check`: clean. `cargo clippy --workspace --all-targets --locked -- -D warnings`: finished with no warnings.
- `Scripts/docs-index.sh --check`: see "Docs check" below.

### Failures

Three Swift tests fail, each on a second run of its own suite alone (`swift test --filter "MirrorNotificationsTests|MirrorGlanceTests"`: 20 tests, 3 issues), so they are not load flakes. Each reads `Tests/Fixtures/sync/attention.json`, which gained four threads in commit 3f0791cf:

- `MirrorNotificationsTests.needsYouCountMatchesFixture` pins the count of needs-you threads in the fixture at 5; the fixture now has 6, because `t-open-work-unread` is a thread that needs you.
- `MirrorGlanceTests.loadsTheTopThreeInAttentionOrderWithEnvironmentNames` and `MirrorGlanceTests.archivedThreadsAreLeftOut` pin the top three rows of the glance; `t-open-work-failed` is a failed thread and now ranks among them.

These failures follow from the fixture change and were not fixed in this record's commit, which changes no code and no test. They need their expected values updated before CI will pass.

### Cases added

- `Tests/Fixtures/sync/attention.json`: four threads with open work, each with the expected hub band. `t-open-work-unread` (latest turn completed and unread, open work 2) is `working`; `t-open-work-earlier` (an earlier turn has open work 1, the latest has 0) is `working`; `t-open-work-read` (the latest turn is the read turn, open work 1) is `working`; `t-open-work-failed` (an earlier completed turn has open work 1, the latest turn failed with 0) is `unread` in the hub's bands, the failed exception, and `failed` in the Swift state rule. The fixture is read by the Swift rule, the mirror's query and the hub's SQL.
- `Tests/Fixtures/sync/push.json`: four turn cases with `atRest` (completed and not at rest gives no notification; failed and not at rest gives "failed"; completed, at rest, not recent gives none; running, not at rest gives none).
- Swift: `TurnCodingTests` (`aNullOpenWorkReadsAsZero`, `theFieldsRoundTrip`), `AttentionTests.openWorkKeepsAnEndedThreadWorking`, `ActivityQueryTests.openWorkIsSummedOverTheThreadsTurns`, `MirrorMigrationTests.version11AddsOpenWorkAndOriginToTurns`, `MirrorStoreTests` (`aTurnInsertFromAnOlderMacReadsAsNoOpenWork`, `aTurnInsertCarriesOpenWorkAndOrigin`), `MirrorActivityTests.openWorkIsSummedOverTheThreadsTurns`.
- Hub: `Hub/crates/b4hub-db/tests/push.rs` (the reply keyed by the latest turn, open work ending late, the already-read reply staying silent: `a_reply_already_read_does_not_alert_when_open_work_ends`, `a_newer_reply_than_the_read_turn_alerts_when_open_work_ends`; `read_withdraws_earlier_turns_once` now pushes its turns in separate batches), `changes.rs` (`a_turn_carries_open_work_and_origin`, `a_turn_without_the_new_columns_is_accepted`), `migrate.rs` and `migrations_frozen.rs` (migration `0023`).

### Review

Each of tasks 1 to 5 had a task review. Task 5 had one fix round: a proposed extra "already read" condition on the reply rule was withdrawn after the existing test `outcome_after_the_read_is_silent` showed the withdrawal already covers it. Minor findings deferred and still open: two over-long doc comment lines (`Sources/WorkspaceProtocol/Attention.swift`, `Sources/WorkspaceStorage/WorkspaceDatabase.swift`), one in `Tests/WorkspaceProtocolTests/AttentionTests.swift`, the open-work test table's parallel array in `AttentionTests.swift`, and the hub test `a_malformed_timestamp_costs_only_its_row`, which does not reach the timestamp cast.

### Not checked

- Anything on a device or in the running app. No row carries open work until the coordinator change, so no thread state or notification could differ on screen.
- A hub that already holds data being migrated by `0023`; the tests migrate an empty database.
- The phone app migrating a schema 10 mirror outside the tests (`MirrorMigrationTests` covers it in process).
- The three failing tests above, which are not fixed.
