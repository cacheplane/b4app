//! The public error envelope. It is B4's, so the Swift client decodes both services with one
//! type: `{"error":{"kind":"request_error"|"execution_error","message":"…","details":{"code":"…"}}}`.
//! Messages are fixed text chosen here; they never carry SQL, a panic, or another tenant's data.

use axum::extract::rejection::JsonRejection;
use axum::extract::{FromRequest, Request};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    /// The caller asked for something wrong or not available to it.
    RequestError,
    /// The hub could not do what was asked.
    ExecutionError,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    pub kind: ErrorKind,
    pub code: &'static str,
    pub message: String,
    pub status: StatusCode,
}

impl ApiError {
    pub fn request(status: StatusCode, code: &'static str, message: impl Into<String>) -> ApiError {
        ApiError {
            kind: ErrorKind::RequestError,
            code,
            message: message.into(),
            status,
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

    pub fn shutting_down() -> ApiError {
        ApiError::execution(
            StatusCode::SERVICE_UNAVAILABLE,
            "shutting_down",
            "the hub is shutting down",
        )
    }
}

impl From<b4hub_db::Error> for ApiError {
    fn from(error: b4hub_db::Error) -> ApiError {
        match error {
            b4hub_db::Error::InvalidCode => ApiError::invalid_code(),
            b4hub_db::Error::ResyncRequired => ApiError::resync_required(),
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

fn json_rejection(rejection: &JsonRejection) -> ApiError {
    if rejection.status() == StatusCode::PAYLOAD_TOO_LARGE {
        ApiError::payload_too_large("the request body is too large")
    } else {
        ApiError::invalid_request("the request body is not valid JSON for this endpoint")
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = json!({
            "error": {
                "kind": self.kind,
                "message": self.message,
                "details": { "code": self.code },
            }
        });
        (self.status, Json(body)).into_response()
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
