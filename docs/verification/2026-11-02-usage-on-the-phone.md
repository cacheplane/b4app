## 2026-11-02: Usage on the phone (D-118)

Branch `blove/phone-usage`.

**Gates**
- `swift format lint --strict` was clean.
- `swift test` passed: 868 tests in 125 suites.
- Hub: `cargo test --workspace --locked` passed 248 tests; `cargo fmt --check` and `clippy -D warnings` were clean. After merging the soft-delete work (#45, D-089), `connectionUsage` has `deleted_at` too, and the hub passed 251 tests with fmt and clippy clean.
- Both `xcodebuild` builds succeeded.

**New tests**
- Mac: `syncedUsageIsLoggedWhenItChanges` (the synced row is logged when it moves, and not when it doesn't) and `usageIsWrittenForThePhone` (a Codex check and a B4 turn write the row).
- Hub: `connection_usage_syncs_under_its_connection` and `connection_usage_is_mirrored_and_pulled`. The migration guards now include `0010` and the table's row-level security.
- Mirror: `usageReadServesTheMacsUsage`, `publishAnnouncesUsage`, and the schema version 4 migration tests.
- UI: `tokenTotalsAreNamedByTheirDay` and `aUsageEventWithTheWholeUsageReplacesIt`.

**Not run before merge: the live check in the Simulator against the owner's Compose hub.** Running the hub from this branch would apply `0010` to the owner's hub database, and a hub binary without it would then refuse to start (sqlx `VersionMissing`). So the check runs after the merge, on the hub and apps rebuilt from `main`, and is recorded there.
