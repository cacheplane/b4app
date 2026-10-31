//! The public error envelope. It is B4's, so the Swift client decodes both services with one
//! type: `{"error":{"kind":"request_error"|"execution_error","message":"…","details":{"code":"…"}}}`.
//! Messages are fixed text chosen here; they never carry SQL, a panic, or another tenant's data.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
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
