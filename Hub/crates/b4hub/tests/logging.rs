//! What an authenticated request leaves in the JSON log: the request id and the device id, and
//! never the bearer token. Run with `source <(../scripts/test-db.sh)` first.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Body;
use axum::http::{header, Request, StatusCode};
use b4hub::serve::{self, AppState};
use b4hub_db::{devices, orgs, Db};
use serde_json::Value;
use sqlx::PgPool;
use tower::ServiceExt;
use tracing_subscriber::fmt::MakeWriter;
use url::Url;

fn admin_url(pool: &PgPool) -> String {
    let base = std::env::var("DATABASE_URL").expect("DATABASE_URL is set by test-db.sh");
    let mut url = Url::parse(&base).unwrap();
    let database = pool
        .connect_options()
        .get_database()
        .expect("test pool has a database")
        .to_string();
    url.set_path(&format!("/{database}"));
    url.to_string()
}

fn app_url(pool: &PgPool) -> String {
    let mut url = Url::parse(&admin_url(pool)).unwrap();
    url.set_username("b4hub_app").unwrap();
    url.set_password(Some("pw-test")).unwrap();
    url.to_string()
}

#[derive(Clone, Default)]
struct Buffer(Arc<Mutex<Vec<u8>>>);

impl Write for Buffer {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for Buffer {
    type Writer = Buffer;

    fn make_writer(&'a self) -> Buffer {
        self.clone()
    }
}

#[sqlx::test(migrations = false)]
async fn an_authenticated_request_logs_the_ids_and_never_the_token(pool: PgPool) {
    b4hub_db::migrate::run(&admin_url(&pool), &app_url(&pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(&pool)).await.unwrap();
    let state = AppState::new(Db::connect(&app_url(&pool)).await.unwrap()).trust_proxy(true);
    let seeded = orgs::seed(
        &admin,
        "cacheplane",
        "Cacheplane",
        "blove",
        "Brian Love",
        "blove@example.test",
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        &admin,
        seeded.org_id,
        seeded.user_id,
        Duration::from_secs(600),
    )
    .await
    .unwrap();
    let enrolled = devices::redeem(&state.db, &code, "test device", "macos")
        .await
        .unwrap();

    let buffer = Buffer::default();
    let subscriber = tracing_subscriber::fmt()
        .json()
        .flatten_event(true)
        .with_current_span(true)
        .with_span_list(false)
        .with_max_level(tracing::Level::TRACE)
        .with_writer(buffer.clone())
        .finish();
    let guard = tracing::subscriber::set_default(subscriber);

    let response = serve::router(state.clone())
        .oneshot(
            Request::get("/v1/me?after=1")
                .header(header::AUTHORIZATION, format!("Bearer {}", enrolled.token))
                .header("X-Request-Id", "edge-7f3a")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["x-request-id"], "edge-7f3a");
    drop(guard);

    let raw = String::from_utf8(buffer.0.lock().unwrap().clone()).unwrap();
    assert!(!raw.is_empty(), "nothing was logged");
    assert!(!raw.contains(&enrolled.token), "the token leaked: {raw}");
    assert!(!raw.contains("after=1"), "the query leaked: {raw}");
    let lines: Vec<Value> = raw
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let done = lines
        .iter()
        .find(|line| line["message"] == "request complete")
        .unwrap_or_else(|| panic!("no completion event in {raw}"));
    assert_eq!(done["span"]["request_id"], "edge-7f3a");
    assert_eq!(done["span"]["device_id"], enrolled.device_id.to_string());
    assert_eq!(done["span"]["path"], "/v1/me");
    assert_eq!(done["status"], 200);
    state.db.pool.close().await;
}
