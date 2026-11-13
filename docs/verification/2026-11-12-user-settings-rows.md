## 2026-11-12: per-user settings rows

D-213: the hub keeps one `viewSettings` row per user, stored as `view:<userId>`, and devices still send and receive `view`; any other row id is refused with `invalid_row_id`; migration `0021` moves the rows a hub already holds. Branch `blove/user-settings-rows`, from `main` 0b17646.

### Gates

Hub, as run during the build (reported by the task implementers, not run again for this record):

- `cargo test -p b4hub-core --locked`: 35 passed, including `the_users_settings_row_is_stored_under_the_user` and `only_view_is_accepted_as_a_settings_row_id`.
- `cargo test -p b4hub-db --locked --test changes --test rls`: changes 51 passed, rls 7 passed. New or changed: `each_user_of_the_org_has_their_own_settings_row` (replaces the test that two users shared one key), `a_settings_change_with_another_row_id_is_refused`, a snapshot that leaves out a stray `viewSettings` row and its clocks and returns the reader's own as `view`.
- `cargo test -p b4hub-db --locked --test migrate settings_rows`: `settings_rows_move_to_their_users` passed (a seeded `view` row and a stray row; after the migration only `view:<user>` is left, with its values and clocks).
- `cargo test --workspace --locked` (after the push and snapshot change, and again after the migration): every suite ok, none failed, including `migrations_frozen` with the new file's hash, the lower-numbered-migration test and the non-superuser owner rerun.
- `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings`: clean.

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
