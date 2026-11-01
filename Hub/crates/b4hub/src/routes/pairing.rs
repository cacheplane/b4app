//! `POST /v1/pairing-codes`: a joined Mac mints a short-lived, single-use code that pairs a phone.
//! The phone redeems it at `POST /v1/enroll` like any enrollment code. The code is in this
//! response and nowhere else, and is never logged.

use axum::extract::State;
use axum::Json;
use b4hub_db::devices::{self, Platform};
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::error::ApiError;
use crate::serve::AppState;

/// Only a `macos` device mints; any other caller is told `not_found`, as if the route did not
/// exist for it.
pub async fn create(
    State(state): State<AppState>,
    device: AuthedDevice,
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
