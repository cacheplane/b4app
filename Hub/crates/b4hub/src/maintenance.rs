//! Maintenance mode: while the operator has switched it on (`b4hub maintenance on`, a row in
//! `hub_settings`), every instance refuses writes with `503 maintenance` and `Retry-After: 30`
//! while reads and `/readyz` continue. Each `serve` polls the switch at start and then every
//! `Settings::maintenance_poll()`, keeping the last value it read when a poll fails.

use std::sync::{Arc, RwLock};
use std::time::Duration;

use axum::extract::FromRequestParts;
use axum::http::request::Parts;
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

/// The error a write gets while maintenance is on.
pub fn refused(maintenance: &Maintenance) -> ApiError {
    ApiError::maintenance(maintenance.message.as_deref())
}

/// An extractor that refuses the request while maintenance is on. Put it first in a write
/// handler's arguments, so the request is refused before the body is read.
#[derive(Debug, Clone, Copy)]
pub struct WritesAllowed;

impl FromRequestParts<AppState> for WritesAllowed {
    type Rejection = ApiError;

    async fn from_request_parts(
        _parts: &mut Parts,
        state: &AppState,
    ) -> Result<WritesAllowed, ApiError> {
        match state.maintenance.current() {
            Some(maintenance) => Err(refused(&maintenance)),
            None => Ok(WritesAllowed),
        }
    }
}

/// Reads the switch now and then every `interval` until `shutdown`, publishing each value into
/// `state`. A failed read is logged and leaves the last value in place: a database blip must not
/// flip the hub into or out of maintenance.
pub async fn poll_loop(db: Db, state: MaintenanceState, interval: Duration, shutdown: Shutdown) {
    let mut stopping = shutdown.subscribe();
    loop {
        match settings::maintenance(&db).await {
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
        tokio::select! {
            () = tokio::time::sleep(interval) => {}
            _ = stopping.wait_for(|down| *down) => return,
        }
    }
}
