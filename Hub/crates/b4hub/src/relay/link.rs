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

use super::admission::{Checked, Failure};
use super::limits::IN_FLIGHT_RETRY;
use super::registry::{Close, Identity, LinkHandle, LiveLink, Outbound, Registration};
use super::registry::{CloseDisposition, Payload};
use super::{close_code, invalid_frame, route, PROTOCOL};
use crate::auth::{bearer_token, AuthedDevice};
use crate::error::ApiError;
use crate::instances;
use crate::maintenance;
use crate::serve::AppState;
use crate::signals;
use b4hub_core::protocol::ClientProtocol;
use b4hub_db::relay::{Admission, ProbeAdmission};

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
    let client = ClientProtocol::new(protocol);
    let session = bearer_token(&headers)
        .map(SessionKey::of)
        .ok_or_else(ApiError::unauthorized)?;
    let admission = Admission::open(&state.db, &session, client)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    state
        .relay
        .observe_floor(admission.floor())
        .map_err(|_| ApiError::internal())?;
    admission.commit().await?;
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
    // Both Axum outcomes own the same lifecycle guard. A failed handoff has no socket and
    // never enters serve_link, but its already committed instance claim still needs cleanup.
    let live = Arc::new(state.relay.track());
    let failed_live = Arc::clone(&live);
    let failed_state = state.clone();
    let failed_user = device.user_id;
    let cookie = state.instances.cookie();
    let mut response = upgrade
        .max_message_size(WIRE_MAX)
        .max_frame_size(WIRE_MAX)
        .on_failed_upgrade(move |_error| {
            tokio::spawn(async move {
                instances::release_if_unlinked(
                    &failed_state.db,
                    &failed_state.relay,
                    &failed_state.instances,
                    failed_user,
                )
                .await;
                // Normal drain includes the actual cleanup work, not just the rejected socket.
                drop(failed_live);
            });
        })
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
    let live = Arc::new(state.relay.track());
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
    _live: Arc<LiveLink>,
) {
    let relay = state.relay.clone();
    let min = relay.min_client_protocol();
    let probe = who.probe;
    let claimed_user = who.user_id;
    if protocol < min {
        if !probe {
            instances::release_if_unlinked(&state.db, &relay, &state.instances, claimed_user).await;
        }
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
    let admitted = async {
        let client = ClientProtocol::new(protocol);
        if probe {
            let mut native = ProbeAdmission::open(&state.db, client)
                .await
                .map_err(Failure::db)?;
            let registration = relay.register_probe(&mut native).map_err(|e| match e {
                super::registry::RegistrationRefusal::TooOld(min) => Failure::TooOld(min),
                _ => Failure::Unavailable,
            })?;
            let mut registered = Registered {
                state: state.clone(),
                handle: registration.handle.clone(),
                probe,
                done: false,
            };
            if let Err(error) = native.commit().await {
                registered.unregister(false);
                return Err(Failure::db(error));
            }
            Ok((registration, registered))
        } else {
            let key = who.session.as_ref().ok_or(Failure::Session)?;
            let mut native = Admission::open(&state.db, key, client)
                .await
                .map_err(Failure::db)?
                .ok_or(Failure::Session)?;
            let registration = relay
                .register_admitted(who, &mut native)
                .map_err(|e| match e {
                    super::registry::RegistrationRefusal::TooOld(min) => Failure::TooOld(min),
                    super::registry::RegistrationRefusal::SessionEnded => Failure::Session,
                    _ => Failure::Unavailable,
                })?;
            // Install exact-generation cleanup before the fallible DB commit and before hello.
            let registered =
                commit_device_registration(&state, registration.handle.clone(), native).await?;
            Ok((registration, registered))
        }
    };
    let (registration, mut registered) = match admitted.await {
        Ok(value) => value,
        Err(error) => {
            // The admission future has completed/dropped its transaction before cleanup takes
            // another lease. No registration may have been inserted; do not invent presence
            // or unregister an unrelated generation. Existing live links keep their claim.
            if !probe {
                instances::release_if_unlinked(&state.db, &relay, &state.instances, claimed_user)
                    .await;
            }
            if let Some(close) = error.close() {
                if send_close(&mut socket, &close, DEAD_LINK).await {
                    await_peer_close(&mut socket).await;
                }
            }
            return;
        }
    };
    let Registration {
        handle,
        mut outbound,
        mut closing,
        replaced,
        probe_closer: _probe_closer,
    } = registration;
    if !probe {
        tracing::info!(device=%handle.device_id,?role,replaced,"link open");
    }
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

    link.handle.discard_pending(&mut outbound);
    // The link is over. The device was last heard from when its last frame arrived, not when the
    // drop was noticed. That goes in the database before the device reads as offline, so anyone who
    // sees it offline (a command judging how recently it was seen) finds the time already there.
    link.write_last_seen(link.last_frame).await;
    // A Mac that went away on its own reads online for a grace, in case it is back at once; one
    // the hub closed for good (revoked, its session ended) is offline now.
    let linger = role == Role::Host
        && !relay.offline_grace().is_zero()
        && close.as_ref().is_none_or(|close| {
            close.code != close_code::REVOKED && close.disposition != CloseDisposition::Fence
        });
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

/// The short device register/COMMIT boundary, before any hello. The upgrade's instance claim
/// was committed already, so a failed admission commit owes the same claim/presence cleanup as
/// an ordinary link end, not merely removal of its local map entry.
async fn commit_device_registration(
    state: &AppState,
    handle: LinkHandle,
    native: Admission,
) -> Result<Registered, Failure> {
    let mut registered = Registered {
        state: state.clone(),
        handle,
        probe: false,
        done: false,
    };
    if let Err(error) = native.commit().await {
        registered.abandon().await;
        return Err(Failure::db(error));
    }
    Ok(registered)
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
    /// Complete an early failed registration without hello, grace or a shutdown flush. If a
    /// newer generation replaced it, neither that entry nor its still-live claim is touched.
    async fn abandon(&mut self) {
        let was_current = self.unregister(false);
        if self.probe || !was_current {
            return;
        }
        instances::release_if_unlinked(
            &self.state.db,
            &self.state.relay,
            &self.state.instances,
            self.handle.user_id,
        )
        .await;
        if self.handle.role == Role::Host {
            host_left(&self.state, &self.handle, false).await;
        }
    }

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
        let linger = false;
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

        macro_rules! admitted {
            ($work:expr) => {
                match $work {
                    Ok(value) => value,
                    Err(error) => return error.close(),
                }
            };
        }
        let mut watch_changes = self.state.relay.watch_changes();
        let is_host = self.handle.role == Role::Host;
        let mut told = Vec::new();
        admitted!(self.initial(socket).await);
        if is_host {
            (told, _) = self.state.relay.take_watching(self.handle.device_id);
            told = admitted!(self.write_watching(socket, told, Vec::new()).await);
        } else if self.probe {
            admitted!(
                self.write_direct(
                    socket,
                    &RelayMessage::Presence { hosts: Vec::new() },
                    1,
                    DEAD_LINK
                )
                .await
            );
        } else {
            admitted!(self.write_presence(socket).await);
        }
        if is_host && !self.replaced {
            self.state
                .relay
                .broadcast_presence(&self.state.db, self.handle.org_id, self.handle.user_id)
                .await;
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
                        admitted!(self.write_queued(socket, frame, CLOSE_GRACE).await);
                    }
                    return Some(Close::shutdown());
                }
                () = &mut dead => return Some(Close::silent()),
                queued = outbound.recv() => {
                    // The registry's handle keeps the sender alive as long as this link is
                    // registered, so `None` is not expected; treat it as the end.
                    let frame = queued?;
                    admitted!(self.write_queued(socket, frame, DEAD_LINK).await);
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
                        let RelayMessage::Watching{thread_ids,refresh}=watching else {unreachable!()};
                        told=admitted!(self.write_watching(socket,thread_ids,refresh).await);
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
                        Message::Text(text) => admitted!(self.on_text(text.as_str()).await),
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
                        admitted!(self.write_direct(socket,&reply,1,DEAD_LINK).await);
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
    async fn on_text(&self, text: &str) -> Result<Option<RelayMessage>, Failure> {
        let checked = Checked::open(&self.state.db, &self.state.relay, &self.handle).await?;
        checked.proof(1)?;
        checked.commit().await?;
        if self.state.relay.take_frame_panic() {
            panic!("a link task panicked (test seam)");
        }
        Ok(match serde_json::from_str::<RelayMessage>(text) {
            Ok(RelayMessage::Ping) => Some(RelayMessage::Pong {
                hub_time: self.state.relay.hub_time(),
            }),
            Ok(other) => self.on_frame(other).await?,
            // A command whose method is not one of the five is answered as a command, by id.
            // Anything else is not echoed: it may carry content the hub must not log or repeat.
            Err(_) => Some(
                route::unknown_command(text)
                    .unwrap_or_else(|| invalid_frame("the frame is not a valid relay message")),
            ),
        })
    }

    /// A well-formed frame other than `ping`. A command runs on its own task, so a slow Mac never
    /// holds up this link (or the link's other commands); a host's reply and event are matched at
    /// once. A client's `watch` is decided here, in order with its other watches and unwatches (a
    /// `watch` followed by an `unwatch` must end unwatched); it costs one indexed lookup.
    async fn on_frame(&self, message: RelayMessage) -> Result<Option<RelayMessage>, Failure> {
        let role = self.handle.role;
        Ok(match message {
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
                        return Ok(Some(RelayMessage::Reply {
                            id,
                            result: None,
                            error: Some(WireError {
                                code: refused.code.to_string(),
                                message: refused.message,
                                details: None,
                            }),
                        }));
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
                        return Ok(None);
                    }
                    tracing::warn!(
                        device = %self.handle.device_id,
                        method = method.as_str(),
                        outcome = "too_many_in_flight",
                        "command"
                    );
                    return Ok(Some(RelayMessage::Reply {
                        id,
                        result: None,
                        error: Some(route::rate_limited(IN_FLIGHT_RETRY)),
                    }));
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
                route::handle_reply(
                    &self.state.relay,
                    &self.state.db,
                    &self.handle,
                    &id,
                    result,
                    error,
                )
                .await?;
                None
            }
            RelayMessage::Watch { thread_id } if role == Role::Client => {
                route::handle_watch(&self.state.relay, &self.state.db, &self.handle, &thread_id)
                    .await
            }
            RelayMessage::Unwatch { thread_id } if role == Role::Client => {
                let checked =
                    Checked::open(&self.state.db, &self.state.relay, &self.handle).await?;
                checked.proof(1)?;
                self.state.relay.unwatch(&self.handle, &thread_id);
                checked.commit().await?;
                None
            }
            RelayMessage::Event { event } if role == Role::Host => {
                route::handle_event(&self.state.relay, &self.state.db, &self.handle, event).await?;
                None
            }
            _ => Some(invalid_frame("this frame is not accepted from a device")),
        })
    }

    /// Writes a frame from the queue within `patience`. An event arrives encoded (once, for every
    /// watcher) and is written as it is; its bytes are given back to the link's budget.
    async fn checked_until(&self, until: Instant) -> Result<Checked, Failure> {
        tokio::time::timeout_at(
            until,
            Checked::open(&self.state.db, &self.state.relay, &self.handle),
        )
        .await
        .map_err(|_| Failure::Unavailable)?
    }
    async fn write_admitted<S: LinkSocket>(
        &self,
        socket: &mut S,
        checked: &Checked,
        message: &RelayMessage,
        required: u32,
        until: Instant,
    ) -> Result<(), Failure> {
        checked.proof(required)?;
        let text = serde_json::to_string(message).map_err(|_| Failure::Socket)?;
        tokio::time::timeout_at(until, socket.send(Message::Text(text.into())))
            .await
            .map_err(|_| Failure::Socket)?
            .map_err(|_| Failure::Socket)
    }
    async fn write_direct<S: LinkSocket>(
        &self,
        socket: &mut S,
        message: &RelayMessage,
        required: u32,
        patience: Duration,
    ) -> Result<(), Failure> {
        let until = Instant::now() + patience;
        let checked = self.checked_until(until).await?;
        self.write_admitted(socket, &checked, message, required, until)
            .await?;
        tokio::time::timeout_at(until, checked.commit())
            .await
            .map_err(|_| Failure::Unavailable)?
    }
    async fn initial<S: LinkSocket>(&self, socket: &mut S) -> Result<(), Failure> {
        let until = Instant::now() + DEAD_LINK;
        let checked = self.checked_until(until).await?;
        let hello = RelayMessage::Hello {
            protocol: PROTOCOL,
            min_client_protocol: self.state.relay.min_client_protocol(),
            device_id: self.handle.device_id,
            role: self.handle.role,
            heartbeat_seconds: HEARTBEAT_SECONDS,
            hub_time: self.state.relay.hub_time(),
        };
        self.write_admitted(socket, &checked, &hello, 1, until)
            .await?;
        tokio::time::timeout_at(until, checked.commit())
            .await
            .map_err(|_| Failure::Unavailable)?
    }
    async fn write_presence<S: LinkSocket>(&self, socket: &mut S) -> Result<(), Failure> {
        let until = Instant::now() + DEAD_LINK;
        let mut checked = self.checked_until(until).await?;
        let hosts = tokio::time::timeout_at(until, checked.native()?.host_devices())
            .await
            .map_err(|_| Failure::Unavailable)?
            .map_err(Failure::db)?;
        let message = self.state.relay.presence_of(hosts);
        self.write_admitted(socket, &checked, &message, 1, until)
            .await?;
        tokio::time::timeout_at(until, checked.commit())
            .await
            .map_err(|_| Failure::Unavailable)?
    }
    async fn write_watching<S: LinkSocket>(
        &self,
        socket: &mut S,
        threads: Vec<String>,
        mut refresh: Vec<String>,
    ) -> Result<Vec<String>, Failure> {
        let until = Instant::now() + DEAD_LINK;
        let mut checked = self.checked_until(until).await?;
        let (threads, required) = tokio::time::timeout_at(
            until,
            route::watching(&self.state.relay, &mut checked, &self.handle, threads),
        )
        .await
        .map_err(|_| Failure::Unavailable)??;
        refresh.retain(|id| threads.contains(id));
        self.write_admitted(
            socket,
            &checked,
            &RelayMessage::Watching {
                thread_ids: threads.clone(),
                refresh,
            },
            required,
            until,
        )
        .await?;
        tokio::time::timeout_at(until, checked.commit())
            .await
            .map_err(|_| Failure::Unavailable)??;
        Ok(threads)
    }
    async fn write_queued<S: LinkSocket>(
        &self,
        socket: &mut S,
        frame: Outbound,
        patience: Duration,
    ) -> Result<(), Failure> {
        let Outbound::Protected(envelope) = frame else {
            return Err(Failure::Unavailable);
        };
        let until = Instant::now() + patience;
        let checked = self.checked_until(until).await?;
        self.state
            .relay
            .pass_queued_write_gate(&self.handle, until)
            .await;
        let (stamp, payload) = envelope.parts();
        // A pre-cut gap/content envelope fences this queue even for a capable peer: reconnect
        // and replay, rather than crossing a dropped gap. This is retriable 1001, never 4002
        // unless the native client itself is too old. No queued/missed shutdown flush follows.
        envelope.check_for_write(self.handle.generation, checked.floor().minimum())?;
        checked.proof(stamp.required)?;
        match payload {
            Payload::Message(message) => {
                self.write_admitted(socket, &checked, message, stamp.required, until)
                    .await?
            }
            Payload::Event(text) => {
                tokio::time::timeout_at(until, socket.send(Message::Text(text.to_string().into())))
                    .await
                    .map_err(|_| Failure::Socket)?
                    .map_err(|_| Failure::Socket)?
            }
        }
        tokio::time::timeout_at(until, checked.commit())
            .await
            .map_err(|_| Failure::Unavailable)?
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

#[cfg(test)]
mod registration_commit_tests {
    use super::*;
    use b4hub_db::instances::{self as native_instances, Claim};
    use b4hub_db::{devices, orgs, Db};
    use sqlx::PgPool;
    use uuid::Uuid;

    /// A native connection-loss control at the actual private COMMIT boundary, not a fake
    /// commit result or full socket fault test. No production failpoint is installed.
    #[sqlx::test(migrations = false)]
    async fn failed_registration_commit_releases_the_live_instance_claim(pool: PgPool) {
        let mut admin_url = url::Url::parse(&std::env::var("DATABASE_URL").unwrap()).unwrap();
        let options = pool.connect_options();
        admin_url.set_path(&format!("/{}", options.get_database().unwrap()));
        let mut app_url = admin_url.clone();
        app_url.set_username("b4hub_app").unwrap();
        app_url.set_password(Some("pw-test")).unwrap();
        b4hub_db::migrate::run(admin_url.as_str(), app_url.as_str())
            .await
            .unwrap();
        let admin = Db::connect(admin_url.as_str()).await.unwrap();
        let app = Db::connect(app_url.as_str()).await.unwrap();
        let state = AppState::new(
            app.clone(),
            crate::config::Config {
                signup: crate::config::Signup::Closed,
                rp_id: "local.b4.run".into(),
                public_url: None,
                secret_key: [7; 32],
                apple: None,
                trust_forwarded_for: false,
            },
        )
        .unwrap();
        let user = orgs::seed(
            &admin,
            "commit-cleanup",
            "Fixture",
            "owner",
            "Owner",
            "owner@example.test",
        )
        .await
        .unwrap();
        let code = devices::create_enrollment_code(
            &admin,
            user.org_id,
            user.user_id,
            Duration::from_secs(60),
        )
        .await
        .unwrap();
        let enrolled = devices::redeem(&app, &code, "Mac", "macos").await.unwrap();
        let key = SessionKey::of(&enrolled.token);
        let original = state.instances.id();
        let other = Uuid::new_v4();
        native_instances::register(&app, original, None)
            .await
            .unwrap();
        native_instances::register(&app, other, None).await.unwrap();
        let alive = Duration::from_secs(86400); // A live owner, never an expiry-based reclaim.
        assert_eq!(
            native_instances::claim_user(&app, user.user_id, original, alive)
                .await
                .unwrap(),
            Claim::Ours
        );
        assert_eq!(
            native_instances::claim_user(&app, user.user_id, other, alive)
                .await
                .unwrap(),
            Claim::Other(original)
        );
        let mut native = Admission::open(&app, &key, ClientProtocol::SUPPORTED)
            .await
            .unwrap()
            .unwrap();
        let identity = Identity {
            device_id: enrolled.device_id,
            name: "Mac".into(),
            role: Role::Host,
            user_id: user.user_id,
            org_id: user.org_id,
            session: Some(key),
            probe: false,
        };
        let mut registration = state
            .relay
            .register_admitted(identity, &mut native)
            .unwrap();
        assert!(
            registration.outbound.try_recv().is_err(),
            "no pre-hello content was queued"
        );
        let database = options.get_database().unwrap();
        // This fixture has one idle application transaction. Capture and recheck its exact
        // native birth tuple; never terminate a whole role, another database or a replacement.
        let candidates:Vec<(i32,String)>=sqlx::query_as("SELECT pid,backend_start::text FROM pg_stat_activity WHERE datname=$1 AND usename='b4hub_app' AND state='idle in transaction'")
            .bind(database).fetch_all(&admin.pool).await.unwrap();
        assert_eq!(candidates.len(), 1, "exactly the owned admission backend");
        let (pid, birth) = &candidates[0];
        let terminated:Option<bool>=sqlx::query_scalar("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid=$1 AND backend_start::text=$2 AND datname=$3 AND usename='b4hub_app' AND state='idle in transaction'")
            .bind(pid).bind(birth).bind(database).fetch_optional(&admin.pool).await.unwrap();
        assert_eq!(terminated, Some(true));
        let gone=tokio::time::timeout(Duration::from_secs(5),async {
            loop {
                let exists:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND backend_start::text=$2 AND datname=$3)")
                    .bind(pid).bind(birth).bind(database).fetch_one(&admin.pool).await.unwrap();
                if !exists{break;}
                tokio::task::yield_now().await;
            }
        }).await;
        let outcome = commit_device_registration(&state, registration.handle.clone(), native).await;
        assert!(
            gone.is_ok(),
            "the exact terminated native backend must be absent"
        );
        assert!(
            matches!(outcome, Err(Failure::Unavailable)),
            "actual native COMMIT must fail"
        );
        assert!(!state.relay.online(enrolled.device_id));
        assert_eq!(
            native_instances::owner_of(&app, user.user_id)
                .await
                .unwrap(),
            None,
            "the failed registration must release its committed upgrade claim"
        );
        assert_eq!(
            native_instances::claim_user(&app, user.user_id, other, alive)
                .await
                .unwrap(),
            Claim::Ours
        );
        let current: bool = sqlx::query_scalar(
            "SELECT heartbeat_at>now()-interval '1 day' FROM hub_instances WHERE instance_id=$1",
        )
        .bind(original)
        .fetch_one(&admin.pool)
        .await
        .unwrap();
        assert!(current, "reclaim did not use heartbeat expiry");
        native_instances::release_user(&app, user.user_id, other)
            .await
            .unwrap();
        // A late cleanup of an older registration must not release a replacement's claim.
        assert_eq!(
            native_instances::claim_user(&app, user.user_id, original, alive)
                .await
                .unwrap(),
            Claim::Ours
        );
        let who = || Identity {
            device_id: enrolled.device_id,
            name: "Mac".into(),
            role: Role::Host,
            user_id: user.user_id,
            org_id: user.org_id,
            session: Some(key),
            probe: false,
        };
        let mut older_native = Admission::open(&app, &key, ClientProtocol::SUPPORTED)
            .await
            .unwrap()
            .unwrap();
        let older = state
            .relay
            .register_admitted(who(), &mut older_native)
            .unwrap();
        let mut older_owner =
            commit_device_registration(&state, older.handle.clone(), older_native)
                .await
                .unwrap();
        let mut newer_native = Admission::open(&app, &key, ClientProtocol::SUPPORTED)
            .await
            .unwrap()
            .unwrap();
        let newer = state
            .relay
            .register_admitted(who(), &mut newer_native)
            .unwrap();
        let mut newer_owner =
            commit_device_registration(&state, newer.handle.clone(), newer_native)
                .await
                .unwrap();
        older_owner.abandon().await;
        assert_eq!(
            state.relay.handle(enrolled.device_id).unwrap().generation,
            newer.handle.generation
        );
        assert_eq!(
            native_instances::owner_of(&app, user.user_id)
                .await
                .unwrap(),
            Some(original)
        );
        newer_owner.abandon().await;
        assert_eq!(
            native_instances::owner_of(&app, user.user_id)
                .await
                .unwrap(),
            None
        );
        drop(older);
        drop(newer);
        drop(older_owner);
        drop(newer_owner);
        drop(registration);
        drop(state);
        app.pool.close().await;
        admin.pool.close().await;
    }
}
