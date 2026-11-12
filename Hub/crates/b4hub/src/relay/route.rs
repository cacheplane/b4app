//! Commands: a client's `command` taken to the Mac that owns what it names, and the Mac's `reply`
//! taken back. `Hub/API.md` ("Commands") is the reference.
//!
//! For each command, [`handle_command`] applies, in order:
//!
//! 1. the role (only a client link sends commands) and the method (an allowlist; an unknown one
//!    never decodes, and [`unknown_command`] answers it), then the in-flight check, then the rate
//!    limits;
//! 2. the lookup of the thread, the runtime request's thread, the environment, or (for
//!    `environment.create`, which names no row yet) the device named by `deviceId`, within the caller's
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
//! A command is in flight from the moment it arrives until its answer is queued for the caller,
//! keyed by the caller *device* and the command `id`: a second command with the same key attaches
//! to the first (it is neither counted against the limits nor forwarded again), and the answer goes
//! to whatever link the caller device has when it is ready. Nothing here is stored; a hub restart forgets it all, and the phone's resend of the same
//! `id` is then forwarded afresh (the Mac recognises the id).
//!
//! The hub logs each command's method, outcome, and latency, never its params or result.
//!
//! Also here: a client's `watch` ([`handle_watch`]), which is authorised like `turn.send`, and a
//! host's `event` ([`handle_event`]), which is fanned out to the clients watching its thread.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use b4hub_core::relay::{
    From, RelayMessage, RelayMethod, Role, WireError, COMMAND_DEADLINE, HELD_MAX, HOLD_WINDOW,
    PENDING_THREAD_TTL, REPLY_WAIT_OTHER, REPLY_WAIT_START,
};
use b4hub_db::relay::Owner;
use b4hub_db::Db;
use serde_json::{json, Value};
use tokio::sync::{oneshot, watch};
use tokio::time::Instant;
use uuid::Uuid;

use super::admission::{
    private_connection_fields, public_requirement, target_requirement, Checked, Failure,
};
use super::limits::{RateWithBurst, SlidingWindow, COMMAND_WINDOW, STARTS_PER_WINDOW};
use super::registry::WatchError;
use super::{rfc3339_millis, LinkHandle, Relay, SendError};
use crate::error::relay_code;

/// How long a command or a reply waits for room in a full outbound queue before it is given up:
/// a command to a Mac is then `relay_timeout`, and a reply to a client is dropped.
pub const QUEUE_WAIT: Duration = Duration::from_secs(5);

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
    required: u32,
    native_owner: Option<Uuid>,
    result: Option<Value>,
    error: Option<WireError>,
}

impl Answer {
    fn refused(error: WireError) -> Answer {
        Answer {
            required: 1,
            native_owner: None,
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
    connection: String,
    required: u32,
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
    /// Set when the instance drains: every hold ends at once with `device_offline`, and nothing
    /// new is held.
    holds_released: watch::Sender<bool>,
    /// Commands that were held and whose answer is not yet queued for the caller; the drain waits
    /// for it to reach zero before it closes the links.
    holding: watch::Sender<usize>,
    per_device: RateWithBurst,
    per_user: SlidingWindow,
}

impl Default for Commands {
    fn default() -> Commands {
        Commands {
            in_flight: Mutex::default(),
            pending_threads: Mutex::default(),
            held: Mutex::default(),
            holds_released: watch::channel(false).0,
            holding: watch::channel(0).0,
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

    fn remember_thread(
        &self,
        user_id: Uuid,
        thread_id: String,
        owner: Uuid,
        connection: String,
        required: u32,
    ) {
        let now = Instant::now();
        let mut pending = lock(&self.pending_threads);
        pending.retain(|_, thread| thread.until > now);
        pending.insert(
            (user_id, thread_id),
            PendingThread {
                owner,
                connection,
                required,
                until: now + PENDING_THREAD_TTL,
            },
        );
    }

    fn pending_thread(&self, user_id: Uuid, thread_id: &str) -> Option<(Uuid, String, u32)> {
        let key = (user_id, thread_id.to_string());
        let mut pending = lock(&self.pending_threads);
        match pending.get(&key) {
            Some(thread) if thread.until > Instant::now() => {
                Some((thread.owner, thread.connection.clone(), thread.required))
            }
            Some(_) => {
                pending.remove(&key);
                None
            }
            None => None,
        }
    }

    /// True when `caller`'s command `id` is in flight, so a resend of it attaches.
    pub(super) fn in_flight(&self, caller: Uuid, id: &str) -> bool {
        lock(&self.in_flight).contains_key(&(caller, id.to_string()))
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
    /// The command waited in a hold, so the drain waits for its answer to be queued.
    held: AtomicBool,
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
        Some(Claim {
            commands,
            key,
            held: AtomicBool::new(false),
        })
    }

    /// Counts the command as held: until [`Claim::unmark_held`] when the Mac came back and it is
    /// forwarded, or else until its `device_offline` answer is queued (the claim is dropped), so
    /// the drain waits for that answer and no longer.
    fn mark_held(&self) {
        if !self.held.swap(true, Ordering::SeqCst) {
            self.commands.holding.send_modify(|count| *count += 1);
        }
    }

    /// The hold ended with the Mac back online: the command is no longer the drain's business.
    fn unmark_held(&self) {
        if self.held.swap(false, Ordering::SeqCst) {
            self.commands
                .holding
                .send_modify(|count| *count = count.saturating_sub(1));
        }
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
        if self.held.load(Ordering::SeqCst) {
            self.commands
                .holding
                .send_modify(|count| *count = count.saturating_sub(1));
        }
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
        self.commands()
            .pending_thread(user_id, thread_id)
            .map(|(owner, _, _)| owner)
    }

    /// How many commands are held for the offline host `host`.
    pub fn held(&self, host: Uuid) -> usize {
        lock(&self.commands().held).get(&host).copied().unwrap_or(0)
    }

    /// The drain's first step: every held command is answered `device_offline` now (a hold must
    /// never time out silently on an instance nobody is connected to any more), nothing new is
    /// held, and this waits, up to `bound`, until those answers are queued for their callers. The
    /// links then close, writing what is queued first.
    pub async fn release_holds(&self, bound: Duration) {
        let commands = self.commands();
        commands.holds_released.send_replace(true);
        let mut holding = commands.holding.subscribe();
        let answered = tokio::time::timeout(bound, holding.wait_for(|count| *count == 0)).await;
        if answered.is_err() {
            tracing::warn!("held commands were not all answered before the links closed");
        }
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
    // Existing IDs attach before interpreting a second, possibly different params object.
    if caller.role == Role::Client && relay.commands().in_flight(caller.device_id, &id) {
        return;
    }
    let mut preflight = match Checked::open(db, relay, caller).await {
        Ok(value) => value,
        Err(error) => {
            fence(relay, caller, error);
            return;
        }
    };
    let inspected = find_target(relay, &mut preflight, caller, method, &params).await;
    let early = match inspected {
        Err(error) if error.code == "protocol_not_activated" => Some(error),
        Err(error) if error.code == code::INTERNAL_ERROR => {
            fence(relay, caller, Failure::Unavailable);
            return;
        }
        _ => None,
    };
    if let Err(error) = preflight.commit().await {
        fence(relay, caller, error);
        return;
    }
    if let Some(error) = early {
        let _ = deliver_answer(
            relay,
            db,
            caller.device_id,
            RelayMessage::Reply {
                id,
                result: None,
                error: Some(error),
            },
            1,
            None,
        )
        .await;
        return;
    }
    let reply_params = params.clone();
    // A client's command is claimed before anything else, the limits included: a resend of one in
    // flight attaches to it and is not counted. The claim is held until the answer has been handed
    // to the caller's link, so a resend in that gap attaches too, and the caller gets one reply.
    let claim = match caller.role {
        Role::Client => match Claim::take(relay.commands(), caller.device_id, &id) {
            Some(claim) => Some(claim),
            None => {
                tracing::info!(method = method.as_str(), outcome = "attached", "command");
                return;
            }
        },
        Role::Host => None,
    };
    let answer = match &claim {
        Some(claim) => route(relay, db, caller, claim, &id, method, params).await,
        None => Answer::refused(not_found()),
    };
    let outcome = answer
        .error
        .as_ref()
        .map_or("ok", |error| error.code.as_str());
    let latency_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    tracing::info!(method = method.as_str(), outcome, latency_ms, "command");
    // The caller may have linked again meanwhile; then the answer goes to the new link. A caller
    // with no link, or whose queue stays full for `QUEUE_WAIT`, misses it and settles the command
    // another way (the phone's `turn.lookup`).
    let owner = answer.native_owner;
    let reply = RelayMessage::Reply {
        id,
        result: answer.result,
        error: answer.error,
    };
    if deliver_answer(
        relay,
        db,
        caller.device_id,
        reply,
        answer.required,
        owner.map(|owner| (method, &reply_params, owner)),
    )
    .await
    .is_err()
    {
        tracing::info!(method = method.as_str(), "command reply not delivered");
    }
    drop(claim);
}

/// A host's `reply`: answers the commands `id` forwarded to it that are still waiting. A reply
/// that nothing waits for (too late, or never asked) is dropped.
pub(super) async fn handle_reply(
    relay: &Relay,
    db: &Db,
    host: &LinkHandle,
    id: &str,
    result: Option<Value>,
    error: Option<WireError>,
) -> Result<(), Failure> {
    let checked = Checked::open(db, relay, host).await?;
    let details = error.as_ref().and_then(|error| error.details.as_ref());
    let required = result
        .as_ref()
        .map_or(1, public_requirement)
        .max(details.map_or(1, public_requirement));
    if result.as_ref().is_some_and(private_connection_fields)
        || details.is_some_and(private_connection_fields)
    {
        return Err(Failure::Gone);
    }
    checked.proof(required)?;
    let answer = Answer {
        result,
        error,
        required: checked.floor().minimum().max(required),
        native_owner: Some(host.device_id),
    };
    for reply in relay.commands().answered(host.device_id, id) {
        let _ = reply.send(answer.clone());
    }
    checked.commit().await
}

/// The answer to a frame that did not decode but is a `command` with an `id`: its method is not
/// on the allowlist, so it is `not_found`, as an unknown target would be. `None` for anything else.
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

/// A client's `watch { threadId }`. Authorised like `turn.send`: the thread must be one the
/// caller's user may reach (the pending-thread map first, then the thread table) and its owner a
/// non-revoked `macos` device of that user. Returns the `error` frame to answer with: `not_found`
/// (a missing thread reads the same as someone else's), `watch_limit`, or `internal_error`.
pub async fn handle_watch(
    relay: &Relay,
    db: &Db,
    client: &LinkHandle,
    thread_id: &str,
) -> Option<RelayMessage> {
    let mut checked = match Checked::open(db, relay, client).await {
        Ok(value) => value,
        Err(error) => {
            fence(relay, client, error);
            return None;
        }
    };
    let found = match thread_target(relay, &mut checked, client, thread_id).await {
        Ok(value) => value,
        Err(error) => return Some(watch_refused(error, thread_id)),
    };
    if let Err(error) = checked.proof(found.required) {
        return Some(watch_refused(error.wire(), thread_id));
    }
    let result = match relay.watch(client, found.owner.device_id, thread_id) {
        Ok(()) | Err(WatchError::Gone) => None,
        Err(WatchError::Limit) => Some(watch_refused(
            WireError {
                code: relay_code::WATCH_LIMIT.into(),
                message: "a link may watch at most 4 threads".into(),
                details: None,
            },
            thread_id,
        )),
    };
    if let Err(error) = checked.commit().await {
        fence(relay, client, error);
        return None;
    }
    result
}

/// The `error` frame refusing a `watch`, with `details.threadId` naming the thread, so the client
/// can tell which watch failed (and retry it or give up on it).
fn watch_refused(error: WireError, thread_id: &str) -> RelayMessage {
    let mut details = match error.details {
        Some(Value::Object(details)) => details,
        _ => serde_json::Map::new(),
    };
    details.insert("threadId".to_string(), Value::String(thread_id.to_string()));
    RelayMessage::Error {
        code: error.code,
        message: error.message,
        details: Some(Value::Object(details)),
    }
}

/// A host's `event`: sent on to every client link watching its `threadId`, and dropped when none
/// does (or the event names no thread). The hub reads that one field and nothing else, and logs
/// nothing about the event.
pub(super) async fn handle_event(
    relay: &Relay,
    db: &Db,
    host: &LinkHandle,
    event: Value,
) -> Result<(), Failure> {
    let Some(thread) = event
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return Ok(());
    };
    let mut checked = Checked::open(db, relay, host).await?;
    let target = match thread_target(relay, &mut checked, host, &thread).await {
        Ok(target) => target,
        Err(_) => return checked.commit().await,
    };
    if target.owner.device_id != host.device_id {
        return checked.commit().await;
    }
    if private_connection_fields(&event) {
        return Ok(());
    }
    let mut required = target.required.max(public_requirement(&event));
    if let Some(id) = event.get("connectionId").and_then(Value::as_str) {
        let found = checked
            .native()?
            .connection(id)
            .await
            .map_err(Failure::db)?
            .ok_or(Failure::Gone)?;
        if found.owner.device_id != host.device_id {
            return Err(Failure::Gone);
        }
        required = required.max(target_requirement(found.protocol)?);
        // An event cannot claim a different connection than its persisted thread.
        let matches = if target.stored {
            checked
                .native()?
                .thread_connection_matches(&thread, id)
                .await
                .map_err(Failure::db)?
        } else {
            relay
                .commands()
                .pending_thread(host.user_id, &thread)
                .is_some_and(|(device, connection, _)| device == host.device_id && connection == id)
        };
        if !matches {
            return Ok(());
        }
    }
    let proof = checked.proof(required)?;
    relay.fan_out_checked(
        host.device_id,
        &thread,
        &RelayMessage::Event { event },
        &proof,
    );
    checked.commit().await
}

pub(super) fn fence(relay: &Relay, handle: &LinkHandle, error: Failure) {
    if let Some(close) = error.close() {
        relay.close_generation(handle.device_id, handle.generation, close);
    }
}

/// Capacity waits finish before opening the short native write admission. A reconnect receives
/// the original result only after its own session, floor and generation have been rechecked.
async fn deliver_answer(
    relay: &Relay,
    db: &Db,
    device: Uuid,
    message: RelayMessage,
    mut required: u32,
    target: Option<(RelayMethod, &Value, Uuid)>,
) -> Result<(), Failure> {
    let until = Instant::now() + QUEUE_WAIT;
    let reserved = relay
        .reserve(device, until)
        .await
        .map_err(|_| Failure::Gone)?;
    let mut checked =
        match tokio::time::timeout_at(until, Checked::open(db, relay, &reserved.handle)).await {
            Ok(Ok(value)) => value,
            Ok(Err(error)) => {
                fence(relay, &reserved.handle, error);
                return Err(error);
            }
            Err(_) => {
                fence(relay, &reserved.handle, Failure::Unavailable);
                return Err(Failure::Unavailable);
            }
        };
    if let Some((method, params, expected_owner)) = target {
        let recipient = reserved.handle.clone();
        let current = tokio::time::timeout_at(
            until,
            find_target(relay, &mut checked, &recipient, method, params),
        )
        .await
        .map_err(|_| Failure::Unavailable)?
        .map_err(|_| Failure::Gone)?;
        if current.owner.device_id != expected_owner {
            return Err(Failure::Gone);
        }
        required = required.max(current.required);
    }
    let proof = checked.proof(required)?;
    reserved.send(message, &proof).map_err(|_| Failure::Gone)?;
    tokio::time::timeout_at(until, checked.commit())
        .await
        .map_err(|_| Failure::Unavailable)?
}

/// A claimed client command, from the limits on.
async fn route(
    relay: &Relay,
    db: &Db,
    caller: &LinkHandle,
    claim: &Claim<'_>,
    id: &str,
    method: RelayMethod,
    params: Value,
) -> Answer {
    if let Err(wait) = relay.commands().check_limits(caller, method) {
        tracing::warn!(device = %caller.device_id, method = method.as_str(), "command rate limit hit");
        return Answer::refused(rate_limited(wait));
    }
    deliver(relay, db, caller, claim, id, method, params)
        .await
        .unwrap_or_else(Answer::refused)
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
    let mut checked = Checked::open(db, relay, caller).await.map_err(|error| {
        fence(relay, caller, error);
        error.wire()
    })?;
    let target = find_target(relay, &mut checked, caller, method, &params).await?;
    checked
        .proof(target.required)
        .map_err(|error| error.wire())?;
    let owner = target.owner;
    checked.commit().await.map_err(|error| error.wire())?;
    if !relay.online(owner.device_id) {
        if !holdable(method) {
            return Err(device_offline(&owner));
        }
        claim.mark_held();
        hold(relay, &owner).await?;
        claim.unmark_held();
    }
    forward(relay, db, caller, claim, id, method, params, &owner).await
}

struct Target {
    owner: Owner,
    required: u32,
    stored: bool,
}
async fn find_target(
    relay: &Relay,
    checked: &mut Checked,
    caller: &LinkHandle,
    method: RelayMethod,
    params: &Value,
) -> Result<Target, WireError> {
    if private_connection_fields(params) {
        return Err(not_found());
    }
    let mut required = public_requirement(params);
    let owner = match method {
        RelayMethod::TurnSend | RelayMethod::TurnInterrupt | RelayMethod::TurnLookup => {
            let found = thread_target(relay, checked, caller, param(params, "threadId")?).await?;
            required = required.max(found.required);
            found.owner
        }
        RelayMethod::RequestRespond => {
            let found = checked
                .native()
                .map_err(|e| e.wire())?
                .request(param(params, "requestId")?)
                .await
                .map_err(lookup_failed)?
                .ok_or_else(not_found)?;
            required =
                required.max(target_requirement(found.target.protocol).map_err(|e| e.wire())?);
            if found
                .state
                .as_deref()
                .is_some_and(|state| state != "pending")
            {
                return Err(stale_runtime_request());
            }
            eligible(caller, found.target.owner)?
        }
        RelayMethod::ThreadStart => {
            // The connection is a real owned row even for a no-folder start. Neither a header
            // nor an untyped missing parent is evidence of a legacy target.
            let connection = checked
                .native()
                .map_err(|e| e.wire())?
                .connection(param(params, "connectionId")?)
                .await
                .map_err(lookup_failed)?
                .ok_or_else(not_found)?;
            required = required.max(target_requirement(connection.protocol).map_err(|e| e.wire())?);
            let owner = if params.get("environmentId").is_none_or(Value::is_null) {
                device_target(checked, caller, params).await?
            } else {
                let row = checked
                    .native()
                    .map_err(|e| e.wire())?
                    .environment(param(params, "environmentId")?)
                    .await
                    .map_err(lookup_failed)?
                    .ok_or_else(not_found)?;
                eligible(caller, row)?
            };
            if connection.owner.device_id != owner.device_id {
                return Err(not_found());
            }
            owner
        }
        RelayMethod::EnvironmentUpdate | RelayMethod::EnvironmentDelete => {
            let row = checked
                .native()
                .map_err(|e| e.wire())?
                .environment(param(params, "environmentId")?)
                .await
                .map_err(lookup_failed)?
                .ok_or_else(not_found)?;
            eligible(caller, row)?
        }
        RelayMethod::EnvironmentCreate => device_target(checked, caller, params).await?,
    };
    checked.proof(required).map_err(|e| e.wire())?;
    Ok(Target {
        owner,
        required,
        stored: true,
    })
}
async fn device_target(
    checked: &mut Checked,
    caller: &LinkHandle,
    params: &Value,
) -> Result<Owner, WireError> {
    let id = param(params, "deviceId")?
        .parse::<Uuid>()
        .map_err(|_| not_found())?;
    eligible(
        caller,
        checked
            .native()
            .map_err(|e| e.wire())?
            .device(id)
            .await
            .map_err(lookup_failed)?
            .ok_or_else(not_found)?,
    )
}
async fn thread_target(
    relay: &Relay,
    checked: &mut Checked,
    caller: &LinkHandle,
    id: &str,
) -> Result<Target, WireError> {
    if let Some(found) = checked
        .native()
        .map_err(|e| e.wire())?
        .thread(id)
        .await
        .map_err(lookup_failed)?
    {
        return Ok(Target {
            owner: eligible(caller, found.owner)?,
            required: target_requirement(found.protocol).map_err(|e| e.wire())?,
            stored: true,
        });
    }
    if let Some((device, connection, required)) =
        relay.commands().pending_thread(caller.user_id, id)
    {
        let target = checked
            .native()
            .map_err(|e| e.wire())?
            .connection(&connection)
            .await
            .map_err(lookup_failed)?
            .ok_or_else(not_found)?;
        if target.owner.device_id != device {
            return Err(not_found());
        }
        return Ok(Target {
            owner: eligible(caller, target.owner)?,
            required: required.max(target_requirement(target.protocol).map_err(|e| e.wire())?),
            stored: false,
        });
    }
    Err(not_found())
}

/// The host's direct watching frame is built under the same fresh admission used to write it.
/// Stale/moved targets are removed rather than disclosed to their former host.
pub(super) async fn watching(
    relay: &Relay,
    checked: &mut Checked,
    host: &LinkHandle,
    ids: Vec<String>,
) -> Result<(Vec<String>, u32), Failure> {
    let mut kept = Vec::new();
    let mut required = 1;
    for id in ids {
        match thread_target(relay, checked, host, &id).await {
            Ok(found) if found.owner.device_id == host.device_id => {
                required = required.max(found.required);
                kept.push(id);
            }
            Err(error) if error.code == code::INTERNAL_ERROR => return Err(Failure::Unavailable),
            _ => {}
        }
    }
    checked.proof(required)?;
    Ok((kept, required))
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
    let mut released = relay.commands().holds_released.subscribe();
    if relay.online(owner.device_id) {
        return Ok(());
    }
    if *released.borrow() {
        return Err(device_offline(owner));
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
            _ = released.changed() => return Err(device_offline(owner)),
        }
    }
}

/// Step 5 and 6 for an online owner: stamp, forward, wait.
async fn forward(
    relay: &Relay,
    db: &Db,
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
    let started_connection = if started_thread.is_some() {
        Some(param(&params, "connectionId")?.to_string())
    } else {
        None
    };
    let mut command = RelayMessage::Command {
        id: id.to_string(),
        method,
        params,
        deadline: Some(rfc3339_millis(relay.wall_now() + COMMAND_DEADLINE)),
        from: Some(From {
            device_id: caller.device_id,
            name: caller.name.clone(),
        }),
    };
    let until = Instant::now() + QUEUE_WAIT;
    let reserved = relay
        .reserve(owner.device_id, until)
        .await
        .map_err(|error| match error {
            SendError::Offline => device_offline(owner),
            SendError::Full => relay_timeout(),
        })?;
    // The accepted command belongs to this logical device, not its old socket. Reconnection
    // keeps dedupe/hold semantics, but must present a fresh native session of the same account.
    let origin = relay
        .handle(caller.device_id)
        .filter(|handle| handle.org_id == caller.org_id && handle.user_id == caller.user_id)
        .ok_or_else(not_found)?;
    let mut checked = tokio::time::timeout_at(until, Checked::open(db, relay, &origin))
        .await
        .map_err(|_| relay_timeout())?
        .map_err(|e| e.wire())?;
    let target = tokio::time::timeout_at(
        until,
        find_target(
            relay,
            &mut checked,
            &origin,
            method,
            &command_params(&command),
        ),
    )
    .await
    .map_err(|_| relay_timeout())??;
    if let RelayMessage::Command { from, .. } = &mut command {
        *from = Some(From {
            device_id: origin.device_id,
            name: origin.name.clone(),
        });
    }
    if target.owner.device_id != owner.device_id {
        return Err(not_found());
    }
    let required = target.required;
    let proof = checked.proof(required).map_err(|e| e.wire())?;
    reserved
        .send(command, &proof)
        .map_err(|error| match error {
            SendError::Offline => device_offline(owner),
            SendError::Full => relay_timeout(),
        })?;
    let mut auto_watch = None;
    if let Some(thread_id) = &started_thread {
        // The caller's link watches the thread it just started (it counts toward its four), so
        // the Mac streams the first turn without the phone having to race a `watch` against it.
        if let Some(link) = relay.handle(caller.device_id) {
            match relay.watch(&link, owner.device_id, thread_id) {
                Ok(()) => auto_watch = Some(link),
                Err(WatchError::Limit) => {
                    tracing::info!(device = %caller.device_id, "new thread not watched: watch limit");
                }
                Err(WatchError::Gone) => {}
            }
        }
        relay.commands().remember_thread(
            caller.user_id,
            thread_id.clone(),
            owner.device_id,
            started_connection.clone().ok_or_else(not_found)?,
            required,
        );
    }
    tokio::time::timeout_at(until, checked.commit())
        .await
        .map_err(|_| relay_timeout())?
        .map_err(|e| e.wire())?;
    let wait = if starts_a_turn(method) {
        REPLY_WAIT_START
    } else {
        REPLY_WAIT_OTHER
    };
    let mut answer = match tokio::time::timeout(wait, answered).await {
        Ok(Ok(answer)) => answer,
        _ => return Err(relay_timeout()),
    };
    // A start the Mac refused before making its turn (an error without `details.turnId`) made no
    // thread, so the watch it took is given back: refusals must not use up the caller's four.
    if let (Some(link), Some(thread_id), Some(error)) = (auto_watch, &started_thread, &answer.error)
    {
        let made_a_turn = error
            .details
            .as_ref()
            .is_some_and(|details| details.get("turnId").is_some());
        if !made_a_turn {
            relay.unwatch(&link, thread_id);
        }
    }
    answer.required = answer.required.max(required);
    Ok(answer)
}

fn command_params(command: &RelayMessage) -> Value {
    match command {
        RelayMessage::Command { params, .. } => params.clone(),
        _ => Value::Null,
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

pub(super) fn rate_limited(wait: Duration) -> WireError {
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
