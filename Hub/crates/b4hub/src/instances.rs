//! This instance among the hub's instances (M8e Part B, `b4hub_db::instances`). Every `serve` has
//! an [`InstancesState`]: a UUIDv7 that names it, the heartbeat cadence, and when its heartbeat
//! was last written. `serve::run` registers the instance, runs [`heartbeat_loop`], and releases
//! its claims when it drains; the link upgrade claims the device's user for this instance
//! (`relay::link::upgrade`); `/readyz` reports `"instances": "stale"` once the heartbeat has not
//! been written for the liveness window.
//!
//! The liveness window is [`BEATS_PER_WINDOW`] heartbeats: 20 s at the default 5 s cadence. Every
//! instance of one hub must run the same cadence (`B4HUB_HEARTBEAT_MS`), since each judges the
//! others by its own window.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::http::HeaderValue;
use b4hub_db::Db;
use tokio::time::Instant;
use uuid::Uuid;

use crate::relay::{Close, Relay};
use crate::serve::Shutdown;

/// The default heartbeat cadence.
pub const DEFAULT_HEARTBEAT: Duration = Duration::from_secs(5);

/// How many heartbeats long the liveness window is.
pub const BEATS_PER_WINDOW: u32 = 4;

/// The cookie that names the instance which answered, for the load balancer's application-cookie
/// stickiness.
pub const COOKIE_NAME: &str = "b4hub-instance";

/// How long the instance cookie lives, in seconds (the ALB's stickiness duration matches).
pub const COOKIE_MAX_AGE: u32 = 3600;

struct Inner {
    id: Uuid,
    heartbeat: Duration,
    /// When the instance row was last written successfully (registration counts). Starts at
    /// construction, so an instance that never manages a write turns stale one window later.
    last_ok: Mutex<Instant>,
    /// A test seam: while set, the heartbeat loop writes nothing, as if the database refused it.
    paused: AtomicBool,
    /// Held by the heartbeat loop from its pause check until its write is recorded, so
    /// [`InstancesState::settle`] can wait out a write that was already on its way.
    beat: tokio::sync::Mutex<()>,
}

/// This instance's identity and heartbeat health. Cheap to clone.
#[derive(Clone)]
pub struct InstancesState(Arc<Inner>);

impl std::fmt::Debug for InstancesState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InstancesState")
            .field("id", &self.0.id)
            .finish_non_exhaustive()
    }
}

impl Default for InstancesState {
    fn default() -> InstancesState {
        InstancesState::new(DEFAULT_HEARTBEAT)
    }
}

impl InstancesState {
    /// A new instance (a fresh UUIDv7) that heartbeats every `heartbeat`.
    pub fn new(heartbeat: Duration) -> InstancesState {
        InstancesState(Arc::new(Inner {
            id: Uuid::now_v7(),
            heartbeat,
            last_ok: Mutex::new(Instant::now()),
            paused: AtomicBool::new(false),
            beat: tokio::sync::Mutex::new(()),
        }))
    }

    pub fn id(&self) -> Uuid {
        self.0.id
    }

    pub fn heartbeat(&self) -> Duration {
        self.0.heartbeat
    }

    /// How recent another instance's heartbeat must be for it to count as alive, and how long this
    /// instance may go without a successful write before it reports itself stale.
    pub fn alive_within(&self) -> Duration {
        self.0.heartbeat * BEATS_PER_WINDOW
    }

    /// Records a successful write of the instance row.
    pub fn record_ok(&self) {
        *self
            .0
            .last_ok
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Instant::now();
    }

    /// True when the instance row has not been written for longer than the liveness window: the
    /// other instances already count this one as dead and may take its users.
    pub fn stale(&self) -> bool {
        self.0
            .last_ok
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .elapsed()
            > self.alive_within()
    }

    /// Stops (or resumes) the heartbeat writes. A test seam; nothing in the hub calls it.
    pub fn pause_heartbeat(&self, paused: bool) {
        self.0.paused.store(paused, Ordering::SeqCst);
    }

    /// Returns once no heartbeat write is in progress. After `pause_heartbeat(true)` and this, the
    /// last successful write is in the past and no other lands, so staleness depends on the clock
    /// alone. A test seam; nothing in the hub calls it.
    pub async fn settle(&self) {
        drop(self.0.beat.lock().await);
    }

    fn paused(&self) -> bool {
        self.0.paused.load(Ordering::SeqCst)
    }

    /// `Set-Cookie: b4hub-instance=<id>; Path=/; Max-Age=3600; Secure; HttpOnly`, which the load
    /// balancer turns into stickiness to the target that sent it.
    pub fn cookie(&self) -> HeaderValue {
        let value = format!(
            "{COOKIE_NAME}={}; Path=/; Max-Age={COOKIE_MAX_AGE}; Secure; HttpOnly",
            self.0.id
        );
        HeaderValue::from_str(&value).expect("a UUID cookie is a valid header value")
    }
}

/// Registers the instance, recording the write when it succeeds; a failure is logged and the
/// heartbeat loop keeps trying.
pub async fn register(db: &Db, instances: &InstancesState, public_url: Option<&str>) {
    match b4hub_db::instances::register(db, instances.id(), public_url).await {
        Ok(()) => {
            instances.record_ok();
            tracing::info!(instance = %instances.id(), "instance registered");
        }
        Err(error) => tracing::warn!(%error, "could not register the instance"),
    }
}

/// Writes the heartbeat every `instances.heartbeat()` until `shutdown`. A row the prune removed is
/// registered again. After each successful write, the links of any user whose claim another
/// instance now holds (it took over while this instance's heartbeat was failing) are closed, so
/// one user's links are never split between instances for longer than a heartbeat.
pub async fn heartbeat_loop(
    db: Db,
    instances: InstancesState,
    relay: Relay,
    public_url: Option<String>,
    shutdown: Shutdown,
) {
    let mut stopping = shutdown.subscribe();
    loop {
        tokio::select! {
            () = tokio::time::sleep(instances.heartbeat()) => {}
            _ = stopping.wait_for(|down| *down) => return,
        }
        let beat = instances.0.beat.lock().await;
        if instances.paused() {
            continue;
        }
        match b4hub_db::instances::heartbeat(&db, instances.id()).await {
            Ok(true) => instances.record_ok(),
            Ok(false) => register(&db, &instances, public_url.as_deref()).await,
            Err(error) => {
                tracing::warn!(%error, "could not write the instance heartbeat");
                continue;
            }
        }
        drop(beat);
        let users = relay.users();
        match b4hub_db::instances::lost_claims(&db, instances.id(), &users).await {
            Ok(lost) => {
                for user in lost {
                    let closed = relay.close_user(user, Close::relocated());
                    tracing::warn!(
                        user = %user,
                        links = closed,
                        "another instance serves this user now; closing its links here"
                    );
                }
            }
            Err(error) => tracing::warn!(%error, "could not check this instance's claims"),
        }
    }
}

/// Deletes this instance's claims and its row, once its links are closed, so its users are
/// claimed at once by the instance they reconnect to.
pub async fn release(db: &Db, instances: &InstancesState) {
    match b4hub_db::instances::release_claims(db, instances.id()).await {
        Ok(released) => {
            tracing::info!(instance = %instances.id(), released, "instance claims released");
        }
        Err(error) => tracing::warn!(%error, "could not release the instance's claims"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cookie_names_the_instance() {
        let instances = InstancesState::default();
        assert_eq!(instances.id().get_version_num(), 7);
        assert_eq!(
            instances.cookie().to_str().unwrap(),
            format!(
                "b4hub-instance={}; Path=/; Max-Age=3600; Secure; HttpOnly",
                instances.id()
            )
        );
        assert_eq!(instances.alive_within(), Duration::from_secs(20));
    }

    #[tokio::test(start_paused = true)]
    async fn an_instance_turns_stale_a_window_after_its_last_write() {
        let instances = InstancesState::new(Duration::from_secs(5));
        assert!(!instances.stale());
        tokio::time::advance(Duration::from_secs(19)).await;
        instances.record_ok();
        tokio::time::advance(Duration::from_secs(20)).await;
        assert!(!instances.stale());
        tokio::time::advance(Duration::from_millis(1)).await;
        assert!(instances.stale());
    }
}
