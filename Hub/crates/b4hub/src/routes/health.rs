//! Liveness and readiness. `/healthz` says the process is up; `/readyz` says it should receive
//! traffic: migrations are current, it has not begun shutting down, the relay serves a link (an
//! in-process probe, `relay::link::probe`), and its instance heartbeat is fresh enough that the
//! other instances have not counted it dead. Maintenance does not fail readiness (reads are still
//! served); `/readyz` reports it instead.
//!
//! Every `/readyz` answer carries `Set-Cookie: b4hub-instance=<this instance>`, which the load
//! balancer's application-cookie stickiness learns the target from.

use axum::extract::State;
use axum::http::header::SET_COOKIE;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::{json, Value};

use crate::error::ApiError;
use crate::relay::link;
use crate::serve::AppState;

/// The oldest client protocol this hub speaks, reported so clients can refuse a hub that is
/// too new for them.
pub const MIN_CLIENT_PROTOCOL: u32 = 1;

pub async fn healthz() -> Json<Value> {
    Json(json!({ "ok": true }))
}

pub async fn readyz(State(state): State<AppState>) -> Response {
    let mut response = match readiness(&state).await {
        Ok(body) => Json(body).into_response(),
        Err(error) => error.into_response(),
    };
    response
        .headers_mut()
        .insert(SET_COOKIE, state.instances.cookie());
    response
}

async fn readiness(state: &AppState) -> Result<Value, ApiError> {
    if state.shutdown.is_triggered() {
        return Err(ApiError::shutting_down());
    }
    match b4hub_db::migrate::status(&state.db).await {
        Ok(status) if status.pending == 0 => {}
        Ok(status) => {
            tracing::warn!(
                pending = status.pending,
                "readiness: migrations are pending"
            );
            return Err(ApiError::not_ready());
        }
        Err(error) => {
            tracing::warn!(%error, "readiness: the database is unavailable");
            return Err(ApiError::not_ready());
        }
    }

    let relay = match link::probe(state).await {
        Ok(()) => "ok",
        Err(failure) => {
            tracing::warn!(?failure, "readiness: the relay probe failed");
            "failed"
        }
    };
    let instances = if state.instances.stale() {
        tracing::warn!(
            instance = %state.instances.id(),
            "readiness: the instance heartbeat is stale"
        );
        "stale"
    } else {
        "ok"
    };
    if relay != "ok" || instances != "ok" {
        let mut error = ApiError::not_ready();
        error.extra.insert("relay".into(), json!(relay));
        error.extra.insert("instances".into(), json!(instances));
        return Err(error);
    }

    let mut body = json!({
        "ok": true,
        "migrations": "current",
        "minClientProtocol": MIN_CLIENT_PROTOCOL,
        "relay": relay,
        "instances": instances,
    });
    if state.maintenance.current().is_some() {
        body["maintenance"] = json!("read_only");
    }
    Ok(body)
}
