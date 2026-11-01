//! Change ingest and the feed. A device uploads its changes in batches; the hub records each in
//! the org's `changes` feed (idempotently, on the device's own sequence) and, the first time it
//! sees a change, applies it to the mirrored tables with the same semantics as the Mac's replay:
//! an insert upserts the columns it carries, an update sets one column, a delete deletes. A
//! change that cannot apply (an unknown table, a missing parent, a malformed shape) is still
//! recorded, so every device's feed stays complete, but it is skipped and counted.
//!
//! Concurrent edits converge by clock. Every change carries a hybrid logical clock (clamped if it
//! is more than five minutes ahead of the hub's wall clock); a column that merges
//! last-writer-wins (`threads.title`, ...) takes a change only when its clock is greater than the
//! clock of the change that last set it, recorded in `column_clocks`. A change that loses is
//! still recorded: the log is the history. Two kinds of change are refused outright, reported
//! per change and not recorded, so no other device ever sees them: one a phone may not make
//! (anything but its writable columns and draft inserts) and a value over the size limit.
//!
//! Every statement runs in a tenant transaction. Mirrored rows are also keyed to the pushing
//! user: ids are client-chosen and unique only per org, so a second user of the org pushing the
//! same row id can neither overwrite, update, delete, nor adopt as a parent the first user's row.

pub use b4hub_core::change::MAX_PAGE_BYTES;
use b4hub_core::change::{
    is_scrubbed, table_spec, Change, ChangeOp, TableSpec, MAX_PAYLOAD_BYTES, MAX_PULL_LIMIT,
};
pub use b4hub_core::change::{Page, StoredChange};
use b4hub_core::hlc::Hlc;
use b4hub_core::writable::{is_clocked, is_phone_writable};
use futures_util::TryStreamExt;
use serde_json::Value;
use sqlx::postgres::PgConnection;
use sqlx::types::Uuid;
use sqlx::{Acquire, FromRow, Postgres, Transaction};

use crate::devices::{AuthedDevice, Platform};
use crate::{Db, Error, Result};

/// What happened to one change that was new to the hub.
enum Applied {
    Yes,
    Skipped,
    /// A clocked column whose stored clock is newer; nothing was written.
    Lost,
}

/// A phone changed something only the Mac may change.
pub const COLUMN_NOT_WRITABLE: &str = "column_not_writable";

/// A change carries an `hlc` that is not in the clock form. A change with none is fine: it gets
/// one derived from its `wall`.
pub const INVALID_CLOCK: &str = "invalid_clock";

/// A change's `value` is over [`MAX_PAYLOAD_BYTES`].
pub const PAYLOAD_TOO_LARGE: &str = "payload_too_large";

/// A change the hub refused: not recorded, not applied, reported to the pusher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rejected {
    pub device_seq: i64,
    pub code: &'static str,
}

/// The result of a push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushOutcome {
    /// The highest `device_seq` in the batch, refused changes included, so the client does not
    /// resend them.
    pub accepted_through: i64,
    pub rejected: Vec<Rejected>,
}

/// Why `auth` may not make `change`, if it may not.
fn refusal(auth: &AuthedDevice, change: &Change) -> Option<&'static str> {
    let phone_allowed = match change.op {
        ChangeOp::Insert => change.table == "drafts",
        ChangeOp::Update => change
            .column
            .as_deref()
            .is_some_and(|column| is_phone_writable(&change.table, column)),
        ChangeOp::Delete => false,
    };
    if auth.platform != Platform::Macos && !phone_allowed {
        return Some(COLUMN_NOT_WRITABLE);
    }
    if change.value_bytes() > MAX_PAYLOAD_BYTES {
        return Some(PAYLOAD_TOO_LARGE);
    }
    if change
        .hlc
        .as_deref()
        .is_some_and(|hlc| Hlc::parse(hlc).is_none())
    {
        return Some(INVALID_CLOCK);
    }
    None
}

/// The wall clock in milliseconds since the epoch.
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(0))
}

/// The clock a change is stored and merged under: the one it carries (a malformed one was
/// refused before this) or, for a client that sends none, one derived from its wall time,
/// clamped to `now`.
fn stamp(auth: &AuthedDevice, change: &Change, now: u64) -> Hlc {
    let sent = change
        .hlc
        .as_deref()
        .and_then(Hlc::parse)
        .unwrap_or_else(|| Hlc::derived(change.wall, &auth.device_id.to_string()));
    let kept = sent.clamped(now);
    if kept != sent {
        tracing::info!(
            device = %auth.device_id,
            sent = %sent,
            kept = %kept,
            "clamped a change clock that was more than five minutes ahead"
        );
    }
    kept
}

/// Takes the org's push lock until the end of `tx`. Pushes to one org run one at a time, and so
/// does pruning its feed, so a prune never deletes rows a push is committing.
pub(crate) async fn lock_org(tx: &mut Transaction<'_, Postgres>, org_id: Uuid) -> Result<()> {
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended('b4hub.changes:' || $1, 0))")
        .bind(org_id.to_string())
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// The oldest cursor the org's feed can serve: pruning has deleted every change up to and
/// including it. 0 until the org is first pruned.
pub(crate) async fn horizon(tx: &mut Transaction<'_, Postgres>, org_id: Uuid) -> Result<i64> {
    let horizon: Option<i64> =
        sqlx::query_scalar("SELECT horizon FROM org_sync_horizons WHERE org_id = $1")
            .bind(org_id)
            .fetch_optional(&mut **tx)
            .await?;
    Ok(horizon.unwrap_or(0))
}

/// Records and applies `batch` for `auth`'s device in one transaction and returns
/// `acceptedThrough`: the highest `device_seq` in the batch (for an empty batch, the highest the
/// device has had accepted so far, or 0), with the changes the hub refused. Changes the hub
/// already has, by `(device, device_seq)`, count as accepted and are not applied again, so a
/// retried batch is harmless.
pub async fn push(db: &Db, auth: &AuthedDevice, batch: &[Change]) -> Result<PushOutcome> {
    let mut tx = db.tenant_tx(auth.org_id).await?;

    // Pushes to one org run one at a time. `hub_seq` is allocated before commit, so without
    // this a slow transaction could commit sequence 11 after a reader had already seen 12 and
    // moved its cursor past 11. Holding the lock until commit makes commit order the sequence
    // order. Reads never take it.
    lock_org(&mut tx, auth.org_id).await?;

    let now = now_ms();
    let mut rejected = Vec::new();
    let (mut applied, mut skipped, mut lost, mut duplicates) = (0usize, 0usize, 0usize, 0usize);
    for change in batch {
        if let Some(code) = refusal(auth, change) {
            tracing::warn!(
                device = %auth.device_id,
                device_seq = change.device_seq,
                code,
                "refused a change"
            );
            rejected.push(Rejected {
                device_seq: change.device_seq,
                code,
            });
            continue;
        }
        let hlc = stamp(auth, change, now);
        let recorded: Option<i64> = sqlx::query_scalar(
            "INSERT INTO changes \
                 (org_id, device_id, device_seq, user_id, wall, \"table\", row_id, op, \"column\", \
                  value, hlc) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) \
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
        .bind(hlc.as_str())
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
        match apply(&mut savepoint, auth, change, &hlc).await {
            Ok(Applied::Yes) => {
                savepoint.commit().await?;
                applied += 1;
            }
            Ok(Applied::Lost) => {
                savepoint.rollback().await?;
                lost += 1;
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
        tracing::debug!(applied, lost, duplicates, "push applied");
    }
    Ok(PushOutcome {
        accepted_through: accepted,
        rejected,
    })
}

/// Pulls up to `limit` (clamped to 1 to the page maximum) of `auth`'s user's changes with
/// `hub_seq > after`, oldest first. The page also stops before the row that would take the sum of
/// the `value` sizes past [`MAX_PAGE_BYTES`], but always holds the first row; `more` is true
/// when it stopped early for either reason. The feed is scoped to the user, not the device: a
/// second device of the same user sees the first one's changes, and another user of the org sees
/// none of them.
///
/// A cursor below the org's horizon (the feed was pruned past it) is [`Error::ResyncRequired`].
/// The horizon and the rows are read in one snapshot, so a prune cannot slip between them and
/// leave the reader silently missing the rows it deleted.
pub async fn pull(db: &Db, auth: &AuthedDevice, after: i64, limit: usize) -> Result<Page> {
    let limit = limit.clamp(1, MAX_PULL_LIMIT);
    let mut tx = db.read_tx(auth.org_id).await?;
    if after < horizon(&mut tx, auth.org_id).await? {
        return Err(Error::ResyncRequired);
    }

    // Rows stream in, so a page that stops early at the byte limit never holds more than the
    // one row that did not fit. One extra row says whether another page follows.
    let mut changes: Vec<StoredChange> = Vec::new();
    let mut more = false;
    {
        let mut rows = sqlx::query_as::<_, Row>(
            "SELECT hub_seq, device_id, device_seq, wall, \"table\" AS table_name, row_id, op, \
                    \"column\" AS column_name, value, hlc \
             FROM changes \
             WHERE org_id = $1 AND user_id = $2 AND hub_seq > $3 \
             ORDER BY hub_seq \
             LIMIT $4",
        )
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(after)
        .bind(limit as i64 + 1)
        .fetch(&mut *tx);
        let mut bytes = 0usize;
        while let Some(row) = rows.try_next().await? {
            let stored = row.into_stored()?;
            if changes.len() == limit
                || (!changes.is_empty() && bytes + stored.value_bytes() > MAX_PAGE_BYTES)
            {
                more = true;
                break;
            }
            bytes += stored.value_bytes();
            changes.push(stored);
        }
    }
    tx.commit().await?;

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
    hlc: String,
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
            hlc: self.hlc,
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
async fn apply(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    change: &Change,
    hlc: &Hlc,
) -> Result<Applied> {
    let Some(spec) = table_spec(&change.table) else {
        return Ok(Applied::Skipped);
    };
    match change.op {
        ChangeOp::Insert => insert(conn, auth, spec, change, hlc).await,
        ChangeOp::Update => update(conn, auth, spec, change, hlc).await,
        ChangeOp::Delete => delete(conn, auth, spec, change).await,
    }
}

/// Records `hlc` as the clock of `table.column` of the row if it is greater than the stored one
/// (or there is none), and says whether it was. A losing clock changes nothing. The write is
/// inside the change's savepoint, so a change that then fails to apply gives the clock back.
async fn claim_clock(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    table: &str,
    row_id: &str,
    column: &str,
    hlc: &Hlc,
) -> Result<bool> {
    let won: Option<i32> = sqlx::query_scalar(
        "INSERT INTO column_clocks (org_id, \"table\", row_id, \"column\", hlc) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (org_id, \"table\", row_id, \"column\") DO UPDATE SET hlc = EXCLUDED.hlc \
         WHERE column_clocks.hlc COLLATE \"C\" < EXCLUDED.hlc COLLATE \"C\" \
         RETURNING 1",
    )
    .bind(auth.org_id)
    .bind(table)
    .bind(row_id)
    .bind(column)
    .bind(hlc.as_str())
    .fetch_optional(conn)
    .await?;
    Ok(won.is_some())
}

async fn insert(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    spec: &TableSpec,
    change: &Change,
    hlc: &Hlc,
) -> Result<Applied> {
    let Some(Value::Object(row)) = change.value.as_ref() else {
        return Ok(Applied::Skipped);
    };
    if !parent_exists(conn, auth, spec, row.get(parent_column(spec))).await? {
        return Ok(Applied::Skipped);
    }
    // The columns the row carries, minus the key (that is the change's rowId) and anything that
    // is not a Mac column: ownership columns can only come from the token. The scrubbed columns
    // are always written, as NULL. A clocked column is written only if this insert's clock beats
    // the clock of the change that last set it; it counts as set at that clock either way.
    let mut provided: Vec<&str> = Vec::new();
    for column in spec.columns.iter().copied() {
        if column == spec.key {
            continue;
        }
        let carried = is_scrubbed(spec.name, column) || row.contains_key(column);
        if carried
            && (!is_clocked(spec.name, column)
                || claim_clock(conn, auth, spec.name, &change.row_id, column, hlc).await?)
        {
            provided.push(column);
        }
    }

    let table = quote(spec.name);
    let key = quote(spec.key);
    // The inserting device is both the last writer and, because this is an insert, the owner.
    let mut columns = format!("org_id, user_id, device_id, owner_device_id, {key}");
    let mut selected = String::from("$1::uuid, $2::uuid, $3::uuid, $3::uuid, $4::text");
    let mut assignments =
        String::from("device_id = EXCLUDED.device_id, owner_device_id = EXCLUDED.owner_device_id");
    for column in &provided {
        let quoted = quote(column);
        columns.push_str(&format!(", {quoted}"));
        if is_scrubbed(spec.name, column) {
            selected.push_str(", NULL");
        } else {
            selected.push_str(&format!(", r.{quoted}"));
        }
        assignments.push_str(&format!(", {quoted} = EXCLUDED.{quoted}"));
    }
    let sql = format!(
        "INSERT INTO {table} ({columns}) \
         SELECT {selected} FROM jsonb_populate_record(NULL::{table}, $5::jsonb) AS r \
         ON CONFLICT (org_id, {key}) DO UPDATE SET {assignments} \
         WHERE {table}.user_id = EXCLUDED.user_id"
    );
    let written = sqlx::query(&sql)
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(auth.device_id)
        .bind(&change.row_id)
        .bind(change.value.as_ref())
        .execute(&mut *conn)
        .await?
        .rows_affected();
    // Nothing written means the row id belongs to another user; the clocks claimed above go back
    // with the savepoint.
    Ok(if written == 0 {
        Applied::Skipped
    } else {
        Applied::Yes
    })
}

async fn update(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    spec: &TableSpec,
    change: &Change,
    hlc: &Hlc,
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
    if is_clocked(spec.name, column)
        && !claim_clock(conn, auth, spec.name, &change.row_id, column, hlc).await?
    {
        return Ok(Applied::Lost);
    }

    // `jsonb_populate_record` converts the JSON value to the column's own type, the same way an
    // insert does; an absent or null value sets the column to NULL, and so does any value for a
    // scrubbed column.
    let value = if is_scrubbed(spec.name, column) {
        None
    } else {
        change.value.as_ref()
    };
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
        .bind(value)
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
        .execute(&mut *conn)
        .await?
        .rows_affected();
    if deleted == 0 {
        return Ok(Applied::Skipped);
    }
    // The row's clocks go with it.
    sqlx::query("DELETE FROM column_clocks WHERE org_id = $1 AND \"table\" = $2 AND row_id = $3")
        .bind(auth.org_id)
        .bind(spec.name)
        .bind(&change.row_id)
        .execute(conn)
        .await?;
    Ok(Applied::Yes)
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
