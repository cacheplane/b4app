//! PostgreSQL access for the hub: the pool, migrations, and the queries behind the CLI commands.

use std::str::FromStr;
use std::time::Duration;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::{ConnectOptions, PgPool};

pub mod accounts;
pub mod ceremonies;
pub mod changes;
pub mod devices;
pub mod migrate;
pub mod orgs;
pub mod prune;
pub mod snapshot;
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
    #[error("the enrollment code is invalid, expired, or already used")]
    InvalidCode,
    /// A pull cursor older than the retained feed; the reader restores from the snapshot.
    #[error("the cursor is older than the retained changes")]
    ResyncRequired,
    #[error("the b4hub_app role has SUPERUSER or BYPASSRLS; refusing to continue")]
    PrivilegedRole,
    /// A ceremony or handoff that is unknown, expired, already used, of another kind, or (for a
    /// handoff) presented with the wrong verifier; the cases are indistinguishable.
    #[error("the sign-in expired or was already used")]
    CeremonyExpired,
    /// Removing the identity would leave the user unable to sign in.
    #[error("the last identity of an account cannot be removed")]
    LastIdentity,
    /// The account to merge away has (or had) a Mac, is not a personal account, or is the
    /// account it would merge into.
    #[error("this account cannot be merged into another")]
    MergeRefused,
    /// The Apple ID or passkey already belongs to an account (its `apple_sub` or `credential_id`
    /// is taken), so nothing was created or added.
    #[error("that sign-in method already belongs to an account")]
    IdentityTaken,
    /// Deleting a user is only implemented for the owner of a personal org.
    #[error("the account belongs to a shared org")]
    SharedOrg,
}

pub type Result<T> = std::result::Result<T, Error>;

/// A connection pool. The service holds one connected as `b4hub_app`; operator commands hold one
/// connected as the owner.
#[derive(Clone, Debug)]
pub struct Db {
    pub pool: PgPool,
}

impl Db {
    /// Connects to `url`, with sqlx's statement logging (every statement at DEBUG, slow ones at
    /// WARN) switched off, so SQL never reaches the hub's log whatever `B4HUB_LOG` allows. TLS
    /// settings (`sslmode`, `sslrootcert`) still come from the URL.
    pub async fn connect(url: &str) -> Result<Db> {
        let options = PgConnectOptions::from_str(url)?.disable_statement_logging();
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(5))
            .connect_with(options)
            .await?;
        Ok(Db { pool })
    }
}
