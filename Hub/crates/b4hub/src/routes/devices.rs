//! The authenticated device's own record: `GET /v1/me` and `DELETE /v1/devices/self`.

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use b4hub_db::devices;
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::error::ApiError;
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
    Ok(StatusCode::NO_CONTENT)
}
