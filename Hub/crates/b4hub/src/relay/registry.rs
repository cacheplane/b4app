//! The live links, by device. [`Relay`] is cheap to clone and lives in `AppState`; the link tasks,
//! the revoke route, and (later) the command router all go through it.
//!
//! One link per device: [`Relay::register`] replaces an older link of the same device and tells it
//! to close. A link is addressed by device id; its `generation` tells the task that registered it
//! whether it is still the current one when it comes to clean up.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime};

use b4hub_core::relay::{HostPresence, RelayMessage, Role, LINK_QUEUE};
use b4hub_db::relay::host_devices;
use b4hub_db::Db;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;
use uuid::Uuid;

use super::limits::SlidingWindow;
use super::{close_code, link_replaced, WallClock, MIN_CLIENT_PROTOCOL};
use crate::error::relay_code;

/// Why a link is being closed and what it is told first.
#[derive(Debug, Clone, PartialEq)]
pub struct Close {
    pub code: u16,
    pub reason: &'static str,
    /// An `error` frame written before the close, if any.
    pub error: Option<RelayMessage>,
}

impl Close {
    /// A newer link from the same device took over.
    pub fn replaced() -> Close {
        Close {
            code: close_code::REPLACED,
            reason: "replaced by a newer link",
            error: Some(link_replaced()),
        }
    }

    /// The device was revoked.
    pub fn revoked() -> Close {
        Close {
            code: close_code::REVOKED,
            reason: "device revoked",
            error: None,
        }
    }

    /// The hub is shutting down.
    pub fn shutdown() -> Close {
        Close {
            code: close_code::SHUTDOWN,
            reason: "hub shutting down",
            error: None,
        }
    }

    /// The link sent nothing for `DEAD_LINK`.
    pub fn silent() -> Close {
        Close {
            code: close_code::SILENT,
            reason: "no frame for 30 seconds",
            error: None,
        }
    }

    /// The device's protocol is older than `min_client_protocol`.
    pub fn client_too_old(min_client_protocol: u32) -> Close {
        Close {
            code: close_code::CLIENT_TOO_OLD,
            reason: "client too old",
            error: Some(RelayMessage::Error {
                code: relay_code::CLIENT_TOO_OLD.to_string(),
                message: "this app is too old to use the hub; update it".to_string(),
                details: Some(serde_json::json!({ "minClientProtocol": min_client_protocol })),
            }),
        }
    }
}

/// Why [`Relay::send`] did not queue a frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendError {
    /// The device has no link.
    Offline,
    /// The link's outbound queue holds [`LINK_QUEUE`] frames.
    Full,
}

/// What other tasks may know about a link: who it is and how to queue a frame to it. Cheap to
/// clone; the link task owns the socket.
#[derive(Debug, Clone)]
pub struct LinkHandle {
    pub device_id: Uuid,
    /// The device's name, stamped on a command as `from.name`.
    pub name: String,
    /// Which registration of this device this is; larger is newer.
    pub generation: u64,
    pub role: Role,
    pub user_id: Uuid,
    pub org_id: Uuid,
    tx: mpsc::Sender<RelayMessage>,
}

impl LinkHandle {
    /// Queues `message` for the link without waiting.
    pub fn try_send(&self, message: RelayMessage) -> Result<(), SendError> {
        self.tx.try_send(message).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => SendError::Full,
            mpsc::error::TrySendError::Closed(_) => SendError::Offline,
        })
    }
}

/// Who is opening a link.
#[derive(Debug, Clone)]
pub struct Identity {
    pub device_id: Uuid,
    pub name: String,
    pub role: Role,
    pub user_id: Uuid,
    pub org_id: Uuid,
}

/// What the task that serves a link gets back from [`Relay::register`].
#[derive(Debug)]
pub struct Registration {
    pub handle: LinkHandle,
    /// The frames other tasks queued for this link, in order.
    pub outbound: mpsc::Receiver<RelayMessage>,
    /// Resolves when something asks this link to close.
    pub closing: oneshot::Receiver<Close>,
    /// True when this link replaced an older one of the same device.
    pub replaced: bool,
}

/// Counts a link as live until dropped; see [`Relay::track`].
#[derive(Debug)]
pub struct LiveLink(Relay);

impl Drop for LiveLink {
    fn drop(&mut self) {
        self.0 .0.live.send_modify(|count| *count -= 1);
    }
}

struct Entry {
    handle: LinkHandle,
    closing: Option<oneshot::Sender<Close>>,
}

struct Inner {
    links: Mutex<HashMap<Uuid, Entry>>,
    next_generation: AtomicU64,
    min_client_protocol: AtomicU32,
    clock: WallClock,
    upgrades: SlidingWindow,
    live: watch::Sender<usize>,
}

/// The registry of live links and the relay-wide settings. Cheap to clone.
#[derive(Clone)]
pub struct Relay(Arc<Inner>);

impl std::fmt::Debug for Relay {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Relay").finish_non_exhaustive()
    }
}

impl Default for Relay {
    fn default() -> Relay {
        Relay::new()
    }
}

impl Relay {
    pub fn new() -> Relay {
        Relay(Arc::new(Inner {
            links: Mutex::default(),
            next_generation: AtomicU64::new(0),
            min_client_protocol: AtomicU32::new(MIN_CLIENT_PROTOCOL),
            clock: WallClock::new(),
            upgrades: SlidingWindow::upgrades(),
            live: watch::channel(0).0,
        }))
    }

    /// Registers a new link for `who`, replacing and closing any older link of the same device.
    pub fn register(&self, who: Identity) -> Registration {
        let (tx, outbound) = mpsc::channel(LINK_QUEUE);
        let (closing_tx, closing) = oneshot::channel();
        let handle = LinkHandle {
            device_id: who.device_id,
            name: who.name,
            generation: self.0.next_generation.fetch_add(1, Ordering::Relaxed) + 1,
            role: who.role,
            user_id: who.user_id,
            org_id: who.org_id,
            tx,
        };
        let previous = self.links().insert(
            who.device_id,
            Entry {
                handle: handle.clone(),
                closing: Some(closing_tx),
            },
        );
        let replaced = previous.is_some();
        if let Some(older) = previous.and_then(|entry| entry.closing) {
            // The older task may already be gone; then there is nobody to tell.
            let _ = older.send(Close::replaced());
        }
        Registration {
            handle,
            outbound,
            closing,
            replaced,
        }
    }

    /// Counts one link as live until the returned guard is dropped, so shutdown can wait for it
    /// ([`Relay::drained`]). Take it when the upgrade is accepted, before the link task has even
    /// started, so a link accepted just before shutdown is not missed.
    pub fn track(&self) -> LiveLink {
        self.0.live.send_modify(|count| *count += 1);
        LiveLink(self.clone())
    }

    /// Removes the link `generation` of `device_id`. True when it was the current link, which
    /// means the device just went offline; false when a newer link has since replaced it.
    pub fn unregister(&self, device_id: Uuid, generation: u64) -> bool {
        let mut links = self.links();
        match links.get(&device_id) {
            Some(entry) if entry.handle.generation == generation => {
                links.remove(&device_id);
                true
            }
            _ => false,
        }
    }

    /// Asks the current link of `device_id` to close with `close`. True when there was one. The
    /// link stays registered (and online) until its task unregisters it.
    pub fn close(&self, device_id: Uuid, close: Close) -> bool {
        let mut links = self.links();
        let Some(entry) = links.get_mut(&device_id) else {
            return false;
        };
        if let Some(closing) = entry.closing.take() {
            let _ = closing.send(close);
        }
        true
    }

    /// Whether `device_id` has a link.
    pub fn online(&self, device_id: Uuid) -> bool {
        self.links().contains_key(&device_id)
    }

    /// The current link of `device_id`.
    pub fn handle(&self, device_id: Uuid) -> Option<LinkHandle> {
        self.links()
            .get(&device_id)
            .map(|entry| entry.handle.clone())
    }

    /// Queues `message` for `device_id`'s link without waiting.
    pub fn send(&self, device_id: Uuid, message: RelayMessage) -> Result<(), SendError> {
        self.handle(device_id)
            .ok_or(SendError::Offline)?
            .try_send(message)
    }

    /// The client links of `user_id`: who is told when one of the user's Macs goes on or offline.
    /// A scan of every link, which is fine for the handful a hub carries.
    pub fn presence_subscribers(&self, user_id: Uuid) -> Vec<LinkHandle> {
        self.links()
            .values()
            .filter(|entry| entry.handle.role == Role::Client && entry.handle.user_id == user_id)
            .map(|entry| entry.handle.clone())
            .collect()
    }

    /// The `presence` frame for `user_id`: every non-revoked Mac of the user, whether it has a
    /// link, and when it was last heard from. `online` is read after the database answers, so
    /// two changes racing each other cannot leave a stale flag behind the later one.
    pub async fn presence(
        &self,
        db: &Db,
        org_id: Uuid,
        user_id: Uuid,
    ) -> Result<RelayMessage, b4hub_db::Error> {
        let hosts = host_devices(db, org_id, user_id).await?;
        Ok(RelayMessage::Presence {
            hosts: hosts
                .into_iter()
                .map(|(device_id, name, last_seen_at)| HostPresence {
                    device_id,
                    name,
                    online: self.online(device_id),
                    last_seen_at,
                })
                .collect(),
        })
    }

    /// Tells every client link of `user_id` the current presence. A client whose queue is full
    /// misses it; it is rebuilt from scratch on that client's next link.
    pub async fn broadcast_presence(&self, db: &Db, org_id: Uuid, user_id: Uuid) {
        let message = match self.presence(db, org_id, user_id).await {
            Ok(message) => message,
            Err(error) => {
                tracing::warn!(%error, "could not read presence");
                return;
            }
        };
        for client in self.presence_subscribers(user_id) {
            let _ = client.try_send(message.clone());
        }
    }

    /// The oldest client protocol the hub serves.
    pub fn min_client_protocol(&self) -> u32 {
        self.0.min_client_protocol.load(Ordering::Relaxed)
    }

    /// Raises or lowers the oldest client protocol served. A test seam: the hub has one protocol,
    /// so nothing else changes it.
    pub fn set_min_client_protocol(&self, protocol: u32) {
        self.0
            .min_client_protocol
            .store(protocol, Ordering::Relaxed);
    }

    /// Counts one link upgrade attempt by `device_id`. `Err` is how long until it may try again.
    pub fn check_upgrade(&self, device_id: Uuid) -> Result<(), Duration> {
        self.0.upgrades.hit(device_id, Instant::now())
    }

    /// The hub's wall-clock time at `at` (see the module docs of `relay` for how it is kept).
    pub fn wall(&self, at: Instant) -> SystemTime {
        self.0.clock.at(at)
    }

    /// The hub's wall-clock time now.
    pub fn wall_now(&self) -> SystemTime {
        self.0.clock.now()
    }

    /// `hubTime` for a frame sent now.
    pub fn hub_time(&self) -> String {
        super::rfc3339_millis(self.wall_now())
    }

    /// Resolves once no link is live: every link has been closed and has finished its cleanup.
    /// Shutdown waits on this inside its bounded drain.
    pub async fn drained(&self) {
        let mut live = self.0.live.subscribe();
        // `wait_for` only fails if the sender is gone, and this `Relay` holds it.
        let _ = live.wait_for(|count| *count == 0).await;
    }

    fn links(&self) -> MutexGuard<'_, HashMap<Uuid, Entry>> {
        self.0
            .links
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(device: u128, role: Role) -> Identity {
        Identity {
            device_id: Uuid::from_u128(device),
            name: format!("device {device}"),
            role,
            user_id: Uuid::from_u128(1000),
            org_id: Uuid::from_u128(2000),
        }
    }

    #[test]
    fn a_new_link_replaces_and_closes_the_old_one() {
        let relay = Relay::new();
        let mut first = relay.register(identity(1, Role::Host));
        assert!(!first.replaced);
        let second = relay.register(identity(1, Role::Host));
        assert!(second.replaced);
        assert!(second.handle.generation > first.handle.generation);
        assert_eq!(first.closing.try_recv().unwrap(), Close::replaced());
        assert!(relay.online(Uuid::from_u128(1)));
        // The old link cleaning up must not take the new one offline.
        assert!(!relay.unregister(Uuid::from_u128(1), first.handle.generation));
        assert!(relay.online(Uuid::from_u128(1)));
        assert!(relay.unregister(Uuid::from_u128(1), second.handle.generation));
        assert!(!relay.online(Uuid::from_u128(1)));
    }

    #[test]
    fn send_queues_in_order_and_reports_a_full_queue_and_an_offline_device() {
        let relay = Relay::new();
        let device = Uuid::from_u128(1);
        assert_eq!(
            relay.send(device, RelayMessage::Ping),
            Err(SendError::Offline)
        );
        let mut link = relay.register(identity(1, Role::Client));
        for _ in 0..LINK_QUEUE {
            relay.send(device, RelayMessage::Ping).unwrap();
        }
        assert_eq!(relay.send(device, RelayMessage::Ping), Err(SendError::Full));
        assert_eq!(link.outbound.try_recv().unwrap(), RelayMessage::Ping);
        relay.send(device, RelayMessage::Ping).unwrap();
    }

    #[test]
    fn close_signals_once_and_keeps_the_link_registered() {
        let relay = Relay::new();
        let mut link = relay.register(identity(1, Role::Host));
        assert!(relay.close(Uuid::from_u128(1), Close::revoked()));
        assert_eq!(link.closing.try_recv().unwrap(), Close::revoked());
        assert!(relay.online(Uuid::from_u128(1)));
        assert!(!relay.close(Uuid::from_u128(9), Close::revoked()));
    }

    #[test]
    fn presence_subscribers_are_the_users_client_links_only() {
        let relay = Relay::new();
        let _mac = relay.register(identity(1, Role::Host));
        let _phone = relay.register(identity(2, Role::Client));
        let mut stranger = identity(3, Role::Client);
        stranger.user_id = Uuid::from_u128(1001);
        let _other = relay.register(stranger);
        let subscribers = relay.presence_subscribers(Uuid::from_u128(1000));
        assert_eq!(subscribers.len(), 1);
        assert_eq!(subscribers[0].device_id, Uuid::from_u128(2));
    }

    #[tokio::test]
    async fn drained_waits_for_every_live_link() {
        let relay = Relay::new();
        let link = relay.track();
        let waiting = tokio::spawn({
            let relay = relay.clone();
            async move { relay.drained().await }
        });
        tokio::task::yield_now().await;
        assert!(!waiting.is_finished());
        drop(link);
        tokio::time::timeout(Duration::from_secs(1), waiting)
            .await
            .expect("drained resolves once the link is dropped")
            .unwrap();
    }
}
