//! Liveness and readiness. `/healthz` says the process is up; `/readyz` says it should receive
//! traffic: migrations are current and it has not begun shutting down.

use axum::extract::State;
use axum::Json;
use serde_json::{json, Value};

use crate::error::ApiError;
use crate::serve::AppState;

/// The oldest client protocol this hub speaks, reported so clients can refuse a hub that is
/// too new for them.
pub const MIN_CLIENT_PROTOCOL: u32 = 1;

pub async fn healthz() -> Json<Value> {
    Json(json!({ "ok": true }))
}

pub async fn readyz(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    if state.shutdown.is_triggered() {
        return Err(ApiError::shutting_down());
    }
    match b4hub_db::migrate::status(&state.db).await {
        Ok(status) if status.pending == 0 => Ok(Json(json!({
            "ok": true,
            "migrations": "current",
            "minClientProtocol": MIN_CLIENT_PROTOCOL,
        }))),
        Ok(status) => {
            tracing::warn!(
                pending = status.pending,
                "readiness: migrations are pending"
            );
            Err(ApiError::not_ready())
        }
        Err(error) => {
            tracing::warn!(%error, "readiness: the database is unavailable");
            Err(ApiError::not_ready())
        }
    }
}
