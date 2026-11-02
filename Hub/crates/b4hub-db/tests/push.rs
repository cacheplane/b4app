//! Which applied changes notify which phones, decided in the push transaction (decisions D-110
//! and D-111). Run with `source <(./scripts/test-db.sh)` first.

mod common;

use b4hub_core::change::{Change, ChangeOp};
use b4hub_core::push::Reason;
use b4hub_db::changes::{self, PushOutcome};
use b4hub_db::devices::{self, AuthedDevice};
use b4hub_db::push::{self, Notification};
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

fn update(seq: i64, table: &str, row: &str, column: &str, value: Value) -> Change {
    Change {
        op: ChangeOp::Update,
        column: Some(column.into()),
        value: Some(value),
        ..insert(seq, table, row, Value::Null)
    }
}

/// The Mac, two phones with tokens, all one user's.
struct World {
    admin: Db,
    app: Db,
    mac: AuthedDevice,
    phones: [AuthedDevice; 2],
}

async fn world(pool: &PgPool) -> World {
    let (admin, app) = common::migrated(pool).await;
    let mac = common::enrolled_as(&admin, &app, "blove", "macos").await;
    let first = common::enrolled_as(&admin, &app, "blove", "ios").await;
    let second = common::enrolled_as(&admin, &app, "blove", "ios").await;
    for (n, phone) in [&first, &second].into_iter().enumerate() {
        push::save_token(
            &app,
            phone,
            &format!("token-{n}"),
            "sandbox",
            "com.example.app",
        )
        .await
        .unwrap();
    }
    World {
        admin,
        app,
        mac,
        phones: [first, second],
    }
}

/// The hub's clock as the Mac writes timestamps, `offset` (a Postgres interval) away from now.
async fn stamp(app: &Db, who: &AuthedDevice, offset: &str) -> String {
    let mut tx = app.tenant_tx(who.org_id).await.unwrap();
    let text = sqlx::query_scalar(&format!(
        "SELECT to_char((now() + interval '{offset}') AT TIME ZONE 'UTC', \
         'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')"
    ))
    .fetch_one(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    text
}

async fn push_batch(w: &World, batch: &[Change]) -> PushOutcome {
    changes::push(&w.app, &w.mac, batch).await.unwrap()
}

/// A connection and a thread titled `title`, as the Mac's first two changes.
async fn with_thread(w: &World, title: &str) {
    push_batch(
        w,
        &[
            insert(
                1,
                "connections",
                "conn-1",
                json!({"id": "conn-1", "kind": "codex", "label": "Codex"}),
            ),
            insert(
                2,
                "threads",
                "thread-1",
                json!({"id": "thread-1", "connectionId": "conn-1", "title": title}),
            ),
        ],
    )
    .await;
}

fn request(seq: i64, id: &str, kind: &str, state: &str) -> Change {
    insert(
        seq,
        "runtimeRequests",
        id,
        json!({"id": id, "threadId": "thread-1", "kind": kind, "state": state}),
    )
}

fn turn(seq: i64, id: &str, status: &str, outcome: Option<&str>, updated_at: &str) -> Change {
    insert(
        seq,
        "turns",
        id,
        json!({"id": id, "threadId": "thread-1", "status": status, "outcome": outcome,
               "updatedAt": updated_at}),
    )
}

/// What matters about a set of notifications, ordered by device.
fn summary(notifications: &[Notification]) -> Vec<(Uuid, String, Reason, String)> {
    let mut found: Vec<_> = notifications
        .iter()
        .map(|n| (n.device_id, n.title.clone(), n.reason, n.thread_id.clone()))
        .collect();
    found.sort_by_key(|(device, ..)| *device);
    found
}

fn expect(w: &World, title: &str, reason: Reason) -> Vec<(Uuid, String, Reason, String)> {
    let mut expected: Vec<_> = w
        .phones
        .iter()
        .map(|p| {
            (
                p.device_id,
                title.to_string(),
                reason,
                "thread-1".to_string(),
            )
        })
        .collect();
    expected.sort_by_key(|(device, ..)| *device);
    expected
}

async fn ledger(w: &World) -> Vec<(String, String, String)> {
    let mut tx = w.app.tenant_tx(w.mac.org_id).await.unwrap();
    let rows =
        sqlx::query_as("SELECT kind, row_id, reason FROM notifications_sent ORDER BY kind, row_id")
            .fetch_all(&mut *tx)
            .await
            .unwrap();
    tx.commit().await.unwrap();
    rows
}

#[sqlx::test(migrations = false)]
async fn pending_request_notifies_each_other_phone(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Fix the build").await;
    let outcome = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;

    assert_eq!(
        summary(&outcome.notifications),
        expect(&w, "Fix the build", Reason::Approval)
    );
    assert!(outcome
        .notifications
        .iter()
        .all(|n| n.device_id != w.mac.device_id));
    let tokens: Vec<_> = {
        let mut t: Vec<_> = outcome
            .notifications
            .iter()
            .map(|n| n.token.clone())
            .collect();
        t.sort();
        t
    };
    assert_eq!(tokens, ["token-0", "token-1"]);
    assert!(outcome
        .notifications
        .iter()
        .all(|n| n.environment == "sandbox" && n.bundle_id == "com.example.app"));
    // The token is not in the debug text.
    assert!(!format!("{:?}", outcome.notifications[0]).contains("token-"));
    assert_eq!(
        ledger(&w).await,
        [("request".into(), "request-1".into(), "approval".into())]
    );
}

#[sqlx::test(migrations = false)]
async fn question_kinds_say_question(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Plan").await;
    let outcome = push_batch(&w, &[request(3, "request-1", "user_question", "pending")]).await;
    assert_eq!(
        summary(&outcome.notifications),
        expect(&w, "Plan", Reason::Question)
    );
}

#[sqlx::test(migrations = false)]
async fn resolved_request_does_not_notify(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Plan").await;
    let outcome = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "resolved")],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(ledger(&w).await.is_empty());
}

#[sqlx::test(migrations = false)]
async fn completed_and_failed_turns_notify_cancelled_does_not(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Ship it").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;

    let done = push_batch(
        &w,
        &[turn(3, "turn-1", "terminal", Some("completed"), &now)],
    )
    .await;
    assert_eq!(
        summary(&done.notifications),
        expect(&w, "Ship it", Reason::Replied)
    );
    let failed = push_batch(&w, &[turn(4, "turn-2", "terminal", Some("failed"), &now)]).await;
    assert_eq!(
        summary(&failed.notifications),
        expect(&w, "Ship it", Reason::Failed)
    );
    let cancelled = push_batch(
        &w,
        &[turn(5, "turn-3", "terminal", Some("cancelled"), &now)],
    )
    .await;
    assert!(cancelled.notifications.is_empty());
    let running = push_batch(&w, &[turn(6, "turn-4", "running", None, &now)]).await;
    assert!(running.notifications.is_empty());
    assert_eq!(ledger(&w).await.len(), 2);
}

#[sqlx::test(migrations = false)]
async fn history_upload_does_not_notify(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Old").await;
    let hour_ago = stamp(&w.app, &w.mac, "-1 hour").await;
    let outcome = push_batch(
        &w,
        &[turn(3, "turn-1", "terminal", Some("completed"), &hour_ago)],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(ledger(&w).await.is_empty());

    // A timestamp that is not a timestamp is not recent, and does not fail the batch.
    let junk = push_batch(
        &w,
        &[
            turn(4, "turn-2", "terminal", Some("completed"), "yesterday"),
            turn(
                5,
                "turn-3",
                "terminal",
                Some("completed"),
                "2026-13-45T99:99:99Z",
            ),
        ],
    )
    .await;
    assert!(junk.notifications.is_empty());
    assert_eq!(junk.accepted_through, 5);
    assert!(ledger(&w).await.is_empty());
}

#[sqlx::test(migrations = false)]
async fn outcome_in_a_later_batch_notifies_once(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Later").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let first = push_batch(&w, &[turn(3, "turn-1", "terminal", None, &now)]).await;
    assert!(first.notifications.is_empty());

    let outcome = push_batch(
        &w,
        &[update(4, "turns", "turn-1", "outcome", json!("completed"))],
    )
    .await;
    assert_eq!(
        summary(&outcome.notifications),
        expect(&w, "Later", Reason::Replied)
    );

    let again = push_batch(
        &w,
        &[update(5, "turns", "turn-1", "outcome", json!("completed"))],
    )
    .await;
    assert!(again.notifications.is_empty());
}

#[sqlx::test(migrations = false)]
async fn retry_and_later_update_do_not_renotify(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Retry").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let batch = [turn(3, "turn-1", "terminal", Some("completed"), &now)];
    assert_eq!(push_batch(&w, &batch).await.notifications.len(), 2);

    // The same batch again: the change is a duplicate and nothing is applied.
    assert!(push_batch(&w, &batch).await.notifications.is_empty());
    // A later change to the turn finds the ledger row.
    let later = stamp(&w.app, &w.mac, "1 minute").await;
    let touched = push_batch(
        &w,
        &[update(4, "turns", "turn-1", "updatedAt", json!(later))],
    )
    .await;
    assert!(touched.notifications.is_empty());
    assert_eq!(ledger(&w).await.len(), 1);
}

#[sqlx::test(migrations = false)]
async fn revoked_or_tokenless_phones_get_nothing(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Quiet").await;
    // One phone is revoked; a third has no token.
    devices::revoke_self(&w.app, w.mac.org_id, w.phones[0].device_id)
        .await
        .unwrap();
    let _tokenless = common::enrolled_as(&w.admin, &w.app, "blove", "ios").await;

    let outcome = push_batch(&w, &[request(3, "request-1", "tool_permission", "pending")]).await;
    assert_eq!(outcome.notifications.len(), 1);
    assert_eq!(outcome.notifications[0].device_id, w.phones[1].device_id);

    // With nobody left to tell, the ledger row is still written and nobody is told later.
    devices::revoke_self(&w.app, w.mac.org_id, w.phones[1].device_id)
        .await
        .unwrap();
    let none = push_batch(&w, &[request(4, "request-2", "tool_permission", "pending")]).await;
    assert!(none.notifications.is_empty());
    assert_eq!(ledger(&w).await.len(), 2);
}

#[sqlx::test(migrations = false)]
async fn other_users_phones_are_not_told(pool: PgPool) {
    let w = world(&pool).await;
    let stranger = common::enrolled_as(&w.admin, &w.app, "eve", "ios").await;
    push::save_token(
        &w.app,
        &stranger,
        "eve-token",
        "production",
        "com.example.app",
    )
    .await
    .unwrap();
    with_thread(&w, "Mine").await;
    let outcome = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;
    assert_eq!(outcome.notifications.len(), 2);
    assert!(outcome
        .notifications
        .iter()
        .all(|n| n.device_id != stranger.device_id));
}

#[sqlx::test(migrations = false)]
async fn untitled_thread_and_long_title(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "   ").await;
    let outcome = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;
    assert_eq!(outcome.notifications[0].title, "Untitled thread");

    let long = "x".repeat(300);
    push_batch(
        &w,
        &[update(4, "threads", "thread-1", "title", json!(long))],
    )
    .await;
    let outcome = push_batch(
        &w,
        &[request(5, "request-2", "command_approval", "pending")],
    )
    .await;
    assert_eq!(outcome.notifications[0].title.chars().count(), 100);
}

#[sqlx::test(migrations = false)]
async fn save_token_replaces(pool: PgPool) {
    let w = world(&pool).await;
    let phone = &w.phones[0];
    push::save_token(
        &w.app,
        phone,
        "replacement",
        "production",
        "com.example.other",
    )
    .await
    .unwrap();
    let mut tx = w.app.tenant_tx(phone.org_id).await.unwrap();
    let rows: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT token, environment, bundle_id FROM push_tokens WHERE device_id = $1",
    )
    .bind(phone.device_id)
    .fetch_all(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        rows,
        [(
            "replacement".into(),
            "production".into(),
            "com.example.other".into()
        )]
    );

    // Anything but the two environments is refused by the table.
    let error = push::save_token(&w.app, phone, "t", "staging", "com.example.app")
        .await
        .unwrap_err();
    assert!(matches!(error, b4hub_db::Error::Sqlx(_)), "{error}");
}

#[sqlx::test(migrations = false)]
async fn pruning_drops_old_ledger_rows(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Old").await;
    push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;
    push_batch(
        &w,
        &[request(4, "request-2", "command_approval", "pending")],
    )
    .await;
    sqlx::query("UPDATE notifications_sent SET sent_at = now() - interval '10 days' WHERE row_id = 'request-1'")
        .execute(&w.admin.pool)
        .await
        .unwrap();

    b4hub_db::prune::prune(
        &w.app,
        w.mac.org_id,
        std::time::Duration::from_secs(7 * 86_400),
    )
    .await
    .unwrap();
    let rows = ledger(&w).await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].1, "request-2");
}
