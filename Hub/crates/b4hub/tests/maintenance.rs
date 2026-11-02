//! Maintenance mode: the operator switch and what `serve` does while it is on. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

use std::time::{Duration, Instant};

use axum::http::{header, StatusCode};
use b4hub::cli::{self, Cli, Settings};
use b4hub::maintenance::{self, MaintenanceState};
use b4hub::serve::{self, AppState};
use b4hub_db::settings::{self, Maintenance};
use b4hub_db::{devices, orgs, Db};
use clap::Parser;
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};
use sqlx::PgPool;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
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

async fn migrated(pool: &PgPool) -> Db {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    Db::connect(&admin_url(pool)).await.unwrap()
}

async fn run(settings: &Settings, args: &[&str]) -> Result<(), cli::CliError> {
    let cli = Cli::try_parse_from(
        ["b4hub", "maintenance"]
            .into_iter()
            .chain(args.iter().copied()),
    )
    .unwrap();
    cli::run(cli, settings).await
}

#[sqlx::test(migrations = false)]
async fn the_maintenance_command_switches_the_database_flag(pool: PgPool) {
    let admin = migrated(&pool).await;
    let settings = Settings::from_pairs([("DATABASE_ADMIN_URL", admin_url(&pool))]);

    run(&settings, &["status"]).await.unwrap();
    assert_eq!(settings::maintenance(&admin).await.unwrap(), None);

    run(&settings, &["on", "--message", "swapping the disk"])
        .await
        .unwrap();
    let on = settings::maintenance(&admin).await.unwrap().expect("on");
    assert_eq!(on.message.as_deref(), Some("swapping the disk"));
    run(&settings, &["status"]).await.unwrap();

    run(&settings, &["on"]).await.unwrap();
    assert_eq!(
        settings::maintenance(&admin)
            .await
            .unwrap()
            .unwrap()
            .message,
        None
    );

    run(&settings, &["off"]).await.unwrap();
    assert_eq!(settings::maintenance(&admin).await.unwrap(), None);

    // Like seed and enroll: no admin URL is a configuration error, exit 2.
    let error = run(&Settings::from_pairs::<&str, &str>([]), &["on"])
        .await
        .unwrap_err();
    assert_eq!(error.exit_code(), 2);
    assert!(Cli::try_parse_from(["b4hub", "maintenance"]).is_err());
    assert!(Cli::try_parse_from(["b4hub", "maintenance", "on", "--message", ""]).is_err());
}

type HttpClient = Client<HttpConnector, Full<Bytes>>;

/// One request over the loopback listener: status, headers, and the JSON body (or `Null`).
async fn http(
    client: &HttpClient,
    method: &str,
    url: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, hyper::HeaderMap, Value) {
    let mut request = hyper::Request::builder().method(method).uri(url);
    if let Some(token) = token {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    if body.is_some() {
        request = request.header(header::CONTENT_TYPE, "application/json");
    }
    let request = request
        .body(Full::new(Bytes::from(
            body.map(|b| b.to_string()).unwrap_or_default(),
        )))
        .unwrap();
    let response = client.request(request).await.unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        headers,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn small_push(seq: i64) -> Value {
    json!({"changes": [{
        "deviceSeq": seq, "wall": 1_761_900_000_000_i64 + seq, "table": "connections",
        "rowId": format!("conn-{seq}"), "op": "insert", "column": null,
        "value": {"id": format!("conn-{seq}"), "kind": "codex", "label": "x"},
    }]})
}

/// Polls `probe` until it returns true or two seconds pass.
async fn within_two_seconds(mut probe: impl AsyncFnMut() -> bool) -> bool {
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(2) {
        if probe().await {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    false
}

#[sqlx::test(migrations = false)]
async fn maintenance_pauses_writes_and_keeps_reads_and_readiness(pool: PgPool) {
    let admin = migrated(&pool).await;
    let state = AppState::new(Db::connect(&app_url(&pool)).await.unwrap());
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
    let token = devices::redeem(&state.db, &code, "test device", "macos")
        .await
        .unwrap()
        .token;

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let (signal, signalled) = oneshot::channel::<()>();
    let server = tokio::spawn(serve::run(
        listener,
        state.clone(),
        Duration::from_secs(2),
        async move {
            let _ = signalled.await;
        },
    ));
    // The poll interval `serve` would read from B4HUB_MAINTENANCE_POLL_MS, shortened.
    let poll = tokio::spawn(maintenance::poll_loop(
        state.db.clone(),
        state.maintenance.clone(),
        Duration::from_millis(50),
        state.shutdown.clone(),
    ));
    let client: HttpClient = Client::builder(TokioExecutor::new()).build_http();
    let changes = format!("{base}/v1/changes");
    let cli_settings = Settings::from_pairs([("DATABASE_ADMIN_URL", admin_url(&pool))]);

    let (status, _, body) =
        http(&client, "POST", &changes, Some(&token), Some(small_push(1))).await;
    assert_eq!(status, StatusCode::OK, "{body}");

    run(&cli_settings, &["on", "--message", "swapping the disk"])
        .await
        .unwrap();
    // Re-pushing the accepted change is a no-op until the poll flips the switch.
    let refused = within_two_seconds(async || {
        let (status, _, _) =
            http(&client, "POST", &changes, Some(&token), Some(small_push(1))).await;
        status == StatusCode::SERVICE_UNAVAILABLE
    })
    .await;
    assert!(refused, "the push was never refused");

    let (status, headers, body) =
        http(&client, "POST", &changes, Some(&token), Some(small_push(2))).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(headers[header::RETRY_AFTER], "30");
    assert_eq!(
        body,
        json!({"error": {
            "kind": "execution_error",
            "message": "the hub is in maintenance: swapping the disk",
            "details": {"code": "maintenance"},
        }})
    );
    let (status, headers, body) = http(
        &client,
        "POST",
        &format!("{base}/v1/enroll"),
        None,
        Some(json!({"code": "BCDFGHJK", "deviceName": "x", "platform": "ios"})),
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(headers[header::RETRY_AFTER], "30");
    let (status, headers, body) = http(
        &client,
        "DELETE",
        &format!("{base}/v1/devices/self"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(headers[header::RETRY_AFTER], "30");
    assert_eq!(
        body,
        json!({"error": {
            "kind": "execution_error",
            "message": "the hub is in maintenance: swapping the disk",
            "details": {"code": "maintenance"},
        }})
    );

    // The Mac's pairing-code mint is a write too.
    let (status, headers, body) = http(
        &client,
        "POST",
        &format!("{base}/v1/pairing-codes"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(headers[header::RETRY_AFTER], "30");
    assert_eq!(
        body,
        json!({"error": {
            "kind": "execution_error",
            "message": "the hub is in maintenance: swapping the disk",
            "details": {"code": "maintenance"},
        }})
    );

    // A bad token is still a 401, since authentication runs before the guard.
    let (status, _, _) = http(
        &client,
        "POST",
        &changes,
        Some("not-a-token"),
        Some(small_push(2)),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Reads continue, the device is still valid, and the hub still reports ready.
    let (status, _, body) = http(
        &client,
        "GET",
        &format!("{changes}?after=0"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["changes"].as_array().unwrap().len(), 1);
    // A long-poll that has to wait is served too: it waits out its (short) window and answers.
    let started = Instant::now();
    let (status, _, body) = http(
        &client,
        "GET",
        &format!("{changes}?after=1&wait=1"),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["changes"].as_array().unwrap().len(), 0);
    assert!(
        started.elapsed() >= Duration::from_millis(900),
        "{:?}",
        started.elapsed()
    );
    let (status, _, _) = http(&client, "GET", &format!("{base}/v1/me"), Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _, body) = http(&client, "GET", &format!("{base}/readyz"), None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({"ok": true, "migrations": "current", "minClientProtocol": 1, "maintenance": "read_only"})
    );

    run(&cli_settings, &["off"]).await.unwrap();
    let restored = within_two_seconds(async || {
        let (status, _, _) =
            http(&client, "POST", &changes, Some(&token), Some(small_push(2))).await;
        status == StatusCode::OK
    })
    .await;
    assert!(restored, "writes never resumed");
    let (_, _, body) = http(&client, "GET", &format!("{base}/readyz"), None, None).await;
    assert!(body.get("maintenance").is_none(), "{body}");

    signal.send(()).unwrap();
    server.await.unwrap().unwrap();
    tokio::time::timeout(Duration::from_secs(1), poll)
        .await
        .expect("the poll loop stops on shutdown")
        .unwrap();
    state.db.pool.close().await;
}

#[test]
fn the_default_message_names_paused_writes() {
    let state = MaintenanceState::default();
    assert!(state.current().is_none());
    state.set(Some(Maintenance::read_only(None)));
    let error = maintenance::refused(&state.current().unwrap()).0;
    assert_eq!(
        error.message,
        "the hub is in maintenance: writes are paused"
    );
    assert_eq!(error.code, "maintenance");
}
