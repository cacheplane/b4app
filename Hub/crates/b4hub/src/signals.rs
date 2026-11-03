//! This instance's side of the signals between instances (`b4hub_db::signals`): it wakes the
//! long-polls of an org another instance took a push for (D-161), looks the sessions of a user's
//! links up again when another instance ended one (D-162), and replaces a listener that has gone
//! quiet (D-164). The session check runs here for the change this instance made, and once a minute
//! on every link (`relay::link`), so a missed signal costs a link at most a minute.

use std::time::Duration;

use b4hub_core::relay::Role;
use b4hub_db::devices::authenticate_session;
use b4hub_db::signals::{self, Listener, Signal};
use b4hub_db::Db;
use tokio::time::Instant;
use uuid::Uuid;

use crate::instances::InstancesState;
use crate::notify::Notifier;
use crate::relay::{Close, LinkHandle, Relay};
use crate::serve::{AppState, Shutdown};

/// How long [`listen_loop`] waits before trying again after the database refused it.
const RETRY: Duration = Duration::from_secs(1);

/// Acts on every signal another instance sends, until `shutdown`; its own are skipped, since it
/// acted on them already.
///
/// Whenever the listener is (re)established, every long-poll is woken, since wake-ups sent while
/// nobody listened are lost (a poll woken for nothing queries once more and answers what it
/// finds); after any reconnect, every link here is checked again too. A listener that hears
/// nothing, not even a heartbeat echo, for the liveness window is presumed cut off and replaced
/// (D-164). While the database refuses, the loop retries every [`RETRY`].
pub async fn listen_loop(
    db: Db,
    notifier: Notifier,
    relay: Relay,
    instances: InstancesState,
    shutdown: Shutdown,
) {
    let instance = instances.id();
    let silence = instances.alive_within();
    let mut stopping = shutdown.subscribe();
    let mut listener: Option<Listener> = None;
    let mut heard_at = Instant::now();
    // A reconnect after a failure, rather than the first connect: links get checked again.
    let mut recovering = false;
    loop {
        let listening = match &mut listener {
            Some(listening) => listening,
            None => {
                let connected = tokio::select! {
                    connected = Listener::connect(&db) => connected,
                    _ = stopping.wait_for(|down| *down) => return,
                };
                match connected {
                    Ok(connected) => {
                        heard_at = Instant::now();
                        notifier.wake_all();
                        if std::mem::take(&mut recovering) {
                            recheck_everyone(&relay, &db);
                        }
                        listener.insert(connected)
                    }
                    Err(error) => {
                        tracing::error!(%error, "the signal listener cannot connect; retrying");
                        recovering = true;
                        tokio::select! {
                            () = tokio::time::sleep(RETRY) => {}
                            _ = stopping.wait_for(|down| *down) => return,
                        }
                        continue;
                    }
                }
            }
        };
        let heard = tokio::select! {
            heard = tokio::time::timeout_at(heard_at + silence, listening.next()) => heard,
            _ = stopping.wait_for(|down| *down) => return,
        };
        let signal = match heard {
            // Abandoning the read loses nothing: the connection is dropped with it.
            Err(_) => {
                tracing::warn!(
                    silence_ms = silence.as_millis() as u64,
                    "the signal listener heard nothing, not even an echo; reconnecting"
                );
                listener = None;
                recovering = true;
                continue;
            }
            Ok(Err(error)) => {
                tracing::error!(%error, "the signal listener failed; reconnecting");
                listener = None;
                recovering = true;
                continue;
            }
            Ok(Ok(_)) if instances.deaf() => continue,
            Ok(Ok(signal)) => signal,
        };
        heard_at = Instant::now();
        match signal {
            Signal::Changes {
                org,
                instance: from,
            } => {
                if from != instance {
                    notifier.wake(org);
                }
            }
            Signal::Recheck {
                org,
                user,
                instance: from,
            } => {
                if from != instance {
                    let (relay, db) = (relay.clone(), db.clone());
                    tokio::spawn(async move {
                        let host_closed = recheck_user(&relay, &db, user).await;
                        // A Mac that had no link here leaves its phones' list only if they hear
                        // it; a Mac link that closes tells them itself when it ends.
                        if !host_closed && !relay.links_of(user).is_empty() {
                            relay.broadcast_presence(&db, org, user).await;
                        }
                    });
                }
            }
            Signal::Echo { .. } => {}
            // sqlx has already listened again on a new connection.
            Signal::Lost => {
                tracing::warn!("the signal listener reconnected; waking every pull and link");
                notifier.wake_all();
                recheck_everyone(&relay, &db);
            }
        }
    }
}

/// Checks every link here again, on a task of its own.
fn recheck_everyone(relay: &Relay, db: &Db) {
    let (relay, db) = (relay.clone(), db.clone());
    tokio::spawn(async move {
        for user in relay.users() {
            recheck_user(&relay, &db, user).await;
        }
    });
}

/// After a change that may have ended sessions of `user` (a log-out, a revocation, an account
/// deleted or merged away) has committed: checks the user's links here and asks the other
/// instances to check theirs. A failed request is logged; their links then find out at their
/// next minute's check.
pub async fn sessions_changed(state: &AppState, org: Uuid, user: Uuid) {
    recheck_user(&state.relay, &state.db, user).await;
    if let Err(error) = signals::recheck(&state.db, org, user, state.instances.id()).await {
        tracing::error!(%error, "asking the other instances to check a user's links failed");
    }
}

/// Checks the session of every link of `user` here; true when a Mac's link was closed.
pub async fn recheck_user(relay: &Relay, db: &Db, user: Uuid) -> bool {
    let mut host_closed = false;
    for link in relay.links_of(user) {
        if !check_session(relay, db, &link).await {
            host_closed |= link.role == Role::Host;
        }
    }
    host_closed
}

/// Looks the session `link` was opened with up again and closes the link (`4001`, "session
/// ended") when the token is gone, its device is revoked, or it now names another device or
/// account. False when it closed the link; a database error leaves the link up (true) and is
/// logged.
pub async fn check_session(relay: &Relay, db: &Db, link: &LinkHandle) -> bool {
    let Some(session) = &link.session else {
        return true;
    };
    let alive = match authenticate_session(db, session).await {
        Ok(Some(device)) => {
            device.device_id == link.device_id
                && device.user_id == link.user_id
                && device.org_id == link.org_id
        }
        Ok(None) => false,
        Err(error) => {
            tracing::warn!(%error, device = %link.device_id, "could not check a link's session");
            return true;
        }
    };
    if !alive && relay.close_generation(link.device_id, link.generation, Close::session_ended()) {
        tracing::info!(device = %link.device_id, "closing a link whose session ended");
    }
    alive
}
