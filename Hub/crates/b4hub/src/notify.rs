//! Wakes long-polling pulls when a push lands. One `Notify` per org; the hub runs a single
//! replica in M8a, so an in-process signal is enough (a second replica would need `LISTEN` /
//! `NOTIFY` or the same signal over the database).
//!
//! A long-poll must not miss a push that commits between its query and its wait. The caller
//! therefore takes the future from [`Notifier::notified`] *before* it queries: a `Notified`
//! created before a `notify_waiters` call completes when that call happens, whether or not it
//! has been polled yet, so a push after the query (or between the query and the first poll)
//! still wakes the wait, and a push before the query is already visible to it.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

use tokio::sync::futures::OwnedNotified;
use tokio::sync::Notify;
use uuid::Uuid;

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

    fn lock(&self) -> MutexGuard<'_, HashMap<Uuid, Arc<Notify>>> {
        self.0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

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
}
