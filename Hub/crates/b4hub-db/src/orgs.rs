//! Organisations and their users: the operator-side `seed` command.

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
/// email. `users` is row-level-secured and the owner is not exempt from forced RLS, so the user
/// is written inside a transaction that sets the tenant context to the org just resolved.
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
        "INSERT INTO users (id, org_id, username, display_name, email) VALUES ($1, $2, $3, $4, $5) \
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
