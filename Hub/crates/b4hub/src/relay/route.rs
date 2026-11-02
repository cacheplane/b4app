//! Commands: a client's `command` taken to the Mac that owns what it names, and the Mac's `reply`
//! taken back. `Hub/API.md` ("Commands") is the reference.
//!
//! For each command, [`handle_command`] applies, in order:
//!
//! 1. the role (only a client link sends commands) and the method (an allowlist; an unknown one
//!    never decodes, and [`unknown_command`] answers it), then the rate limits;
//! 2. the lookup of the thread, the runtime request's thread, or the project, within the caller's
//!    org and user (a thread started moments ago through this hub is found in the pending-thread
//!    map first); a miss is `not_found`;
//! 3. the owner: it must be a non-revoked `macos` device of the caller's user, or `not_found`;
//! 4. for `request.respond`, `stale_runtime_request` at once when the request is no longer
//!    `pending`;
//! 5. delivery: an online owner gets the command with `deadline` and `from` stamped; an offline
//!    one gets `turn.interrupt` and `request.respond` held until it is back (within 60 s of when it
//!    was last heard from) and is otherwise `device_offline`;
//! 6. the wait for the reply, or `relay_timeout`.
//!
//! A command is in flight from the moment it passes the limits until it is answered, keyed by the
//! caller *device* and the command `id`: a second command with the same key attaches to the first
//! (it is not forwarded again), and the answer goes to whatever link the caller device has when it
//! arrives. Nothing here is stored; a hub restart forgets it all, and the phone's resend of the same
//! `id` is then forwarded afresh (the Mac recognises the id).
//!
//! The hub logs each command's method, outcome, and latency, never its params or result.

use std::collections::HashMap;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use b4hub_core::relay::{
    From, RelayMessage, RelayMethod, Role, WireError, COMMAND_DEADLINE, HELD_MAX, HOLD_WINDOW,
    PENDING_THREAD_TTL, REPLY_WAIT_OTHER, REPLY_WAIT_START,
};
use b4hub_db::relay::{owner_device, owner_of_project, owner_of_request, owner_of_thread, Owner};
use b4hub_db::Db;
use serde_json::{json, Value};
use tokio::sync::oneshot;
use tokio::time::Instant;
use uuid::Uuid;

use super::limits::{RateWithBurst, SlidingWindow, COMMAND_WINDOW, STARTS_PER_WINDOW};
use super::{rfc3339_millis, LinkHandle, Relay};
use crate::error::relay_code;

/// The reused codes a command can be refused with besides the relay's own (`relay_code`).
pub mod code {
    /// No such row, another user's or org's, an owner that may not receive commands, an unknown
    /// method, or a command from a host: all the same answer.
    pub const NOT_FOUND: &str = "not_found";
    /// The runtime request was already answered.
    pub const STALE_RUNTIME_REQUEST: &str = "stale_runtime_request";
    /// The hub could not read what it needed to route the command.
    pub const INTERNAL_ERROR: &str = "internal_error";
}

/// What a host answered to one command.
#[derive(Debug, Clone)]
struct Answer {
    result: Option<Value>,
    error: Option<WireError>,
}

impl Answer {
    fn refused(error: WireError) -> Answer {
        Answer {
            result: None,
            error: Some(error),
        }
    }
}

/// One command in flight. `host` and `reply` are set once it is forwarded.
struct InFlight {
    host: Option<Uuid>,
    reply: Option<oneshot::Sender<Answer>>,
}

/// A thread a `thread.start` was routed for, before its row reaches the hub.
struct PendingThread {
    owner: Uuid,
    until: Instant,
}

/// The router's in-memory state, kept in the [`Relay`].
pub struct Commands {
    /// Keyed by (caller device, command id).
    in_flight: Mutex<HashMap<(Uuid, String), InFlight>>,
    /// Keyed by (user, thread id): the Mac a `thread.start` went to.
    pending_threads: Mutex<HashMap<(Uuid, String), PendingThread>>,
    /// How many commands are held for each offline host.
    held: Mutex<HashMap<Uuid, usize>>,
    per_device: RateWithBurst,
    per_user: SlidingWindow,
}

impl Default for Commands {
    fn default() -> Commands {
        Commands {
            in_flight: Mutex::default(),
            pending_threads: Mutex::default(),
            held: Mutex::default(),
            per_device: RateWithBurst::commands(),
            per_user: SlidingWindow::new(STARTS_PER_WINDOW, COMMAND_WINDOW),
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Commands {
    /// Counts the command against the caller device's limit and, for `turn.send` and
    /// `thread.start`, its user's. `Err` is how long to wait. A command the user's limit refuses
    /// has still been counted against the device's.
    fn check_limits(&self, caller: &LinkHandle, method: RelayMethod) -> Result<(), Duration> {
        let now = Instant::now();
        self.per_device.hit(caller.device_id, now)?;
        if starts_a_turn(method) {
            self.per_user.hit(caller.user_id, now)?;
        }
        Ok(())
    }

    fn remember_thread(&self, user_id: Uuid, thread_id: String, owner: Uuid) {
        let now = Instant::now();
        let mut pending = lock(&self.pending_threads);
        pending.retain(|_, thread| thread.until > now);
        pending.insert(
            (user_id, thread_id),
            PendingThread {
                owner,
                until: now + PENDING_THREAD_TTL,
            },
        );
    }

    fn pending_thread(&self, user_id: Uuid, thread_id: &str) -> Option<Uuid> {
        let key = (user_id, thread_id.to_string());
        let mut pending = lock(&self.pending_threads);
        match pending.get(&key) {
            Some(thread) if thread.until > Instant::now() => Some(thread.owner),
            Some(_) => {
                pending.remove(&key);
                None
            }
            None => None,
        }
    }

    /// Takes the reply senders of every command `id` forwarded to `host` and still waiting.
    fn answered(&self, host: Uuid, id: &str) -> Vec<oneshot::Sender<Answer>> {
        lock(&self.in_flight)
            .iter_mut()
            .filter(|((_, key_id), entry)| key_id == id && entry.host == Some(host))
            .filter_map(|(_, entry)| entry.reply.take())
            .collect()
    }
}

/// A command's place in the in-flight map, given up when the command is answered (or its task is
/// dropped).
struct Claim<'a> {
    commands: &'a Commands,
    key: (Uuid, String),
}

impl<'a> Claim<'a> {
    /// `None` when the same caller device already has a command `id` in flight.
    fn take(commands: &'a Commands, caller: Uuid, id: &str) -> Option<Claim<'a>> {
        let key = (caller, id.to_string());
        let mut in_flight = lock(&commands.in_flight);
        if in_flight.contains_key(&key) {
            return None;
        }
        in_flight.insert(
            key.clone(),
            InFlight {
                host: None,
                reply: None,
            },
        );
        Some(Claim { commands, key })
    }

    /// Records that the command is about to be forwarded to `host`, whose reply goes to `reply`.
    fn forwarding(&self, host: Uuid, reply: oneshot::Sender<Answer>) {
        if let Some(entry) = lock(&self.commands.in_flight).get_mut(&self.key) {
            entry.host = Some(host);
            entry.reply = Some(reply);
        }
    }
}

impl Drop for Claim<'_> {
    fn drop(&mut self) {
        lock(&self.commands.in_flight).remove(&self.key);
    }
}

/// One of the [`HELD_MAX`] places for commands held for an offline host.
struct HeldSlot<'a> {
    commands: &'a Commands,
    host: Uuid,
}

impl<'a> HeldSlot<'a> {
    fn take(commands: &'a Commands, host: Uuid) -> Option<HeldSlot<'a>> {
        let mut held = lock(&commands.held);
        let count = held.entry(host).or_default();
        if *count >= HELD_MAX {
            return None;
        }
        *count += 1;
        Some(HeldSlot { commands, host })
    }
}

impl Drop for HeldSlot<'_> {
    fn drop(&mut self) {
        let mut held = lock(&self.commands.held);
        if let Some(count) = held.get_mut(&self.host) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                held.remove(&self.host);
            }
        }
    }
}

impl Relay {
    /// The Mac a `thread.start` for `thread_id` was routed to by one of `user_id`'s devices in the
    /// last [`PENDING_THREAD_TTL`], before the thread's row reached the hub. Commands consult it
    /// before the thread lookup; so does `watch`.
    pub fn pending_thread_owner(&self, user_id: Uuid, thread_id: &str) -> Option<Uuid> {
        self.commands().pending_thread(user_id, thread_id)
    }

    /// How many commands are held for the offline host `host`.
    pub fn held(&self, host: Uuid) -> usize {
        lock(&self.commands().held).get(&host).copied().unwrap_or(0)
    }
}

/// Routes one command from `caller` and sends the answer to the caller device's current link.
/// It runs until the command is answered (up to the reply wait, plus a hold), so the link spawns
/// it rather than awaiting it.
pub async fn handle_command(
    relay: &Relay,
    db: &Db,
    caller: &LinkHandle,
    id: String,
    method: RelayMethod,
    params: Value,
) {
    let started = Instant::now();
    let Some(answer) = route(relay, db, caller, &id, method, params).await else {
        tracing::info!(method = method.as_str(), outcome = "attached", "command");
        return;
    };
    let outcome = answer
        .error
        .as_ref()
        .map_or("ok", |error| error.code.as_str());
    let latency_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    tracing::info!(method = method.as_str(), outcome, latency_ms, "command");
    // The caller may have linked again meanwhile; then the answer goes to the new link. A caller
    // with no link misses it and settles the command another way (the phone's `turn.lookup`).
    let _ = relay.send(
        caller.device_id,
        RelayMessage::Reply {
            id,
            result: answer.result,
            error: answer.error,
        },
    );
}

/// A host's `reply`: answers the commands `id` forwarded to it that are still waiting. A reply
/// that nothing waits for (too late, or never asked) is dropped.
pub fn handle_reply(
    relay: &Relay,
    host: &LinkHandle,
    id: &str,
    result: Option<Value>,
    error: Option<WireError>,
) {
    let answer = Answer { result, error };
    let waiting = relay.commands().answered(host.device_id, id);
    if waiting.is_empty() {
        tracing::debug!("dropped a reply nothing waits for");
    }
    for reply in waiting {
        let _ = reply.send(answer.clone());
    }
}

/// The answer to a frame that did not decode but is a `command` with an `id`: its method is not
/// one of the five, so it is `not_found`, as an unknown target would be. `None` for anything else.
pub fn unknown_command(text: &str) -> Option<RelayMessage> {
    let frame: Value = serde_json::from_str(text).ok()?;
    if frame.get("type").and_then(Value::as_str) != Some("command") {
        return None;
    }
    let id = frame.get("id").and_then(Value::as_str)?;
    tracing::info!(method = "unknown", outcome = code::NOT_FOUND, "command");
    Some(RelayMessage::Reply {
        id: id.to_string(),
        result: None,
        error: Some(not_found()),
    })
}

/// `None` when the command attached to one already in flight, which will be answered instead.
async fn route(
    relay: &Relay,
    db: &Db,
    caller: &LinkHandle,
    id: &str,
    method: RelayMethod,
    params: Value,
) -> Option<Answer> {
    if caller.role != Role::Client {
        return Some(Answer::refused(not_found()));
    }
    let commands = relay.commands();
    if let Err(wait) = commands.check_limits(caller, method) {
        tracing::warn!(device = %caller.device_id, method = method.as_str(), "command rate limit hit");
        return Some(Answer::refused(rate_limited(wait)));
    }
    let claim = Claim::take(commands, caller.device_id, id)?;
    Some(
        deliver(relay, db, caller, &claim, id, method, params)
            .await
            .unwrap_or_else(Answer::refused),
    )
}

async fn deliver(
    relay: &Relay,
    db: &Db,
    caller: &LinkHandle,
    claim: &Claim<'_>,
    id: &str,
    method: RelayMethod,
    params: Value,
) -> Result<Answer, WireError> {
    let mut owner = find_owner(relay, db, caller, method, &params).await?;
    if !relay.online(owner.device_id) {
        // Read the owner again now that it reads offline: its `last_seen_at` is then the last
        // frame it sent, which is what the hold window and the refusal's details are about.
        owner = eligible(caller, reread(db, caller, owner.device_id).await?)?;
        if !holdable(method) {
            return Err(device_offline(&owner));
        }
        hold(relay, &owner).await?;
    }
    forward(relay, caller, claim, id, method, params, &owner).await
}

/// Steps 2 to 4: the owner of what the command names, if the caller may reach it.
async fn find_owner(
    relay: &Relay,
    db: &Db,
    caller: &LinkHandle,
    method: RelayMethod,
    params: &Value,
) -> Result<Owner, WireError> {
    let (org, user) = (caller.org_id, caller.user_id);
    match method {
        RelayMethod::TurnSend | RelayMethod::TurnInterrupt | RelayMethod::TurnLookup => {
            let thread_id = param(params, "threadId")?;
            let found = match relay.pending_thread_owner(user, thread_id) {
                Some(device) => owner_device(db, org, user, device).await,
                None => owner_of_thread(db, org, user, thread_id).await,
            };
            eligible(caller, found.map_err(lookup_failed)?.ok_or_else(not_found)?)
        }
        RelayMethod::RequestRespond => {
            let request_id = param(params, "requestId")?;
            let found = owner_of_request(db, org, user, request_id)
                .await
                .map_err(lookup_failed)?
                .ok_or_else(not_found)?;
            let owner = eligible(caller, found.owner)?;
            // The Mac stays the authority (a request with no state is forwarded); this only saves
            // the round trip for one the hub already knows was answered.
            match found.state.as_deref() {
                Some(state) if state != "pending" => Err(stale_runtime_request()),
                _ => Ok(owner),
            }
        }
        RelayMethod::ThreadStart => {
            let project_id = param(params, "projectId")?;
            let found = owner_of_project(db, org, user, project_id)
                .await
                .map_err(lookup_failed)?;
            eligible(caller, found.ok_or_else(not_found)?)
        }
    }
}

async fn reread(db: &Db, caller: &LinkHandle, device_id: Uuid) -> Result<Owner, WireError> {
    owner_device(db, caller.org_id, caller.user_id, device_id)
        .await
        .map_err(lookup_failed)?
        .ok_or_else(not_found)
}

/// Step 3: only a non-revoked `macos` device of the caller's own user receives its commands.
fn eligible(caller: &LinkHandle, owner: Owner) -> Result<Owner, WireError> {
    if owner.user_id == caller.user_id && owner.platform == "macos" && !owner.revoked {
        Ok(owner)
    } else {
        Err(not_found())
    }
}

/// Waits for the offline `owner` to link again, for as long as it was last heard from less than
/// [`HOLD_WINDOW`] ago, taking one of its [`HELD_MAX`] places meanwhile. `Err` is the
/// `device_offline` to answer: never seen, seen too long ago, no place left, or the window ran out.
async fn hold(relay: &Relay, owner: &Owner) -> Result<(), WireError> {
    // Subscribe before looking, so a registration in between is not missed.
    let mut registered = relay.registrations();
    if relay.online(owner.device_id) {
        return Ok(());
    }
    let left = owner
        .last_seen_at
        .and_then(|seen| (seen + HOLD_WINDOW).duration_since(relay.wall_now()).ok())
        .unwrap_or(Duration::ZERO);
    if left.is_zero() {
        return Err(device_offline(owner));
    }
    let Some(_slot) = HeldSlot::take(relay.commands(), owner.device_id) else {
        tracing::warn!(host = %owner.device_id, "held command limit hit");
        return Err(device_offline(owner));
    };
    let until = Instant::now() + left;
    loop {
        tokio::select! {
            changed = registered.changed() => {
                if changed.is_err() {
                    return Err(device_offline(owner));
                }
                if relay.online(owner.device_id) {
                    return Ok(());
                }
            }
            () = tokio::time::sleep_until(until) => return Err(device_offline(owner)),
        }
    }
}

/// Step 5 and 6 for an online owner: stamp, forward, wait.
async fn forward(
    relay: &Relay,
    caller: &LinkHandle,
    claim: &Claim<'_>,
    id: &str,
    method: RelayMethod,
    params: Value,
    owner: &Owner,
) -> Result<Answer, WireError> {
    let started_thread = match method {
        RelayMethod::ThreadStart => params
            .get("threadId")
            .and_then(Value::as_str)
            .map(str::to_string),
        _ => None,
    };
    let (reply, answered) = oneshot::channel();
    claim.forwarding(owner.device_id, reply);
    let command = RelayMessage::Command {
        id: id.to_string(),
        method,
        params,
        deadline: Some(rfc3339_millis(relay.wall_now() + COMMAND_DEADLINE)),
        from: Some(From {
            device_id: caller.device_id,
            name: caller.name.clone(),
        }),
    };
    // Offline (it dropped since we looked) or a full queue: either way it did not reach the Mac.
    relay
        .send(owner.device_id, command)
        .map_err(|_| device_offline(owner))?;
    if let Some(thread_id) = started_thread {
        relay
            .commands()
            .remember_thread(caller.user_id, thread_id, owner.device_id);
    }
    let wait = if starts_a_turn(method) {
        REPLY_WAIT_START
    } else {
        REPLY_WAIT_OTHER
    };
    match tokio::time::timeout(wait, answered).await {
        Ok(Ok(answer)) => Ok(answer),
        _ => Err(relay_timeout()),
    }
}

/// `turn.send` and `thread.start`: never held, waited on longest, and limited per user.
fn starts_a_turn(method: RelayMethod) -> bool {
    matches!(method, RelayMethod::TurnSend | RelayMethod::ThreadStart)
}

/// Only these wait for an offline Mac that was seen within the hold window.
fn holdable(method: RelayMethod) -> bool {
    matches!(
        method,
        RelayMethod::TurnInterrupt | RelayMethod::RequestRespond
    )
}

/// A string param the hub routes by; a missing one names nothing, so `not_found`.
fn param<'a>(params: &'a Value, name: &str) -> Result<&'a str, WireError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(not_found)
}

fn wire(code: &str, message: &str, details: Option<Value>) -> WireError {
    WireError {
        code: code.to_string(),
        message: message.to_string(),
        details,
    }
}

fn not_found() -> WireError {
    wire(code::NOT_FOUND, "not found", None)
}

fn stale_runtime_request() -> WireError {
    wire(
        code::STALE_RUNTIME_REQUEST,
        "this request was already answered",
        None,
    )
}

fn relay_timeout() -> WireError {
    wire(
        relay_code::RELAY_TIMEOUT,
        "the Mac did not reply in time",
        None,
    )
}

fn rate_limited(wait: Duration) -> WireError {
    let millis = u64::try_from(wait.as_millis()).unwrap_or(u64::MAX).max(1);
    wire(
        relay_code::RATE_LIMITED,
        "too many commands; try again shortly",
        Some(json!({ "retryAfterMs": millis })),
    )
}

fn device_offline(owner: &Owner) -> WireError {
    let mut details = json!({ "deviceId": owner.device_id, "deviceName": owner.name });
    if let Some(seen) = owner.last_seen_at {
        details["lastSeenAt"] = json!(rfc3339_millis(seen));
    }
    wire(
        relay_code::DEVICE_OFFLINE,
        "the Mac is offline",
        Some(details),
    )
}

fn lookup_failed(error: b4hub_db::Error) -> WireError {
    tracing::warn!(%error, "could not look up a command's owner");
    wire(
        code::INTERNAL_ERROR,
        "the hub could not route the command",
        None,
    )
}
