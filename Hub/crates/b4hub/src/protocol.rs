//! Early HTTP refusal plus transaction-level admission in the database layer.
use crate::error::ApiError;
use crate::serve::AppState;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use b4hub_core::protocol::ClientProtocol;

/// Place after authentication and before body extraction. The real sync transaction rechecks.
#[derive(Debug, Clone, Copy)]
pub struct SyncProtocol(pub ClientProtocol);

impl FromRequestParts<AppState> for SyncProtocol {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let client = match parts.headers.get("B4-Protocol") {
            None => ClientProtocol::LEGACY,
            Some(value) => ClientProtocol::new(
                value
                    .to_str()
                    .ok()
                    .and_then(|value| value.trim().parse::<u32>().ok())
                    .ok_or_else(|| {
                        ApiError::invalid_request("B4-Protocol must be a whole number")
                    })?,
            ),
        };
        let floor = b4hub_db::settings::protocol_floor(&state.db)
            .await
            .map_err(ApiError::from)?;
        if !floor.admits(client) {
            return Err(b4hub_db::Error::ClientTooOld {
                minimum: floor.minimum(),
            }
            .into());
        }
        Ok(Self(client))
    }
}
