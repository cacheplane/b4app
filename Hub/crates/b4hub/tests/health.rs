//! Health, readiness, and shutdown behaviour against a real PostgreSQL. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use b4hub::cli::CliError;
use b4hub::serve::{self, AppState};
use b4hub_db::Db;
use serde_json::{json, Value};
use sqlx::PgPool;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tower::ServiceExt;
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

async fn migrated_state(pool: &PgPool) -> AppState {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    AppState::new(Db::connect(&app_url(pool)).await.unwrap())
}

#[sqlx::test(migrations = false)]
async fn serve_refuses_a_privileged_database_url(pool: PgPool) {
    // The test pool connects as the cluster superuser, as an admin URL in DATABASE_URL would.
    b4hub_db::migrate::run(&admin_url(&pool), &app_url(&pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(&pool)).await.unwrap();
    match b4hub::cli::refuse_privileged_connection(&admin).await {
        Err(CliError::Config(e)) => {
            assert_eq!(e.name, "DATABASE_URL");
            assert!(!e.to_string().contains("pw-test"));
        }
        other => panic!("expected a configuration error, got {other:?}"),
    }
    let err = b4hub::cli::refuse_privileged_connection(&admin)
        .await
        .unwrap_err();
    assert_eq!(err.exit_code(), 2);

    let app = Db::connect(&app_url(&pool)).await.unwrap();
    b4hub::cli::refuse_privileged_connection(&app)
        .await
        .expect("b4hub_app is not privileged");
}

async fn get(state: AppState, path: &str) -> (StatusCode, Value) {
    let response = serve::router(state)
        .oneshot(Request::get(path).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

/// A bare HTTP/1.1 GET over TCP, so the shutdown test talks to the real listener.
async fn get_over_tcp(addr: SocketAddr, path: &str) -> std::io::Result<(u16, Value)> {
    let mut stream = TcpStream::connect(addr).await?;
    let request = format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).await?;
    let mut raw = String::new();
    stream.read_to_string(&mut raw).await?;
    let status = raw
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .expect("status line");
    let body = raw.split("\r\n\r\n").nth(1).unwrap_or_default();
    Ok((status, serde_json::from_str(body).unwrap_or(Value::Null)))
}

#[sqlx::test(migrations = false)]
async fn readyz_reports_current_after_migrate(pool: PgPool) {
    let state = migrated_state(&pool).await;

    let (status, body) = get(state.clone(), "/healthz").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"ok": true}));

    let (status, body) = get(state.clone(), "/readyz").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({"ok": true, "migrations": "current", "minClientProtocol": 1})
    );
    state.db.pool.close().await;
}

#[sqlx::test(migrations = false)]
async fn readyz_is_503_before_migrate(pool: PgPool) {
    let state = AppState::new(Db { pool });

    let (status, body) = get(state.clone(), "/healthz").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "liveness does not depend on migrations"
    );
    assert_eq!(body, json!({"ok": true}));

    let (status, body) = get(state, "/readyz").await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"]["kind"], "execution_error");
    assert_eq!(body["error"]["details"]["code"], "not_ready");
    assert!(body["error"]["message"].is_string());
}

#[sqlx::test(migrations = false)]
async fn unknown_paths_answer_the_error_envelope(pool: PgPool) {
    let (status, body) = get(AppState::new(Db { pool }), "/nope").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["kind"], "request_error");
    assert_eq!(body["error"]["details"]["code"], "not_found");
}

#[sqlx::test(migrations = false)]
async fn shutdown_fails_readiness_then_exits_within_the_deadline(pool: PgPool) {
    let state = migrated_state(&pool).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (signal, signalled) = oneshot::channel::<()>();
    let server = tokio::spawn(serve::run(
        listener,
        state.clone(),
        Duration::from_millis(2000),
        async move {
            let _ = signalled.await;
        },
    ));

    let (status, body) = get_over_tcp(addr, "/readyz").await.unwrap();
    assert_eq!(status, 200);
    assert_eq!(body["migrations"], "current");

    let sent = Instant::now();
    signal.send(()).unwrap();

    // The listener stays open for a short readiness grace, answering 503 shutting_down.
    let mut saw_shutting_down = false;
    while sent.elapsed() < Duration::from_millis(1500) {
        match get_over_tcp(addr, "/readyz").await {
            Ok((503, body)) => {
                assert_eq!(body["error"]["details"]["code"], "shutting_down");
                saw_shutting_down = true;
                break;
            }
            Ok((200, _)) => tokio::time::sleep(Duration::from_millis(10)).await,
            Ok((other, _)) => panic!("unexpected status {other}"),
            Err(_) => break, // listener already closed
        }
    }
    assert!(saw_shutting_down, "/readyz never reported shutting_down");

    let finished = tokio::time::timeout(Duration::from_millis(2000), server)
        .await
        .expect("server exits within the shutdown deadline")
        .unwrap();
    finished.unwrap();
    assert!(sent.elapsed() < Duration::from_millis(2000));
    assert!(
        TcpStream::connect(addr).await.is_err(),
        "the listener is closed after shutdown"
    );
    state.db.pool.close().await;
}
