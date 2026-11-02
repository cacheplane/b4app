//! `POST /v1/enroll`: exchange a one-time enrollment code for a device token. It needs no bearer
//! token; the code is the credential. The token is in this response and nowhere else, and is
//! never logged.
//!
//! A phone signed in to an account of its own may send that account's token: the account is
//! then merged into the code's one as the code is redeemed (pairing a phone that signed up
//! before it met the Mac), in the same transaction, so a failed redemption merges nothing.

use axum::extract::State;
use axum::http::header::AUTHORIZATION;
use axum::http::HeaderMap;
use axum::Json;
use b4hub_db::accounts::Principal;
use b4hub_db::devices;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::bearer_token;
use crate::error::{ApiError, ApiJson};
use crate::serve::AppState;

/// The platforms a device can enroll as; the `devices` table enforces the same set.
const PLATFORMS: [&str; 3] = ["macos", "ios", "cli"];

/// The longest device name accepted, in characters.
pub(crate) const MAX_DEVICE_NAME_CHARS: usize = 200;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EnrollRequest {
    pub code: String,
    pub device_name: String,
    pub platform: String,
}

pub async fn enroll(
    State(state): State<AppState>,
    headers: HeaderMap,
    ApiJson(request): ApiJson<EnrollRequest>,
) -> Result<Json<Value>, ApiError> {
    // An `Authorization` header that is present must be a valid token: it asks for a merge.
    let merge_from = match headers.get(AUTHORIZATION) {
        None => None,
        Some(_) => {
            let token = bearer_token(&headers).ok_or_else(ApiError::unauthorized)?;
            let device = devices::authenticate(&state.db, token)
                .await?
                .ok_or_else(ApiError::unauthorized)?;
            Some(Principal::from(device))
        }
    };

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

    let enrolled = match merge_from {
        None => devices::redeem(&state.db, &request.code, name, &request.platform).await?,
        Some(from) => {
            let enrolled =
                devices::redeem_merging(&state.db, &request.code, name, &request.platform, from)
                    .await?;
            tracing::info!(
                from_user_id = %from.user_id,
                into_org_id = %enrolled.org_id,
                into_user_id = %enrolled.user_id,
                device_id = %enrolled.device_id,
                "merged a phone-only account while pairing"
            );
            enrolled
        }
    };
    Ok(Json(json!({
        "deviceId": enrolled.device_id.to_string(),
        "token": enrolled.token,
        "org": { "slug": enrolled.org_slug, "name": enrolled.org_name },
        "user": { "username": enrolled.username, "displayName": enrolled.display_name },
    })))
}
