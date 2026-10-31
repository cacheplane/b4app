//! Identifiers the hub mints itself. Synced rows keep their client text ids; everything the
//! hub creates (orgs, users, devices, tokens) is a UUIDv7 so ids sort by creation time.

use uuid::Uuid;

/// A fresh UUIDv7.
pub fn new_uuid() -> Uuid {
    Uuid::now_v7()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_version_7_and_unique() {
        let a = new_uuid();
        let b = new_uuid();
        assert_eq!(a.get_version_num(), 7);
        assert_ne!(a, b);
    }
}
