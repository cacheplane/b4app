//! Organisations and their users: the operator-side `seed` and `enroll` commands.

use b4hub_core::ids::new_uuid;
use sqlx::types::Uuid;

use crate::{Db, Result};

/// What `seed` found or created.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeedOutcome {
    pub org_id: Uuid,
    pub user_id: Uuid,
    /// True when this call created the org or the user; false when both already existed.
    pub created: bool,
}

/// Ensures the org (by slug) and its user (by username within the org) exist. Idempotent: a
/// repeat call returns the existing ids and `created == false`, and never overwrites a name or
/// email. An operator names the user, so a new one counts as onboarded with `display_name` as
/// their full name, as `0005_accounts.sql` treats the users that already existed. `users` is
/// row-level-secured and the owner is not exempt from forced RLS, so the user is written inside a
/// transaction that sets the tenant context to the org just resolved.
pub async fn seed(
    db: &Db,
    org_slug: &str,
    org_name: &str,
    username: &str,
    display_name: &str,
    email: &str,
) -> Result<SeedOutcome> {
    let mut tx = db.pool.begin().await?;

    let new_org: Option<Uuid> = sqlx::query_scalar(
        "INSERT INTO orgs (id, slug, name) VALUES ($1, $2, $3) \
         ON CONFLICT (slug) DO NOTHING RETURNING id",
    )
    .bind(new_uuid())
    .bind(org_slug)
    .bind(org_name)
    .fetch_optional(&mut *tx)
    .await?;
    let org_id = match new_org {
        Some(id) => id,
        None => {
            sqlx::query_scalar("SELECT id FROM orgs WHERE slug = $1")
                .bind(org_slug)
                .fetch_one(&mut *tx)
                .await?
        }
    };

    sqlx::query("SELECT set_config('b4hub.org_id', $1, true)")
        .bind(org_id.to_string())
        .execute(&mut *tx)
        .await?;

    let new_user: Option<Uuid> = sqlx::query_scalar(
        "INSERT INTO users (id, org_id, username, display_name, email, full_name, onboarded_at) \
         VALUES ($1, $2, $3, $4, $5, $4, now()) \
         ON CONFLICT (org_id, username) DO NOTHING RETURNING id",
    )
    .bind(new_uuid())
    .bind(org_id)
    .bind(username)
    .bind(display_name)
    .bind(email)
    .fetch_optional(&mut *tx)
    .await?;
    let user_id = match new_user {
        Some(id) => id,
        None => {
            sqlx::query_scalar("SELECT id FROM users WHERE org_id = $1 AND username = $2")
                .bind(org_id)
                .bind(username)
                .fetch_one(&mut *tx)
                .await?
        }
    };

    tx.commit().await?;
    Ok(SeedOutcome {
        org_id,
        user_id,
        created: new_org.is_some() || new_user.is_some(),
    })
}

/// How `--org` resolved against the orgs that exist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrgChoice {
    Found(Uuid),
    /// A slug was given and no org has it.
    UnknownSlug,
    /// No slug was given and more than one org exists.
    Ambiguous,
    /// No slug was given and no org exists.
    NoOrgs,
}

/// Resolves an org for an operator command: by `slug` when given, otherwise the only org when
/// exactly one exists. `orgs` carries no row-level security, so this needs no tenant context.
pub async fn resolve_org(db: &Db, slug: Option<&str>) -> Result<OrgChoice> {
    if let Some(slug) = slug {
        let id: Option<Uuid> = sqlx::query_scalar("SELECT id FROM orgs WHERE slug = $1")
            .bind(slug)
            .fetch_optional(&db.pool)
            .await?;
        return Ok(id.map_or(OrgChoice::UnknownSlug, OrgChoice::Found));
    }
    let ids: Vec<Uuid> = sqlx::query_scalar("SELECT id FROM orgs ORDER BY created_at LIMIT 2")
        .fetch_all(&db.pool)
        .await?;
    Ok(match ids.as_slice() {
        [] => OrgChoice::NoOrgs,
        [only] => OrgChoice::Found(*only),
        _ => OrgChoice::Ambiguous,
    })
}

/// The id of `username` within `org_id`, read under that org's tenant context.
pub async fn find_user(db: &Db, org_id: Uuid, username: &str) -> Result<Option<Uuid>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let id = sqlx::query_scalar("SELECT id FROM users WHERE org_id = $1 AND username = $2")
        .bind(org_id)
        .bind(username)
        .fetch_optional(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(id)
}

/// Every org's id and slug, oldest first. `orgs` carries no row-level security.
pub async fn list(db: &Db) -> Result<Vec<(Uuid, String)>> {
    let orgs = sqlx::query_as("SELECT id, slug FROM orgs ORDER BY created_at, id")
        .fetch_all(&db.pool)
        .await?;
    Ok(orgs)
}
