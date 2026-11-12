//! The live links, by device. [`Relay`] is cheap to clone and lives in `AppState`; the link tasks,
//! the revoke route, and (later) the command router all go through it.
//!
//! One link per device: [`Relay::register_admitted`] replaces an older link of the same device and tells it
//! to close. A link is addressed by device id; its `generation` tells the task that registered it
//! whether it is still the current one when it comes to clean up.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime};

use b4hub_core::protocol::{ClientProtocol, ProtocolFloor};
use b4hub_core::relay::{HostPresence, RelayMessage, Role, LINK_QUEUE, WATCH_MAX};
use b4hub_db::devices::SessionKey;
use b4hub_db::relay::{host_devices, Admission};
use b4hub_db::Db;
use std::ops::{Deref, DerefMut};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::Instant;
use uuid::Uuid;

use super::limits::{SlidingWindow, COMMANDS_IN_FLIGHT};
use super::route::Commands;
use super::{close_code, link_replaced, WallClock, MIN_CLIENT_PROTOCOL};
use crate::error::relay_code;

/// Why a link is being closed and what it is told first.
#[derive(Debug, Clone, PartialEq)]
pub struct Close {
    pub(super) disposition: CloseDisposition,
    pub code: u16,
    pub reason: &'static str,
    /// An `error` frame written before the close, if any.
    pub error: Option<RelayMessage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum CloseDisposition {
    Drain,
    Terminal,
    Fence,
}

impl Close {
    /// A newer link from the same device took over.
    pub fn replaced() -> Close {
        Close {
            disposition: CloseDisposition::Fence,
            code: close_code::REPLACED,
            reason: "replaced by a newer link",
            error: Some(link_replaced()),
        }
    }

    /// The device was revoked.
    pub fn revoked() -> Close {
        Close {
            disposition: CloseDisposition::Terminal,
            code: close_code::REVOKED,
            reason: "device revoked",
            error: None,
        }
    }

    /// The token that opened the link was deleted (log-out, account deletion) or now names
    /// another device or account: the same code as a revocation, since reconnecting with that
    /// token cannot help.
    pub fn session_ended() -> Close {
        Close {
            disposition: CloseDisposition::Terminal,
            code: close_code::REVOKED,
            reason: "session ended",
            error: None,
        }
    }

    /// The hub is shutting down.
    pub fn shutdown() -> Close {
        Close {
            disposition: CloseDisposition::Drain,
            code: close_code::SHUTDOWN,
            reason: "hub shutting down",
            error: None,
        }
    }

    /// Another instance took over the user's links (this instance's heartbeat had stalled). The
    /// device reconnects and reaches the owner. Code 1001, like shutdown: reconnect with backoff.
    pub fn relocated() -> Close {
        Close {
            disposition: CloseDisposition::Terminal,
            code: close_code::SHUTDOWN,
            reason: "served by another hub instance",
            error: None,
        }
    }

    /// The link sent nothing for `DEAD_LINK`.
    pub fn silent() -> Close {
        Close {
            disposition: CloseDisposition::Terminal,
            code: close_code::SILENT,
            reason: "no frame for 30 seconds",
            error: None,
        }
    }

    pub(crate) fn protocol_unavailable() -> Close {
        Close {
            disposition: CloseDisposition::Fence,
            code: close_code::SHUTDOWN,
            reason: "relay admission unavailable",
            error: Some(super::error_frame(
                "internal_error",
                "the relay is unavailable",
            )),
        }
    }
    pub(super) fn protocol_not_activated() -> Close {
        Close {
            disposition: CloseDisposition::Fence,
            code: close_code::SHUTDOWN,
            reason: "protocol not activated",
            error: Some(super::error_frame(
                "protocol_not_activated",
                "protocol 2 is not activated on this Hub",
            )),
        }
    }
    /// The device's protocol is older than `min_client_protocol`.
    pub fn client_too_old(min_client_protocol: u32) -> Close {
        Close {
            disposition: CloseDisposition::Fence,
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

/// A frame on a link's outbound queue.
#[derive(Debug, Clone, PartialEq)]
pub enum Outbound {
    /// A frame the link task encodes when it writes it.
    Message(RelayMessage),
    /// A live `event`, encoded once by [`Relay::fan_out`] for every link watching its thread. Its
    /// bytes count toward the link's [`EVENT_BYTES_MAX`] until the link task has written it.
    Event(Arc<str>),
    /// Production frames retain compatibility facts only, never a DB lease or wire extension.
    Protected(Envelope),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Stamp {
    pub generation: u64,
    pub required: u32,
}
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Payload {
    Message(RelayMessage),
    Event(Arc<str>),
}
#[derive(Debug)]
pub struct Envelope {
    stamp: Stamp,
    payload: Payload,
    event_bytes: Option<Arc<AtomicUsize>>,
}
impl Envelope {
    fn message(message: RelayMessage, stamp: Stamp) -> Self {
        Self {
            stamp,
            payload: Payload::Message(message),
            event_bytes: None,
        }
    }
    fn event(text: Arc<str>, stamp: Stamp, bytes: Arc<AtomicUsize>) -> Self {
        Self {
            stamp,
            payload: Payload::Event(text),
            event_bytes: Some(bytes),
        }
    }
    pub(super) fn parts(&self) -> (Stamp, &Payload) {
        (self.stamp, &self.payload)
    }
    pub(super) fn compatible(&self, generation: u64, floor: u32) -> bool {
        self.stamp.generation == generation && self.stamp.required >= floor
    }
    pub(super) fn check_for_write(
        &self,
        generation: u64,
        floor: u32,
    ) -> Result<(), super::admission::Failure> {
        if self.compatible(generation, floor) {
            Ok(())
        } else {
            Err(super::admission::Failure::Unavailable)
        }
    }
}
impl Clone for Envelope {
    fn clone(&self) -> Self {
        if let (Some(bytes), Payload::Event(text)) = (&self.event_bytes, &self.payload) {
            bytes.fetch_add(text.len(), Ordering::SeqCst);
        }
        Self {
            stamp: self.stamp,
            payload: self.payload.clone(),
            event_bytes: self.event_bytes.clone(),
        }
    }
}
impl PartialEq for Envelope {
    fn eq(&self, other: &Self) -> bool {
        self.stamp == other.stamp && self.payload == other.payload
    }
}
impl Drop for Envelope {
    fn drop(&mut self) {
        if let (Some(bytes), Payload::Event(text)) = (&self.event_bytes, &self.payload) {
            bytes.fetch_sub(text.len(), Ordering::SeqCst);
        }
    }
}

impl Outbound {
    /// The frame as a message (an encoded event decoded again); `None` for an encoded event that
    /// does not decode, which `fan_out` never queues.
    pub fn message(&self) -> Option<RelayMessage> {
        match self {
            Outbound::Message(message) => Some(message.clone()),
            Outbound::Event(text) => serde_json::from_str(text).ok(),
            Outbound::Protected(frame) => match &frame.payload {
                Payload::Message(message) => Some(message.clone()),
                Payload::Event(text) => serde_json::from_str(text).ok(),
            },
        }
    }
}

/// The most bytes of encoded live events one link may have waiting in its queue. Past it, events
/// for a thread are dropped and the thread gets a `stream_gap`, as when the queue is full, so a
/// phone that stops reading holds a few MiB rather than [`LINK_QUEUE`] events of up to 256 KiB.
pub const EVENT_BYTES_MAX: usize = 4 * 1024 * 1024;

/// How long a Mac whose link dropped on its own still reads online in `presence` (D-193): long
/// enough for a Mac on a network change, a short sleep, or a hub deploy to link again (its first
/// retries come within about 7 s), so its phones never see it flicker offline.
pub const OFFLINE_GRACE: Duration = Duration::from_secs(10);

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
    /// The session the link was opened with, looked up again to find out whether it still holds;
    /// `None` for the readiness probe.
    pub session: Option<SessionKey>,
    pub client_protocol: ClientProtocol,
    /// The local floor observation epoch under which registration was inserted.
    pub cut_generation: u64,
    admitted: bool,
    probe: bool,
    #[cfg(test)]
    synthetic_model: bool,
    tx: mpsc::Sender<Outbound>,
    /// What a full queue made the link miss; see [`Missed`].
    missed: Arc<Mutex<Missed>>,
    /// Bytes of encoded events queued and not yet written ([`EVENT_BYTES_MAX`]).
    event_bytes: Arc<AtomicUsize>,
}

impl LinkHandle {
    /// This registration was admitted. This historical fact alone is never fresh action/write
    /// authority; the dependent producer conversion must acquire its own native admission.
    pub fn is_admitted(&self) -> bool {
        self.admitted
    }
    pub(super) fn is_probe(&self) -> bool {
        self.probe
    }
    fn synthetic_model(&self) -> bool {
        #[cfg(test)]
        {
            self.synthetic_model
        }
        #[cfg(not(test))]
        {
            false
        }
    }
    /// Queues `message` for the link without waiting.
    pub fn try_send(&self, message: RelayMessage) -> Result<(), SendError> {
        if !self.synthetic_model() {
            return Err(SendError::Offline);
        }
        self.tx
            .try_send(Outbound::Message(message))
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => SendError::Full,
                mpsc::error::TrySendError::Closed(_) => SendError::Offline,
            })
    }

    /// Queues a live `event` (encoded) for `thread_id`, or drops it when the queue is full or
    /// would hold more than [`EVENT_BYTES_MAX`] of events, in which case the thread is marked as
    /// having a gap and the link is sent a `stream_gap` as soon as its queue has room. Until that
    /// `stream_gap` is queued, later events for the thread are dropped too, so it always reaches
    /// the phone after the hole it reports and before anything newer.
    pub fn deliver_event(&self, thread_id: &str, event: Arc<str>) {
        if self.synthetic_model() {
            self.deliver_event_inner(thread_id, event, None);
        }
    }
    pub(super) fn deliver_event_checked(
        &self,
        thread_id: &str,
        event: Arc<str>,
        proof: &super::admission::Proof<'_>,
    ) {
        if let Some(stamp) = proof.stamp_for(self) {
            self.deliver_event_inner(thread_id, event, Some(stamp));
        }
    }
    fn deliver_event_inner(&self, thread_id: &str, event: Arc<str>, stamp: Option<Stamp>) {
        let mut missed = self.missed();
        missed.flush(&self.tx);
        if missed.gaps.contains_key(thread_id) {
            return;
        }
        let len = event.len();
        let queued = self.event_bytes.fetch_add(len, Ordering::SeqCst);
        let frame = match stamp {
            Some(stamp) => {
                Outbound::Protected(Envelope::event(event, stamp, Arc::clone(&self.event_bytes)))
            }
            None => Outbound::Event(event),
        };
        let dropped = if queued + len > EVENT_BYTES_MAX {
            drop(frame);
            Some("bytes")
        } else {
            match self.tx.try_send(frame) {
                Ok(()) => None,
                Err(mpsc::error::TrySendError::Full(_)) => Some("frames"),
                Err(mpsc::error::TrySendError::Closed(_)) => Some("closed"),
            }
        };
        if let Some(full) = dropped {
            // Protected events release their own bytes on every drop, including a closed receiver.
            if stamp.is_none() {
                self.event_bytes.fetch_sub(len, Ordering::SeqCst);
            }
            if full != "closed" && missed.gaps.insert(thread_id.to_string(), stamp).is_none() {
                tracing::info!(device=%self.device_id,full,"dropping live events: queue full");
            }
        }
    }

    /// The link task wrote an encoded event of `len` bytes: room for more.
    pub fn event_written(&self, len: usize) {
        self.event_bytes.fetch_sub(len, Ordering::SeqCst);
    }

    /// Queues `presence`, or, when the queue is full, keeps it (replacing any older one it was
    /// keeping) to send once the queue has room. A phone therefore always ends up with the latest
    /// presence, once, and never a stale one after a newer.
    pub fn deliver_presence(&self, presence: RelayMessage) {
        if !self.synthetic_model() {
            return;
        }
        let mut missed = self.missed();
        missed.presence = Some(Outbound::Message(presence));
        missed.flush(&self.tx);
    }
    pub(super) fn deliver_presence_checked(
        &self,
        presence: RelayMessage,
        proof: &super::admission::Proof<'_>,
    ) {
        if let Some(stamp) = proof.stamp_for(self) {
            let mut missed = self.missed();
            missed.presence = Some(Outbound::Protected(Envelope::message(presence, stamp)));
            missed.flush(&self.tx);
        }
    }
    fn queue_stamped(&self, message: RelayMessage, stamp: Stamp) -> Result<(), SendError> {
        self.tx
            .try_send(Outbound::Protected(Envelope::message(message, stamp)))
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => SendError::Full,
                mpsc::error::TrySendError::Closed(_) => SendError::Offline,
            })
    }
    pub(super) fn clear_missed(&self) {
        let mut missed = self.missed();
        missed.presence = None;
        missed.gaps.clear();
    }
    pub(super) fn discard_pending(&self, outbound: &mut mpsc::Receiver<Outbound>) {
        outbound.close();
        while outbound.try_recv().is_ok() {}
        self.clear_missed();
    }

    /// Sends what a full queue made the link miss, as far as the queue has room. The link task
    /// calls it each time it takes a frame off the queue.
    pub fn flush_missed(&self) {
        if !self.admitted {
            return;
        }
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
    presence: Option<Outbound>,
    gaps: BTreeMap<String, Option<Stamp>>,
}

impl Missed {
    fn flush(&mut self, tx: &mpsc::Sender<Outbound>) {
        if let Some(presence) = self.presence.take() {
            if let Err(mpsc::error::TrySendError::Full(frame)) = tx.try_send(presence) {
                self.presence = Some(frame);
                return;
            }
        }
        while let Some((thread, stamp)) = self
            .gaps
            .first_key_value()
            .map(|(thread, stamp)| (thread.clone(), *stamp))
        {
            let gap = RelayMessage::StreamGap {
                thread_id: thread.clone(),
            };
            let frame = match stamp {
                Some(stamp) => Outbound::Protected(Envelope::message(gap, stamp)),
                None => Outbound::Message(gap),
            };
            if tx.try_send(frame).is_err() {
                return;
            }
            self.gaps.remove(&thread);
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
    /// host device -> its watched threads that gained a client since the host was last told
    /// ([`Relay::take_watching`]). Only watched threads are kept, so it stays bounded.
    refresh: HashMap<Uuid, BTreeSet<String>>,
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
                    if let Some(refresh) = self.refresh.get_mut(&host) {
                        refresh.remove(thread_id);
                        if refresh.is_empty() {
                            self.refresh.remove(&host);
                        }
                    }
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
    /// The session the link was opened with; `None` for the readiness probe.
    pub session: Option<SessionKey>,
    /// The readiness probe's in-process identity. The unconverted registration path refuses it
    /// too; the dependent link conversion must provide a separate native-floor probe admission.
    /// A probe never becomes online, enters presence or watches.
    pub probe: bool,
}

impl Identity {
    /// The readiness probe's identity: a client with nil ids that no device or user has.
    pub fn probe() -> Identity {
        Identity {
            device_id: Uuid::nil(),
            name: "readiness probe".to_string(),
            role: Role::Client,
            user_id: Uuid::nil(),
            org_id: Uuid::nil(),
            session: None,
            probe: true,
        }
    }
}

/// What the task that serves a link gets back from [`Relay::register`].
#[derive(Debug)]
pub struct Registration {
    pub handle: LinkHandle,
    /// The frames other tasks queued for this link, in order.
    pub outbound: mpsc::Receiver<Outbound>,
    /// Resolves when something asks this link to close.
    pub closing: oneshot::Receiver<Close>,
    /// True when this link replaced an older one of the same device.
    pub replaced: bool,
    /// The probe's own close sender (nothing in the registry can close an unregistered link); kept
    /// here so `closing` stays pending for as long as the link task holds the registration.
    pub probe_closer: Option<oneshot::Sender<Close>>,
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
    blocked: bool,
}

struct RegistrationState {
    links: HashMap<Uuid, Entry>,
    minimum: u32,
    local_denial: u32,
    initialized: bool,
    cut_generation: u64,
}
impl Default for RegistrationState {
    fn default() -> Self {
        Self {
            links: HashMap::new(),
            minimum: MIN_CLIENT_PROTOCOL,
            local_denial: 0,
            initialized: false,
            cut_generation: 0,
        }
    }
}

/// Keep existing map operations under the same mutex as floor comparison and insertion.
struct LinksGuard<'a>(MutexGuard<'a, RegistrationState>);
impl Deref for LinksGuard<'_> {
    type Target = HashMap<Uuid, Entry>;
    fn deref(&self) -> &Self::Target {
        &self.0.links
    }
}
impl DerefMut for LinksGuard<'_> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0.links
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FloorObservationError {
    Unsupported,
    Decreased,
    Exhausted,
}

/// Compact fixed refusal facts; produce the wire close only at the socket boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistrationRefusal {
    SessionEnded,
    StaleFloor,
    TooOld(u32),
    AdmissionUsed,
}
impl RegistrationRefusal {
    pub fn close(self) -> Close {
        match self {
            Self::SessionEnded => Close::session_ended(),
            Self::TooOld(minimum) => Close::client_too_old(minimum),
            Self::StaleFloor | Self::AdmissionUsed => Close::protocol_unavailable(),
        }
    }
}

struct Inner {
    registration: Mutex<RegistrationState>,
    next_generation: AtomicU64,
    /// How many commands a link opened from now on may have running at once.
    commands_in_flight_max: AtomicUsize,
    clock: WallClock,
    gate: Mutex<Option<Arc<RegistrationGate>>>,
    /// [`Relay::offline_grace`], in milliseconds.
    offline_grace_ms: AtomicU64,
    /// Macs whose link dropped within the grace, by the generation of that link: `presence` still
    /// counts them online.
    lingering: Mutex<HashMap<Uuid, u64>>,
    /// Set by [`Relay::panic_on_next_frame`], a test seam.
    panic_next_frame: AtomicBool,
    upgrades: SlidingWindow,
    live: watch::Sender<usize>,
    /// Held while a broadcast reads who is online and delivers it ([`Relay::broadcast_presence`]).
    presence_order: Mutex<()>,
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
            registration: Mutex::default(),
            next_generation: AtomicU64::new(0),
            commands_in_flight_max: AtomicUsize::new(COMMANDS_IN_FLIGHT),
            clock,
            gate: Mutex::new(None),
            offline_grace_ms: AtomicU64::new(OFFLINE_GRACE.as_millis() as u64),
            lingering: Mutex::default(),
            panic_next_frame: AtomicBool::new(false),
            upgrades: SlidingWindow::upgrades(),
            live: watch::channel(0).0,
            presence_order: Mutex::new(()),
            registered: watch::channel(0).0,
            commands: Commands::default(),
            watchers: Mutex::default(),
            watch_epoch: watch::channel(0).0,
        }))
    }

    /// Compatibility entrypoint for callers not yet converted to DB-backed admission. It is
    /// deliberately refused: no entry, watch, generation, registration notification or presence
    /// side effect. The link boundary must reject its handle before emitting any frame.
    pub fn register(&self, who: Identity) -> Registration {
        let (tx, outbound) = mpsc::channel(LINK_QUEUE);
        let (closing_tx, closing) = oneshot::channel();
        let handle = LinkHandle {
            device_id: who.device_id,
            name: who.name,
            generation: 0,
            role: who.role,
            user_id: who.user_id,
            org_id: who.org_id,
            session: who.session,
            client_protocol: ClientProtocol::LEGACY,
            cut_generation: 0,
            admitted: false,
            probe: who.probe,
            #[cfg(test)]
            synthetic_model: false,
            tx,
            missed: Arc::default(),
            event_bytes: Arc::default(),
        };
        let _ = closing_tx.send(Close::protocol_unavailable());
        Registration {
            handle,
            outbound,
            closing,
            replaced: false,
            probe_closer: None,
        }
    }

    /// Compare and insert against the observed floor under one mutex, while the caller retains
    /// the live admission's DB AS barrier. No pool or command wait occurs in this operation.
    pub fn register_admitted(
        &self,
        mut who: Identity,
        admission: &mut Admission,
    ) -> Result<Registration, RegistrationRefusal> {
        let native = admission.identity();
        let role = if native.platform == b4hub_db::devices::Platform::Macos {
            Role::Host
        } else {
            Role::Client
        };
        if who.probe
            || who.device_id != native.device_id
            || who.org_id != native.org_id
            || who.user_id != native.user_id
            || who.role != role
            || who.session != Some(admission.session())
        {
            return Err(RegistrationRefusal::SessionEnded);
        }
        who.name = admission.device_name().to_string();
        self.register_core(who, admission.client(), admission.floor(), false, || {
            admission.claim_registration()
        })
    }
    pub(super) fn register_probe(
        &self,
        admission: &mut b4hub_db::relay::ProbeAdmission,
    ) -> Result<Registration, RegistrationRefusal> {
        self.register_core(
            Identity::probe(),
            admission.client(),
            admission.floor(),
            false,
            || admission.claim_registration(),
        )
    }
    fn register_core(
        &self,
        who: Identity,
        client: ClientProtocol,
        floor: ProtocolFloor,
        synthetic: bool,
        claim: impl FnOnce() -> bool,
    ) -> Result<Registration, RegistrationRefusal> {
        #[cfg(not(test))]
        {
            debug_assert!(!synthetic);
        }
        let (registration, previous, dropped_watches) = {
            let mut state = self.registration();
            Self::advance_floor(&mut state, floor).map_err(|_| RegistrationRefusal::StaleFloor)?;
            let effective = state.minimum.max(state.local_denial);
            if client.value() < effective {
                return Err(RegistrationRefusal::TooOld(effective));
            }
            if !claim() {
                return Err(RegistrationRefusal::AdmissionUsed);
            }
            let (tx, outbound) = mpsc::channel(LINK_QUEUE);
            let (closing_tx, closing) = oneshot::channel();
            let handle = LinkHandle {
                device_id: who.device_id,
                name: who.name,
                generation: self.0.next_generation.fetch_add(1, Ordering::Relaxed) + 1,
                role: who.role,
                user_id: who.user_id,
                org_id: who.org_id,
                session: who.session,
                client_protocol: client,
                cut_generation: state.cut_generation,
                admitted: true,
                probe: who.probe,
                #[cfg(test)]
                synthetic_model: synthetic,
                tx,
                missed: Arc::default(),
                event_bytes: Arc::default(),
            };
            if who.probe {
                return Ok(Registration {
                    handle,
                    outbound,
                    closing,
                    replaced: false,
                    probe_closer: Some(closing_tx),
                });
            }
            let previous = state.links.insert(
                who.device_id,
                Entry {
                    handle: handle.clone(),
                    closing: Some(closing_tx),
                    blocked: false,
                },
            );
            let dropped = previous.is_some() && self.forget_watches(who.device_id);
            (
                Registration {
                    handle,
                    outbound,
                    closing,
                    replaced: previous.is_some(),
                    probe_closer: None,
                },
                previous,
                dropped,
            )
        };
        if dropped_watches {
            self.bump_watches();
        }
        self.0.registered.send_modify(|count| *count += 1);
        if let Some(older) = previous.and_then(|entry| entry.closing) {
            let _ = older.send(Close::replaced());
        }
        Ok(registration)
    }
    /// Pure queue/watch/replacement MODEL fixture only. No native admission is asserted and this
    /// constructor is absent from the production library and native integration builds.
    #[cfg(test)]
    fn register_synthetic_model(&self, who: Identity) -> Registration {
        self.register_core(
            who,
            ClientProtocol::LEGACY,
            ProtocolFloor::new(1).unwrap(),
            true,
            || true,
        )
        .unwrap()
    }

    fn advance_floor(
        state: &mut RegistrationState,
        floor: ProtocolFloor,
    ) -> Result<u64, FloorObservationError> {
        if !floor.supported() {
            return Err(FloorObservationError::Unsupported);
        }
        if floor.minimum() < state.minimum {
            return Err(FloorObservationError::Decreased);
        }
        if !state.initialized || floor.minimum() > state.minimum {
            state.cut_generation = state
                .cut_generation
                .checked_add(1)
                .ok_or(FloorObservationError::Exhausted)?;
        }
        state.minimum = floor.minimum();
        state.initialized = true;
        for entry in state.links.values_mut() {
            if entry.handle.client_protocol.value() < state.minimum.max(state.local_denial) {
                entry.blocked = true;
                if let Some(close) = entry.closing.take() {
                    let _ =
                        close.send(Close::client_too_old(state.minimum.max(state.local_denial)));
                }
            }
        }
        Ok(state.cut_generation)
    }

    /// A fresh native floor observation can only advance the denial state, never manufacture an
    /// admission. It closes incompatible current registrations under the insertion mutex.
    pub fn observe_floor(&self, floor: ProtocolFloor) -> Result<u64, FloorObservationError> {
        Self::advance_floor(&mut self.registration(), floor)
    }

    pub fn cut_generation(&self) -> u64 {
        self.registration().cut_generation
    }

    pub(super) fn current(&self, handle: &LinkHandle) -> bool {
        if handle.probe {
            return handle.admitted;
        }
        self.registration()
            .links
            .get(&handle.device_id)
            .is_some_and(|entry| {
                !entry.blocked
                    && entry.handle.generation == handle.generation
                    && entry.handle.org_id == handle.org_id
                    && entry.handle.user_id == handle.user_id
                    && entry.handle.session == handle.session
                    && entry.handle.client_protocol == handle.client_protocol
            })
    }
    pub(crate) fn queue_native(
        &self,
        handle: &LinkHandle,
        message: RelayMessage,
        required: u32,
    ) -> Result<(), SendError> {
        if !self.current(handle)
            || required < self.min_client_protocol()
            || handle.client_protocol.value() < required
        {
            return Err(SendError::Offline);
        }
        handle.queue_stamped(
            message,
            Stamp {
                generation: handle.generation,
                required,
            },
        )
    }

    /// How many links are live now (the readiness probe's included while it runs).
    pub fn live_links(&self) -> usize {
        *self.0.live.borrow()
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
        self.unregister_lingering(device_id, generation, false)
    }

    /// [`Relay::unregister`], and when `linger` and it was the current link, the device keeps
    /// reading online in `presence` until [`Relay::linger_ended`] for that link. It is marked
    /// lingering before its link is removed, so no presence read in between finds it offline.
    pub fn unregister_lingering(&self, device_id: Uuid, generation: u64, linger: bool) -> bool {
        let (current, dropped_watches) = {
            let mut links = self.links();
            match links.get(&device_id) {
                Some(entry) if entry.handle.generation == generation => {
                    if linger {
                        self.lingering().insert(device_id, generation);
                    }
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

    /// Ends the grace of `device_id`'s link `generation`. True when that link was still the one
    /// lingering (no later link of the device has dropped since, which has a grace of its own).
    pub fn linger_ended(&self, device_id: Uuid, generation: u64) -> bool {
        let mut lingering = self.lingering();
        if lingering.get(&device_id) == Some(&generation) {
            lingering.remove(&device_id);
            true
        } else {
            false
        }
    }

    /// How long a Mac whose link dropped on its own still reads online: [`OFFLINE_GRACE`].
    pub fn offline_grace(&self) -> Duration {
        Duration::from_millis(self.0.offline_grace_ms.load(Ordering::Relaxed))
    }

    /// Sets [`Relay::offline_grace`]; zero makes a Mac read offline as soon as its link is gone.
    /// A test seam: nothing in the hub changes it.
    pub fn set_offline_grace(&self, grace: Duration) {
        self.0
            .offline_grace_ms
            .store(grace.as_millis() as u64, Ordering::Relaxed);
    }

    fn lingering(&self) -> MutexGuard<'_, HashMap<Uuid, u64>> {
        self.0
            .lingering
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Asks the current link of `device_id` to close with `close`. True when there was one. The
    /// link stays registered (and online) until its task unregisters it.
    pub fn close(&self, device_id: Uuid, close: Close) -> bool {
        let mut links = self.links();
        let Some(entry) = links.get_mut(&device_id) else {
            return false;
        };
        if close.disposition != CloseDisposition::Drain {
            entry.blocked = true;
        }
        if let Some(closing) = entry.closing.take() {
            let _ = closing.send(close);
        }
        true
    }

    /// Asks the link of `device_id` to close with `close` if it is still registration
    /// `generation`, so a newer link of the same device is left alone. True when it was.
    pub fn close_generation(&self, device_id: Uuid, generation: u64, close: Close) -> bool {
        let mut links = self.links();
        let Some(entry) = links.get_mut(&device_id) else {
            return false;
        };
        if entry.handle.generation != generation {
            return false;
        }
        if close.disposition != CloseDisposition::Drain {
            entry.blocked = true;
        }
        if let Some(closing) = entry.closing.take() {
            let _ = closing.send(close);
        }
        true
    }

    /// The handles of every link of `user_id` here.
    pub fn links_of(&self, user_id: Uuid) -> Vec<LinkHandle> {
        self.links()
            .values()
            .filter(|entry| entry.handle.user_id == user_id)
            .map(|entry| entry.handle.clone())
            .collect()
    }

    /// Asks every link of `user_id` to close with `close`; returns how many there were.
    pub fn close_user(&self, user_id: Uuid, close: Close) -> usize {
        let mut links = self.links();
        let mut closed = 0;
        for entry in links.values_mut() {
            if entry.handle.user_id != user_id {
                continue;
            }
            closed += 1;
            if close.disposition != CloseDisposition::Drain {
                entry.blocked = true;
            }
            if let Some(closing) = entry.closing.take() {
                let _ = closing.send(close.clone());
            }
        }
        closed
    }

    /// The users with at least one link here, sorted.
    pub fn users(&self) -> Vec<Uuid> {
        let users: BTreeSet<Uuid> = self
            .links()
            .values()
            .map(|entry| entry.handle.user_id)
            .collect();
        users.into_iter().collect()
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
        let mut frame = Outbound::Message(message);
        let mut tried = None;
        loop {
            let handle = self.handle(device_id).ok_or(SendError::Offline)?;
            if !handle.synthetic_model() {
                return Err(SendError::Offline);
            }
            if tried == Some(handle.generation) {
                return Err(SendError::Offline);
            }
            tried = Some(handle.generation);
            match tokio::time::timeout_at(until, handle.tx.send(frame)).await {
                Ok(Ok(())) => return Ok(()),
                // That link is gone; try the device's current one, if it has a newer one.
                Ok(Err(mpsc::error::SendError(back))) => frame = back,
                Err(_) => return Err(SendError::Full),
            }
        }
    }

    pub(super) async fn reserve(
        &self,
        device: Uuid,
        until: Instant,
    ) -> Result<Reserved, SendError> {
        let mut tried = None;
        loop {
            let handle = self.handle(device).ok_or(SendError::Offline)?;
            if !handle.admitted || tried == Some(handle.generation) {
                return Err(SendError::Offline);
            }
            tried = Some(handle.generation);
            match tokio::time::timeout_at(until, handle.tx.clone().reserve_owned()).await {
                Ok(Ok(permit)) => {
                    return Ok(Reserved {
                        handle,
                        relay: self.clone(),
                        permit,
                        until,
                    })
                }
                Ok(Err(_)) => continue,
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
        Ok(self.presence_of(hosts))
    }

    /// The `presence` frame for `hosts` as read from the database, online as of now: with a link,
    /// or within the grace of one that dropped. The lingering set is read after the links, and a
    /// Mac is put in it before its link is removed, so a Mac in its grace is never missed.
    pub(super) fn presence_of(&self, hosts: Vec<(Uuid, String, Option<String>)>) -> RelayMessage {
        RelayMessage::Presence {
            hosts: hosts
                .into_iter()
                .map(|(device_id, name, last_seen_at)| HostPresence {
                    device_id,
                    name,
                    online: self.online(device_id) || self.lingering().contains_key(&device_id),
                    last_seen_at,
                })
                .collect(),
        }
    }

    /// Tells every client link of `user_id` the current presence. A client whose queue is full
    /// is sent it once the queue has room (see [`LinkHandle::deliver_presence`]).
    ///
    /// Who is online is read and delivered under one lock, so two broadcasts racing on other
    /// threads (a Mac leaving while another links) reach every phone in the order their snapshots
    /// were taken, and a phone is never left with the older one.
    pub async fn broadcast_presence(&self, db: &Db, org_id: Uuid, user_id: Uuid) {
        for client in self.presence_subscribers(user_id) {
            if client.org_id != org_id {
                continue;
            }
            let mut checked = match super::admission::Checked::open(db, self, &client).await {
                Ok(checked) => checked,
                Err(error) => {
                    if let Some(close) = error.close() {
                        self.close_generation(client.device_id, client.generation, close);
                    }
                    continue;
                }
            };
            let hosts = match checked.native() {
                Ok(native) => native.host_devices().await,
                Err(_) => continue,
            };
            let Ok(hosts) = hosts else {
                self.close_generation(
                    client.device_id,
                    client.generation,
                    Close::protocol_unavailable(),
                );
                continue;
            };
            {
                let _ordered = self
                    .0
                    .presence_order
                    .lock()
                    .unwrap_or_else(|p| p.into_inner());
                let message = self.presence_of(hosts);
                if let Ok(proof) = checked.proof(1) {
                    client.deliver_presence_checked(message, &proof);
                }
            }
            if checked.commit().await.is_err() {
                self.close_generation(
                    client.device_id,
                    client.generation,
                    Close::protocol_unavailable(),
                );
            }
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
            watchers
                .refresh
                .entry(host)
                .or_default()
                .insert(thread_id.to_string());
        }
        self.bump_watches();
        Ok(())
    }

    /// True when `client`'s link, still its device's current one, already watches `thread_id`.
    pub fn watches(&self, client: &LinkHandle, thread_id: &str) -> bool {
        let links = self.links();
        match links.get(&client.device_id) {
            Some(entry) if entry.handle.generation == client.generation => self
                .watchers()
                .by_client
                .get(&client.device_id)
                .is_some_and(|watches| watches.contains_key(thread_id)),
            _ => false,
        }
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

    /// What `host` is to be told in `watching`: [`Relay::watched_by`], and the threads of it that
    /// gained a client since the last call (which this call clears), sorted.
    pub fn take_watching(&self, host: Uuid) -> (Vec<String>, Vec<String>) {
        let refresh = self
            .watchers()
            .refresh
            .remove(&host)
            .map(|threads| threads.into_iter().collect())
            .unwrap_or_default();
        (self.watched_by(host), refresh)
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
        if watching.is_empty() {
            return 0;
        }
        // Encoded once for every watcher, not once per link.
        let Ok(text) = serde_json::to_string(event) else {
            return 0;
        };
        let text: Arc<str> = text.into();
        for client in &watching {
            if let Some(handle) = self.handle(*client) {
                handle.deliver_event(thread_id, Arc::clone(&text));
            }
        }
        watching.len()
    }

    pub(super) fn fan_out_checked(
        &self,
        host: Uuid,
        thread_id: &str,
        event: &RelayMessage,
        proof: &super::admission::Proof<'_>,
    ) -> usize {
        let watching: Vec<Uuid> = self
            .watchers()
            .by_host
            .get(&host)
            .and_then(|threads| threads.get(thread_id))
            .map(|clients| clients.iter().copied().collect())
            .unwrap_or_default();
        let Ok(text) = serde_json::to_string(event) else {
            return 0;
        };
        let text: Arc<str> = text.into();
        for client in &watching {
            if let Some(handle) = self.handle(*client) {
                handle.deliver_event_checked(thread_id, Arc::clone(&text), proof);
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

    /// Makes the link task that reads the next text frame panic, as a bug in the link path would.
    /// A test seam; nothing in the hub calls it.
    pub fn panic_on_next_frame(&self) {
        self.0.panic_next_frame.store(true, Ordering::SeqCst);
    }

    /// True once after [`Relay::panic_on_next_frame`].
    pub(super) fn take_frame_panic(&self) -> bool {
        self.0.panic_next_frame.swap(false, Ordering::SeqCst)
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

    /// A local denial hint, never an admission capability.
    pub fn min_client_protocol(&self) -> u32 {
        let state = self.registration();
        state.minimum.max(state.local_denial)
    }

    /// Test denial control, separate from the monotonic observed DB floor. Clearing this extra
    /// denial never lowers the native floor, creates admission or activates protocol 2.
    pub fn set_min_client_protocol(&self, protocol: u32) {
        let mut state = self.registration();
        state.local_denial = protocol;
    }

    /// How many commands a link may have running at once ([`COMMANDS_IN_FLIGHT`]).
    pub fn commands_in_flight_max(&self) -> usize {
        self.0.commands_in_flight_max.load(Ordering::Relaxed)
    }

    /// Sets [`Relay::commands_in_flight_max`] for links opened from now on. A test seam: nothing in
    /// the hub changes it.
    pub fn set_commands_in_flight_max(&self, max: usize) {
        self.0.commands_in_flight_max.store(max, Ordering::Relaxed);
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

    fn registration(&self) -> MutexGuard<'_, RegistrationState> {
        self.0
            .registration
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
    fn links(&self) -> LinksGuard<'_> {
        LinksGuard(self.registration())
    }
}

pub(super) struct Reserved {
    pub handle: LinkHandle,
    relay: Relay,
    permit: mpsc::OwnedPermit<Outbound>,
    until: Instant,
}
impl Reserved {
    pub fn send(
        self,
        message: RelayMessage,
        proof: &super::admission::Proof<'_>,
    ) -> Result<(), SendError> {
        if Instant::now() >= self.until {
            return Err(SendError::Full);
        }
        if !self.relay.current(&self.handle) {
            return Err(SendError::Offline);
        }
        let stamp = proof.stamp_for(&self.handle).ok_or(SendError::Offline)?;
        self.permit
            .send(Outbound::Protected(Envelope::message(message, stamp)));
        Ok(())
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
            session: None,
            probe: false,
        }
    }

    #[test]
    fn queued_frames_keep_their_generation_and_pre_cut_requirement() {
        let frame = Envelope::message(
            RelayMessage::Ping,
            Stamp {
                generation: 7,
                required: 1,
            },
        );
        assert!(frame.compatible(7, 1));
        assert!(
            !frame.compatible(8, 1),
            "a replacement cannot inherit the old queue"
        );
        assert!(
            !frame.compatible(7, 2),
            "support2 does not retag pre-cut content"
        );
        assert_eq!(
            frame.stamp,
            Stamp {
                generation: 7,
                required: 1
            }
        );
        let modern = Envelope::message(
            RelayMessage::Ping,
            Stamp {
                generation: 7,
                required: 2,
            },
        );
        assert!(modern.compatible(7, 2));
    }

    #[test]
    fn dropped_or_cloned_protected_events_release_the_exact_byte_budget() {
        let bytes = Arc::new(AtomicUsize::new(4));
        let frame = Envelope::event(
            Arc::from("data"),
            Stamp {
                generation: 1,
                required: 1,
            },
            Arc::clone(&bytes),
        );
        let duplicate = frame.clone();
        assert_eq!(bytes.load(Ordering::SeqCst), 8);
        drop(frame);
        assert_eq!(bytes.load(Ordering::SeqCst), 4);
        drop(duplicate);
        assert_eq!(bytes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn stale_gap_fences_the_following_event_and_releases_its_bytes_without_flush() {
        let relay = Relay::new();
        let mut link = relay.register_synthetic_model(identity(17, Role::Client));
        let generation = link.handle.generation;
        let gap = Envelope::message(
            RelayMessage::StreamGap {
                thread_id: "thread".into(),
            },
            Stamp {
                generation,
                required: 1,
            },
        );
        let text: Arc<str> = Arc::from(
            "{\"type\":\"event\",\"event\":{\"threadId\":\"thread\",\"text\":\"after-gap\"}}",
        );
        link.handle
            .event_bytes
            .fetch_add(text.len(), Ordering::SeqCst);
        let event = Envelope::event(
            Arc::clone(&text),
            Stamp {
                generation,
                required: 2,
            },
            Arc::clone(&link.handle.event_bytes),
        );
        link.handle.tx.try_send(Outbound::Protected(gap)).unwrap();
        link.handle.tx.try_send(Outbound::Protected(event)).unwrap();
        let Outbound::Protected(first) = link.outbound.try_recv().unwrap() else {
            panic!("missing gap");
        };
        let failure = first.check_for_write(generation, 2).unwrap_err();
        let close = failure.close().unwrap();
        assert_eq!(close.code, close_code::SHUTDOWN);
        assert_eq!(close.disposition, CloseDisposition::Fence);
        // The writer checks the original first envelope before any socket send. Its Fence
        // return uses this same production drain, never a shutdown-flush loop.
        drop(first);
        link.handle.discard_pending(&mut link.outbound);
        assert!(link.outbound.try_recv().is_err());
        assert_eq!(link.handle.event_bytes.load(Ordering::SeqCst), 0);
        link.handle.discard_pending(&mut link.outbound);
        assert_eq!(
            link.handle.event_bytes.load(Ordering::SeqCst),
            0,
            "cleanup cannot double release"
        );
        assert!(link.handle.missed().gaps.is_empty());
    }

    #[test]
    fn test_denial_never_lowers_the_observed_native_floor() {
        let relay = Relay::new();
        relay.observe_floor(ProtocolFloor::new(1).unwrap()).unwrap();
        relay.set_min_client_protocol(3);
        assert_eq!(relay.min_client_protocol(), 3);
        relay.set_min_client_protocol(1);
        assert_eq!(relay.min_client_protocol(), 1);
        relay.observe_floor(ProtocolFloor::new(2).unwrap()).unwrap();
        relay.set_min_client_protocol(1);
        assert_eq!(relay.min_client_protocol(), 2);
        assert!(relay.observe_floor(ProtocolFloor::new(1).unwrap()).is_err());
        assert!(relay.links_of(Uuid::nil()).is_empty());
    }

    #[test]
    fn protocol_refusals_are_never_ordinary_shutdown_drains() {
        assert_eq!(Close::shutdown().disposition, CloseDisposition::Drain);
        for close in [
            Close::client_too_old(2),
            Close::protocol_unavailable(),
            Close::protocol_not_activated(),
        ] {
            assert_eq!(close.disposition, CloseDisposition::Fence);
        }
    }

    #[test]
    fn the_probe_is_never_registered() {
        let relay = Relay::new();
        let _mac = relay.register_synthetic_model(identity(1, Role::Host));
        let probe = relay.register_synthetic_model(Identity::probe());
        assert!(!probe.replaced);
        assert!(!relay.online(Uuid::nil()));
        assert_eq!(relay.users(), [Uuid::from_u128(1000)]);
        assert!(relay.presence_subscribers(Uuid::nil()).is_empty());
        // Its handle cannot watch: it is not the device's current link.
        assert_eq!(
            relay.watch(&probe.handle, Uuid::from_u128(1), "t1"),
            Err(WatchError::Gone)
        );
        assert!(!relay.unregister(Uuid::nil(), probe.handle.generation));
    }

    #[test]
    fn close_user_closes_every_link_of_that_user_only() {
        let relay = Relay::new();
        let mut mac = relay.register_synthetic_model(identity(1, Role::Host));
        let mut phone = relay.register_synthetic_model(identity(2, Role::Client));
        let mut stranger = identity(3, Role::Client);
        stranger.user_id = Uuid::from_u128(1001);
        let mut other = relay.register_synthetic_model(stranger);
        assert_eq!(
            relay.users(),
            [Uuid::from_u128(1000), Uuid::from_u128(1001)]
        );
        assert_eq!(
            relay.close_user(Uuid::from_u128(1000), Close::relocated()),
            2
        );
        assert_eq!(mac.closing.try_recv().unwrap(), Close::relocated());
        assert_eq!(phone.closing.try_recv().unwrap(), Close::relocated());
        assert!(other.closing.try_recv().is_err());
    }

    #[test]
    fn a_new_link_replaces_and_closes_the_old_one() {
        let relay = Relay::new();
        let mut first = relay.register_synthetic_model(identity(1, Role::Host));
        assert!(!first.replaced);
        let second = relay.register_synthetic_model(identity(1, Role::Host));
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
        let mut link = relay.register_synthetic_model(identity(1, Role::Client));
        for _ in 0..LINK_QUEUE {
            relay.send(device, RelayMessage::Ping).unwrap();
        }
        assert_eq!(relay.send(device, RelayMessage::Ping), Err(SendError::Full));
        assert_eq!(
            link.outbound.try_recv().unwrap().message().unwrap(),
            RelayMessage::Ping
        );
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
        let mut link = relay.register_synthetic_model(identity(1, Role::Client));
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
        let mut link = relay.register_synthetic_model(identity(1, Role::Host));
        assert!(relay.close(Uuid::from_u128(1), Close::revoked()));
        assert_eq!(link.closing.try_recv().unwrap(), Close::revoked());
        assert!(relay.online(Uuid::from_u128(1)));
        assert!(!relay.close(Uuid::from_u128(9), Close::revoked()));
    }

    #[test]
    fn presence_subscribers_are_the_users_client_links_only() {
        let relay = Relay::new();
        let _mac = relay.register_synthetic_model(identity(1, Role::Host));
        let _phone = relay.register_synthetic_model(identity(2, Role::Client));
        let mut stranger = identity(3, Role::Client);
        stranger.user_id = Uuid::from_u128(1001);
        let _other = relay.register_synthetic_model(stranger);
        let subscribers = relay.presence_subscribers(Uuid::from_u128(1000));
        assert_eq!(subscribers.len(), 1);
        assert_eq!(subscribers[0].device_id, Uuid::from_u128(2));
    }

    fn event(thread: &str) -> RelayMessage {
        RelayMessage::Event {
            event: serde_json::json!({ "threadId": thread }),
        }
    }

    /// [`event`] as `fan_out` hands it to a link: encoded once.
    fn encoded(thread: &str) -> Arc<str> {
        serde_json::to_string(&event(thread)).unwrap().into()
    }

    #[test]
    fn events_past_the_byte_budget_are_a_gap_and_written_ones_give_room_back() {
        let relay = Relay::new();
        let mut link = relay.register_synthetic_model(identity(2, Role::Client));
        // 1 MiB events: four fit in the budget, the fifth would pass it.
        let big = |n: usize| -> Arc<str> {
            serde_json::to_string(&RelayMessage::Event {
                event: serde_json::json!({ "threadId": "t1", "text": "x".repeat((1 << 20) - 64 - n) }),
            })
            .unwrap()
            .into()
        };
        for n in 0..4 {
            link.handle.deliver_event("t1", big(n));
        }
        link.handle.deliver_event("t1", big(4));
        let mut queued = Vec::new();
        while let Ok(frame) = link.outbound.try_recv() {
            queued.push(frame);
        }
        assert_eq!(queued.len(), 4, "the fifth event is over the budget");
        // The link writes what it took off the queue: the gap goes out, then events flow again.
        for frame in &queued {
            if let Outbound::Event(text) = frame {
                link.handle.event_written(text.len());
            }
        }
        link.handle.flush_missed();
        assert_eq!(
            link.outbound.try_recv().unwrap().message().unwrap(),
            RelayMessage::StreamGap {
                thread_id: "t1".into()
            }
        );
        link.handle.deliver_event("t1", encoded("t1"));
        assert_eq!(
            link.outbound.try_recv().unwrap().message().unwrap(),
            event("t1")
        );
    }

    #[test]
    fn a_full_queue_drops_events_and_reports_one_gap_when_there_is_room() {
        let relay = Relay::new();
        let mut link = relay.register_synthetic_model(identity(2, Role::Client));
        for _ in 0..LINK_QUEUE {
            link.handle.deliver_event("t1", encoded("t1"));
        }
        // Full: these are dropped, and the thread is marked once, not once per event.
        link.handle.deliver_event("t1", encoded("t1"));
        link.handle.deliver_event("t1", encoded("t1"));
        link.handle.deliver_event("t2", encoded("t2"));
        // No room yet, so nothing more is queued.
        link.handle.flush_missed();
        assert!(link.handle.try_send(RelayMessage::Ping).is_err());

        // Room appears: the gaps take it, once each, in order, behind what was already queued.
        link.outbound.try_recv().unwrap();
        link.outbound.try_recv().unwrap();
        link.handle.flush_missed();
        let mut rest = Vec::new();
        while let Ok(frame) = link.outbound.try_recv() {
            rest.push(frame.message().unwrap());
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
        link.handle.deliver_event("t1", encoded("t1"));
        assert_eq!(
            link.outbound.try_recv().unwrap().message().unwrap(),
            event("t1")
        );
        assert!(link.outbound.try_recv().is_err());
    }

    #[test]
    fn presence_that_does_not_fit_is_kept_latest_only() {
        let relay = Relay::new();
        let mut link = relay.register_synthetic_model(identity(2, Role::Client));
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
            frames.push(frame.message().unwrap());
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
        let old = relay
            .register_synthetic_model(identity(2, Role::Client))
            .handle;
        for n in 0..WATCH_MAX {
            relay.watch(&old, host, &format!("t{n}")).unwrap();
        }
        assert_eq!(relay.watch(&old, host, "t9"), Err(WatchError::Limit));
        // A thread it already watches is not a new one.
        relay.watch(&old, host, "t0").unwrap();
        assert_eq!(relay.watched_by(host), ["t0", "t1", "t2", "t3"]);

        // A newer link of the device starts with none, and the old link can no longer add.
        let new = relay
            .register_synthetic_model(identity(2, Role::Client))
            .handle;
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
