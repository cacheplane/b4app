//! `POST /v1/changes` (upload a batch) and `GET /v1/changes` (the long-poll feed).

use std::time::Duration;

use axum::extract::{DefaultBodyLimit, RawQuery, State};
use axum::routing::{post, MethodRouter};
use axum::Json;
use b4hub_core::change::{Change, Page, MAX_PAYLOAD_BYTES, MAX_PULL_LIMIT, MAX_PUSH_CHANGES};
use b4hub_db::changes;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::auth::AuthedDevice;
use crate::error::{ApiError, ApiJson};
use crate::serve::AppState;

/// The longest a pull waits for a change, in seconds, whatever `wait` asks for.
pub const MAX_WAIT_SECS: u64 = 25;

/// The largest push body accepted. A batch of up to [`MAX_PUSH_CHANGES`] changes may carry
/// several values near the 1 MiB the client truncates to; the per-change limit
/// ([`MAX_PAYLOAD_BYTES`]) is what refuses an oversized value, this only bounds what the server
/// will buffer.
pub const MAX_PUSH_BODY_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRequest {
    pub changes: Vec<Change>,
}

/// The `/v1/changes` method router: `POST` pushes (with the larger body limit) and `GET` pulls.
pub fn route() -> MethodRouter<AppState> {
    post(push)
        .layer(DefaultBodyLimit::max(MAX_PUSH_BODY_BYTES))
        .get(pull)
}

async fn push(
    State(state): State<AppState>,
    device: AuthedDevice,
    ApiJson(request): ApiJson<PushRequest>,
) -> Result<Json<Value>, ApiError> {
    if request.changes.len() > MAX_PUSH_CHANGES {
        return Err(ApiError::invalid_request(format!(
            "a push carries at most {MAX_PUSH_CHANGES} changes"
        )));
    }
    // The client truncates large payloads before upload; the hub refuses rather than truncating,
    // and refuses the whole batch before storing any of it.
    if request
        .changes
        .iter()
        .any(|change| change.value_bytes() > MAX_PAYLOAD_BYTES)
    {
        return Err(ApiError::payload_too_large(format!(
            "a change value is larger than {MAX_PAYLOAD_BYTES} bytes"
        )));
    }

    let accepted_through = changes::push(&state.db, &device, &request.changes).await?;
    // After the commit, so a woken pull finds the changes.
    state.notifier.wake(device.org_id);
    Ok(Json(json!({ "acceptedThrough": accepted_through })))
}

/// The query of `GET /v1/changes`. Absent parameters take their defaults; unknown ones are
/// ignored.
struct PullParams {
    after: i64,
    limit: usize,
    wait: Duration,
}

impl PullParams {
    fn parse(query: Option<&str>) -> Result<PullParams, ApiError> {
        let mut params = PullParams {
            after: 0,
            limit: MAX_PULL_LIMIT,
            wait: Duration::ZERO,
        };
        for (name, value) in url::form_urlencoded::parse(query.unwrap_or_default().as_bytes()) {
            match name.as_ref() {
                "after" => params.after = number(&name, &value)?,
                "limit" => {
                    let limit: i64 = number(&name, &value)?;
                    params.limit = usize::try_from(limit).unwrap_or(0).clamp(1, MAX_PULL_LIMIT);
                }
                "wait" => {
                    let seconds: u64 = number(&name, &value)?;
                    params.wait = Duration::from_secs(seconds.min(MAX_WAIT_SECS));
                }
                _ => {}
            }
        }
        Ok(params)
    }
}

fn number<T: std::str::FromStr>(name: &str, value: &str) -> Result<T, ApiError> {
    value
        .parse()
        .map_err(|_| ApiError::invalid_request(format!("{name} must be a whole number")))
}

async fn pull(
    State(state): State<AppState>,
    device: AuthedDevice,
    RawQuery(query): RawQuery,
) -> Result<Json<Page>, ApiError> {
    let params = PullParams::parse(query.as_deref())?;
    if params.after < changes::HORIZON {
        return Err(ApiError::resync_required());
    }

    // Take the wake-up future before the first query: a push that commits after this line either
    // is seen by the query or completes this future, so the wait below cannot sleep through it.
    let notified = state.notifier.notified(device.org_id);
    let mut page = changes::pull(&state.db, &device, params.after, params.limit).await?;
    if page.changes.is_empty() && !params.wait.is_zero() && !state.shutdown.is_triggered() {
        let mut shutdown = state.shutdown.subscribe();
        tokio::select! {
            () = notified => {}
            () = tokio::time::sleep(params.wait) => {}
            // Shutdown: answer with whatever is there now instead of holding the connection.
            _ = shutdown.wait_for(|down| *down) => {}
        }
        page = changes::pull(&state.db, &device, params.after, params.limit).await?;
    }
    Ok(Json(page))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(query: &str) -> Result<PullParams, ApiError> {
        PullParams::parse(Some(query))
    }

    #[test]
    fn defaults_and_clamps() {
        let defaults = PullParams::parse(None).unwrap();
        assert_eq!(
            (defaults.after, defaults.limit, defaults.wait),
            (0, MAX_PULL_LIMIT, Duration::ZERO)
        );
        let params = parse("after=7&limit=5000&wait=999&other=1").unwrap();
        assert_eq!(params.after, 7);
        assert_eq!(params.limit, MAX_PULL_LIMIT);
        assert_eq!(params.wait, Duration::from_secs(MAX_WAIT_SECS));
        assert_eq!(parse("limit=0").unwrap().limit, 1);
        assert_eq!(parse("limit=-3").unwrap().limit, 1);
        assert_eq!(parse("wait=3").unwrap().wait, Duration::from_secs(3));
        assert_eq!(parse("after=-1").unwrap().after, -1);
    }

    #[test]
    fn non_numbers_are_invalid_requests() {
        for query in ["after=x", "limit=", "wait=-1", "wait=1.5"] {
            let error = parse(query).err().unwrap_or_else(|| panic!("{query}"));
            assert_eq!(error.code, "invalid_request", "{query}");
        }
    }
}
