//! The HTTP server: router, shared state, and graceful shutdown.

use std::future::{Future, IntoFuture};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::routing::{delete, get, post, put};
use axum::Router;
use b4hub_db::Db;
use tokio::net::TcpListener;
use tokio::sync::{oneshot, watch};
use webauthn_rs::prelude::Webauthn;

use crate::apple::{AppleRevoker, ErasedAppleRevoker, NoopRevoker};
use crate::auth::LastTouched;
use crate::auth_limits::AuthLimits;
use crate::cli::ConfigError;
use crate::config::Config;
use crate::error::ApiError;
use crate::notify::Notifier;
use crate::routes::{auth, changes, devices, enroll, health, me, snapshot};

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
    /// The sign-in configuration `serve` read at start.
    pub config: Arc<Config>,
    /// The WebAuthn relying party built from it.
    pub webauthn: Arc<Webauthn>,
    /// The sign-in routes' per-IP limits (in memory, per process).
    pub limits: AuthLimits,
    /// Revokes Apple refresh tokens when an account is deleted ([`NoopRevoker`] until Sign in
    /// with Apple is built).
    pub apple_revoker: Arc<dyn ErasedAppleRevoker>,
}

impl AppState {
    /// The state for `db` and `config`; a relying party webauthn-rs refuses is a configuration
    /// error.
    pub fn new(db: Db, config: Config) -> Result<AppState, ConfigError> {
        let webauthn = config.webauthn()?;
        Ok(AppState {
            db,
            shutdown: Shutdown::default(),
            last_touched: LastTouched::default(),
            notifier: Notifier::default(),
            config: Arc::new(config),
            webauthn: Arc::new(webauthn),
            limits: AuthLimits::default(),
            apple_revoker: Arc::new(NoopRevoker),
        })
    }

    /// This state with `revoker` revoking Apple refresh tokens.
    pub fn with_apple_revoker(mut self, revoker: impl AppleRevoker) -> AppState {
        self.apple_revoker = Arc::new(revoker);
        self
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
        .route("/v1/changes", changes::route())
        .route("/v1/me", get(me::me).delete(me::delete_me))
        .route("/v1/me/profile", put(me::profile))
        .route("/v1/me/passkeys/begin", post(me::passkey_begin))
        .route("/v1/me/passkeys/finish", post(me::passkey_finish))
        .route("/v1/me/identities/{id}", delete(me::remove_identity))
        .route("/v1/sessions/self", delete(me::end_session))
        .route("/v1/devices", get(devices::list))
        .route("/v1/snapshot", get(snapshot::get))
        .route("/v1/devices/self", delete(devices::revoke_self))
        .route("/v1/auth/config", get(auth::config))
        .route("/v1/auth/passkey/begin", post(auth::passkey_begin))
        .route("/v1/auth/passkey/finish", post(auth::passkey_finish))
        .method_not_allowed_fallback(|| async { ApiError::method_not_allowed() })
        .fallback(|| async { ApiError::not_found() })
        .with_state(state)
}

/// Serves `router(state)` on `listener` (with each connection's peer address, which the sign-in
/// rate limits key on) until `signal` resolves, then shuts down: `/readyz`
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

    let app = router(state).into_make_service_with_connect_info::<SocketAddr>();
    let server = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            signal.await;
            shutdown.trigger();
            let _ = signalled_tx.send(());
            tokio::time::sleep(grace).await;
        })
        .into_future();
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
/// `interval`, until `shutdown`; each pass also deletes expired sign-in ceremonies and handoffs.
/// Each org is pruned in its own transaction (which takes that org's push lock for just that
/// long), a failure is logged and the next org still runs, and shutdown ends the wait between
/// passes and abandons a prune in flight (its transaction rolls back), so the task never holds up
/// the drain.
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
        let pruned = tokio::select! {
            pruned = b4hub_db::ceremonies::prune_expired(&db) => pruned,
            _ = stopping.wait_for(|down| *down) => return,
        };
        if let Err(error) = pruned {
            tracing::error!(%error, "pruning expired sign-in ceremonies failed");
        }
        tokio::select! {
            () = tokio::time::sleep(interval) => {}
            _ = stopping.wait_for(|down| *down) => return,
        }
    }
}
