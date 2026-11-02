//! The pool never logs SQL, whatever the tracing filter lets through. Run with
//! `source <(./scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use std::io::Write;
use std::sync::{Arc, Mutex};

use b4hub_db::Db;
use sqlx::PgPool;
use tracing_subscriber::fmt::MakeWriter;

/// Everything the subscriber writes, kept for the assertion.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for Captured {
    type Writer = Captured;

    fn make_writer(&'a self) -> Captured {
        self.clone()
    }
}

#[sqlx::test(migrations = false)]
async fn statements_are_never_logged(pool: PgPool) {
    let (_admin, _app) = common::migrated(&pool).await;
    let captured = Captured::default();
    let subscriber = tracing_subscriber::fmt()
        .with_max_level(tracing::Level::TRACE)
        .with_writer(captured.clone())
        .finish();
    // `#[sqlx::test]` runs on one thread, so a thread-local subscriber sees every event.
    let _guard = tracing::subscriber::set_default(subscriber);

    let db = Db::connect(&common::app_url(&pool, common::APP_PASSWORD))
        .await
        .unwrap();
    // A fast statement (sqlx logs these at DEBUG) and a slow one (WARN after a second).
    sqlx::query("SELECT 'marker-fast'")
        .execute(&db.pool)
        .await
        .unwrap();
    sqlx::query("SELECT 'marker-slow', pg_sleep(1.1)")
        .execute(&db.pool)
        .await
        .unwrap();
    tracing::info!("canary");

    let text = captured.text();
    assert!(text.contains("canary"), "the capture works: {text}");
    assert!(!text.contains("marker-fast"), "{text}");
    assert!(!text.contains("marker-slow"), "{text}");
}
