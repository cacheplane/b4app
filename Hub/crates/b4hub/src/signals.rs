//! This instance's side of the signals between instances (`b4hub_db::signals`): it wakes the
//! long-polls of an org another instance took a push for, and looks the sessions of a user's
//! links up again when another instance ended one (D-161, D-162). The same check runs here for
//! the change this instance made, and once a minute on every link (`relay::link`), so a missed
//! signal costs a link at most a minute.

use std::time::Duration;

use b4hub_core::relay::Role;
use b4hub_db::devices::authenticate_session;
use b4hub_db::signals::{self, Listener, Signal};
use b4hub_db::Db;
use uuid::Uuid;

use crate::notify::Notifier;
use crate::relay::{Close, LinkHandle, Relay};
use crate::serve::{AppState, Shutdown};

/// How long [`listen_loop`] waits before trying again after the database refused it.
const RETRY: Duration = Duration::from_secs(1);

/// Acts on every signal another instance sends, until `shutdown`; its own (`instance`) are
/// skipped, since it acted on them already.
///
/// Whenever the listener is (re)established, every long-poll is woken, since wake-ups sent while
/// nobody listened are lost (a poll woken for nothing queries once more and answers what it
/// finds); after a dropped connection every link here is checked again too. While the database
/// refuses, the loop retries every [`RETRY`].
pub async fn listen_loop(
    db: Db,
    notifier: Notifier,
    relay: Relay,
    instance: Uuid,
    shutdown: Shutdown,
) {
    let mut stopping = shutdown.subscribe();
    let mut listener: Option<Listener> = None;
    loop {
        let heard = async {
            let listening = match &mut listener {
                Some(listening) => listening,
                None => {
                    let listening = listener.insert(Listener::connect(&db).await?);
                    notifier.wake_all();
                    listening
                }
            };
            listening.next().await
        };
        let heard = tokio::select! {
            heard = heard => heard,
            _ = stopping.wait_for(|down| *down) => return,
        };
        match heard {
            Ok(Signal::Changes {
                org,
                instance: from,
            }) => {
                if from != instance {
                    notifier.wake(org);
                }
            }
            Ok(Signal::Recheck {
                org,
                user,
                instance: from,
            }) => {
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
            // sqlx has already listened again on a new connection.
            Ok(Signal::Lost) => {
                tracing::warn!("the signal listener reconnected; waking every pull and link");
                notifier.wake_all();
                let (relay, db) = (relay.clone(), db.clone());
                tokio::spawn(async move {
                    for user in relay.users() {
                        recheck_user(&relay, &db, user).await;
                    }
                });
            }
            Err(error) => {
                tracing::error!(%error, "the signal listener failed; retrying");
                listener = None;
                tokio::select! {
                    () = tokio::time::sleep(RETRY) => {}
                    _ = stopping.wait_for(|down| *down) => return,
                }
            }
        }
    }
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
