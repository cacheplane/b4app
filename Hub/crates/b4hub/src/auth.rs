//! Bearer authentication. [`AuthedDevice`] is an axum `FromRequestParts` extractor, which axum
//! runs before any body extractor, so an unauthenticated request is refused without its body
//! being read. The principal (org, user, device) comes only from the verified token.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::FromRequestParts;
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use axum::http::HeaderMap;
use b4hub_db::devices;
use uuid::Uuid;

use crate::error::ApiError;
use crate::serve::AppState;

/// How often a device's `last_seen_at` is written.
const LAST_SEEN_INTERVAL: Duration = Duration::from_secs(60);

/// A device that presented a valid token. Dereferences to the verified principal.
#[derive(Debug, Clone, Copy)]
pub struct AuthedDevice(pub devices::AuthedDevice);

impl std::ops::Deref for AuthedDevice {
    type Target = devices::AuthedDevice;

    fn deref(&self) -> &devices::AuthedDevice {
        &self.0
    }
}

impl FromRequestParts<AppState> for AuthedDevice {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<AuthedDevice, ApiError> {
        let token = bearer_token(&parts.headers).ok_or_else(ApiError::unauthorized)?;
        let device = devices::authenticate(&state.db, token)
            .await?
            .ok_or_else(ApiError::unauthorized)?;
        if state.last_touched.due(device.device_id, Instant::now()) {
            // A failed touch must not fail the request it rode on.
            if let Err(error) =
                devices::touch_last_seen(&state.db, device.org_id, device.device_id).await
            {
                tracing::warn!(%error, "could not record last_seen_at");
            }
        }
        Ok(AuthedDevice(device))
    }
}

/// The token in `Authorization: Bearer <token>`; `None` for a missing header, another scheme, an
/// empty token, or a token with whitespace in it. The scheme is matched case-insensitively.
pub(crate) fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let value = headers.get(AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    (scheme.eq_ignore_ascii_case("bearer")
        && !token.is_empty()
        && !token.contains(char::is_whitespace))
    .then_some(token)
}

/// When each device's `last_seen_at` was last written, so a busy device costs one write a
/// minute rather than one per request. In memory: M8a runs a single replica, and losing the map
/// on restart only means one extra write.
#[derive(Clone, Debug, Default)]
pub struct LastTouched(Arc<Mutex<HashMap<Uuid, Instant>>>);

impl LastTouched {
    /// True when `device` has not been recorded within the interval before `now`, and then
    /// records it as touched at `now`.
    pub fn due(&self, device: Uuid, now: Instant) -> bool {
        let mut map = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match map.get(&device) {
            Some(last) if now.saturating_duration_since(*last) < LAST_SEEN_INTERVAL => false,
            _ => {
                map.insert(device, now);
                true
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use axum::http::HeaderValue;

    use super::*;

    fn headers(value: Option<&str>) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Some(value) = value {
            headers.insert(AUTHORIZATION, HeaderValue::from_str(value).unwrap());
        }
        headers
    }

    #[test]
    fn bearer_tokens_are_parsed_strictly() {
        assert_eq!(bearer_token(&headers(Some("Bearer abc"))), Some("abc"));
        assert_eq!(bearer_token(&headers(Some("bearer abc"))), Some("abc"));
        assert_eq!(bearer_token(&headers(None)), None);
        assert_eq!(bearer_token(&headers(Some("Basic abc"))), None);
        assert_eq!(bearer_token(&headers(Some("Bearer"))), None);
        assert_eq!(bearer_token(&headers(Some("Bearer "))), None);
        assert_eq!(bearer_token(&headers(Some("Bearer a b"))), None);
        assert_eq!(bearer_token(&headers(Some("abc"))), None);
    }

    #[test]
    fn a_device_is_touched_at_most_once_a_minute() {
        let touched = LastTouched::default();
        let device = Uuid::from_u128(1);
        let other = Uuid::from_u128(2);
        let start = Instant::now();
        assert!(touched.due(device, start));
        assert!(!touched.due(device, start + Duration::from_secs(59)));
        assert!(touched.due(other, start + Duration::from_secs(1)));
        assert!(touched.due(device, start + Duration::from_secs(60)));
        assert!(!touched.due(device, start + Duration::from_secs(61)));
    }
}
