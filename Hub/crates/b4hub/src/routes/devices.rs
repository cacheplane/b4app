//! Revoking the authenticated device (`DELETE /v1/devices/self`) and the user's devices
//! (`GET /v1/devices`). `GET /v1/me` is in [`crate::routes::me`].

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use b4hub_db::devices::{self, Platform};
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::error::ApiError;
use crate::maintenance::WritesAllowed;
use crate::relay::Close;
use crate::serve::AppState;
use crate::signals;

pub async fn revoke_self(
    State(state): State<AppState>,
    device: AuthedDevice,
    WritesAllowed: WritesAllowed,
) -> Result<StatusCode, ApiError> {
    devices::revoke_self(&state.db, device.org_id, device.device_id).await?;
    // A revoked device's link ends now, not at its next heartbeat.
    let had_link = state.relay.close(device.device_id, Close::revoked());
    // With a link, the link's own end tells the user's phones. Without one, a Mac that was offline
    // still leaves their list now.
    if !had_link && device.platform == Platform::Macos {
        state
            .relay
            .broadcast_presence(&state.db, device.org_id, device.user_id)
            .await;
    }
    // The link, or the user's phones, may be on another instance.
    signals::sessions_changed(&state, device.org_id, device.user_id).await;
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
