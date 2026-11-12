# Per-user settings rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The hub keeps one `viewSettings` row per user in an organisation, while every device keeps reading and writing a row whose id is `view`.

**Architecture:** The user's id is carried in the stored row id, `view:<userId>`, on the hub only. `b4hub-core` gets two pure functions that map between the wire id and the stored id; `b4hub-db` uses them where a change is applied (row and column clocks) and where a snapshot is built. The change log keeps the id as pushed (`view`), so pulls need no translation. A migration renames the stored row and its clocks.

**Tech Stack:** Rust (`b4hub-core`, `b4hub-db`, sqlx, PostgreSQL), one Swift test double (`FakeHubAPI`), Markdown records.

**Spec:** `docs/superpowers/specs/2026-11-12-density-and-user-settings-design.md`, Part 1 only. Parts 2 to 4 get their own plans after this merges.

## Global Constraints

- Never edit an applied migration (D-178). The new one is `Hub/crates/b4hub-db/migrations/0021_user_settings_rows.sql`. The number is 0021 because draft pull request 180 (another session) holds `0020_client_protocol.sql`. Before Task 3, `git fetch` and check `origin/main` for a `0021_*`; if one exists, stop and report.
- Devices are not changed: no coordinator migration, no mirror schema change, no change to `Tests/Fixtures/sync/changes.json`. A device sends and receives the row id `view`, always.
- The wire id is the literal `view`. The stored id is `view:` followed by the user's id in the lowercase hyphenated form (`Uuid`'s `Display`), which is also what PostgreSQL's `user_id::text` gives.
- The table keeps its name, `viewSettings`. New code and comments call it the user's settings.
- A refused change is reported per change with a code, is not recorded in the log, and is not applied. The new code is `invalid_row_id`.
- Every statement keeps its `org_id` and `user_id` conditions. Table and column names reach SQL only from `TableSpec`.
- Gates, from `Hub/`: `source <(./scripts/test-db.sh) && cargo test --workspace --locked`, `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings`. One `cargo test` per checkout at a time. From the repo root: `swift format lint --strict --recursive Sources Tests Apps Package.swift` and `Scripts/docs-index.sh --check`.
- Commit messages end with `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`.
- Other sessions merge to main while this runs. Before each task, `git fetch` and look at `git log HEAD..origin/main -- Hub Sources/WorkspaceSync` for the same files; stop and report if another session is changing `changes.rs`, `snapshot.rs` or the view-settings code.

## Review Focus

1. **A second user of the organisation pushes `view`.** Expected: their own row is stored; the first user's row is untouched; neither user's pull or snapshot contains the other's settings. Test in Task 2.
2. **A device pushes a `viewSettings` change with a row id other than `view`**, including `view:<another user's id>` and `view:<its own id>`. Expected: refused with `invalid_row_id`, nothing recorded, nothing stored. Test in Task 2.
3. **A device restores from a snapshot.** Expected: the row id, the `id` inside the value, and every clock's row id are `view`; nothing shows `view:`. Test in Task 2.
4. **A hub that already holds the owner's row is migrated, then the owner changes a setting.** Expected: the change lands on the migrated row, an older clock still loses to the clock carried over, and no second row appears. Test in Task 3.
5. **A hub holds a stray `viewSettings` row with some other id** (today's hub accepts any id). Expected: the migration removes it and its clocks, so no snapshot can ever return a row a device cannot write. Test in Task 3.

---

### Task 1: the wire id and the stored id

**Files:**
- Modify: `Hub/crates/b4hub-core/src/change.rs` (functions beside `table_spec`; tests in the file's `tests` module)

**Interfaces:**
- Produces, all `pub` in `b4hub_core::change`:
  - `pub const USER_SETTINGS_TABLE: &str = "viewSettings";`
  - `pub const USER_SETTINGS_WIRE_ID: &str = "view";`
  - `pub fn accepts_row_id(table: &str, row_id: &str) -> bool` — false only for `USER_SETTINGS_TABLE` with a row id other than `USER_SETTINGS_WIRE_ID`.
  - `pub fn stored_row_id<'a>(table: &str, row_id: &'a str, user_id: Uuid) -> Cow<'a, str>` — for `USER_SETTINGS_TABLE` and the wire id, `view:<user_id>`; anything else is borrowed unchanged.
  - `pub fn wire_row_id<'a>(table: &str, stored: &'a str, user_id: Uuid) -> &'a str` — for `USER_SETTINGS_TABLE` and exactly `view:<user_id>`, `"view"`; anything else unchanged.
  - `Uuid` is the type `StoredChange::device_id` already uses in this file.

- [ ] **Step 1: Write the failing tests** in `change.rs`'s test module:

```rust
#[test]
fn the_users_settings_row_is_stored_under_the_user() {
    let user = Uuid::parse_str("6f1c2a4e-0b7d-4c1e-9a55-0c9d3e2b1a00").unwrap();
    let other = Uuid::parse_str("11111111-2222-4333-8444-555555555555").unwrap();
    let stored = stored_row_id("viewSettings", "view", user);
    assert_eq!(stored, "view:6f1c2a4e-0b7d-4c1e-9a55-0c9d3e2b1a00");
    assert_eq!(wire_row_id("viewSettings", &stored, user), "view");
    // Another user's stored id is never handed out as `view`.
    assert_eq!(wire_row_id("viewSettings", &stored, other), stored);
    // Other tables, and other ids, pass through.
    assert_eq!(stored_row_id("threads", "view", user), "view");
    assert_eq!(wire_row_id("threads", "view:x", user), "view:x");
}

#[test]
fn only_view_is_accepted_as_a_settings_row_id() {
    assert!(accepts_row_id("viewSettings", "view"));
    assert!(!accepts_row_id("viewSettings", "other"));
    assert!(!accepts_row_id("viewSettings", "view:6f1c2a4e-0b7d-4c1e-9a55-0c9d3e2b1a00"));
    assert!(!accepts_row_id("viewSettings", ""));
    assert!(accepts_row_id("threads", "anything"));
    assert!(accepts_row_id("drafts", "view"));
}
```

- [ ] **Step 2: Run** `cd Hub && cargo test -p b4hub-core --locked settings_row` — expected: does not compile (`stored_row_id` not found).
- [ ] **Step 3: Implement** the two constants and three functions. Update the comment on the `viewSettings` `TableSpec` to say the row is one per user, stored as `view:<userId>`, and `view` on the wire.
- [ ] **Step 4: Run** `cargo test -p b4hub-core --locked` — expected: all pass.
- [ ] **Step 5: Commit** `feat(hub): map the settings row's wire id to a per-user stored id`.

---

### Task 2: apply and snapshot use the stored id; other ids are refused

**Files:**
- Modify: `Hub/crates/b4hub-db/src/changes.rs` (`refusal`, `insert`, `update`, `delete`, the module comment)
- Modify: `Hub/crates/b4hub-db/src/snapshot.rs` (`take`)
- Test: `Hub/crates/b4hub-db/tests/changes.rs`, `Hub/crates/b4hub-db/tests/rls.rs`

**Interfaces:**
- Consumes: Task 1's `accepts_row_id`, `stored_row_id`, `wire_row_id`, `USER_SETTINGS_TABLE`.
- Produces: `pub const INVALID_ROW_ID: &str = "invalid_row_id";` in `b4hub_db::changes`, beside `COLUMN_NOT_WRITABLE`.

Decisions:

- `refusal` returns `INVALID_ROW_ID` when `!accepts_row_id(&change.table, &change.row_id)`, for every platform. It is checked after the platform check (so existing `column_not_writable` cases keep their code) and before `CANNOT_CLEAR`.
- The `changes` log insert in `push` keeps binding `change.row_id` as pushed. Only the mirrored row and `column_clocks` use the stored id.
- In `insert`, `update` and `delete`, compute `let row_id = stored_row_id(spec.name, &change.row_id, auth.user_id);` once and use it in every statement and every `claim_clock` call that used `change.row_id`. `insert` already drops the key column from the value and binds the row id separately, so the stored `id` column becomes `view:<userId>` with no other change.
- In `snapshot::take`, after each query, for a row of `USER_SETTINGS_TABLE`: the `StoredChange::row_id` is `wire_row_id(...)`, the value's `"id"` member is set to the same wire id, and each `SnapshotClock::row_id` is `wire_row_id(...)`. Other tables are untouched. Do it in Rust, not SQL. A `USER_SETTINGS_TABLE` row whose stored id is not the reader's own `view:<userId>`, and any clock of such a row, is left out of the snapshot: a device could not write it, and during a rolling deploy an old hub task can still create one named `view`.
- A `viewSettings` update of the `id` column stays what it is today: recorded, then skipped by `update` (the key is not updatable).

- [ ] **Step 1: Change the test helper** `view(app, who)` in `tests/changes.rs` to read the row whose id is `format!("view:{}", who.user_id)`, and change the heading comment to "one row per user, `view` on the wire". In `a_phone_update_of_the_view_id_is_recorded_and_leaves_the_row_alone`, the stored id assertion becomes `assert_eq!(stored["id"], format!("view:{}", mac.user_id));`. In `tests/rls.rs` line 360, select the row by `"id" LIKE 'view:%'`.

- [ ] **Step 2: Replace** `a_second_user_of_the_org_shares_the_first_users_view_key` with:

```rust
/// Settings are per user: a second user of the org stores a row of their own, and neither sees
/// the other's.
#[sqlx::test(migrations = false)]
async fn each_user_of_the_org_has_their_own_settings_row(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let alice = common::enrolled(&admin, &app, "alice").await;
    let bob = common::enrolled(&admin, &app, "bob").await;
    assert_eq!(alice.org_id, bob.org_id);
    let view_insert = |arrangement: &str| {
        insert(1, "viewSettings", "view", json!({"id": "view", "arrangement": arrangement}))
    };
    push_through(&app, &alice, &[view_insert("needsYouFirst")]).await.unwrap();
    push_through(&app, &bob, &[view_insert("byEnvironment")]).await.unwrap();
    assert_eq!(count(&app, &alice, "viewSettings").await, 2);
    assert_eq!(view(&app, &alice).await["arrangement"], "needsYouFirst");
    assert_eq!(view(&app, &bob).await["arrangement"], "byEnvironment");
    assert_eq!(view(&app, &bob).await["user_id"], bob.user_id.to_string());

    // Bob changes his; Alice's does not move, and her clock is not his.
    push_through(
        &app,
        &bob,
        &[update(2, "viewSettings", "view", "quietThreads", Some(json!("hidden")))],
    )
    .await
    .unwrap();
    assert_eq!(view(&app, &bob).await["quietThreads"], "hidden");
    assert!(view(&app, &alice).await["quietThreads"].is_null());

    for (who, arrangement) in [(&alice, "needsYouFirst"), (&bob, "byEnvironment")] {
        let page = changes::pull(&app, who, 0, 100).await.unwrap();
        let mine: Vec<_> = page.changes.iter().filter(|c| c.table == "viewSettings").collect();
        assert!(mine.iter().all(|c| c.row_id == "view"));
        assert_eq!(mine[0].value.as_ref().unwrap()["arrangement"], arrangement);
        let snapshot = b4hub_db::snapshot::take(&app, who).await.unwrap();
        let rows: Vec<_> =
            snapshot.changes.iter().filter(|c| c.table == "viewSettings").collect();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].row_id, "view");
        assert_eq!(rows[0].value.as_ref().unwrap()["id"], "view");
        assert_eq!(rows[0].value.as_ref().unwrap()["arrangement"], arrangement);
        let clocks: Vec<_> =
            snapshot.clocks.iter().filter(|c| c.table == "viewSettings").collect();
        assert!(!clocks.is_empty());
        assert!(clocks.iter().all(|c| c.row_id == "view"));
    }
}
```

(Match the file's existing import path for `snapshot::take` and line wrapping; `cargo fmt` decides the layout.)

Before the final loop, also insert through `admin`, by SQL, a `"viewSettings"` row with `"id" = 'view'` owned by Alice (her org, user and device ids, `arrangement = 'stray'`) and a `column_clocks` row for it; the loop's assertions (one row, `arrangement` as pushed, every clock's row id `view` and exactly as many `viewSettings` clocks as before the stray was added) must still hold for her.

- [ ] **Step 3: Add** the refusal test:

```rust
/// A device reaches only its own settings row: any row id but `view` is refused, recorded
/// nowhere, and stores nothing.
#[sqlx::test(migrations = false)]
async fn a_settings_change_with_another_row_id_is_refused(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;
    let before = count(&app, &mac, "changes").await;
    let own = format!("view:{}", mac.user_id);
    for (who, id) in [(&mac, "other"), (&mac, own.as_str()), (&phone, "view:someone"), (&mac, "")] {
        let outcome = changes::push(
            &app,
            who,
            &[
                insert(1, "viewSettings", id, json!({"id": id, "arrangement": "byEnvironment"})),
                update(2, "viewSettings", id, "arrangement", Some(json!("byEnvironment"))),
            ],
        )
        .await
        .unwrap();
        assert_eq!(outcome.accepted_through, 2);
        assert_eq!(
            outcome.rejected,
            vec![
                Rejected { device_seq: 1, code: changes::INVALID_ROW_ID },
                Rejected { device_seq: 2, code: changes::INVALID_ROW_ID },
            ]
        );
    }
    assert_eq!(count(&app, &mac, "changes").await, before);
    assert_eq!(count(&app, &mac, "viewSettings").await, 0);
    // A Mac's delete of a foreign id is refused the same way.
    let outcome = changes::push(&app, &mac, &[delete(3, "viewSettings", "other")]).await.unwrap();
    assert_eq!(outcome.rejected[0].code, changes::INVALID_ROW_ID);
}
```

(Use the file's existing way of naming `Rejected`.)

- [ ] **Step 4: Run** `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --locked --test changes --test rls` — expected: the two new tests fail (`INVALID_ROW_ID` not found, then count 1 not 2), and the `view` helper's callers fail with "the view row is mirrored".
- [ ] **Step 5: Implement** `INVALID_ROW_ID`, the `refusal` check, and the stored id in `insert`, `update`, `delete`. Extend the module comment's list of refused changes ("a settings row id other than `view`") and its last paragraph (the settings row is the exception to "a second user pushing the same row id": each user's `view` is a row of their own).
- [ ] **Step 6: Implement** the snapshot translation in `snapshot::take`, and say so in its doc comment.
- [ ] **Step 7: Run** `cargo test --workspace --locked`, `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets --locked -- -D warnings` — expected: all pass. Any other test that read the stored row by `id = 'view'` is fixed to the stored id; a test that asserts on pulled or snapshot row ids must still see `view` (the existing `find("viewSettings", "view")` snapshot assertion must pass unchanged).
- [ ] **Step 8: Commit** `feat(hub): one settings row per user, refused under any id but view`.

---

### Task 3: the migration

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0021_user_settings_rows.sql`
- Modify: `Hub/crates/b4hub-db/tests/migrations_frozen.rs` (pin the new file's SHA-256, computed with `shasum -a 256`)
- Test: `Hub/crates/b4hub-db/tests/migrate.rs`

**Interfaces:**
- Consumes: Task 2's behaviour (a pushed `view` lands on `view:<userId>`).

What the migration does, in this order, with a header comment in the style of `0019`:

1. Lifts forced row security on `"viewSettings"` and `column_clocks` for its duration, as `0018_environments.sql` does, and restores it at the end.
2. Deletes `column_clocks` rows where `"table" = 'viewSettings' AND row_id <> 'view'`, then `"viewSettings"` rows where `"id" <> 'view'`. These are rows no device will be able to reach.
3. Renames clocks: `UPDATE column_clocks c SET row_id = 'view:' || v.user_id::text FROM "viewSettings" v WHERE c.org_id = v.org_id AND c."table" = 'viewSettings' AND c.row_id = 'view' AND v."id" = 'view'`.
4. Renames rows: `UPDATE "viewSettings" SET "id" = 'view:' || user_id::text WHERE "id" = 'view'`.
5. Leaves `changes` alone: the log keeps `view`.

- [ ] **Step 1: Write the failing test** in `tests/migrate.rs`. Generalise `migrate_to_0017` into `migrate_before(pool: &PgPool, first_excluded: &str)` (the body is the same with `name.as_str() < first_excluded`), keep `migrate_to_0017` as a one-line caller, and add:

```rust
/// `0021_user_settings_rows.sql` moves each settings row, with its clocks, to the id that names
/// its user, drops rows no device can reach, and leaves the log alone; a change pushed afterwards
/// lands on the moved row and still merges against the clock that came with it.
#[sqlx::test(migrations = false)]
async fn settings_rows_move_to_their_users(pool: PgPool)
```

The test, following `environments_rename_carries_rows_changes_and_clocks` for seeding:
  - `migrate_before(&pool, "0021")`; seed an org, a user and a `macos` device with SQL as that test does.
  - Insert by SQL: a `"viewSettings"` row `id = 'view'`, `arrangement = 'byEnvironment'`, `"quietThreads" = 'tiny'`; a stray row `id = 'stray'`; `column_clocks` rows for (`viewSettings`, `view`, `quietThreads`, hlc `000001000000-0000-<device>`) and (`viewSettings`, `stray`, `arrangement`, any clock); and one `changes` row for `viewSettings` / `view` / insert.
  - Run the full migrator the way the file's other upgrade tests do.
  - Assert: exactly one `"viewSettings"` row, its `"id"` is `view:<user>`, `arrangement` and `"quietThreads"` unchanged; exactly one `column_clocks` row for the table, `row_id = view:<user>`, same hlc; the `changes` row still has `row_id = 'view'`; `relforcerowsecurity` is true for both tables.
  - Then, through `changes::push` as that device (build the `AuthedDevice` as the file's other tests do, or enrol one for the same user): an update of `quietThreads` to `hidden` with an hlc lower than the seeded clock (`000000000001-0000-<device>`) leaves `tiny`; one with a higher clock (`000002100000-0000-<device>`) stores `hidden`; the table still holds one row. A pull from 0 returns the seeded insert and both updates with `row_id == "view"`.

- [ ] **Step 2: Run** `cargo test -p b4hub-db --locked --test migrate settings_rows` — expected: fails (row id still `view`, stray row present).
- [ ] **Step 3: Write** `0021_user_settings_rows.sql`.
- [ ] **Step 4: Pin it** in `migrations_frozen.rs` after `0019`.
- [ ] **Step 5: Run** the three hub gates — expected: all pass, including `applied_migrations_are_unchanged_and_every_migration_is_pinned` and `sqlx_applies_a_lower_numbered_migration_added_later`.
- [ ] **Step 6: Commit** `feat(hub): migration 0021 moves settings rows to their users`.

---

### Task 4: the test double, the reference and the records

**Files:**
- Modify: `Sources/WorkspaceSync/FakeHubAPI.swift` (`refusal(for:)`), `Sources/WorkspaceSync/Wire.swift:301` (the comment listing codes)
- Test: `Tests/WorkspaceSyncTests/FakeHubWritesTests.swift`
- Modify: `Hub/API.md` (the rejection codes after `cannot_clear` near line 1080; the phone-writable paragraph near 1130; the *View settings* section near 1279; the `table` row near 1267)
- Modify: `AGENTS.md` line on `viewSettings` (add "hub migration `0021` keeps one row per user, stored as `view:<userId>`; devices see `view`").
- Create: `docs/decisions/D-NNN-settings-belong-to-a-user.md`, `docs/verification/2026-11-12-user-settings-rows.md` (use the day the gates ran)
- Modify: `docs/milestones.md`, `docs/compatibility.md` (hub migration 0021; no device build needed)

**Interfaces:**
- Consumes: the code `invalid_row_id`.

- [ ] **Step 1: Write the failing Swift test** in `FakeHubWritesTests.swift`, in the style of the test at line 81:

```swift
@Test func aSettingsChangeUnderAnotherRowIdIsRefused() async throws
```

Push, as a `macos` fake and again as an `ios` one, a `viewSettings` insert with `rowId: "other"`; expect `rejected == [RejectedChange(deviceSeq: 1, code: "invalid_row_id")]` and that a following pull holds no `viewSettings` change. A `viewSettings` insert with `rowId: "view"` in the same test is accepted.

- [ ] **Step 2: Run** `swift test --filter FakeHubWritesTests` — expected: the new test fails (nothing refused).
- [ ] **Step 3: Implement** in `refusal(for:)`, after the platform check: `if change.table == "viewSettings" && change.rowId != "view" { return "invalid_row_id" }`. Add the code to the comment in `Wire.swift`.
- [ ] **Step 4: Run** `swift test --filter WorkspaceSyncTests` and `swift format lint --strict --recursive Sources Tests Apps Package.swift` — expected: pass.
- [ ] **Step 5: Update `Hub/API.md`:** add `invalid_row_id` to the per-change codes ("a `viewSettings` change whose `rowId` is not `view`; for any device"); rewrite the *View settings* opening to say the row is one per user, always `view` on the wire, stored by the hub under the user, and that two users of one organisation never see each other's.
- [ ] **Step 6: Write the decision.** Take the number with `Scripts/docs-index.sh --next` when the pull request is opened, not before (`blove/b4-command-palette-spec-ba5790` uses D-213 to D-215 and may merge first). First line `## 2026-11-12 (settings belong to a user)`, then one bullet `- **D-NNN Settings belong to a user.** ...` covering: the owner's rule (settings per user, separate per organisation; organisation settings are for billing and the like); the stored id `view:<userId>` on the hub only and the five reasons devices keep `view` (spec, Part 1); the refusal `invalid_row_id`; migration 0021 and what it drops; that the log keeps `view`; "amends D-208" for its known limit and its deferred minor.
- [ ] **Step 7: Write the verification record** (`## 2026-11-12: per-user settings rows`): the gate commands and their results as run, the test names from Review Focus, and what was not checked (no hosted hub was touched; nothing was run in an app, because no device code changed). Add the `docs/milestones.md` line and the `docs/compatibility.md` note.
- [ ] **Step 8: Run** `Scripts/docs-index.sh --check` — expected: passes.
- [ ] **Step 9: Commit** `docs: settings belong to a user (D-NNN); the fake hub refuses other settings ids`.

---

## Deploying (after merge, with the owner's go-ahead for each hub)

The "Hub image" workflow deploys beta's hub on merge to main. Each hub runs two tasks, so for a moment an old task can still write a row with the id `view` after the migration has run; no snapshot returns that row (Task 2) and the change itself is in the log, so every device still receives it; only the hub's stored row misses that one edit until the setting is next changed. With one user this window is the owner not touching a setting for a minute; the verification record says so. Prod is a separate, owner-approved release. No Mac or phone build is needed for this part.
