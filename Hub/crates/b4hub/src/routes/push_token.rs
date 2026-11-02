//! `POST /v1/devices/self/push-token`: a phone registers the APNs token the hub notifies it at
//! (decision D-111).

use axum::extract::State;
use axum::http::StatusCode;
use b4hub_db::devices::Platform;
use b4hub_db::push;
use serde::Deserialize;

use crate::auth::AuthedDevice;
use crate::error::{ApiError, ApiJson};
use crate::maintenance::WritesAllowed;
use crate::serve::AppState;

const TOKEN_LENGTH: std::ops::RangeInclusive<usize> = 32..=512;
const BUNDLE_ID_MAX: usize = 155;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct TokenRequest {
    token: String,
    environment: String,
    bundle_id: String,
}

pub async fn save(
    State(state): State<AppState>,
    device: AuthedDevice,
    WritesAllowed: WritesAllowed,
    ApiJson(request): ApiJson<TokenRequest>,
) -> Result<StatusCode, ApiError> {
    if device.platform != Platform::Ios {
        return Err(ApiError::forbidden(
            "only an iOS device registers a push token",
        ));
    }
    if !TOKEN_LENGTH.contains(&request.token.len())
        || !request.token.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(ApiError::invalid_request(
            "token must be 32 to 512 hexadecimal characters",
        ));
    }
    if !matches!(request.environment.as_str(), "sandbox" | "production") {
        return Err(ApiError::invalid_request(
            "environment must be sandbox or production",
        ));
    }
    if !is_bundle_id(&request.bundle_id) {
        return Err(ApiError::invalid_request(
            "bundleId must be a reverse-DNS bundle identifier",
        ));
    }
    push::save_token(
        &state.db,
        &device,
        &request.token,
        &request.environment,
        &request.bundle_id,
    )
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `^[A-Za-z0-9][A-Za-z0-9.-]{0,154}$`.
fn is_bundle_id(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() <= BUNDLE_ID_MAX
        && bytes.first().is_some_and(u8::is_ascii_alphanumeric)
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_ids() {
        assert!(is_bundle_id("com.cacheplane.b4app"));
        assert!(is_bundle_id("a"));
        assert!(is_bundle_id(&format!("a{}", "-".repeat(154))));
        assert!(!is_bundle_id(&"a".repeat(156)));
        assert!(!is_bundle_id(""));
        assert!(!is_bundle_id(".a"));
        assert!(!is_bundle_id("-a"));
        assert!(!is_bundle_id("a b"));
        assert!(!is_bundle_id("a_b"));
        assert!(!is_bundle_id("é.com"));
    }
}
