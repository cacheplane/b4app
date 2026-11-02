//! What the relay reads and writes in the database: a user's Macs for the presence frame,
//! `devices.last_seen_at` as a link reports it, and the device that owns the thread, runtime
//! request, or project a command names.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

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

/// The device that owns a row a command names, as the router needs it: who it is, whether it may
/// receive commands (a `macos` device of the caller's user that is not revoked), and when it was
/// last heard from.
#[derive(Debug, Clone, PartialEq)]
pub struct Owner {
    pub device_id: Uuid,
    pub user_id: Uuid,
    pub name: String,
    /// `macos`, `ios`, or `cli`.
    pub platform: String,
    pub revoked: bool,
    /// `devices.last_seen_at`; `None` for a device never seen.
    pub last_seen_at: Option<SystemTime>,
}

/// A runtime request's owner (the owner of the request's thread) and the request's materialised
/// `state` (`pending`, `resolved`, ...; `None` when the row has none).
#[derive(Debug, Clone, PartialEq)]
pub struct RequestOwner {
    pub owner: Owner,
    pub state: Option<String>,
}

type OwnerRow = (Uuid, Uuid, String, String, bool, Option<f64>);
/// An [`OwnerRow`] and the request's state.
type RequestRow = (
    Uuid,
    Uuid,
    String,
    String,
    bool,
    Option<f64>,
    Option<String>,
);

/// The columns of an [`OwnerRow`], from the `devices` row aliased `d`.
const OWNER_COLUMNS: &str = "d.id, d.user_id, d.name, d.platform, d.revoked_at IS NOT NULL, \
                             extract(epoch FROM d.last_seen_at)::float8";

fn owner((device_id, user_id, name, platform, revoked, seen): OwnerRow) -> Owner {
    Owner {
        device_id,
        user_id,
        name,
        platform,
        revoked,
        last_seen_at: seen
            .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
            .map(|seconds| UNIX_EPOCH + Duration::from_secs_f64(seconds)),
    }
}

/// The owner of the user's thread `thread_id` (`threads.owner_device_id`). `None` when the org has
/// no such thread, when it is another user's, or when its owner is not a device of this org.
pub async fn owner_of_thread(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    thread_id: &str,
) -> Result<Option<Owner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let row: Option<OwnerRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS} FROM \"threads\" t \
         JOIN devices d ON d.id = t.owner_device_id AND d.org_id = t.org_id \
         WHERE t.org_id = $1 AND t.user_id = $2 AND t.\"id\" = $3"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(thread_id)
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(row.map(owner))
}

/// The owner of the thread of the user's runtime request `request_id` (through
/// `"runtimeRequests"."threadId"`), with the request's state. `None` when either row is missing or
/// not the user's.
pub async fn owner_of_request(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    request_id: &str,
) -> Result<Option<RequestOwner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let row: Option<RequestRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS}, r.\"state\" FROM \"runtimeRequests\" r \
         JOIN \"threads\" t ON t.org_id = r.org_id AND t.\"id\" = r.\"threadId\" \
         JOIN devices d ON d.id = t.owner_device_id AND d.org_id = t.org_id \
         WHERE r.org_id = $1 AND r.user_id = $2 AND r.\"id\" = $3 AND t.user_id = $2"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(request_id)
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(row.map(
        |(device, user, name, platform, revoked, seen, state)| RequestOwner {
            owner: owner((device, user, name, platform, revoked, seen)),
            state,
        },
    ))
}

/// The owner of the user's project `project_id` (`projects.owner_device_id`).
pub async fn owner_of_project(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    project_id: &str,
) -> Result<Option<Owner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let row: Option<OwnerRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS} FROM \"projects\" p \
         JOIN devices d ON d.id = p.owner_device_id AND d.org_id = p.org_id \
         WHERE p.org_id = $1 AND p.user_id = $2 AND p.\"id\" = $3"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(project_id)
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(row.map(owner))
}

/// The user's device `device_id` as an [`Owner`]: how the router re-reads an owner it already
/// knows (a thread started moments ago, or a Mac that just went offline, whose `last_seen_at` is
/// then current). `None` when it is not a device of this user.
pub async fn owner_device(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    device_id: Uuid,
) -> Result<Option<Owner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let row: Option<OwnerRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS} FROM devices d \
         WHERE d.org_id = $1 AND d.user_id = $2 AND d.id = $3"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(row.map(owner))
}
