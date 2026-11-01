//! `POST /v1/changes` and the long-poll `GET /v1/changes` against a real PostgreSQL. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

use std::time::{Duration, Instant};

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::Router;
use b4hub::serve::{self, AppState};
use b4hub_core::change::Change;
use b4hub_db::{devices, orgs, Db};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};
use sqlx::PgPool;
use tokio::net::TcpListener;
use tower::ServiceExt;
use url::Url;

const FIXTURE: &str = include_str!("../../../../Tests/Fixtures/sync/changes.json");

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

/// A migrated database, the app state (connected as `b4hub_app`), and the owner handle.
async fn migrated(pool: &PgPool) -> (Db, AppState) {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(pool)).await.unwrap();
    let app = Db::connect(&app_url(pool)).await.unwrap();
    (admin, AppState::new(app))
}

/// Seeds `username` in the org `cacheplane`, enrolls a device for them, and returns its token.
async fn token_for(admin: &Db, state: &AppState, username: &str) -> String {
    let seeded = orgs::seed(
        admin,
        "cacheplane",
        "Cacheplane",
        username,
        username,
        &format!("{username}@example.test"),
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        admin,
        seeded.org_id,
        seeded.user_id,
        Duration::from_secs(600),
    )
    .await
    .unwrap();
    devices::redeem(&state.db, &code, "test device", "macos")
        .await
        .unwrap()
        .token
}

/// The fixture after the coordinator's upload filter, applied by hand (see the Task 4 brief).
fn filtered_fixture() -> Vec<Change> {
    let mut changes: Vec<Change> = serde_json::from_str(FIXTURE).unwrap();
    for change in &mut changes {
        let Some(Value::Object(row)) = change.value.as_mut() else {
            continue;
        };
        if change.table == "connections" {
            for column in ["authReference", "localServerId", "target"] {
                row.insert(column.into(), Value::Null);
            }
        }
        if change.table == "displayItems" {
            let bytes = serde_json::to_vec(&row["payload"]).unwrap().len();
            if bytes > 1_048_576 {
                row.insert("payload".into(), json!({"truncated": true, "bytes": bytes}));
            }
        }
    }
    changes
}

fn push_body(changes: &[Change]) -> String {
    json!({ "changes": changes }).to_string()
}

/// One small change: a thread-less connection insert with a distinguishing id.
fn small_change(seq: i64, row_id: &str) -> Change {
    serde_json::from_value(json!({
        "deviceSeq": seq, "wall": 1_761_900_000_000_i64 + seq, "table": "connections",
        "rowId": row_id, "op": "insert", "column": null,
        "value": {"id": row_id, "kind": "codex", "label": row_id},
    }))
    .unwrap()
}

/// Sends one request through a fresh router over `state` and returns the status and JSON body.
async fn send(
    state: &AppState,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<String>,
) -> (StatusCode, Value) {
    send_to(serve::router(state.clone()), method, path, token, body).await
}

async fn send_to(
    router: Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<String>,
) -> (StatusCode, Value) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(token) = token {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let request = match body {
        Some(body) => request
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body)),
        None => request.body(Body::empty()),
    }
    .unwrap();
    let response = router.oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 16 * 1024 * 1024)
        .await
        .unwrap();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or_else(|_| {
            panic!(
                "{method} {path} answered {status} with a body that is not JSON: {:?}",
                String::from_utf8_lossy(&bytes[..bytes.len().min(200)])
            )
        })
    };
    (status, value)
}

fn error_code(body: &Value) -> &str {
    body["error"]["details"]["code"]
        .as_str()
        .unwrap_or_default()
}

async fn count(state: &AppState, org: &str, table: &str) -> i64 {
    // The owner is subject to forced row-level security too, so set the tenant first.
    let mut tx = state.db.pool.begin().await.unwrap();
    sqlx::query(
        "SELECT set_config('b4hub.org_id', (SELECT id::text FROM orgs WHERE slug = $1), true)",
    )
    .bind(org)
    .execute(&mut *tx)
    .await
    .unwrap();
    let n = sqlx::query_scalar(&format!("SELECT count(*) FROM \"{table}\""))
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    n
}

#[sqlx::test(migrations = false)]
async fn push_then_pull_over_http(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;

    let (status, body) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&filtered_fixture())),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body, json!({"acceptedThrough": 12}));

    // Retrying the same batch is the same answer.
    let (status, body) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&filtered_fixture())),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"acceptedThrough": 12}));

    let (status, page) = send(
        &state,
        "GET",
        "/v1/changes?after=0&limit=5",
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{page}");
    assert_eq!(page["more"], true);
    assert_eq!(page["next"], 5);
    let changes = page["changes"].as_array().unwrap();
    assert_eq!(changes.len(), 5);
    assert_eq!(changes[0]["hubSeq"], 1);
    assert_eq!(changes[0]["deviceSeq"], 1);
    assert_eq!(changes[0]["table"], "connections");
    assert_eq!(changes[0]["rowId"], "conn-1");
    assert_eq!(changes[0]["op"], "insert");
    assert!(changes[0]["deviceId"].as_str().is_some());
    assert_eq!(changes[0]["value"]["label"], "Codex");

    let (_, rest) = send(
        &state,
        "GET",
        "/v1/changes?after=5&limit=1000",
        Some(&token),
        None,
    )
    .await;
    assert_eq!(rest["changes"].as_array().unwrap().len(), 7);
    assert_eq!(
        (rest["more"].clone(), rest["next"].clone()),
        (json!(false), json!(12))
    );

    // The defaults (no query) are after=0, limit 1000, no waiting.
    let (_, all) = send(&state, "GET", "/v1/changes", Some(&token), None).await;
    assert_eq!(all["changes"].as_array().unwrap().len(), 12);

    // `limit=0` is clamped to one change, not an error.
    let (status, one) = send(&state, "GET", "/v1/changes?limit=0", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(one["changes"].as_array().unwrap().len(), 1);
}

#[sqlx::test(migrations = false)]
async fn pull_pages_and_long_polls(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    let other = token_for(&admin, &state, "alice").await;
    let (status, _) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&filtered_fixture())),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // A long-poll at the end of the feed wakes when a push lands 200 ms in.
    let started = Instant::now();
    let poll = send(
        &state,
        "GET",
        "/v1/changes?after=12&wait=5",
        Some(&token),
        None,
    );
    let push = async {
        tokio::time::sleep(Duration::from_millis(200)).await;
        send(
            &state,
            "POST",
            "/v1/changes",
            Some(&token),
            Some(push_body(&[small_change(13, "conn-2")])),
        )
        .await
    };
    let ((status, page), (push_status, _)) = tokio::join!(poll, push);
    let elapsed = started.elapsed();
    assert_eq!(push_status, StatusCode::OK);
    assert_eq!(status, StatusCode::OK, "{page}");
    assert!(
        elapsed >= Duration::from_millis(150) && elapsed < Duration::from_secs(1),
        "woke after {elapsed:?}"
    );
    let changes = page["changes"].as_array().unwrap();
    assert_eq!(changes.len(), 1, "{page}");
    assert_eq!(changes[0]["rowId"], "conn-2");
    assert_eq!(page["next"], changes[0]["hubSeq"]);

    // Another user in the same org pulls nothing, however long they wait for it to arrive.
    let (status, theirs) = send(&state, "GET", "/v1/changes?after=0", Some(&other), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(theirs["changes"], json!([]));
    assert_eq!(
        (theirs["next"].clone(), theirs["more"].clone()),
        (json!(0), json!(false))
    );
}

#[sqlx::test(migrations = false)]
async fn an_empty_long_poll_times_out_with_an_empty_page(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;

    let started = Instant::now();
    let (status, page) = send(
        &state,
        "GET",
        "/v1/changes?after=0&wait=1",
        Some(&token),
        None,
    )
    .await;
    let elapsed = started.elapsed();
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page, json!({"changes": [], "next": 0, "more": false}));
    assert!(
        elapsed >= Duration::from_millis(900) && elapsed < Duration::from_secs(3),
        "{elapsed:?}"
    );
}

#[sqlx::test(migrations = false)]
async fn shutdown_releases_open_long_polls(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;

    let started = Instant::now();
    let poll = send(
        &state,
        "GET",
        "/v1/changes?after=0&wait=25",
        Some(&token),
        None,
    );
    let stop = async {
        tokio::time::sleep(Duration::from_millis(200)).await;
        state.shutdown.trigger();
    };
    let ((status, page), ()) = tokio::join!(poll, stop);
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["changes"], json!([]));
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "{:?}",
        started.elapsed()
    );

    // A poll that starts after shutdown began does not wait at all.
    let started = Instant::now();
    let (status, _) = send(
        &state,
        "GET",
        "/v1/changes?after=0&wait=25",
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[sqlx::test(migrations = false)]
async fn oversize_value_is_rejected_per_change(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;

    // The raw fixture carries a 2 MiB payload (deviceSeq 7). The push is a 200: that one change
    // is rejected, is not recorded, and the rest of the batch lands.
    let raw: Vec<Change> = serde_json::from_str(FIXTURE).unwrap();
    let (status, body) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&raw)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body,
        json!({"acceptedThrough": 12, "rejected": [{"deviceSeq": 7, "code": "payload_too_large"}]})
    );
    assert_eq!(count(&state, "cacheplane", "changes").await, 11);
    assert_eq!(count(&state, "cacheplane", "displayItems").await, 3);

    // A value exactly at the limit is accepted; one byte over is rejected. (`"x"` quotes count.)
    let limit = b4hub_core::change::MAX_PAYLOAD_BYTES;
    let sized = |bytes: usize| -> Change {
        let mut change = small_change(100, "conn-big");
        change.value = Some(Value::String("y".repeat(bytes - 2)));
        change
    };
    let (status, body) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&[sized(limit + 1)])),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body,
        json!({"acceptedThrough": 100, "rejected": [{"deviceSeq": 100, "code": "payload_too_large"}]})
    );
    let (status, body) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&[sized(limit)])),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body,
        json!({"acceptedThrough": 100}),
        "no rejected key when none"
    );
    assert_eq!(count(&state, "cacheplane", "changes").await, 12);

    // The body limit is still 413: a body over 32 MiB is refused before it is read.
    let body = format!(
        r#"{{"changes": [{{"deviceSeq": 1, "wall": 0, "table": "connections", "rowId": "c", "op": "insert", "value": "{}"}}]}}"#,
        "z".repeat(33 * 1024 * 1024)
    );
    let (status, body) = send(&state, "POST", "/v1/changes", Some(&token), Some(body)).await;
    assert_eq!(status, StatusCode::PAYLOAD_TOO_LARGE, "{body}");
    assert_eq!(error_code(&body), "payload_too_large");
}

#[sqlx::test(migrations = false)]
async fn a_malformed_clock_is_rejected_per_change(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    let mut bad = small_change(2, "conn-bad");
    bad.hlc = Some("not-a-clock".into());
    let (status, body) = send(
        &state,
        "POST",
        "/v1/changes",
        Some(&token),
        Some(push_body(&[
            small_change(1, "conn-1"),
            bad,
            small_change(3, "conn-3"),
        ])),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body,
        json!({"acceptedThrough": 3, "rejected": [{"deviceSeq": 2, "code": "invalid_clock"}]})
    );
    // The other two landed; the bad one was neither logged nor applied.
    assert_eq!(count(&state, "cacheplane", "changes").await, 2);
    assert_eq!(count(&state, "cacheplane", "connections").await, 2);
}

#[sqlx::test(migrations = false)]
async fn bad_requests_are_refused_in_the_envelope(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    let post = |body: Value| {
        let state = state.clone();
        let token = token.clone();
        async move {
            send(
                &state,
                "POST",
                "/v1/changes",
                Some(&token),
                Some(body.to_string()),
            )
            .await
        }
    };
    let good = json!({
        "deviceSeq": 1, "wall": 2, "table": "connections", "rowId": "c", "op": "insert",
        "value": {"id": "c"},
    });

    for body in [
        json!({"changes": [], "extra": 1}),
        json!({"changes": [{"deviceId": "x", "deviceSeq": 1, "wall": 2, "table": "connections", "rowId": "c", "op": "delete"}]}),
        json!({"changes": [{"deviceSeq": 1, "wall": 2, "table": "connections", "rowId": "c", "op": "upsert"}]}),
        json!({"changes": [{"wall": 2, "table": "connections", "rowId": "c", "op": "delete"}]}),
        json!({"nope": []}),
    ] {
        let (status, response) = post(body.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body} -> {response}");
        assert_eq!(error_code(&response), "invalid_request");
    }
    let too_many = vec![good.clone(); b4hub_core::change::MAX_PUSH_CHANGES + 1];
    let (status, response) = post(json!({ "changes": too_many })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{response}");
    assert_eq!(error_code(&response), "invalid_request");
    assert_eq!(count(&state, "cacheplane", "changes").await, 0);

    // An empty batch is fine and reports nothing accepted yet.
    let (status, response) = post(json!({"changes": []})).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(response, json!({"acceptedThrough": 0}));

    for query in ["after=abc", "limit=x", "wait=-1", "after=1.5"] {
        let (status, response) = send(
            &state,
            "GET",
            &format!("/v1/changes?{query}"),
            Some(&token),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{query} -> {response}");
        assert_eq!(error_code(&response), "invalid_request");
    }

    // A cursor below the horizon (0 in M8a) must resync.
    let (status, response) = send(&state, "GET", "/v1/changes?after=-1", Some(&token), None).await;
    assert_eq!(status, StatusCode::GONE, "{response}");
    assert_eq!(error_code(&response), "resync_required");
    assert_eq!(response["error"]["kind"], "request_error");

    // The method router answers other methods in the envelope too.
    let (status, response) = send(&state, "DELETE", "/v1/changes", Some(&token), None).await;
    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
    assert_eq!(error_code(&response), "method_not_allowed");
}

#[sqlx::test(migrations = false)]
async fn a_token_is_required_before_the_body_is_read(pool: PgPool) {
    let (_admin, state) = migrated(&pool).await;
    let big = push_body(&filtered_fixture());
    for token in [None, Some("not-a-token")] {
        let (status, body) = send(&state, "POST", "/v1/changes", token, Some(big.clone())).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{body}");
        assert_eq!(error_code(&body), "unauthorized");
        // Not even a malformed body gets as far as being parsed without a token.
        let (status, _) = send(&state, "POST", "/v1/changes", token, Some("{".into())).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, _) = send(&state, "GET", "/v1/changes?wait=5", token, None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
}

type HttpClient = Client<HttpConnector, Full<Bytes>>;

async fn http(
    client: &HttpClient,
    method: &str,
    url: &str,
    token: &str,
    body: Option<String>,
) -> (StatusCode, Value) {
    let request = hyper::Request::builder()
        .method(method)
        .uri(url)
        .header(header::AUTHORIZATION, format!("Bearer {token}"))
        .header(header::CONTENT_TYPE, "application/json")
        .body(Full::new(Bytes::from(body.unwrap_or_default())))
        .unwrap();
    let response = client.request(request).await.unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

/// The lost-wakeup race over a real socket: a push that lands between a pull's emptiness check
/// and its wait must still wake it. The pull and the push start together, the push delayed by
/// 0 to 1.95 ms in 50 microsecond steps (three sweeps, to cross the pull's query window), and
/// every round must come back inside a second even though the pull is willing to wait five. The
/// window is a few hundred microseconds wide, so this catches taking the wake-up future after
/// the query only some of the time; the deterministic check of the ordering is the
/// `long_poll` unit test in `routes/changes.rs`.
#[sqlx::test(migrations = false)]
async fn pull_over_real_tcp_does_not_miss_a_push_in_the_gap(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, serve::router(state)).await.unwrap();
    });
    let client: HttpClient = Client::builder(TokioExecutor::new()).build_http();

    let mut cursor = 0_i64;
    // One round with the push 50 ms after the pull started, then 120 with the push at 0 to
    // 1.95 ms.
    let delays: Vec<Duration> = std::iter::once(Duration::from_millis(50))
        .chain((0..120).map(|round| Duration::from_micros((round % 40) * 50)))
        .collect();
    for (round, delay) in delays.into_iter().enumerate() {
        let seq = round as i64 + 1;
        let row_id = format!("conn-{round}");
        let started = Instant::now();
        let pull_url = format!("{base}/v1/changes?after={cursor}&wait=5");
        let pull = http(&client, "GET", &pull_url, &token, None);
        let push = async {
            tokio::time::sleep(delay).await;
            http(
                &client,
                "POST",
                &format!("{base}/v1/changes"),
                &token,
                Some(push_body(&[small_change(seq, &row_id)])),
            )
            .await
        };
        let ((pull_status, page), (push_status, _)) = tokio::join!(pull, push);
        let elapsed = started.elapsed();
        assert_eq!(push_status, StatusCode::OK, "round {round}");
        assert_eq!(pull_status, StatusCode::OK, "round {round}: {page}");
        assert!(
            elapsed < Duration::from_secs(1),
            "round {round} took {elapsed:?}: {page}"
        );
        let changes = page["changes"].as_array().unwrap();
        assert_eq!(changes.len(), 1, "round {round}: {page}");
        assert_eq!(changes[0]["rowId"], row_id, "round {round}");
        cursor = page["next"].as_i64().unwrap();
    }
    server.abort();
}

// ---- Pruning, the snapshot, and the devices list (M8b task 6) ----

/// Marks every change of `org` as received two days ago, as the owner under the org's tenant.
async fn backdate(state: &AppState, org: &str) {
    let mut tx = state.db.pool.begin().await.unwrap();
    sqlx::query(
        "SELECT set_config('b4hub.org_id', (SELECT id::text FROM orgs WHERE slug = $1), true)",
    )
    .bind(org)
    .execute(&mut *tx)
    .await
    .unwrap();
    sqlx::query("UPDATE changes SET received_at = now() - interval '2 days'")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
}

async fn push_fixture(state: &AppState, token: &str) {
    let (status, body) = send(
        state,
        "POST",
        "/v1/changes",
        Some(token),
        Some(push_body(&filtered_fixture())),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
}

#[sqlx::test(migrations = false)]
async fn devices_and_snapshot_need_a_token(pool: PgPool) {
    let (_admin, state) = migrated(&pool).await;
    for path in ["/v1/devices", "/v1/snapshot"] {
        for token in [None, Some("not-a-token")] {
            let (status, body) = send(&state, "GET", path, token, None).await;
            assert_eq!(status, StatusCode::UNAUTHORIZED, "{path}: {body}");
            assert_eq!(error_code(&body), "unauthorized");
        }
    }
}

#[sqlx::test(migrations = false)]
async fn devices_lists_this_users_devices_over_http(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let mac = token_for(&admin, &state, "blove").await;
    let other = token_for(&admin, &state, "alice").await;

    let (status, body) = send(&state, "GET", "/v1/devices", Some(&mac), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let devices = body["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 1);
    let device = &devices[0];
    assert_eq!(device["name"], "test device");
    assert_eq!(device["platform"], "macos");
    assert!(device["id"].as_str().is_some_and(|id| id.len() == 36));
    assert!(device["revokedAt"].is_null());
    assert!(device.get("lastSeenAt").is_some());
    let mut keys: Vec<&str> = device
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(keys, ["id", "lastSeenAt", "name", "platform", "revokedAt"]);

    // Another user's device list is their own; a revoked device stays listed with revokedAt.
    let (_, theirs) = send(&state, "GET", "/v1/devices", Some(&other), None).await;
    assert_eq!(theirs["devices"].as_array().unwrap().len(), 1);
    assert_ne!(theirs["devices"][0]["id"], device["id"]);
    let (status, _) = send(&state, "DELETE", "/v1/devices/self", Some(&other), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, body) = send(&state, "POST", "/v1/devices", Some(&mac), None).await;
    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED, "{body}");
}

#[sqlx::test(migrations = false)]
async fn a_pruned_cursor_resyncs_through_the_snapshot_over_http(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    let other = token_for(&admin, &state, "alice").await;
    push_fixture(&state, &token).await;
    backdate(&state, "cacheplane").await;

    let org = b4hub_db::orgs::resolve_org(&admin, Some("cacheplane"))
        .await
        .unwrap();
    let b4hub_db::orgs::OrgChoice::Found(org_id) = org else {
        panic!("{org:?}")
    };
    let horizon = b4hub_db::prune::prune(&state.db, org_id, Duration::from_secs(86_400))
        .await
        .unwrap();
    assert_eq!(horizon, 12);

    let (status, body) = send(&state, "GET", "/v1/changes?after=3", Some(&token), None).await;
    assert_eq!(status, StatusCode::GONE, "{body}");
    assert_eq!(error_code(&body), "resync_required");
    // The long-poll path answers the same way.
    let (status, _) = send(
        &state,
        "GET",
        "/v1/changes?after=0&wait=1",
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::GONE);

    let (status, snapshot) = send(&state, "GET", "/v1/snapshot", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK, "{snapshot}");
    assert_eq!(snapshot["next"], 12);
    let changes = snapshot["changes"].as_array().unwrap();
    assert!(!changes.is_empty());
    assert!(changes
        .iter()
        .all(|c| c["hubSeq"] == 0 && c["op"] == "insert"));
    assert_eq!(changes[0]["table"], "connections");
    assert!(changes[0]["hlc"]
        .as_str()
        .unwrap()
        .starts_with("000000000000-0000-"));
    let clock = &snapshot["clocks"][0];
    for key in ["table", "rowId", "column", "hlc"] {
        assert!(clock.get(key).is_some(), "{key}");
    }
    let (_, theirs) = send(&state, "GET", "/v1/snapshot", Some(&other), None).await;
    assert_eq!(theirs["changes"], json!([]));
    assert_eq!(theirs["clocks"], json!([]));
    assert_eq!(theirs["next"], 12);

    let (status, body) = send(&state, "GET", "/v1/changes?after=12", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["changes"], json!([]));
    assert_eq!(body["next"], 12);
}

#[sqlx::test(migrations = false)]
async fn the_prune_loop_prunes_and_stops_promptly_on_shutdown(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    push_fixture(&state, &token).await;
    backdate(&state, "cacheplane").await;

    let task = tokio::spawn(serve::prune_loop(
        state.db.clone(),
        Duration::from_secs(86_400),
        Duration::from_secs(3600),
        state.shutdown.clone(),
    ));
    // The first pass runs at once: the cursor behind the horizon starts to resync.
    let started = Instant::now();
    loop {
        let (status, _) = send(&state, "GET", "/v1/changes?after=0", Some(&token), None).await;
        if status == StatusCode::GONE {
            break;
        }
        assert!(started.elapsed() < Duration::from_secs(10), "never pruned");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(count(&state, "cacheplane", "changes").await, 0);

    // Shutdown ends the hour-long wait immediately.
    let stopping = Instant::now();
    state.shutdown.trigger();
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .expect("the prune loop stops on shutdown")
        .unwrap();
    assert!(stopping.elapsed() < Duration::from_secs(2));
}

#[sqlx::test(migrations = false)]
async fn the_prune_command_prunes_one_org_or_all(pool: PgPool) {
    use clap::Parser;

    let (admin, state) = migrated(&pool).await;
    let token = token_for(&admin, &state, "blove").await;
    push_fixture(&state, &token).await;
    backdate(&state, "cacheplane").await;
    let settings = b4hub::cli::Settings::from_pairs([("DATABASE_ADMIN_URL", admin_url(&pool))]);
    let run = |args: &[&str]| {
        let cli = b4hub::cli::Cli::try_parse_from(
            ["b4hub", "prune"].into_iter().chain(args.iter().copied()),
        )
        .unwrap();
        let settings = settings.clone();
        async move { b4hub::cli::run(cli, &settings).await }
    };

    // An unknown org is a configuration error (exit 2) before anything is pruned.
    let error = run(&["--older-than-days", "1", "--org", "nope"])
        .await
        .unwrap_err();
    assert_eq!(error.exit_code(), 2, "{error}");
    assert_eq!(count(&state, "cacheplane", "changes").await, 12);

    // Not older than the retention: nothing happens.
    run(&["--older-than-days", "3"]).await.unwrap();
    assert_eq!(count(&state, "cacheplane", "changes").await, 12);

    run(&["--older-than-days", "1", "--org", "cacheplane"])
        .await
        .unwrap();
    assert_eq!(count(&state, "cacheplane", "changes").await, 0);
    let (status, _) = send(&state, "GET", "/v1/changes?after=1", Some(&token), None).await;
    assert_eq!(status, StatusCode::GONE);

    // Days must be a positive whole number: clap refuses 0 and text.
    for bad in ["0", "x", "-1"] {
        assert!(
            b4hub::cli::Cli::try_parse_from(["b4hub", "prune", "--older-than-days", bad]).is_err()
        );
    }
}
