//! Transactions with the tenant context set, which is what row-level security keys on.

use sqlx::types::Uuid;
use sqlx::{Postgres, Transaction};

use crate::{Db, Result};

impl Db {
    /// Admission lock precedes the first snapshot-taking statement, including `set_tenant`.
    /// Held through COMMIT, it makes a floor cut wait for already-admitted sync work.
    pub async fn protocol_write_tx(
        &self,
        org_id: Uuid,
        client: b4hub_core::protocol::ClientProtocol,
    ) -> Result<(
        Transaction<'static, Postgres>,
        b4hub_core::protocol::ProtocolFloor,
    )> {
        self.protocol_tx(org_id, client, None).await
    }

    pub async fn protocol_read_tx(
        &self,
        org_id: Uuid,
        client: b4hub_core::protocol::ClientProtocol,
    ) -> Result<(
        Transaction<'static, Postgres>,
        b4hub_core::protocol::ProtocolFloor,
    )> {
        self.protocol_tx(
            org_id,
            client,
            Some("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY"),
        )
        .await
    }

    async fn protocol_tx(
        &self,
        org_id: Uuid,
        client: b4hub_core::protocol::ClientProtocol,
        statement: Option<&'static str>,
    ) -> Result<(
        Transaction<'static, Postgres>,
        b4hub_core::protocol::ProtocolFloor,
    )> {
        let (mut tx, floor) = self.begin_protocol_tx(client, statement).await?;
        set_tenant(&mut tx, org_id).await?;
        Ok((tx, floor))
    }

    /// The relay resolves its native session only after locking and reading the floor. Its
    /// authenticated token supplies the tenant, so no caller-provided org is installed here.
    pub(crate) async fn protocol_untenanted_read_tx(
        &self,
        client: b4hub_core::protocol::ClientProtocol,
    ) -> Result<(
        Transaction<'static, Postgres>,
        b4hub_core::protocol::ProtocolFloor,
    )> {
        self.begin_protocol_tx(
            client,
            Some("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY"),
        )
        .await
    }

    async fn begin_protocol_tx(
        &self,
        client: b4hub_core::protocol::ClientProtocol,
        statement: Option<&'static str>,
    ) -> Result<(
        Transaction<'static, Postgres>,
        b4hub_core::protocol::ProtocolFloor,
    )> {
        let mut tx = self.begin(statement).await?;
        sqlx::query("LOCK TABLE public.hub_settings IN ACCESS SHARE MODE")
            .execute(&mut *tx)
            .await?;
        let floor = crate::settings::protocol_floor_in(&mut tx).await?;
        if !floor.admits(client) {
            return Err(crate::Error::ClientTooOld {
                minimum: floor.minimum(),
            });
        }
        Ok((tx, floor))
    }

    /// Begins a transaction whose first statement sets `b4hub.org_id` to `org_id`, transaction-
    /// locally (`set_config(..., true)`), so the tenant policies on `users` and `devices` admit
    /// only that org's rows and the setting vanishes at commit or rollback. Every request that
    /// touches a tenant-secured table runs inside one of these; `org_id` comes from the verified
    /// device token, never from the request.
    pub async fn tenant_tx(&self, org_id: Uuid) -> Result<Transaction<'_, Postgres>> {
        let mut tx = self.begin(None).await?;
        set_tenant(&mut tx, org_id).await?;
        Ok(tx)
    }

    /// Begins a read-only `REPEATABLE READ` transaction with the tenant context set: every
    /// statement in it sees the one snapshot taken by its first. For reads that must agree with
    /// each other (the horizon with the feed, the snapshot's tables with its cursor).
    pub async fn read_tx(&self, org_id: Uuid) -> Result<Transaction<'_, Postgres>> {
        let mut tx = self
            .begin(Some("BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
            .await?;
        set_tenant(&mut tx, org_id).await?;
        Ok(tx)
    }

    /// Begins a transaction with no tenant context. Only for `device_tokens` and
    /// `enrollment_codes`, which have no row-level security because they are looked up by the
    /// hash of a presented secret before the org is known. Against any tenant-secured table such
    /// a transaction sees and writes nothing.
    pub async fn untenanted_tx(&self) -> Result<Transaction<'_, Postgres>> {
        self.begin(None).await
    }

    /// Begins a transaction with `statement` (a plain `BEGIN` when `None`), in a task of its own,
    /// so a caller dropped while Postgres answers the `BEGIN` (a client that disconnects mid-
    /// request) cannot interrupt it. sqlx 0.8 counts a transaction only once that answer has
    /// arrived, so interrupting it there would return the connection to the pool still inside the
    /// transaction, unknown to sqlx: every later user of the connection would run inside it (a
    /// write fails as read-only after `read_tx`, and after any error the connection answers
    /// "current transaction is aborted" until it is closed). Run to completion, an abandoned
    /// transaction is dropped like any other and rolled back before the connection is reused.
    /// Every transaction on the pool starts here.
    pub(crate) async fn begin(
        &self,
        statement: Option<&'static str>,
    ) -> Result<Transaction<'static, Postgres>> {
        let pool = self.pool.clone();
        let begin = tokio::spawn(async move {
            match statement {
                Some(statement) => pool.begin_with(statement).await,
                None => pool.begin().await,
            }
        });
        match begin.await {
            Ok(begun) => Ok(begun?),
            Err(error) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
            // Cancelled only when the runtime is shutting down, which closes the pool too.
            Err(_) => Err(sqlx::Error::PoolClosed.into()),
        }
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
