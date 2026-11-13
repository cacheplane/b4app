## 2026-11-12: per-user settings rows

D-213: the hub keeps one `viewSettings` row per user, stored as `view:<userId>`, and devices still send and receive `view`; any other row id is refused with `invalid_row_id`; migration `0020` moves the rows a hub already holds. Branch `blove/user-settings-rows`, from `main` 0b17646.

### Gates

Hub, run on the finished tree (from `Hub/`, after `source <(./scripts/test-db.sh)`):

- `cargo test --workspace --locked --no-fail-fast`: 30 suites, 543 passed, 0 failed. New or changed tests: `the_users_settings_row_is_stored_under_the_user` and `only_view_is_accepted_as_a_settings_row_id` (`b4hub-core`); `each_user_of_the_org_has_their_own_settings_row` (replaces the test that two users shared one key; it also shows a snapshot leaving out a stray row and its clocks) and `a_settings_change_with_another_row_id_is_refused` (`tests/changes.rs`); `settings_rows_move_to_their_users` (`tests/migrate.rs`: run as the non-superuser owner over three organisations, one with a row and a stray row, one with its own row, one with only a leftover clock; a clock carried over still beats an older write).
- `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings`: clean.

Three things failed on the way and were fixed before that run:

- The migration was first numbered 0021, leaving 0020 to draft pull request 180. `environment_history_controls` needs the applied numbers to be consecutive, so six of its tests failed; the migration is 0020.
- The migration first forced row-level security on both tables when it finished. Four `environment_history_controls` tests failed ("per-table RLS flags changed or were swapped"): a migration must leave each table's flag as it found it. It now reads the two flags first and restores them.
- `migrate_is_idempotent_and_provisions_the_app_role` counted 19 migrations; it counts 20.

The implementers' reports during the build said the whole suite passed while the first two of these were failing, so the hub results here are from this run only.

Swift, run for this record:

- `swift test --filter FakeHubWritesTests`, before the fake changed: `aSettingsChangeUnderAnotherRowIdIsRefused` failed (the push rejected nothing and the row was stored).
- `swift test --filter WorkspaceSyncTests`, after: 144 tests in 10 suites passed. New: `aSettingsChangeUnderAnotherRowIdIsRefused` (a `macos` and an `ios` fake each have an insert under `other` refused with `invalid_row_id`, nothing stored, and an insert under `view` accepted). Changed: `pushReportsRejectedPhoneColumns` now sends its settings update under the row id `view`.
- `swift format lint --strict --recursive Sources Tests Apps Package.swift`: clean.
- `swift build`: succeeded.
- `Scripts/docs-index.sh --check`: passed.

### Not checked

- No hosted hub was touched or migrated. Whether either hosted hub holds a stray settings row (an id other than `view`), which the migration deletes, was not looked at.
- Nothing was run in an app, because no device code changed. Two devices syncing the settings through a hub was not tried.
- The rolling deploy was not exercised: an old hub task writing a row named `view` after the migration, while a new task serves. D-213 describes what to expect (devices still get the change from the log; the hub's stored row misses that one edit until the setting is next changed).
- The full `swift test` was not run for this record.
