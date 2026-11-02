//! Which applied changes notify which phones, decided in the push transaction (decisions D-121
//! and D-122). Run with `source <(./scripts/test-db.sh)` first.

mod common;

use b4hub_core::change::{Change, ChangeOp};
use b4hub_core::push::Reason;
use b4hub_db::changes::{self, PushOutcome};
use b4hub_db::devices::{self, AuthedDevice};
use b4hub_db::push::{self, Notification, Withdrawal};
use b4hub_db::Db;
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;
use std::collections::HashMap;

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

fn delete(seq: i64, table: &str, row: &str) -> Change {
    Change {
        op: ChangeOp::Delete,
        value: None,
        ..insert(seq, table, row, Value::Null)
    }
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
    // The key names the request; the badge counts the one thread that needs input.
    assert!(outcome
        .notifications
        .iter()
        .all(|n| n.key == "request:request-1" && n.badge == 1));
    assert!(outcome.withdrawals.is_empty());
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

/// A phone that logged out (`DELETE /v1/sessions/self` deletes its session token) stays enrolled
/// and keeps its push-token row, but is told nothing until it signs in again.
#[sqlx::test(migrations = false)]
async fn a_phone_with_no_session_gets_nothing(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Quiet").await;
    sqlx::query("DELETE FROM device_tokens WHERE device_id = $1")
        .bind(w.phones[0].device_id)
        .execute(&w.admin.pool)
        .await
        .unwrap();
    let outcome = push_batch(&w, &[request(3, "request-1", "tool_permission", "pending")]).await;
    assert_eq!(outcome.notifications.len(), 1);
    assert_eq!(outcome.notifications[0].device_id, w.phones[1].device_id);
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

#[sqlx::test(migrations = false)]
async fn a_request_deleted_in_the_same_push_does_not_notify(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Plan").await;
    let outcome = push_batch(
        &w,
        &[
            request(3, "request-1", "command_approval", "pending"),
            delete(4, "runtimeRequests", "request-1"),
        ],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(ledger(&w).await.is_empty());
}

#[sqlx::test(migrations = false)]
async fn a_turn_in_a_deleted_thread_does_not_notify(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Gone").await;
    push_batch(&w, &[delete(3, "threads", "thread-1")]).await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let outcome = push_batch(
        &w,
        &[
            turn(4, "turn-1", "terminal", Some("completed"), &now),
            request(5, "request-1", "command_approval", "pending"),
        ],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(ledger(&w).await.is_empty());
}

#[sqlx::test(migrations = false)]
async fn a_deleted_turn_does_not_notify(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Ship it").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let outcome = push_batch(
        &w,
        &[
            turn(3, "turn-1", "terminal", Some("completed"), &now),
            delete(4, "turns", "turn-1"),
        ],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(ledger(&w).await.is_empty());
}

// Withdrawing notifications, the badge, and one device per token (the M8f APNs slice).

/// A turn of `thread` created at `created_at`, finished and updated now (so it is recent).
fn turn_in(seq: i64, id: &str, thread: &str, created_at: &str, updated_at: &str) -> Change {
    insert(
        seq,
        "turns",
        id,
        json!({"id": id, "threadId": thread, "status": "terminal", "outcome": "completed",
               "createdAt": created_at, "updatedAt": updated_at}),
    )
}

/// What matters about a set of withdrawals: each phone's keys, ordered by device.
fn withdrawn(withdrawals: &[Withdrawal]) -> Vec<(Uuid, Vec<String>)> {
    let mut found: Vec<_> = withdrawals
        .iter()
        .map(|w| {
            let mut keys = w.keys.clone();
            keys.sort();
            (w.device_id, keys)
        })
        .collect();
    found.sort_by_key(|(device, _)| *device);
    found
}

/// Both phones, each withdrawing `keys`.
fn to_both(w: &World, keys: &[&str]) -> Vec<(Uuid, Vec<String>)> {
    let mut keys: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
    keys.sort();
    let mut expected: Vec<_> = w
        .phones
        .iter()
        .map(|p| (p.device_id, keys.clone()))
        .collect();
    expected.sort_by_key(|(device, _)| *device);
    expected
}

/// The ledger's withdrawn keys, sorted.
async fn withdrawn_in_ledger(w: &World) -> Vec<String> {
    let mut tx = w.app.tenant_tx(w.mac.org_id).await.unwrap();
    let rows: Vec<String> = sqlx::query_scalar(
        "SELECT kind || ':' || row_id FROM notifications_sent \
         WHERE withdrawn_at IS NOT NULL ORDER BY 1",
    )
    .fetch_all(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    rows
}

async fn needs_you(w: &World) -> i64 {
    let mut tx = w.app.tenant_tx(w.mac.org_id).await.unwrap();
    let n = push::needs_you_count(&mut tx, w.mac.org_id, w.mac.user_id)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    n
}

async fn bands_of(w: &World) -> HashMap<String, String> {
    let mut tx = w.app.tenant_tx(w.mac.org_id).await.unwrap();
    let bands = push::bands(&mut tx, w.mac.org_id, w.mac.user_id)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    bands
        .into_iter()
        .map(|(id, band)| (id, band.as_str().to_string()))
        .collect()
}

#[sqlx::test(migrations = false)]
async fn answer_withdraws_once(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Plan").await;
    let asked = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;
    assert_eq!(asked.notifications.len(), 2);

    let answered = push_batch(
        &w,
        &[update(
            4,
            "runtimeRequests",
            "request-1",
            "state",
            json!("resolved"),
        )],
    )
    .await;
    assert!(answered.notifications.is_empty());
    assert_eq!(
        withdrawn(&answered.withdrawals),
        to_both(&w, &["request:request-1"])
    );
    assert!(answered
        .withdrawals
        .iter()
        .all(|x| x.environment == "sandbox" && x.bundle_id == "com.example.app"));
    // The token is not in the debug text.
    assert!(!format!("{:?}", answered.withdrawals[0]).contains("token-"));
    assert_eq!(withdrawn_in_ledger(&w).await, ["request:request-1"]);

    // A later change to the answered request withdraws nothing again.
    let again = push_batch(
        &w,
        &[update(
            5,
            "runtimeRequests",
            "request-1",
            "state",
            json!("expired"),
        )],
    )
    .await;
    assert!(again.withdrawals.is_empty());
}

#[sqlx::test(migrations = false)]
async fn expiry_withdraws(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Plan").await;
    push_batch(&w, &[request(3, "request-1", "user_question", "pending")]).await;
    let expired = push_batch(
        &w,
        &[update(
            4,
            "runtimeRequests",
            "request-1",
            "state",
            json!("expired"),
        )],
    )
    .await;
    assert_eq!(
        withdrawn(&expired.withdrawals),
        to_both(&w, &["request:request-1"])
    );
}

#[sqlx::test(migrations = false)]
async fn answered_in_same_batch_is_silent(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Plan").await;
    let outcome = push_batch(
        &w,
        &[
            request(3, "request-1", "command_approval", "pending"),
            update(
                4,
                "runtimeRequests",
                "request-1",
                "state",
                json!("resolved"),
            ),
        ],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(outcome.withdrawals.is_empty());
    assert!(ledger(&w).await.is_empty());
}

#[sqlx::test(migrations = false)]
async fn read_withdraws_earlier_turns_once(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Ship it").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let outcome = push_batch(
        &w,
        &[
            turn_in(3, "turn-1", "thread-1", "2026-11-02T10:00:00Z", &now),
            turn_in(4, "turn-2", "thread-1", "2026-11-02T10:05:00Z", &now),
            turn_in(5, "turn-3", "thread-1", "2026-11-02T10:10:00Z", &now),
        ],
    )
    .await;
    assert_eq!(outcome.notifications.len(), 6);

    // Reading turn-2 on the Mac withdraws turn-1 and turn-2, not turn-3.
    let read = push_batch(
        &w,
        &[update(
            6,
            "threads",
            "thread-1",
            "readTurnId",
            json!("turn-2"),
        )],
    )
    .await;
    assert_eq!(
        withdrawn(&read.withdrawals),
        to_both(&w, &["turn:turn-1", "turn:turn-2"])
    );
    assert_eq!(
        withdrawn_in_ledger(&w).await,
        ["turn:turn-1", "turn:turn-2"]
    );

    // Reading it again withdraws nothing; reading turn-3 withdraws turn-3 alone.
    let again = push_batch(
        &w,
        &[update(7, "threads", "thread-1", "title", json!("Renamed"))],
    )
    .await;
    assert!(again.withdrawals.is_empty());
    let last = push_batch(
        &w,
        &[update(
            8,
            "threads",
            "thread-1",
            "readTurnId",
            json!("turn-3"),
        )],
    )
    .await;
    assert_eq!(withdrawn(&last.withdrawals), to_both(&w, &["turn:turn-3"]));
}

#[sqlx::test(migrations = false)]
async fn withdrawal_reaches_the_reader_too(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Ship it").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    push_batch(
        &w,
        &[turn_in(
            3,
            "turn-1",
            "thread-1",
            "2026-11-02T10:00:00Z",
            &now,
        )],
    )
    .await;

    // The first phone reads the turn; both phones, the reader included, withdraw it.
    let reader = &w.phones[0];
    let read = changes::push(
        &w.app,
        reader,
        &[update(
            1,
            "threads",
            "thread-1",
            "readTurnId",
            json!("turn-1"),
        )],
    )
    .await
    .unwrap();
    assert!(read.rejected.is_empty(), "{:?}", read.rejected);
    assert!(read.notifications.is_empty());
    assert_eq!(withdrawn(&read.withdrawals), to_both(&w, &["turn:turn-1"]));
}

#[sqlx::test(migrations = false)]
async fn badge_counts_needs_input_and_unread(pool: PgPool) {
    let w = world(&pool).await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let thread = |seq: i64, id: &str, archived: bool| {
        insert(
            seq,
            "threads",
            id,
            json!({"id": id, "connectionId": "conn-1", "title": id, "archived": archived}),
        )
    };
    let running = |seq: i64, id: &str, thread: &str| {
        insert(
            seq,
            "turns",
            id,
            json!({"id": id, "threadId": thread, "status": "running",
                   "createdAt": "2026-11-02T10:00:00Z", "updatedAt": now}),
        )
    };
    push_batch(
        &w,
        &[
            insert(
                1,
                "connections",
                "conn-1",
                json!({"id": "conn-1", "kind": "codex", "label": "Codex"}),
            ),
            thread(2, "needs-input", false),
            thread(3, "unread", false),
            thread(4, "working", false),
            thread(5, "quiet", false),
            thread(6, "archived-unread", true),
            thread(7, "no-turns", false),
            turn_in(8, "u-unread", "unread", "2026-11-02T10:00:00Z", &now),
            running(9, "u-working", "working"),
            turn_in(10, "u-quiet", "quiet", "2026-11-02T10:00:00Z", &now),
            update(11, "threads", "quiet", "readTurnId", json!("u-quiet")),
            turn_in(
                12,
                "u-archived",
                "archived-unread",
                "2026-11-02T10:00:00Z",
                &now,
            ),
        ],
    )
    .await;
    assert_eq!(needs_you(&w).await, 1);

    // The notification carries the count after its whole batch: the request makes it two.
    let outcome = push_batch(
        &w,
        &[insert(
            13,
            "runtimeRequests",
            "request-1",
            json!({"id": "request-1", "threadId": "needs-input",
                   "kind": "command_approval", "state": "pending"}),
        )],
    )
    .await;
    assert_eq!(outcome.notifications.len(), 2);
    assert!(outcome.notifications.iter().all(|n| n.badge == 2));
    assert_eq!(needs_you(&w).await, 2);

    let bands = bands_of(&w).await;
    assert_eq!(bands["needs-input"], "needsInput");
    assert_eq!(bands["unread"], "unread");
    assert_eq!(bands["working"], "working");
    assert_eq!(bands["quiet"], "quiet");
    assert_eq!(bands["archived-unread"], "unread");
    assert_eq!(bands["no-turns"], "quiet");
}

/// The shared attention fixture, pushed as the Mac would upload its rows, gives the bands every
/// other implementation gives.
#[sqlx::test(migrations = false)]
async fn bands_match_the_shared_fixture(pool: PgPool) {
    let w = world(&pool).await;
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../Tests/Fixtures/sync/attention.json"
    ))
    .unwrap();
    let mut batch = Vec::new();
    for table in ["connections", "threads", "turns", "runtimeRequests"] {
        for row in fixture[table].as_array().unwrap() {
            let id = row["id"].as_str().unwrap();
            batch.push(insert(batch.len() as i64 + 1, table, id, row.clone()));
        }
    }
    let outcome = push_batch(&w, &batch).await;
    assert_eq!(outcome.accepted_through, batch.len() as i64);

    let expected: HashMap<String, String> =
        serde_json::from_value(fixture["expected"]["bands"].clone()).unwrap();
    assert_eq!(bands_of(&w).await, expected);
}

#[sqlx::test(migrations = false)]
async fn deleted_thread_never_notifies_and_is_not_counted(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Gone").await;
    push_batch(
        &w,
        &[
            insert(
                3,
                "threads",
                "thread-2",
                json!({"id": "thread-2", "connectionId": "conn-1", "title": "Here"}),
            ),
            update(
                4,
                "threads",
                "thread-1",
                "userDeletedAt",
                json!("2026-11-02T10:00:00Z"),
            ),
        ],
    )
    .await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    let outcome = push_batch(
        &w,
        &[
            turn(5, "turn-1", "terminal", Some("completed"), &now),
            request(6, "request-1", "command_approval", "pending"),
        ],
    )
    .await;
    assert!(outcome.notifications.is_empty());
    assert!(ledger(&w).await.is_empty());
    assert_eq!(needs_you(&w).await, 0);
    assert!(!bands_of(&w).await.contains_key("thread-1"));

    // A notification from the live thread counts that thread alone.
    let live = push_batch(
        &w,
        &[insert(
            7,
            "runtimeRequests",
            "request-2",
            json!({"id": "request-2", "threadId": "thread-2",
                   "kind": "command_approval", "state": "pending"}),
        )],
    )
    .await;
    assert_eq!(live.notifications.len(), 2);
    assert!(live.notifications.iter().all(|n| n.badge == 1));
}

#[sqlx::test(migrations = false)]
async fn deleting_a_thread_withdraws_its_notifications(pool: PgPool) {
    let w = world(&pool).await;
    with_thread(&w, "Busy").await;
    let now = stamp(&w.app, &w.mac, "0 seconds").await;
    push_batch(
        &w,
        &[
            turn_in(3, "turn-1", "thread-1", "2026-11-02T10:00:00Z", &now),
            request(4, "request-1", "command_approval", "pending"),
        ],
    )
    .await;

    // The phone deletes the thread: both of its notifications are withdrawn from both phones.
    let deleted = changes::push(
        &w.app,
        &w.phones[1],
        &[update(
            1,
            "threads",
            "thread-1",
            "userDeletedAt",
            json!("2026-11-02T10:30:00Z"),
        )],
    )
    .await
    .unwrap();
    assert!(deleted.rejected.is_empty(), "{:?}", deleted.rejected);
    assert_eq!(
        withdrawn(&deleted.withdrawals),
        to_both(&w, &["request:request-1", "turn:turn-1"])
    );
    assert_eq!(
        withdrawn_in_ledger(&w).await,
        ["request:request-1", "turn:turn-1"]
    );

    // Nothing is withdrawn twice.
    let again = push_batch(
        &w,
        &[update(
            5,
            "runtimeRequests",
            "request-1",
            "state",
            json!("resolved"),
        )],
    )
    .await;
    assert!(again.withdrawals.is_empty());
}

/// A phone that re-enrolled while the hub still holds its old device registers the same token
/// from its new device; the old row gives it up, so the phone is told once.
#[sqlx::test(migrations = false)]
async fn token_moves_to_its_new_device(pool: PgPool) {
    let w = world(&pool).await;
    let reenrolled = common::enrolled_as(&w.admin, &w.app, "blove", "ios").await;
    push::save_token(&w.app, &reenrolled, "token-0", "sandbox", "com.example.app")
        .await
        .unwrap();
    with_thread(&w, "Once").await;
    let outcome = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;
    let mut told: Vec<_> = outcome
        .notifications
        .iter()
        .map(|n| (n.device_id, n.token.clone()))
        .collect();
    told.sort();
    let mut expected = vec![
        (reenrolled.device_id, "token-0".to_string()),
        (w.phones[1].device_id, "token-1".to_string()),
    ];
    expected.sort();
    assert_eq!(told, expected);
}

/// A token Apple rejects is deleted; the phone is told nothing until it registers again.
#[sqlx::test(migrations = false)]
async fn delete_token_forgets_the_phone(pool: PgPool) {
    let w = world(&pool).await;
    push::delete_token(&w.app, w.mac.org_id, w.phones[0].device_id)
        .await
        .unwrap();
    with_thread(&w, "Quiet").await;
    let outcome = push_batch(
        &w,
        &[request(3, "request-1", "command_approval", "pending")],
    )
    .await;
    assert_eq!(outcome.notifications.len(), 1);
    assert_eq!(outcome.notifications[0].device_id, w.phones[1].device_id);
    // Deleting a token that is not there is not an error.
    push::delete_token(&w.app, w.mac.org_id, w.phones[0].device_id)
        .await
        .unwrap();
}
