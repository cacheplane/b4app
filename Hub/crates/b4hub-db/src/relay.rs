//! What the relay reads and writes in the database: a user's Macs for the presence frame, and
//! `devices.last_seen_at` as a link reports it.

use std::time::{SystemTime, UNIX_EPOCH};

use sqlx::types::Uuid;

use crate::{Db, Result};

/// One of a user's Macs: its id, its name, and when it was last heard from as RFC 3339 in UTC with
/// milliseconds (`None` for a Mac never seen).
pub type HostRow = (Uuid, String, Option<String>);

/// The user's non-revoked `macos` devices, oldest first. This is the host list of a `presence`
/// frame: it is filtered by org and user, so one user's Macs never reach another user.
pub async fn host_devices(db: &Db, org_id: Uuid, user_id: Uuid) -> Result<Vec<HostRow>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let hosts = sqlx::query_as(
        "SELECT id, name, \
                to_char(last_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') \
         FROM devices \
         WHERE org_id = $1 AND user_id = $2 AND platform = 'macos' AND revoked_at IS NULL \
         ORDER BY created_at, id",
    )
    .bind(org_id)
    .bind(user_id)
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(hosts)
}

/// Records that the device was heard from at `at`. It never moves `last_seen_at` backwards: a
/// link that closes late reports the time of its last frame, and by then a newer link of the same
/// device (or the request throttle) may already have written a later time.
pub async fn set_last_seen(db: &Db, org_id: Uuid, device_id: Uuid, at: SystemTime) -> Result<()> {
    let seconds = at
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64());
    let mut tx = db.tenant_tx(org_id).await?;
    sqlx::query(
        "UPDATE devices SET last_seen_at = GREATEST(last_seen_at, to_timestamp($2)) WHERE id = $1",
    )
    .bind(device_id)
    .bind(seconds)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}
