//! `GET /v1/devices/self/link`: the endpoint, and the task that serves one link.
//!
//! The handler authenticates (the bearer token, before any upgrade, so a bad token is a plain
//! `401` and no socket), applies the upgrade rate limit, and upgrades. One task then serves the
//! link, reading and writing: it says `hello`, answers `ping` with `pong`, writes what other
//! tasks queued through the registry, and closes the link when it has been silent for
//! `DEAD_LINK`, when something asks it to ([`Close`]), or when the hub shuts down. When it ends it
//! leaves the registry, records the time of the link's last frame as `last_seen_at`, and, for a
//! Mac, tells the user's phones.
//!
//! With more than one instance, the upgrade first claims the device's user for this instance
//! (`b4hub_db::instances::claim_user`); a user served by another live instance is refused `409
//! relocated` before any socket exists. [`probe`] runs the same link task over an in-memory socket
//! for `/readyz`.

use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::header::SET_COOKIE;
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use b4hub_core::relay::{
    RelayMessage, RelayMethod, Role, WireError, CLIENT_FRAME_MAX, DEAD_LINK, HEARTBEAT_SECONDS,
    HOST_FRAME_MAX,
};
use b4hub_db::devices::{self, Platform, SessionKey};
use b4hub_db::instances::Claim;
use b4hub_db::relay::set_last_seen;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, Semaphore};
use tokio::time::Instant;

use super::limits::IN_FLIGHT_RETRY;
use super::registry::{Close, Identity, LinkHandle, LiveLink, Outbound, Registration};
use super::{close_code, invalid_frame, route, PROTOCOL};
use crate::auth::{bearer_token, AuthedDevice};
use crate::error::ApiError;
use crate::instances;
use crate::maintenance;
use crate::serve::AppState;
use crate::signals;

/// The header a device names its link protocol in; a missing header counts as 1.
const PROTOCOL_HEADER: &str = "b4-protocol";

/// How often a link that stays up writes `last_seen_at`, the same cadence as the per-request
/// throttle in `auth`.
const LAST_SEEN_EVERY: Duration = Duration::from_secs(60);

/// The largest WebSocket message the socket layer reads at all. The per-role limits
/// (`CLIENT_FRAME_MAX`, `HOST_FRAME_MAX`) are checked on top of it, as a refusal that leaves the
/// link up; a message past this ends the connection before the hub sees it, and the hub drops it
/// without a close frame (the read fails, `run` returns `None`, and only a chosen close is sent).
const WIRE_MAX: usize = 1024 * 1024;

/// How long the hub waits, after sending a close frame, for the device's own before it drops the
/// connection.
const CLOSE_GRACE: Duration = Duration::from_secs(2);

/// How long [`probe`] may take, `hello` exchange included.
pub const PROBE_WAIT: Duration = Duration::from_secs(2);

/// How long [`probe`] waits for its link task to finish after the exchange before aborting it, so
/// a failing `/readyz` still answers well inside the container `HEALTHCHECK --timeout=4s`.
const PROBE_JOIN_WAIT: Duration = Duration::from_millis(500);

/// What a link task reads and writes: the upgraded WebSocket, or the readiness probe's in-memory
/// socket. The link task is the same code over either.
pub trait LinkSocket: Send {
    /// The next message; `None` once the peer is gone, `Err` when the socket failed.
    fn recv(&mut self) -> impl Future<Output = Option<Result<Message, ()>>> + Send;
    fn send(&mut self, message: Message) -> impl Future<Output = Result<(), ()>> + Send;
}

impl LinkSocket for WebSocket {
    async fn recv(&mut self) -> Option<Result<Message, ()>> {
        WebSocket::recv(self)
            .await
            .map(|message| message.map_err(|_| ()))
    }

    async fn send(&mut self, message: Message) -> Result<(), ()> {
        WebSocket::send(self, message).await.map_err(|_| ())
    }
}

/// One end of an in-memory socket: the messages the other end sent, and the way to send it more.
struct MemorySocket {
    incoming: mpsc::Receiver<Message>,
    outgoing: mpsc::Sender<Message>,
}

impl MemorySocket {
    fn pair() -> (MemorySocket, MemorySocket) {
        let (a_tx, a_rx) = mpsc::channel(16);
        let (b_tx, b_rx) = mpsc::channel(16);
        (
            MemorySocket {
                incoming: a_rx,
                outgoing: b_tx,
            },
            MemorySocket {
                incoming: b_rx,
                outgoing: a_tx,
            },
        )
    }
}

impl LinkSocket for MemorySocket {
    async fn recv(&mut self) -> Option<Result<Message, ()>> {
        self.incoming.recv().await.map(Ok)
    }

    async fn send(&mut self, message: Message) -> Result<(), ()> {
        self.outgoing.send(message).await.map_err(|_| ())
    }
}

pub async fn upgrade(
    State(state): State<AppState>,
    device: AuthedDevice,
    headers: HeaderMap,
    upgrade: Result<WebSocketUpgrade, WebSocketUpgradeRejection>,
) -> Result<Response, ApiError> {
    if state.shutdown.is_triggered() {
        return Err(ApiError::shutting_down());
    }
    let upgrade = upgrade.map_err(|_| ApiError::invalid_request("expected a WebSocket upgrade"))?;
    let protocol = client_protocol(&headers)?;
    state
        .relay
        .check_upgrade(device.device_id)
        .map_err(|retry_after| {
            tracing::warn!(device = %device.device_id, "link upgrade rate limit hit");
            ApiError::rate_limited_after(retry_after)
        })?;
    // The device was valid a moment ago; if it is gone now it was revoked in between.
    let info = devices::me(&state.db, device.org_id, device.device_id)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    // Every link of one user is served by one instance. A user another live instance serves is
    // refused here, before any socket exists, so the device hears no `hello` and nothing about
    // the refused link enters the registry. No cookie goes with the refusal: the load balancer
    // would bind it to this (wrong) target.
    let claim = b4hub_db::instances::claim_user(
        &state.db,
        device.user_id,
        state.instances.id(),
        state.instances.alive_within(),
    )
    .await?;
    if let Claim::Other(owner) = claim {
        tracing::info!(device = %device.device_id, owner = %owner, "link relocated");
        return Err(ApiError::relocated(owner));
    }
    let who = Identity {
        device_id: device.device_id,
        name: info.device_name,
        role: role_of(device.platform),
        user_id: device.user_id,
        org_id: device.org_id,
        // The extractor verified this header; the link keeps its hash to look it up again.
        session: bearer_token(&headers).map(SessionKey::of),
        probe: false,
    };
    let live = state.relay.track();
    let cookie = state.instances.cookie();
    let mut response = upgrade
        .max_message_size(WIRE_MAX)
        .max_frame_size(WIRE_MAX)
        .on_upgrade(move |socket| serve_link(state, who, protocol, socket, live))
        .into_response();
    response.headers_mut().insert(SET_COOKIE, cookie);
    Ok(response)
}

/// Why [`probe`] failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProbeFailure {
    /// No `hello` (and `pong`) within [`PROBE_WAIT`].
    Timeout,
    /// The link answered something else first, or ended.
    Unexpected(&'static str),
}

/// The readiness probe: runs this instance's link task over an in-memory socket as the probe
/// identity (which the registry never enters), expects `hello` and the client's `presence`, sends
/// `ping`, expects `pong`, and closes, all within [`PROBE_WAIT`]. No device is minted and no row
/// is written.
pub async fn probe(state: &AppState) -> Result<(), ProbeFailure> {
    let (hub_end, mut device) = MemorySocket::pair();
    let live = state.relay.track();
    let mut task = tokio::spawn(serve_link(
        state.clone(),
        Identity::probe(),
        PROTOCOL,
        hub_end,
        live,
    ));
    let exchange = async {
        match next_frame(&mut device).await? {
            RelayMessage::Hello { .. } => {}
            _ => return Err(ProbeFailure::Unexpected("the link did not say hello")),
        }
        match next_frame(&mut device).await? {
            RelayMessage::Presence { .. } => {}
            _ => return Err(ProbeFailure::Unexpected("no presence after hello")),
        }
        let ping = serde_json::to_string(&RelayMessage::Ping)
            .map_err(|_| ProbeFailure::Unexpected("a ping does not encode"))?;
        device
            .send(Message::Text(ping.into()))
            .await
            .map_err(|()| ProbeFailure::Unexpected("the link stopped reading"))?;
        match next_frame(&mut device).await? {
            RelayMessage::Pong { .. } => Ok(()),
            _ => Err(ProbeFailure::Unexpected("no pong")),
        }
    };
    let outcome = match tokio::time::timeout(PROBE_WAIT, exchange).await {
        Ok(outcome) => outcome,
        Err(_) => Err(ProbeFailure::Timeout),
    };
    if outcome.is_err() {
        // A wedged link task must not linger in the relay's live count (shutdown waits on it).
        task.abort();
        return outcome;
    }
    // Close politely, then hang up: the link task sees the close, and then the end of the socket.
    let _ = tokio::time::timeout(PROBE_JOIN_WAIT, device.send(Message::Close(None))).await;
    drop(device);
    if tokio::time::timeout(PROBE_JOIN_WAIT, &mut task)
        .await
        .is_err()
    {
        task.abort();
        tracing::warn!("the readiness probe's link task did not finish; aborted");
    }
    outcome
}

/// The next relay frame the probe's device end receives.
async fn next_frame(device: &mut MemorySocket) -> Result<RelayMessage, ProbeFailure> {
    loop {
        match device.recv().await {
            Some(Ok(Message::Text(text))) => {
                return serde_json::from_str(text.as_str())
                    .map_err(|_| ProbeFailure::Unexpected("not a relay frame"));
            }
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
            Some(Ok(Message::Close(_))) => {
                return Err(ProbeFailure::Unexpected("the link closed"));
            }
            _ => return Err(ProbeFailure::Unexpected("the link ended")),
        }
    }
}

/// A `macos` device is a host; an `ios` or `cli` device is a client.
pub fn role_of(platform: Platform) -> Role {
    match platform {
        Platform::Macos => Role::Host,
        Platform::Ios | Platform::Cli => Role::Client,
    }
}

fn client_protocol(headers: &HeaderMap) -> Result<u32, ApiError> {
    match headers.get(PROTOCOL_HEADER) {
        None => Ok(1),
        Some(value) => value
            .to_str()
            .ok()
            .and_then(|text| text.trim().parse().ok())
            .ok_or_else(|| ApiError::invalid_request("B4-Protocol must be a whole number")),
    }
}

/// One link, from its first frame to its cleanup.
async fn serve_link<S: LinkSocket>(
    state: AppState,
    who: Identity,
    protocol: u32,
    mut socket: S,
    _live: LiveLink,
) {
    let relay = state.relay.clone();
    let min = relay.min_client_protocol();
    let probe = who.probe;
    if protocol < min {
        if probe {
            tracing::warn!(protocol, min, "readiness probe refused: protocol too old");
        } else {
            tracing::info!(device = %who.device_id, protocol, min, "link refused: client too old");
        }
        if send_close(&mut socket, &Close::client_too_old(min), DEAD_LINK).await {
            await_peer_close(&mut socket).await;
        }
        return;
    }

    if !probe {
        relay.pass_gate().await;
    }
    let role = who.role;
    let Registration {
        handle,
        mut outbound,
        mut closing,
        replaced,
        probe_closer: _probe_closer,
    } = relay.register(who);
    if !probe {
        tracing::info!(device = %handle.device_id, ?role, replaced, "link open");
    }
    let mut registered = Registered {
        state: state.clone(),
        handle: handle.clone(),
        probe,
        done: false,
    };

    let mut link = Link {
        state,
        handle,
        replaced,
        last_frame: Instant::now(),
        last_written: Instant::now(),
        peer_closed: false,
        probe,
        running: Arc::new(Semaphore::new(relay.commands_in_flight_max())),
    };
    // The upgrade checked the session, but a log-out or revocation can land between that check
    // and the registration above, when the check that follows it finds no link to close.
    // Registering first and looking again closes that window: a change after this look finds the
    // registered link.
    // The upgrade claimed the user, but their last other link here may have released the claim
    // since (D-172): take it again, or, if another instance has the user now, close this link.
    if !probe {
        instances::reclaim(
            &link.state.db,
            &relay,
            &link.state.instances,
            link.handle.user_id,
        )
        .await;
    }
    let ended = !probe && !signals::check_session(&relay, &link.state.db, &link.handle).await;
    let close = if ended {
        Some(Close::session_ended())
    } else {
        link.run(&mut socket, &mut outbound, &mut closing).await
    };

    // The link is over. The device was last heard from when its last frame arrived, not when the
    // drop was noticed. That goes in the database before the device reads as offline, so anyone who
    // sees it offline (a command judging how recently it was seen) finds the time already there.
    link.write_last_seen(link.last_frame).await;
    // A Mac that went away on its own reads online for a grace, in case it is back at once; one
    // the hub closed for good (revoked, its session ended) is offline now.
    let linger = role == Role::Host
        && !relay.offline_grace().is_zero()
        && close
            .as_ref()
            .is_none_or(|close| close.code != close_code::REVOKED);
    let was_current = registered.unregister(linger);
    // Once the user has no link left here, their claim goes now, before this link's close is even
    // written, so the instance they reconnect to takes them at once (D-165, D-172): whether this
    // instance is draining, or its links were cut while it lives on.
    let draining = link.state.shutdown.is_triggered();
    if !probe && was_current {
        instances::release_if_unlinked(
            &link.state.db,
            &relay,
            &link.state.instances,
            link.handle.user_id,
        )
        .await;
    }
    // A draining hub gives a device that is not reading the close grace, not a dead link's wait.
    let patience = if draining { CLOSE_GRACE } else { DEAD_LINK };
    let closed = match &close {
        Some(close) => send_close(&mut socket, close, patience).await,
        None => false,
    };
    if was_current && role == Role::Host {
        host_left(&link.state, &link.handle, linger).await;
    }
    if closed || link.peer_closed {
        await_peer_close(&mut socket).await;
    }
    if probe {
        return;
    }
    tracing::info!(
        device = %link.handle.device_id,
        ?role,
        code = close.as_ref().map(|close| close.code),
        "link closed"
    );
}

/// A link's place in the registry, taken back when the link task ends however it ends. The
/// ordinary end calls [`Registered::unregister`] in its place in the cleanup (after the last-seen
/// write, before the claim and presence); a link task that panics, or is dropped before it gets
/// there, is unregistered on drop instead, and its claim and presence follow on a task of their
/// own. Without it, the device would stay online with its watches until it linked again.
struct Registered {
    state: AppState,
    handle: LinkHandle,
    probe: bool,
    done: bool,
}

impl Registered {
    /// Takes the link out of the registry, a Mac's lingering when `linger`. True when it was the
    /// device's current link.
    fn unregister(&mut self, linger: bool) -> bool {
        self.done = true;
        self.state
            .relay
            .unregister_lingering(self.handle.device_id, self.handle.generation, linger)
    }
}

impl Drop for Registered {
    fn drop(&mut self) {
        if self.done {
            return;
        }
        let linger = self.handle.role == Role::Host && !self.state.relay.offline_grace().is_zero();
        let was_current = self.unregister(linger);
        if self.probe || !was_current {
            return;
        }
        tracing::warn!(device = %self.handle.device_id, "link task ended early; link unregistered");
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let (state, handle) = (self.state.clone(), self.handle.clone());
        runtime.spawn(async move {
            instances::release_if_unlinked(
                &state.db,
                &state.relay,
                &state.instances,
                handle.user_id,
            )
            .await;
            if handle.role == Role::Host {
                host_left(&state, &handle, linger).await;
            }
        });
    }
}

/// Tells the user's phones that the Mac of `handle` lost its link. When it `lingered`, it still
/// reads online, and the phones hear of it only if it has not linked again once
/// [`Relay::offline_grace`] has passed (D-193); otherwise they hear now.
async fn host_left(state: &AppState, handle: &LinkHandle, lingered: bool) {
    if !lingered {
        state
            .relay
            .broadcast_presence(&state.db, handle.org_id, handle.user_id)
            .await;
        return;
    }
    let grace = state.relay.offline_grace();
    let (state, handle) = (state.clone(), handle.clone());
    tokio::spawn(async move {
        tokio::time::sleep(grace).await;
        let relay = &state.relay;
        // A Mac that linked again was never offline to its phones: nothing to tell them.
        if relay.linger_ended(handle.device_id, handle.generation)
            && !relay.online(handle.device_id)
        {
            relay
                .broadcast_presence(&state.db, handle.org_id, handle.user_id)
                .await;
        }
    });
}

struct Link {
    state: AppState,
    handle: LinkHandle,
    /// This link took over from an older one of the same device, so the device never went offline
    /// and its phones have nothing new to hear.
    replaced: bool,
    /// When the last frame (of any kind) arrived from the device; the link opening counts.
    last_frame: Instant,
    /// When `last_seen_at` was last written for this link, for the once-a-minute refresh. It is
    /// the link's own, on the tokio clock, rather than `auth`'s shared throttle on the real clock,
    /// so a paused clock moves it.
    last_written: Instant,
    /// The device sent its own close frame. Our answer is queued inside the WebSocket and goes out
    /// the next time the socket is read, which `await_peer_close` does.
    peer_closed: bool,
    /// The readiness probe's link: it writes no `last_seen_at` (there is no such device).
    probe: bool,
    /// One permit per command this link may have running ([`Relay::commands_in_flight_max`]).
    running: Arc<Semaphore>,
}

impl Link {
    /// Serves the link until it ends. `Some(close)` is a close the hub chose (and still owes the
    /// device); `None` means the device went away or the socket failed.
    async fn run<S: LinkSocket>(
        &mut self,
        socket: &mut S,
        outbound: &mut tokio::sync::mpsc::Receiver<Outbound>,
        closing: &mut tokio::sync::oneshot::Receiver<Close>,
    ) -> Option<Close> {
        // `last_seen_at` is written on open, before `hello`, so a device that has heard `hello`
        // can rely on it.
        self.write_last_seen(self.last_frame).await;

        let hello = RelayMessage::Hello {
            protocol: PROTOCOL,
            min_client_protocol: self.state.relay.min_client_protocol(),
            device_id: self.handle.device_id,
            role: self.handle.role,
            heartbeat_seconds: HEARTBEAT_SECONDS,
            hub_time: self.state.relay.hub_time(),
        };
        write(socket, &hello).await.ok()?;

        // A phone is told which of its Macs are online, once after `hello`; a Mac coming online
        // is told to the user's phones.
        match self.handle.role {
            Role::Client => {
                let presence = self
                    .state
                    .relay
                    .presence(&self.state.db, self.handle.org_id, self.handle.user_id)
                    .await;
                match presence {
                    Ok(presence) => write(socket, &presence).await.ok()?,
                    Err(error) => tracing::warn!(%error, "could not read presence"),
                }
            }
            Role::Host if !self.replaced => {
                self.state
                    .relay
                    .broadcast_presence(&self.state.db, self.handle.org_id, self.handle.user_id)
                    .await;
            }
            Role::Host => {}
        }

        // A host is told which of its threads are watched, whole, right after `hello` and again
        // whenever the set changes or a thread it was told of gains another client (`refresh`,
        // so that client gets the catch-up too). The receiver is made first, so a change that
        // lands while the first frame is being written is not missed. It is written by this task,
        // not queued: it is never dropped and never reordered behind a later change.
        let mut watch_changes = self.state.relay.watch_changes();
        let is_host = self.handle.role == Role::Host;
        let mut told = Vec::new();
        if is_host {
            // Every thread is new to this link, so nothing needs refreshing.
            (told, _) = self.state.relay.take_watching(self.handle.device_id);
            let watching = RelayMessage::Watching {
                thread_ids: told.clone(),
                refresh: Vec::new(),
            };
            write(socket, &watching).await.ok()?;
        }

        let mut stopping = self.state.shutdown.subscribe();
        let dead = tokio::time::sleep_until(self.last_frame + DEAD_LINK);
        tokio::pin!(dead);
        loop {
            tokio::select! {
                closing = &mut *closing => {
                    return Some(closing.unwrap_or_else(|_| Close::shutdown()));
                }
                () = hub_stopping(&mut stopping) => {
                    // What is already queued (the drain's answers to held commands, a reply)
                    // goes out before the close, to a device that is still reading.
                    while let Ok(frame) = outbound.try_recv() {
                        self.write_queued(socket, frame, CLOSE_GRACE).await.ok()?;
                    }
                    return Some(Close::shutdown());
                }
                () = &mut dead => return Some(Close::silent()),
                queued = outbound.recv() => {
                    // The registry's handle keeps the sender alive as long as this link is
                    // registered, so `None` is not expected; treat it as the end.
                    let frame = queued?;
                    self.write_queued(socket, frame, DEAD_LINK).await.ok()?;
                    // A frame left the queue: room for what a full queue made this link miss.
                    self.handle.flush_missed();
                }
                _ = watch_changes.changed(), if is_host => {
                    let (now, mut refresh) = self.state.relay.take_watching(self.handle.device_id);
                    // A thread new to the set is caught up anyway.
                    refresh.retain(|thread| told.contains(thread));
                    if now != told || !refresh.is_empty() {
                        let watching = RelayMessage::Watching {
                            thread_ids: now.clone(),
                            refresh,
                        };
                        write(socket, &watching).await.ok()?;
                        told = now;
                    }
                }
                incoming = socket.recv() => {
                    let message = incoming?.ok()?;
                    let now = Instant::now();
                    self.last_frame = now;
                    dead.as_mut().reset(now + DEAD_LINK);
                    self.keep_last_seen_fresh(now);
                    let reply = match message {
                        Message::Text(text) if text.len() > self.frame_max() => {
                            Some(self.too_large())
                        }
                        Message::Text(text) => self.on_text(text.as_str()).await,
                        Message::Binary(bytes) if bytes.len() > self.frame_max() => {
                            Some(self.too_large())
                        }
                        Message::Binary(_) => {
                            Some(invalid_frame("frames are JSON text, not binary"))
                        }
                        Message::Close(_) => {
                            self.peer_closed = true;
                            return None;
                        }
                        // Protocol-level ping and pong are answered by the WebSocket layer; they
                        // count as the device being alive and nothing more.
                        Message::Ping(_) | Message::Pong(_) => None,
                    };
                    if let Some(reply) = reply {
                        write(socket, &reply).await.ok()?;
                    }
                }
            }
        }
    }

    /// The largest frame this link may send: 64 KiB from a client, 256 KiB from a host.
    fn frame_max(&self) -> usize {
        match self.handle.role {
            Role::Client => CLIENT_FRAME_MAX,
            Role::Host => HOST_FRAME_MAX,
        }
    }

    /// The refusal of a frame over [`Link::frame_max`]. The frame is not read, and not echoed.
    fn too_large(&self) -> RelayMessage {
        let max = self.frame_max();
        RelayMessage::Error {
            code: "invalid_request".to_string(),
            message: format!("a frame may be at most {max} bytes from this device"),
            details: Some(serde_json::json!({ "maxBytes": max })),
        }
    }

    /// Handles one text frame; the returned frame, if any, is written back at once.
    async fn on_text(&self, text: &str) -> Option<RelayMessage> {
        if self.state.relay.take_frame_panic() {
            panic!("a link task panicked (test seam)");
        }
        match serde_json::from_str::<RelayMessage>(text) {
            Ok(RelayMessage::Ping) => Some(RelayMessage::Pong {
                hub_time: self.state.relay.hub_time(),
            }),
            Ok(other) => self.on_frame(other).await,
            // A command whose method is not one of the five is answered as a command, by id.
            // Anything else is not echoed: it may carry content the hub must not log or repeat.
            Err(_) => Some(
                route::unknown_command(text)
                    .unwrap_or_else(|| invalid_frame("the frame is not a valid relay message")),
            ),
        }
    }

    /// A well-formed frame other than `ping`. A command runs on its own task, so a slow Mac never
    /// holds up this link (or the link's other commands); a host's reply and event are matched at
    /// once. A client's `watch` is decided here, in order with its other watches and unwatches (a
    /// `watch` followed by an `unwatch` must end unwatched); it costs one indexed lookup.
    async fn on_frame(&self, message: RelayMessage) -> Option<RelayMessage> {
        let role = self.handle.role;
        match message {
            RelayMessage::Command {
                id, method, params, ..
            } => {
                // While maintenance is on, a client's commands that change something answer as
                // the HTTP write routes do; `turn.lookup` and `watch` continue.
                if role == Role::Client && writes(method) {
                    if let Some(paused) = self.state.maintenance.current() {
                        tracing::info!(
                            method = method.as_str(),
                            outcome = "maintenance",
                            "command"
                        );
                        let refused = maintenance::refused(&paused).0;
                        return Some(RelayMessage::Reply {
                            id,
                            result: None,
                            error: Some(WireError {
                                code: refused.code.to_string(),
                                message: refused.message,
                                details: None,
                            }),
                        });
                    }
                }
                let Ok(running) = Arc::clone(&self.running).try_acquire_owned() else {
                    // A resend of a command still running attaches to it, as it would have.
                    if self
                        .state
                        .relay
                        .commands()
                        .in_flight(self.handle.device_id, &id)
                    {
                        return None;
                    }
                    tracing::warn!(
                        device = %self.handle.device_id,
                        method = method.as_str(),
                        outcome = "too_many_in_flight",
                        "command"
                    );
                    return Some(RelayMessage::Reply {
                        id,
                        result: None,
                        error: Some(route::rate_limited(IN_FLIGHT_RETRY)),
                    });
                };
                let relay = self.state.relay.clone();
                let db = self.state.db.clone();
                let caller = self.handle.clone();
                tokio::spawn(async move {
                    route::handle_command(&relay, &db, &caller, id, method, params).await;
                    drop(running);
                });
                None
            }
            RelayMessage::Reply { id, result, error } if role == Role::Host => {
                route::handle_reply(&self.state.relay, &self.handle, &id, result, error);
                None
            }
            RelayMessage::Watch { thread_id } if role == Role::Client => {
                route::handle_watch(&self.state.relay, &self.state.db, &self.handle, &thread_id)
                    .await
            }
            RelayMessage::Unwatch { thread_id } if role == Role::Client => {
                self.state.relay.unwatch(&self.handle, &thread_id);
                None
            }
            RelayMessage::Event { event } if role == Role::Host => {
                route::handle_event(&self.state.relay, &self.handle, event);
                None
            }
            _ => Some(invalid_frame("this frame is not accepted from a device")),
        }
    }

    /// Writes a frame from the queue within `patience`. An event arrives encoded (once, for every
    /// watcher) and is written as it is; its bytes are given back to the link's budget.
    async fn write_queued<S: LinkSocket>(
        &self,
        socket: &mut S,
        frame: Outbound,
        patience: Duration,
    ) -> Result<(), ()> {
        match frame {
            Outbound::Message(message) => write_within(socket, &message, patience).await,
            Outbound::Event(text) => {
                let written =
                    write_message(socket, Message::Text(text.to_string().into()), patience).await;
                self.handle.event_written(text.len());
                written
            }
        }
    }

    /// Writes `last_seen_at` at most once a minute while the link is up, and looks the link's
    /// session up again, so a link whose token was deleted or whose device was revoked closes
    /// within a minute even when no signal reached this instance. Off the link's task, so a slow
    /// database never delays a heartbeat.
    fn keep_last_seen_fresh(&mut self, now: Instant) {
        if self.probe {
            return;
        }
        if now.saturating_duration_since(self.last_written) < LAST_SEEN_EVERY {
            return;
        }
        self.last_written = now;
        let db = self.state.db.clone();
        let (org_id, device_id) = (self.handle.org_id, self.handle.device_id);
        let at = self.state.relay.wall(now);
        let (relay, handle) = (self.state.relay.clone(), self.handle.clone());
        tokio::spawn(async move {
            if let Err(error) = set_last_seen(&db, org_id, device_id, at).await {
                tracing::warn!(%error, "could not record last_seen_at");
            }
            signals::check_session(&relay, &db, &handle).await;
        });
    }

    /// Records that the device was heard from at `at` (an instant on the tokio clock).
    async fn write_last_seen(&self, at: Instant) {
        if self.probe {
            return;
        }
        let at = self.state.relay.wall(at);
        let written = set_last_seen(
            &self.state.db,
            self.handle.org_id,
            self.handle.device_id,
            at,
        )
        .await;
        if let Err(error) = written {
            tracing::warn!(%error, "could not record last_seen_at");
        }
    }
}

/// Resolves once the hub is shutting down. (The guard `wait_for` returns is not `Send`, so it must
/// not live in the caller's `select!`.)
async fn hub_stopping(stopping: &mut tokio::sync::watch::Receiver<bool>) {
    let _ = stopping.wait_for(|down| *down).await;
}

/// The commands that change something on the Mac, refused while maintenance is on: `turn.send`,
/// `thread.start`, `request.respond`, and the environment edits. `turn.lookup` is a read, and
/// `turn.interrupt` stops work rather than starting it, so both continue.
fn writes(method: RelayMethod) -> bool {
    matches!(
        method,
        RelayMethod::TurnSend
            | RelayMethod::ThreadStart
            | RelayMethod::RequestRespond
            | RelayMethod::EnvironmentCreate
            | RelayMethod::EnvironmentUpdate
            | RelayMethod::EnvironmentDelete
    )
}

/// Writes one frame, giving up if the device stops reading for as long as a dead link.
async fn write<S: LinkSocket>(socket: &mut S, message: &RelayMessage) -> Result<(), ()> {
    write_within(socket, message, DEAD_LINK).await
}

/// Writes one frame, giving up if the device stops reading for `patience`.
async fn write_within<S: LinkSocket>(
    socket: &mut S,
    message: &RelayMessage,
    patience: Duration,
) -> Result<(), ()> {
    // A relay frame is plain data, so encoding it cannot fail.
    let text = serde_json::to_string(message).map_err(|_| ())?;
    write_message(socket, Message::Text(text.into()), patience).await
}

async fn write_message<S: LinkSocket>(
    socket: &mut S,
    message: Message,
    patience: Duration,
) -> Result<(), ()> {
    match tokio::time::timeout(patience, socket.send(message)).await {
        Ok(Ok(())) => Ok(()),
        _ => Err(()),
    }
}

/// Writes the close's `error` frame, if any, then its close frame, each within `patience`. True
/// when the close frame was written, so the device may still answer it.
async fn send_close<S: LinkSocket>(socket: &mut S, close: &Close, patience: Duration) -> bool {
    if let Some(error) = &close.error {
        let _ = write_within(socket, error, patience).await;
    }
    let frame = CloseFrame {
        code: close.code,
        reason: close.reason.into(),
    };
    write_message(socket, Message::Close(Some(frame)), patience)
        .await
        .is_ok()
}

/// Gives the device a moment to answer our close frame with its own, so it sees the code before
/// the connection is dropped.
async fn await_peer_close<S: LinkSocket>(socket: &mut S) {
    let _ = tokio::time::timeout(CLOSE_GRACE, async {
        while let Some(Ok(message)) = socket.recv().await {
            if matches!(message, Message::Close(_)) {
                break;
            }
        }
    })
    .await;
}
