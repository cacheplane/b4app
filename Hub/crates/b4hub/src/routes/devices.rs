//! Revoking the authenticated device (`DELETE /v1/devices/self`) and the user's devices
//! (`GET /v1/devices`). `GET /v1/me` is in [`crate::routes::me`].

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use b4hub_db::devices;
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::error::ApiError;
use crate::serve::AppState;

pub async fn revoke_self(
    State(state): State<AppState>,
    device: AuthedDevice,
) -> Result<StatusCode, ApiError> {
    devices::revoke_self(&state.db, device.org_id, device.device_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `GET /v1/devices`: every device of the authenticated user, revoked ones included.
pub async fn list(
    State(state): State<AppState>,
    device: AuthedDevice,
) -> Result<Json<Value>, ApiError> {
    let devices = devices::list(&state.db, device.org_id, device.user_id).await?;
    let devices: Vec<Value> = devices
        .into_iter()
        .map(|d| {
            json!({
                "id": d.id.to_string(),
                "name": d.name,
                "platform": d.platform,
                "lastSeenAt": d.last_seen_at,
                "revokedAt": d.revoked_at,
            })
        })
        .collect();
    Ok(Json(json!({ "devices": devices })))
}
