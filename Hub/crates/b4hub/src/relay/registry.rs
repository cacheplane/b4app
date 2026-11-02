//! The live links, by device. [`Relay`] is cheap to clone and lives in `AppState`; the link tasks,
//! the revoke route, and (later) the command router all go through it.
//!
//! One link per device: [`Relay::register`] replaces an older link of the same device and tells it
//! to close. A link is addressed by device id; its `generation` tells the task that registered it
//! whether it is still the current one when it comes to clean up.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime};

use b4hub_core::relay::{HostPresence, RelayMessage, Role, LINK_QUEUE, WATCH_MAX};
use b4hub_db::relay::host_devices;
use b4hub_db::Db;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;
use uuid::Uuid;

use super::limits::SlidingWindow;
use super::route::Commands;
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
    /// The link's outbound queue holds [`LINK_QUEUE`] frames (for [`Relay::send_wait`]: and kept
    /// holding them for the whole wait).
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
    /// What a full queue made the link miss; see [`Missed`].
    missed: Arc<Mutex<Missed>>,
}

impl LinkHandle {
    /// Queues `message` for the link without waiting.
    pub fn try_send(&self, message: RelayMessage) -> Result<(), SendError> {
        self.tx.try_send(message).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => SendError::Full,
            mpsc::error::TrySendError::Closed(_) => SendError::Offline,
        })
    }

    /// Queues a live `event` for `thread_id`, or drops it when the queue is full, in which case
    /// the thread is marked as having a gap and the link is sent a `stream_gap` as soon as its
    /// queue has room. Until that `stream_gap` is queued, later events for the thread are dropped
    /// too, so it always reaches the phone after the hole it reports and before anything newer.
    pub fn deliver_event(&self, thread_id: &str, event: RelayMessage) {
        let mut missed = self.missed();
        missed.flush(&self.tx);
        if missed.gaps.contains(thread_id) {
            return;
        }
        if let Err(mpsc::error::TrySendError::Full(_)) = self.tx.try_send(event) {
            missed.gaps.insert(thread_id.to_string());
        }
    }

    /// Queues `presence`, or, when the queue is full, keeps it (replacing any older one it was
    /// keeping) to send once the queue has room. A phone therefore always ends up with the latest
    /// presence, once, and never a stale one after a newer.
    pub fn deliver_presence(&self, presence: RelayMessage) {
        let mut missed = self.missed();
        missed.presence = Some(presence);
        missed.flush(&self.tx);
    }

    /// Sends what a full queue made the link miss, as far as the queue has room. The link task
    /// calls it each time it takes a frame off the queue.
    pub fn flush_missed(&self) {
        self.missed().flush(&self.tx);
    }

    /// Forgets a gap on `thread_id`: nothing is watched there any more.
    fn forget_gap(&self, thread_id: &str) {
        self.missed().gaps.remove(thread_id);
    }

    fn missed(&self) -> MutexGuard<'_, Missed> {
        self.missed
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// What a client's full outbound queue made it miss: the latest `presence`, and the threads whose
/// events were dropped (which each want one `stream_gap`). Frames other than `event` wait for
/// room rather than being dropped; these are the two that the registry cannot await, because the
/// sender is a broadcast or a fan-out. The mutex also orders a `try_send` against a mark: the
/// link task flushes after every frame it takes, so a mark made because the queue was full is
/// always followed by a flush.
#[derive(Debug, Default)]
struct Missed {
    presence: Option<RelayMessage>,
    gaps: BTreeSet<String>,
}

impl Missed {
    fn flush(&mut self, tx: &mpsc::Sender<RelayMessage>) {
        if let Some(presence) = self.presence.take() {
            if let Err(mpsc::error::TrySendError::Full(presence)) = tx.try_send(presence) {
                self.presence = Some(presence);
                return;
            }
        }
        while let Some(thread_id) = self.gaps.first().cloned() {
            let gap = RelayMessage::StreamGap {
                thread_id: thread_id.clone(),
            };
            if tx.try_send(gap).is_err() {
                return;
            }
            self.gaps.remove(&thread_id);
        }
    }
}

/// Why [`Relay::watch`] did not add a watch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchError {
    /// The link already watches [`WATCH_MAX`] other threads.
    Limit,
    /// The link is no longer its device's current one.
    Gone,
}

/// Who watches what: per host, the threads with at least one watching client link.
#[derive(Debug, Default)]
struct Watchers {
    /// host device -> thread -> client devices watching it.
    by_host: HashMap<Uuid, HashMap<String, HashSet<Uuid>>>,
    /// client device -> thread -> the host that owns it. A client's watches belong to its current
    /// link and are dropped with it.
    by_client: HashMap<Uuid, HashMap<String, Uuid>>,
}

impl Watchers {
    fn remove(&mut self, client: Uuid, thread_id: &str) -> bool {
        let Some(watches) = self.by_client.get_mut(&client) else {
            return false;
        };
        let Some(host) = watches.remove(thread_id) else {
            return false;
        };
        if watches.is_empty() {
            self.by_client.remove(&client);
        }
        if let Some(threads) = self.by_host.get_mut(&host) {
            if let Some(clients) = threads.get_mut(thread_id) {
                clients.remove(&client);
                if clients.is_empty() {
                    threads.remove(thread_id);
                }
            }
            if threads.is_empty() {
                self.by_host.remove(&host);
            }
        }
        true
    }

    /// Drops all of `client`'s watches. True if there were any.
    fn remove_all(&mut self, client: Uuid) -> bool {
        let threads: Vec<String> = self
            .by_client
            .get(&client)
            .map(|watches| watches.keys().cloned().collect())
            .unwrap_or_default();
        for thread_id in &threads {
            self.remove(client, thread_id);
        }
        !threads.is_empty()
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

/// A test seam that holds an accepted upgrade just before its link registers, so a test can make
/// something else (a revocation) happen in exactly that window.
#[derive(Debug, Default)]
pub struct RegistrationGate {
    /// Signalled when a link reaches the gate.
    pub reached: tokio::sync::Notify,
    /// The gated link waits for this.
    pub release: tokio::sync::Notify,
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
    gate: Mutex<Option<Arc<RegistrationGate>>>,
    upgrades: SlidingWindow,
    live: watch::Sender<usize>,
    /// Bumped on every registration, so a held command learns its Mac is back.
    registered: watch::Sender<u64>,
    /// The router's in-memory state: commands in flight, held commands, started threads, limits.
    commands: Commands,
    watchers: Mutex<Watchers>,
    /// Bumped whenever any watch is added or removed, so a host's link learns its set may have
    /// changed and sends the whole of it.
    watch_epoch: watch::Sender<u64>,
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
        Relay::with_clock(WallClock::system())
    }

    /// A relay that reads wall time from `clock`. Tests use it to date frames on a paused clock.
    pub fn with_clock(clock: WallClock) -> Relay {
        Relay(Arc::new(Inner {
            links: Mutex::default(),
            next_generation: AtomicU64::new(0),
            min_client_protocol: AtomicU32::new(MIN_CLIENT_PROTOCOL),
            clock,
            gate: Mutex::new(None),
            upgrades: SlidingWindow::upgrades(),
            live: watch::channel(0).0,
            registered: watch::channel(0).0,
            commands: Commands::default(),
            watchers: Mutex::default(),
            watch_epoch: watch::channel(0).0,
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
            missed: Arc::default(),
        };
        let (previous, dropped_watches) = {
            let mut links = self.links();
            let previous = links.insert(
                who.device_id,
                Entry {
                    handle: handle.clone(),
                    closing: Some(closing_tx),
                },
            );
            // The older link's watches end with it; the new link starts with none.
            let dropped = previous.is_some() && self.forget_watches(who.device_id);
            (previous, dropped)
        };
        if dropped_watches {
            self.bump_watches();
        }
        let replaced = previous.is_some();
        self.0.registered.send_modify(|count| *count += 1);
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
        let (current, dropped_watches) = {
            let mut links = self.links();
            match links.get(&device_id) {
                Some(entry) if entry.handle.generation == generation => {
                    links.remove(&device_id);
                    (true, self.forget_watches(device_id))
                }
                _ => (false, false),
            }
        };
        if dropped_watches {
            self.bump_watches();
        }
        current
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

    /// Queues `message` for `device_id`'s current link, waiting up to `bound` for room in its
    /// queue: for frames that must not be dropped (commands and replies). If that link closes
    /// meanwhile and the device has linked again, the newer link gets it. `Offline` when the
    /// device has no link; `Full` when its queue stayed full for `bound`.
    pub async fn send_wait(
        &self,
        device_id: Uuid,
        message: RelayMessage,
        bound: Duration,
    ) -> Result<(), SendError> {
        let until = Instant::now() + bound;
        let mut message = message;
        let mut tried = None;
        loop {
            let handle = self.handle(device_id).ok_or(SendError::Offline)?;
            if tried == Some(handle.generation) {
                return Err(SendError::Offline);
            }
            tried = Some(handle.generation);
            match tokio::time::timeout_at(until, handle.tx.send(message)).await {
                Ok(Ok(())) => return Ok(()),
                // That link is gone; try the device's current one, if it has a newer one.
                Ok(Err(mpsc::error::SendError(back))) => message = back,
                Err(_) => return Err(SendError::Full),
            }
        }
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
    /// is sent it once the queue has room (see [`LinkHandle::deliver_presence`]).
    pub async fn broadcast_presence(&self, db: &Db, org_id: Uuid, user_id: Uuid) {
        let message = match self.presence(db, org_id, user_id).await {
            Ok(message) => message,
            Err(error) => {
                tracing::warn!(%error, "could not read presence");
                return;
            }
        };
        for client in self.presence_subscribers(user_id) {
            client.deliver_presence(message.clone());
        }
    }

    /// Makes `client`'s link watch `thread_id`, owned by the host `host`. Watching a thread it
    /// already watches is fine and counts once. At most [`WATCH_MAX`] threads per link. The link
    /// must still be its device's current one (a watch decided on after the link was replaced is
    /// not added).
    pub fn watch(
        &self,
        client: &LinkHandle,
        host: Uuid,
        thread_id: &str,
    ) -> Result<(), WatchError> {
        {
            let links = self.links();
            match links.get(&client.device_id) {
                Some(entry) if entry.handle.generation == client.generation => {}
                _ => return Err(WatchError::Gone),
            }
            let mut watchers = self.watchers();
            let watches = watchers.by_client.entry(client.device_id).or_default();
            if watches.contains_key(thread_id) {
                return Ok(());
            }
            if watches.len() >= WATCH_MAX {
                return Err(WatchError::Limit);
            }
            watches.insert(thread_id.to_string(), host);
            watchers
                .by_host
                .entry(host)
                .or_default()
                .entry(thread_id.to_string())
                .or_default()
                .insert(client.device_id);
        }
        self.bump_watches();
        Ok(())
    }

    /// Stops `client`'s link watching `thread_id`; a thread it did not watch is ignored.
    pub fn unwatch(&self, client: &LinkHandle, thread_id: &str) {
        client.forget_gap(thread_id);
        let removed = {
            let links = self.links();
            match links.get(&client.device_id) {
                Some(entry) if entry.handle.generation == client.generation => {
                    self.watchers().remove(client.device_id, thread_id)
                }
                _ => false,
            }
        };
        if removed {
            self.bump_watches();
        }
    }

    /// The threads of `host` that some client watches, sorted: what the host is told in `watching`.
    pub fn watched_by(&self, host: Uuid) -> Vec<String> {
        let mut threads: Vec<String> = self
            .watchers()
            .by_host
            .get(&host)
            .map(|threads| threads.keys().cloned().collect())
            .unwrap_or_default();
        threads.sort();
        threads
    }

    /// Sends `event` to every client link watching `thread_id` of `host`. A link whose queue is
    /// full loses it and gets a `stream_gap` later. Returns how many links watch the thread.
    pub fn fan_out(&self, host: Uuid, thread_id: &str, event: &RelayMessage) -> usize {
        let watching: Vec<Uuid> = self
            .watchers()
            .by_host
            .get(&host)
            .and_then(|threads| threads.get(thread_id))
            .map(|clients| clients.iter().copied().collect())
            .unwrap_or_default();
        for client in &watching {
            if let Some(handle) = self.handle(*client) {
                handle.deliver_event(thread_id, event.clone());
            }
        }
        watching.len()
    }

    /// A receiver that changes whenever a watch is added or removed (from the moment of this call
    /// on); the host's link recomputes [`Relay::watched_by`] when it does.
    pub(super) fn watch_changes(&self) -> watch::Receiver<u64> {
        self.0.watch_epoch.subscribe()
    }

    /// Drops all of `device_id`'s watches, if it is a client with any. Call with the `links` lock
    /// held, which is what keeps this atomic with a link replacing or leaving.
    fn forget_watches(&self, device_id: Uuid) -> bool {
        self.watchers().remove_all(device_id)
    }

    fn bump_watches(&self) {
        self.0.watch_epoch.send_modify(|count| *count += 1);
    }

    fn watchers(&self) -> MutexGuard<'_, Watchers> {
        self.0
            .watchers
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Installs a gate that every upgraded link passes through just before it registers, and
    /// returns it. A test seam; nothing in the hub installs one.
    pub fn gate_registration(&self) -> Arc<RegistrationGate> {
        let gate = Arc::new(RegistrationGate::default());
        *self
            .0
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(Arc::clone(&gate));
        gate
    }

    /// Waits at the registration gate, if one is installed.
    pub(super) async fn pass_gate(&self) {
        let gate = self
            .0
            .gate
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        if let Some(gate) = gate {
            gate.reached.notify_one();
            gate.release.notified().await;
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

    /// A receiver that changes whenever a link registers (from the moment of this call on).
    pub(super) fn registrations(&self) -> watch::Receiver<u64> {
        self.0.registered.subscribe()
    }

    /// The router's state.
    pub(super) fn commands(&self) -> &Commands {
        &self.0.commands
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

    #[tokio::test(start_paused = true)]
    async fn send_wait_waits_for_room_and_gives_up_after_its_bound() {
        let relay = Relay::new();
        let device = Uuid::from_u128(1);
        let bound = Duration::from_secs(5);
        assert_eq!(
            relay.send_wait(device, RelayMessage::Ping, bound).await,
            Err(SendError::Offline)
        );
        let mut link = relay.register(identity(1, Role::Client));
        for _ in 0..LINK_QUEUE {
            relay.send(device, RelayMessage::Ping).unwrap();
        }
        // A slot frees after 2 s: the frame waits for it rather than being dropped.
        let waiting = tokio::spawn({
            let relay = relay.clone();
            async move { relay.send_wait(device, RelayMessage::Ping, bound).await }
        });
        tokio::time::sleep(Duration::from_secs(2)).await;
        link.outbound.recv().await.unwrap();
        assert_eq!(waiting.await.unwrap(), Ok(()));
        // A queue that stays full for the bound is `Full`.
        let started = Instant::now();
        assert_eq!(
            relay.send_wait(device, RelayMessage::Ping, bound).await,
            Err(SendError::Full)
        );
        assert_eq!(started.elapsed(), bound);
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

    fn event(thread: &str) -> RelayMessage {
        RelayMessage::Event {
            event: serde_json::json!({ "threadId": thread }),
        }
    }

    #[test]
    fn a_full_queue_drops_events_and_reports_one_gap_when_there_is_room() {
        let relay = Relay::new();
        let mut link = relay.register(identity(2, Role::Client));
        for _ in 0..LINK_QUEUE {
            link.handle.deliver_event("t1", event("t1"));
        }
        // Full: these are dropped, and the thread is marked once, not once per event.
        link.handle.deliver_event("t1", event("t1"));
        link.handle.deliver_event("t1", event("t1"));
        link.handle.deliver_event("t2", event("t2"));
        // No room yet, so nothing more is queued.
        link.handle.flush_missed();
        assert!(link.handle.try_send(RelayMessage::Ping).is_err());

        // Room appears: the gaps take it, once each, in order, behind what was already queued.
        link.outbound.try_recv().unwrap();
        link.outbound.try_recv().unwrap();
        link.handle.flush_missed();
        let mut rest = Vec::new();
        while let Ok(frame) = link.outbound.try_recv() {
            rest.push(frame);
        }
        let gaps: Vec<&RelayMessage> = rest
            .iter()
            .filter(|frame| matches!(frame, RelayMessage::StreamGap { .. }))
            .collect();
        assert_eq!(
            gaps,
            [
                &RelayMessage::StreamGap {
                    thread_id: "t1".into()
                },
                &RelayMessage::StreamGap {
                    thread_id: "t2".into()
                }
            ]
        );
        assert_eq!(
            rest.len(),
            LINK_QUEUE,
            "the two gaps replaced the two frames read"
        );
        // Live again.
        link.handle.deliver_event("t1", event("t1"));
        assert_eq!(link.outbound.try_recv().unwrap(), event("t1"));
        assert!(link.outbound.try_recv().is_err());
    }

    #[test]
    fn presence_that_does_not_fit_is_kept_latest_only() {
        let relay = Relay::new();
        let mut link = relay.register(identity(2, Role::Client));
        for _ in 0..LINK_QUEUE {
            link.handle.try_send(RelayMessage::Ping).unwrap();
        }
        let presence = |online| RelayMessage::Presence {
            hosts: vec![HostPresence {
                device_id: Uuid::from_u128(1),
                name: "Mac".into(),
                online,
                last_seen_at: None,
            }],
        };
        link.handle.deliver_presence(presence(false));
        link.handle.deliver_presence(presence(true));
        link.outbound.try_recv().unwrap();
        link.handle.flush_missed();
        let mut frames = Vec::new();
        while let Ok(frame) = link.outbound.try_recv() {
            frames.push(frame);
        }
        assert_eq!(frames.last(), Some(&presence(true)));
        assert_eq!(
            frames
                .iter()
                .filter(|frame| matches!(frame, RelayMessage::Presence { .. }))
                .count(),
            1
        );
    }

    #[test]
    fn watches_are_limited_per_link_and_end_with_the_link() {
        let relay = Relay::new();
        let host = Uuid::from_u128(1);
        let old = relay.register(identity(2, Role::Client)).handle;
        for n in 0..WATCH_MAX {
            relay.watch(&old, host, &format!("t{n}")).unwrap();
        }
        assert_eq!(relay.watch(&old, host, "t9"), Err(WatchError::Limit));
        // A thread it already watches is not a new one.
        relay.watch(&old, host, "t0").unwrap();
        assert_eq!(relay.watched_by(host), ["t0", "t1", "t2", "t3"]);

        // A newer link of the device starts with none, and the old link can no longer add.
        let new = relay.register(identity(2, Role::Client)).handle;
        assert!(relay.watched_by(host).is_empty());
        assert_eq!(relay.watch(&old, host, "t0"), Err(WatchError::Gone));
        relay.watch(&new, host, "t0").unwrap();
        // The old link cleaning up leaves the new link's watch alone; the new one leaving ends it.
        assert!(!relay.unregister(old.device_id, old.generation));
        assert_eq!(relay.watched_by(host), ["t0"]);
        assert!(relay.unregister(new.device_id, new.generation));
        assert!(relay.watched_by(host).is_empty());
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
