//! Change ingest, materialisation, and the feed against a real PostgreSQL. Run with
//! `source <(./scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use b4hub_core::change::{table_spec, Change, ChangeOp, SYNCED_TABLES};
use b4hub_db::changes;
use b4hub_db::devices::AuthedDevice;
use b4hub_db::Db;
use serde_json::{json, Value};
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
    }
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
    changes::push(app, who, &batch).await.unwrap();
}

#[sqlx::test(migrations = false)]
async fn push_materialises_and_is_idempotent(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let device = common::enrolled(&admin, &app, "blove").await;
    let batch = common::filtered_fixture();

    let accepted = changes::push(&app, &device, &batch).await.unwrap();
    assert_eq!(accepted, 12);
    assert_eq!(count(&app, &device, "changes").await, 12);

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
    let again = changes::push(&app, &device, &batch).await.unwrap();
    assert_eq!(again, 12);
    assert_eq!(count(&app, &device, "changes").await, 12);
    assert!(row(&app, &device, "turns", "id", "turn-1").await.is_none());
    assert_eq!(count(&app, &device, "turns").await, 1);

    // acceptedThrough is the batch's highest device sequence, wherever it sits in the batch,
    // and an empty batch reports what the device has already had accepted.
    let mut shuffled = batch[..3].to_vec();
    shuffled.reverse();
    assert_eq!(changes::push(&app, &device, &shuffled).await.unwrap(), 3);
    assert_eq!(changes::push(&app, &device, &[]).await.unwrap(), 12);
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
    changes::push(&app, &device, &[sneaky]).await.unwrap();
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
    changes::push(&app, &device, &batch).await.unwrap();
    let thread = row(&app, &device, "threads", "id", "thread-1")
        .await
        .unwrap();
    assert_eq!(thread["pinned"], false);
    assert_eq!(thread["context"], "notes");
    assert_eq!(thread["title"], Value::Null);
    assert_eq!(thread["connectionId"], "conn-1");

    // A jsonb column takes a JSON value whole.
    let capabilities = json!({"streaming": false, "list": [1, 2]});
    changes::push(
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
    let accepted = changes::push(&app, &device, &batch).await.unwrap();
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
    assert_eq!(changes::push(&app, &bob, &batch).await.unwrap(), 4);

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
    changes::push(&app, &device, &common::filtered_fixture())
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
    changes::push(&app, &device, &common::filtered_fixture())
        .await
        .unwrap();

    let page = changes::pull(&app, &outsider, 0, 1000).await.unwrap();
    assert!(page.changes.is_empty());
    for table in std::iter::once("changes").chain(SYNCED_TABLES) {
        assert_eq!(count(&app, &outsider, table).await, 0, "{table}");
        // The fixture's draft is inserted and then deleted.
        if table != "drafts" {
            assert!(count(&app, &device, table).await > 0, "{table}");
        }
    }
    // No tenant context at all: nothing either.
    for table in std::iter::once("changes").chain(SYNCED_TABLES) {
        let n: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM \"{table}\""))
            .fetch_one(&app.pool)
            .await
            .unwrap();
        assert_eq!(n, 0, "{table}");
    }
    // The outsider reusing the same device sequence numbers and row ids is independent.
    let accepted = changes::push(&app, &outsider, &common::filtered_fixture())
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
        expected.extend(["org_id", "user_id", "device_id"].map(String::from));
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
    for table in std::iter::once("changes").chain(SYNCED_TABLES) {
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
    let task_a = tokio::spawn(async move { changes::push(&app_a, &alice, &a).await });
    let task_b = tokio::spawn(async move { changes::push(&app_b, &bob, &b).await });
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
