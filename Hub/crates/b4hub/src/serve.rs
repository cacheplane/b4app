//! The HTTP server: router, shared state, and graceful shutdown.

use std::future::{Future, IntoFuture};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::routing::{delete, get, post, put};
use axum::{middleware, Router};
use b4hub_db::Db;
use tokio::net::TcpListener;
use tokio::sync::{oneshot, watch};
use url::Url;
use webauthn_rs::prelude::Webauthn;

use crate::apple::{AppleClient, AppleRevoker, ErasedAppleRevoker, UnconfiguredRevoker};
use crate::auth::LastTouched;
use crate::auth_limits::AuthLimits;
use crate::cli::ConfigError;
use crate::config::Config;
use crate::error::ApiError;
use crate::instances::{self, InstancesState};
use crate::maintenance::MaintenanceState;
use crate::notify::Notifier;
use crate::push::PushSender;
use crate::relay::{link, Relay};
use crate::request_log;
use crate::routes::{
    apple, auth, changes, devices, enroll, health, me, pairing, push_token, snapshot, step_up,
};
use crate::signals;

/// How long the listener stays open, answering `/readyz` 503, after shutdown begins, so a load
/// balancer polling readiness stops routing here before connections are refused. Capped at a
/// quarter of the shutdown wait.
const READINESS_GRACE_MAX: Duration = Duration::from_millis(500);

/// How long the drain waits for held commands to be answered before it closes the links, capped
/// at a quarter of the shutdown wait.
const HOLD_RELEASE_MAX: Duration = Duration::from_secs(1);

/// The part of the shutdown wait kept back for releasing the instance's claims after the drain,
/// capped at an eighth of the wait.
const RELEASE_RESERVE_MAX: Duration = Duration::from_secs(1);

/// How often `serve` prunes every org's change log.
pub const PRUNE_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// Everything a handler needs. Cheap to clone.
#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub shutdown: Shutdown,
    /// When each device last had `last_seen_at` written (throttle: once a minute).
    pub last_touched: LastTouched,
    /// Wakes long-polling pulls when a push commits, here or (over `LISTEN`) on another instance.
    pub notifier: Notifier,
    /// The sign-in configuration `serve` read at start.
    pub config: Arc<Config>,
    /// The WebAuthn relying party built from it.
    pub webauthn: Arc<Webauthn>,
    /// The sign-in routes' per-IP limits (in memory, per process).
    pub limits: AuthLimits,
    /// Sign in with Apple, when `B4HUB_APPLE_*` configures it; without it the Apple routes
    /// answer `not_found`.
    pub apple: Option<Arc<AppleClient>>,
    /// Revokes Apple refresh tokens when an account is deleted: the Apple client, or (without
    /// Apple) [`UnconfiguredRevoker`], which refuses.
    pub apple_revoker: Arc<dyn ErasedAppleRevoker>,
    /// `B4HUB_PUBLIC_URL`: the URL clients reach the hub at, handed to a phone with a pairing code.
    /// [`AppState::new`] copies it from `config`.
    pub public_url: Option<Url>,
    /// The device links: who is online, and the means to reach them.
    pub relay: Relay,
    /// The maintenance switch as last polled (`maintenance::poll_loop`); writes check it.
    pub maintenance: MaintenanceState,
    /// This instance's id and heartbeat health; the link upgrade claims users for it.
    pub instances: InstancesState,
    /// Delivers the alerts and withdrawals a push decides on; `None` sends nothing (the ledger
    /// still records them, so delivery stays at most once).
    pub push: Option<Arc<dyn PushSender>>,
}

impl AppState {
    /// The state for `db` and `config`; a relying party webauthn-rs refuses, or an Apple private
    /// key that does not sign, is a configuration error.
    pub fn new(db: Db, config: Config) -> Result<AppState, ConfigError> {
        let webauthn = config.webauthn()?;
        let apple = config
            .apple
            .as_ref()
            .map(AppleClient::new)
            .transpose()?
            .map(Arc::new);
        let apple_revoker: Arc<dyn ErasedAppleRevoker> = match &apple {
            Some(client) => client.clone(),
            None => Arc::new(UnconfiguredRevoker),
        };
        let public_url = config.public_url.clone();
        Ok(AppState {
            db,
            shutdown: Shutdown::default(),
            last_touched: LastTouched::default(),
            notifier: Notifier::default(),
            config: Arc::new(config),
            webauthn: Arc::new(webauthn),
            limits: AuthLimits::default(),
            apple,
            apple_revoker,
            public_url,
            relay: Relay::new(),
            maintenance: MaintenanceState::default(),
            instances: InstancesState::default(),
            push: None,
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
        .route("/v1/pairing-codes", post(pairing::create))
        .route("/v1/pairing-codes/check", post(pairing::check))
        .route("/v1/changes", changes::route())
        .route("/v1/me", get(me::me).delete(me::delete_me))
        .route("/v1/me/profile", put(me::profile))
        .route("/v1/me/passkeys/begin", post(me::passkey_begin))
        .route("/v1/me/passkeys/finish", post(me::passkey_finish))
        .route("/v1/me/apple", post(apple::link_begin))
        .route("/v1/me/apple/native", post(apple::link_native))
        .route("/v1/me/apple/handoff", post(apple::link_handoff))
        .route("/v1/me/identities/{id}", delete(me::remove_identity))
        .route("/v1/me/step-up/passkey/begin", post(step_up::passkey_begin))
        .route(
            "/v1/me/step-up/passkey/finish",
            post(step_up::passkey_finish),
        )
        .route("/v1/me/step-up/apple", post(apple::step_up_begin))
        .route("/v1/me/step-up/apple/native", post(apple::step_up_native))
        .route("/v1/me/step-up/apple/handoff", post(apple::step_up_handoff))
        .route("/v1/me/step-up/code", post(step_up::code))
        .route("/v1/sessions/self", delete(me::end_session))
        .route("/v1/devices", get(devices::list))
        .route("/v1/snapshot", get(snapshot::get))
        .route("/v1/devices/self", delete(devices::revoke_self))
        .route("/v1/auth/config", get(auth::config))
        .route("/v1/auth/passkey/begin", post(auth::passkey_begin))
        .route("/v1/auth/passkey/finish", post(auth::passkey_finish))
        .route("/v1/auth/apple/begin", post(apple::begin))
        .route("/v1/auth/apple/native", post(apple::native))
        .route("/v1/auth/apple/start", get(apple::start))
        .route("/v1/auth/apple/callback", post(apple::callback))
        .route("/v1/auth/handoff", post(apple::handoff))
        .route("/v1/devices/self/link", get(link::upgrade))
        .route("/v1/devices/self/push-token", post(push_token::save))
        .method_not_allowed_fallback(|| async { ApiError::method_not_allowed() })
        .fallback(|| async { ApiError::not_found() })
        .layer(middleware::from_fn(request_log::trace_request))
        .with_state(state)
}

/// Serves `router(state)` on `listener` (with each connection's peer address, which the sign-in
/// rate limits key on) until `signal` resolves, then shuts down: `/readyz`
/// turns 503 `shutting_down` and waiters are told, the listener stays open for a short readiness
/// grace and then closes, and in-flight requests drain.
///
/// Around that, the instance: it registers before serving and heartbeats while it serves
/// (`instances::heartbeat_loop`, on a connection of its own), and listens for the other
/// instances' signals (`signals::listen_loop`); when the signal arrives, commands held for offline Macs are
/// answered `device_offline` first (so the answers go out before the links close), and once the
/// links are closed the instance releases its claims, so its users are claimed at once by the
/// instance they reconnect to.
///
/// The whole sequence, from the signal to the claims released, is bounded by `wait`: the drain
/// (holds, readiness grace, requests, links) gets `wait` less a reserve for the release (an
/// eighth of `wait`, at most 1 s), whatever is still open then is dropped, and the release gets
/// what is left.
pub async fn run(
    listener: TcpListener,
    state: AppState,
    wait: Duration,
    signal: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    let grace = (wait / 4).min(READINESS_GRACE_MAX);
    let hold_release = (wait / 4).min(HOLD_RELEASE_MAX);
    let shutdown = state.shutdown.clone();
    let (signalled_tx, signalled_rx) = oneshot::channel::<()>();
    let release_reserve = (wait / 8).min(RELEASE_RESERVE_MAX);
    // When the signal arrived, so the release after the drain knows what is left of `wait`.
    let signalled_at = Arc::new(std::sync::Mutex::new(None::<tokio::time::Instant>));

    let public_url = state.public_url.as_ref().map(|url| url.to_string());
    // The heartbeat has a connection of its own: one that queued behind busy requests for the
    // pool's 5 s acquire wait could let a healthy instance read as dead to the others.
    let beat_db = state.db.dedicated();
    instances::register(&beat_db, &state.instances, public_url.as_deref()).await;
    // Aborted however `run` ends, dropped mid-drain included.
    let heartbeat = AbortOnDrop(tokio::spawn(instances::heartbeat_loop(
        beat_db,
        state.instances.clone(),
        state.relay.clone(),
        public_url,
        state.shutdown.clone(),
    )));
    let listening = AbortOnDrop(tokio::spawn(signals::listen_loop(
        state.db.clone(),
        state.notifier.clone(),
        state.relay.clone(),
        state.instances.clone(),
        state.shutdown.clone(),
    )));
    let (db, instance) = (state.db.clone(), state.instances.clone());

    let relay = state.relay.clone();
    let holds = state.relay.clone();
    let marked = Arc::clone(&signalled_at);
    let app = router(state).into_make_service_with_connect_info::<SocketAddr>();
    let server = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            signal.await;
            // The deadline starts now, before anything else the drain does.
            *marked.lock().unwrap_or_else(|p| p.into_inner()) = Some(tokio::time::Instant::now());
            let _ = signalled_tx.send(());
            holds.release_holds(hold_release).await;
            shutdown.trigger();
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
            Ok(()) => tokio::time::sleep(wait - release_reserve).await,
            Err(_) => std::future::pending().await,
        }
    };

    let result = tokio::select! {
        result = server => result,
        () = deadline => {
            tracing::warn!(
                wait_ms = (wait - release_reserve).as_millis() as u64,
                "shutdown deadline reached; dropping open connections"
            );
            Ok(())
        }
    };
    drop(heartbeat);
    drop(listening);
    let left = signalled_at
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .map_or(wait, |at| {
            (at + wait).saturating_duration_since(tokio::time::Instant::now())
        });
    if tokio::time::timeout(left, instances::release(&db, &instance))
        .await
        .is_err()
    {
        tracing::warn!("releasing the instance's claims did not finish within the shutdown wait");
    }
    result
}

/// Aborts its task when dropped.
struct AbortOnDrop(tokio::task::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
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
///
/// Each pass also deletes expired sign-in ceremonies and handoffs, and prunes dead instances and the claims no live instance holds
/// (`b4hub_db::instances::prune`, with the instances' liveness window `alive_within`).
pub async fn prune_loop(
    db: Db,
    retention: Duration,
    alive_within: Duration,
    interval: Duration,
    shutdown: Shutdown,
) {
    let mut stopping = shutdown.subscribe();
    loop {
        match b4hub_db::instances::prune(&db, alive_within).await {
            Ok(pruned) if pruned.instances > 0 || pruned.claims > 0 => {
                tracing::info!(
                    instances = pruned.instances,
                    claims = pruned.claims,
                    "pruned dead instances"
                );
            }
            Ok(_) => {}
            Err(error) => tracing::error!(%error, "pruning dead instances failed"),
        }
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
