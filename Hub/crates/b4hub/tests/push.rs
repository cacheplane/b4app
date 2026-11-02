//! The push-token route and delivery after commit (decisions D-122 to D-124) against a real
//! PostgreSQL. Run with `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one
//! database per test.

mod common;

use std::collections::{HashSet, VecDeque};
use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::{to_bytes, Body};
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, Request, StatusCode, Version};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::Router;
use b4hub::push::{
    deliver, ApnsConfig, ApnsSender, Clock, Message, PushError, PushSender, Sent, SpoolSender,
};
use b4hub::serve::{self, AppState};
use b4hub_core::push::{
    payload, spool_payload, spool_withdrawal_payload, withdrawal_payload, Reason,
};
use b4hub_db::push::{Notification, Withdrawal};
use b4hub_db::{devices, orgs, Db};
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use p256::ecdsa::SigningKey;
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;
use tokio::net::TcpListener;
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

type Seen = Arc<Mutex<Vec<Message>>>;

struct RecordingSender {
    seen: Seen,
}

impl PushSender for RecordingSender {
    fn send<'a>(
        &'a self,
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, PushError>> + Send + 'a>> {
        Box::pin(async move {
            self.seen.lock().unwrap().push(message.clone());
            Ok(Sent::Delivered)
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
        let Message::Alert(alert) = &seen[0] else {
            panic!("expected an alert, got {:?}", seen[0]);
        };
        assert_eq!(alert.thread_id, "thread-1");
        assert_eq!(alert.reason, Reason::Approval);
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
        spool_payload(
            "thread-1",
            "Fix the build",
            Reason::Approval,
            "request:request-1",
            1,
            BUNDLE
        )
    );
    assert_eq!(written["Simulator Target Bundle"], BUNDLE);
}

/// The Mac's next batch: the pending request was answered.
fn answered_request_batch() -> String {
    json!({"changes": [
        {"deviceSeq": 4, "wall": 1_761_900_000_004_i64, "table": "runtimeRequests",
         "rowId": "request-1", "op": "update", "column": "state", "value": "resolved"},
    ]})
    .to_string()
}

/// The org's one id, read from the row the seed wrote.
async fn org_id(pool: &PgPool) -> Uuid {
    sqlx::query_scalar("SELECT id FROM orgs WHERE slug = 'cacheplane'")
        .fetch_one(pool)
        .await
        .unwrap()
}

/// The device id behind `token`.
async fn device_id(w: &World, token: &str) -> Uuid {
    let me = send(&w.state, "GET", "/v1/me", token, None).await.1;
    Uuid::parse_str(me["deviceId"].as_str().unwrap()).unwrap()
}

/// The push tokens `device` holds (zero or one).
async fn tokens_of(pool: &PgPool, device: Uuid) -> Vec<String> {
    sqlx::query_scalar("SELECT token FROM push_tokens WHERE device_id = $1")
        .bind(device)
        .fetch_all(pool)
        .await
        .unwrap()
}

#[sqlx::test(migrations = false)]
async fn the_route_delivers_alerts_and_withdrawals(pool: PgPool) {
    let mut w = world(&pool).await;
    register(&w).await;
    let phone = device_id(&w, &w.phone).await;
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
    eventually("the alert", || seen.lock().unwrap().len() == 1).await;

    let (status, body) = send(
        &w.state,
        "POST",
        "/v1/changes",
        &w.mac,
        Some(answered_request_batch()),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    eventually("the withdrawal", || seen.lock().unwrap().len() == 2).await;

    let seen = seen.lock().unwrap();
    match &seen[0] {
        Message::Alert(alert) => {
            assert_eq!(alert.device_id, phone);
            assert_eq!(alert.key, "request:request-1");
            assert_eq!(alert.badge, 1);
        }
        other => panic!("expected an alert, got {other:?}"),
    }
    match &seen[1] {
        Message::Withdraw(withdrawal) => {
            assert_eq!(withdrawal.device_id, phone);
            assert_eq!(withdrawal.token, GOOD_TOKEN);
            assert_eq!(withdrawal.keys, ["request:request-1"]);
        }
        other => panic!("expected a withdrawal, got {other:?}"),
    }
}

#[sqlx::test(migrations = false)]
async fn spool_writes_withdrawals(pool: PgPool) {
    let mut w = world(&pool).await;
    register(&w).await;
    let dir = TempDir::new();
    w.state.push = Some(Arc::new(SpoolSender::new(dir.0.clone()).unwrap()));
    let listing = || -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(&dir.0)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".apns") && !n.starts_with('.'))
            .collect();
        names.sort();
        names
    };

    for batch in [pending_request_batch(), answered_request_batch()] {
        let (status, body) = send(&w.state, "POST", "/v1/changes", &w.mac, Some(batch)).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let want = listing().len() + 1;
        eventually("the spool file", || listing().len() == want).await;
    }

    let names = listing();
    let written: Value =
        serde_json::from_slice(&std::fs::read(dir.0.join(&names[1])).unwrap()).unwrap();
    assert_eq!(
        written,
        spool_withdrawal_payload(&["request:request-1".to_string()], BUNDLE)
    );
    assert!(written["aps"].get("alert").is_none());
}

// The APNs sender, against a fake APNs speaking HTTP/2 without TLS.

const KEY_ID: &str = "KEY1234567";
const TEAM_ID: &str = "TEAM123456";
/// 2026-11-02T00:00:00Z, the clock the sender tests start at.
const T0: u64 = 1_793_577_600;

/// The DER of a PKCS #8 `PrivateKeyInfo` for a P-256 key, up to the 32-byte scalar, as an Apple
/// `.p8` file holds it.
const PKCS8_P256_PREFIX: [u8; 35] = [
    0x30, 0x41, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x27, 0x30, 0x25, 0x02, 0x01,
    0x01, 0x04, 0x20,
];

/// A fresh P-256 key (generated per test, never a real one): its `.p8` PEM and its public half.
struct TestKey {
    pem: String,
    public: DecodingKey,
}

fn test_key() -> TestKey {
    let mut scalar = [0u8; 32];
    getrandom::fill(&mut scalar).expect("randomness");
    let signing = SigningKey::from_bytes(&scalar.into()).expect("a valid scalar");
    let point = signing.verifying_key().to_sec1_point(false);
    let public = DecodingKey::from_ec_components(
        &URL_SAFE_NO_PAD.encode(point.x().unwrap()),
        &URL_SAFE_NO_PAD.encode(point.y().unwrap()),
    )
    .unwrap();
    let mut der = PKCS8_P256_PREFIX.to_vec();
    der.extend_from_slice(&scalar);
    let pem = format!(
        "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
        STANDARD.encode(der)
    );
    TestKey { pem, public }
}

/// One request the fake APNs received.
#[derive(Debug, Clone)]
struct Received {
    version: Version,
    token: String,
    headers: HeaderMap,
    body: Value,
}

impl Received {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).map(|v| v.to_str().unwrap())
    }

    fn jwt(&self) -> &str {
        self.header("authorization")
            .and_then(|v| v.strip_prefix("bearer "))
            .expect("a bearer provider token")
    }
}

/// An answer the fake APNs gives: the status and Apple's reason.
type Answer = (u16, Option<&'static str>);

#[derive(Clone, Default)]
struct FakeApnsState {
    received: Arc<Mutex<Vec<Received>>>,
    /// The answers for the next requests, in order: status and Apple's reason. 200 once empty.
    answers: Arc<Mutex<VecDeque<Answer>>>,
}

struct FakeApns {
    url: Url,
    state: FakeApnsState,
    server: tokio::task::JoinHandle<()>,
}

impl Drop for FakeApns {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl FakeApns {
    async fn start() -> FakeApns {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = Url::parse(&format!("http://{}/", listener.local_addr().unwrap())).unwrap();
        let state = FakeApnsState::default();
        let app = Router::new()
            .route("/3/device/{token}", post(fake_apns_route))
            .with_state(state.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        FakeApns { url, state, server }
    }

    fn answer(&self, status: u16, reason: Option<&'static str>) {
        self.state
            .answers
            .lock()
            .unwrap()
            .push_back((status, reason));
    }

    fn received(&self) -> Vec<Received> {
        self.state.received.lock().unwrap().clone()
    }
}

async fn fake_apns_route(
    State(state): State<FakeApnsState>,
    Path(token): Path<String>,
    request: Request<Body>,
) -> Response {
    let version = request.version();
    let headers = request.headers().clone();
    let bytes = to_bytes(request.into_body(), 1024 * 1024).await.unwrap();
    state.received.lock().unwrap().push(Received {
        version,
        token,
        headers,
        body: serde_json::from_slice(&bytes).unwrap(),
    });
    let (status, reason) = state
        .answers
        .lock()
        .unwrap()
        .pop_front()
        .unwrap_or((200, None));
    let status = StatusCode::from_u16(status).unwrap();
    let apns_id = Uuid::now_v7().to_string().to_uppercase();
    match reason {
        Some(reason) => (
            status,
            [("apns-id", apns_id)],
            axum::Json(json!({ "reason": reason })),
        )
            .into_response(),
        None => (status, [("apns-id", apns_id)]).into_response(),
    }
}

/// A clock the test moves: Unix seconds.
fn fixed_clock(at: &Arc<AtomicU64>) -> Clock {
    let at = at.clone();
    Arc::new(move || at.load(Ordering::SeqCst))
}

/// A clock one second later at every reading, so each provider token minted is distinct.
fn ticking_clock() -> Clock {
    let at = Arc::new(AtomicU64::new(T0));
    Arc::new(move || at.fetch_add(1, Ordering::SeqCst))
}

/// The sender with sandbox tokens going to `sandbox` and production tokens to `production`.
fn apns(key: &TestKey, sandbox: &FakeApns, production: &FakeApns, clock: Clock) -> ApnsSender {
    let config = ApnsConfig {
        key_id: KEY_ID.into(),
        team_id: TEAM_ID.into(),
        private_key_pem: key.pem.clone(),
    };
    ApnsSender::with_endpoints(config, sandbox.url.clone(), production.url.clone())
        .unwrap()
        .with_clock(clock)
}

fn alert(environment: &str) -> Notification {
    Notification {
        device_id: Uuid::now_v7(),
        token: GOOD_TOKEN.into(),
        environment: environment.into(),
        bundle_id: BUNDLE.into(),
        thread_id: "thread-1".into(),
        title: "Fix the build".into(),
        reason: Reason::Approval,
        key: "request:request-1".into(),
        badge: 3,
    }
}

fn withdrawal() -> Withdrawal {
    Withdrawal {
        device_id: Uuid::now_v7(),
        token: GOOD_TOKEN.into(),
        environment: "production".into(),
        bundle_id: BUNDLE.into(),
        keys: vec!["request:request-1".into(), "turn:turn-1".into()],
    }
}

#[derive(Debug, serde::Deserialize)]
struct ProviderClaims {
    iss: String,
    iat: u64,
}

/// Verifies `jwt` with the key's public half and returns its claims.
fn verify(jwt: &str, key: &TestKey) -> ProviderClaims {
    let header = jsonwebtoken::decode_header(jwt).unwrap();
    assert_eq!(header.alg, Algorithm::ES256);
    assert_eq!(header.kid.as_deref(), Some(KEY_ID));
    let mut validation = Validation::new(Algorithm::ES256);
    validation.required_spec_claims = HashSet::new();
    validation.validate_exp = false;
    jsonwebtoken::decode::<ProviderClaims>(jwt, &key.public, &validation)
        .unwrap()
        .claims
}

#[tokio::test]
async fn alert_carries_jwt_topic_and_headers() {
    let key = test_key();
    let (sandbox, production) = (FakeApns::start().await, FakeApns::start().await);
    let now = Arc::new(AtomicU64::new(T0));
    let sender = apns(&key, &sandbox, &production, fixed_clock(&now));
    assert_eq!(sender.name(), "apns");
    assert!(!format!("{sender:?}").contains("PRIVATE KEY"));

    let message = alert("sandbox");
    let sent = sender.send(&Message::Alert(message.clone())).await.unwrap();
    assert_eq!(sent, Sent::Delivered);
    assert!(production.received().is_empty());
    let received = sandbox.received();
    assert_eq!(received.len(), 1);
    let r = &received[0];
    assert_eq!(r.version, Version::HTTP_2);
    assert_eq!(r.token, GOOD_TOKEN);
    assert_eq!(r.header("apns-topic"), Some(BUNDLE));
    assert_eq!(r.header("apns-push-type"), Some("alert"));
    assert_eq!(r.header("apns-priority"), Some("10"));
    assert_eq!(r.header("apns-collapse-id"), Some("request:request-1"));
    let expiration: u64 = r.header("apns-expiration").unwrap().parse().unwrap();
    assert!(expiration > T0, "{expiration}");
    assert_eq!(r.header("content-type"), Some("application/json"));
    assert_eq!(
        r.body,
        payload(
            "thread-1",
            "Fix the build",
            Reason::Approval,
            "request:request-1",
            3
        )
    );
    let claims = verify(r.jwt(), &key);
    assert_eq!(claims.iss, TEAM_ID);
    assert_eq!(claims.iat, T0);

    // A production token goes to the production endpoint.
    sender
        .send(&Message::Alert(alert("production")))
        .await
        .unwrap();
    assert_eq!(production.received().len(), 1);
    assert_eq!(sandbox.received().len(), 1);
}

#[tokio::test]
async fn withdrawal_is_background_priority_5() {
    let key = test_key();
    let (sandbox, production) = (FakeApns::start().await, FakeApns::start().await);
    let now = Arc::new(AtomicU64::new(T0));
    let sender = apns(&key, &sandbox, &production, fixed_clock(&now));
    let message = withdrawal();
    let sent = sender
        .send(&Message::Withdraw(message.clone()))
        .await
        .unwrap();
    assert_eq!(sent, Sent::Delivered);
    let received = production.received();
    assert_eq!(received.len(), 1);
    let r = &received[0];
    assert_eq!(r.version, Version::HTTP_2);
    assert_eq!(r.header("apns-topic"), Some(BUNDLE));
    assert_eq!(r.header("apns-push-type"), Some("background"));
    assert_eq!(r.header("apns-priority"), Some("5"));
    assert_eq!(r.header("apns-collapse-id"), None);
    let expiration: u64 = r.header("apns-expiration").unwrap().parse().unwrap();
    assert!(expiration > T0, "{expiration}");
    assert_eq!(r.body, withdrawal_payload(&message.keys));
    assert!(r.body["aps"].get("alert").is_none());
    assert!(r.body["aps"].get("badge").is_none());
    assert!(r.body["aps"].get("sound").is_none());
    verify(r.jwt(), &key);
}

#[sqlx::test(migrations = false)]
async fn dead_token_is_deleted(pool: PgPool) {
    let w = world(&pool).await;
    let org = org_id(&pool).await;
    let phone = device_id(&w, &w.phone).await;
    let key = test_key();
    let (sandbox, production) = (FakeApns::start().await, FakeApns::start().await);
    let sender: Arc<dyn PushSender> = Arc::new(apns(&key, &sandbox, &production, ticking_clock()));
    let message = || {
        Message::Alert(Notification {
            device_id: phone,
            ..alert("sandbox")
        })
    };

    for (status, reason) in [
        (410, "Unregistered"),
        (400, "BadDeviceToken"),
        (400, "DeviceTokenNotForTopic"),
    ] {
        register(&w).await;
        assert_eq!(tokens_of(&pool, phone).await, [GOOD_TOKEN]);
        sandbox.answer(status, Some(reason));
        deliver(sender.clone(), w.state.db.clone(), org, vec![message()]);
        let mut gone = false;
        let started = Instant::now();
        while !gone {
            assert!(
                started.elapsed() < Duration::from_secs(2),
                "{reason}: the token was not deleted"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
            gone = tokens_of(&pool, phone).await.is_empty();
        }
    }

    // Any other refusal leaves the token alone.
    register(&w).await;
    let before = sandbox.received().len();
    sandbox.answer(400, Some("BadCollapseId"));
    deliver(sender.clone(), w.state.db.clone(), org, vec![message()]);
    eventually("the refused send", || {
        sandbox.received().len() == before + 1
    })
    .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(tokens_of(&pool, phone).await, [GOOD_TOKEN]);
    // The sender reports a dead token as such.
    sandbox.answer(410, Some("Unregistered"));
    assert_eq!(sender.send(&message()).await.unwrap(), Sent::DeadToken);
}

#[tokio::test]
async fn expired_jwt_is_reminted_once() {
    let key = test_key();
    for reason in ["ExpiredProviderToken", "InvalidProviderToken"] {
        let (sandbox, production) = (FakeApns::start().await, FakeApns::start().await);
        let sender = apns(&key, &sandbox, &production, ticking_clock());
        sandbox.answer(403, Some(reason));
        let sent = sender.send(&Message::Alert(alert("sandbox"))).await;
        assert_eq!(sent.unwrap(), Sent::Delivered, "{reason}");
        let received = sandbox.received();
        assert_eq!(received.len(), 2, "{reason}");
        let (first, second) = (
            verify(received[0].jwt(), &key),
            verify(received[1].jwt(), &key),
        );
        assert!(
            second.iat > first.iat,
            "{reason}: the token was not re-minted"
        );

        // Refused again after re-minting: dropped, not retried a third time.
        sandbox.answer(403, Some(reason));
        sandbox.answer(403, Some(reason));
        let error = sender
            .send(&Message::Alert(alert("sandbox")))
            .await
            .unwrap_err();
        assert!(
            matches!(&error, PushError::Rejected { status: 403, reason: Some(r), .. } if r == reason),
            "{error}"
        );
        assert_eq!(sandbox.received().len(), 4, "{reason}");
    }
}

#[tokio::test]
async fn server_error_retries_once_then_drops() {
    let key = test_key();
    let (sandbox, production) = (FakeApns::start().await, FakeApns::start().await);
    let now = Arc::new(AtomicU64::new(T0));
    let sender = apns(&key, &sandbox, &production, fixed_clock(&now));
    let message = Message::Alert(alert("sandbox"));
    let send = || sender.send(&message);

    // A 5xx, then success: delivered on the retry, after a pause.
    sandbox.answer(503, Some("ServiceUnavailable"));
    let started = Instant::now();
    assert_eq!(send().await.unwrap(), Sent::Delivered);
    assert!(started.elapsed() >= Duration::from_millis(500));
    assert_eq!(sandbox.received().len(), 2);

    // 429 is retried too.
    sandbox.answer(429, Some("TooManyRequests"));
    assert_eq!(send().await.unwrap(), Sent::Delivered);
    assert_eq!(sandbox.received().len(), 4);

    // Twice in a row: dropped, with Apple's answer in the error.
    sandbox.answer(500, Some("InternalServerError"));
    sandbox.answer(500, Some("InternalServerError"));
    let error = send().await.unwrap_err();
    assert!(
        matches!(&error, PushError::Rejected { status: 500, reason: Some(r), apns_id: Some(_) }
            if r == "InternalServerError"),
        "{error}"
    );
    assert_eq!(sandbox.received().len(), 6);
    assert!(!error.to_string().contains(GOOD_TOKEN));

    // Anything else is not retried.
    sandbox.answer(400, Some("BadPriority"));
    let error = send().await.unwrap_err();
    assert!(
        matches!(&error, PushError::Rejected { status: 400, .. }),
        "{error}"
    );
    assert_eq!(sandbox.received().len(), 7);

    // A transport failure is retried once, then dropped; the error does not carry the URL (and
    // so the token).
    let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dead = Url::parse(&format!("http://{}/", closed.local_addr().unwrap())).unwrap();
    drop(closed);
    let config = ApnsConfig {
        key_id: KEY_ID.into(),
        team_id: TEAM_ID.into(),
        private_key_pem: key.pem.clone(),
    };
    let unreachable = ApnsSender::with_endpoints(config, dead.clone(), dead).unwrap();
    let error = unreachable
        .send(&Message::Alert(alert("sandbox")))
        .await
        .unwrap_err();
    assert!(matches!(error, PushError::Transport(_)), "{error}");
    assert!(!error.to_string().contains(GOOD_TOKEN), "{error}");
}

#[tokio::test]
async fn jwt_reused_within_50_minutes() {
    let key = test_key();
    let (sandbox, production) = (FakeApns::start().await, FakeApns::start().await);
    let now = Arc::new(AtomicU64::new(T0));
    let sender = apns(&key, &sandbox, &production, fixed_clock(&now));
    let mut jwts = Vec::new();
    for at in [T0, T0 + 49 * 60 + 59, T0 + 50 * 60] {
        now.store(at, Ordering::SeqCst);
        sender
            .send(&Message::Alert(alert("sandbox")))
            .await
            .unwrap();
        jwts.push(sandbox.received().last().unwrap().jwt().to_string());
    }
    assert_eq!(jwts[0], jwts[1], "reused within 50 minutes");
    assert_ne!(jwts[1], jwts[2], "re-minted at 50 minutes");
    assert_eq!(verify(&jwts[2], &key).iat, T0 + 50 * 60);
}
