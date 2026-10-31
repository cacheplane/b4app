//! The HTTP server: router, shared state, and graceful shutdown.

use std::future::{Future, IntoFuture};
use std::sync::Arc;
use std::time::Duration;

use axum::routing::get;
use axum::Router;
use b4hub_db::Db;
use tokio::net::TcpListener;
use tokio::sync::{oneshot, watch};

use crate::error::ApiError;
use crate::routes::health;

/// How long the listener stays open, answering `/readyz` 503, after shutdown begins, so a load
/// balancer polling readiness stops routing here before connections are refused. Capped at a
/// quarter of the shutdown wait.
const READINESS_GRACE_MAX: Duration = Duration::from_millis(500);

/// Everything a handler needs. Cheap to clone.
#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub shutdown: Shutdown,
    // Task 4 adds the change-feed `Notify` here.
}

impl AppState {
    pub fn new(db: Db) -> AppState {
        AppState {
            db,
            shutdown: Shutdown::default(),
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

    let server = axum::serve(listener, router(state))
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
