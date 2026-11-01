//! Enrollment codes, device tokens, and the device record: everything the hub does to turn an
//! operator's one-time code into a bearer credential and to check that credential afterwards.
//!
//! Only SHA-256 hashes of codes and tokens are stored. `device_tokens` and `enrollment_codes` are
//! looked up by those hashes before the org is known, so they have no row-level security; the
//! lookups here read the org from the matching row and then set the tenant context on the same
//! transaction before touching `devices` or `users`.

use std::fmt;
use std::time::Duration;

use b4hub_core::ids::new_uuid;
use b4hub_core::tokens::{hash_code, hash_token, new_code, new_token};
use sqlx::types::Uuid;
use sqlx::{Postgres, Transaction};

use crate::tenant::set_tenant;
use crate::{Db, Error, Result};

/// What kind of device enrolled, which decides what it may write: a `macos` device writes any
/// column, an `ios` or `cli` device only the phone-writable ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Macos,
    Ios,
    Cli,
}

impl Platform {
    pub fn parse(text: &str) -> Option<Platform> {
        match text {
            "macos" => Some(Platform::Macos),
            "ios" => Some(Platform::Ios),
            "cli" => Some(Platform::Cli),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Platform::Macos => "macos",
            Platform::Ios => "ios",
            Platform::Cli => "cli",
        }
    }
}

/// A device that proved its token: the principal of every protected request. It comes only from
/// the verified token row and the device row it points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthedDevice {
    pub org_id: Uuid,
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub platform: Platform,
}

/// What redeeming a code yields. `token` is shown to the caller once and stored nowhere.
#[derive(Clone, PartialEq, Eq)]
pub struct Enrolled {
    pub org_id: Uuid,
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub token: String,
    pub org_slug: String,
    pub org_name: String,
    pub username: String,
    pub display_name: String,
}

impl fmt::Debug for Enrolled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Enrolled")
            .field("org_id", &self.org_id)
            .field("user_id", &self.user_id)
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .field("org_slug", &self.org_slug)
            .field("username", &self.username)
            .finish_non_exhaustive()
    }
}

/// A device and the org and user it belongs to, as `GET /v1/me` reports them.
#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
pub struct DeviceInfo {
    pub device_id: Uuid,
    pub device_name: String,
    pub platform: String,
    /// RFC 3339 in UTC with microseconds, rendered by the database.
    pub created_at: String,
    pub org_slug: String,
    pub org_name: String,
    pub username: String,
    pub display_name: String,
}

/// Mints an enrollment code for `user_id` in `org_id` that stays redeemable for `ttl`, and
/// returns it. Only its hash is stored. `ttl` of zero yields a code that is already expired.
pub async fn create_enrollment_code(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    ttl: Duration,
) -> Result<String> {
    // 28^8 codes make a collision with a stored hash vanishingly rare, but a collision must
    // never overwrite or fail an unrelated code, so draw again.
    for _ in 0..5 {
        let code = new_code();
        let mut tx = db.untenanted_tx().await?;
        let inserted = sqlx::query(
            "INSERT INTO enrollment_codes (code_hash, org_id, user_id, expires_at) \
             VALUES ($1, $2, $3, now() + make_interval(secs => $4)) \
             ON CONFLICT (code_hash) DO NOTHING",
        )
        .bind(&hash_code(&code)[..])
        .bind(org_id)
        .bind(user_id)
        .bind(ttl.as_secs_f64())
        .execute(&mut *tx)
        .await?
        .rows_affected();
        tx.commit().await?;
        if inserted == 1 {
            return Ok(code);
        }
    }
    Err(Error::Entropy)
}

/// Redeems `code`: marks it used, creates the device, and issues its token, atomically. A code
/// that is unknown, expired, or already used is [`Error::InvalidCode`]; nothing is changed then.
/// `platform` must be one the `devices` table accepts.
pub async fn redeem(db: &Db, code: &str, name: &str, platform: &str) -> Result<Enrolled> {
    let mut tx = db.untenanted_tx().await?;

    // A single conditional UPDATE is the whole single-use guarantee: of two concurrent
    // redemptions the second waits on the row lock, then finds `used_at` set and matches nothing.
    let claimed: Option<(Uuid, Uuid)> = sqlx::query_as(
        "UPDATE enrollment_codes SET used_at = now() \
         WHERE code_hash = $1 AND used_at IS NULL AND expires_at > now() \
         RETURNING org_id, user_id",
    )
    .bind(&hash_code(code)[..])
    .fetch_optional(&mut *tx)
    .await?;
    let Some((org_id, user_id)) = claimed else {
        return Err(Error::InvalidCode);
    };

    set_tenant(&mut tx, org_id).await?;
    let device_id = new_uuid();
    sqlx::query(
        "INSERT INTO devices (id, org_id, user_id, name, platform) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(device_id)
    .bind(org_id)
    .bind(user_id)
    .bind(name)
    .bind(platform)
    .execute(&mut *tx)
    .await?;
    let token = new_token();
    sqlx::query(
        "INSERT INTO device_tokens (id, org_id, device_id, token_hash) VALUES ($1, $2, $3, $4)",
    )
    .bind(new_uuid())
    .bind(org_id)
    .bind(device_id)
    .bind(&hash_token(&token)[..])
    .execute(&mut *tx)
    .await?;
    let info = describe(&mut tx, device_id)
        .await?
        .ok_or(Error::InvalidCode)?;
    tx.commit().await?;

    Ok(Enrolled {
        org_id,
        user_id,
        device_id,
        token,
        org_slug: info.org_slug,
        org_name: info.org_name,
        username: info.username,
        display_name: info.display_name,
    })
}

/// Resolves a presented token to its device. `None` when the token is unknown, or when the token
/// or its device has been revoked; the caller cannot tell those apart.
pub async fn authenticate(db: &Db, token: &str) -> Result<Option<AuthedDevice>> {
    let mut tx = db.untenanted_tx().await?;
    let found: Option<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT org_id, device_id FROM device_tokens WHERE token_hash = $1 AND revoked_at IS NULL",
    )
    .bind(&hash_token(token)[..])
    .fetch_optional(&mut *tx)
    .await?;
    let Some((org_id, device_id)) = found else {
        return Ok(None);
    };

    set_tenant(&mut tx, org_id).await?;
    let device: Option<(Uuid, String)> = sqlx::query_as(
        "SELECT user_id, platform FROM devices WHERE id = $1 AND revoked_at IS NULL",
    )
    .bind(device_id)
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    let Some((user_id, platform)) = device else {
        return Ok(None);
    };
    // The `devices` table only holds the three platforms.
    let platform = Platform::parse(&platform)
        .ok_or_else(|| sqlx::Error::Decode("unknown device platform".into()))?;
    Ok(Some(AuthedDevice {
        org_id,
        user_id,
        device_id,
        platform,
    }))
}

/// The device record behind `GET /v1/me`; `None` if the device is gone or revoked.
pub async fn me(db: &Db, org_id: Uuid, device_id: Uuid) -> Result<Option<DeviceInfo>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let info = describe(&mut tx, device_id).await?;
    tx.commit().await?;
    Ok(info)
}

/// Revokes the device: deletes its token rows and sets `devices.revoked_at`. Uploaded history is
/// kept. Idempotent.
pub async fn revoke_self(db: &Db, org_id: Uuid, device_id: Uuid) -> Result<()> {
    let mut tx = db.tenant_tx(org_id).await?;
    sqlx::query("UPDATE devices SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL")
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM device_tokens WHERE device_id = $1")
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

/// Records that the device was just seen. Callers throttle this (the service writes it at most
/// once a minute per device); this function always writes.
pub async fn touch_last_seen(db: &Db, org_id: Uuid, device_id: Uuid) -> Result<()> {
    let mut tx = db.tenant_tx(org_id).await?;
    sqlx::query("UPDATE devices SET last_seen_at = now() WHERE id = $1")
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

/// Reads an unrevoked device with its org and user. The transaction must carry the tenant
/// context.
async fn describe(
    tx: &mut Transaction<'_, Postgres>,
    device_id: Uuid,
) -> Result<Option<DeviceInfo>> {
    let info = sqlx::query_as(
        "SELECT d.id AS device_id, d.name AS device_name, d.platform, \
                to_char(d.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') \
                    AS created_at, \
                o.slug AS org_slug, o.name AS org_name, u.username, u.display_name \
         FROM devices d \
         JOIN users u ON u.id = d.user_id \
         JOIN orgs o ON o.id = d.org_id \
         WHERE d.id = $1 AND d.revoked_at IS NULL",
    )
    .bind(device_id)
    .fetch_optional(&mut **tx)
    .await?;
    Ok(info)
}
