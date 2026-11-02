//! Device enrollment, bearer authentication, and the `enroll` command against a real PostgreSQL.
//! Run with `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use std::time::Duration;

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use axum::routing::post;
use axum::Router;
use b4hub::auth::AuthedDevice;
use b4hub::cli::{self, Cli, CliError};
use b4hub::error::ApiJson;
use b4hub::routes::enroll::EnrollRequest;
use b4hub::serve::{self, AppState};
use b4hub_core::tokens::hash_token;
use b4hub_db::{devices, orgs, Db};
use clap::Parser;
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;
use tower::ServiceExt;
use url::Url;

const TEN_MINUTES: Duration = Duration::from_secs(600);

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

/// The owner handle (for seeding and inspection) and the app state (connected as `b4hub_app`).
async fn migrated(pool: &PgPool) -> (Db, AppState) {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(pool)).await.unwrap();
    let app = Db::connect(&app_url(pool)).await.unwrap();
    (admin, common::state(app))
}

async fn seed_blove(admin: &Db) -> orgs::SeedOutcome {
    orgs::seed(
        admin,
        "cacheplane",
        "Cacheplane",
        "blove",
        "Brian Love",
        "b@example.test",
    )
    .await
    .unwrap()
}

/// Sends one request through `router` and returns the status and the JSON body (`Null` when the
/// body is empty). A non-empty body that is not JSON fails the test: every answer must be JSON.
async fn send_to(
    router: Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&str>,
) -> (StatusCode, Value) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(token) = token {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let request = match body {
        Some(body) => request
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string())),
        None => request.body(Body::empty()),
    }
    .unwrap();
    let response = router.oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let value = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or_else(|_| {
            panic!(
                "{method} {path} answered {status} with a body that is not JSON: {:?}",
                String::from_utf8_lossy(&bytes)
            )
        })
    };
    (status, value)
}

async fn send(
    state: &AppState,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Option<&str>,
) -> (StatusCode, Value) {
    send_to(serve::router(state.clone()), method, path, token, body).await
}

fn enroll_body(code: &str) -> String {
    json!({"code": code, "deviceName": "Brian's Mac", "platform": "macos"}).to_string()
}

fn error_code(body: &Value) -> &str {
    body["error"]["details"]["code"]
        .as_str()
        .unwrap_or_default()
}

#[sqlx::test(migrations = false)]
async fn enroll_then_me_then_revoke(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();

    let (status, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code)),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let token = body["token"].as_str().expect("a token").to_string();
    let device_id = body["deviceId"].as_str().expect("a device id").to_string();
    assert_eq!(
        body["org"],
        json!({"slug": "cacheplane", "name": "Cacheplane"})
    );
    assert_eq!(
        body["user"],
        json!({"username": "blove", "displayName": "Brian Love"})
    );

    let (status, me) = send(&state, "GET", "/v1/me", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK, "{me}");
    assert_eq!(me["deviceId"], device_id);
    assert_eq!(me["deviceName"], "Brian's Mac");
    assert_eq!(me["platform"], "macos");
    assert_eq!(
        me["org"],
        json!({"slug": "cacheplane", "name": "Cacheplane"})
    );
    assert_eq!(
        me["user"],
        json!({"username": "blove", "displayName": "Brian Love"})
    );
    assert!(
        me["createdAt"].as_str().is_some_and(|s| s.ends_with('Z')),
        "{me}"
    );

    // The code is single-use.
    let (status, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code)),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(error_code(&body), "invalid_code");

    // An unknown field is refused, and a fresh code is not consumed by a request that is refused.
    let fresh = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();
    let with_extra = json!({"code": fresh, "deviceName": "x", "platform": "ios", "extra": 1});
    let (status, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&with_extra.to_string()),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(error_code(&body), "invalid_request");
    assert_eq!(body["error"]["kind"], "request_error");
    let (status, _) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&json!({"code": fresh, "deviceName": "Phone", "platform": "ios"}).to_string()),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // A bad token with a body that is not JSON is 401 on a route that reads a JSON body: the
    // credential is checked before the body is.
    let probe = Router::new()
        .route(
            "/probe",
            post(|_device: AuthedDevice, ApiJson(_): ApiJson<EnrollRequest>| async { "ok" }),
        )
        .with_state(state.clone());
    let (status, body) = send_to(
        probe.clone(),
        "POST",
        "/probe",
        Some("not-a-real-token"),
        Some("not json"),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(error_code(&body), "unauthorized");
    // The same body with a good token is a 400, so the 401 above was the credential check.
    let (status, body) = send_to(probe, "POST", "/probe", Some(&token), Some("not json")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(error_code(&body), "invalid_request");

    // A bad token on /v1/me is 401 too.
    let (status, bad) = send(&state, "GET", "/v1/me", Some("bad"), Some("not json")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(error_code(&bad), "unauthorized");

    // Revoking: 204, then the same token is refused with the same body as any other bad token.
    let (status, body) = send(&state, "DELETE", "/v1/devices/self", Some(&token), None).await;
    assert_eq!((status, body), (StatusCode::NO_CONTENT, Value::Null));
    let (status, revoked) = send(&state, "GET", "/v1/me", Some(&token), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(revoked, bad);

    // Revoking deletes the token rows and marks the device; the device row itself stays.
    let device: Uuid = device_id.parse().unwrap();
    let tokens: i64 = sqlx::query_scalar("SELECT count(*) FROM device_tokens WHERE device_id = $1")
        .bind(device)
        .fetch_one(&admin.pool)
        .await
        .unwrap();
    assert_eq!(tokens, 0);
    let mut tx = admin.tenant_tx(seeded.org_id).await.unwrap();
    let revoked_at: Option<bool> =
        sqlx::query_scalar("SELECT revoked_at IS NOT NULL FROM devices WHERE id = $1")
            .bind(device)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    tx.rollback().await.unwrap();
    assert_eq!(revoked_at, Some(true));
}

#[sqlx::test(migrations = false)]
async fn only_the_hash_of_the_token_is_stored(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();
    let (_, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code)),
    )
    .await;
    let token = body["token"].as_str().unwrap().to_string();

    let hash = hash_token(&token);
    let matching: i64 =
        sqlx::query_scalar("SELECT count(*) FROM device_tokens WHERE token_hash = $1")
            .bind(&hash[..])
            .fetch_one(&admin.pool)
            .await
            .unwrap();
    assert_eq!(matching, 1);

    // The token appears in no row of any table that holds enrollment state, in any encoding the
    // database would render it in (the hash column is bytea, shown as hex).
    for table in ["device_tokens", "enrollment_codes"] {
        let rows: Vec<String> =
            sqlx::query_scalar(&format!("SELECT row_to_json(t)::text FROM {table} t"))
                .fetch_all(&admin.pool)
                .await
                .unwrap();
        assert!(!rows.is_empty(), "{table} has rows");
        assert!(rows.iter().all(|row| !row.contains(&token)), "{table}");
    }
    let mut tx = admin.tenant_tx(seeded.org_id).await.unwrap();
    let rows: Vec<String> = sqlx::query_scalar("SELECT row_to_json(t)::text FROM devices t")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    assert!(!rows.is_empty() && rows.iter().all(|row| !row.contains(&token)));
    tx.rollback().await.unwrap();
    // The code is stored hashed too.
    let codes: Vec<String> =
        sqlx::query_scalar("SELECT row_to_json(t)::text FROM enrollment_codes t")
            .fetch_all(&admin.pool)
            .await
            .unwrap();
    assert!(codes.iter().all(|row| !row.contains(&code)));
}

#[sqlx::test(migrations = false)]
async fn expired_code_is_rejected(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code =
        devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, Duration::ZERO)
            .await
            .unwrap();
    let (status, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code)),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(error_code(&body), "invalid_code");
}

#[sqlx::test(migrations = false)]
async fn codes_match_in_any_case_and_unknown_codes_are_invalid(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();
    assert_eq!(code.len(), 8);

    let (status, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body("BBBBBBBB")),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(error_code(&body), "invalid_code");

    let (status, _) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code.to_lowercase())),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[sqlx::test(migrations = false)]
async fn a_code_can_be_redeemed_only_once_even_concurrently(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();

    let attempts = (0..8).map(|_| {
        let db = state.db.clone();
        let code = code.clone();
        tokio::spawn(async move { devices::redeem(&db, &code, "Mac", "macos").await })
    });
    let mut won = 0;
    for attempt in attempts {
        match attempt.await.unwrap() {
            Ok(_) => won += 1,
            Err(b4hub_db::Error::InvalidCode) => {}
            Err(other) => panic!("unexpected {other}"),
        }
    }
    assert_eq!(won, 1);
    let device_count: i64 = {
        let mut tx = admin.tenant_tx(seeded.org_id).await.unwrap();
        let n = sqlx::query_scalar("SELECT count(*) FROM devices")
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        tx.rollback().await.unwrap();
        n
    };
    assert_eq!(device_count, 1);
}

#[sqlx::test(migrations = false)]
async fn invalid_requests_and_credentials_are_all_the_json_envelope(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();

    // Malformed JSON, a missing field, and an unsupported platform are 400 invalid_request, and
    // none of them uses up the code.
    for body in [
        "{".to_string(),
        json!({"code": code}).to_string(),
        json!({"code": code, "deviceName": "Mac", "platform": "windows"}).to_string(),
        json!({"code": code, "deviceName": "  ", "platform": "macos"}).to_string(),
    ] {
        let (status, response) = send(&state, "POST", "/v1/enroll", None, Some(&body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
        assert_eq!(error_code(&response), "invalid_request", "{body}");
    }
    // A body that is not declared as JSON is refused as an invalid request, not a plain-text 415.
    let response = serve::router(state.clone())
        .oneshot(
            Request::post("/v1/enroll")
                .body(Body::from(enroll_body(&code)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
    let envelope: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(error_code(&envelope), "invalid_request");

    // A wrong method on a known path is still the envelope.
    let (status, response) = send(&state, "GET", "/v1/enroll", None, None).await;
    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED);
    assert_eq!(error_code(&response), "method_not_allowed");

    // The code still works after all of that.
    let (status, _) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // A missing header, another scheme, and an empty token are the same 401 as a wrong token.
    let (status, reference) = send(&state, "GET", "/v1/me", Some("wrong"), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    for header_value in [
        None,
        Some("Basic dXNlcjpwYXNz"),
        Some("Bearer "),
        Some("Bearer"),
    ] {
        let mut request = Request::get("/v1/me");
        if let Some(value) = header_value {
            request = request.header(header::AUTHORIZATION, value);
        }
        let response = serve::router(state.clone())
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::UNAUTHORIZED,
            "{header_value:?}"
        );
        let bytes = to_bytes(response.into_body(), 4096).await.unwrap();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body, reference, "{header_value:?}");
    }
}

#[sqlx::test(migrations = false)]
async fn each_device_belongs_to_the_org_and_user_of_its_code(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let a = seed_blove(&admin).await;
    let b = orgs::seed(&admin, "other", "Other Org", "eve", "Eve", "e@example.test")
        .await
        .unwrap();

    let mut tokens = Vec::new();
    for seeded in [&a, &b] {
        let code =
            devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
                .await
                .unwrap();
        let (status, body) = send(
            &state,
            "POST",
            "/v1/enroll",
            None,
            Some(&enroll_body(&code)),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        tokens.push(body["token"].as_str().unwrap().to_string());
    }

    let (_, me_a) = send(&state, "GET", "/v1/me", Some(&tokens[0]), None).await;
    let (_, me_b) = send(&state, "GET", "/v1/me", Some(&tokens[1]), None).await;
    assert_eq!(me_a["org"]["slug"], "cacheplane");
    assert_eq!(me_a["user"]["username"], "blove");
    assert_eq!(me_b["org"]["slug"], "other");
    assert_eq!(me_b["user"]["username"], "eve");

    // Revoking one device leaves the other working.
    send(&state, "DELETE", "/v1/devices/self", Some(&tokens[0]), None).await;
    let (status, _) = send(&state, "GET", "/v1/me", Some(&tokens[1]), None).await;
    assert_eq!(status, StatusCode::OK);
}

/// Enrolls a fresh device for `seeded` and returns its token and id.
async fn enroll_device(admin: &Db, state: &AppState, seeded: &orgs::SeedOutcome) -> (String, Uuid) {
    let code = devices::create_enrollment_code(admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();
    let (status, body) = send(state, "POST", "/v1/enroll", None, Some(&enroll_body(&code))).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    (
        body["token"].as_str().unwrap().to_string(),
        body["deviceId"].as_str().unwrap().parse().unwrap(),
    )
}

/// `authenticate` refuses a token whose own row is revoked and a token whose device is revoked,
/// each on its own: the first leaves the device live, the second leaves the token row in place.
/// (`revoke_self` deletes the token rows, so it exercises neither filter.)
#[sqlx::test(migrations = false)]
async fn a_revoked_token_or_a_revoked_device_is_refused_on_its_own(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let (_, reference) = send(&state, "GET", "/v1/me", Some("wrong"), None).await;

    // Device one: only the token row is revoked.
    let (token_one, device_one) = enroll_device(&admin, &state, &seeded).await;
    let (status, _) = send(&state, "GET", "/v1/me", Some(&token_one), None).await;
    assert_eq!(status, StatusCode::OK);
    let revoked = sqlx::query("UPDATE device_tokens SET revoked_at = now() WHERE device_id = $1")
        .bind(device_one)
        .execute(&admin.pool)
        .await
        .unwrap()
        .rows_affected();
    assert_eq!(revoked, 1);
    // Asserted on `authenticate` itself: a route that re-reads the device (`/v1/me`) could mask
    // a missing filter here.
    assert_eq!(
        devices::authenticate(&state.db, &token_one).await.unwrap(),
        None
    );
    let (status, body) = send(&state, "GET", "/v1/me", Some(&token_one), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body, reference);
    let mut tx = admin.tenant_tx(seeded.org_id).await.unwrap();
    let live: bool = sqlx::query_scalar("SELECT revoked_at IS NULL FROM devices WHERE id = $1")
        .bind(device_one)
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    tx.rollback().await.unwrap();
    assert!(live, "only the token was revoked");

    // Device two: only the device is revoked; its token row stays, unrevoked.
    let (token_two, device_two) = enroll_device(&admin, &state, &seeded).await;
    let (status, _) = send(&state, "GET", "/v1/me", Some(&token_two), None).await;
    assert_eq!(status, StatusCode::OK);
    let mut tx = admin.tenant_tx(seeded.org_id).await.unwrap();
    let revoked = sqlx::query("UPDATE devices SET revoked_at = now() WHERE id = $1")
        .bind(device_two)
        .execute(&mut *tx)
        .await
        .unwrap()
        .rows_affected();
    tx.commit().await.unwrap();
    assert_eq!(revoked, 1);
    let kept: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM device_tokens WHERE device_id = $1 AND revoked_at IS NULL",
    )
    .bind(device_two)
    .fetch_one(&admin.pool)
    .await
    .unwrap();
    assert_eq!(kept, 1, "the token row is still there and unrevoked");
    assert_eq!(
        devices::authenticate(&state.db, &token_two).await.unwrap(),
        None
    );
    let (status, body) = send(&state, "GET", "/v1/me", Some(&token_two), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body, reference);
}

#[sqlx::test(migrations = false)]
async fn last_seen_is_recorded_and_throttled_to_once_a_minute(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;
    let code = devices::create_enrollment_code(&admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap();
    let (_, body) = send(
        &state,
        "POST",
        "/v1/enroll",
        None,
        Some(&enroll_body(&code)),
    )
    .await;
    let token = body["token"].as_str().unwrap().to_string();
    let device: Uuid = body["deviceId"].as_str().unwrap().parse().unwrap();

    async fn last_seen(admin: &Db, org: Uuid, device: Uuid) -> Option<String> {
        let mut tx = admin.tenant_tx(org).await.unwrap();
        let value = sqlx::query_scalar("SELECT last_seen_at::text FROM devices WHERE id = $1")
            .bind(device)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        tx.rollback().await.unwrap();
        value
    }

    assert_eq!(last_seen(&admin, seeded.org_id, device).await, None);
    send(&state, "GET", "/v1/me", Some(&token), None).await;
    let first = last_seen(&admin, seeded.org_id, device)
        .await
        .expect("the first authenticated request records last_seen_at");

    // A second request inside the minute does not write again.
    send(&state, "GET", "/v1/me", Some(&token), None).await;
    assert_eq!(
        last_seen(&admin, seeded.org_id, device).await.as_deref(),
        Some(first.as_str())
    );
}

#[sqlx::test(migrations = false)]
async fn enroll_command_resolves_the_org_and_the_user(pool: PgPool) {
    let (admin, state) = migrated(&pool).await;
    let seeded = seed_blove(&admin).await;

    // With one org, --org is optional; the code redeems into that org as that user.
    let code = cli::issue_enrollment_code(&admin, "blove", None)
        .await
        .unwrap();
    let enrolled = devices::redeem(&state.db, &code, "Mac", "macos")
        .await
        .unwrap();
    assert_eq!(
        (enrolled.org_id, enrolled.user_id),
        (seeded.org_id, seeded.user_id)
    );
    assert_eq!(enrolled.username, "blove");

    // An unknown user is a configuration error (exit 2) naming --user.
    let error = cli::issue_enrollment_code(&admin, "nobody", None)
        .await
        .unwrap_err();
    assert!(
        matches!(&error, CliError::Config(c) if c.name == "--user"),
        "{error}"
    );
    assert_eq!(error.exit_code(), 2);

    // With several orgs --org is required, and an unknown slug is refused.
    orgs::seed(
        &admin,
        "other",
        "Other",
        "blove",
        "Other Blove",
        "o@example.test",
    )
    .await
    .unwrap();
    let error = cli::issue_enrollment_code(&admin, "blove", None)
        .await
        .unwrap_err();
    assert!(
        matches!(&error, CliError::Config(c) if c.name == "--org"),
        "{error}"
    );
    assert_eq!(error.exit_code(), 2);
    let error = cli::issue_enrollment_code(&admin, "blove", Some("nope"))
        .await
        .unwrap_err();
    assert!(
        matches!(&error, CliError::Config(c) if c.name == "--org"),
        "{error}"
    );

    // --org picks the org; the same username in another org is a different user.
    let code = cli::issue_enrollment_code(&admin, "blove", Some("other"))
        .await
        .unwrap();
    let enrolled = devices::redeem(&state.db, &code, "Mac", "macos")
        .await
        .unwrap();
    assert_eq!(enrolled.org_slug, "other");
    assert_eq!(enrolled.display_name, "Other Blove");

    // The command line parses `--user` and the optional `--org`.
    let parsed = Cli::try_parse_from(["b4hub", "enroll", "--user", "blove", "--org", "other"]);
    match parsed.unwrap().command {
        cli::Command::Enroll(args) => {
            assert_eq!(
                (args.user.as_str(), args.org.as_deref()),
                ("blove", Some("other"))
            );
        }
        other => panic!("parsed as {other:?}"),
    }
    match Cli::try_parse_from(["b4hub", "enroll", "--user", "blove"])
        .unwrap()
        .command
    {
        cli::Command::Enroll(args) => assert_eq!(args.org, None),
        other => panic!("parsed as {other:?}"),
    }
    assert!(Cli::try_parse_from(["b4hub", "enroll"]).is_err());
}
