//! `POST /v1/changes` (upload a batch) and `GET /v1/changes` (the long-poll feed).

use std::future::Future;
use std::time::Duration;

use axum::extract::{DefaultBodyLimit, RawQuery, State};
use axum::routing::{post, MethodRouter};
use axum::Json;
use b4hub_core::change::{Change, Page, MAX_PAYLOAD_BYTES, MAX_PULL_LIMIT, MAX_PUSH_CHANGES};
use b4hub_db::changes;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::auth::AuthedDevice;
use crate::error::{ApiError, ApiJson};
use crate::notify::Notifier;
use crate::serve::{AppState, Shutdown};

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

/// Runs `query` and, when it returns an empty page and `wait` is not zero, waits for a push to
/// the org (or `wait`, or shutdown) and runs `query` once more.
///
/// The wake-up future is taken *before* the first query, which is what closes the lost-wakeup
/// gap: a push that commits after that point either is seen by the query or completes the
/// future, so the wait cannot sleep through it. Keep that order: the unit test
/// `a_push_during_the_first_query_is_not_slept_through` fails if it changes.
async fn long_poll<F, Fut, E>(
    notifier: &Notifier,
    org: Uuid,
    wait: Duration,
    shutdown: &Shutdown,
    mut query: F,
) -> Result<Page, E>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<Page, E>>,
{
    let notified = notifier.notified(org);
    let page = query().await?;
    if !page.changes.is_empty() || wait.is_zero() || shutdown.is_triggered() {
        return Ok(page);
    }
    let mut stopping = shutdown.subscribe();
    tokio::select! {
        () = notified => {}
        () = tokio::time::sleep(wait) => {}
        // Shutdown: answer with whatever is there now instead of holding the connection.
        _ = stopping.wait_for(|down| *down) => {}
    }
    query().await
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

    let page = long_poll(
        &state.notifier,
        device.org_id,
        params.wait,
        &state.shutdown,
        || changes::pull(&state.db, &device, params.after, params.limit),
    )
    .await?;
    Ok(Json(page))
}

#[cfg(test)]
mod tests {
    use std::convert::Infallible;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Instant;

    use b4hub_core::change::{ChangeOp, StoredChange};

    use super::*;

    const WAIT: Duration = Duration::from_secs(5);

    fn empty() -> Page {
        Page {
            changes: vec![],
            next: 0,
            more: false,
        }
    }

    fn one_change() -> Page {
        Page {
            changes: vec![StoredChange {
                hub_seq: 1,
                device_id: Uuid::from_u128(1),
                device_seq: 1,
                wall: 0,
                table: "connections".into(),
                row_id: "c".into(),
                op: ChangeOp::Delete,
                column: None,
                value: None,
            }],
            next: 1,
            more: false,
        }
    }

    /// A push that commits while the first query is running, after the query has read its
    /// (empty) snapshot: the query wakes the org and still returns an empty page. With the
    /// wake-up future taken before the query, the wait ends at once and the second query sees the
    /// push; taken after, the wake is lost and the poll sleeps the whole `WAIT`.
    #[tokio::test]
    async fn a_push_during_the_first_query_is_not_slept_through() {
        let (notifier, shutdown, org) =
            (Notifier::default(), Shutdown::default(), Uuid::from_u128(7));
        let calls = AtomicUsize::new(0);
        let started = Instant::now();
        let page = long_poll(&notifier, org, WAIT, &shutdown, || {
            let call = calls.fetch_add(1, Ordering::SeqCst);
            let notifier = &notifier;
            async move {
                Ok::<_, Infallible>(if call == 0 {
                    notifier.wake(org); // the push commits after the query's snapshot
                    empty()
                } else {
                    one_change()
                })
            }
        })
        .await
        .unwrap();
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "{:?}",
            started.elapsed()
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(page.changes.len(), 1);
    }

    #[tokio::test]
    async fn a_page_with_changes_or_no_wait_returns_without_waiting() {
        let (notifier, shutdown, org) =
            (Notifier::default(), Shutdown::default(), Uuid::from_u128(7));
        let calls = AtomicUsize::new(0);
        let page = long_poll(&notifier, org, WAIT, &shutdown, || {
            calls.fetch_add(1, Ordering::SeqCst);
            async { Ok::<_, Infallible>(one_change()) }
        })
        .await
        .unwrap();
        assert_eq!((page.changes.len(), calls.load(Ordering::SeqCst)), (1, 1));

        let page = long_poll(&notifier, org, Duration::ZERO, &shutdown, || {
            calls.fetch_add(1, Ordering::SeqCst);
            async { Ok::<_, Infallible>(empty()) }
        })
        .await
        .unwrap();
        assert_eq!((page.changes.len(), calls.load(Ordering::SeqCst)), (0, 2));
    }

    #[tokio::test]
    async fn an_empty_poll_waits_out_the_timeout_then_queries_once_more() {
        let (notifier, shutdown, org) =
            (Notifier::default(), Shutdown::default(), Uuid::from_u128(7));
        let calls = AtomicUsize::new(0);
        let started = Instant::now();
        let page = long_poll(
            &notifier,
            org,
            Duration::from_millis(100),
            &shutdown,
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                async { Ok::<_, Infallible>(empty()) }
            },
        )
        .await
        .unwrap();
        assert!(page.changes.is_empty());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(started.elapsed() >= Duration::from_millis(90));
    }

    #[tokio::test]
    async fn shutdown_ends_the_wait() {
        let (notifier, shutdown, org) =
            (Notifier::default(), Shutdown::default(), Uuid::from_u128(7));
        let stopper = shutdown.clone();
        let started = Instant::now();
        let poll = long_poll(&notifier, org, WAIT, &shutdown, || async {
            Ok::<_, Infallible>(empty())
        });
        let stop = async {
            tokio::time::sleep(Duration::from_millis(100)).await;
            stopper.trigger();
        };
        let (page, ()) = tokio::join!(poll, stop);
        assert!(page.unwrap().changes.is_empty());
        assert!(started.elapsed() < Duration::from_secs(1));
    }

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
