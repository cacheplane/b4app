//! `GET /v1/snapshot`: the user's state for a reader whose pull cursor was pruned away.

use axum::extract::State;
use axum::Json;
use b4hub_core::change::Snapshot;
use b4hub_db::snapshot;

use crate::auth::AuthedDevice;
use crate::error::ApiError;
use crate::protocol::SyncProtocol;
use crate::serve::AppState;

pub async fn get(
    State(state): State<AppState>,
    device: AuthedDevice,
    SyncProtocol(protocol): SyncProtocol,
) -> Result<Json<Snapshot>, ApiError> {
    Ok(Json(
        snapshot::take_for_protocol(&state.db, &device, protocol).await?,
    ))
}
