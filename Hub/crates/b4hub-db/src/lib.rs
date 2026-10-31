//! PostgreSQL access for the hub: the pool, migrations, and the queries behind the CLI commands.

use std::time::Duration;

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

pub mod migrate;
pub mod orgs;
mod tenant;

/// Everything that can go wrong in this crate. Messages never include a connection URL.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("database error: {0}")]
    Sqlx(#[from] sqlx::Error),
    #[error("migration error: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),
    #[error("DATABASE_URL {0}")]
    InvalidUrl(&'static str),
    #[error("the operating system has no source of randomness")]
    Entropy,
    #[error("the b4hub_app role has SUPERUSER or BYPASSRLS; refusing to continue")]
    PrivilegedRole,
}

pub type Result<T> = std::result::Result<T, Error>;

/// A connection pool. The service holds one connected as `b4hub_app`; operator commands hold one
/// connected as the owner.
#[derive(Clone, Debug)]
pub struct Db {
    pub pool: PgPool,
}

impl Db {
    pub async fn connect(url: &str) -> Result<Db> {
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(5))
            .connect(url)
            .await?;
        Ok(Db { pool })
    }
}
