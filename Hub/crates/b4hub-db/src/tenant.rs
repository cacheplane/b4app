//! Transactions with the tenant context set, which is what row-level security keys on.

use sqlx::types::Uuid;
use sqlx::{Postgres, Transaction};

use crate::{Db, Result};

impl Db {
    /// Begins a transaction whose first statement sets `b4hub.org_id` to `org_id`, transaction-
    /// locally (`set_config(..., true)`), so the tenant policies on `users` and `devices` admit
    /// only that org's rows and the setting vanishes at commit or rollback. Every request that
    /// touches a tenant-secured table runs inside one of these; `org_id` comes from the verified
    /// device token, never from the request.
    pub async fn tenant_tx(&self, org_id: Uuid) -> Result<Transaction<'_, Postgres>> {
        let mut tx = self.pool.begin().await?;
        set_tenant(&mut tx, org_id).await?;
        Ok(tx)
    }

    /// Begins a read-only `REPEATABLE READ` transaction with the tenant context set: every
    /// statement in it sees the one snapshot taken by its first. For reads that must agree with
    /// each other (the horizon with the feed, the snapshot's tables with its cursor).
    pub async fn read_tx(&self, org_id: Uuid) -> Result<Transaction<'_, Postgres>> {
        let mut tx = self
            .pool
            .begin_with("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .await?;
        set_tenant(&mut tx, org_id).await?;
        Ok(tx)
    }

    /// Begins a transaction with no tenant context. Only for `device_tokens` and
    /// `enrollment_codes`, which have no row-level security because they are looked up by the
    /// hash of a presented secret before the org is known. Against any tenant-secured table such
    /// a transaction sees and writes nothing.
    pub async fn untenanted_tx(&self) -> Result<Transaction<'_, Postgres>> {
        Ok(self.pool.begin().await?)
    }
}

/// Sets `b4hub.org_id` for the rest of `tx`. For a transaction that had to look something up
/// untenanted first (a token or code, to learn the org) and then needs tenant-secured tables.
pub(crate) async fn set_tenant(tx: &mut Transaction<'_, Postgres>, org_id: Uuid) -> Result<()> {
    sqlx::query("SELECT set_config('b4hub.org_id', $1::text, true)")
        .bind(org_id.to_string())
        .execute(&mut **tx)
        .await?;
    Ok(())
}
