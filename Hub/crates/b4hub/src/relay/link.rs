//! `GET /v1/devices/self/link`: the endpoint, and the task that serves one link.
//!
//! The handler authenticates (the bearer token, before any upgrade, so a bad token is a plain
//! `401` and no socket), applies the upgrade rate limit, and upgrades. One task then serves the
//! link, reading and writing: it says `hello`, answers `ping` with `pong`, writes what other
//! tasks queued through the registry, and closes the link when it has been silent for
//! `DEAD_LINK`, when something asks it to ([`Close`]), or when the hub shuts down. When it ends it
//! leaves the registry, records the time of the link's last frame as `last_seen_at`, and, for a
//! Mac, tells the user's phones.

use axum::extract::ws::rejection::WebSocketUpgradeRejection;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::{IntoResponse, Response};
use b4hub_core::relay::{RelayMessage, Role, DEAD_LINK, HEARTBEAT_SECONDS, HOST_FRAME_MAX};
use b4hub_db::devices::{self, Platform};
use b4hub_db::relay::set_last_seen;
use std::time::Duration;
use tokio::time::Instant;

use super::registry::{Close, Identity, LinkHandle, LiveLink, Registration};
use super::{invalid_frame, route, PROTOCOL};
use crate::auth::AuthedDevice;
use crate::error::ApiError;
use crate::serve::AppState;

/// The header a device names its link protocol in; a missing header counts as 1.
const PROTOCOL_HEADER: &str = "b4-protocol";

/// How often a link that stays up writes `last_seen_at`, the same cadence as the per-request
/// throttle in `auth`.
const LAST_SEEN_EVERY: Duration = Duration::from_secs(60);

/// How long the hub waits, after sending a close frame, for the device's own before it drops the
/// connection.
const CLOSE_GRACE: Duration = Duration::from_secs(2);

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
    let who = Identity {
        device_id: device.device_id,
        name: info.device_name,
        role: role_of(device.platform),
        user_id: device.user_id,
        org_id: device.org_id,
    };
    let live = state.relay.track();
    Ok(upgrade
        .max_message_size(HOST_FRAME_MAX)
        .max_frame_size(HOST_FRAME_MAX)
        .on_upgrade(move |socket| serve_link(state, who, protocol, socket, live))
        .into_response())
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
async fn serve_link(
    state: AppState,
    who: Identity,
    protocol: u32,
    mut socket: WebSocket,
    _live: LiveLink,
) {
    let relay = state.relay.clone();
    let min = relay.min_client_protocol();
    if protocol < min {
        tracing::info!(device = %who.device_id, protocol, min, "link refused: client too old");
        if send_close(&mut socket, &Close::client_too_old(min)).await {
            await_peer_close(&mut socket).await;
        }
        return;
    }

    relay.pass_gate().await;
    let role = who.role;
    let identity = (who.org_id, who.device_id);
    let Registration {
        handle,
        mut outbound,
        mut closing,
        replaced,
    } = relay.register(who);
    tracing::info!(device = %handle.device_id, ?role, replaced, "link open");

    let mut link = Link {
        state,
        handle,
        replaced,
        last_frame: Instant::now(),
        last_written: Instant::now(),
        peer_closed: false,
    };
    // The upgrade checked that the device is not revoked, but a revocation can land between that
    // check and the registration above, when `close` finds no link to close. Registering first and
    // looking again closes that window: a revocation after this look finds the registered link.
    let revoked = matches!(
        devices::me(&link.state.db, identity.0, identity.1).await,
        Ok(None)
    );
    let close = if revoked {
        Some(Close::revoked())
    } else {
        link.run(&mut socket, &mut outbound, &mut closing).await
    };

    // The link is over. The device was last heard from when its last frame arrived, not when the
    // drop was noticed. That goes in the database before the device reads as offline, so anyone who
    // sees it offline (a command judging how recently it was seen) finds the time already there.
    link.write_last_seen(link.last_frame).await;
    let was_current = relay.unregister(link.handle.device_id, link.handle.generation);
    let closed = match &close {
        Some(close) => send_close(&mut socket, close).await,
        None => false,
    };
    if was_current && role == Role::Host {
        relay
            .broadcast_presence(&link.state.db, link.handle.org_id, link.handle.user_id)
            .await;
    }
    if closed || link.peer_closed {
        await_peer_close(&mut socket).await;
    }
    tracing::info!(
        device = %link.handle.device_id,
        ?role,
        code = close.as_ref().map(|close| close.code),
        "link closed"
    );
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
}

impl Link {
    /// Serves the link until it ends. `Some(close)` is a close the hub chose (and still owes the
    /// device); `None` means the device went away or the socket failed.
    async fn run(
        &mut self,
        socket: &mut WebSocket,
        outbound: &mut tokio::sync::mpsc::Receiver<RelayMessage>,
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

        let mut stopping = self.state.shutdown.subscribe();
        let dead = tokio::time::sleep_until(self.last_frame + DEAD_LINK);
        tokio::pin!(dead);
        loop {
            tokio::select! {
                closing = &mut *closing => {
                    return Some(closing.unwrap_or_else(|_| Close::shutdown()));
                }
                () = hub_stopping(&mut stopping) => return Some(Close::shutdown()),
                () = &mut dead => return Some(Close::silent()),
                queued = outbound.recv() => {
                    // The registry's handle keeps the sender alive as long as this link is
                    // registered, so `None` is not expected; treat it as the end.
                    let message = queued?;
                    write(socket, &message).await.ok()?;
                }
                incoming = socket.recv() => {
                    let message = incoming?.ok()?;
                    let now = Instant::now();
                    self.last_frame = now;
                    dead.as_mut().reset(now + DEAD_LINK);
                    self.keep_last_seen_fresh(now);
                    let reply = match message {
                        Message::Text(text) => self.on_text(text.as_str()),
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

    /// Handles one text frame; the returned frame, if any, is written back at once.
    fn on_text(&self, text: &str) -> Option<RelayMessage> {
        match serde_json::from_str::<RelayMessage>(text) {
            Ok(RelayMessage::Ping) => Some(RelayMessage::Pong {
                hub_time: self.state.relay.hub_time(),
            }),
            Ok(other) => self.on_frame(other),
            // A command whose method is not one of the five is answered as a command, by id.
            // Anything else is not echoed: it may carry content the hub must not log or repeat.
            Err(_) => Some(
                route::unknown_command(text)
                    .unwrap_or_else(|| invalid_frame("the frame is not a valid relay message")),
            ),
        }
    }

    /// A well-formed frame other than `ping`. A command runs on its own task, so a slow Mac never
    /// holds up this link (or the link's other commands); a host's reply is matched at once.
    /// Watches and events are routed here as they are implemented.
    fn on_frame(&self, message: RelayMessage) -> Option<RelayMessage> {
        match message {
            RelayMessage::Command {
                id, method, params, ..
            } => {
                let relay = self.state.relay.clone();
                let db = self.state.db.clone();
                let caller = self.handle.clone();
                tokio::spawn(async move {
                    route::handle_command(&relay, &db, &caller, id, method, params).await;
                });
                None
            }
            RelayMessage::Reply { id, result, error } if self.handle.role == Role::Host => {
                route::handle_reply(&self.state.relay, &self.handle, &id, result, error);
                None
            }
            _ => Some(invalid_frame("this frame is not accepted from a device")),
        }
    }

    /// Writes `last_seen_at` at most once a minute while the link is up, off the link's task so
    /// a slow database never delays a heartbeat.
    fn keep_last_seen_fresh(&mut self, now: Instant) {
        if now.saturating_duration_since(self.last_written) < LAST_SEEN_EVERY {
            return;
        }
        self.last_written = now;
        let db = self.state.db.clone();
        let (org_id, device_id) = (self.handle.org_id, self.handle.device_id);
        let at = self.state.relay.wall(now);
        tokio::spawn(async move {
            if let Err(error) = set_last_seen(&db, org_id, device_id, at).await {
                tracing::warn!(%error, "could not record last_seen_at");
            }
        });
    }

    /// Records that the device was heard from at `at` (an instant on the tokio clock).
    async fn write_last_seen(&self, at: Instant) {
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

/// Writes one frame, giving up if the device stops reading for as long as a dead link.
async fn write(socket: &mut WebSocket, message: &RelayMessage) -> Result<(), ()> {
    // A relay frame is plain data, so encoding it cannot fail.
    let text = serde_json::to_string(message).map_err(|_| ())?;
    write_message(socket, Message::Text(text.into())).await
}

async fn write_message(socket: &mut WebSocket, message: Message) -> Result<(), ()> {
    match tokio::time::timeout(DEAD_LINK, socket.send(message)).await {
        Ok(Ok(())) => Ok(()),
        _ => Err(()),
    }
}

/// Writes the close's `error` frame, if any, then its close frame. True when the close frame was
/// written, so the device may still answer it.
async fn send_close(socket: &mut WebSocket, close: &Close) -> bool {
    if let Some(error) = &close.error {
        let _ = write(socket, error).await;
    }
    let frame = CloseFrame {
        code: close.code,
        reason: close.reason.into(),
    };
    write_message(socket, Message::Close(Some(frame)))
        .await
        .is_ok()
}

/// Gives the device a moment to answer our close frame with its own, so it sees the code before
/// the connection is dropped.
async fn await_peer_close(socket: &mut WebSocket) {
    let _ = tokio::time::timeout(CLOSE_GRACE, async {
        while let Some(Ok(message)) = socket.recv().await {
            if matches!(message, Message::Close(_)) {
                break;
            }
        }
    })
    .await;
}
