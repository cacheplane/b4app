# Open work and origin: fields and state rule (change 1 of 6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A turn can carry `openWork` and `origin` on the Mac, the hub and the phone, a thread with open work reads as working everywhere, and the hub tells the phone "Replied" only when a thread has come to rest. Nothing writes the fields yet.

**Architecture:** Two new columns on `turns` in all three stores, decoded leniently. `ThreadActivity` sums `openWork` over a thread's turns in the Mac's and the phone's activity queries, and `Attention.state(of:)` and the hub's `BANDS` SQL gain one rule each. The hub's turn notification is re-keyed from "the turn that changed" to "the thread's latest turn, once the thread is at rest".

**Tech Stack:** Swift 6 (swift-testing), PostgreSQL (coordinator, hub), SQLite (mirror), Rust (sqlx, `#[sqlx::test]`).

**Spec:** `docs/superpowers/specs/2026-11-19-runtime-turns-and-open-work-design.md` (sections "The model", "Hub", "Coordinator store and phone", "When the phone is told"). This plan is change 1 of its "Order of work"; changes 2 to 6 get plans of their own.

## Global Constraints

- Field names, exactly: `openWork` (integer) and `origin` (text) on a turn; `openWork` on `ThreadActivity`.
- `openWork` absent or null reads as 0. `origin` absent or null is nil, a turn the owner sent.
- Coordinator migration is `Sources/WorkspaceStorage/SQL/0016_turn_open_work.sql`; hub migration is `Hub/crates/b4hub-db/migrations/0023_turn_open_work.sql`; mirror schema version is 11. Never edit an applied migration.
- Both columns are unclocked on the Mac: the Mac is their only writer, so `b4app_record_change()` is left as it is (the pattern of `0014_connection_commands.sql`).
- State order in Swift: approve, reply, quiet with no turn, reply for a turn waiting, working for a turn not ended, failed, **working for open work above zero**, finished, quiet.
- Hub bands order: needsInput, quiet with no turn, working for a turn not ended, **working for open work above zero unless the latest turn's outcome is `failed`**, unread, quiet.
- `Tests/Fixtures/sync/attention.json` and `Tests/Fixtures/sync/push.json` are read by both languages: a task that edits one leaves both suites green.
- Nothing in `Sources/Coordinator`, the adapters or `Sources/WorkspaceUI` changes in this plan, beyond what a new `Turn` initialiser parameter with a default requires (nothing).
- Before each commit: `swift format lint --strict --recursive Sources Tests Apps Package.swift`; for hub tasks also `cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets --locked -- -D warnings` from `Hub/`.
- Hub tests: `cd Hub && source <(./scripts/test-db.sh) && cargo test --workspace --locked` (needs `./Scripts/fetch-postgres.sh` once). One `cargo test` per checkout at a time.
- The decision file takes its number from `Scripts/docs-index.sh --next` when the pull request is opened, not before.

## Review Focus

1. A row written before the columns existed (a null `openWork` in the mirror, an absent key on the wire): reads as 0, never a decode failure. Tests in Tasks 1 and 2.
2. A deleted turn's open work on the hub (`deleted_at` set): does not keep its thread working. Test in Task 3.
3. A failed latest turn with open work elsewhere on the thread: failed in Swift, `unread` on the hub, counted in the badge. Tests in Tasks 1, 3 and 4.
4. Open work ending long after the latest turn completed (more than `TURN_RECENCY_SECS`): the phone is still told. Test in Task 5.
5. A turn row with a malformed `updatedAt` reaching the new notification query: costs that row only, as today (the savepoint in `detect`). Test in Task 5.

---

### Task 1: The fields, the state rule, and the Mac's store

**Files:**
- Modify: `Sources/WorkspaceProtocol/Domain.swift` (`Turn`, about line 300)
- Modify: `Sources/WorkspaceProtocol/Attention.swift` (`ThreadActivity`, `Attention.state(of:)`)
- Create: `Sources/WorkspaceStorage/SQL/0016_turn_open_work.sql`
- Modify: `Sources/WorkspaceStorage/WorkspaceDatabase.swift` (`threadWithActivity`, about line 374)
- Test: `Tests/WorkspaceProtocolTests/TurnCodingTests.swift` (create), `Tests/WorkspaceProtocolTests/AttentionTests.swift`, `Tests/WorkspaceStorageTests/ActivityQueryTests.swift`

**Interfaces:**
- Produces: `Turn.openWork: Int` (default 0) and `Turn.origin: String?` (default nil), both initialiser parameters placed after `outcome`; `ThreadActivity.openWork: Int` (default 0, initialiser parameter after `pendingApprovals`); the rule in `Attention.state(of:)`.

- [ ] **Step 1: Write the failing tests**

`TurnCodingTests.swift`:

```swift
@Suite struct TurnCodingTests {
  private let old = #"{"id":"u1","threadId":"t1","operationId":"op1","nativeTurnId":null,"inputRef":null,"status":"terminal","submission":"acknowledged","outcome":"completed","createdAt":"2026-11-19T10:00:00Z","updatedAt":"2026-11-19T10:01:00Z"}"#

  @Test func aTurnWrittenBeforeTheFieldsReadsAsNoOpenWorkAndNoOrigin() throws {
    let turn = try JSONCoding.decoder.decode(Turn.self, from: Data(old.utf8))
    #expect(turn.openWork == 0)
    #expect(turn.origin == nil)
  }

  @Test func aNullOpenWorkReadsAsZero() throws {
    let json = old.replacingOccurrences(of: #""outcome":"completed""#, with: #""outcome":"completed","openWork":null,"origin":null"#)
    #expect(try JSONCoding.decoder.decode(Turn.self, from: Data(json.utf8)).openWork == 0)
  }

  @Test func theFieldsRoundTrip() throws {
    let turn = Turn(id: "u1", threadId: "t1", operationId: "op1", openWork: 2, origin: "task-notification")
    let back = try JSONCoding.decoder.decode(Turn.self, from: JSONCoding.encoder.encode(turn))
    #expect(back == turn)
  }
}
```

In `AttentionTests.swift`, a new test `openWorkKeepsAnEndedThreadWorking`, building threads with a hand-made `ThreadActivity` (`latestTurnStatus: .terminal`, `lastActivityAt` any):

| latest outcome | read | pending requests | openWork | expected state |
| --- | --- | --- | --- | --- |
| completed | no | 0 | 1 | `.working` |
| completed | yes | 0 | 1 | `.working` |
| failed | no | 0 | 1 | `.failed` |
| completed | no | 1 (approval) | 1 | `.approve` |
| completed | no | 0 | 0 | `.finished` |

and `#expect(!Attention.countsTowardBadge(thread))` for the first two rows, `#expect(Attention.countsTowardBadge(thread))` for the third. Also `aThreadActivityWithoutOpenWorkDecodesAsZero`: decode `{"pendingRequests":0,"lastActivityAt":"2026-11-19T10:00:00Z"}` and expect `openWork == 0`.

In `ActivityQueryTests.swift`, a new test `openWorkIsSummedOverTheThreadsTurns`: a temporary database, one connection and thread, three turns with `openWork` 2, 0 and 1; `listThreads()` gives `activity?.openWork == 3`; a thread with no turns gives 0.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter "TurnCodingTests|AttentionTests|ActivityQueryTests"`
Expected: build failure, `Turn` has no member `openWork`.

- [ ] **Step 3: Add the fields to `Turn`**

`openWork` and `origin` as stored properties and initialiser parameters. `Turn` gets an explicit `init(from:)` that decodes every existing key as today and the two new ones with `decodeIfPresent` (`openWork` falling back to 0); `encode(to:)` stays synthesized.

- [ ] **Step 4: Add `openWork` to `ThreadActivity` and the rule to `state(of:)`**

`ThreadActivity.openWork` follows `pendingApprovals` in the stored properties, the initialiser, `CodingKeys` and the lenient `init(from:)`. In `state(of:)`, `if activity.openWork > 0 { return .working }` stands directly after the failed check; update the doc comment's sentence to name it. `countsTowardBadge` needs no change (working does not count).

- [ ] **Step 5: Write migration `0016_turn_open_work.sql`**

```sql
-- Open work and origin (the runtime turns design, 2026-11-19): `openWork` is how many agents the turn
-- started are still running; `origin` is null for a turn the owner sent and the runtime's word for one
-- it started itself. Written only by the Mac that owns the thread, so neither is clocked and the 0015
-- trigger function stands as it is.
ALTER TABLE "turns" ADD COLUMN "openWork" integer NOT NULL DEFAULT 0;
ALTER TABLE "turns" ADD COLUMN "origin" text;
```

- [ ] **Step 6: Sum it in `threadWithActivity`**

Add `'openWork', ow."n"` to the `jsonb_build_object` and a lateral `CROSS JOIN LATERAL (SELECT COALESCE(sum("openWork"), 0) AS "n" FROM "turns" WHERE "threadId" = t."id") ow`. Extend the doc comment above the query.

- [ ] **Step 7: Run the tests**

Run: `swift test --filter "TurnCodingTests|AttentionTests|ActivityQueryTests|WorkspaceStorageTests"`
Expected: PASS. The migrator's own tests (any that pin the newest migration's name or count) are updated to `0016_turn_open_work` if they fail.

- [ ] **Step 8: Commit**

```bash
git add Sources/WorkspaceProtocol Sources/WorkspaceStorage Tests/WorkspaceProtocolTests Tests/WorkspaceStorageTests
git commit -m "feat(protocol): a turn carries open work and origin, and open work keeps a thread working"
```

---

### Task 2: The phone's mirror

**Files:**
- Modify: `Sources/WorkspaceMirror/MirrorSchema.swift` (`migrations`, a new `version11`)
- Modify: `Sources/WorkspaceMirror/MirrorStore.swift` (`threadWithActivity`, about line 236)
- Test: `Tests/WorkspaceMirrorTests/MirrorMigrationTests.swift`, `Tests/WorkspaceMirrorTests/MirrorActivityTests.swift`, and the mirror's apply tests (the file that tests `MirrorApply` turn inserts)

**Interfaces:**
- Consumes: `Turn.openWork`, `Turn.origin`, `ThreadActivity.openWork` (Task 1).
- Produces: mirror schema 11 with `"openWork" INTEGER` and `"origin" TEXT` on `turns`, both nullable.

- [ ] **Step 1: Write the failing tests**

- `MirrorMigrationTests`: change `#expect(MirrorSchema.version == 10)` to `11`; a new test `version11AddsOpenWorkAndOriginToTurns` that builds a version-10 file with one turn row, migrates, and expects the row to decode as a `Turn` with `openWork == 0` and `origin == nil`.
- `MirrorActivityTests`: `openWorkIsSummedOverTheThreadsTurns`, the same three-turn case as Task 1, through the mirror's thread listing.
- Apply test `aTurnInsertFromAnOlderMacReadsAsNoOpenWork`: apply a turn insert whose value has the ten old keys only, then a second insert of the same row (the conflict path that sets undeclared columns to NULL); the stored turn decodes with `openWork == 0`.
- Apply test `aTurnInsertCarriesOpenWorkAndOrigin`: an insert with `"openWork": 2, "origin": "task-notification"` stores both; a following update of column `openWork` to `0` stores 0.

- [ ] **Step 2: Run them and see them fail**

Run: `swift test --filter WorkspaceMirrorTests`
Expected: FAIL on the version expectation and the missing columns.

- [ ] **Step 3: Add `version11` and the sum**

```swift
static let version11 = [
  #"ALTER TABLE "turns" ADD COLUMN "openWork" INTEGER"#,
  #"ALTER TABLE "turns" ADD COLUMN "origin" TEXT"#,
]
```

appended to `migrations` as `(11, version11)`. In `threadWithActivity`, add `'openWork', (SELECT coalesce(sum("openWork"), 0) FROM "turns" WHERE "threadId" = t."id")` to the `json_object`, and extend the doc comment. If the mirror keeps a per-table list of declared columns for apply, add both names to the `turns` entry.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter WorkspaceMirrorTests`
Expected: PASS, apart from the five mirror tests that already fail on this machine and pass in CI (compare with a run on the base commit before judging a failure).

- [ ] **Step 5: Commit**

```bash
git add Sources/WorkspaceMirror Tests/WorkspaceMirrorTests
git commit -m "feat(mirror): schema 11 holds a turn's open work and origin"
```

---

### Task 3: The hub's columns and bands

**Files:**
- Create: `Hub/crates/b4hub-db/migrations/0023_turn_open_work.sql`
- Modify: `Hub/crates/b4hub-core/src/change.rs` (the `turns` `TableSpec`, about line 119)
- Modify: `Hub/crates/b4hub-db/src/push.rs` (`BANDS`, about line 409, and its doc comment)
- Modify: `Hub/API.md` where it lists a turn's columns or the bands rule
- Test: `Hub/crates/b4hub-db/tests/push.rs`, and the changes/snapshot test file that round-trips a turn

**Interfaces:**
- Produces: hub columns `"openWork" integer` and `"origin" text` on `turns`, accepted on insert and update and served in snapshots; `BANDS` with the open-work rule.

- [ ] **Step 1: Write the failing tests**

In `tests/push.rs`, a helper beside `turn(...)`:

```rust
fn turn_at(seq: i64, id: &str, status: &str, outcome: Option<&str>, created_at: &str, updated_at: &str, open_work: i64) -> Change
```

(the existing `turn` row plus `"createdAt"` and `"openWork"`), and:

- `open_work_keeps_an_ended_thread_working`: one thread; a terminal completed turn with `openWork` 1 gives band `working` and `needs_you_count` 0; updating `openWork` to 0 gives `unread` and count 1.
- `open_work_on_an_earlier_turn_counts`: an earlier turn with `openWork` 1 and a later terminal completed turn with 0 gives `working`.
- `a_failed_latest_turn_stays_unread_despite_open_work`: latest turn terminal failed, an earlier turn with `openWork` 1: band `unread`, count 1.
- `a_deleted_turns_open_work_does_not_count`: a turn with `openWork` 1 that is then deleted (`delete(seq, "turns", id)`), and a later terminal completed turn: band `unread`.

In the changes/snapshot tests: `a_turn_carries_open_work_and_origin`: push a turn insert with `"openWork": 2, "origin": "task-notification"`, then an update of `openWork` to `1`; the snapshot's turn has `openWork` 1 and `origin` `task-notification`. And `a_turn_without_the_new_columns_is_accepted`: the ten-key insert still applies and the snapshot shows `openWork` null.

- [ ] **Step 2: Run them and see them fail**

Run: `cd Hub && source <(./scripts/test-db.sh) && cargo test -p b4hub-db --locked`
Expected: the new tests FAIL (unknown column dropped, band `unread`).

- [ ] **Step 3: Write migration `0023_turn_open_work.sql`**

```sql
-- Open work and origin on a turn (the Mac's migration 0016): how many agents the turn started are
-- still running, and the runtime's word for a turn it started itself (null for one the owner sent).
-- Both are nullable: a Mac that predates them sends neither.
ALTER TABLE "turns" ADD COLUMN "openWork" integer;
ALTER TABLE "turns" ADD COLUMN "origin" text;
```

Follow `0021_connection_commands.sql` for anything a plain added column needs beyond this (row-level security, grants); add nothing it does not have.

- [ ] **Step 4: Add both names to the `turns` `TableSpec` columns**, after `"updatedAt"`.

- [ ] **Step 5: Change `BANDS`**

`lt` also selects `u."outcome"`. A new lateral:

```sql
CROSS JOIN LATERAL (
    SELECT COALESCE(sum(u."openWork"), 0) AS n FROM "turns" u
    WHERE u.org_id = t.org_id AND u.user_id = t.user_id AND u."threadId" = t."id"
      AND u.deleted_at IS NULL) ow
```

and one `CASE` arm directly after the `<> 'terminal'` arm: `WHEN ow.n > 0 AND lt."outcome" IS DISTINCT FROM 'failed' THEN 'working'`. Rewrite the doc comment's rule sentence to include it.

- [ ] **Step 6: Run the hub's tests and lints**

Run: `cargo test --workspace --locked && cargo fmt --all -- --check && cargo clippy --workspace --all-targets --locked -- -D warnings`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Hub
git commit -m "feat(hub): turns carry open work and origin, and open work keeps a thread in the working band"
```

---

### Task 4: The shared attention fixture

**Files:**
- Modify: `Tests/Fixtures/sync/attention.json`
- Modify: `Tests/WorkspaceProtocolTests/AttentionTests.swift` (the reference `activity` in `threadsWithActivity`, the `Variant` list)
- Test: `AttentionTests`, `ActivityQueryTests`, `MirrorActivityTests`, `AttentionModelTests`, and the hub's `bands_match_the_shared_fixture`

**Interfaces:**
- Consumes: everything from Tasks 1 to 3. No production code changes here; a failure means one of the three implementations disagrees with the fixture.

- [ ] **Step 1: Add four threads and their turns to the fixture**

Same shape as the existing rows (`conn-attn`, unpinned, unarchived). Turn rows carry `"openWork"`; existing turn rows are left without the key.

| thread | turns (oldest first) | `readTurnId` | band |
| --- | --- | --- | --- |
| `t-open-work-unread` | `u-owu1` terminal completed, `openWork` 2 | null | `working` |
| `t-open-work-earlier` | `u-owe1` terminal completed, `openWork` 1; `u-owe2` terminal completed, `openWork` 0 | null | `working` |
| `t-open-work-read` | `u-owr1` terminal completed, `openWork` 1 | `u-owr1` | `working` |
| `t-open-work-failed` | `u-owf1` terminal completed, `openWork` 1; `u-owf2` terminal failed, `openWork` 0 | null | `unread` |

Give each thread a `createdAt` and each turn `createdAt`/`updatedAt` on 2026-10-31 that no existing row uses, add the four bands to `expected.bands`, and insert the four ids into `expected.order` where the fixture's own rule puts them (pinned first, then band, then newest activity, ties by id).

- [ ] **Step 2: Teach the Swift reference implementation**

In `AttentionTests.swift`, `threadsWithActivity` sums `openWork` over each thread's turns into `ThreadActivity.openWork`. Add a `Variant` case `ignoresOpenWork` (the sum left at 0) so `fixtureExposesEveryActivityMistake` proves the fixture catches an implementation that forgets it. Update the fixture's thread and turn counts wherever a test pins them.

- [ ] **Step 3: Run every suite that reads the fixture**

Run: `swift test --filter "AttentionTests|ActivityQueryTests|MirrorActivityTests|AttentionModelTests"` and `cd Hub && cargo test -p b4hub-db --locked bands_match_the_shared_fixture`
Expected: PASS in both languages with no production change. If one fails, the fix belongs in the task that owns that implementation, not in the fixture.

- [ ] **Step 4: Commit**

```bash
git add Tests/Fixtures/sync/attention.json Tests/WorkspaceProtocolTests/AttentionTests.swift
git commit -m "test: the attention fixture holds threads with open work"
```

---

### Task 5: The phone is told when the thread comes to rest

**Files:**
- Modify: `Hub/crates/b4hub-core/src/push.rs` (`turn_reason`, its doc comment, its fixture test)
- Modify: `Hub/crates/b4hub-db/src/push.rs` (`Subject`, `subject` for `Kind::Turn`, `TurnRow`, `detect`)
- Modify: `Tests/Fixtures/sync/push.json` (`turns` cases)
- Modify: `Hub/API.md` (the notification rule)
- Test: `Hub/crates/b4hub-core/src/push.rs` (unit), `Hub/crates/b4hub-db/tests/push.rs`

**Interfaces:**
- Consumes: the hub's `openWork` column (Task 3), `turn_at` (Task 3).
- Produces: `pub fn turn_reason(status: &str, outcome: Option<&str>, recent: bool, at_rest: bool) -> Option<Reason>`; `Subject` gains `row_id: String`, the row the notification is keyed by.

The rule, for a turn row `X` a push touched, in thread `T`:

1. `X` is terminal, failed and recent: `Failed`, keyed by `X`. Open work does not matter.
2. Otherwise let `L` be `T`'s latest live turn (greatest `createdAt`, ties by greatest `id`, as in `BANDS`) and `W` the sum of `openWork` over `T`'s live turns. If `X` is recent, `L` is terminal and completed, and `W` is 0: `Replied`, keyed by `L`.
3. Otherwise nothing.

"Recent" is judged on `X`, the row that changed, so open work ending long after `L` completed still notifies. The ledger's `ON CONFLICT DO NOTHING` on `L`'s key keeps it to once.

- [ ] **Step 1: Write the failing tests**

Unit, in `core/push.rs`: the fixture loop reads `atRest` (`case.get("atRest").and_then(Value::as_bool).unwrap_or(true)`) and passes it. Add to `push.json` `turns`: `{"status":"terminal","outcome":"completed","recent":true,"atRest":false,"reason":null}`, `{"status":"terminal","outcome":"failed","recent":true,"atRest":false,"reason":"failed"}`, `{"status":"terminal","outcome":"completed","recent":false,"atRest":true,"reason":null}`, and `{"status":"running","outcome":null,"recent":true,"atRest":false,"reason":null}`. Use the fixture's own spelling for the reason values.

Database, in `tests/push.rs` (one thread from `with_thread`, timestamps from `stamp`):

- `a_completed_turn_with_open_work_waits_for_rest`: push `T` terminal completed with `openWork` 1: no notification, empty ledger. Push an update of `T`'s `openWork` to 0 with a fresh `updatedAt`: one `Replied` keyed `turn:T`.
- `the_wake_up_turn_is_the_one_that_notifies`: `T` completed with `openWork` 1; then, in one batch, insert `R` running (later `createdAt`) and set `T.openWork` to 0: nothing. Then `R` terminal completed: one `Replied` keyed `turn:R`; the ledger has no row for `T`.
- `a_turn_that_ends_while_another_has_open_work_does_not_notify`: `T` completed with `openWork` 1, `R` terminal completed with 0: nothing.
- `a_failed_turn_notifies_despite_open_work`: `T` completed with `openWork` 1, `R` terminal failed: one `Failed` keyed `turn:R`.
- `open_work_ending_long_after_the_latest_turn_still_notifies`: `T` completed with `openWork` 1; `L` terminal completed with an `updatedAt` older than `TURN_RECENCY_SECS`; then `T.openWork` to 0 with a fresh `updatedAt`: one `Replied` keyed `turn:L`.
- `rest_notifies_once`: after the first test's notification, a further fresh update of `T` (any column) sends nothing.
- `a_malformed_timestamp_costs_only_its_row`: a batch with a turn whose `updatedAt` is `"soon"` and a second, well-formed completed turn in another thread: the second notifies.

The existing `completed_and_failed_turns_notify_cancelled_does_not`, `history_upload_does_not_notify`, `outcome_in_a_later_batch_notifies_once` and `retry_and_later_update_do_not_renotify` must pass unchanged.

- [ ] **Step 2: Run them and see them fail**

Run: `cargo test --workspace --locked`
Expected: build failure on `turn_reason`'s arity, then the new database tests FAIL.

- [ ] **Step 3: Change `turn_reason`**

`failed` gives `Failed` when terminal and recent, whatever `at_rest` is; `completed` gives `Replied` only when terminal, recent and `at_rest`. Rewrite the doc comment to say so.

- [ ] **Step 4: Change `subject` and `detect`**

`subject` for `Kind::Turn` reads, for the touched row: its own status, outcome and `recent`; the thread's title and deleted flag; the thread's latest live turn's id, status and outcome; and the thread's summed open work. It returns a `Subject` whose `row_id` is the touched row for rule 1 and the latest turn for rule 2, calling `turn_reason` with the latest turn's status and outcome, the touched row's `recent`, and `at_rest = (sum == 0)`. For `Kind::Request`, `row_id` is the request's own id. `detect` inserts into `notifications_sent`, and builds the key, from `subject.row_id` instead of the touched `row_id`. Keep the whole read inside the existing per-row savepoint.

- [ ] **Step 5: Run the hub's tests and lints**

Run: `cargo test --workspace --locked && cargo fmt --all -- --check && cargo clippy --workspace --all-targets --locked -- -D warnings`
Expected: PASS. Then `swift test --filter ThreadLinkTests` (it reads `push.json`'s other sections): PASS.

- [ ] **Step 6: Commit**

```bash
git add Hub Tests/Fixtures/sync/push.json
git commit -m "feat(hub): a reply notifies when its thread has come to rest"
```

---

### Task 6: Records

**Files:**
- Create: `docs/decisions/D-NNN-open-work-and-origin.md` (number from `Scripts/docs-index.sh --next` when the pull request is opened)
- Create: `docs/verification/2026-11-19-open-work-fields-and-state.md` (use the date the work is verified)
- Modify: `docs/milestones.md`, `docs/compatibility.md` (mirror schema 11, coordinator migration 0016, hub migration 0023), `AGENTS.md` (the "Layout" bullet that names the synced `viewSettings` migrations is the model: one sentence naming `openWork`, `origin`, the three migrations and the at-rest notification rule, in the Notifications bullet)

- [ ] **Step 1: Write the decision**, in the log's style (read a recent file first): what `openWork` and `origin` are, that nothing writes them until the coordinator change, the state rule's place, the hub's band rule and its failed exception, the at-rest notification rule with its three cases, and that it amends D-204 (thread state) and the decision that set the turn notification rule (find it by searching `docs/decisions` for `turn_reason` or "Replied").
- [ ] **Step 2: Write the gate record**: the commands run and their results, the fixture cases added, and under "Not checked": anything on a device, since no row carries open work yet.
- [ ] **Step 3: Run** `Scripts/docs-index.sh --check`, the full `swift test` (split as AGENTS.md describes if the machine needs it) and the hub's full test and lint commands. Expected: PASS, apart from the six tests that already fail locally and pass in CI.
- [ ] **Step 4: Commit**

```bash
git add docs AGENTS.md
git commit -m "docs: open work and origin (D-NNN)"
```
