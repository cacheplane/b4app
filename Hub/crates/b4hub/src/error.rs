//! The public error envelope. It is B4's, so the Swift client decodes both services with one
//! type: `{"error":{"kind":"request_error"|"execution_error","message":"…","details":{"code":"…"}}}`.
//! Messages are fixed text chosen here; they never carry SQL, a panic, or another tenant's data.
//! `rate_limited` adds `details.retryAfterMs` and a `Retry-After` header.

use std::time::Duration;

use axum::extract::rejection::JsonRejection;
use axum::extract::{FromRequest, Request};
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::json;

/// The error codes the relay adds. They travel in `error` frames and in a `reply`'s `error` on the
/// link; only `rate_limited` is also an HTTP status (429, before a link upgrade). `not_found` and
/// `stale_runtime_request` are reused from the table above.
pub mod relay_code {
    pub const DEVICE_OFFLINE: &str = "device_offline";
    pub const COMMAND_EXPIRED: &str = "command_expired";
    pub const RELAY_TIMEOUT: &str = "relay_timeout";
    pub const RATE_LIMITED: &str = "rate_limited";
    pub const LINK_REPLACED: &str = "link_replaced";
    pub const CLIENT_TOO_OLD: &str = "client_too_old";
    pub const WATCH_LIMIT: &str = "watch_limit";

    /// Every code above, for tests and for validating a host's `reply`.
    pub const ALL: [&str; 7] = [
        DEVICE_OFFLINE,
        COMMAND_EXPIRED,
        RELAY_TIMEOUT,
        RATE_LIMITED,
        LINK_REPLACED,
        CLIENT_TOO_OLD,
        WATCH_LIMIT,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// The caller asked for something wrong or not available to it.
    RequestError,
    /// The hub could not do what was asked.
    ExecutionError,
}

/// `details.reason` of a passkey sign-in's `credential_rejected` when no identity holds the asserted
/// credential id ([`ApiError::credential_unknown`]).
pub const UNKNOWN_CREDENTIAL: &str = "unknown_credential";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    pub kind: ErrorKind,
    pub code: &'static str,
    pub message: String,
    pub status: StatusCode,
    /// For `rate_limited`: how long until the caller may try again, sent as `Retry-After`.
    pub retry_after: Option<Duration>,
    /// Fields added to `details` beside `code`, such as a `rate_limited` answer's `retryAfterMs`.
    pub extra: serde_json::Map<String, serde_json::Value>,
}

impl ApiError {
    pub fn request(status: StatusCode, code: &'static str, message: impl Into<String>) -> ApiError {
        ApiError {
            kind: ErrorKind::RequestError,
            code,
            message: message.into(),
            status,
            retry_after: None,
            extra: serde_json::Map::new(),
        }
    }

    pub fn execution(
        status: StatusCode,
        code: &'static str,
        message: impl Into<String>,
    ) -> ApiError {
        ApiError {
            kind: ErrorKind::ExecutionError,
            code,
            message: message.into(),
            status,
            retry_after: None,
            extra: serde_json::Map::new(),
        }
    }

    pub fn not_found() -> ApiError {
        ApiError::request(StatusCode::NOT_FOUND, "not_found", "not found")
    }

    /// The credential is missing, malformed, unknown, or revoked. All four answer identically so
    /// a caller learns nothing about which it was.
    pub fn unauthorized() -> ApiError {
        ApiError::request(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "a valid device token is required",
        )
    }

    /// The credential is good but this device may not do this.
    pub fn forbidden(message: impl Into<String>) -> ApiError {
        ApiError::request(StatusCode::FORBIDDEN, "forbidden", message)
    }

    pub fn invalid_code() -> ApiError {
        ApiError::request(
            StatusCode::UNAUTHORIZED,
            "invalid_code",
            "the enrollment code is invalid, expired, or already used",
        )
    }

    pub fn invalid_request(message: impl Into<String>) -> ApiError {
        ApiError::request(StatusCode::BAD_REQUEST, "invalid_request", message)
    }

    pub fn payload_too_large(message: impl Into<String>) -> ApiError {
        ApiError::request(StatusCode::PAYLOAD_TOO_LARGE, "payload_too_large", message)
    }

    /// The caller's cursor is older than the feed still holds; it must start over.
    pub fn resync_required() -> ApiError {
        ApiError::request(
            StatusCode::GONE,
            "resync_required",
            "the cursor is older than the retained changes; start again from the beginning",
        )
    }

    /// A sign-in with a new Apple ID or passkey while the hub's sign-up policy is closed.
    pub fn signup_closed() -> ApiError {
        ApiError::request(
            StatusCode::FORBIDDEN,
            "signup_closed",
            "this hub does not create new accounts",
        )
    }

    /// The ceremony or handoff is unknown, expired, or already used (indistinguishably).
    pub fn ceremony_expired() -> ApiError {
        ApiError::request(
            StatusCode::BAD_REQUEST,
            "ceremony_expired",
            "the sign-in expired or was already used; start again",
        )
    }

    /// Any failed verification of a sign-in credential. Deliberately vague: the caller learns
    /// nothing about which check failed.
    pub fn credential_rejected() -> ApiError {
        ApiError::request(
            StatusCode::UNAUTHORIZED,
            "credential_rejected",
            "the credential could not be verified",
        )
    }

    /// [`ApiError::credential_rejected`] for a passkey sign-in whose credential id no identity holds
    /// (as after its account was deleted), with `details.reason` [`UNKNOWN_CREDENTIAL`], so the app
    /// can tell the password manager to forget that passkey. Credential ids are random, so the reason
    /// tells a caller nothing it could use to find an account. Every other failed check carries no
    /// reason.
    pub fn credential_unknown() -> ApiError {
        let mut error = ApiError::credential_rejected();
        error
            .extra
            .insert("reason".into(), json!(UNKNOWN_CREDENTIAL));
        error
    }

    /// Removing the identity would leave the account with no way to sign in.
    pub fn last_identity() -> ApiError {
        ApiError::request(
            StatusCode::CONFLICT,
            "last_identity",
            "the last sign-in method of an account cannot be removed",
        )
    }

    /// The signed-in account cannot be merged into the code's account: it is already in the
    /// code's org, is a member of a shared org, or has (or had) a Mac. `details.reason` says which
    /// (`same_account`, `shared_org`, `has_mac`) when the hub knows.
    pub fn merge_refused(reason: Option<b4hub_db::MergeRefusal>) -> ApiError {
        let mut error = ApiError::request(
            StatusCode::CONFLICT,
            "merge_refused",
            "this account cannot be merged into another",
        );
        if let Some(reason) = reason {
            error.extra.insert("reason".into(), json!(reason.as_str()));
        }
        error
    }

    /// Linking an Apple ID to an account that already has one.
    pub fn apple_linked() -> ApiError {
        ApiError::request(
            StatusCode::CONFLICT,
            "apple_linked",
            "this account already has an Apple ID; remove it before connecting another",
        )
    }

    /// Deleting an account is only possible for the owner of a personal org.
    pub fn shared_org() -> ApiError {
        ApiError::request(
            StatusCode::CONFLICT,
            "shared_org",
            "an account in a shared org cannot be deleted here",
        )
    }

    /// A change that needs a fresh assertion (D-135) arrived without a live step-up grant of this
    /// user and device. [`crate::routes::step_up::step_up_required`] adds `details.methods`.
    pub fn step_up_required() -> ApiError {
        ApiError::request(
            StatusCode::FORBIDDEN,
            "step_up_required",
            "confirm it is you with a passkey or your Apple ID, then try again",
        )
    }

    /// A caller is over a rate limit; used before a link upgrade, where the answer is HTTP.
    pub fn rate_limited() -> ApiError {
        ApiError::request(
            StatusCode::TOO_MANY_REQUESTS,
            relay_code::RATE_LIMITED,
            "too many requests; try again shortly",
        )
    }

    /// `rate_limited` with the wait the caller should honour before trying again.
    pub fn rate_limited_after(retry_after: Duration) -> ApiError {
        let mut error = ApiError::rate_limited();
        let millis = u64::try_from(retry_after.as_millis())
            .unwrap_or(u64::MAX)
            .max(1);
        error.extra.insert("retryAfterMs".into(), json!(millis));
        error.retry_after = Some(retry_after);
        error
    }

    pub fn method_not_allowed() -> ApiError {
        ApiError::request(
            StatusCode::METHOD_NOT_ALLOWED,
            "method_not_allowed",
            "method not allowed",
        )
    }

    /// An unexpected failure. The cause is logged where it happened, never sent.
    pub fn internal() -> ApiError {
        ApiError::execution(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            "the hub could not complete the request",
        )
    }

    pub fn not_ready() -> ApiError {
        ApiError::execution(
            StatusCode::SERVICE_UNAVAILABLE,
            "not_ready",
            "the hub is not ready to serve requests",
        )
    }

    /// A link upgrade that reached an instance other than the one serving the user's links:
    /// `instance_id` is the owner. The device retries at once (up to three times), so the load
    /// balancer can land it on the owner; see `Hub/API.md`, "More than one instance".
    pub fn relocated(instance_id: uuid::Uuid) -> ApiError {
        let mut error = ApiError::request(
            StatusCode::CONFLICT,
            "relocated",
            "your links are served by another hub instance",
        );
        error
            .extra
            .insert("instanceId".into(), json!(instance_id.to_string()));
        error
    }

    pub fn shutting_down() -> ApiError {
        ApiError::execution(
            StatusCode::SERVICE_UNAVAILABLE,
            "shutting_down",
            "the hub is shutting down",
        )
    }

    /// A write while the operator has paused writes (`b4hub maintenance on`). `message` is the
    /// operator's text, if any. `maintenance::Refused` is what a handler answers with, so the
    /// response also carries `Retry-After`.
    pub fn maintenance(message: Option<&str>) -> ApiError {
        ApiError::execution(
            StatusCode::SERVICE_UNAVAILABLE,
            "maintenance",
            format!(
                "the hub is in maintenance: {}",
                message.unwrap_or("writes are paused")
            ),
        )
    }
}

impl From<b4hub_db::Error> for ApiError {
    fn from(error: b4hub_db::Error) -> ApiError {
        match error {
            b4hub_db::Error::InvalidCode => ApiError::invalid_code(),
            b4hub_db::Error::ResyncRequired => ApiError::resync_required(),
            b4hub_db::Error::CeremonyExpired => ApiError::ceremony_expired(),
            b4hub_db::Error::IdentityTaken => ApiError::credential_rejected(),
            b4hub_db::Error::LastIdentity => ApiError::last_identity(),
            b4hub_db::Error::MergeRefused(reason) => ApiError::merge_refused(reason),
            b4hub_db::Error::SharedOrg => ApiError::shared_org(),
            b4hub_db::Error::AppleLinked => ApiError::apple_linked(),
            b4hub_db::Error::RateLimited { retry_after } => {
                ApiError::rate_limited_after(retry_after)
            }
            other => {
                tracing::error!(error = %other, "request failed in the database layer");
                ApiError::internal()
            }
        }
    }
}

/// `axum::Json` for request bodies, with every rejection (malformed JSON, an unknown or missing
/// field, a wrong content type, an oversized body) turned into the B4 envelope instead of axum's
/// plain-text answer. The message is fixed text: serde's wording is not part of the API.
pub struct ApiJson<T>(pub T);

impl<S, T> FromRequest<S> for ApiJson<T>
where
    S: Send + Sync,
    T: DeserializeOwned,
{
    type Rejection = ApiError;

    async fn from_request(request: Request, state: &S) -> Result<ApiJson<T>, ApiError> {
        match Json::<T>::from_request(request, state).await {
            Ok(Json(value)) => Ok(ApiJson(value)),
            Err(rejection) => Err(json_rejection(&rejection)),
        }
    }
}

/// A JSON body that may be absent: an empty body is `T::default()`. Otherwise as [`ApiJson`],
/// without requiring a content type.
pub struct OptionalJson<T>(pub T);

impl<S, T> FromRequest<S> for OptionalJson<T>
where
    S: Send + Sync,
    T: DeserializeOwned + Default,
{
    type Rejection = ApiError;

    async fn from_request(request: Request, state: &S) -> Result<OptionalJson<T>, ApiError> {
        let body = axum::body::Bytes::from_request(request, state)
            .await
            .map_err(|_| ApiError::payload_too_large("the request body is too large"))?;
        if body.iter().all(u8::is_ascii_whitespace) {
            return Ok(OptionalJson(T::default()));
        }
        serde_json::from_slice(&body)
            .map(OptionalJson)
            .map_err(|_| {
                ApiError::invalid_request("the request body is not valid JSON for this endpoint")
            })
    }
}

fn json_rejection(rejection: &JsonRejection) -> ApiError {
    if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
        ApiError::payload_too_large("the request body is too large")
    } else {
        ApiError::invalid_request("the request body is not valid JSON for this endpoint")
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut details = self.extra;
        details.insert("code".into(), json!(self.code));
        let body = json!({
            "error": {
                "kind": self.kind,
                "message": self.message,
                "details": details,
            }
        });
        let mut response = (self.status, Json(body)).into_response();
        if let Some(wait) = self.retry_after {
            // Whole seconds, rounded up, and at least one.
            let seconds = wait.as_secs() + u64::from(wait.subsec_nanos() > 0);
            response
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(seconds.max(1)));
        }
        response
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn serialises_as_the_b4_envelope() {
        let response = ApiError::not_ready().into_response();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        let bytes = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            body,
            json!({"error": {
                "kind": "execution_error",
                "message": "the hub is not ready to serve requests",
                "details": {"code": "not_ready"},
            }})
        );
    }

    #[tokio::test]
    async fn rate_limited_says_when_to_retry() {
        let response = ApiError::rate_limited_after(Duration::from_millis(1500)).into_response();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()[header::RETRY_AFTER], "2");
        let bytes = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            body["error"]["details"],
            json!({"code": "rate_limited", "retryAfterMs": 1500})
        );
        assert_eq!(body["error"]["kind"], "request_error");
    }

    #[tokio::test]
    async fn relocated_names_the_owner() {
        let owner = uuid::Uuid::from_u128(7);
        let response = ApiError::relocated(owner).into_response();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let bytes = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            body,
            json!({"error": {
                "kind": "request_error",
                "message": "your links are served by another hub instance",
                "details": {"code": "relocated", "instanceId": owner.to_string()},
            }})
        );
    }

    #[test]
    fn relay_codes_are_the_swift_wire_strings() {
        assert_eq!(
            relay_code::ALL,
            [
                "device_offline",
                "command_expired",
                "relay_timeout",
                "rate_limited",
                "link_replaced",
                "client_too_old",
                "watch_limit",
            ]
        );
        let error = ApiError::rate_limited();
        assert_eq!(error.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(error.code, "rate_limited");
    }

    #[tokio::test]
    async fn rate_limited_carries_retry_after_ms_beside_the_code() {
        let response = ApiError::rate_limited_after(Duration::from_millis(1500)).into_response();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        let bytes = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            body["error"]["details"],
            json!({"code": "rate_limited", "retryAfterMs": 1500})
        );
        // Never zero: a client that waits "0 ms" would hammer the hub.
        let tiny = ApiError::rate_limited_after(Duration::ZERO);
        assert_eq!(tiny.extra["retryAfterMs"], json!(1));
    }

    #[test]
    fn kinds_serialise_in_snake_case() {
        assert_eq!(
            serde_json::to_string(&ErrorKind::RequestError).unwrap(),
            "\"request_error\""
        );
        assert_eq!(
            serde_json::to_string(&ErrorKind::ExecutionError).unwrap(),
            "\"execution_error\""
        );
    }
}
