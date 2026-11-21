//! Authenticated in-process HTTP controls; no external runtime or new endpoint.
mod common;
use axum::{
    body::{to_bytes, Body},
    http::{header, Request, StatusCode},
};
use b4hub::serve;
use b4hub_db::{devices, orgs, settings};
use serde_json::Value;
use sqlx::PgPool;
use tower::ServiceExt;

#[sqlx::test(migrations = false)]
async fn every_sync_http_entry_refuses_old_clients_before_body_or_data(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let state = common::state(app.clone());
    let user = orgs::seed(
        &admin,
        "floor-http",
        "Floor",
        "floor-http",
        "Floor",
        "floor@example.test",
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        &admin,
        user.org_id,
        user.user_id,
        std::time::Duration::from_secs(60),
    )
    .await
    .unwrap();
    let token = devices::redeem(&app, &code, "fixture", "macos")
        .await
        .unwrap()
        .token;
    // Staged support remains compatible at floor 1; malformed protocol never defaults to 1.
    for protocol in [None, Some("1"), Some("2"), Some("bad")] {
        let mut request = Request::builder()
            .method("POST")
            .uri("/v1/changes")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json");
        if let Some(protocol) = protocol {
            request = request.header("B4-Protocol", protocol);
        }
        let response = serve::router(state.clone())
            .oneshot(request.body(Body::from("{\"changes\":[]}")).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            if protocol == Some("bad") {
                StatusCode::BAD_REQUEST
            } else {
                StatusCode::OK
            }
        );
    }
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    for (method, path) in [
        ("POST", "/v1/changes"),
        ("GET", "/v1/changes?after=0&wait=0"),
        ("GET", "/v1/snapshot"),
    ] {
        for protocol in [None, Some("1"), Some("2"), Some("bad")] {
            let mut request = Request::builder()
                .method(method)
                .uri(path)
                .header(header::AUTHORIZATION, format!("Bearer {token}"));
            if let Some(protocol) = protocol {
                request = request.header("B4-Protocol", protocol);
            }
            if method == "POST" {
                request = request.header(header::CONTENT_TYPE, "application/json");
            }
            let body = if method == "POST" {
                "{not valid JSON"
            } else {
                ""
            };
            let response = serve::router(state.clone())
                .oneshot(request.body(Body::from(body)).unwrap())
                .await
                .unwrap();
            let expected = match protocol {
                None | Some("1") => StatusCode::CONFLICT,
                _ => StatusCode::BAD_REQUEST,
            };
            // A compatible GET succeeds; a compatible malformed POST proves the floor did not
            // replace normal body validation. Old POST must refuse before this malformed body.
            let expected = if protocol == Some("2") && method == "GET" {
                StatusCode::OK
            } else {
                expected
            };
            assert_eq!(response.status(), expected, "{method} {path} {protocol:?}");
            let bytes = to_bytes(response.into_body(), 1024 * 1024).await.unwrap();
            let json: Value = serde_json::from_slice(&bytes).unwrap();
            if protocol.is_none() || protocol == Some("1") {
                assert_eq!(json["error"]["details"]["code"], "client_too_old");
                assert_eq!(json["error"]["details"]["minClientProtocol"], 2);
            }
        }
        let response = serve::router(state.clone())
            .oneshot(
                Request::builder()
                    .method(method)
                    .uri(path)
                    .header("B4-Protocol", "bad")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }
    for protocol in [None, Some("1"), Some("2")] {
        let mut request = Request::builder()
            .method("POST")
            .uri("/v1/changes")
            .header(header::AUTHORIZATION, format!("Bearer {token}"))
            .header(header::CONTENT_TYPE, "application/json");
        if let Some(protocol) = protocol {
            request = request.header("B4-Protocol", protocol);
        }
        let response = serve::router(state.clone())
            .oneshot(request.body(Body::from("{\"changes\":[]}")).unwrap())
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            if protocol == Some("2") {
                StatusCode::OK
            } else {
                StatusCode::CONFLICT
            }
        );
    }
    let ready = serve::router(state.clone())
        .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(ready.status(), StatusCode::OK);
    let body: Value =
        serde_json::from_slice(&to_bytes(ready.into_body(), 1024 * 1024).await.unwrap()).unwrap();
    assert_eq!(body["minClientProtocol"], 2);
    assert_eq!(body["supportedClientProtocol"], 2);
    sqlx::query("UPDATE public.hub_settings SET value='{}'::jsonb WHERE key='client_protocol'")
        .execute(&admin.pool)
        .await
        .unwrap();
    let ready = serve::router(state.clone())
        .oneshot(Request::get("/readyz").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(ready.status(), StatusCode::SERVICE_UNAVAILABLE);
}
