//! Preserve opaque history only while the frozen pending migration 18 runs.

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use sqlx::migrate::{AppliedMigration, Migrate, MigrateError, Migration, MigrationType};
use sqlx::{Connection, PgConnection};

type MigrationFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, MigrateError>> + Send + 'a>>;

pub(super) struct GuardedMigrate<'a> {
    conn: &'a mut PgConnection,
}

impl<'a> GuardedMigrate<'a> {
    pub(super) fn new(conn: &'a mut PgConnection) -> Self {
        Self { conn }
    }
}

impl Migrate for GuardedMigrate<'_> {
    fn ensure_migrations_table(&mut self) -> MigrationFuture<'_, ()> {
        <PgConnection as Migrate>::ensure_migrations_table(self.conn)
    }

    fn dirty_version(&mut self) -> MigrationFuture<'_, Option<i64>> {
        <PgConnection as Migrate>::dirty_version(self.conn)
    }

    fn list_applied_migrations(&mut self) -> MigrationFuture<'_, Vec<AppliedMigration>> {
        <PgConnection as Migrate>::list_applied_migrations(self.conn)
    }

    fn lock(&mut self) -> MigrationFuture<'_, ()> {
        <PgConnection as Migrate>::lock(self.conn)
    }

    fn unlock(&mut self) -> MigrationFuture<'_, ()> {
        <PgConnection as Migrate>::unlock(self.conn)
    }

    fn apply<'e: 'm, 'm>(&'e mut self, migration: &'m Migration) -> MigrationFuture<'m, Duration> {
        if migration.version != 18 {
            return <PgConnection as Migrate>::apply(self.conn, migration);
        }
        Box::pin(apply_environment_migration(self.conn, migration))
    }

    fn revert<'e: 'm, 'm>(&'e mut self, migration: &'m Migration) -> MigrationFuture<'m, Duration> {
        <PgConnection as Migrate>::revert(self.conn, migration)
    }
}

fn safe_error() -> MigrateError {
    // Never attach a native error: trigger DETAIL/CONTEXT can contain history.
    MigrateError::ExecuteMigration(
        sqlx::Error::Protocol("environment history preservation failed".to_owned()),
        18,
    )
}

async fn apply_environment_migration(
    conn: &mut PgConnection,
    migration: &Migration,
) -> Result<Duration, MigrateError> {
    if migration.version != 18
        || migration.no_tx
        || migration.migration_type != MigrationType::Simple
        || migration.sql.as_ref() != include_str!("../../migrations/0018_environments.sql")
    {
        return Err(safe_error());
    }
    let mut outer = conn.begin().await.map_err(|_| safe_error())?;
    let outcome = async {
        let captured = capture(&mut outer).await?;
        // SQLx begins a tracked savepoint here. Original SQL, checksum, ledger
        // INSERT and execution_time UPDATE all remain in our outer transaction.
        let elapsed = <PgConnection as Migrate>::apply(&mut outer, migration).await?;
        restore(&mut outer, &captured).await?;
        Ok::<_, MigrateError>(elapsed)
    }
    .await;
    match outcome {
        Ok(elapsed) => {
            // apply must commit BEFORE run_direct can release its session lock.
            outer.commit().await.map_err(|_| safe_error())?;
            Ok(elapsed)
        }
        Err(_) => {
            // A failed rollback is not reuse permission. The public run owns
            // this connection and closes it on every error, without unlocking.
            let _ = outer.rollback().await;
            Err(safe_error())
        }
    }
}

// Original DDL lock order, followed by its renamed indexes and native ledger.
const RELATIONS: [(&str, &str, &str); 9] = [
    ("projects", "environments", "r"),
    ("projectFolders", "environmentFolders", "r"),
    ("threads", "threads", "r"),
    ("connections", "connections", "r"),
    ("changes", "changes", "r"),
    ("column_clocks", "column_clocks", "r"),
    ("projects_by_user", "environments_by_user", "i"),
    ("projectFolders_by_user", "environmentFolders_by_user", "i"),
    ("_sqlx_migrations", "_sqlx_migrations", "r"),
];
const CHANGES: usize = 4;
const CLOCKS: usize = 5;

struct RelationState {
    oid: i64,
    enabled: bool,
    forced: bool,
}

struct Captured {
    relations: Vec<RelationState>,
    temp_oid: i64,
    rows: u64,
}

async fn relation(
    conn: &mut PgConnection,
    name: &str,
    kind: &str,
) -> Result<RelationState, MigrateError> {
    let (oid, enabled, forced) = sqlx::query_as::<_, (i64, bool, bool)>(
        "SELECT c.oid::bigint,c.relrowsecurity,c.relforcerowsecurity
         FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
         WHERE n.nspname='public' AND c.relname::text=$1 AND c.relkind::text=$2
           AND c.oid=pg_catalog.to_regclass(pg_catalog.quote_ident($1))",
    )
    .bind(name)
    .bind(kind)
    .fetch_one(conn)
    .await?;
    Ok(RelationState {
        oid,
        enabled,
        forced,
    })
}

async fn temp_oid(conn: &mut PgConnection) -> Result<i64, MigrateError> {
    Ok(sqlx::query_scalar(
        "SELECT c.oid::bigint FROM pg_catalog.pg_class c
         WHERE c.oid=pg_catalog.to_regclass('pg_temp.b4hub_environment18_opaque')
           AND c.relnamespace=pg_catalog.pg_my_temp_schema()
           AND c.relkind='r' AND c.relpersistence='t'",
    )
    .fetch_one(conn)
    .await?)
}

async fn owner_access(conn: &mut PgConnection) -> Result<(), MigrateError> {
    sqlx::query("ALTER TABLE public.changes NO FORCE ROW LEVEL SECURITY")
        .execute(&mut *conn)
        .await?;
    let active: bool = sqlx::query_scalar(
        "SELECT pg_catalog.row_security_active('public.changes'::pg_catalog.regclass)",
    )
    .fetch_one(conn)
    .await?;
    if active {
        return Err(safe_error());
    }
    Ok(())
}

async fn capture(conn: &mut PgConnection) -> Result<Captured, MigrateError> {
    // Lock before the first SELECT so Repeatable Read / Serializable cannot
    // freeze a snapshot before an in-flight writer commits (PostgreSQL LOCK).
    sqlx::Executor::execute(
        &mut *conn,
        sqlx::raw_sql(
            "LOCK TABLE public.\"projects\" IN ACCESS EXCLUSIVE MODE;
         LOCK TABLE public.\"projectFolders\" IN ACCESS EXCLUSIVE MODE;
         LOCK TABLE public.\"threads\" IN ACCESS EXCLUSIVE MODE;
         LOCK TABLE public.\"connections\" IN ACCESS EXCLUSIVE MODE;
         LOCK TABLE public.changes IN ACCESS EXCLUSIVE MODE;
         LOCK TABLE public.column_clocks IN ACCESS EXCLUSIVE MODE;",
        ),
    )
    .await?;
    let public_ledger: bool = sqlx::query_scalar(
        "SELECT (pg_catalog.to_regclass('_sqlx_migrations')=
                 pg_catalog.to_regclass('public._sqlx_migrations')) IS TRUE",
    )
    .fetch_one(&mut *conn)
    .await?;
    if !public_ledger {
        return Err(safe_error());
    }
    sqlx::query("SET LOCAL search_path=public")
        .execute(&mut *conn)
        .await?;
    let mut relations = Vec::with_capacity(RELATIONS.len());
    for (old, _, kind) in RELATIONS {
        relations.push(relation(conn, old, kind).await?);
    }
    owner_access(conn).await?;
    let ambiguous: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM public.changes
         WHERE pg_catalog.jsonb_typeof(value)='object' AND value ? 'projectId'
           AND op='insert' AND \"column\" IS NULL
           AND \"table\" IN ('projectFolders','threads','connections')
           AND value ? 'environmentId')",
    )
    .fetch_one(&mut *conn)
    .await?;
    if ambiguous {
        return Err(safe_error());
    }
    sqlx::Executor::execute(
        &mut *conn,
        sqlx::raw_sql(
            "CREATE TEMP TABLE b4hub_environment18_opaque (
           org_id pg_catalog.uuid NOT NULL, hub_seq pg_catalog.int8 NOT NULL,
           value pg_catalog.jsonb NOT NULL, value_bytes pg_catalog.int4 NOT NULL,
           PRIMARY KEY(org_id,hub_seq)
         ) ON COMMIT DROP;",
        ),
    )
    .await?;
    let temp_oid = temp_oid(conn).await?;
    let rows = sqlx::query(
        "INSERT INTO pg_temp.b4hub_environment18_opaque(org_id,hub_seq,value,value_bytes)
         SELECT org_id,hub_seq,value,value_bytes FROM public.changes
         WHERE pg_catalog.jsonb_typeof(value)='object' AND value ? 'projectId'
           AND (op='insert' AND \"column\" IS NULL
                AND \"table\" IN ('projectFolders','threads','connections')) IS NOT TRUE",
    )
    .execute(conn)
    .await?
    .rows_affected();
    Ok(Captured {
        relations,
        temp_oid,
        rows,
    })
}

async fn restore(conn: &mut PgConnection, captured: &Captured) -> Result<(), MigrateError> {
    for ((_, new, kind), before) in RELATIONS.iter().zip(&captured.relations) {
        if relation(conn, new, kind).await?.oid != before.oid {
            return Err(safe_error());
        }
    }
    if temp_oid(conn).await? != captured.temp_oid {
        return Err(safe_error());
    }
    owner_access(conn).await?;
    let restored = sqlx::query(
        "UPDATE public.changes AS c SET value=b.value,value_bytes=b.value_bytes
         FROM pg_temp.b4hub_environment18_opaque AS b
         WHERE c.org_id=b.org_id AND c.hub_seq=b.hub_seq",
    )
    .execute(&mut *conn)
    .await?
    .rows_affected();
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM pg_temp.b4hub_environment18_opaque")
        .fetch_one(&mut *conn)
        .await?;
    let equal: bool = sqlx::query_scalar(
        "SELECT NOT EXISTS (
           SELECT 1 FROM pg_temp.b4hub_environment18_opaque b
           LEFT JOIN public.changes c ON c.org_id=b.org_id AND c.hub_seq=b.hub_seq
           WHERE c.org_id IS NULL OR c.value IS DISTINCT FROM b.value
             OR c.value::text IS DISTINCT FROM b.value::text
             OR c.value_bytes IS DISTINCT FROM b.value_bytes)",
    )
    .fetch_one(&mut *conn)
    .await?;
    if restored != captured.rows || u64::try_from(count).ok() != Some(captured.rows) || !equal {
        return Err(safe_error());
    }
    for (index, name) in [(CHANGES, "changes"), (CLOCKS, "column_clocks")] {
        let before = &captured.relations[index];
        let enable = if before.enabled { "ENABLE" } else { "DISABLE" };
        let force = if before.forced { "FORCE" } else { "NO FORCE" };
        // Both identifiers come only from the fixed source list above.
        sqlx::Executor::execute(
            &mut *conn,
            sqlx::raw_sql(&format!(
                "ALTER TABLE public.{name} {enable} ROW LEVEL SECURITY;
             ALTER TABLE public.{name} {force} ROW LEVEL SECURITY;"
            )),
        )
        .await?;
        let after = relation(conn, name, "r").await?;
        if after.oid != before.oid
            || after.enabled != before.enabled
            || after.forced != before.forced
        {
            return Err(safe_error());
        }
    }
    Ok(())
}
