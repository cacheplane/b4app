//! Change ingest and the feed. A device uploads its changes in batches; the hub records each in
//! the org's `changes` feed (idempotently, on the device's own sequence) and, the first time it
//! sees a change, applies it to the mirrored tables with the same semantics as the Mac's replay:
//! an insert upserts the columns it carries, an update sets one column, a delete deletes. A
//! change that cannot apply (an unknown table, a missing parent, a malformed shape) is still
//! recorded, so every device's feed stays complete, but it is skipped and counted.
//!
//! Every statement runs in a tenant transaction. Mirrored rows are also keyed to the pushing
//! user: ids are client-chosen and unique only per org, so a second user of the org pushing the
//! same row id can neither overwrite, update, delete, nor adopt as a parent the first user's row.

use b4hub_core::change::{table_spec, Change, ChangeOp, TableSpec, MAX_PULL_LIMIT};
pub use b4hub_core::change::{Page, StoredChange};
use serde_json::Value;
use sqlx::postgres::PgConnection;
use sqlx::types::Uuid;
use sqlx::{Acquire, FromRow};

use crate::devices::AuthedDevice;
use crate::{Db, Error, Result};

/// The oldest `hubSeq` a cursor may start from. M8a never prunes the feed, so every cursor from
/// 0 up is valid; a cursor below this gets `resync_required`.
pub const HORIZON: i64 = 0;

/// What happened to one change that was new to the hub.
enum Applied {
    Yes,
    Skipped,
}

/// Records and applies `batch` for `auth`'s device in one transaction and returns
/// `acceptedThrough`: the highest `device_seq` in the batch (for an empty batch, the highest the
/// device has had accepted so far, or 0). Changes the hub already has, by `(device, device_seq)`,
/// count as accepted and are not applied again, so a retried batch is harmless.
pub async fn push(db: &Db, auth: &AuthedDevice, batch: &[Change]) -> Result<i64> {
    let mut tx = db.tenant_tx(auth.org_id).await?;

    // Pushes to one org run one at a time. `hub_seq` is allocated before commit, so without
    // this a slow transaction could commit sequence 11 after a reader had already seen 12 and
    // moved its cursor past 11. Holding the lock until commit makes commit order the sequence
    // order. Reads never take it.
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended('b4hub.changes:' || $1, 0))")
        .bind(auth.org_id.to_string())
        .execute(&mut *tx)
        .await?;

    let (mut applied, mut skipped, mut duplicates) = (0usize, 0usize, 0usize);
    for change in batch {
        let recorded: Option<i64> = sqlx::query_scalar(
            "INSERT INTO changes \
                 (org_id, device_id, device_seq, user_id, wall, \"table\", row_id, op, \"column\", value) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) \
             ON CONFLICT (org_id, device_id, device_seq) DO NOTHING \
             RETURNING hub_seq",
        )
        .bind(auth.org_id)
        .bind(auth.device_id)
        .bind(change.device_seq)
        .bind(auth.user_id)
        .bind(change.wall)
        .bind(&change.table)
        .bind(&change.row_id)
        .bind(change.op.as_str())
        .bind(change.column.as_deref())
        .bind(change.value.as_ref())
        .fetch_optional(&mut *tx)
        .await?;
        if recorded.is_none() {
            duplicates += 1;
            continue;
        }

        // A savepoint per change: a value the column type refuses (a string for a boolean) rolls
        // back that one change instead of failing the batch, which the client would retry
        // forever.
        let mut savepoint = tx.begin().await?;
        match apply(&mut savepoint, auth, change).await {
            Ok(Applied::Yes) => {
                savepoint.commit().await?;
                applied += 1;
            }
            Ok(Applied::Skipped) => {
                savepoint.rollback().await?;
                skipped += 1;
            }
            Err(Error::Sqlx(error)) if is_data_error(&error) => {
                savepoint.rollback().await?;
                skipped += 1;
            }
            Err(error) => return Err(error),
        }
    }

    let accepted = match batch.iter().map(|c| c.device_seq).max() {
        Some(max) => max,
        None => {
            sqlx::query_scalar(
                "SELECT COALESCE(max(device_seq), 0) FROM changes WHERE device_id = $1",
            )
            .bind(auth.device_id)
            .fetch_one(&mut *tx)
            .await?
        }
    };
    tx.commit().await?;

    if skipped > 0 {
        tracing::warn!(
            skipped,
            applied,
            duplicates,
            "push recorded changes that could not be applied to the mirror"
        );
    } else {
        tracing::debug!(applied, duplicates, "push applied");
    }
    Ok(accepted)
}

/// Pulls up to `limit` (clamped to 1 to the page maximum) of `auth`'s user's changes with
/// `hub_seq > after`, oldest first. The feed is scoped to the user, not the device: a second
/// device of the same user sees the first one's changes, and another user of the org sees none
/// of them.
pub async fn pull(db: &Db, auth: &AuthedDevice, after: i64, limit: usize) -> Result<Page> {
    let limit = limit.clamp(1, MAX_PULL_LIMIT);
    let mut tx = db.tenant_tx(auth.org_id).await?;
    // One extra row says whether another page follows.
    let mut rows: Vec<Row> = sqlx::query_as(
        "SELECT hub_seq, device_id, device_seq, wall, \"table\" AS table_name, row_id, op, \
                \"column\" AS column_name, value \
         FROM changes \
         WHERE org_id = $1 AND user_id = $2 AND hub_seq > $3 \
         ORDER BY hub_seq \
         LIMIT $4",
    )
    .bind(auth.org_id)
    .bind(auth.user_id)
    .bind(after)
    .bind(limit as i64 + 1)
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;

    let more = rows.len() > limit;
    rows.truncate(limit);
    let changes = rows
        .into_iter()
        .map(Row::into_stored)
        .collect::<Result<Vec<_>>>()?;
    let next = changes.last().map_or(after, |c| c.hub_seq);
    Ok(Page {
        changes,
        next,
        more,
    })
}

#[derive(FromRow)]
struct Row {
    hub_seq: i64,
    device_id: Uuid,
    device_seq: i64,
    wall: i64,
    table_name: String,
    row_id: String,
    op: String,
    column_name: Option<String>,
    value: Option<Value>,
}

impl Row {
    fn into_stored(self) -> Result<StoredChange> {
        let op = ChangeOp::parse(&self.op)
            .ok_or_else(|| sqlx::Error::Decode("unknown change op in the feed".into()))?;
        Ok(StoredChange {
            hub_seq: self.hub_seq,
            device_id: self.device_id,
            device_seq: self.device_seq,
            wall: self.wall,
            table: self.table_name,
            row_id: self.row_id,
            op,
            column: self.column_name,
            value: self.value,
        })
    }
}

/// SQLSTATE class 22: the value does not fit the column (wrong type, out of range).
fn is_data_error(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|e| e.code())
        .is_some_and(|code| code.starts_with("22"))
}

/// Applies one change to its mirrored table. Table and column names reach SQL only from the
/// static [`TableSpec`], never from the change itself.
async fn apply(conn: &mut PgConnection, auth: &AuthedDevice, change: &Change) -> Result<Applied> {
    let Some(spec) = table_spec(&change.table) else {
        return Ok(Applied::Skipped);
    };
    match change.op {
        ChangeOp::Insert => insert(conn, auth, spec, change).await,
        ChangeOp::Update => update(conn, auth, spec, change).await,
        ChangeOp::Delete => delete(conn, auth, spec, change).await,
    }
}

async fn insert(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    spec: &TableSpec,
    change: &Change,
) -> Result<Applied> {
    let Some(Value::Object(row)) = change.value.as_ref() else {
        return Ok(Applied::Skipped);
    };
    if !parent_exists(conn, auth, spec, row.get(parent_column(spec))).await? {
        return Ok(Applied::Skipped);
    }
    // The columns the row carries, minus the key (that is the change's rowId) and anything that
    // is not a Mac column: ownership columns can only come from the token.
    let provided: Vec<&str> = spec
        .columns
        .iter()
        .copied()
        .filter(|column| *column != spec.key && row.contains_key(*column))
        .collect();

    let table = quote(spec.name);
    let key = quote(spec.key);
    let mut columns = format!("org_id, user_id, device_id, {key}");
    let mut selected = String::from("$1::uuid, $2::uuid, $3::uuid, $4::text");
    let mut assignments = String::from("device_id = EXCLUDED.device_id");
    for column in &provided {
        let column = quote(column);
        columns.push_str(&format!(", {column}"));
        selected.push_str(&format!(", r.{column}"));
        assignments.push_str(&format!(", {column} = EXCLUDED.{column}"));
    }
    let sql = format!(
        "INSERT INTO {table} ({columns}) \
         SELECT {selected} FROM jsonb_populate_record(NULL::{table}, $5::jsonb) AS r \
         ON CONFLICT (org_id, {key}) DO UPDATE SET {assignments} \
         WHERE {table}.user_id = EXCLUDED.user_id"
    );
    sqlx::query(&sql)
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(auth.device_id)
        .bind(&change.row_id)
        .bind(change.value.as_ref())
        .execute(conn)
        .await?;
    Ok(Applied::Yes)
}

async fn update(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    spec: &TableSpec,
    change: &Change,
) -> Result<Applied> {
    let Some(column) = change.column.as_deref() else {
        return Ok(Applied::Skipped);
    };
    if column == spec.key || !spec.columns.contains(&column) {
        return Ok(Applied::Skipped);
    }
    if column == parent_column(spec)
        && !parent_exists(conn, auth, spec, change.value.as_ref()).await?
    {
        return Ok(Applied::Skipped);
    }

    // `jsonb_populate_record` converts the JSON value to the column's own type, the same way an
    // insert does; an absent or null value sets the column to NULL.
    let table = quote(spec.name);
    let column_sql = quote(column);
    let sql = format!(
        "UPDATE {table} SET {column_sql} = r.{column_sql} \
         FROM jsonb_populate_record(NULL::{table}, jsonb_build_object($1::text, $2::jsonb)) AS r \
         WHERE {table}.org_id = $3 AND {table}.user_id = $4 AND {table}.{key} = $5",
        key = quote(spec.key),
    );
    let updated = sqlx::query(&sql)
        .bind(column)
        .bind(change.value.as_ref())
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(&change.row_id)
        .execute(conn)
        .await?
        .rows_affected();
    Ok(if updated == 0 {
        Applied::Skipped
    } else {
        Applied::Yes
    })
}

async fn delete(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    spec: &TableSpec,
    change: &Change,
) -> Result<Applied> {
    let sql = format!(
        "DELETE FROM {table} WHERE org_id = $1 AND user_id = $2 AND {key} = $3",
        table = quote(spec.name),
        key = quote(spec.key),
    );
    let deleted = sqlx::query(&sql)
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(&change.row_id)
        .execute(conn)
        .await?
        .rows_affected();
    Ok(if deleted == 0 {
        Applied::Skipped
    } else {
        Applied::Yes
    })
}

/// The column of `spec` that names its parent; `""` (matching no column) when it has none.
fn parent_column(spec: &TableSpec) -> &'static str {
    spec.parent.map_or("", |(column, _)| column)
}

/// True when `spec` has no parent, or `reference` is a string naming a row of the parent table
/// that belongs to this org and this user.
async fn parent_exists(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    spec: &TableSpec,
    reference: Option<&Value>,
) -> Result<bool> {
    let Some((_, parent_table)) = spec.parent else {
        return Ok(true);
    };
    let Some(Value::String(reference)) = reference else {
        return Ok(false);
    };
    let parent = table_spec(parent_table).expect("a parent is a synced table");
    let sql = format!(
        "SELECT EXISTS (SELECT 1 FROM {table} WHERE org_id = $1 AND user_id = $2 AND {key} = $3)",
        table = quote(parent.name),
        key = quote(parent.key),
    );
    let exists = sqlx::query_scalar(&sql)
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(reference)
        .fetch_one(conn)
        .await?;
    Ok(exists)
}

/// A quoted SQL identifier. The inputs are static names from [`TableSpec`], so this is for the
/// camelCase columns, not for defence; it still doubles quotes.
fn quote(identifier: &str) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}
