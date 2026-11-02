//! The push-token route and delivery after commit (decisions D-122 to D-124) against a real
//! PostgreSQL. Run with `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one
//! database per test.

mod common;

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use b4hub::push::{ApnsSender, PushError, PushSender, SpoolSender};
use b4hub::serve::{self, AppState};
use b4hub_core::push::{spool_payload, Reason};
use b4hub_db::push::Notification;
use b4hub_db::{devices, orgs, Db};
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;
use tower::ServiceExt;
use url::Url;

const BUNDLE: &str = "com.example.b4app";
const GOOD_TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

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

/// One user with a Mac and a phone (enrolled through the real redeem path).
struct World {
    state: AppState,
    mac: String,
    phone: String,
}

async fn world(pool: &PgPool) -> World {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(pool)).await.unwrap();
    let app = Db::connect(&app_url(pool)).await.unwrap();
    let state = common::state(app);
    let seeded = orgs::seed(
        &admin,
        "cacheplane",
        "Cacheplane",
        "blove",
        "blove",
        "blove@example.test",
    )
    .await
    .unwrap();
    let mut tokens = Vec::new();
    for (name, platform) in [("mac", "macos"), ("phone", "ios")] {
        let code = devices::create_enrollment_code(
            &admin,
            seeded.org_id,
            seeded.user_id,
            Duration::from_secs(600),
        )
        .await
        .unwrap();
        let enrolled = devices::redeem(&state.db, &code, name, platform)
            .await
            .unwrap();
        tokens.push(enrolled.token);
    }
    let phone = tokens.pop().unwrap();
    let mac = tokens.pop().unwrap();
    World { state, mac, phone }
}

async fn send(
    state: &AppState,
    method: &str,
    path: &str,
    token: &str,
    body: Option<String>,
) -> (StatusCode, Value) {
    let request = Request::builder()
        .method(method)
        .uri(path)
        .header(header::AUTHORIZATION, format!("Bearer {token}"));
    let request = match body {
        Some(body) => request
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body)),
        None => request.body(Body::empty()),
    }
    .unwrap();
    let response = serve::router(state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap()
    };
    (status, value)
}

fn token_body(token: &str, environment: &str, bundle_id: &str) -> String {
    json!({"token": token, "environment": environment, "bundleId": bundle_id}).to_string()
}

async fn register(w: &World) {
    let (status, body) = send(
        &w.state,
        "POST",
        "/v1/devices/self/push-token",
        &w.phone,
        Some(token_body(GOOD_TOKEN, "sandbox", BUNDLE)),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
}

fn code(body: &Value) -> &str {
    body["error"]["details"]["code"]
        .as_str()
        .unwrap_or_default()
}

/// The Mac's batch: a connection, a thread, and a pending approval request.
fn pending_request_batch() -> String {
    let change = |seq: i64, table: &str, row: &str, value: Value| {
        json!({"deviceSeq": seq, "wall": 1_761_900_000_000_i64 + seq, "table": table,
               "rowId": row, "op": "insert", "column": null, "value": value})
    };
    json!({"changes": [
        change(1, "connections", "conn-1", json!({"id": "conn-1", "kind": "codex", "label": "Codex"})),
        change(2, "threads", "thread-1",
               json!({"id": "thread-1", "connectionId": "conn-1", "title": "Fix the build"})),
        change(3, "runtimeRequests", "request-1",
               json!({"id": "request-1", "threadId": "thread-1",
                      "kind": "command_approval", "state": "pending"})),
    ]})
    .to_string()
}

type Seen = Arc<Mutex<Vec<(Uuid, String, Reason)>>>;

struct RecordingSender {
    seen: Seen,
}

impl PushSender for RecordingSender {
    fn send<'a>(
        &'a self,
        message: &'a Notification,
    ) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>> {
        Box::pin(async move {
            self.seen.lock().unwrap().push((
                message.device_id,
                message.thread_id.clone(),
                message.reason,
            ));
            Ok(())
        })
    }

    fn name(&self) -> &'static str {
        "recording"
    }
}

async fn eventually(what: &str, mut ready: impl FnMut() -> bool) {
    let started = Instant::now();
    while !ready() {
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[sqlx::test(migrations = false)]
async fn push_token_requires_an_ios_device(pool: PgPool) {
    let w = world(&pool).await;
    let (status, body) = send(
        &w.state,
        "POST",
        "/v1/devices/self/push-token",
        &w.mac,
        Some(token_body(GOOD_TOKEN, "sandbox", BUNDLE)),
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN, "{body}");
    assert_eq!(code(&body), "forbidden");
}

#[sqlx::test(migrations = false)]
async fn push_token_validates_fields(pool: PgPool) {
    let w = world(&pool).await;
    let bad = [
        ("non-hex", token_body(&"g".repeat(64), "sandbox", BUNDLE)),
        ("short", token_body(&"ab".repeat(15), "sandbox", BUNDLE)),
        ("long", token_body(&"ab".repeat(257), "sandbox", BUNDLE)),
        ("environment", token_body(GOOD_TOKEN, "staging", BUNDLE)),
        (
            "bundle with a space",
            token_body(GOOD_TOKEN, "sandbox", "com example"),
        ),
        (
            "bundle starting with a dot",
            token_body(GOOD_TOKEN, "sandbox", ".com.example"),
        ),
        ("empty bundle", token_body(GOOD_TOKEN, "sandbox", "")),
        (
            "long bundle",
            token_body(GOOD_TOKEN, "sandbox", &"a".repeat(156)),
        ),
        (
            "unknown field",
            json!({"token": GOOD_TOKEN, "environment": "sandbox", "bundleId": BUNDLE, "x": 1})
                .to_string(),
        ),
        ("not json", "{".to_string()),
    ];
    for (what, body) in bad {
        let (status, answer) = send(
            &w.state,
            "POST",
            "/v1/devices/self/push-token",
            &w.phone,
            Some(body),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{what}: {answer}");
        assert_eq!(code(&answer), "invalid_request", "{what}");
    }
    // The edges that are allowed.
    for body in [
        token_body(&"ab".repeat(16), "production", BUNDLE),
        token_body(&"AB".repeat(256), "sandbox", &"a".repeat(155)),
    ] {
        let (status, answer) = send(
            &w.state,
            "POST",
            "/v1/devices/self/push-token",
            &w.phone,
            Some(body),
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{answer}");
    }
}

#[sqlx::test(migrations = false)]
async fn push_token_saves(pool: PgPool) {
    let w = world(&pool).await;
    register(&w).await;
    // A second call replaces the first.
    let (status, _) = send(
        &w.state,
        "POST",
        "/v1/devices/self/push-token",
        &w.phone,
        Some(token_body(
            "cd".repeat(20).as_str(),
            "production",
            "com.example.other",
        )),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    let me = send(&w.state, "GET", "/v1/me", &w.phone, None).await.1;
    let device = Uuid::parse_str(me["deviceId"].as_str().unwrap()).unwrap();
    let mut tx = w
        .state
        .db
        .tenant_tx(
            // The org id is not in /v1/me; read it from the row the route wrote.
            sqlx::query_scalar::<_, Uuid>("SELECT id FROM orgs WHERE slug = 'cacheplane'")
                .fetch_one(&pool)
                .await
                .unwrap(),
        )
        .await
        .unwrap();
    let rows: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT token, environment, bundle_id FROM push_tokens WHERE device_id = $1",
    )
    .bind(device)
    .fetch_all(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(
        rows,
        [(
            "cd".repeat(20),
            "production".to_string(),
            "com.example.other".to_string()
        )]
    );
}

#[sqlx::test(migrations = false)]
async fn a_pending_request_reaches_the_sender_once(pool: PgPool) {
    let mut w = world(&pool).await;
    register(&w).await;
    let seen: Seen = Seen::default();
    w.state.push = Some(Arc::new(RecordingSender { seen: seen.clone() }));

    let (status, body) = send(
        &w.state,
        "POST",
        "/v1/changes",
        &w.mac,
        Some(pending_request_batch()),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    eventually("the notification", || seen.lock().unwrap().len() == 1).await;
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0].1, "thread-1");
        assert_eq!(seen[0].2, Reason::Approval);
    }

    // The same push again is a retry: nothing more is sent.
    let (status, _) = send(
        &w.state,
        "POST",
        "/v1/changes",
        &w.mac,
        Some(pending_request_batch()),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(seen.lock().unwrap().len(), 1);
}

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> TempDir {
        let dir = std::env::temp_dir().join(format!("b4hub-spool-test-{}", Uuid::now_v7()));
        TempDir(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[sqlx::test(migrations = false)]
async fn spool_writes_a_simulator_file(pool: PgPool) {
    let mut w = world(&pool).await;
    register(&w).await;
    let dir = TempDir::new();
    // `new` creates the directory, nested parents included.
    let spool = dir.0.join("nested");
    w.state.push = Some(Arc::new(SpoolSender::new(spool.clone()).unwrap()));

    let (status, body) = send(
        &w.state,
        "POST",
        "/v1/changes",
        &w.mac,
        Some(pending_request_batch()),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let listing = || -> Vec<String> {
        std::fs::read_dir(&spool)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect()
    };
    eventually("the spool file", || {
        listing().iter().any(|n| n.ends_with(".apns"))
    })
    .await;

    let names = listing();
    assert_eq!(names.len(), 1, "{names:?}");
    assert!(names[0].ends_with(".apns") && !names[0].starts_with('.'));
    let written: Value =
        serde_json::from_slice(&std::fs::read(spool.join(&names[0])).unwrap()).unwrap();
    assert_eq!(
        written,
        spool_payload("thread-1", "Fix the build", Reason::Approval, "", 0, BUNDLE)
    );
    assert_eq!(written["Simulator Target Bundle"], BUNDLE);
}

#[test]
fn apns_refuses() {
    let error = ApnsSender::new().unwrap_err();
    assert!(matches!(error, PushError::Unsupported(_)));
    assert_eq!(
        error.to_string(),
        "push sender unsupported: APNs delivery is not built yet (the deploy slice)"
    );
}
