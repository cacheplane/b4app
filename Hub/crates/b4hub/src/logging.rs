//! Request-scoped logging: every request gets a request id and runs inside a `request` span that
//! names the id, the method, the matched route pattern (never the raw path or query), and, once
//! [`crate::auth::AuthedDevice`] has run, the device id. One completion event per request carries
//! the status and the elapsed time. Headers and bodies are never logged; the id is the only header
//! value the hub reads into a log.

use std::time::Instant;

use axum::extract::{MatchedPath, Request, State};
use axum::http::{HeaderName, HeaderValue};
use axum::middleware::Next;
use axum::response::Response;
use tracing::Instrument;

/// The header a request id travels in, both ways.
pub const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

/// What the span's `path` says for a request no route matched. The raw path is never logged.
pub const UNMATCHED_ROUTE: &str = "(unmatched)";

/// The longest inbound request id kept.
const MAX_REQUEST_ID_LEN: usize = 64;

/// The request's id, in the request extensions for anything that wants to echo it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestId(pub String);

/// The middleware on every route: picks the request id, opens the `request` span, runs the rest
/// of the stack inside it, sets `X-Request-Id` on the response, and logs the completion event.
/// `trust_proxy` is `Settings::trust_proxy()`.
pub async fn trace_request(
    State(trust_proxy): State<bool>,
    mut request: Request,
    next: Next,
) -> Response {
    let id = accept_inbound(request.headers().get(&REQUEST_ID_HEADER), trust_proxy)
        .unwrap_or_else(|| b4hub_core::ids::new_uuid().to_string());
    let path = request
        .extensions()
        .get::<MatchedPath>()
        .map_or(UNMATCHED_ROUTE, MatchedPath::as_str)
        .to_string();
    let span = tracing::info_span!(
        "request",
        request_id = %id,
        method = %request.method(),
        path = %path,
        device_id = tracing::field::Empty,
    );
    request.extensions_mut().insert(RequestId(id.clone()));

    let started = Instant::now();
    async move {
        let mut response = next.run(request).await;
        let status = response.status();
        let elapsed_ms = started.elapsed().as_millis() as u64;
        if status.is_server_error() {
            tracing::error!(status = status.as_u16(), elapsed_ms, "request complete");
        } else {
            tracing::info!(status = status.as_u16(), elapsed_ms, "request complete");
        }
        if let Ok(value) = HeaderValue::from_str(&id) {
            response.headers_mut().insert(REQUEST_ID_HEADER, value);
        }
        response
    }
    .instrument(span)
    .await
}

/// The inbound id when there is one, it is well-formed (1 to 64 printable ASCII characters with
/// no whitespace), and a trusted proxy put it there; otherwise `None`, and a fresh id is minted.
pub fn accept_inbound(value: Option<&HeaderValue>, trust_proxy: bool) -> Option<String> {
    if !trust_proxy {
        return None;
    }
    let value = value?.to_str().ok()?;
    let well_formed = !value.is_empty()
        && value.len() <= MAX_REQUEST_ID_LEN
        && value.bytes().all(|b| b.is_ascii_graphic());
    well_formed.then(|| value.to_string())
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    use axum::body::Body;
    use axum::http::{header, HeaderValue, Request, StatusCode};
    use axum::routing::get;
    use axum::{middleware, Router};
    use serde_json::Value;
    use tower::ServiceExt;
    use tracing_subscriber::fmt::MakeWriter;

    use super::*;

    /// A `MakeWriter` over a shared buffer, so a test can read back what a JSON subscriber wrote.
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

    impl Buffer {
        fn lines(&self) -> Vec<Value> {
            let raw = String::from_utf8(self.0.lock().unwrap().clone()).unwrap();
            raw.lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    fn router(trust_proxy: bool) -> Router {
        Router::new()
            .route("/items/{id}", get(|| async { "ok" }))
            .layer(middleware::from_fn_with_state(trust_proxy, trace_request))
    }

    async fn call(
        trust_proxy: bool,
        path: &str,
        inbound: Option<&str>,
    ) -> axum::response::Response {
        let mut request = Request::get(path);
        if let Some(inbound) = inbound {
            request = request.header(REQUEST_ID_HEADER, inbound);
        }
        router(trust_proxy)
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap()
    }

    fn header_value(response: &axum::response::Response) -> String {
        response
            .headers()
            .get(REQUEST_ID_HEADER)
            .expect("X-Request-Id is set on the response")
            .to_str()
            .unwrap()
            .to_string()
    }

    #[tokio::test]
    async fn a_generated_id_is_a_uuid_set_on_the_response() {
        let response = call(false, "/items/1", None).await;
        assert_eq!(response.status(), StatusCode::OK);
        let id = header_value(&response);
        let parsed = uuid::Uuid::parse_str(&id).expect("a UUID");
        assert_eq!(parsed.get_version_num(), 7);
    }

    #[tokio::test]
    async fn an_inbound_id_is_honoured_only_behind_a_trusted_proxy() {
        let response = call(false, "/items/1", Some("edge-abc123")).await;
        assert_ne!(header_value(&response), "edge-abc123");
        let response = call(true, "/items/1", Some("edge-abc123")).await;
        assert_eq!(header_value(&response), "edge-abc123");
    }

    #[tokio::test]
    async fn a_malformed_inbound_id_is_replaced_even_when_trusted() {
        for bad in ["", "has space", "tab\there", &"x".repeat(65)] {
            let response = call(true, "/items/1", Some(bad)).await;
            let id = header_value(&response);
            assert_ne!(id, bad);
            assert!(uuid::Uuid::parse_str(&id).is_ok(), "{bad:?}");
        }
        let response = call(true, "/items/1", Some(&"x".repeat(64))).await;
        assert_eq!(header_value(&response), "x".repeat(64));
    }

    #[test]
    fn inbound_ids_are_checked_strictly() {
        let value = |s: &str| HeaderValue::from_str(s).ok();
        assert_eq!(
            accept_inbound(value("abc-123").as_ref(), true).as_deref(),
            Some("abc-123")
        );
        assert_eq!(accept_inbound(value("abc-123").as_ref(), false), None);
        assert_eq!(accept_inbound(None, true), None);
        assert_eq!(accept_inbound(value("").as_ref(), true), None);
        assert_eq!(accept_inbound(value("a b").as_ref(), true), None);
        assert_eq!(accept_inbound(value("a\u{7f}b").as_ref(), true), None);
        assert_eq!(accept_inbound(value(&"y".repeat(65)).as_ref(), true), None);
        assert_eq!(
            HeaderValue::from_bytes(b"caf\xe9")
                .ok()
                .and_then(|v| accept_inbound(Some(&v), true)),
            None,
            "non-ASCII bytes are refused"
        );
    }

    #[tokio::test]
    async fn the_span_names_the_route_pattern_and_not_the_raw_path() {
        let buffer = Buffer::default();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .flatten_event(true)
            .with_current_span(true)
            .with_span_list(false)
            .with_writer(buffer.clone())
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);

        let response = call(true, "/items/42?token=secret-query&x=1", Some("req-1")).await;
        assert_eq!(response.status(), StatusCode::OK);
        drop(_guard);

        let raw = String::from_utf8(buffer.0.lock().unwrap().clone()).unwrap();
        assert!(!raw.contains("secret-query"), "{raw}");
        assert!(!raw.contains("/items/42"), "{raw}");
        let lines = buffer.lines();
        let done = lines
            .iter()
            .find(|line| line["message"] == "request complete")
            .unwrap_or_else(|| panic!("no completion event in {raw}"));
        assert_eq!(done["level"], "INFO");
        assert_eq!(done["status"], 200);
        assert!(done["elapsed_ms"].is_u64(), "{done}");
        assert_eq!(done["span"]["name"], "request");
        assert_eq!(done["span"]["request_id"], "req-1");
        assert_eq!(done["span"]["method"], "GET");
        assert_eq!(done["span"]["path"], "/items/{id}");
        assert!(done["span"].get("device_id").is_none(), "{done}");
    }

    #[tokio::test]
    async fn an_unmatched_route_and_a_5xx_are_logged_at_error_without_the_raw_path() {
        let buffer = Buffer::default();
        let subscriber = tracing_subscriber::fmt()
            .json()
            .flatten_event(true)
            .with_current_span(true)
            .with_span_list(false)
            .with_writer(buffer.clone())
            .finish();
        let _guard = tracing::subscriber::set_default(subscriber);

        let router = Router::new()
            .route("/boom", get(|| async { StatusCode::INTERNAL_SERVER_ERROR }))
            .layer(middleware::from_fn_with_state(false, trace_request));
        let response = router
            .clone()
            .oneshot(Request::get("/boom").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let response = router
            .oneshot(
                Request::get("/no/such/thing?q=1")
                    .header(header::AUTHORIZATION, "Bearer tok")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        drop(_guard);

        let raw = String::from_utf8(buffer.0.lock().unwrap().clone()).unwrap();
        assert!(!raw.contains("/no/such/thing"), "{raw}");
        assert!(!raw.contains("tok"), "{raw}");
        let lines = buffer.lines();
        let mut done = lines
            .iter()
            .filter(|line| line["message"] == "request complete");
        let boom = done.next().unwrap();
        assert_eq!(boom["level"], "ERROR");
        assert_eq!(boom["status"], 500);
        let missing = done.next().unwrap();
        assert_eq!(missing["level"], "INFO");
        assert_eq!(missing["status"], 404);
        assert_eq!(missing["span"]["path"], UNMATCHED_ROUTE);
    }
}
