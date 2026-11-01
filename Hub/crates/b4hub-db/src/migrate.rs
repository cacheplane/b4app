//! Applying migrations and provisioning the application role.

use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use hmac::{Hmac, Mac};
use percent_encoding::percent_decode_str;
use sha2::{Digest, Sha256};
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
/// migrations add). Safe to run repeatedly and concurrently with another run, and works for an
/// owner that is not a superuser (it needs `CREATEROLE`, and `ADMIN` on `b4hub_app` once the
/// role exists). Refuses to continue if the role turns out to be a superuser or to bypass RLS.
pub async fn run(admin_url: &str, app_url: &str) -> Result<()> {
    let password = app_password(app_url).map_err(Error::InvalidUrl)?;
    // The server only ever receives a SCRAM-SHA-256 verifier, never the plaintext password, so
    // neither the statement log, the bind-parameter log, nor an error's CONTEXT can leak it.
    let verifier = scram_sha256_verifier(&password)?;
    let mut conn = PgConnection::connect(admin_url).await?;
    MIGRATOR.run(&mut conn).await?;
    provision_role(&mut conn, &verifier).await?;
    refuse_privileged_role(&mut conn).await?;
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

/// Checks that `app_url` can provision the application role: it connects as `b4hub_app` (the
/// service would otherwise run with the wrong privileges, possibly a superuser's) with a
/// non-empty printable-ASCII password. The reason never includes the URL.
pub fn validate_app_url(app_url: &str) -> std::result::Result<(), &'static str> {
    app_password(app_url).map(|_| ())
}

/// The percent-decoded password of `app_url`, after the checks in [`validate_app_url`]. Printable
/// ASCII keeps this client's SCRAM derivation identical to the server's SASLprep handling.
fn app_password(app_url: &str) -> std::result::Result<String, &'static str> {
    let url = Url::parse(app_url).map_err(|_| "is not a valid URL")?;
    if percent_decode_str(url.username()).decode_utf8_lossy() != APP_ROLE {
        return Err("must connect as the user b4hub_app");
    }
    let password = url
        .password()
        .map(|p| percent_decode_str(p).decode_utf8_lossy().into_owned())
        .filter(|p| !p.is_empty())
        .ok_or("has no password for b4hub_app")?;
    if !password
        .chars()
        .all(|c| c.is_ascii() && !c.is_ascii_control())
    {
        return Err("has a b4hub_app password with characters other than printable ASCII");
    }
    Ok(password)
}

const SCRAM_ITERATIONS: u32 = 4096;

/// A PostgreSQL SCRAM-SHA-256 verifier for `password`:
/// `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>` (RFC 5802 / 7677), with a fresh
/// random salt. PostgreSQL stores a pre-hashed `PASSWORD` literal as given.
fn scram_sha256_verifier(password: &str) -> Result<String> {
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).map_err(|_| Error::Entropy)?;
    Ok(scram_sha256_verifier_with_salt(
        password,
        &salt,
        SCRAM_ITERATIONS,
    ))
}

fn scram_sha256_verifier_with_salt(password: &str, salt: &[u8], iterations: u32) -> String {
    let salted = pbkdf2_hmac_sha256(password.as_bytes(), salt, iterations);
    let client_key = hmac_sha256(&salted, b"Client Key");
    let stored_key = Sha256::digest(client_key);
    let server_key = hmac_sha256(&salted, b"Server Key");
    format!(
        "SCRAM-SHA-256${iterations}:{}${}:{}",
        BASE64.encode(salt),
        BASE64.encode(stored_key),
        BASE64.encode(server_key),
    )
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(message);
    mac.finalize().into_bytes().into()
}

/// PBKDF2-HMAC-SHA-256 for one 32-byte output block, which is all SCRAM needs.
fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut mac = Hmac::<Sha256>::new_from_slice(password).expect("HMAC accepts any key length");
    mac.update(salt);
    mac.update(&1u32.to_be_bytes());
    let mut u: [u8; 32] = mac.finalize().into_bytes().into();
    let mut out = u;
    for _ in 1..iterations {
        u = hmac_sha256(password, &u);
        for (o, b) in out.iter_mut().zip(u) {
            *o ^= b;
        }
    }
    out
}

const CREATE_ROLE: &str = "DO $$ BEGIN EXECUTE format(\
    'CREATE ROLE b4hub_app WITH LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE PASSWORD %L', \
    current_setting('b4hub.app_password')); END $$";
const ALTER_ROLE: &str = "DO $$ BEGIN EXECUTE format(\
    'ALTER ROLE b4hub_app WITH LOGIN PASSWORD %L', \
    current_setting('b4hub.app_password')); END $$";

/// Creates the role, or sets its password when it already exists. The alter changes only
/// `LOGIN` and the password: changing any other attribute (even to its current value) needs
/// SUPERUSER, which a typical owner lacks; [`refuse_privileged_role`] checks the rest. Roles are
/// cluster-global, so another process (or another database's test) may be creating or altering
/// the same role at the same moment: a `duplicate_object` / `unique_violation` from the create
/// and a "tuple concurrently updated" from the alter are retried as the alternative statement.
async fn provision_role(conn: &mut PgConnection, verifier: &str) -> Result<()> {
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
            verifier,
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

async fn set_role(conn: &mut PgConnection, statement: &str, verifier: &str) -> sqlx::Result<()> {
    let mut tx = conn.begin().await?;
    sqlx::query("SELECT set_config('b4hub.app_password', $1, true)")
        .bind(verifier)
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

/// The role must not be able to bypass row-level security: a superuser or `BYPASSRLS` role
/// (say, one created by hand earlier) would make the tenant policies meaningless.
async fn refuse_privileged_role(conn: &mut PgConnection) -> Result<()> {
    let (superuser, bypass_rls): (bool, bool) =
        sqlx::query_as("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1")
            .bind(APP_ROLE)
            .fetch_one(&mut *conn)
            .await?;
    if superuser || bypass_rls {
        return Err(Error::PrivilegedRole);
    }
    Ok(())
}

/// Whether the pool's own role would escape row-level security: a superuser, a `BYPASSRLS` role,
/// or the owner of the tables (the policies are forced, but an owner can still alter or disable
/// them), either itself or through a role it is a member of with `INHERIT` (`pg_has_role(...,
/// 'USAGE')` follows the membership chain and honours `NOINHERIT`). `serve` refuses to start on
/// such a connection.
pub async fn connected_role_is_privileged(db: &Db) -> Result<bool> {
    let privileged: bool = sqlx::query_scalar(
        "SELECT EXISTS ( \
             SELECT 1 FROM pg_roles r \
             WHERE pg_has_role(current_user, r.oid, 'USAGE') \
               AND (r.rolsuper OR r.rolbypassrls OR EXISTS ( \
                   SELECT 1 FROM pg_tables \
                   WHERE tablename = 'changes' AND tableowner = r.rolname)))",
    )
    .fetch_one(&db.pool)
    .await?;
    Ok(privileged)
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Postgres' own derivation is the reference: create a role with a plaintext password under
    /// `password_encryption = scram-sha-256`, then recompute the verifier from the salt and
    /// iteration count it chose.
    #[sqlx::test(migrations = false)]
    async fn verifier_matches_what_postgres_derives(pool: sqlx::PgPool) {
        let role = format!("b4hub_scram_probe_{}", b4hub_core::ids::new_uuid().simple());
        let mut conn = pool.acquire().await.unwrap();
        sqlx::query("SET password_encryption = 'scram-sha-256'")
            .execute(&mut *conn)
            .await
            .unwrap();
        sqlx::query(&format!("CREATE ROLE {role} PASSWORD 'correct horse'"))
            .execute(&mut *conn)
            .await
            .unwrap();
        let reference: String =
            sqlx::query_scalar("SELECT rolpassword FROM pg_authid WHERE rolname = $1")
                .bind(&role)
                .fetch_one(&mut *conn)
                .await
                .unwrap();
        sqlx::query(&format!("DROP ROLE {role}"))
            .execute(&mut *conn)
            .await
            .unwrap();

        let params = reference.split('$').nth(1).unwrap();
        let (iterations, salt) = params.split_once(':').unwrap();
        let salt = BASE64.decode(salt).unwrap();
        let ours =
            scram_sha256_verifier_with_salt("correct horse", &salt, iterations.parse().unwrap());
        assert_eq!(ours, reference);
    }

    #[test]
    fn verifiers_use_a_fresh_salt_and_hide_the_password() {
        let a = scram_sha256_verifier("pw-test").unwrap();
        let b = scram_sha256_verifier("pw-test").unwrap();
        assert_ne!(a, b);
        assert!(a.starts_with("SCRAM-SHA-256$4096:"));
        assert!(!a.contains("pw-test"));
    }

    #[test]
    fn app_url_checks_name_the_problem_and_not_the_value() {
        assert!(validate_app_url("postgres://b4hub_app:s3cr%40t@db/x").is_ok());
        assert_eq!(
            app_password("postgres://b4hub_app:s3cr%40t@db/x").unwrap(),
            "s3cr@t"
        );
        for url in [
            "postgres://postgres:hunter2@db/x",
            "postgres://b4hub_app@db/x",
            "postgres://b4hub_app:@db/x",
            "postgres://b4hub_app:p%C3%A9@db/x",
            "postgres://b4hub_app:a%0Ab@db/x",
            "not a url",
        ] {
            let reason = validate_app_url(url).unwrap_err();
            assert!(!reason.contains("hunter2"), "{url}");
        }
    }
}
