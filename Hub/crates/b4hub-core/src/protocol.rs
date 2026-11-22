//! Wire capability and the database-authoritative admission floor. Support is not activation.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClientProtocol(u32);

impl ClientProtocol {
    pub const LEGACY: Self = Self(1);
    pub const SUPPORTED: Self = Self(2);
    pub const fn new(value: u32) -> Self {
        Self(value)
    }
    pub const fn value(self) -> u32 {
        self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProtocolFloor(u32);

impl ProtocolFloor {
    pub fn new(value: u32) -> Option<Self> {
        (value > 0).then_some(Self(value))
    }
    pub const fn minimum(self) -> u32 {
        self.0
    }
    pub const fn admits(self, client: ClientProtocol) -> bool {
        client.value() >= self.0
    }
    pub const fn supported(self) -> bool {
        self.0 <= ClientProtocol::SUPPORTED.value()
    }
}

/// Public connection metadata introduced by protocol 2. Credentials never join this list.
pub const CONNECTION_COLUMNS: &[&str] = &[
    "peerProfile",
    "agentId",
    "protocolRetiredAt",
    "protocolRetiredReason",
];

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn support_does_not_activate_and_floor_is_positive() {
        let floor = ProtocolFloor::new(1).unwrap();
        assert!(floor.admits(ClientProtocol::LEGACY));
        assert!(floor.admits(ClientProtocol::SUPPORTED));
        assert!(!ProtocolFloor::new(2)
            .unwrap()
            .admits(ClientProtocol::LEGACY));
        assert!(ProtocolFloor::new(0).is_none());
        assert!(!ProtocolFloor::new(3).unwrap().supported());
    }
}
