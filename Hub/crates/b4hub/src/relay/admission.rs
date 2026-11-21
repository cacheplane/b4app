//! Short native relay admissions. Never keep one across queue/offline/command waits.
use super::{Close, LinkHandle, Relay};
use b4hub_core::{
    protocol::ClientProtocol,
    relay::{RelayMessage, WireError},
};
use b4hub_db::{
    relay::{Admission, ProbeAdmission, TargetProtocol},
    Db,
};
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Failure {
    TooOld(u32),
    Session,
    Unavailable,
    Gone,
    NotActivated,
    Socket,
}
impl Failure {
    pub fn close(self) -> Option<Close> {
        match self {
            Self::TooOld(min) => Some(Close::client_too_old(min)),
            Self::Session => Some(Close::session_ended()),
            Self::Gone => Some(Close::replaced()),
            Self::Unavailable => Some(Close::protocol_unavailable()),
            Self::NotActivated => Some(Close::protocol_not_activated()),
            Self::Socket => None,
        }
    }
    pub fn wire(self) -> WireError {
        let (code, message, details) = match self {
            Self::TooOld(min) => (
                "client_too_old",
                "update the client before using the relay",
                Some(json!({"minClientProtocol":min})),
            ),
            Self::NotActivated => (
                "protocol_not_activated",
                "protocol 2 is not activated on this Hub",
                Some(json!({"requiredProtocol":2})),
            ),
            Self::Session | Self::Gone => ("not_found", "the requested target was not found", None),
            Self::Unavailable | Self::Socket => {
                ("internal_error", "the relay is unavailable", None)
            }
        };
        WireError {
            code: code.into(),
            message: message.into(),
            details,
        }
    }
    pub fn db(error: b4hub_db::Error) -> Self {
        match error {
            b4hub_db::Error::ClientTooOld { minimum } => Self::TooOld(minimum),
            b4hub_db::Error::ProtocolNotActivated => Self::NotActivated,
            _ => Self::Unavailable,
        }
    }
}

enum Native {
    Device(Admission),
    Probe(ProbeAdmission),
}
pub(crate) struct Checked {
    native: Native,
    handle: LinkHandle,
    relay: Relay,
}
impl Checked {
    pub async fn open(db: &Db, relay: &Relay, handle: &LinkHandle) -> Result<Self, Failure> {
        let native = if handle.is_probe() {
            Native::Probe(
                ProbeAdmission::open(db, handle.client_protocol)
                    .await
                    .map_err(Failure::db)?,
            )
        } else {
            let key = handle.session.as_ref().ok_or(Failure::Session)?;
            let native = Admission::open(db, key, handle.client_protocol)
                .await
                .map_err(Failure::db)?
                .ok_or(Failure::Session)?;
            let who = native.identity();
            if who.org_id != handle.org_id
                || who.user_id != handle.user_id
                || who.device_id != handle.device_id
            {
                return Err(Failure::Session);
            }
            Native::Device(native)
        };
        let checked = Self {
            native,
            handle: handle.clone(),
            relay: relay.clone(),
        };
        relay
            .observe_floor(checked.floor())
            .map_err(|_| Failure::Unavailable)?;
        if handle.client_protocol.value() < relay.min_client_protocol() {
            return Err(Failure::TooOld(relay.min_client_protocol()));
        }
        if !relay.current(handle) {
            return Err(Failure::Gone);
        }
        Ok(checked)
    }
    pub fn floor(&self) -> b4hub_core::protocol::ProtocolFloor {
        match &self.native {
            Native::Device(n) => n.floor(),
            Native::Probe(n) => n.floor(),
        }
    }
    pub fn native(&mut self) -> Result<&mut Admission, Failure> {
        match &mut self.native {
            Native::Device(n) => Ok(n),
            Native::Probe(_) => Err(Failure::Session),
        }
    }
    pub fn handle(&self) -> &LinkHandle {
        &self.handle
    }
    pub fn proof(&self, required: u32) -> Result<Proof<'_>, Failure> {
        if required == 0 || required > self.floor().minimum() {
            return Err(Failure::NotActivated);
        }
        if !self.relay.current(&self.handle) {
            return Err(Failure::Gone);
        }
        Ok(Proof {
            checked: self,
            required: required.max(self.floor().minimum()),
        })
    }
    pub async fn commit(self) -> Result<(), Failure> {
        match self.native {
            Native::Device(n) => n.commit().await,
            Native::Probe(n) => n.commit().await,
        }
        .map_err(Failure::db)
    }
}

/// Borrowing the live Checked value keeps its DB barrier alive through synchronous enqueue.
/// The queue retains only Stamp, not this proof or a pool lease.
pub(crate) struct Proof<'a> {
    checked: &'a Checked,
    required: u32,
}
impl Proof<'_> {
    pub fn stamp_for(&self, target: &LinkHandle) -> Option<super::registry::Stamp> {
        let origin = self.checked.handle();
        if origin.org_id != target.org_id
            || origin.user_id != target.user_id
            || !self.checked.relay.current(origin)
            || !self.checked.relay.current(target)
            || target.client_protocol.value() < self.required
        {
            return None;
        }
        Some(super::registry::Stamp {
            generation: target.generation,
            required: self.required,
        })
    }
}

pub(super) fn target_requirement(protocol: TargetProtocol) -> Result<u32, Failure> {
    match protocol {
        TargetProtocol::Legacy => Ok(1),
        TargetProtocol::Protocol2 => Ok(ClientProtocol::SUPPORTED.value()),
        TargetProtocol::Unknown => Err(Failure::Gone),
    }
}

/// Only schema-owned protocol coordinates are interpreted. Arbitrary nested user text remains
/// opaque; an untrusted claimed minimum is never authority.
pub(super) fn public_requirement(value: &Value) -> u32 {
    fn modern(value: &Value) -> bool {
        value.get("kind").and_then(Value::as_str) == Some("agentProtocol")
            || b4hub_core::protocol::CONNECTION_COLUMNS
                .iter()
                .any(|key| value.get(*key).is_some_and(|v| !v.is_null()))
    }
    if modern(value) || connection_objects(value).any(modern) {
        2
    } else {
        1
    }
}
fn connection_objects(value: &Value) -> impl Iterator<Item = &Value> {
    // Only typed public envelope positions. No recursive walk through opaque user payloads.
    [
        value.get("connection"),
        value.get("payload").and_then(|v| v.get("connection")),
        value.get("thread").and_then(|v| v.get("connection")),
    ]
    .into_iter()
    .flatten()
}
pub(super) fn private_connection_fields(value: &Value) -> bool {
    let private = |row: &Value| {
        // These two owner-private bundle fields never belong to a public connection object,
        // including an explicit null. The older scrubbed fields retain harmless legacy forms.
        ["authMode", "authHeaderName"]
            .iter()
            .any(|key| row.get(*key).is_some())
            || row.get("target").is_some_and(|value| match value {
                Value::Null => false,
                Value::String(text) => !text.is_empty(),
                _ => true,
            })
            || ["authReference", "localServerId"]
                .iter()
                .any(|key| row.get(*key).is_some_and(|value| !value.is_null()))
    };
    let root_connection = matches!(
        value.get("kind").and_then(Value::as_str),
        Some("codex" | "claude" | "b4" | "agentProtocol")
    );
    (root_connection && private(value)) || connection_objects(value).any(private)
}

/// Native recipient-side server producer (also used by queue/backpressure integration fixtures).
/// It takes an actual session admission, not an exported synthetic/test authorization flag.
pub async fn try_send_native(
    relay: &Relay,
    native: &mut Admission,
    device: uuid::Uuid,
    message: RelayMessage,
) -> Result<(), super::SendError> {
    let handle = relay.handle(device).ok_or(super::SendError::Offline)?;
    let who = native.identity();
    if who.device_id != device
        || who.org_id != handle.org_id
        || who.user_id != handle.user_id
        || handle.session != Some(native.session())
        || native.client() != handle.client_protocol
    {
        return Err(super::SendError::Offline);
    }
    let required = match &message {
        RelayMessage::Event { event } => {
            if private_connection_fields(event) {
                return Err(super::SendError::Offline);
            }
            let mut required = public_requirement(event);
            if let Some(thread) = event.get("threadId").and_then(Value::as_str) {
                let target = native
                    .thread(thread)
                    .await
                    .map_err(|_| super::SendError::Offline)?
                    .ok_or(super::SendError::Offline)?;
                required = required.max(
                    target_requirement(target.protocol).map_err(|_| super::SendError::Offline)?,
                );
            }
            required
        }
        RelayMessage::Ping | RelayMessage::Pong { .. } => 1,
        // Commands/replies/presence/watch output use their typed production producers below.
        _ => return Err(super::SendError::Offline),
    };
    if required > native.floor().minimum() || relay.observe_floor(native.floor()).is_err() {
        return Err(super::SendError::Offline);
    }
    relay.queue_native(&handle, message, native.floor().minimum().max(required))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn known_connection_positions_preserve_harmless_forms_and_exclude_private_sentinels() {
        for row in [
            json!({}),
            json!({"target":null,"authReference":null,"localServerId":null}),
            json!({"target":""}),
        ] {
            let mut root = row.clone();
            root["kind"] = json!("codex");
            for value in [
                root,
                json!({"connection":row.clone()}),
                json!({"payload":{"connection":row.clone()}}),
                json!({"thread":{"connection":row.clone()}}),
            ] {
                assert!(!private_connection_fields(&value));
            }
        }
        for row in [
            json!({"target":"PRIVATE_TARGET_CANARY"}),
            json!({"authReference":"PRIVATE_REFERENCE_CANARY"}),
            json!({"localServerId":"PRIVATE_SERVER_CANARY"}),
            json!({"authMode":null}),
            json!({"authHeaderName":null}),
            json!({"target":false}),
            json!({"authReference":""}),
            json!({"localServerId":""}),
        ] {
            let mut root = row.clone();
            root["kind"] = json!("codex");
            for value in [
                root,
                json!({"connection":row.clone()}),
                json!({"payload":{"connection":row.clone()}}),
                json!({"thread":{"connection":row.clone()}}),
            ] {
                assert!(private_connection_fields(&value));
            }
        }
        assert!(!private_connection_fields(
            &json!({"text":{"connection":{"target":"ordinary-user-text","authReference":"text","localServerId":"text","authMode":"text"}}})
        ));
    }

    #[test]
    fn requirements_use_only_named_public_connection_coordinates() {
        assert_eq!(
            public_requirement(&json!({"connection":{"kind":"agentProtocol"}})),
            2
        );
        assert_eq!(
            public_requirement(&json!({"payload":{"connection":{"agentId":"public-agent"}}})),
            2
        );
        assert_eq!(
            public_requirement(&json!({"thread":{"connection":{"protocolRetiredAt":"now"}}})),
            2
        );
        assert_eq!(
            public_requirement(
                &json!({"text":{"connection":{"kind":"agentProtocol"}},"minClientProtocol":2})
            ),
            1
        );
        assert_eq!(
            public_requirement(&json!({"connection":{"kind":"codex","peerProfile":null}})),
            1
        );
        assert!(private_connection_fields(
            &json!({"connection":{"authMode":"bearer"}})
        ));
        assert!(private_connection_fields(
            &json!({"payload":{"connection":{"authHeaderName":null}}})
        ));
        assert!(!private_connection_fields(
            &json!({"text":{"authMode":"user text"}})
        ));
    }
}
