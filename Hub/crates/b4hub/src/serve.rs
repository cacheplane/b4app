//! The HTTP server: router, shared state, and graceful shutdown.

use std::future::{Future, IntoFuture};
use std::sync::Arc;
use std::time::Duration;

use axum::routing::{delete, get, post};
use axum::Router;
use b4hub_db::Db;
use tokio::net::TcpListener;
use tokio::sync::{oneshot, watch};
use url::Url;

use crate::auth::LastTouched;
use crate::error::ApiError;
use crate::notify::Notifier;
use crate::relay::{link, Relay};
use crate::routes::{changes, devices, enroll, health, pairing, snapshot};

/// How long the listener stays open, answering `/readyz` 503, after shutdown begins, so a load
/// balancer polling readiness stops routing here before connections are refused. Capped at a
/// quarter of the shutdown wait.
const READINESS_GRACE_MAX: Duration = Duration::from_millis(500);

/// How often `serve` prunes every org's change log.
pub const PRUNE_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// Everything a handler needs. Cheap to clone.
#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub shutdown: Shutdown,
    /// When each device last had `last_seen_at` written (throttle: once a minute).
    pub last_touched: LastTouched,
    /// Wakes long-polling pulls when a push commits (single replica in M8a).
    pub notifier: Notifier,
    /// `B4HUB_PUBLIC_URL`: the URL clients reach the hub at, handed to a phone with a pairing code.
    pub public_url: Option<Url>,
    /// The device links: who is online, and the means to reach them.
    pub relay: Relay,
}

impl AppState {
    pub fn new(db: Db) -> AppState {
        AppState {
            db,
            shutdown: Shutdown::default(),
            last_touched: LastTouched::default(),
            notifier: Notifier::default(),
            public_url: None,
            relay: Relay::new(),
        }
    }
}

/// A one-way "the hub is shutting down" flag. `/readyz` reads it; open long-polls subscribe so
/// they can return their current page instead of waiting out their timeout.
#[derive(Clone, Debug)]
pub struct Shutdown(Arc<watch::Sender<bool>>);

impl Default for Shutdown {
    fn default() -> Shutdown {
        Shutdown(Arc::new(watch::channel(false).0))
    }
}

impl Shutdown {
    pub fn trigger(&self) {
        self.0.send_replace(true);
    }

    pub fn is_triggered(&self) -> bool {
        *self.0.borrow()
    }

    pub fn subscribe(&self) -> watch::Receiver<bool> {
        self.0.subscribe()
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health::healthz))
        .route("/readyz", get(health::readyz))
        .route("/v1/enroll", post(enroll::enroll))
        .route("/v1/pairing-codes", post(pairing::create))
        .route("/v1/changes", changes::route())
        .route("/v1/me", get(devices::me))
        .route("/v1/devices", get(devices::list))
        .route("/v1/snapshot", get(snapshot::get))
        .route("/v1/devices/self", delete(devices::revoke_self))
        .route("/v1/devices/self/link", get(link::upgrade))
        .method_not_allowed_fallback(|| async { ApiError::method_not_allowed() })
        .fallback(|| async { ApiError::not_found() })
        .with_state(state)
}

/// Serves `router(state)` on `listener` until `signal` resolves, then shuts down: `/readyz`
/// turns 503 `shutting_down` and waiters are told, the listener stays open for a short readiness
/// grace and then closes, and in-flight requests drain. The whole sequence is bounded by `wait`
/// from the moment the signal arrives; whatever is still open then is dropped.
pub async fn run(
    listener: TcpListener,
    state: AppState,
    wait: Duration,
    signal: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    let grace = (wait / 4).min(READINESS_GRACE_MAX);
    let shutdown = state.shutdown.clone();
    let (signalled_tx, signalled_rx) = oneshot::channel::<()>();

    let relay = state.relay.clone();
    let server = axum::serve(listener, router(state))
        .with_graceful_shutdown(async move {
            signal.await;
            shutdown.trigger();
            let _ = signalled_tx.send(());
            tokio::time::sleep(grace).await;
        })
        .into_future();
    // An upgraded connection is no longer the server's: its link task is, so the drain also
    // waits for the links, which close themselves (code 1001) as soon as shutdown begins.
    let server = async move {
        let served = server.await;
        relay.drained().await;
        served
    };
    let deadline = async move {
        match signalled_rx.await {
            Ok(()) => tokio::time::sleep(wait).await,
            Err(_) => std::future::pending().await,
        }
    };

    tokio::select! {
        result = server => result,
        () = deadline => {
            tracing::warn!(wait_ms = wait.as_millis() as u64, "shutdown deadline reached; dropping open connections");
            Ok(())
        }
    }
}

/// Resolves on SIGTERM or SIGINT.
pub async fn os_signal() {
    use tokio::signal::unix::{signal, SignalKind};

    let terminate = async {
        match signal(SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(error) => {
                tracing::error!(%error, "cannot install the SIGTERM handler");
                std::future::pending::<()>().await;
            }
        }
    };
    let interrupt = async {
        if let Err(error) = tokio::signal::ctrl_c().await {
            tracing::error!(%error, "cannot install the SIGINT handler");
            std::future::pending::<()>().await;
        }
    };
    tokio::select! {
        () = terminate => tracing::info!("SIGTERM received"),
        () = interrupt => tracing::info!("SIGINT received"),
    }
}

/// Prunes every org's change log of what is older than `retention`, immediately and then every
/// `interval`, until `shutdown`. Each org is pruned in its own transaction (which takes that
/// org's push lock for just that long), a failure is logged and the next org still runs, and
/// shutdown ends the wait between passes and abandons a prune in flight (its transaction rolls
/// back), so the task never holds up the drain.
pub async fn prune_loop(db: Db, retention: Duration, interval: Duration, shutdown: Shutdown) {
    let mut stopping = shutdown.subscribe();
    loop {
        match b4hub_db::orgs::list(&db).await {
            Ok(orgs) => {
                for (org_id, slug) in orgs {
                    let pruned = tokio::select! {
                        pruned = b4hub_db::prune::prune(&db, org_id, retention) => pruned,
                        _ = stopping.wait_for(|down| *down) => return,
                    };
                    if let Err(error) = pruned {
                        tracing::error!(org = %slug, %error, "pruning the change log failed");
                    }
                }
            }
            Err(error) => tracing::error!(%error, "listing orgs to prune failed"),
        }
        tokio::select! {
            () = tokio::time::sleep(interval) => {}
            _ = stopping.wait_for(|down| *down) => return,
        }
    }
}
