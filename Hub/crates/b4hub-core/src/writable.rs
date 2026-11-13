//! Which columns a phone may write and which merge last-writer-wins. The lists equal the Swift
//! client's `SyncColumns` (`Sources/WorkspaceProtocol/HybridClock.swift`); change them together.
//! A table or column not listed is Mac-only.

/// `(table, column)` pairs a phone (an `ios` or `cli` device) may write.
pub const PHONE_WRITABLE: &[(&str, &str)] = &[
    ("threads", "title"),
    ("threads", "pinned"),
    ("threads", "archived"),
    ("threads", "readTurnId"),
    ("threads", "userDeletedAt"),
    ("threads", "model"),
    ("threads", "permission"),
    ("environments", "name"),
    ("drafts", "threadId"),
    ("drafts", "text"),
    ("drafts", "updatedAt"),
    ("viewSettings", "id"),
    ("viewSettings", "arrangement"),
    ("viewSettings", "quietThreads"),
    ("viewSettings", "showArchived"),
    ("viewSettings", "updatedAt"),
    ("viewSettings", "density"),
];

/// `(table, column)` pairs that merge by clock: the phone-writable ones plus `threads.environmentId`,
/// which only the Mac writes.
pub const CLOCKED: &[(&str, &str)] = &[
    ("threads", "title"),
    ("threads", "pinned"),
    ("threads", "archived"),
    ("threads", "readTurnId"),
    ("threads", "environmentId"),
    ("threads", "userDeletedAt"),
    ("threads", "model"),
    ("threads", "permission"),
    ("environments", "name"),
    ("drafts", "threadId"),
    ("drafts", "text"),
    ("drafts", "updatedAt"),
    ("viewSettings", "id"),
    ("viewSettings", "arrangement"),
    ("viewSettings", "quietThreads"),
    ("viewSettings", "showArchived"),
    ("viewSettings", "updatedAt"),
    ("viewSettings", "density"),
];

/// `(table, column)` pairs that are set once and never cleared: no device may set them to null.
pub const NEVER_CLEARED: &[(&str, &str)] = &[("threads", "userDeletedAt")];

/// True when a phone may write `table.column`.
pub fn is_phone_writable(table: &str, column: &str) -> bool {
    PHONE_WRITABLE.contains(&(table, column))
}

/// True when `table.column` is never cleared once set.
pub fn is_never_cleared(table: &str, column: &str) -> bool {
    NEVER_CLEARED.contains(&(table, column))
}

/// True when `table.column` merges by clock.
pub fn is_clocked(table: &str, column: &str) -> bool {
    CLOCKED.contains(&(table, column))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_phone_may_write_exactly_the_documented_columns() {
        assert_eq!(PHONE_WRITABLE.len(), 17);
        for (table, column) in [
            ("threads", "title"),
            ("threads", "pinned"),
            ("threads", "archived"),
            ("threads", "readTurnId"),
            ("threads", "userDeletedAt"),
            ("threads", "model"),
            ("threads", "permission"),
            ("environments", "name"),
            ("drafts", "threadId"),
            ("drafts", "text"),
            ("drafts", "updatedAt"),
            ("viewSettings", "id"),
            ("viewSettings", "arrangement"),
            ("viewSettings", "quietThreads"),
            ("viewSettings", "showArchived"),
            ("viewSettings", "updatedAt"),
            ("viewSettings", "density"),
        ] {
            assert!(is_phone_writable(table, column), "{table}.{column}");
        }
        for (table, column) in [
            ("threads", "environmentId"),
            ("threads", "continuity"),
            ("threads", "context"),
            ("environments", "manual"),
            ("environmentFolders", "path"),
            ("turns", "status"),
            ("connections", "label"),
            ("connections", "environmentId"),
            ("connections", "models"),
            ("connections", "commands"),
            ("connectionUsage", "tokens"),
        ] {
            assert!(!is_phone_writable(table, column), "{table}.{column}");
        }
    }

    #[test]
    fn clocked_is_phone_writable_plus_thread_environment() {
        let mut expected: Vec<_> = PHONE_WRITABLE.to_vec();
        expected.push(("threads", "environmentId"));
        let mut actual = CLOCKED.to_vec();
        expected.sort_unstable();
        actual.sort_unstable();
        assert_eq!(actual, expected);
        assert!(is_clocked("threads", "environmentId"));
        assert!(!is_clocked("threads", "continuity"));
    }
}
