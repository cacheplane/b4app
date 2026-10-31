//! `POST /v1/enroll`: exchange a one-time enrollment code for a device token. The only route that
//! needs no bearer token; the code is the credential. The token is in this response and nowhere
//! else, and is never logged.

use axum::extract::State;
use axum::Json;
use b4hub_db::devices;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::error::{ApiError, ApiJson};
use crate::serve::AppState;

/// The platforms a device can enroll as; the `devices` table enforces the same set.
const PLATFORMS: [&str; 3] = ["macos", "ios", "cli"];

/// The longest device name accepted, in characters.
const MAX_DEVICE_NAME_CHARS: usize = 200;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EnrollRequest {
    pub code: String,
    pub device_name: String,
    pub platform: String,
}

pub async fn enroll(
    State(state): State<AppState>,
    ApiJson(request): ApiJson<EnrollRequest>,
) -> Result<Json<Value>, ApiError> {
    // Validate before redeeming so a malformed request does not use up the code.
    let name = request.device_name.trim();
    if name.is_empty() || name.chars().count() > MAX_DEVICE_NAME_CHARS {
        return Err(ApiError::invalid_request(
            "deviceName must be 1 to 200 characters",
        ));
    }
    if !PLATFORMS.contains(&request.platform.as_str()) {
        return Err(ApiError::invalid_request(
            "platform must be one of macos, ios, cli",
        ));
    }

    let enrolled = devices::redeem(&state.db, &request.code, name, &request.platform).await?;
    Ok(Json(json!({
        "deviceId": enrolled.device_id.to_string(),
        "token": enrolled.token,
        "org": { "slug": enrolled.org_slug, "name": enrolled.org_name },
        "user": { "username": enrolled.username, "displayName": enrolled.display_name },
    })))
}
