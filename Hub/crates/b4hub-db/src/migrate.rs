//! Applying migrations and provisioning the application role.

use std::time::Duration;

use percent_encoding::percent_decode_str;
use sqlx::migrate::Migrator;
use sqlx::{Connection, PgConnection};
use url::Url;

use crate::{Db, Error, Result};

static MIGRATOR: Migrator = sqlx::migrate!();

/// The unprivileged role the service connects as. It is not the table owner and has no
/// `BYPASSRLS`, so the row-level-security policies always apply to it.
const APP_ROLE: &str = "b4hub_app";

/// Which migrations the database has applied and how many the binary still carries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationStatus {
    pub applied: Vec<i64>,
    pub pending: usize,
}

/// Applies every pending migration as the owner, then creates or updates the `b4hub_app` role
/// with the password from `app_url` and grants it table access (including on tables later
/// migrations add). Safe to run repeatedly and concurrently with another run.
pub async fn run(admin_url: &str, app_url: &str) -> Result<()> {
    let password = app_password(app_url)?;
    // One connection and no pool: the password never appears in SQL text (it travels as a bind
    // parameter into a transaction-local setting), so statement logging cannot leak it.
    let mut conn = PgConnection::connect(admin_url).await?;
    MIGRATOR.run(&mut conn).await?;
    provision_role(&mut conn, &password).await?;
    grant_table_access(&mut conn).await?;
    conn.close().await?;
    Ok(())
}

/// Reads the migration state through `db`, which only needs `SELECT` on `_sqlx_migrations`.
pub async fn status(db: &Db) -> Result<MigrationStatus> {
    let table_exists: bool =
        sqlx::query_scalar("SELECT to_regclass('_sqlx_migrations') IS NOT NULL")
            .fetch_one(&db.pool)
            .await?;
    let applied: Vec<i64> = if table_exists {
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success ORDER BY version")
            .fetch_all(&db.pool)
            .await?
    } else {
        Vec::new()
    };
    let pending = MIGRATOR
        .iter()
        .filter(|m| !m.migration_type.is_down_migration() && !applied.contains(&m.version))
        .count();
    Ok(MigrationStatus { applied, pending })
}

/// The password component of `app_url`, percent-decoded. The URL must connect as `b4hub_app`:
/// provisioning that role is pointless (and the service would run with the wrong privileges)
/// otherwise.
fn app_password(app_url: &str) -> Result<String> {
    let url =
        Url::parse(app_url).map_err(|_| Error::InvalidUrl("DATABASE_URL is not a valid URL"))?;
    if percent_decode_str(url.username()).decode_utf8_lossy() != APP_ROLE {
        return Err(Error::InvalidUrl(
            "DATABASE_URL must connect as the user b4hub_app",
        ));
    }
    let password = url
        .password()
        .map(|p| percent_decode_str(p).decode_utf8_lossy().into_owned())
        .filter(|p| !p.is_empty())
        .ok_or(Error::InvalidUrl(
            "DATABASE_URL has no password for b4hub_app",
        ))?;
    Ok(password)
}

const CREATE_ROLE: &str = "DO $$ BEGIN EXECUTE format(\
    'CREATE ROLE b4hub_app WITH LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE PASSWORD %L', \
    current_setting('b4hub.app_password')); END $$";
const ALTER_ROLE: &str = "DO $$ BEGIN EXECUTE format(\
    'ALTER ROLE b4hub_app WITH LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE PASSWORD %L', \
    current_setting('b4hub.app_password')); END $$";

/// Creates the role, or sets its password and attributes when it already exists. Roles are
/// cluster-global, so another process (or another database's test) may be creating or altering
/// the same role at the same moment: a `duplicate_object` / `unique_violation` from the create
/// and a "tuple concurrently updated" from the alter are retried as the alternative statement.
async fn provision_role(conn: &mut PgConnection, password: &str) -> Result<()> {
    const ATTEMPTS: usize = 10;
    let mut last = None;
    for attempt in 0..ATTEMPTS {
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)")
                .bind(APP_ROLE)
                .fetch_one(&mut *conn)
                .await?;
        match set_role(
            conn,
            if exists { ALTER_ROLE } else { CREATE_ROLE },
            password,
        )
        .await
        {
            Ok(()) => return Ok(()),
            Err(error) if is_role_race(&error) => {
                last = Some(error);
                tokio::time::sleep(Duration::from_millis(25 * (attempt as u64 + 1))).await;
            }
            Err(error) => return Err(error.into()),
        }
    }
    Err(last.expect("at least one attempt ran").into())
}

async fn set_role(conn: &mut PgConnection, statement: &str, password: &str) -> sqlx::Result<()> {
    let mut tx = conn.begin().await?;
    sqlx::query("SELECT set_config('b4hub.app_password', $1, true)")
        .bind(password)
        .execute(&mut *tx)
        .await?;
    sqlx::query(statement).execute(&mut *tx).await?;
    tx.commit().await
}

fn is_role_race(error: &sqlx::Error) -> bool {
    match error {
        // 42710 duplicate_object, 23505 unique_violation (two creators), XX000 internal_error
        // ("tuple concurrently updated", two alterers).
        sqlx::Error::Database(db) => {
            matches!(db.code().as_deref(), Some("42710" | "23505" | "XX000"))
        }
        _ => false,
    }
}

/// Table access for the application role: read and write everything the migrations created,
/// except the migration ledger, which it may only read (readiness reports from it). Default
/// privileges cover the tables later migrations create as this owner.
async fn grant_table_access(conn: &mut PgConnection) -> Result<()> {
    const STATEMENTS: [&str; 6] = [
        "GRANT USAGE ON SCHEMA public TO b4hub_app",
        "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO b4hub_app",
        "REVOKE INSERT, UPDATE, DELETE ON _sqlx_migrations FROM b4hub_app",
        "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO b4hub_app",
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO b4hub_app",
        "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO b4hub_app",
    ];
    for statement in STATEMENTS {
        sqlx::query(statement).execute(&mut *conn).await?;
    }
    Ok(())
}
