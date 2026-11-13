//! The snapshot a reader restores from when its cursor is behind the pruned feed: the user's rows
//! as the hub holds them (deleted rows left out, D-089), rewritten as synthetic inserts, with the
//! column clocks and the cursor to continue from. Everything is read in one `REPEATABLE READ`
//! transaction, so the rows, the clocks, and `next` are one consistent instant even while pushes
//! land.

use b4hub_core::change::{
    stored_row_id, table_spec, wire_row_id, ChangeOp, Snapshot, SnapshotClock, StoredChange,
    SYNCED_TABLES, USER_SETTINGS_TABLE, USER_SETTINGS_WIRE_ID,
};
use b4hub_core::protocol::{ClientProtocol, CONNECTION_COLUMNS};
use serde_json::Value;
use sqlx::types::Uuid;

use crate::devices::AuthedDevice;
use crate::{Db, Result};

/// The clock of a row that no clocked column ever set: the earliest possible one, owned by the
/// row's owner, so any later change of the row wins over it.
fn zero_clock(owner: Uuid) -> String {
    format!("000000000000-0000-{owner}")
}

/// The Mac's columns are the table's own; these are the hub's.
const HUB_COLUMNS: &str = "{org_id,user_id,device_id,owner_device_id,deleted_at}";

/// Reads `auth`'s user's state. `changes` lists every row of every synced table that is not
/// deleted, in dependency order, as an `insert` with `hubSeq` 0, `deviceSeq` 0, `deviceId` the
/// row's owner, `value` the Mac columns only, and `hlc` the greatest clock of the row's columns
/// (the zero clock of its owner if none). `clocks` lists every column clock of those rows. `next`
/// is the highest `hubSeq` the org's feed had at that instant, or its horizon if pruning has
/// emptied the feed, so a pull from `next` is neither stale nor missing a change.
///
/// The user's settings row, stored as `view:<userId>`, is served under its wire id `view` (the
/// row id, the value's `id`, and its clocks' row ids). Any other settings row of the user, and
/// its clocks, is left out: a device could not write it, and during a rolling deploy an old hub
/// task can still store one named `view`.
pub async fn take(db: &Db, auth: &AuthedDevice) -> Result<Snapshot> {
    take_for_protocol(db, auth, ClientProtocol::LEGACY).await
}

pub async fn take_for_protocol(
    db: &Db,
    auth: &AuthedDevice,
    client: ClientProtocol,
) -> Result<Snapshot> {
    let (mut tx, floor) = db.protocol_read_tx(auth.org_id, client).await?;
    let mut changes = Vec::new();
    let mut clocks = Vec::new();

    let own_settings = stored_row_id(USER_SETTINGS_TABLE, USER_SETTINGS_WIRE_ID, auth.user_id);
    // True for a row the snapshot serves: every row but a settings row other than the user's.
    let served = |table: &str, row_id: &str| table != USER_SETTINGS_TABLE || row_id == own_settings;

    for name in SYNCED_TABLES {
        let spec = table_spec(name).expect("a synced table has a spec");
        let table = quote(spec.name);
        let key = quote(spec.key);
        // Names reach SQL only from the static spec.
        let rows: Vec<(String, Uuid, Value, Option<String>)> = sqlx::query_as(&format!(
            "SELECT t.{key}, t.owner_device_id, to_jsonb(t) - '{HUB_COLUMNS}'::text[], \
                    (SELECT max(c.hlc COLLATE \"C\") FROM column_clocks c \
                     WHERE c.org_id = t.org_id AND c.\"table\" = $3 AND c.row_id = t.{key}) \
             FROM {table} t \
             WHERE t.org_id = $1 AND t.user_id = $2 AND t.deleted_at IS NULL \
             ORDER BY t.{key} COLLATE \"C\""
        ))
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(spec.name)
        .fetch_all(&mut *tx)
        .await?;
        for (row_id, owner, mut value, clock) in rows {
            if !served(spec.name, &row_id) {
                continue;
            }
            let row_id = wire_row_id(spec.name, &row_id, auth.user_id).to_string();
            if spec.name == USER_SETTINGS_TABLE {
                if let Value::Object(columns) = &mut value {
                    columns.insert(spec.key.to_string(), Value::String(row_id.clone()));
                }
            }
            if spec.name == "connections" && floor.minimum() < 2 {
                if let Some(object) = value.as_object_mut() {
                    for column in CONNECTION_COLUMNS {
                        object.remove(*column);
                    }
                }
            }
            changes.push(StoredChange {
                hub_seq: 0,
                device_id: owner,
                device_seq: 0,
                wall: 0,
                table: spec.name.to_string(),
                row_id,
                op: ChangeOp::Insert,
                column: None,
                value: Some(value),
                hlc: clock.unwrap_or_else(|| zero_clock(owner)),
            });
        }

        let table_clocks: Vec<(String, String, String)> = sqlx::query_as(&format!(
            "SELECT c.row_id, c.\"column\", c.hlc \
             FROM column_clocks c JOIN {table} t ON t.org_id = c.org_id AND t.{key} = c.row_id \
             WHERE c.org_id = $1 AND c.\"table\" = $3 AND t.user_id = $2 \
                   AND t.deleted_at IS NULL \
             ORDER BY c.row_id COLLATE \"C\", c.\"column\" COLLATE \"C\""
        ))
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(spec.name)
        .fetch_all(&mut *tx)
        .await?;
        clocks.extend(
            table_clocks
                .into_iter()
                .filter(|(row_id, _, _)| served(spec.name, row_id))
                .map(|(row_id, column, hlc)| SnapshotClock {
                    table: spec.name.to_string(),
                    row_id: wire_row_id(spec.name, &row_id, auth.user_id).to_string(),
                    column,
                    hlc,
                }),
        );
    }

    let next: i64 = sqlx::query_scalar(
        "SELECT GREATEST(COALESCE((SELECT max(hub_seq) FROM changes WHERE org_id = $1), 0), \
                         COALESCE((SELECT horizon FROM org_sync_horizons WHERE org_id = $1), 0))",
    )
    .bind(auth.org_id)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Snapshot {
        changes,
        clocks,
        next,
    })
}

fn quote(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}
