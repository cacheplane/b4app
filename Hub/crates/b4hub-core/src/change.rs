//! The change record that travels between a device and the hub, and the static description of
//! the synced tables it applies to. The wire form is camelCase and matches the Swift client's
//! `ChangeRecord` minus its local-only fields (`seq` is `deviceSeq`; the device id is not sent,
//! the hub attributes every change to the authenticated device; `synced` never leaves the Mac).

use std::io::{self, Write};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

/// The largest serialised `value` the hub accepts in one change, in bytes. The client replaces a
/// `displayItems.payload` above 1 MiB with a truncation marker before upload, so a value over
/// this limit means a broken or hostile client; the hub refuses rather than truncating.
pub const MAX_PAYLOAD_BYTES: usize = 2 * 1024 * 1024;

/// The most changes one push may carry. The client sends batches of 500.
pub const MAX_PUSH_CHANGES: usize = 1000;

/// The most changes one pull page returns, and the default.
pub const MAX_PULL_LIMIT: usize = 1000;

/// The most `value` bytes (serialised JSON, summed) one pull page carries. A page stops before the
/// row that would pass this, but always holds at least one row.
pub const MAX_PAGE_BYTES: usize = 8 * 1024 * 1024;

/// The tables whose rows sync, in dependency order.
pub const SYNCED_TABLES: [&str; 8] = [
    "connections",
    "projects",
    "projectFolders",
    "threads",
    "turns",
    "displayItems",
    "runtimeRequests",
    "drafts",
];

/// A synced table as the hub mirrors it: the Mac's column names (quoted camelCase), its key, and
/// the parent row a child must have before the hub applies it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TableSpec {
    pub name: &'static str,
    /// The key column; `drafts` is keyed by `threadId`, everything else by `id`.
    pub key: &'static str,
    /// Every Mac column, key included. Only these names ever reach SQL.
    pub columns: &'static [&'static str],
    /// `(column, table)`: the column must name an existing row of the table (same org and user)
    /// or the change is skipped.
    pub parent: Option<(&'static str, &'static str)>,
}

const TABLES: [TableSpec; 8] = [
    TableSpec {
        name: "connections",
        key: "id",
        columns: &[
            "id",
            "kind",
            "label",
            "enabled",
            "profileRevision",
            "target",
            "routeKey",
            "b4Mode",
            "localServerId",
            "authReference",
            "nativeScope",
            "capabilities",
            "status",
            "authStatus",
            "createdAt",
            "updatedAt",
        ],
        parent: None,
    },
    TableSpec {
        name: "projects",
        key: "id",
        columns: &["id", "name", "manual", "createdAt", "updatedAt"],
        parent: None,
    },
    TableSpec {
        name: "projectFolders",
        key: "id",
        columns: &["id", "projectId", "path", "createdAt"],
        parent: Some(("projectId", "projects")),
    },
    TableSpec {
        name: "threads",
        key: "id",
        columns: &[
            "id",
            "connectionId",
            "nativeThreadId",
            "nativeScope",
            "title",
            "context",
            "pinned",
            "archived",
            "continuity",
            "createdAt",
            "updatedAt",
            "projectId",
            "readTurnId",
        ],
        parent: Some(("connectionId", "connections")),
    },
    TableSpec {
        name: "turns",
        key: "id",
        columns: &[
            "id",
            "threadId",
            "operationId",
            "nativeTurnId",
            "inputRef",
            "status",
            "submission",
            "outcome",
            "createdAt",
            "updatedAt",
        ],
        parent: Some(("threadId", "threads")),
    },
    TableSpec {
        name: "displayItems",
        key: "id",
        columns: &[
            "id",
            "threadId",
            "turnId",
            "nativeItemId",
            "role",
            "type",
            "payload",
            "sequence",
            "provenance",
            "createdAt",
        ],
        parent: Some(("threadId", "threads")),
    },
    TableSpec {
        name: "runtimeRequests",
        key: "id",
        columns: &[
            "id",
            "nativeRequestId",
            "threadId",
            "turnId",
            "adapterGeneration",
            "kind",
            "state",
            "payload",
            "createdAt",
            "updatedAt",
        ],
        parent: Some(("threadId", "threads")),
    },
    TableSpec {
        name: "drafts",
        key: "threadId",
        columns: &["threadId", "text", "updatedAt"],
        parent: Some(("threadId", "threads")),
    },
];

/// Columns the hub sets NULL on every insert and update, whatever the change carries. The Mac
/// blanks them before upload (they name local executables, servers, and secret references that
/// mean nothing off the Mac); the hub does not trust that.
pub const SCRUBBED_COLUMNS: &[(&str, &str)] = &[
    ("connections", "authReference"),
    ("connections", "localServerId"),
    ("connections", "target"),
];

/// True when the hub nulls `table.column` on write.
pub fn is_scrubbed(table: &str, column: &str) -> bool {
    SCRUBBED_COLUMNS.contains(&(table, column))
}

/// The description of a synced table; `None` for any other name (including `localServers`,
/// which never syncs).
pub fn table_spec(name: &str) -> Option<&'static TableSpec> {
    TABLES.iter().find(|spec| spec.name == name)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChangeOp {
    Insert,
    Update,
    Delete,
}

impl ChangeOp {
    pub fn as_str(self) -> &'static str {
        match self {
            ChangeOp::Insert => "insert",
            ChangeOp::Update => "update",
            ChangeOp::Delete => "delete",
        }
    }

    pub fn parse(text: &str) -> Option<ChangeOp> {
        match text {
            "insert" => Some(ChangeOp::Insert),
            "update" => Some(ChangeOp::Update),
            "delete" => Some(ChangeOp::Delete),
            _ => None,
        }
    }
}

/// One change as a device uploads it. For `insert`, `value` is the whole row; for `update`,
/// `column` names the column and `value` is its new value (absent or null sets it to NULL); for
/// `delete`, both are absent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Change {
    /// The change's sequence on the device that wrote it: unique per device, increasing.
    pub device_seq: i64,
    /// Milliseconds since the epoch on the origin device.
    pub wall: i64,
    pub table: String,
    pub row_id: String,
    pub op: ChangeOp,
    pub column: Option<String>,
    pub value: Option<Value>,
    /// The hybrid logical clock the writing device stamped on the change (see [`crate::hlc`]).
    /// Absent from an M8a client; the hub then derives one from `wall`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hlc: Option<String>,
}

impl Change {
    /// The serialised size of `value` in bytes (0 when absent).
    pub fn value_bytes(&self) -> usize {
        self.value.as_ref().map_or(0, json_len)
    }
}

/// A change as the hub stores and serves it: the uploaded change plus where it sits in the
/// org's feed and which device wrote it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredChange {
    pub hub_seq: i64,
    pub device_id: Uuid,
    pub device_seq: i64,
    pub wall: i64,
    pub table: String,
    pub row_id: String,
    pub op: ChangeOp,
    pub column: Option<String>,
    pub value: Option<Value>,
    /// The change's clock after the hub's clamp.
    pub hlc: String,
}

impl StoredChange {
    /// The serialised size of `value` in bytes (0 when absent): the same measure as
    /// [`Change::value_bytes`], which is what [`MAX_PAGE_BYTES`] sums.
    pub fn value_bytes(&self) -> usize {
        self.value.as_ref().map_or(0, json_len)
    }
}

/// One page of the feed. `next` is the cursor for the following request: the last returned
/// `hubSeq`, or the requested `after` when the page is empty.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Page {
    pub changes: Vec<StoredChange>,
    pub next: i64,
    pub more: bool,
}

/// One entry of a snapshot's `clocks`: the clock of the change that last set a clocked column of
/// a row, so a client that restores from the snapshot can keep merging by clock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotClock {
    pub table: String,
    pub row_id: String,
    pub column: String,
    pub hlc: String,
}

/// The user's synced state as of one instant, for a reader whose cursor is older than the
/// retained feed. `changes` are synthetic inserts (`hubSeq` 0) in dependency order; `next` is
/// the cursor to pull from afterwards.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    pub changes: Vec<StoredChange>,
    pub clocks: Vec<SnapshotClock>,
    pub next: i64,
}

/// The length of `value` serialised as JSON, without building the string.
fn json_len(value: &Value) -> usize {
    struct Counter(usize);
    impl Write for Counter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.0 += buf.len();
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut counter = Counter(0);
    // Serialising a `Value` into a writer that never fails cannot fail.
    let _ = serde_json::to_writer(&mut counter, value);
    counter.0
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const FIXTURE: &str = include_str!("../../../../Tests/Fixtures/sync/changes.json");

    #[test]
    fn change_round_trips_camel_case() {
        let wire = json!({
            "deviceSeq": 7,
            "wall": 1761900000000_i64,
            "table": "threads",
            "rowId": "thread-1",
            "op": "update",
            "column": "title",
            "value": "New title",
        });
        let change: Change = serde_json::from_value(wire.clone()).unwrap();
        assert_eq!(change.device_seq, 7);
        assert_eq!(change.row_id, "thread-1");
        assert_eq!(change.op, ChangeOp::Update);
        assert_eq!(change.column.as_deref(), Some("title"));
        assert_eq!(serde_json::to_value(&change).unwrap(), wire);

        let minimal =
            json!({"deviceSeq": 1, "wall": 2, "table": "drafts", "rowId": "t", "op": "delete"});
        let delete: Change = serde_json::from_value(minimal).unwrap();
        assert_eq!(delete.op, ChangeOp::Delete);
        assert_eq!(
            (delete.column, delete.value, delete.hlc),
            (None, None, None)
        );

        let clocked = json!({"deviceSeq": 1, "wall": 2, "table": "drafts", "rowId": "t",
                             "op": "delete", "hlc": "000000000002-0001-dev"});
        let change: Change = serde_json::from_value(clocked.clone()).unwrap();
        assert_eq!(change.hlc.as_deref(), Some("000000000002-0001-dev"));
        assert_eq!(
            serde_json::to_value(&change).unwrap()["hlc"],
            clocked["hlc"]
        );
    }

    #[test]
    fn unknown_fields_and_ops_are_refused() {
        let extra = json!({"deviceSeq": 1, "wall": 2, "table": "t", "rowId": "r", "op": "insert", "deviceId": "x"});
        assert!(serde_json::from_value::<Change>(extra).is_err());
        let op = json!({"deviceSeq": 1, "wall": 2, "table": "t", "rowId": "r", "op": "upsert"});
        assert!(serde_json::from_value::<Change>(op).is_err());
    }

    #[test]
    fn stored_changes_add_hub_seq_and_device_id() {
        let stored = StoredChange {
            hub_seq: 3,
            device_id: Uuid::from_u128(9),
            device_seq: 2,
            wall: 4,
            table: "turns".into(),
            row_id: "turn-1".into(),
            op: ChangeOp::Delete,
            column: None,
            value: None,
            hlc: "000000000004-0000-dev".into(),
        };
        let wire = serde_json::to_value(&stored).unwrap();
        assert_eq!(wire["hubSeq"], 3);
        assert_eq!(wire["deviceId"], "00000000-0000-0000-0000-000000000009");
        assert_eq!(wire["op"], "delete");
        assert_eq!(wire["hlc"], "000000000004-0000-dev");
        assert_eq!(
            serde_json::from_value::<StoredChange>(wire).unwrap(),
            stored
        );
    }

    #[test]
    fn fixture_decodes() {
        let changes: Vec<Change> = serde_json::from_str(FIXTURE).unwrap();
        assert_eq!(changes.len(), 12);
        let seqs: Vec<i64> = changes.iter().map(|c| c.device_seq).collect();
        assert_eq!(seqs, (1..=12).collect::<Vec<_>>());
        // Every change names a synced table, and the one big payload is over the limit.
        assert!(changes.iter().all(|c| table_spec(&c.table).is_some()));
        let oversize: Vec<&str> = changes
            .iter()
            .filter(|c| c.value_bytes() > MAX_PAYLOAD_BYTES)
            .map(|c| c.row_id.as_str())
            .collect();
        assert_eq!(oversize, vec!["item-3"]);
        // Every entry carries a clock, derived from its wall and one device id.
        for change in &changes {
            let hlc = crate::hlc::Hlc::parse(change.hlc.as_deref().unwrap()).unwrap();
            assert_eq!(hlc.millis() as i64, change.wall);
            assert_eq!(hlc.counter(), 0);
            assert_eq!(hlc.device_id(), "01a194cf-0d12-7418-b3b5-5559dbee2441");
        }
        // The connection still carries what the client blanks before upload.
        let connection = changes[0].value.as_ref().unwrap();
        assert_eq!(connection["authReference"], "secret:abc");
        assert_eq!(connection["target"], "/usr/local/bin/codex");
    }

    #[test]
    fn every_fixture_row_uses_only_known_columns() {
        let changes: Vec<Change> = serde_json::from_str(FIXTURE).unwrap();
        for change in changes.iter().filter(|c| c.op == ChangeOp::Insert) {
            let spec = table_spec(&change.table).unwrap();
            for column in change.value.as_ref().unwrap().as_object().unwrap().keys() {
                assert!(
                    spec.columns.contains(&column.as_str()),
                    "{}.{column} is not a Mac column",
                    spec.name
                );
            }
            assert!(spec.columns.contains(&spec.key));
        }
    }

    #[test]
    fn table_specs_match_the_synced_table_list() {
        for name in SYNCED_TABLES {
            let spec = table_spec(name).unwrap();
            assert_eq!(spec.name, name);
            assert_eq!(spec.key, if name == "drafts" { "threadId" } else { "id" });
        }
        assert!(table_spec("localServers").is_none());
        assert!(table_spec("changes").is_none());
    }

    #[test]
    fn value_bytes_is_the_serialised_length() {
        let change = |value: Option<Value>| Change {
            device_seq: 1,
            wall: 0,
            table: "threads".into(),
            row_id: "t".into(),
            op: ChangeOp::Update,
            column: Some("title".into()),
            value,
            hlc: None,
        };
        assert_eq!(change(None).value_bytes(), 0);
        let value = json!({"a": "é", "b": [1, 2.5, null]});
        assert_eq!(
            change(Some(value.clone())).value_bytes(),
            serde_json::to_string(&value).unwrap().len()
        );
    }
}
