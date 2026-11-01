//! The snapshot a reader restores from when its cursor is behind the pruned feed: the user's rows
//! as the hub holds them, rewritten as synthetic inserts, with the column clocks and the cursor
//! to continue from. Everything is read in one `REPEATABLE READ` transaction, so the rows, the
//! clocks, and `next` are one consistent instant even while pushes land.

use b4hub_core::change::{
    table_spec, ChangeOp, Snapshot, SnapshotClock, StoredChange, SYNCED_TABLES,
};
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
const HUB_COLUMNS: &str = "{org_id,user_id,device_id,owner_device_id}";

/// Reads `auth`'s user's state. `changes` lists every row of every synced table in dependency
/// order as an `insert` with `hubSeq` 0, `deviceSeq` 0, `deviceId` the row's owner, `value` the
/// Mac columns only, and `hlc` the greatest clock of the row's columns (the zero clock of its
/// owner if none). `clocks` lists every column clock of those rows. `next` is the highest
/// `hubSeq` the org's feed had at that instant, or its horizon if pruning has emptied the feed,
/// so a pull from `next` is neither stale nor missing a change.
pub async fn take(db: &Db, auth: &AuthedDevice) -> Result<Snapshot> {
    let mut tx = db.read_tx(auth.org_id).await?;
    let mut changes = Vec::new();
    let mut clocks = Vec::new();

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
             WHERE t.org_id = $1 AND t.user_id = $2 \
             ORDER BY t.{key} COLLATE \"C\""
        ))
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(spec.name)
        .fetch_all(&mut *tx)
        .await?;
        for (row_id, owner, value, clock) in rows {
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
                .map(|(row_id, column, hlc)| SnapshotClock {
                    table: spec.name.to_string(),
                    row_id,
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
