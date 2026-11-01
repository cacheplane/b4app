//! Which columns a phone may write and which merge last-writer-wins. The lists equal the Swift
//! client's `SyncColumns` (`Sources/WorkspaceProtocol/HybridClock.swift`); change them together.
//! A table or column not listed is Mac-only.

/// `(table, column)` pairs a phone (an `ios` or `cli` device) may write.
pub const PHONE_WRITABLE: &[(&str, &str)] = &[
    ("threads", "title"),
    ("threads", "pinned"),
    ("threads", "archived"),
    ("threads", "readTurnId"),
    ("projects", "name"),
    ("drafts", "threadId"),
    ("drafts", "text"),
    ("drafts", "updatedAt"),
];

/// `(table, column)` pairs that merge by clock: the phone-writable ones plus `threads.projectId`,
/// which only the Mac writes.
pub const CLOCKED: &[(&str, &str)] = &[
    ("threads", "title"),
    ("threads", "pinned"),
    ("threads", "archived"),
    ("threads", "readTurnId"),
    ("threads", "projectId"),
    ("projects", "name"),
    ("drafts", "threadId"),
    ("drafts", "text"),
    ("drafts", "updatedAt"),
];

/// True when a phone may write `table.column`.
pub fn is_phone_writable(table: &str, column: &str) -> bool {
    PHONE_WRITABLE.contains(&(table, column))
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
        assert_eq!(PHONE_WRITABLE.len(), 8);
        for (table, column) in [
            ("threads", "title"),
            ("threads", "pinned"),
            ("threads", "archived"),
            ("threads", "readTurnId"),
            ("projects", "name"),
            ("drafts", "threadId"),
            ("drafts", "text"),
            ("drafts", "updatedAt"),
        ] {
            assert!(is_phone_writable(table, column), "{table}.{column}");
        }
        for (table, column) in [
            ("threads", "projectId"),
            ("threads", "continuity"),
            ("threads", "context"),
            ("projects", "manual"),
            ("projectFolders", "path"),
            ("turns", "status"),
            ("connections", "label"),
        ] {
            assert!(!is_phone_writable(table, column), "{table}.{column}");
        }
    }

    #[test]
    fn clocked_is_phone_writable_plus_thread_project() {
        let mut expected: Vec<_> = PHONE_WRITABLE.to_vec();
        expected.push(("threads", "projectId"));
        let mut actual = CLOCKED.to_vec();
        expected.sort_unstable();
        actual.sort_unstable();
        assert_eq!(actual, expected);
        assert!(is_clocked("threads", "projectId"));
        assert!(!is_clocked("threads", "continuity"));
    }
}
