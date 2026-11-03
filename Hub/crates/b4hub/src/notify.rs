//! Wakes long-polling pulls when a push lands. One `Notify` per org. The instance that took the
//! push wakes its own pulls at once; the others hear of it over `LISTEN` / `NOTIFY`
//! (`b4hub_db::wakes`, [`listen_loop`]), since a device's pulls may reach any instance.
//!
//! A long-poll must not miss a push that commits between its query and its wait. The caller
//! therefore takes the future from [`Notifier::notified`] *before* it queries: a `Notified`
//! created before a `notify_waiters` call completes when that call happens, whether or not it
//! has been polled yet, so a push after the query (or between the query and the first poll)
//! still wakes the wait, and a push before the query is already visible to it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use std::time::Duration;

use b4hub_db::wakes::{Listener, Wake};
use b4hub_db::Db;
use tokio::sync::futures::OwnedNotified;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::serve::Shutdown;

/// How long [`listen_loop`] waits before trying again after the database refused it.
const RETRY: Duration = Duration::from_secs(1);

#[derive(Clone, Debug, Default)]
pub struct Notifier(Arc<Mutex<HashMap<Uuid, Arc<Notify>>>>);

impl Notifier {
    /// A future that completes the next time [`Notifier::wake`] is called for `org` after this
    /// call returns.
    pub fn notified(&self, org: Uuid) -> OwnedNotified {
        let mut map = self.lock();
        Arc::clone(map.entry(org).or_default()).notified_owned()
    }

    /// Completes every future taken for `org` so far. Call it after the push has committed.
    pub fn wake(&self, org: Uuid) {
        // No entry means no future was ever taken for this org, so nobody is waiting; a future
        // taken after this point queries after the commit and sees the push.
        if let Some(notify) = self.lock().get(&org) {
            notify.notify_waiters();
        }
    }

    /// Completes every future taken so far, for every org: for when wake-ups may have been lost.
    pub fn wake_all(&self) {
        for notify in self.lock().values() {
            notify.notify_waiters();
        }
    }

    fn lock(&self) -> MutexGuard<'_, HashMap<Uuid, Arc<Notify>>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// Wakes `notifier`'s pulls for every push another instance announces, until `shutdown`. Its own
/// announcements (`instance`) are skipped: the push route already woke those pulls.
///
/// Whenever the listener is (re)established, every pull is woken, since announcements made while
/// nobody listened are lost; a pull woken for nothing queries once more and answers what it
/// finds. While the database refuses, the loop retries every [`RETRY`].
pub async fn listen_loop(db: Db, notifier: Notifier, instance: Uuid, shutdown: Shutdown) {
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
            Ok(Wake::Org {
                org,
                instance: from,
            }) => {
                if from != instance {
                    notifier.wake(org);
                }
            }
            // sqlx has already listened again on a new connection.
            Ok(Wake::Lost) => {
                tracing::warn!("the change listener reconnected; waking every pull");
                notifier.wake_all();
            }
            Err(error) => {
                tracing::error!(%error, "the change listener failed; retrying");
                listener = None;
                tokio::select! {
                    () = tokio::time::sleep(RETRY) => {}
                    _ = stopping.wait_for(|down| *down) => return,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_future_taken_before_the_wake_completes_even_if_polled_after() {
        let notifier = Notifier::default();
        let org = Uuid::from_u128(1);
        let notified = notifier.notified(org);
        notifier.wake(org);
        tokio::time::timeout(Duration::from_millis(100), notified)
            .await
            .expect("the wake between creation and first poll is not lost");
    }

    #[tokio::test]
    async fn wakes_are_per_org_and_not_remembered() {
        let notifier = Notifier::default();
        let (a, b) = (Uuid::from_u128(1), Uuid::from_u128(2));
        notifier.wake(a); // nobody has waited yet
        let for_a = notifier.notified(a);
        let for_b = notifier.notified(b);
        notifier.wake(b);
        tokio::time::timeout(Duration::from_millis(100), for_b)
            .await
            .expect("b is woken");
        assert!(tokio::time::timeout(Duration::from_millis(50), for_a)
            .await
            .is_err());
    }

    #[tokio::test]
    async fn wake_all_wakes_every_org() {
        let notifier = Notifier::default();
        let for_a = notifier.notified(Uuid::from_u128(1));
        let for_b = notifier.notified(Uuid::from_u128(2));
        notifier.wake_all();
        tokio::time::timeout(Duration::from_millis(100), async {
            for_a.await;
            for_b.await;
        })
        .await
        .expect("both orgs are woken");
    }
}
