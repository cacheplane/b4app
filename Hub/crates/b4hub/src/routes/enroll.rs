//! `POST /v1/enroll`: exchange a one-time enrollment code for a device token. It needs no bearer
//! token; the code is the credential. The token is in this response and nowhere else, and is
//! never logged.
//!
//! A phone signed in to an account of its own may send that account's token: the account is
//! then merged into the code's one as the code is redeemed (pairing a phone that signed up
//! before it met the Mac), in the same transaction, so a failed redemption merges nothing.
//!
//! Like a sign-in, the request may name the devices the client already has (`deviceId`, then
//! `candidateDeviceIds`): the first that is an unrevoked device of the code's user on the same
//! platform is reused, so a Mac or phone that logged out and rejoins with a code keeps its device
//! and the ownership of the rows it synced.

use axum::extract::State;
use axum::http::header::AUTHORIZATION;
use axum::http::HeaderMap;
use axum::Json;
use b4hub_db::accounts::Principal;
use b4hub_db::devices;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::auth::bearer_token;
use crate::error::{ApiError, ApiJson};
use crate::maintenance::WritesAllowed;
use crate::relay::Close;
use crate::routes::auth::DeviceRequest;
use crate::serve::AppState;
use crate::signals;

/// The longest device name accepted, in characters.
pub(crate) const MAX_DEVICE_NAME_CHARS: usize = 200;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EnrollRequest {
    pub code: String,
    pub device_name: String,
    pub platform: String,
    /// A device of the code's user to reuse, as in a sign-in's `device` object.
    #[serde(default)]
    pub device_id: Option<Uuid>,
    /// More devices to try reusing after `device_id`, at most
    /// [`crate::routes::auth::MAX_CANDIDATE_DEVICE_IDS`].
    #[serde(default)]
    pub candidate_device_ids: Option<Vec<Uuid>>,
}

pub async fn enroll(
    WritesAllowed: WritesAllowed,
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

    // Validate before redeeming so a malformed request does not use up the code. The checks
    // (name, platform, the candidate cap) are a sign-in's.
    let device_request = DeviceRequest {
        device_name: request.device_name,
        platform: request.platform,
        device_id: request.device_id,
        candidate_device_ids: request.candidate_device_ids,
    };
    let device = device_request.validate()?;
    let candidates = device_request.reuse_candidates();

    let enrolled =
        devices::redeem_reusing(&state.db, &request.code, &device, &candidates, merge_from).await?;
    if let Some(from) = merge_from {
        // The merged-away account and its tokens are gone; its links end now.
        state.relay.close_user(from.user_id, Close::revoked());
        signals::sessions_changed(&state, from.org_id, from.user_id).await;
        tracing::info!(
            from_user_id = %from.user_id,
            into_org_id = %enrolled.org_id,
            into_user_id = %enrolled.user_id,
            device_id = %enrolled.device_id,
            "merged a phone-only account while pairing"
        );
    }
    Ok(Json(json!({
        "deviceId": enrolled.device_id.to_string(),
        "token": enrolled.token,
        "org": { "slug": enrolled.org_slug, "name": enrolled.org_name },
        "user": { "username": enrolled.username, "displayName": enrolled.display_name },
    })))
}
