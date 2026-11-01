//! Change ingest, materialisation, and the feed against a real PostgreSQL. Run with
//! `source <(./scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use b4hub_core::change::{table_spec, Change, ChangeOp, SYNCED_TABLES};
use b4hub_core::hlc::Hlc;
use b4hub_db::changes::{self, PushOutcome, Rejected};
use b4hub_db::devices::{AuthedDevice, Platform};
use b4hub_db::Db;
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;

fn insert(seq: i64, table: &str, row: &str, value: Value) -> Change {
    Change {
        device_seq: seq,
        wall: 1_761_900_000_000 + seq,
        table: table.into(),
        row_id: row.into(),
        op: ChangeOp::Insert,
        column: None,
        value: Some(value),
        hlc: None,
    }
}

/// `push`, reduced to `acceptedThrough`.
async fn push_through(app: &Db, who: &AuthedDevice, batch: &[Change]) -> b4hub_db::Result<i64> {
    changes::push(app, who, batch)
        .await
        .map(|outcome| outcome.accepted_through)
}

fn update(seq: i64, table: &str, row: &str, column: &str, value: Option<Value>) -> Change {
    Change {
        op: ChangeOp::Update,
        column: Some(column.into()),
        value,
        ..insert(seq, table, row, Value::Null)
    }
}

fn delete(seq: i64, table: &str, row: &str) -> Change {
    Change {
        op: ChangeOp::Delete,
        value: None,
        ..insert(seq, table, row, Value::Null)
    }
}

/// One row's columns as JSON (`null` when the row is absent), read under `who`'s tenant context.
/// `columns` are the quoted column names to read.
async fn row(app: &Db, who: &AuthedDevice, table: &str, key: &str, id: &str) -> Option<Value> {
    let mut tx = app.tenant_tx(who.org_id).await.unwrap();
    let found: Option<Value> = sqlx::query_scalar(&format!(
        "SELECT to_jsonb(t) FROM \"{table}\" t WHERE org_id = $1 AND \"{key}\" = $2"
    ))
    .bind(who.org_id)
    .bind(id)
    .fetch_optional(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    found
}

async fn count(app: &Db, who: &AuthedDevice, table: &str) -> i64 {
    let mut tx = app.tenant_tx(who.org_id).await.unwrap();
    let n = sqlx::query_scalar(&format!("SELECT count(*) FROM \"{table}\""))
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    n
}

async fn thread_fixture(app: &Db, who: &AuthedDevice, first_seq: i64) {
    let batch = vec![
        insert(
            first_seq,
            "connections",
            "conn-1",
            json!({"id": "conn-1", "kind": "codex", "label": "Codex"}),
        ),
        insert(
            first_seq + 1,
            "threads",
            "thread-1",
            json!({"id": "thread-1", "connectionId": "conn-1", "title": "Original", "pinned": true}),
        ),
    ];
    push_through(app, who, &batch).await.unwrap();
}

#[sqlx::test(migrations = false)]
async fn push_materialises_and_is_idempotent(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    let batch = common::filtered_fixture();

    let accepted = push_through(&app, &device, &batch).await.unwrap();
    assert_eq!(accepted, 12);
    assert_eq!(count(&app, &device, "changes").await, 12);
    // Every fixture change carries its clock, and the hub stores it as sent.
    let stored = changes::pull(&app, &device, 0, 1000).await.unwrap();
    for (sent, kept) in batch.iter().zip(&stored.changes) {
        assert!(sent.hlc.is_some(), "fixture change {}", sent.device_seq);
        assert_eq!(Some(&kept.hlc), sent.hlc.as_ref());
    }

    let thread = row(&app, &device, "threads", "id", "thread-1")
        .await
        .expect("the thread is mirrored");
    assert_eq!(thread["title"], "Renamed");
    assert_eq!(thread["pinned"], false);
    assert_eq!(thread["connectionId"], "conn-1");
    assert_eq!(thread["org_id"], device.org_id.to_string());
    assert_eq!(thread["user_id"], device.user_id.to_string());
    assert_eq!(thread["device_id"], device.device_id.to_string());
    assert!(
        row(&app, &device, "drafts", "threadId", "thread-1")
            .await
            .is_none(),
        "the draft was inserted then deleted"
    );
    assert_eq!(count(&app, &device, "turns").await, 2);
    assert_eq!(count(&app, &device, "displayItems").await, 4);
    assert_eq!(count(&app, &device, "runtimeRequests").await, 1);

    let connection = row(&app, &device, "connections", "id", "conn-1")
        .await
        .unwrap();
    assert_eq!(
        connection["capabilities"]["permission_decisions"],
        "supported"
    );
    assert_eq!(connection["profileRevision"], 1);
    for blanked in ["authReference", "localServerId", "target"] {
        assert_eq!(connection[blanked], Value::Null, "{blanked}");
    }
    let big = row(&app, &device, "displayItems", "id", "item-3")
        .await
        .unwrap();
    assert_eq!(big["payload"]["truncated"], true);
    assert_eq!(big["sequence"], 3);

    // A duplicate batch is accepted without being applied again: remove a row the batch
    // inserted, push the batch once more, and the row stays removed.
    let mut tx = app.tenant_tx(device.org_id).await.unwrap();
    sqlx::query("DELETE FROM turns WHERE \"id\" = 'turn-1'")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let again = push_through(&app, &device, &batch).await.unwrap();
    assert_eq!(again, 12);
    assert_eq!(count(&app, &device, "changes").await, 12);
    assert!(row(&app, &device, "turns", "id", "turn-1").await.is_none());
    assert_eq!(count(&app, &device, "turns").await, 1);

    // acceptedThrough is the batch's highest device sequence, wherever it sits in the batch,
    // and an empty batch reports what the device has already had accepted.
    let mut shuffled = batch[..3].to_vec();
    shuffled.reverse();
    assert_eq!(push_through(&app, &device, &shuffled).await.unwrap(), 3);
    assert_eq!(push_through(&app, &device, &[]).await.unwrap(), 12);
}

#[sqlx::test(migrations = false)]
async fn an_insert_upserts_only_the_columns_it_carries(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    thread_fixture(&app, &device, 1).await;

    // A later insert of the same row names two columns: those change, the others stay. The key
    // comes from the change's rowId and ownership columns from the token, whatever the value
    // claims.
    let sneaky = insert(
        3,
        "threads",
        "thread-1",
        json!({
            "id": "someone-else", "title": "Renamed", "connectionId": "conn-1",
            "org_id": "00000000-0000-0000-0000-000000000001",
            "user_id": "00000000-0000-0000-0000-000000000002",
            "bogus": "ignored",
        }),
    );
    push_through(&app, &device, &[sneaky]).await.unwrap();
    let thread = row(&app, &device, "threads", "id", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["title"], "Renamed");
    assert_eq!(thread["pinned"], true, "a column the insert did not carry");
    assert_eq!(thread["org_id"], device.org_id.to_string());
    assert_eq!(thread["user_id"], device.user_id.to_string());
    assert!(row(&app, &device, "threads", "id", "someone-else")
        .await
        .is_none());
    assert_eq!(count(&app, &device, "threads").await, 1);
}

#[sqlx::test(migrations = false)]
async fn updates_set_one_column_and_null_clears_it(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    thread_fixture(&app, &device, 1).await;

    let batch = vec![
        update(3, "threads", "thread-1", "pinned", Some(json!(false))),
        update(4, "threads", "thread-1", "context", Some(json!("notes"))),
        update(5, "threads", "thread-1", "title", None),
    ];
    push_through(&app, &device, &batch).await.unwrap();
    let thread = row(&app, &device, "threads", "id", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["pinned"], false);
    assert_eq!(thread["context"], "notes");
    assert_eq!(thread["title"], Value::Null);
    assert_eq!(thread["connectionId"], "conn-1");

    // A jsonb column takes a JSON value whole.
    let capabilities = json!({"streaming": false, "list": [1, 2]});
    push_through(
        &app,
        &device,
        &[update(
            6,
            "connections",
            "conn-1",
            "capabilities",
            Some(capabilities.clone()),
        )],
    )
    .await
    .unwrap();
    let connection = row(&app, &device, "connections", "id", "conn-1")
        .await
        .unwrap();
    assert_eq!(connection["capabilities"], capabilities);
}

#[sqlx::test(migrations = false)]
async fn changes_that_cannot_apply_are_recorded_but_skipped(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    thread_fixture(&app, &device, 1).await;

    let batch = vec![
        // Not a synced table (the Mac never uploads localServers).
        insert(3, "localServers", "ls-1", json!({"id": "ls-1"})),
        insert(4, "nonsense", "x", json!({"id": "x"})),
        // Parents that do not exist in this org.
        insert(
            5,
            "turns",
            "turn-orphan",
            json!({"id": "turn-orphan", "threadId": "no-such-thread"}),
        ),
        insert(
            6,
            "displayItems",
            "item-orphan",
            json!({"id": "item-orphan", "threadId": "no-such-thread"}),
        ),
        insert(
            7,
            "runtimeRequests",
            "req-orphan",
            json!({"id": "req-orphan"}),
        ),
        insert(
            8,
            "drafts",
            "no-such-thread",
            json!({"threadId": "no-such-thread", "text": "x"}),
        ),
        insert(
            9,
            "threads",
            "thread-orphan",
            json!({"id": "thread-orphan", "connectionId": "no-such-connection"}),
        ),
        // Malformed: an insert whose value is not an object, an update with no column or an
        // unknown column or the key column, and a value of the wrong type.
        insert(10, "threads", "thread-1", json!("not an object")),
        Change {
            column: None,
            ..update(11, "threads", "thread-1", "x", Some(json!("v")))
        },
        update(12, "threads", "thread-1", "nope", Some(json!("v"))),
        update(13, "threads", "thread-1", "id", Some(json!("renamed"))),
        update(14, "threads", "thread-1", "org_id", Some(json!("x"))),
        update(15, "threads", "thread-1", "pinned", Some(json!("maybe"))),
        // An update and a delete of rows that are not there.
        update(16, "threads", "no-such-row", "title", Some(json!("x"))),
        delete(17, "turns", "no-such-row"),
        // And one that applies, after all the failures: the batch is not poisoned.
        update(
            18,
            "threads",
            "thread-1",
            "title",
            Some(json!("Still applied")),
        ),
    ];
    let accepted = push_through(&app, &device, &batch).await.unwrap();
    assert_eq!(accepted, 18);
    assert_eq!(count(&app, &device, "changes").await, 2 + 16);

    for (table, key, id) in [
        ("turns", "id", "turn-orphan"),
        ("displayItems", "id", "item-orphan"),
        ("runtimeRequests", "id", "req-orphan"),
        ("drafts", "threadId", "no-such-thread"),
        ("threads", "id", "thread-orphan"),
        ("threads", "id", "renamed"),
        ("threads", "id", "no-such-row"),
    ] {
        assert!(
            row(&app, &device, table, key, id).await.is_none(),
            "{table} {id}"
        );
    }
    let thread = row(&app, &device, "threads", "id", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["title"], "Still applied");
    assert_eq!(
        thread["pinned"], true,
        "a wrongly typed value changed nothing"
    );
    assert_eq!(thread["org_id"], device.org_id.to_string());
}

#[sqlx::test(migrations = false)]
async fn a_user_cannot_touch_another_users_rows(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let alice = common::enrolled(&admin, &app, "alice").await;
    let bob = common::enrolled(&admin, &app, "bob").await;
    assert_eq!(alice.org_id, bob.org_id);
    thread_fixture(&app, &alice, 1).await;

    // Bob's device writes with alice's row ids, in the same org.
    let batch = vec![
        insert(
            1,
            "connections",
            "conn-1",
            json!({"id": "conn-1", "label": "Hijacked"}),
        ),
        // Alice's thread as a parent does not count for bob.
        insert(
            2,
            "turns",
            "turn-bob",
            json!({"id": "turn-bob", "threadId": "thread-1"}),
        ),
        update(3, "threads", "thread-1", "title", Some(json!("Hijacked"))),
        delete(4, "threads", "thread-1"),
    ];
    assert_eq!(push_through(&app, &bob, &batch).await.unwrap(), 4);

    let connection = row(&app, &alice, "connections", "id", "conn-1")
        .await
        .unwrap();
    assert_eq!(connection["label"], "Codex");
    assert_eq!(connection["user_id"], alice.user_id.to_string());
    let thread = row(&app, &alice, "threads", "id", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["title"], "Original");
    assert!(row(&app, &alice, "turns", "id", "turn-bob").await.is_none());
}

#[sqlx::test(migrations = false)]
async fn pull_pages_and_is_scoped_to_the_user(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    let other = common::enrolled(&admin, &app, "alice").await;
    push_through(&app, &device, &common::filtered_fixture())
        .await
        .unwrap();

    let first = changes::pull(&app, &device, 0, 5).await.unwrap();
    assert_eq!(first.changes.len(), 5);
    assert!(first.more);
    assert_eq!(first.next, 5);
    assert_eq!(
        first.changes.iter().map(|c| c.hub_seq).collect::<Vec<_>>(),
        vec![1, 2, 3, 4, 5]
    );
    assert!(first
        .changes
        .iter()
        .all(|c| c.device_id == device.device_id));
    assert_eq!(first.changes[0].table, "connections");
    assert_eq!(first.changes[0].device_seq, 1);
    assert_eq!(first.changes[1].row_id, "thread-1");

    let rest = changes::pull(&app, &device, first.next, 1000)
        .await
        .unwrap();
    assert_eq!(rest.changes.len(), 7);
    assert!(!rest.more);
    assert_eq!(rest.next, 12);
    assert_eq!(rest.changes[4].op, ChangeOp::Update);
    assert_eq!(rest.changes[4].column.as_deref(), Some("title"));
    assert_eq!(rest.changes[6].op, ChangeOp::Delete);
    assert_eq!(rest.changes[6].value, None);
    let truncated = rest
        .changes
        .iter()
        .find(|c| c.row_id == "item-3")
        .and_then(|c| c.value.as_ref())
        .unwrap();
    assert_eq!(truncated["payload"]["truncated"], true);

    // A page that ends exactly at the last change is not "more".
    let exact = changes::pull(&app, &device, 5, 7).await.unwrap();
    assert_eq!(
        (exact.changes.len(), exact.more, exact.next),
        (7, false, 12)
    );
    // Nothing after the end: an empty page keeps the cursor.
    let empty = changes::pull(&app, &device, 12, 1000).await.unwrap();
    assert!(empty.changes.is_empty());
    assert_eq!((empty.next, empty.more), (12, false));
    // A limit of zero is clamped, not an error.
    assert_eq!(
        changes::pull(&app, &device, 0, 0)
            .await
            .unwrap()
            .changes
            .len(),
        1
    );

    // Another user in the same org sees none of it.
    let theirs = changes::pull(&app, &other, 0, 1000).await.unwrap();
    assert!(theirs.changes.is_empty());
    assert_eq!(theirs.next, 0);

    // The same device id's rows are the device's own: the feed is scoped by user, so a second
    // device of the same user would see this device's changes.
    let second = {
        let seeded = b4hub_db::orgs::find_user(&admin, device.org_id, "blove")
            .await
            .unwrap()
            .unwrap();
        let code = b4hub_db::devices::create_enrollment_code(
            &admin,
            device.org_id,
            seeded,
            std::time::Duration::from_secs(600),
        )
        .await
        .unwrap();
        let enrolled = b4hub_db::devices::redeem(&app, &code, "phone", "ios")
            .await
            .unwrap();
        AuthedDevice {
            org_id: enrolled.org_id,
            user_id: enrolled.user_id,
            device_id: enrolled.device_id,
            platform: Platform::Ios,
        }
    };
    let phone = changes::pull(&app, &second, 0, 1000).await.unwrap();
    assert_eq!(phone.changes.len(), 12);
    assert!(phone
        .changes
        .iter()
        .all(|c| c.device_id == device.device_id));
}

#[sqlx::test(migrations = false)]
async fn another_org_sees_nothing_of_the_feed_or_the_mirror(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    let outsider = common::enrolled_in(&admin, &app, "other", "eve").await;
    push_through(&app, &device, &common::filtered_fixture())
        .await
        .unwrap();

    let page = changes::pull(&app, &outsider, 0, 1000).await.unwrap();
    assert!(page.changes.is_empty());
    for table in std::iter::once("changes").chain(SYNCED_TABLES) {
        assert_eq!(count(&app, &outsider, table).await, 0, "{table}");
        // The fixture's draft is inserted and then deleted, and it has no projects.
        if !["drafts", "projects", "projectFolders"].contains(&table) {
            assert!(count(&app, &device, table).await > 0, "{table}");
        }
    }
    // No tenant context at all: nothing either.
    for table in std::iter::once("changes")
        .chain(SYNCED_TABLES)
        .chain(["column_clocks"])
    {
        let n: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM \"{table}\""))
            .fetch_one(&app.pool)
            .await
            .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    // The outsider reusing the same device sequence numbers and row ids is independent.
    let accepted = push_through(&app, &outsider, &common::filtered_fixture())
        .await
        .unwrap();
    assert_eq!(accepted, 12);
    assert_eq!(count(&app, &outsider, "threads").await, 1);
    assert_eq!(count(&app, &device, "changes").await, 12);
}

#[sqlx::test(migrations = false)]
async fn mirrored_columns_are_the_macs_columns(pool: PgPool) {
    let (admin, _app) = common::migrated(&pool).await;
    for name in SYNCED_TABLES {
        let spec = table_spec(name).unwrap();
        let mut expected: Vec<String> = spec.columns.iter().map(|c| c.to_string()).collect();
        expected.extend(["org_id", "user_id", "device_id", "owner_device_id"].map(String::from));
        expected.sort();
        let mut actual: Vec<String> = sqlx::query_scalar(
            "SELECT column_name::text FROM information_schema.columns \
             WHERE table_schema = 'public' AND table_name = $1",
        )
        .bind(name)
        .fetch_all(&admin.pool)
        .await
        .unwrap();
        actual.sort();
        assert_eq!(actual, expected, "{name}");
        let key_nullable: String = sqlx::query_scalar(
            "SELECT is_nullable::text FROM information_schema.columns \
             WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        )
        .bind(name)
        .bind(spec.key)
        .fetch_one(&admin.pool)
        .await
        .unwrap();
        assert_eq!(key_nullable, "NO", "{name} key");
    }
}

#[sqlx::test(migrations = false)]
async fn row_level_security_is_forced_on_every_sync_table(pool: PgPool) {
    let (admin, _app) = common::migrated(&pool).await;
    for table in std::iter::once("changes")
        .chain(SYNCED_TABLES)
        .chain(["column_clocks"])
    {
        let (enabled, forced): (bool, bool) = sqlx::query_as(
            "SELECT relrowsecurity, relforcerowsecurity FROM pg_class \
             WHERE relname = $1 AND relnamespace = 'public'::regnamespace",
        )
        .bind(table)
        .fetch_one(&admin.pool)
        .await
        .unwrap();
        assert!(enabled && forced, "{table}");
    }
}

#[sqlx::test(migrations = false)]
async fn two_devices_pushing_at_once_all_land_in_one_order(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let alice = common::enrolled(&admin, &app, "alice").await;
    let bob = common::enrolled(&admin, &app, "bob").await;

    let batch_for = |offset: i64| -> Vec<Change> {
        (1..=40)
            .map(|n| {
                insert(
                    n,
                    "connections",
                    &format!("c-{offset}-{n}"),
                    json!({"label": n}),
                )
            })
            .collect()
    };
    let (a, b) = (batch_for(1), batch_for(2));
    let (app_a, app_b) = (app.clone(), app.clone());
    let task_a = tokio::spawn(async move { push_through(&app_a, &alice, &a).await });
    let task_b = tokio::spawn(async move { push_through(&app_b, &bob, &b).await });
    assert_eq!(task_a.await.unwrap().unwrap(), 40);
    assert_eq!(task_b.await.unwrap().unwrap(), 40);

    // Each user reads their own 40, in increasing order.
    for who in [&alice, &bob] {
        let page = changes::pull(&app, who, 0, 1000).await.unwrap();
        assert_eq!(page.changes.len(), 40);
        assert!(page.changes.windows(2).all(|w| w[0].hub_seq < w[1].hub_seq));
    }
    assert_eq!(count(&app, &alice, "changes").await, 80);
}

// ---- Task 5: clocks, ownership, the write rule, per-change rejection, scrubbing ----

const T0: i64 = 1_761_900_000_000;
const MAC_CLOCK: &str = "mac-device";
const PHONE_CLOCK: &str = "phone-device";

/// `change` stamped `offset_ms` after `T0` by the clock of `who`.
fn at(change: Change, offset_ms: i64, who: &str) -> Change {
    Change {
        wall: T0 + offset_ms,
        hlc: Some(Hlc::new((T0 + offset_ms) as u64, 0, who).to_string()),
        ..change
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// A Mac and a phone of one user, and a thread the Mac inserted at `T0 + 100`.
async fn mac_and_phone(admin: &Db, app: &Db) -> (AuthedDevice, AuthedDevice) {
    let mac = common::enrolled(admin, app, "blove").await;
    let phone = common::enrolled_as(admin, app, "blove", "ios").await;
    assert_eq!((mac.user_id, mac.org_id), (phone.user_id, phone.org_id));
    assert_eq!(
        (mac.platform, phone.platform),
        (Platform::Macos, Platform::Ios)
    );
    let batch = vec![
        at(
            insert(
                1,
                "connections",
                "conn-1",
                json!({"id": "conn-1", "label": "Codex"}),
            ),
            50,
            MAC_CLOCK,
        ),
        at(
            insert(
                2,
                "threads",
                "thread-1",
                json!({"id": "thread-1", "connectionId": "conn-1", "title": "Original",
                       "pinned": false, "continuity": "native"}),
            ),
            100,
            MAC_CLOCK,
        ),
    ];
    push_through(app, &mac, &batch).await.unwrap();
    (mac, phone)
}

async fn title(app: &Db, who: &AuthedDevice) -> Value {
    row(app, who, "threads", "id", "thread-1").await.unwrap()["title"].clone()
}

#[sqlx::test(migrations = false)]
async fn phone_title_edit_applies_and_later_mac_edit_wins(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;

    let from_phone = at(
        update(
            1,
            "threads",
            "thread-1",
            "title",
            Some(json!("Phone title")),
        ),
        200,
        PHONE_CLOCK,
    );
    let outcome = changes::push(&app, &phone, &[from_phone]).await.unwrap();
    assert_eq!(
        outcome,
        PushOutcome {
            accepted_through: 1,
            rejected: vec![]
        }
    );
    assert_eq!(title(&app, &mac).await, "Phone title");

    let from_mac = at(
        update(3, "threads", "thread-1", "title", Some(json!("Mac title"))),
        300,
        MAC_CLOCK,
    );
    push_through(&app, &mac, &[from_mac]).await.unwrap();
    assert_eq!(title(&app, &mac).await, "Mac title");
}

#[sqlx::test(migrations = false)]
async fn stale_phone_edit_loses(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;

    let from_mac = at(
        update(3, "threads", "thread-1", "title", Some(json!("Mac title"))),
        500,
        MAC_CLOCK,
    );
    push_through(&app, &mac, &[from_mac]).await.unwrap();

    // The phone edited earlier by its clock but pushed later: it loses, yet stays in the log.
    let stale = at(
        update(1, "threads", "thread-1", "title", Some(json!("Stale"))),
        300,
        PHONE_CLOCK,
    );
    let outcome = changes::push(&app, &phone, &[stale]).await.unwrap();
    assert_eq!(
        outcome,
        PushOutcome {
            accepted_through: 1,
            rejected: vec![]
        }
    );
    assert_eq!(title(&app, &mac).await, "Mac title");
    assert_eq!(count(&app, &mac, "changes").await, 4);
    let page = changes::pull(&app, &mac, 0, 1000).await.unwrap();
    assert_eq!(page.changes.last().unwrap().value, Some(json!("Stale")));
}

#[sqlx::test(migrations = false)]
async fn phone_cannot_write_mac_only_columns(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;
    let before = count(&app, &mac, "changes").await;

    let batch = vec![
        at(
            update(
                1,
                "threads",
                "thread-1",
                "continuity",
                Some(json!("forged")),
            ),
            200,
            PHONE_CLOCK,
        ),
        at(
            insert(
                2,
                "turns",
                "turn-p",
                json!({"id": "turn-p", "threadId": "thread-1"}),
            ),
            210,
            PHONE_CLOCK,
        ),
        // A phone cannot write projectId (clocked, but Mac-only), delete, or touch a table the
        // list does not name.
        at(
            update(3, "threads", "thread-1", "projectId", Some(json!("p-1"))),
            220,
            PHONE_CLOCK,
        ),
        at(delete(4, "threads", "thread-1"), 230, PHONE_CLOCK),
        at(
            update(5, "connections", "conn-1", "label", Some(json!("Forged"))),
            240,
            PHONE_CLOCK,
        ),
        // A writable column in the same batch still applies.
        at(
            update(6, "threads", "thread-1", "pinned", Some(json!(true))),
            250,
            PHONE_CLOCK,
        ),
    ];
    let outcome = changes::push(&app, &phone, &batch).await.unwrap();
    assert_eq!(outcome.accepted_through, 6);
    assert_eq!(
        outcome.rejected,
        (1..=5)
            .map(|device_seq| Rejected {
                device_seq,
                code: "column_not_writable"
            })
            .collect::<Vec<_>>()
    );
    // Only the writable change reached the log; the refused ones are invisible to other devices.
    assert_eq!(count(&app, &mac, "changes").await, before + 1);
    assert!(row(&app, &mac, "turns", "id", "turn-p").await.is_none());
    let thread = row(&app, &mac, "threads", "id", "thread-1").await.unwrap();
    assert_eq!(thread["continuity"], "native");
    assert_eq!(thread["pinned"], true);
    assert_eq!(thread["projectId"], Value::Null);

    // The same changes from the Mac work.
    let from_mac: Vec<Change> = batch
        .into_iter()
        .take(3)
        .enumerate()
        .map(|(n, change)| Change {
            device_seq: 10 + n as i64,
            ..change
        })
        .collect();
    let outcome = changes::push(&app, &mac, &from_mac).await.unwrap();
    assert!(outcome.rejected.is_empty());
    let thread = row(&app, &mac, "threads", "id", "thread-1").await.unwrap();
    assert_eq!(thread["continuity"], "forged");
    assert_eq!(thread["projectId"], "p-1");
    assert!(row(&app, &mac, "turns", "id", "turn-p").await.is_some());
}

#[sqlx::test(migrations = false)]
async fn a_phone_may_insert_a_draft_and_clear_it(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;
    let batch = vec![
        at(
            insert(
                1,
                "drafts",
                "thread-1",
                json!({"threadId": "thread-1", "text": "hello", "updatedAt": "t"}),
            ),
            200,
            PHONE_CLOCK,
        ),
        at(
            update(2, "drafts", "thread-1", "text", Some(json!(""))),
            210,
            PHONE_CLOCK,
        ),
    ];
    let outcome = changes::push(&app, &phone, &batch).await.unwrap();
    assert!(outcome.rejected.is_empty());
    let draft = row(&app, &mac, "drafts", "threadId", "thread-1")
        .await
        .unwrap();
    assert_eq!(draft["text"], "", "cleared, not NULL and not deleted");
}

#[sqlx::test(migrations = false)]
async fn an_insert_counts_per_clocked_column_at_its_clock(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;
    let rename = at(
        update(
            1,
            "threads",
            "thread-1",
            "title",
            Some(json!("Phone title")),
        ),
        400,
        PHONE_CLOCK,
    );
    push_through(&app, &phone, &[rename]).await.unwrap();

    // The Mac re-sends the whole row, stamped before the phone's edit: the title keeps the
    // phone's value, the unclocked columns take the insert's.
    let resend = at(
        insert(
            3,
            "threads",
            "thread-1",
            json!({"id": "thread-1", "connectionId": "conn-1", "title": "Old",
                   "continuity": "resumed", "pinned": true}),
        ),
        300,
        MAC_CLOCK,
    );
    push_through(&app, &mac, &[resend]).await.unwrap();
    let thread = row(&app, &mac, "threads", "id", "thread-1").await.unwrap();
    assert_eq!(thread["title"], "Phone title");
    assert_eq!(thread["continuity"], "resumed");
    assert_eq!(
        thread["pinned"], true,
        "pinned was last clocked at the first insert"
    );

    // Stamped after it, the insert's title wins.
    let resend = at(
        insert(
            4,
            "threads",
            "thread-1",
            json!({"id": "thread-1", "connectionId": "conn-1", "title": "Newest"}),
        ),
        500,
        MAC_CLOCK,
    );
    push_through(&app, &mac, &[resend]).await.unwrap();
    assert_eq!(title(&app, &mac).await, "Newest");
}

#[sqlx::test(migrations = false)]
async fn a_change_without_a_clock_gets_the_wall_derived_one(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let mac = common::enrolled(&admin, &app, "blove").await;
    let bare = insert(1, "connections", "c", json!({"id": "c"}));
    push_through(&app, &mac, std::slice::from_ref(&bare))
        .await
        .unwrap();
    let page = changes::pull(&app, &mac, 0, 10).await.unwrap();
    assert_eq!(
        page.changes[0].hlc,
        Hlc::derived(bare.wall, &mac.device_id.to_string()).to_string()
    );
}

#[sqlx::test(migrations = false)]
async fn push_clamps_a_clock_far_ahead(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, phone) = mac_and_phone(&admin, &app).await;

    let now = now_ms();
    let hour_ahead = Hlc::new((now + 3_600_000) as u64, 5, PHONE_CLOCK);
    let ahead = Change {
        hlc: Some(hour_ahead.to_string()),
        wall: now,
        ..update(
            1,
            "threads",
            "thread-1",
            "title",
            Some(json!("From the future")),
        )
    };
    // Exactly at the limit is kept as sent.
    let edge = Hlc::new((now + 290_000) as u64, 1, PHONE_CLOCK);
    let at_edge = Change {
        hlc: Some(edge.to_string()),
        ..update(2, "threads", "thread-1", "pinned", Some(json!(true)))
    };
    push_through(&app, &phone, &[ahead, at_edge]).await.unwrap();
    let stored = changes::pull(&app, &mac, 0, 1000).await.unwrap();
    let kept: Vec<&str> = stored.changes[2..].iter().map(|c| c.hlc.as_str()).collect();
    let clamped = Hlc::parse(kept[0]).unwrap();
    assert!(clamped.millis() as i64 <= now_ms() + 1_000, "{clamped}");
    assert!(clamped.millis() as i64 >= now, "{clamped}");
    assert_eq!((clamped.counter(), clamped.device_id()), (0, PHONE_CLOCK));
    assert_eq!(kept[1], edge.as_str());

    // The clamped clock cannot beat the Mac's next honest edit.
    let honest = at(
        update(3, "threads", "thread-1", "title", Some(json!("Mac title"))),
        0,
        MAC_CLOCK,
    );
    let honest = Change {
        hlc: Some(Hlc::new((now_ms() + 5_000) as u64, 0, MAC_CLOCK).to_string()),
        ..honest
    };
    push_through(&app, &mac, &[honest]).await.unwrap();
    assert_eq!(title(&app, &mac).await, "Mac title");
}

#[sqlx::test(migrations = false)]
async fn connection_secrets_are_scrubbed_even_if_sent(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let mac = common::enrolled(&admin, &app, "blove").await;
    let insert_with_secrets = insert(
        1,
        "connections",
        "conn-1",
        json!({"id": "conn-1", "kind": "codex", "label": "Codex",
               "target": "/usr/bin/codex", "authReference": "secret:x", "localServerId": "ls-1"}),
    );
    push_through(&app, &mac, &[insert_with_secrets])
        .await
        .unwrap();
    let connection = row(&app, &mac, "connections", "id", "conn-1")
        .await
        .unwrap();
    assert_eq!(connection["label"], "Codex");
    for secret in ["target", "authReference", "localServerId"] {
        assert_eq!(connection[secret], Value::Null, "{secret}");
    }

    let updates = vec![
        update(2, "connections", "conn-1", "target", Some(json!("/bin/sh"))),
        update(
            3,
            "connections",
            "conn-1",
            "authReference",
            Some(json!("secret:y")),
        ),
        update(
            4,
            "connections",
            "conn-1",
            "localServerId",
            Some(json!("ls-2")),
        ),
        update(5, "connections", "conn-1", "label", Some(json!("Renamed"))),
    ];
    push_through(&app, &mac, &updates).await.unwrap();
    let connection = row(&app, &mac, "connections", "id", "conn-1")
        .await
        .unwrap();
    assert_eq!(connection["label"], "Renamed");
    for secret in ["target", "authReference", "localServerId"] {
        assert_eq!(connection[secret], Value::Null, "{secret}");
    }
}

#[sqlx::test(migrations = false)]
async fn owner_is_the_latest_inserter(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac_a, phone) = mac_and_phone(&admin, &app).await;
    let mac_b = common::enrolled_as(&admin, &app, "blove", "macos").await;
    let owner = |who: AuthedDevice| {
        let app = app.clone();
        async move {
            row(&app, &who, "threads", "id", "thread-1").await.unwrap()["owner_device_id"].clone()
        }
    };
    assert_eq!(owner(mac_a).await, mac_a.device_id.to_string());

    // The Mac was rejoined as a new device and re-inserts the row: it owns it now.
    let again = at(
        insert(
            1,
            "threads",
            "thread-1",
            json!({"id": "thread-1", "connectionId": "conn-1", "title": "Again"}),
        ),
        600,
        MAC_CLOCK,
    );
    push_through(&app, &mac_b, &[again]).await.unwrap();
    assert_eq!(owner(mac_a).await, mac_b.device_id.to_string());
    let thread = row(&app, &mac_a, "threads", "id", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["device_id"], mac_b.device_id.to_string());

    // An update, from the phone or a Mac, never moves it.
    let edits = vec![at(
        update(1, "threads", "thread-1", "pinned", Some(json!(true))),
        700,
        PHONE_CLOCK,
    )];
    push_through(&app, &phone, &edits).await.unwrap();
    let edits = vec![at(
        update(2, "threads", "thread-1", "context", Some(json!("notes"))),
        710,
        MAC_CLOCK,
    )];
    push_through(&app, &mac_a, &edits).await.unwrap();
    assert_eq!(owner(mac_a).await, mac_b.device_id.to_string());
}

#[sqlx::test(migrations = false)]
async fn oversized_value_is_rejected_not_413(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, _phone) = mac_and_phone(&admin, &app).await;
    let before = count(&app, &mac, "changes").await;
    let huge = "x".repeat(3 * 1024 * 1024);
    let batch = vec![
        at(
            update(10, "threads", "thread-1", "context", Some(json!(huge))),
            800,
            MAC_CLOCK,
        ),
        at(
            update(11, "threads", "thread-1", "title", Some(json!("Fine"))),
            810,
            MAC_CLOCK,
        ),
    ];
    let outcome = changes::push(&app, &mac, &batch).await.unwrap();
    assert_eq!(outcome.accepted_through, 11);
    assert_eq!(
        outcome.rejected,
        vec![Rejected {
            device_seq: 10,
            code: "payload_too_large"
        }]
    );
    assert_eq!(count(&app, &mac, "changes").await, before + 1);
    assert_eq!(title(&app, &mac).await, "Fine");
}

#[sqlx::test(migrations = false)]
async fn a_second_user_cannot_move_the_first_users_clock(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (mac, _phone) = mac_and_phone(&admin, &app).await;
    let bob = common::enrolled(&admin, &app, "bob").await;
    // Bob re-inserts alice's row id with a far newer clock; nothing of it applies, and the
    // clock does not move, so alice's next edit (older than bob's stamp) still lands.
    let hijack = at(
        insert(
            1,
            "threads",
            "thread-1",
            json!({"id": "thread-1", "title": "Bob"}),
        ),
        250_000,
        MAC_CLOCK,
    );
    push_through(&app, &bob, &[hijack]).await.unwrap();
    let edit = at(
        update(3, "threads", "thread-1", "title", Some(json!("Alice"))),
        200,
        MAC_CLOCK,
    );
    push_through(&app, &mac, &[edit]).await.unwrap();
    assert_eq!(title(&app, &mac).await, "Alice");
}

#[sqlx::test(migrations = false)]
async fn the_conflict_fixture_converges(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let mac = common::enrolled(&admin, &app, "blove").await;
    let phone = common::enrolled_as(&admin, &app, "blove", "ios").await;
    let replay: Value = serde_json::from_str(include_str!(
        "../../../../Tests/Fixtures/sync/conflicts.json"
    ))
    .unwrap();

    for entry in replay["changes"].as_array().unwrap().clone() {
        let who = match entry["platform"].as_str().unwrap() {
            "macos" => &mac,
            "ios" => &phone,
            other => panic!("unknown platform {other}"),
        };
        let Value::Object(mut fields) = entry else {
            panic!("a conflict entry is an object")
        };
        fields.remove("platform");
        fields.remove("device");
        let change: Change = serde_json::from_value(Value::Object(fields)).unwrap();
        assert!(change.hlc.is_some());
        let outcome = changes::push(&app, who, &[change]).await.unwrap();
        assert!(outcome.rejected.is_empty(), "{outcome:?}");
    }

    let thread = row(&app, &mac, "threads", "id", "thread-1").await.unwrap();
    let draft = row(&app, &mac, "drafts", "threadId", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["title"], replay["expected"]["threads.title"]);
    assert_eq!(
        thread["readTurnId"],
        replay["expected"]["threads.readTurnId"]
    );
    assert_eq!(draft["text"], replay["expected"]["drafts.text"]);
    assert_eq!(
        draft["text"], "",
        "an empty string survives as the empty string"
    );
}

#[sqlx::test(migrations = false)]
async fn migration_backfills_clocks_and_owners(pool: PgPool) {
    // Migrate to 0002 only, load an M8a-era feed, then apply 0003.
    let admin_url = common::admin_url(&pool);
    let migrator = sqlx::migrate!("./migrations");
    let mut up_to_0002 = sqlx::migrate!("./migrations");
    up_to_0002.migrations = migrator
        .migrations
        .iter()
        .filter(|m| m.version <= 2)
        .cloned()
        .collect::<Vec<_>>()
        .into();
    let mut conn = <sqlx::PgConnection as sqlx::Connection>::connect(&admin_url)
        .await
        .unwrap();
    up_to_0002.run(&mut conn).await.unwrap();

    let org = Uuid::from_u128(1);
    let user = Uuid::from_u128(2);
    let (dev_a, dev_b) = (Uuid::from_u128(3), Uuid::from_u128(4));
    let mut tx = sqlx::Connection::begin(&mut conn).await.unwrap();
    sqlx::query("SELECT set_config('b4hub.org_id', $1, true)")
        .bind(org.to_string())
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("INSERT INTO orgs (id, slug, name) VALUES ($1, 'o', 'o')")
        .bind(org)
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("INSERT INTO users (id, org_id, username, display_name, email) VALUES ($1, $2, 'u', 'u', 'u@x.test')")
        .bind(user)
        .bind(org)
        .execute(&mut *tx)
        .await
        .unwrap();
    for device in [dev_a, dev_b] {
        sqlx::query("INSERT INTO devices (id, org_id, user_id, name, platform) VALUES ($1, $2, $3, 'd', 'macos')")
            .bind(device)
            .bind(org)
            .bind(user)
            .execute(&mut *tx)
            .await
            .unwrap();
    }
    for (seq, device) in [(1_i64, dev_a), (2, dev_b), (3, dev_a)] {
        sqlx::query(
            "INSERT INTO changes (org_id, device_id, device_seq, user_id, wall, \"table\", row_id, op) \
             VALUES ($1, $2, $3, $4, $5, 'threads', 't1', $6)",
        )
        .bind(org)
        .bind(device)
        .bind(seq)
        .bind(user)
        .bind(T0 + seq)
        .bind(if seq == 3 { "update" } else { "insert" })
        .execute(&mut *tx)
        .await
        .unwrap();
    }
    sqlx::query(
        "INSERT INTO threads (org_id, user_id, device_id, \"id\") VALUES ($1, $2, $3, 't1')",
    )
    .bind(org)
    .bind(user)
    .bind(dev_a)
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    migrator.run(&mut conn).await.unwrap();

    let mut tx = sqlx::Connection::begin(&mut conn).await.unwrap();
    sqlx::query("SELECT set_config('b4hub.org_id', $1, true)")
        .bind(org.to_string())
        .execute(&mut *tx)
        .await
        .unwrap();
    let owner: Uuid = sqlx::query_scalar("SELECT owner_device_id FROM threads WHERE \"id\" = 't1'")
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    assert_eq!(owner, dev_b, "the latest insert, not the latest write");
    let clocks: Vec<String> = sqlx::query_scalar("SELECT hlc FROM changes ORDER BY device_seq")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    assert_eq!(
        clocks,
        [(1, dev_a), (2, dev_b), (3, dev_a)]
            .map(|(seq, device)| format!("{:012x}-0000-{device}", T0 + seq))
            .to_vec()
    );
    tx.commit().await.unwrap();
}
