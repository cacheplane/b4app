//! Sign-in ceremonies and handoffs: the short-lived, single-use state a sign-in passes through.
//!
//! A ceremony holds what the hub needs to finish a sign-in it began (webauthn-rs's registration
//! and authentication state, the Apple nonce and verifier hash) for five minutes, in the database
//! so any hub instance can finish it. A handoff carries the web Apple flow's result to the app
//! that began it for two minutes; it is redeemed with the code from the redirect and the verifier
//! the app kept. Neither table has row-level security: both are read before the org is known.
//!
//! Taking either is one conditional `UPDATE`: of two concurrent takes the second waits on the row
//! lock, then finds `used_at` set and matches nothing, so exactly one succeeds.

use std::time::Duration;

use b4hub_core::ids::new_uuid;
use b4hub_core::tokens::{hash_token, new_token};
use serde_json::Value;
use sqlx::types::Uuid;

use crate::accounts::Principal;
use crate::{Db, Error, Result};

/// How long a ceremony can be finished after it began.
pub const CEREMONY_TTL: Duration = Duration::from_secs(5 * 60);

/// How long a handoff can be redeemed after it was recorded.
pub const HANDOFF_TTL: Duration = Duration::from_secs(2 * 60);

/// Begins a ceremony of `kind` holding `state`, and returns its id.
pub async fn create(db: &Db, kind: &str, state: Value) -> Result<Uuid> {
    let id = new_uuid();
    sqlx::query(
        "INSERT INTO auth_ceremonies (id, kind, state, created_at, expires_at) \
         VALUES ($1, $2, $3, now(), now() + make_interval(secs => $4))",
    )
    .bind(id)
    .bind(kind)
    .bind(state)
    .bind(CEREMONY_TTL.as_secs_f64())
    .execute(&db.pool)
    .await?;
    Ok(id)
}

/// Takes the ceremony `id` of `kind`, once, and returns its state. A ceremony that is unknown, of
/// another kind, expired, or already taken is [`Error::CeremonyExpired`].
pub async fn take(db: &Db, id: Uuid, kind: &str) -> Result<Value> {
    sqlx::query_scalar(
        "UPDATE auth_ceremonies SET used_at = now() \
         WHERE id = $1 AND kind = $2 AND used_at IS NULL AND expires_at > now() \
         RETURNING state",
    )
    .bind(id)
    .bind(kind)
    .fetch_optional(&db.pool)
    .await?
    .ok_or(Error::CeremonyExpired)
}

/// Records that the ceremony `ceremony_id` signed in `principal`, redeemable with the returned
/// code and the verifier whose SHA-256 is `verifier_hash`. Only the code's hash is stored; the
/// code itself goes into the one redirect that hands it over.
pub async fn create_handoff(
    db: &Db,
    ceremony_id: Uuid,
    principal: Principal,
    verifier_hash: &[u8],
) -> Result<String> {
    let code = new_token();
    sqlx::query(
        "INSERT INTO auth_handoffs \
             (code_hash, ceremony_id, org_id, user_id, verifier_hash, expires_at) \
         VALUES ($1, $2, $3, $4, $5, now() + make_interval(secs => $6))",
    )
    .bind(&hash_token(&code)[..])
    .bind(ceremony_id)
    .bind(principal.org_id)
    .bind(principal.user_id)
    .bind(verifier_hash)
    .bind(HANDOFF_TTL.as_secs_f64())
    .execute(&db.pool)
    .await?;
    Ok(code)
}

/// Redeems the handoff whose code hashes to `code_hash`, once, and returns who it signed in. A
/// wrong `verifier_hash` is [`Error::CeremonyExpired`], exactly like an unknown, expired, or
/// spent handoff, and leaves the handoff redeemable by its rightful holder.
pub async fn take_handoff(db: &Db, code_hash: &[u8], verifier_hash: &[u8]) -> Result<Principal> {
    let taken: Option<(Uuid, Uuid)> = sqlx::query_as(
        "UPDATE auth_handoffs SET used_at = now() \
         WHERE code_hash = $1 AND verifier_hash = $2 AND used_at IS NULL AND expires_at > now() \
         RETURNING org_id, user_id",
    )
    .bind(code_hash)
    .bind(verifier_hash)
    .fetch_optional(&db.pool)
    .await?;
    let (org_id, user_id) = taken.ok_or(Error::CeremonyExpired)?;
    Ok(Principal { org_id, user_id })
}

/// Deletes expired handoffs, then expired ceremonies no remaining handoff points at, and returns
/// how many rows went. The serve loop runs it with each change-log prune.
pub async fn prune_expired(db: &Db) -> Result<u64> {
    let mut tx = db.untenanted_tx().await?;
    let handoffs = sqlx::query("DELETE FROM auth_handoffs WHERE expires_at <= now()")
        .execute(&mut *tx)
        .await?
        .rows_affected();
    let ceremonies = sqlx::query(
        "DELETE FROM auth_ceremonies c WHERE expires_at <= now() \
         AND NOT EXISTS (SELECT 1 FROM auth_handoffs h WHERE h.ceremony_id = c.id)",
    )
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;
    Ok(handoffs + ceremonies)
}
