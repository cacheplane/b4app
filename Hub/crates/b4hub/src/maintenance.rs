//! Maintenance mode: while the operator has switched it on (`b4hub maintenance on`, a row in
//! `hub_settings`), every instance refuses writes with `503 maintenance` and `Retry-After: 30`
//! while reads and `/readyz` continue. Each `serve` polls the switch at start and then every
//! `Settings::maintenance_poll()`, keeping the last value it read when a poll fails.

use std::sync::{Arc, RwLock};
use std::time::Duration;

use axum::extract::FromRequestParts;
use axum::http::header::RETRY_AFTER;
use axum::http::request::Parts;
use axum::http::HeaderValue;
use axum::response::{IntoResponse, Response};
use b4hub_db::settings::{self, Maintenance};
use b4hub_db::Db;

use crate::error::ApiError;
use crate::serve::{AppState, Shutdown};

/// What `Retry-After` says on a refused write, in seconds.
pub const RETRY_AFTER_SECS: u32 = 30;

/// The switch as this instance last saw it. Cheap to clone; shared by the poll loop and the
/// handlers.
#[derive(Clone, Debug, Default)]
pub struct MaintenanceState(Arc<RwLock<Option<Maintenance>>>);

impl MaintenanceState {
    pub fn current(&self) -> Option<Maintenance> {
        self.0
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn set(&self, maintenance: Option<Maintenance>) {
        *self
            .0
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = maintenance;
    }
}

/// The answer a write gets while maintenance is on: `503 maintenance` plus `Retry-After`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused(pub ApiError);

pub fn refused(maintenance: &Maintenance) -> Refused {
    Refused(ApiError::maintenance(maintenance.message.as_deref()))
}

impl IntoResponse for Refused {
    fn into_response(self) -> Response {
        let mut response = self.0.into_response();
        response
            .headers_mut()
            .insert(RETRY_AFTER, HeaderValue::from(RETRY_AFTER_SECS));
        response
    }
}

/// An extractor that refuses the request while maintenance is on. Put it after `AuthedDevice`
/// (so the refusal is logged with the device id and a bad token still gets `401`) and before the
/// body extractor, so a refused body is never read.
#[derive(Debug, Clone, Copy)]
pub struct WritesAllowed;

impl FromRequestParts<AppState> for WritesAllowed {
    type Rejection = Refused;

    async fn from_request_parts(
        _parts: &mut Parts,
        state: &AppState,
    ) -> Result<WritesAllowed, Refused> {
        match state.maintenance.current() {
            Some(maintenance) => Err(refused(&maintenance)),
            None => Ok(WritesAllowed),
        }
    }
}

/// One read of the switch into `state`; a failure is logged and leaves the last value in place,
/// since a database blip must not flip the hub into or out of maintenance.
pub async fn refresh(db: &Db, state: &MaintenanceState) {
    match settings::maintenance(db).await {
        Ok(maintenance) => {
            let was_on = state.current().is_some();
            let is_on = maintenance.is_some();
            if was_on != is_on {
                tracing::info!(
                    maintenance = if is_on { "read_only" } else { "off" },
                    "maintenance switch changed"
                );
            }
            state.set(maintenance);
        }
        Err(error) => {
            tracing::warn!(%error, "could not read the maintenance switch; keeping the last value");
        }
    }
}

/// [`refresh`]es now and then every `interval` until `shutdown`. `serve` also refreshes once
/// before it starts listening, so no write slips through before the first poll.
pub async fn poll_loop(db: Db, state: MaintenanceState, interval: Duration, shutdown: Shutdown) {
    let mut stopping = shutdown.subscribe();
    loop {
        refresh(&db, &state).await;
        tokio::select! {
            () = tokio::time::sleep(interval) => {}
            _ = stopping.wait_for(|down| *down) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use axum::http::StatusCode;

    use super::*;

    #[tokio::test]
    async fn a_refusal_says_when_to_retry() {
        let response = refused(&Maintenance::read_only(Some("back soon".into()))).into_response();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers()[RETRY_AFTER], "30");
        let bytes = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            body["error"]["message"],
            "the hub is in maintenance: back soon"
        );
        assert_eq!(body["error"]["details"]["code"], "maintenance");
        assert_eq!(
            refused(&Maintenance::read_only(None)).0.message,
            "the hub is in maintenance: writes are paused"
        );
        assert!(ApiError::not_ready()
            .into_response()
            .headers()
            .get(RETRY_AFTER)
            .is_none());
    }
}
