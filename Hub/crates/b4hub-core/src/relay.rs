//! The relay wire: the JSON text frames on `GET /v1/devices/self/link`. The hub forwards commands
//! from a phone to the Mac that owns a thread and the Mac's replies and live events back. This
//! module is only the shape; routing, limits and deadlines live in the service. Swift's
//! `RelayWire.swift` is the same contract, and `Tests/Fixtures/sync/relay.json` is decoded by both.
//!
//! Optional fields that are absent are omitted when encoding, never written as `null`, so a frame
//! round-trips exactly. `params`, `result`, `details` and `event` stay opaque here: the hub forwards
//! them and never reads their content.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

/// How often a device sends `ping`, in seconds; also sent in `hello` as `heartbeatSeconds`.
pub const HEARTBEAT_SECONDS: u32 = 10;
/// A link silent for this long is dead, on either end.
pub const DEAD_LINK: Duration = Duration::from_secs(30);
/// How long a command stays valid after the hub stamps it.
pub const COMMAND_DEADLINE: Duration = Duration::from_secs(10);
/// How long the hub waits for a host's reply to `turn.send` and `thread.start`.
pub const REPLY_WAIT_START: Duration = Duration::from_secs(30);
/// How long the hub waits for a host's reply to every other method.
pub const REPLY_WAIT_OTHER: Duration = Duration::from_secs(15);
/// How long `turn.interrupt` and `request.respond` may be held for an offline owner, from its
/// `lastSeenAt`.
pub const HOLD_WINDOW: Duration = Duration::from_secs(60);
/// How long a `thread.start` result routes by thread id before the synced row exists.
pub const PENDING_THREAD_TTL: Duration = Duration::from_secs(300);
/// The largest frame accepted from a client link, in bytes.
pub const CLIENT_FRAME_MAX: usize = 65_536;
/// The largest frame accepted from a host link, in bytes.
pub const HOST_FRAME_MAX: usize = 262_144;
/// The most threads one client link may watch.
pub const WATCH_MAX: usize = 4;
/// The most commands held at once for one offline host.
pub const HELD_MAX: usize = 32;
/// The outbound frames queued for one link before the hub starts dropping a client's events.
pub const LINK_QUEUE: usize = 256;

/// The event kinds the hub forwards to watching clients, and no others.
pub const FORWARDED_EVENT_KINDS: [&str; 10] = [
    "turn.acknowledged",
    "turn.state_changed",
    "turn.finished",
    "message.started",
    "message.delta",
    "message.completed",
    "tool.started",
    "tool.completed",
    "runtime_request.opened",
    "runtime_request.resolved",
];

/// What a command asks the Mac to do: an allowlist on both the hub and the Mac.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RelayMethod {
    #[serde(rename = "turn.send")]
    TurnSend,
    #[serde(rename = "turn.interrupt")]
    TurnInterrupt,
    #[serde(rename = "request.respond")]
    RequestRespond,
    #[serde(rename = "thread.start")]
    ThreadStart,
    #[serde(rename = "turn.lookup")]
    TurnLookup,
}

impl RelayMethod {
    /// The wire string.
    pub fn as_str(self) -> &'static str {
        match self {
            RelayMethod::TurnSend => "turn.send",
            RelayMethod::TurnInterrupt => "turn.interrupt",
            RelayMethod::RequestRespond => "request.respond",
            RelayMethod::ThreadStart => "thread.start",
            RelayMethod::TurnLookup => "turn.lookup",
        }
    }
}

/// Which end of the relay a link is: a `macos` device is a host; `ios` and `cli` are clients.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Host,
    Client,
}

/// One Mac in a `presence` frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostPresence {
    pub device_id: Uuid,
    pub name: String,
    pub online: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seen_at: Option<String>,
}

/// The client a command came from, stamped on it by the hub.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct From {
    pub device_id: Uuid,
    pub name: String,
}

/// The failure of one command, carried in a `reply`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WireError {
    pub code: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

/// One frame on a relay link.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum RelayMessage {
    /// Hub to device, first on every link.
    Hello {
        protocol: u32,
        min_client_protocol: u32,
        device_id: Uuid,
        role: Role,
        heartbeat_seconds: u32,
        hub_time: String,
    },
    Ping,
    Pong {
        hub_time: String,
    },
    /// Client to hub with `id`, `method` and `params`; hub to host with `deadline` and `from` too.
    Command {
        id: String,
        method: RelayMethod,
        params: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        deadline: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from: Option<From>,
    },
    /// Host to hub, and hub to client: `result` or `error`, never both.
    Reply {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        result: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<WireError>,
    },
    Watch {
        thread_id: String,
    },
    Unwatch {
        thread_id: String,
    },
    /// Hub to host: the full set of its threads that some client watches.
    Watching {
        thread_ids: Vec<String>,
    },
    /// Host to hub, and hub to client: an `AdapterEvent` the hub never reads beyond its thread id.
    Event {
        event: Value,
    },
    /// Hub to client: events for this thread were dropped.
    StreamGap {
        thread_id: String,
    },
    Presence {
        hosts: Vec<HostPresence>,
    },
    /// Hub to device: a problem with the link or a frame, not with a command.
    Error {
        code: String,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        details: Option<Value>,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../../../Tests/Fixtures/sync/relay.json");

    #[test]
    fn relay_fixture_round_trips() {
        let elements: Vec<serde_json::Value> = serde_json::from_str(FIXTURE).unwrap();
        assert_eq!(elements.len(), 17);
        for element in elements {
            let decoded: RelayMessage = serde_json::from_value(element.clone()).unwrap();
            assert_eq!(serde_json::to_value(decoded).unwrap(), element);
        }
    }

    #[test]
    fn methods_use_their_wire_strings() {
        for (method, wire) in [
            (RelayMethod::TurnSend, "turn.send"),
            (RelayMethod::TurnInterrupt, "turn.interrupt"),
            (RelayMethod::RequestRespond, "request.respond"),
            (RelayMethod::ThreadStart, "thread.start"),
            (RelayMethod::TurnLookup, "turn.lookup"),
        ] {
            assert_eq!(method.as_str(), wire);
            assert_eq!(serde_json::to_value(method).unwrap(), wire);
        }
        assert!(serde_json::from_str::<RelayMethod>("\"turn.delete\"").is_err());
    }

    #[test]
    fn absent_optionals_are_omitted_not_null() {
        let command = RelayMessage::Command {
            id: "c".into(),
            method: RelayMethod::TurnSend,
            params: serde_json::json!({}),
            deadline: None,
            from: None,
        };
        let wire = serde_json::to_value(command).unwrap();
        assert!(wire.get("deadline").is_none() && wire.get("from").is_none());
    }

    #[test]
    fn constants_match_the_swift_limits() {
        assert_eq!(HEARTBEAT_SECONDS, 10);
        assert_eq!(DEAD_LINK, Duration::from_secs(30));
        assert_eq!(COMMAND_DEADLINE, Duration::from_secs(10));
        assert_eq!(REPLY_WAIT_START, Duration::from_secs(30));
        assert_eq!(REPLY_WAIT_OTHER, Duration::from_secs(15));
        assert_eq!(HOLD_WINDOW, Duration::from_secs(60));
        assert_eq!(PENDING_THREAD_TTL, Duration::from_secs(300));
        assert_eq!(CLIENT_FRAME_MAX, 65_536);
        assert_eq!(HOST_FRAME_MAX, 262_144);
        assert_eq!(WATCH_MAX, 4);
        assert_eq!(HELD_MAX, 32);
        assert_eq!(LINK_QUEUE, 256);
        assert_eq!(FORWARDED_EVENT_KINDS.len(), 10);
    }

    #[test]
    fn unknown_type_is_an_error() {
        let result = serde_json::from_str::<RelayMessage>(r#"{"type":"teleport"}"#);
        assert!(result.is_err());
    }
}
