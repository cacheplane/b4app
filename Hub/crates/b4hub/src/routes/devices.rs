//! The authenticated device's own record (`GET /v1/me`, `DELETE /v1/devices/self`) and the
//! user's devices (`GET /v1/devices`).

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use b4hub_db::devices;
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::error::ApiError;
use crate::relay::Close;
use crate::serve::AppState;

pub async fn me(
    State(state): State<AppState>,
    device: AuthedDevice,
) -> Result<Json<Value>, ApiError> {
    // The device was valid a moment ago; if it is gone now it was revoked in between.
    let info = devices::me(&state.db, device.org_id, device.device_id)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    Ok(Json(json!({
        "deviceId": info.device_id.to_string(),
        "deviceName": info.device_name,
        "platform": info.platform,
        "org": { "slug": info.org_slug, "name": info.org_name },
        "user": { "username": info.username, "displayName": info.display_name },
        "createdAt": info.created_at,
    })))
}

pub async fn revoke_self(
    State(state): State<AppState>,
    device: AuthedDevice,
) -> Result<StatusCode, ApiError> {
    devices::revoke_self(&state.db, device.org_id, device.device_id).await?;
    // A revoked device's link ends now, not at its next heartbeat.
    state.relay.close(device.device_id, Close::revoked());
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
