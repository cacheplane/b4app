//! A transaction whose opening is cancelled must not leave its connection inside a transaction.
//!
//! sqlx 0.8 counts a transaction only once Postgres has answered its `BEGIN`; a future dropped
//! while it waits for that answer (a client that disconnects mid-request) returns the connection
//! to the pool still inside the transaction, unknown to sqlx. Every later user of that connection
//! then runs inside it: a write after `read_tx` fails as read-only, and after one error the
//! connection answers "current transaction is aborted" until it is closed. The hub's own `begin`
//! runs the `BEGIN` where a dropped caller cannot interrupt it.

mod common;

use std::future::Future;
use std::task::Poll;
use std::time::Duration;

use b4hub_db::Db;
use sqlx::postgres::PgPoolOptions;
use sqlx::types::Uuid;
use sqlx::PgPool;

/// One connection, handed out without a ping first, so the first poll of a begin acquires it and
/// sends `BEGIN` straight away, and every later query uses that same connection.
async fn single_connection(pool: &PgPool) -> Db {
    let _ = common::migrated(pool).await;
    let pool = PgPoolOptions::new()
        .max_connections(1)
        .test_before_acquire(false)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&common::app_url(pool, common::APP_PASSWORD))
        .await
        .unwrap();
    Db { pool }
}

/// Polls `begin` once (the connection is acquired and `BEGIN` is on the wire, waiting for its
/// answer) and drops it there, as a disconnected client's request is dropped.
async fn cancel_after_first_poll<F: Future>(begin: F) {
    let mut begin = std::pin::pin!(begin);
    let _ = std::future::poll_fn(|cx| Poll::Ready(begin.as_mut().poll(cx))).await;
}

/// Whether the pool's connection is inside a transaction: `now()` is the transaction's start
/// time, so two statements in one transaction see the same value, and outside one they do not.
async fn in_transaction(db: &Db) -> bool {
    let mut conn = db.pool.acquire().await.unwrap();
    let first: f64 = sqlx::query_scalar("SELECT extract(epoch FROM now())::float8")
        .fetch_one(&mut *conn)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(5)).await;
    let second: f64 = sqlx::query_scalar("SELECT extract(epoch FROM now())::float8")
        .fetch_one(&mut *conn)
        .await
        .unwrap();
    first == second
}

#[sqlx::test(migrations = false)]
async fn a_cancelled_read_tx_leaves_no_transaction(pool: PgPool) {
    let db = single_connection(&pool).await;
    for _ in 0..20 {
        cancel_after_first_poll(db.read_tx(Uuid::nil())).await;
        assert!(
            !in_transaction(&db).await,
            "the connection came back inside the read transaction"
        );
        let read_only: String =
            sqlx::query_scalar("SELECT current_setting('transaction_read_only')")
                .fetch_one(&db.pool)
                .await
                .unwrap();
        assert_eq!(read_only, "off");
    }
}

#[sqlx::test(migrations = false)]
async fn a_cancelled_tenant_tx_leaves_no_transaction(pool: PgPool) {
    let db = single_connection(&pool).await;
    for _ in 0..20 {
        cancel_after_first_poll(db.tenant_tx(Uuid::nil())).await;
        assert!(
            !in_transaction(&db).await,
            "the connection came back inside the tenant transaction"
        );
    }
}

#[sqlx::test(migrations = false)]
async fn a_cancelled_untenanted_tx_leaves_no_transaction(pool: PgPool) {
    let db = single_connection(&pool).await;
    for _ in 0..20 {
        cancel_after_first_poll(db.untenanted_tx()).await;
        assert!(
            !in_transaction(&db).await,
            "the connection came back inside the transaction"
        );
    }
}

#[sqlx::test(migrations = false)]
async fn a_completed_read_tx_still_works(pool: PgPool) {
    let db = single_connection(&pool).await;
    let mut tx = db.read_tx(Uuid::nil()).await.unwrap();
    let read_only: String = sqlx::query_scalar("SELECT current_setting('transaction_read_only')")
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    assert_eq!(read_only, "on");
    tx.rollback().await.unwrap();
    assert!(!in_transaction(&db).await);
}
