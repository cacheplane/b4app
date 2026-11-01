//! Pruning the change log. The hub keeps the feed for a retention period; older changes are
//! deleted and the org's horizon moves up to the last one deleted, so a reader whose cursor is
//! behind it restores from the snapshot (`snapshot`) instead of silently missing changes. The
//! materialised tables are untouched: the log is history, the tables are state.

use std::time::Duration;

use sqlx::types::Uuid;

use crate::changes::{horizon, lock_org};
use crate::{Db, Result};

/// Deletes `org_id`'s changes received more than `older_than` ago, and every change with a lower
/// `hub_seq` (the horizon is one cursor, so what is kept is a contiguous tail), and records the
/// new horizon, which it returns. When nothing is old enough it returns the horizon
/// the org already had, and the horizon never moves down.
///
/// Takes the org's push lock for its one transaction, the same lock a push holds, so it waits
/// for a push in flight and a push waits for it: it can never delete rows a concurrent push is
/// committing, and a push's `hub_seq` order is untouched. Callers prune one org at a time.
pub async fn prune(db: &Db, org_id: Uuid, older_than: Duration) -> Result<i64> {
    let mut tx = db.tenant_tx(org_id).await?;
    lock_org(&mut tx, org_id).await?;

    let current = horizon(&mut tx, org_id).await?;
    let cutoff: Option<i64> = sqlx::query_scalar(
        "SELECT max(hub_seq) FROM changes \
         WHERE org_id = $1 AND received_at < now() - make_interval(secs => $2)",
    )
    .bind(org_id)
    .bind(older_than.as_secs_f64())
    .fetch_one(&mut *tx)
    .await?;
    let Some(new_horizon) = cutoff.filter(|cut| *cut > current) else {
        tx.commit().await?;
        return Ok(current);
    };

    let deleted = sqlx::query("DELETE FROM changes WHERE org_id = $1 AND hub_seq <= $2")
        .bind(org_id)
        .bind(new_horizon)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    sqlx::query(
        "INSERT INTO org_sync_horizons (org_id, horizon) VALUES ($1, $2) \
         ON CONFLICT (org_id) DO UPDATE SET horizon = GREATEST(org_sync_horizons.horizon, \
                                                               EXCLUDED.horizon)",
    )
    .bind(org_id)
    .bind(new_horizon)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    tracing::info!(%org_id, deleted, horizon = new_horizon, "pruned the change log");
    Ok(new_horizon)
}
