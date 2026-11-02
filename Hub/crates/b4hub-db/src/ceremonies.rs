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

use b4hub_core::tokens::{hash_token, new_token};
use serde_json::Value;
use sqlx::types::Uuid;

use crate::accounts::Principal;
use crate::{Db, Error, Result};

/// How long a ceremony can be finished after it began.
pub const CEREMONY_TTL: Duration = Duration::from_secs(5 * 60);

/// How long a handoff can be redeemed after it was recorded.
pub const HANDOFF_TTL: Duration = Duration::from_secs(2 * 60);

/// How long after expiring a ceremony or handoff is kept before pruning deletes it, so a finish
/// that read the row just before the deadline never finds it gone mid-request.
pub const PRUNE_GRACE: Duration = Duration::from_secs(60);

/// Begins a ceremony of `kind` holding `state`, and returns its id. The id is a version 4 UUID
/// (122 random bits, no timestamp): it is what a finish presents, so it must not be guessable.
pub async fn create(db: &Db, kind: &str, state: Value) -> Result<Uuid> {
    let id = Uuid::new_v4();
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

/// Takes the ceremony `id` if it is of one of `kinds`, once, and returns its kind and state;
/// otherwise as [`take`].
pub async fn take_any(db: &Db, id: Uuid, kinds: &[&str]) -> Result<(String, Value)> {
    let kinds: Vec<String> = kinds.iter().map(|kind| kind.to_string()).collect();
    sqlx::query_as(
        "UPDATE auth_ceremonies SET used_at = now() \
         WHERE id = $1 AND kind = ANY($2) AND used_at IS NULL AND expires_at > now() \
         RETURNING kind, state",
    )
    .bind(id)
    .bind(kinds)
    .fetch_optional(&db.pool)
    .await?
    .ok_or(Error::CeremonyExpired)
}

/// Reads the ceremony `id` without taking it, if it is of one of `kinds` and still open
/// (unexpired and not taken); otherwise [`Error::CeremonyExpired`].
pub async fn peek(db: &Db, id: Uuid, kinds: &[&str]) -> Result<(String, Value)> {
    let kinds: Vec<String> = kinds.iter().map(|kind| kind.to_string()).collect();
    sqlx::query_as(
        "SELECT kind, state FROM auth_ceremonies \
         WHERE id = $1 AND kind = ANY($2) AND used_at IS NULL AND expires_at > now()",
    )
    .bind(id)
    .bind(kinds)
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

/// Redeems the handoff whose code hashes to `code_hash`, once, and returns who it signed in (only
/// a handoff that names an account; the Apple flows use [`redeem_apple_handoff`]). A wrong
/// `verifier_hash` is [`Error::CeremonyExpired`], exactly like an unknown, expired, or
/// spent handoff, and leaves the handoff redeemable by its rightful holder.
pub async fn take_handoff(db: &Db, code_hash: &[u8], verifier_hash: &[u8]) -> Result<Principal> {
    let taken: Option<(Uuid, Uuid)> = sqlx::query_as(
        "UPDATE auth_handoffs SET used_at = now() \
         WHERE code_hash = $1 AND verifier_hash = $2 AND used_at IS NULL AND expires_at > now() \
           AND org_id IS NOT NULL \
         RETURNING org_id, user_id",
    )
    .bind(code_hash)
    .bind(verifier_hash)
    .fetch_optional(&db.pool)
    .await?;
    let (org_id, user_id) = taken.ok_or(Error::CeremonyExpired)?;
    Ok(Principal { org_id, user_id })
}

/// Records the web Apple flow's handoff for the ceremony `ceremony_id`, redeemable with `code`
/// (only its hash is stored) and the verifier whose SHA-256 is `verifier_hash`. `pending` is what
/// the redemption needs, already sealed by the caller; `link` is the account a link ceremony
/// was begun by (a sign-in names none: the account is found or made at redemption).
pub async fn create_apple_handoff(
    db: &Db,
    code: &str,
    ceremony_id: Uuid,
    link: Option<Principal>,
    verifier_hash: &[u8],
    pending: &[u8],
) -> Result<()> {
    sqlx::query(
        "INSERT INTO auth_handoffs \
             (code_hash, ceremony_id, org_id, user_id, verifier_hash, pending, expires_at) \
         VALUES ($1, $2, $3, $4, $5, $6, now() + make_interval(secs => $7))",
    )
    .bind(&hash_token(code)[..])
    .bind(ceremony_id)
    .bind(link.map(|p| p.org_id))
    .bind(link.map(|p| p.user_id))
    .bind(verifier_hash)
    .bind(pending)
    .bind(HANDOFF_TTL.as_secs_f64())
    .execute(&db.pool)
    .await?;
    Ok(())
}

/// Redeems, once, the Apple handoff whose code hashes to `code_hash`, presented with the
/// verifier whose SHA-256 is `verifier_hash`, when its ceremony is of `kind` and (for a link)
/// it names `link`; answers its sealed pending payload. Anything else is
/// [`Error::CeremonyExpired`] and uses nothing up. Of two concurrent redemptions the second
/// waits on the row lock, then matches nothing.
pub async fn redeem_apple_handoff(
    db: &Db,
    code_hash: &[u8],
    verifier_hash: &[u8],
    kind: &str,
    link: Option<Principal>,
) -> Result<Vec<u8>> {
    let pending: Option<Option<Vec<u8>>> = sqlx::query_scalar(
        "UPDATE auth_handoffs h SET used_at = now() FROM auth_ceremonies c \
         WHERE c.id = h.ceremony_id AND h.code_hash = $1 AND h.verifier_hash = $2 \
           AND h.used_at IS NULL AND h.expires_at > now() AND c.kind = $3 \
           AND h.org_id IS NOT DISTINCT FROM $4 AND h.user_id IS NOT DISTINCT FROM $5 \
         RETURNING h.pending",
    )
    .bind(code_hash)
    .bind(verifier_hash)
    .bind(kind)
    .bind(link.map(|p| p.org_id))
    .bind(link.map(|p| p.user_id))
    .fetch_optional(&db.pool)
    .await?;
    pending.flatten().ok_or(Error::CeremonyExpired)
}

/// Whether a handoff with this code and verifier is still redeemable at all (by whichever route
/// and account it belongs to). Only the holder of both can learn this.
pub async fn handoff_is_live(db: &Db, code_hash: &[u8], verifier_hash: &[u8]) -> Result<bool> {
    let live: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM auth_handoffs \
           WHERE code_hash = $1 AND verifier_hash = $2 AND used_at IS NULL AND expires_at > now())",
    )
    .bind(code_hash)
    .bind(verifier_hash)
    .fetch_one(&db.pool)
    .await?;
    Ok(live)
}

/// Deletes handoffs, then ceremonies no remaining handoff points at, that expired more than
/// [`PRUNE_GRACE`] ago, and returns how many rows went. The serve loop runs it with each
/// change-log prune.
pub async fn prune_expired(db: &Db) -> Result<u64> {
    let grace = PRUNE_GRACE.as_secs_f64();
    let mut tx = db.untenanted_tx().await?;
    let handoffs = sqlx::query(
        "DELETE FROM auth_handoffs WHERE expires_at <= now() - make_interval(secs => $1)",
    )
    .bind(grace)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    let ceremonies = sqlx::query(
        "DELETE FROM auth_ceremonies c WHERE expires_at <= now() - make_interval(secs => $1) \
         AND NOT EXISTS (SELECT 1 FROM auth_handoffs h WHERE h.ceremony_id = c.id)",
    )
    .bind(grace)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;
    Ok(handoffs + ceremonies)
}
