//! `POST /v1/pairing-codes`: a joined Mac mints a short-lived, single-use code that pairs a phone.
//! The phone redeems it at `POST /v1/enroll` like any enrollment code. The code is in this
//! response and nowhere else, and is never logged.
//!
//! `POST /v1/pairing-codes/check`: a signed-in phone asks whether a code is its own account's
//! before it offers to pair (D-170). The check spends nothing.

use std::fmt;

use axum::extract::State;
use axum::Json;
use b4hub_db::devices::{self, Platform};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::auth_limits::FinishAllowed;
use crate::error::{ApiError, ApiJson};
use crate::maintenance::WritesAllowed;
use crate::serve::AppState;

/// Only a `macos` device mints; any other caller is told `not_found`, as if the route did not
/// exist for it.
pub async fn create(
    State(state): State<AppState>,
    device: AuthedDevice,
    WritesAllowed: WritesAllowed,
) -> Result<Json<Value>, ApiError> {
    if device.platform != Platform::Macos {
        return Err(ApiError::not_found());
    }
    let (code, expires_at) =
        devices::create_pairing_code(&state.db, device.org_id, device.user_id, device.device_id)
            .await?;
    let mut answer = json!({ "code": code, "expiresAt": expires_at });
    if let Some(url) = &state.public_url {
        answer["hubURL"] = json!(url.as_str());
    }
    Ok(Json(answer))
}

/// `POST /v1/pairing-codes/check`'s body. `Debug` leaves out the code.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PairingCodeCheckRequest {
    pub code: String,
}

impl fmt::Debug for PairingCodeCheckRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PairingCodeCheckRequest")
            .field("code", &"<redacted>")
            .finish()
    }
}

/// What the check answers: whether the code is for the caller's own account, as the merge counts
/// it (`same_account`: the same org).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PairingCodeCheckResponse {
    pub same_account: bool,
}

/// Whether a code an iPhone could redeem now is the caller's own account's, without redeeming it:
/// a paired phone that scans its own Mac's code says so before it asks (D-170). Only an `ios`
/// device checks; any other is told `not_found`, as `create` tells a phone. An unknown, expired, or
/// used code is `invalid_code`, as `POST /v1/enroll` refuses it. Counted against the per-IP
/// `finish` limit, as the step-up code is, so it is no way to probe codes.
pub async fn check(
    State(state): State<AppState>,
    _allowed: FinishAllowed,
    device: AuthedDevice,
    ApiJson(request): ApiJson<PairingCodeCheckRequest>,
) -> Result<Json<PairingCodeCheckResponse>, ApiError> {
    if device.platform != Platform::Ios {
        return Err(ApiError::not_found());
    }
    let owner = devices::code_owner(&state.db, &request.code)
        .await?
        .ok_or_else(ApiError::invalid_code)?;
    Ok(Json(PairingCodeCheckResponse {
        same_account: owner.org_id == device.org_id,
    }))
}
