//! The hub's instances and which one serves each user's links (`hub_instances`, `user_links`;
//! migration 0008). Every `serve` registers on start and refreshes its heartbeat; an instance whose
//! heartbeat is older than the liveness window is dead. Every link of one user is served by the
//! instance that holds the user's claim: a live owner keeps it, a dead owner's claim is taken over
//! by the next instance a link of that user reaches, and a draining instance releases its claims.
//!
//! The liveness window is the caller's (`serve` passes four heartbeat intervals, 20 s by default),
//! so a test can shorten it with the heartbeat. Every instance of one hub must use the same one.
//! Times are the database's `now()`, so instances never compare their own clocks.
//!
//! Both tables are hub-internal: no tenant, no row-level security, read and written by
//! `b4hub_app` through the plain pool.

use std::time::Duration;

use sqlx::types::Uuid;

use crate::{Db, Result};

/// Who serves a user's links after [`claim_user`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Claim {
    /// This instance: serve the link here.
    Ours,
    /// Another live instance holds the claim.
    Other(Uuid),
}

/// Registers (or re-registers) `instance_id`, alive as of now.
pub async fn register(db: &Db, instance_id: Uuid, public_url: Option<&str>) -> Result<()> {
    sqlx::query(
        "INSERT INTO hub_instances (instance_id, started_at, heartbeat_at, public_url) \
         VALUES ($1, now(), now(), $2) \
         ON CONFLICT (instance_id) DO UPDATE SET heartbeat_at = now(), \
                                                 public_url = EXCLUDED.public_url",
    )
    .bind(instance_id)
    .bind(public_url)
    .execute(&db.pool)
    .await?;
    Ok(())
}

/// Refreshes `instance_id`'s heartbeat. False when it has no row (the prune removed it while its
/// heartbeat was stalled); the caller then registers again.
pub async fn heartbeat(db: &Db, instance_id: Uuid) -> Result<bool> {
    let updated =
        sqlx::query("UPDATE hub_instances SET heartbeat_at = now() WHERE instance_id = $1")
            .bind(instance_id)
            .execute(&db.pool)
            .await?
            .rows_affected();
    Ok(updated > 0)
}

/// Claims `user_id`'s links for `instance_id`, unless another instance whose heartbeat is younger
/// than `alive_within` holds them, and says who holds them now. One statement decides: two
/// instances claiming at once both read the winner afterwards. If the row vanished between the
/// two statements (its owner released its claims just then), the claim is tried once more.
pub async fn claim_user(
    db: &Db,
    user_id: Uuid,
    instance_id: Uuid,
    alive_within: Duration,
) -> Result<Claim> {
    for _ in 0..2 {
        if let Some(claim) = try_claim(db, user_id, instance_id, alive_within).await? {
            return Ok(claim);
        }
    }
    // Vanished twice in a row: not a race worth chasing further.
    Err(sqlx::Error::RowNotFound.into())
}

async fn try_claim(
    db: &Db,
    user_id: Uuid,
    instance_id: Uuid,
    alive_within: Duration,
) -> Result<Option<Claim>> {
    sqlx::query(
        "INSERT INTO user_links (user_id, instance_id, claimed_at) VALUES ($1, $2, now()) \
         ON CONFLICT (user_id) DO UPDATE \
             SET instance_id = EXCLUDED.instance_id, claimed_at = now() \
             WHERE user_links.instance_id <> EXCLUDED.instance_id \
               AND user_links.instance_id NOT IN ( \
                   SELECT instance_id FROM hub_instances \
                   WHERE heartbeat_at > now() - make_interval(secs => $3))",
    )
    .bind(user_id)
    .bind(instance_id)
    .bind(alive_within.as_secs_f64())
    .execute(&db.pool)
    .await?;
    let owner: Option<Uuid> =
        sqlx::query_scalar("SELECT instance_id FROM user_links WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&db.pool)
            .await?;
    Ok(owner.map(|owner| {
        if owner == instance_id {
            Claim::Ours
        } else {
            Claim::Other(owner)
        }
    }))
}

/// The instance holding `user_id`'s claim, if any.
pub async fn owner_of(db: &Db, user_id: Uuid) -> Result<Option<Uuid>> {
    Ok(
        sqlx::query_scalar("SELECT instance_id FROM user_links WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&db.pool)
            .await?,
    )
}

/// Of `users`, those whose claim is now held by an instance other than `instance_id`: a link of
/// theirs still open here must close, so the device reconnects to the owner.
pub async fn lost_claims(db: &Db, instance_id: Uuid, users: &[Uuid]) -> Result<Vec<Uuid>> {
    if users.is_empty() {
        return Ok(Vec::new());
    }
    Ok(sqlx::query_scalar(
        "SELECT user_id FROM user_links WHERE user_id = ANY($1) AND instance_id <> $2 \
         ORDER BY user_id",
    )
    .bind(users)
    .bind(instance_id)
    .fetch_all(&db.pool)
    .await?)
}

/// Deletes every claim `instance_id` holds and its instance row, so the next link of each of its
/// users is claimed at once by whichever instance it reaches. A draining instance calls it after
/// its links have closed. Returns how many claims were released.
pub async fn release_claims(db: &Db, instance_id: Uuid) -> Result<u64> {
    let mut tx = db.begin(None).await?;
    let released = sqlx::query("DELETE FROM user_links WHERE instance_id = $1")
        .bind(instance_id)
        .execute(&mut *tx)
        .await?
        .rows_affected();
    sqlx::query("DELETE FROM hub_instances WHERE instance_id = $1")
        .bind(instance_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(released)
}

/// What [`prune`] removed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pruned {
    pub instances: u64,
    pub claims: u64,
}

/// Deletes instances dead for longer than `alive_within` and every claim that no live instance
/// holds (a dead instance's, or one whose instance row is gone).
pub async fn prune(db: &Db, alive_within: Duration) -> Result<Pruned> {
    let mut tx = db.begin(None).await?;
    let instances = sqlx::query(
        "DELETE FROM hub_instances WHERE heartbeat_at <= now() - make_interval(secs => $1)",
    )
    .bind(alive_within.as_secs_f64())
    .execute(&mut *tx)
    .await?
    .rows_affected();
    let claims = sqlx::query(
        "DELETE FROM user_links WHERE instance_id NOT IN (SELECT instance_id FROM hub_instances)",
    )
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;
    Ok(Pruned { instances, claims })
}
