//! Request-scoped logging: every request gets a hub-minted request id and runs inside a `request`
//! span that names the id, the method, the matched route pattern (never the raw path or query),
//! the caller's own `X-Request-Id` when it sent a well-formed one, and, once
//! [`crate::auth::AuthedDevice`] has run, the device id. One completion event per request carries
//! the status and the elapsed time. Headers and bodies are never logged; the caller's id is the
//! only header value the hub reads into a log, and it never replaces the hub's own id (nothing
//! deployed in front of the hub strips the header, so a caller could otherwise choose the id it
//! is logged under).

use std::time::Instant;

use axum::extract::{MatchedPath, Request};
use axum::http::{HeaderName, HeaderValue, StatusCode};
use axum::middleware::Next;
use axum::response::Response;
use tracing::Instrument;

/// The header the hub's request id is answered in, and the one a caller's own id is read from.
pub const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

/// What the span's `path` says for a request no route matched. The raw path is never logged.
pub const UNMATCHED_ROUTE: &str = "(unmatched)";

/// The longest caller id recorded.
const MAX_CLIENT_REQUEST_ID_LEN: usize = 64;

/// The request's id, in the request extensions for anything that wants to echo it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestId(pub String);

/// The middleware on every route: mints the request id, opens the `request` span, runs the rest
/// of the stack inside it, sets `X-Request-Id` on the response, and logs the completion event.
pub async fn trace_request(mut request: Request, next: Next) -> Response {
    let id = b4hub_core::ids::new_uuid().to_string();
    let client_request_id = client_request_id(request.headers().get(&REQUEST_ID_HEADER));
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
        client_request_id = tracing::field::Empty,
        device_id = tracing::field::Empty,
    );
    if let Some(client_id) = &client_request_id {
        span.record("client_request_id", client_id.as_str());
    }
    request.extensions_mut().insert(RequestId(id.clone()));

    let started = Instant::now();
    async move {
        let mut response = next.run(request).await;
        let status = response.status();
        let elapsed_ms = started.elapsed().as_millis() as u64;
        // A 503 is the hub refusing on purpose (maintenance, shutting down, not ready), so it is
        // a warning; any other 5xx is a failure.
        if status == StatusCode::SERVICE_UNAVAILABLE {
            tracing::warn!(status = status.as_u16(), elapsed_ms, "request complete");
        } else if status.is_server_error() {
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

/// The caller's `X-Request-Id` when there is one and it is well-formed (1 to 64 printable ASCII
/// characters with no whitespace); otherwise `None`. It is recorded for correlation with the
/// caller's own logs and never becomes the hub's request id.
pub fn client_request_id(value: Option<&HeaderValue>) -> Option<String> {
    let value = value?.to_str().ok()?;
    let well_formed = !value.is_empty()
        && value.len() <= MAX_CLIENT_REQUEST_ID_LEN
        && value.bytes().all(|b| b.is_ascii_graphic());
    well_formed.then(|| value.to_string())
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::io::Write;
    use std::sync::{Arc, Mutex, OnceLock};

    use axum::body::Body;
    use axum::http::{header, Request};
    use axum::routing::get;
    use axum::{middleware, Router};
    use serde_json::Value;
    use tower::ServiceExt;
    use tracing_subscriber::fmt::MakeWriter;

    use super::*;

    /// What one test's log lines are collected into.
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

    thread_local! {
        /// The buffer the current test thread's lines go to; `None` discards them.
        static SINK: RefCell<Option<Buffer>> = const { RefCell::new(None) };
    }

    /// A `MakeWriter` that writes each line into the emitting thread's [`SINK`]. The tests use
    /// one process-wide subscriber with this writer rather than a scoped `set_default` each:
    /// `tracing-core` caches a callsite's `Interest` globally, and while exactly one scoped
    /// dispatcher is registered it computes that interest from the *registering* thread's
    /// thread-local default, so a parallel test thread that had not set one yet could cache
    /// `Interest::never` for `request complete` and make another test's event vanish (seen in
    /// about one run in 25). A global default is registered once, so the cache never changes.
    struct ThreadSink;

    impl<'a> MakeWriter<'a> for ThreadSink {
        type Writer = ThreadSink;

        fn make_writer(&'a self) -> ThreadSink {
            ThreadSink
        }
    }

    impl Write for ThreadSink {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            SINK.with(|sink| {
                if let Some(buffer) = sink.borrow_mut().as_mut() {
                    buffer.write_all(bytes)?;
                }
                Ok(bytes.len())
            })
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Clears the thread's sink when the test is done, so a later test on the same thread (the
    /// harness reuses threads) starts clean.
    struct Capture;

    impl Drop for Capture {
        fn drop(&mut self) {
            SINK.with(|sink| sink.borrow_mut().take());
        }
    }

    /// Starts collecting this thread's JSON log lines. `#[tokio::test]` drives the request on the
    /// test thread, so every line the request produces lands in the returned buffer and nowhere
    /// else.
    fn json_buffer() -> (Buffer, Capture) {
        static INSTALLED: OnceLock<()> = OnceLock::new();
        INSTALLED.get_or_init(|| {
            let subscriber = tracing_subscriber::fmt()
                .json()
                .flatten_event(true)
                .with_current_span(true)
                .with_span_list(false)
                .with_writer(ThreadSink)
                .finish();
            tracing::subscriber::set_global_default(subscriber)
                .expect("no other test in this binary installs a global subscriber");
        });
        let buffer = Buffer::default();
        SINK.with(|sink| *sink.borrow_mut() = Some(buffer.clone()));
        (buffer, Capture)
    }

    impl Buffer {
        fn lines(&self) -> Vec<Value> {
            let raw = String::from_utf8(self.0.lock().unwrap().clone()).unwrap();
            raw.lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect()
        }
    }

    fn router() -> Router {
        Router::new()
            .route("/items/{id}", get(|| async { "ok" }))
            .layer(middleware::from_fn(trace_request))
    }

    async fn call(path: &str, inbound: Option<&str>) -> axum::response::Response {
        let mut request = Request::get(path);
        if let Some(inbound) = inbound {
            request = request.header(REQUEST_ID_HEADER, inbound);
        }
        router()
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
    async fn the_id_is_a_fresh_uuid_set_on_the_response() {
        let response = call("/items/1", None).await;
        assert_eq!(response.status(), StatusCode::OK);
        let id = header_value(&response);
        let parsed = uuid::Uuid::parse_str(&id).expect("a UUID");
        assert_eq!(parsed.get_version_num(), 7);
        let again = header_value(&call("/items/1", None).await);
        assert_ne!(id, again);
    }

    #[tokio::test]
    async fn a_callers_id_never_replaces_the_hubs() {
        let response = call("/items/1", Some("edge-abc123")).await;
        let id = header_value(&response);
        assert_ne!(id, "edge-abc123");
        assert!(uuid::Uuid::parse_str(&id).is_ok());
    }

    #[tokio::test]
    async fn a_well_formed_callers_id_is_recorded_and_a_malformed_one_dropped() {
        let (buffer, guard) = json_buffer();
        call("/items/1", Some("edge-abc123")).await;
        call("/items/1", Some("has space")).await;
        call("/items/1", None).await;
        drop(guard);

        let lines = buffer.lines();
        let done: Vec<&Value> = lines
            .iter()
            .filter(|line| line["message"] == "request complete")
            .collect();
        assert_eq!(done.len(), 3);
        assert_eq!(done[0]["span"]["client_request_id"], "edge-abc123");
        assert_ne!(done[0]["span"]["request_id"], "edge-abc123");
        assert!(
            done[1]["span"].get("client_request_id").is_none(),
            "{}",
            done[1]
        );
        assert!(
            done[2]["span"].get("client_request_id").is_none(),
            "{}",
            done[2]
        );
        let raw = String::from_utf8(buffer.0.lock().unwrap().clone()).unwrap();
        assert!(!raw.contains("has space"), "{raw}");
    }

    #[test]
    fn callers_ids_are_checked_strictly() {
        let value = |s: &str| HeaderValue::from_str(s).ok();
        assert_eq!(
            client_request_id(value("abc-123").as_ref()).as_deref(),
            Some("abc-123")
        );
        assert_eq!(
            client_request_id(value(&"x".repeat(64)).as_ref()).as_deref(),
            Some("x".repeat(64).as_str())
        );
        assert_eq!(client_request_id(None), None);
        assert_eq!(client_request_id(value("").as_ref()), None);
        assert_eq!(client_request_id(value("a b").as_ref()), None);
        assert_eq!(client_request_id(value("tab\there").as_ref()), None);
        assert_eq!(client_request_id(value("a\u{7f}b").as_ref()), None);
        assert_eq!(client_request_id(value(&"y".repeat(65)).as_ref()), None);
        assert_eq!(
            HeaderValue::from_bytes(b"caf\xe9")
                .ok()
                .and_then(|v| client_request_id(Some(&v))),
            None,
            "non-ASCII bytes are refused"
        );
    }

    #[tokio::test]
    async fn the_span_names_the_route_pattern_and_not_the_raw_path() {
        let (buffer, guard) = json_buffer();
        let response = call("/items/42?token=secret-query&x=1", Some("req-1")).await;
        assert_eq!(response.status(), StatusCode::OK);
        let id = header_value(&response);
        drop(guard);

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
        assert_eq!(done["span"]["request_id"], id);
        assert_eq!(done["span"]["client_request_id"], "req-1");
        assert_eq!(done["span"]["method"], "GET");
        assert_eq!(done["span"]["path"], "/items/{id}");
        assert!(done["span"].get("device_id").is_none(), "{done}");
    }

    #[tokio::test]
    async fn a_503_is_a_warning_a_5xx_an_error_and_the_raw_path_is_never_logged() {
        let (buffer, _guard) = json_buffer();

        let router = Router::new()
            .route("/boom", get(|| async { StatusCode::INTERNAL_SERVER_ERROR }))
            .route("/paused", get(|| async { StatusCode::SERVICE_UNAVAILABLE }))
            .layer(middleware::from_fn(trace_request));
        let response = router
            .clone()
            .oneshot(Request::get("/boom").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let response = router
            .clone()
            .oneshot(Request::get("/paused").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
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
        let paused = done.next().unwrap();
        assert_eq!(paused["level"], "WARN");
        assert_eq!(paused["status"], 503);
        let missing = done.next().unwrap();
        assert_eq!(missing["level"], "INFO");
        assert_eq!(missing["status"], 404);
        assert_eq!(missing["span"]["path"], UNMATCHED_ROUTE);
    }
}
