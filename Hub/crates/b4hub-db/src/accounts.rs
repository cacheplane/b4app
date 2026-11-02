//! Accounts that sign in: identities (an Apple ID or a passkey), the personal org a sign-up
//! creates, the sessions a sign-in issues, and deleting or merging an account.
//!
//! `user_identities` has no row-level security: an identity is looked up by an Apple `sub` or a
//! credential id before the org is known, the same as `device_tokens`. Every write to a tenant
//! table runs in one transaction with the tenant context set to the org it writes, and a session
//! is a `device_tokens` row minted exactly as enrollment mints one.

use std::fmt;

use b4hub_core::accounts::{new_org_slug, new_username, personal_org_name, PLACEHOLDER_ORG_NAME};
use b4hub_core::ids::new_uuid;
use b4hub_core::tokens::{hash_token, new_token};
use serde_json::Value;
use sqlx::types::Uuid;
use sqlx::{Postgres, Transaction};

use crate::devices::{AuthedDevice, Platform};
use crate::tenant::set_tenant;
use crate::{Db, Error, Result};

/// Who signed in: a user and the org they belong to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Principal {
    pub org_id: Uuid,
    pub user_id: Uuid,
}

impl From<AuthedDevice> for Principal {
    fn from(device: AuthedDevice) -> Principal {
        Principal {
            org_id: device.org_id,
            user_id: device.user_id,
        }
    }
}

/// The device a sign-in is for, as the client describes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceSpec {
    pub name: String,
    pub platform: Platform,
}

/// A verified way to sign in, as it is stored.
#[derive(Clone, PartialEq)]
pub enum Identity {
    /// An Apple ID: the token's `sub`, the (often relay) email Apple gave, and the refresh token
    /// from the code exchange, already encrypted with `B4HUB_SECRET_KEY`, kept so deleting the
    /// account can revoke it.
    Apple {
        sub: String,
        email: Option<String>,
        refresh_enc: Option<Vec<u8>>,
    },
    /// A passkey: its credential id, webauthn-rs's serialised `Passkey`, the user handle the
    /// authenticator returns, and a name for the list in Settings.
    Passkey {
        credential_id: Vec<u8>,
        passkey_json: Value,
        user_handle: Vec<u8>,
        name: String,
    },
}

impl fmt::Debug for Identity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Identity::Apple { email, .. } => f
                .debug_struct("Apple")
                .field("email", email)
                .finish_non_exhaustive(),
            Identity::Passkey { name, .. } => f
                .debug_struct("Passkey")
                .field("name", name)
                .finish_non_exhaustive(),
        }
    }
}

/// A passkey identity as sign-in reads it back, to verify an assertion against.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredPasskey {
    pub identity_id: Uuid,
    pub passkey: Value,
    pub user_handle: Vec<u8>,
    pub name: Option<String>,
}

/// One identity of a user, as `GET /v1/me` lists it. Timestamps are RFC 3339 in UTC with
/// microseconds, rendered by the database. `name` is a passkey's name or an Apple ID's email.
#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
pub struct IdentitySummary {
    pub id: Uuid,
    pub kind: String,
    pub name: Option<String>,
    pub created_at: String,
    pub last_used_at: Option<String>,
}

/// What a sign-in answers about the account: the org and user as enrollment reports them, and
/// whether the user has onboarded (given a full name) yet.
#[derive(Debug, Clone, PartialEq, Eq, sqlx::FromRow)]
pub struct AccountSummary {
    pub org_slug: String,
    pub org_name: String,
    pub username: String,
    pub display_name: String,
    pub onboarded: bool,
}

/// What a sign-up created. `token` is shown to the caller once and stored nowhere.
#[derive(Clone, PartialEq, Eq)]
pub struct Created {
    pub user_id: Uuid,
    pub org_id: Uuid,
    pub device_id: Uuid,
    pub token: String,
}

impl fmt::Debug for Created {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Created")
            .field("user_id", &self.user_id)
            .field("org_id", &self.org_id)
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// What a sign-in issued. `token` is shown to the caller once and stored nowhere.
#[derive(Clone, PartialEq, Eq)]
pub struct Session {
    pub device_id: Uuid,
    pub token: String,
}

impl fmt::Debug for Session {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Session")
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .finish()
    }
}

/// The encrypted Apple refresh tokens of an account's identities, as stored (sealed with
/// `B4HUB_SECRET_KEY`). `Debug` shows only how many there are.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct SealedAppleTokens(pub Vec<Vec<u8>>);

impl fmt::Debug for SealedAppleTokens {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("SealedAppleTokens")
            .field(&self.0.len())
            .finish()
    }
}

/// What [`delete_user`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Deletion {
    /// The account is gone (or was already).
    Deleted,
    /// The account holds Apple refresh tokens the caller did not say it revoked (an Apple ID was
    /// linked meanwhile); nothing was deleted. Revoke these too, then delete again.
    Unrevoked(SealedAppleTokens),
}

/// A passkey of a user, as adding another one needs it: the credential id to exclude, and the
/// user handle it was registered with.
#[derive(Clone, PartialEq, Eq)]
pub struct PasskeyCredential {
    pub credential_id: Vec<u8>,
    pub user_handle: Vec<u8>,
}

impl fmt::Debug for PasskeyCredential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PasskeyCredential").finish_non_exhaustive()
    }
}

/// Signs up: creates a personal org named [`PLACEHOLDER_ORG_NAME`] with a generated slug, its
/// one user with a generated username (not onboarded), the identity, the device, and its token,
/// in one transaction. An identity that already exists fails the insert and nothing is created.
pub async fn create_personal(db: &Db, identity: Identity, device: DeviceSpec) -> Result<Created> {
    let mut tx = db.untenanted_tx().await?;

    // `orgs` carries no row-level security, so the org goes in before the tenant is set. A slug
    // collision among 32^8 is vanishingly rare, but must not fail a sign-up, so draw again.
    let org_id = new_uuid();
    let mut inserted = false;
    for _ in 0..5 {
        inserted = sqlx::query(
            "INSERT INTO orgs (id, slug, name, personal) VALUES ($1, $2, $3, true) \
             ON CONFLICT (slug) DO NOTHING",
        )
        .bind(org_id)
        .bind(new_org_slug())
        .bind(PLACEHOLDER_ORG_NAME)
        .execute(&mut *tx)
        .await?
        .rows_affected()
            == 1;
        if inserted {
            break;
        }
    }
    if !inserted {
        return Err(Error::Entropy);
    }

    set_tenant(&mut tx, org_id).await?;
    // The org is new, so its one username cannot collide. `display_name` is required; it stays
    // empty until onboarding gives a full name.
    let user_id = new_uuid();
    sqlx::query("INSERT INTO users (id, org_id, username, display_name) VALUES ($1, $2, $3, '')")
        .bind(user_id)
        .bind(org_id)
        .bind(new_username())
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE orgs SET owner_user_id = $2 WHERE id = $1")
        .bind(org_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await?;
    let principal = Principal { org_id, user_id };
    insert_identity(&mut tx, principal, &identity).await?;
    let session = create_session(&mut tx, principal, &device, None).await?;
    tx.commit().await?;

    Ok(Created {
        user_id,
        org_id,
        device_id: session.device_id,
        token: session.token,
    })
}

/// The account whose Apple identity has `sub`, if any.
pub async fn find_by_apple_sub(db: &Db, sub: &str) -> Result<Option<Principal>> {
    let found: Option<(Uuid, Uuid)> =
        sqlx::query_as("SELECT org_id, user_id FROM user_identities WHERE apple_sub = $1")
            .bind(sub)
            .fetch_optional(&db.pool)
            .await?;
    Ok(found.map(|(org_id, user_id)| Principal { org_id, user_id }))
}

/// The account and stored passkey whose credential id is `credential_id`, if any.
pub async fn find_by_credential(
    db: &Db,
    credential_id: &[u8],
) -> Result<Option<(Principal, StoredPasskey)>> {
    type Row = (Uuid, Uuid, Uuid, Value, Vec<u8>, Option<String>);
    let found: Option<Row> = sqlx::query_as(
        "SELECT org_id, user_id, id, passkey, user_handle, name FROM user_identities \
         WHERE credential_id = $1 AND kind = 'passkey'",
    )
    .bind(credential_id)
    .fetch_optional(&db.pool)
    .await?;
    Ok(found.map(
        |(org_id, user_id, identity_id, passkey, user_handle, name)| {
            (
                Principal { org_id, user_id },
                StoredPasskey {
                    identity_id,
                    passkey,
                    user_handle,
                    name,
                },
            )
        },
    ))
}

/// Records that the passkey identity `identity_id` was just used to sign in: sets `last_used_at`,
/// and replaces the stored passkey with `passkey` when the assertion changed it (its counter or
/// backup state).
pub async fn record_passkey_use(db: &Db, identity_id: Uuid, passkey: Option<&Value>) -> Result<()> {
    sqlx::query(
        "UPDATE user_identities SET last_used_at = now(), passkey = COALESCE($2, passkey) \
         WHERE id = $1 AND kind = 'passkey'",
    )
    .bind(identity_id)
    .bind(passkey)
    .execute(&db.pool)
    .await?;
    Ok(())
}

/// `principal`'s org and user as a sign-in reports them; `None` when there is no such user.
pub async fn account_summary(db: &Db, principal: Principal) -> Result<Option<AccountSummary>> {
    let mut tx = db.tenant_tx(principal.org_id).await?;
    let summary = sqlx::query_as(
        "SELECT o.slug AS org_slug, o.name AS org_name, u.username, u.display_name, \
                u.onboarded_at IS NOT NULL AS onboarded \
         FROM users u JOIN orgs o ON o.id = u.org_id \
         WHERE u.id = $1 AND u.org_id = $2",
    )
    .bind(principal.user_id)
    .bind(principal.org_id)
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(summary)
}

/// Signs `principal` in on `device`: issues a token for the device `reuse` names when it is an
/// unrevoked device of this user on the same platform (renaming it to `device.name` and
/// replacing its earlier tokens, so a session a failed log-out left open ends here), otherwise
/// for a new device.
pub async fn issue_session(
    db: &Db,
    principal: Principal,
    device: DeviceSpec,
    reuse: Option<Uuid>,
) -> Result<Session> {
    let mut tx = db.tenant_tx(principal.org_id).await?;
    let session = create_session(&mut tx, principal, &device, reuse).await?;
    tx.commit().await?;
    Ok(session)
}

/// Records the full name the user gave at onboarding: sets `full_name` and `display_name`, marks
/// the user onboarded (once), and renames the org to [`personal_org_name`] when it is this user's
/// personal org. `tx` must carry the user's tenant context.
pub async fn set_profile(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    full_name: &str,
) -> Result<()> {
    let org_id: Option<Uuid> = sqlx::query_scalar(
        "UPDATE users SET full_name = $2, display_name = $2, \
                          onboarded_at = COALESCE(onboarded_at, now()) \
         WHERE id = $1 RETURNING org_id",
    )
    .bind(user_id)
    .bind(full_name)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some(org_id) = org_id {
        sqlx::query("UPDATE orgs SET name = $3 WHERE id = $1 AND personal AND owner_user_id = $2")
            .bind(org_id)
            .bind(user_id)
            .bind(personal_org_name(full_name))
            .execute(&mut **tx)
            .await?;
    }
    Ok(())
}

/// [`set_profile`] for `principal` in a transaction of its own.
pub async fn update_profile(db: &Db, principal: Principal, full_name: &str) -> Result<()> {
    let mut tx = db.tenant_tx(principal.org_id).await?;
    set_profile(&mut tx, principal.user_id, full_name).await?;
    tx.commit().await?;
    Ok(())
}

/// Adds `identity` to `principal`'s account and returns its id. An identity that already
/// belongs to any account fails the insert.
pub async fn add_identity(db: &Db, principal: Principal, identity: Identity) -> Result<Uuid> {
    let mut tx = db.tenant_tx(principal.org_id).await?;
    let id = insert_identity(&mut tx, principal, &identity).await?;
    tx.commit().await?;
    Ok(id)
}

/// Removes the identity `identity_id` from `principal`'s account. `false` when the account has
/// no such identity; [`Error::LastIdentity`] when it is the account's only one.
pub async fn remove_identity(db: &Db, principal: Principal, identity_id: Uuid) -> Result<bool> {
    let mut tx = db.untenanted_tx().await?;
    // Locking every identity of the user serialises concurrent removals, so two of them cannot
    // each see the other's identity and leave the account with none.
    let ids: Vec<Uuid> = sqlx::query_scalar(
        "SELECT id FROM user_identities WHERE org_id = $1 AND user_id = $2 FOR UPDATE",
    )
    .bind(principal.org_id)
    .bind(principal.user_id)
    .fetch_all(&mut *tx)
    .await?;
    if !ids.contains(&identity_id) {
        return Ok(false);
    }
    if ids.len() == 1 {
        return Err(Error::LastIdentity);
    }
    sqlx::query("DELETE FROM user_identities WHERE id = $1")
        .bind(identity_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(true)
}

/// `principal`'s identities, oldest first.
pub async fn list_identities(db: &Db, principal: Principal) -> Result<Vec<IdentitySummary>> {
    const RFC3339: &str = "'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'";
    let identities = sqlx::query_as(&format!(
        "SELECT id, kind, COALESCE(name, apple_email) AS name, \
                to_char(created_at AT TIME ZONE 'UTC', {RFC3339}) AS created_at, \
                to_char(last_used_at AT TIME ZONE 'UTC', {RFC3339}) AS last_used_at \
         FROM user_identities WHERE org_id = $1 AND user_id = $2 \
         ORDER BY created_at, id"
    ))
    .bind(principal.org_id)
    .bind(principal.user_id)
    .fetch_all(&db.pool)
    .await?;
    Ok(identities)
}

/// The first half of deleting `principal`'s account: the encrypted Apple refresh tokens it
/// holds, for the caller to revoke at Apple before [`delete_user`]. An account in a shared org is
/// [`Error::SharedOrg`], refused here so that nothing is revoked for an account that cannot be
/// deleted.
pub async fn apple_tokens_to_revoke(db: &Db, principal: Principal) -> Result<SealedAppleTokens> {
    let mut tx = db.tenant_tx(principal.org_id).await?;
    if !owns_personal_org(&mut tx, principal).await? {
        return Err(Error::SharedOrg);
    }
    let tokens = sealed_apple_tokens(&mut tx, principal).await?;
    tx.commit().await?;
    Ok(tokens)
}

/// Deletes `principal`'s account once its Apple refresh tokens are revoked: every row of their
/// personal org in every tenant table, then the user and the org, in one transaction that first
/// locks the user row (so no identity or device can be added for it meanwhile). `revoked` is
/// what the caller revoked; a token the account holds beyond those is
/// [`Deletion::Unrevoked`] and nothing is deleted. An account in a shared org is
/// [`Error::SharedOrg`]; one already gone is [`Deletion::Deleted`].
pub async fn delete_user(
    db: &Db,
    principal: Principal,
    revoked: &SealedAppleTokens,
) -> Result<Deletion> {
    let mut tx = db.tenant_tx(principal.org_id).await?;
    if !lock_user(&mut tx, principal.user_id).await? {
        return Ok(Deletion::Deleted);
    }
    if !owns_personal_org(&mut tx, principal).await? {
        return Err(Error::SharedOrg);
    }
    let held = sealed_apple_tokens(&mut tx, principal).await?;
    let unrevoked: Vec<Vec<u8>> = held
        .0
        .into_iter()
        .filter(|token| !revoked.0.contains(token))
        .collect();
    if !unrevoked.is_empty() {
        return Ok(Deletion::Unrevoked(SealedAppleTokens(unrevoked)));
    }
    delete_org(&mut tx, principal.org_id).await?;
    tx.commit().await?;
    Ok(Deletion::Deleted)
}

/// Merges the phone-only account `from` into `into`, as pairing a phone with a Mac's account
/// does: `from`'s identities move to `into`, then `from`'s tokens, devices, user, and personal
/// org are deleted, in one transaction. [`Error::MergeRefused`] when `from` has ever had a
/// `macos` device (revoked or not), is not the owner of a personal org, or is `into`; nothing
/// changes then.
pub async fn merge_phone_only(db: &Db, from: Principal, into: Principal) -> Result<()> {
    let mut tx = db.untenanted_tx().await?;
    merge_in(&mut tx, from, into).await?;
    tx.commit().await?;
    Ok(())
}

/// [`merge_phone_only`] inside `tx`, which it leaves with `from.org_id`'s tenant context. On an
/// error the caller must roll `tx` back.
pub(crate) async fn merge_in(
    tx: &mut Transaction<'_, Postgres>,
    from: Principal,
    into: Principal,
) -> Result<()> {
    if from == into || from.org_id == into.org_id {
        return Err(Error::MergeRefused);
    }
    set_tenant(tx, from.org_id).await?;
    // Locking the user row first holds off a device enrolling for it meanwhile (its foreign key
    // needs a share lock on the row), so the check below stays true until commit.
    if !lock_user(tx, from.user_id).await? || !owns_personal_org(tx, from).await? {
        return Err(Error::MergeRefused);
    }
    let has_mac: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM devices WHERE user_id = $1 AND platform = 'macos')",
    )
    .bind(from.user_id)
    .fetch_one(&mut **tx)
    .await?;
    if has_mac {
        return Err(Error::MergeRefused);
    }

    sqlx::query(
        "UPDATE user_identities SET org_id = $3, user_id = $4 WHERE org_id = $1 AND user_id = $2",
    )
    .bind(from.org_id)
    .bind(from.user_id)
    .bind(into.org_id)
    .bind(into.user_id)
    .execute(&mut **tx)
    .await?;
    delete_org(tx, from.org_id).await?;
    Ok(())
}

/// `principal`'s passkeys, oldest first.
pub async fn passkey_credentials(db: &Db, principal: Principal) -> Result<Vec<PasskeyCredential>> {
    let rows: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as(
        "SELECT credential_id, user_handle FROM user_identities \
         WHERE org_id = $1 AND user_id = $2 AND kind = 'passkey' ORDER BY created_at, id",
    )
    .bind(principal.org_id)
    .bind(principal.user_id)
    .fetch_all(&db.pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(credential_id, user_handle)| PasskeyCredential {
            credential_id,
            user_handle,
        })
        .collect())
}

/// Locks the user row `FOR UPDATE`; `false` when there is no such user. `tx` must carry the
/// user's tenant context.
async fn lock_user(tx: &mut Transaction<'_, Postgres>, user_id: Uuid) -> Result<bool> {
    let locked: Option<Uuid> = sqlx::query_scalar("SELECT id FROM users WHERE id = $1 FOR UPDATE")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await?;
    Ok(locked.is_some())
}

async fn sealed_apple_tokens(
    tx: &mut Transaction<'_, Postgres>,
    principal: Principal,
) -> Result<SealedAppleTokens> {
    let tokens = sqlx::query_scalar(
        "SELECT apple_refresh_token_enc FROM user_identities \
         WHERE org_id = $1 AND user_id = $2 AND apple_refresh_token_enc IS NOT NULL \
         ORDER BY created_at, id",
    )
    .bind(principal.org_id)
    .bind(principal.user_id)
    .fetch_all(&mut **tx)
    .await?;
    Ok(SealedAppleTokens(tokens))
}

/// Whether `principal` is the owner of a personal org that is `principal.org_id`.
async fn owns_personal_org(
    tx: &mut Transaction<'_, Postgres>,
    principal: Principal,
) -> Result<bool> {
    let owns: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM orgs WHERE id = $1 AND personal AND owner_user_id = $2)",
    )
    .bind(principal.org_id)
    .bind(principal.user_id)
    .fetch_one(&mut **tx)
    .await?;
    Ok(owns)
}

/// Every table with an `org_id` column, in an order that deletes rows before the rows they
/// reference. `users` and `orgs` follow. A table added later must be added here too; the test
/// `delete_user_removes_every_tenant_row` lists the tables from the catalogue and fails until it
/// is.
const ORG_TABLES: [&str; 16] = [
    "changes",
    "column_clocks",
    "org_sync_horizons",
    "connections",
    "threads",
    "turns",
    "displayItems",
    "runtimeRequests",
    "drafts",
    "projectFolders",
    "projects",
    "auth_handoffs",
    "user_identities",
    "enrollment_codes",
    "device_tokens",
    "devices",
];

/// Deletes every row of `org_id` in every tenant table, then its users and the org itself. `tx`
/// must carry `org_id`'s tenant context, which the row-secured tables need.
async fn delete_org(tx: &mut Transaction<'_, Postgres>, org_id: Uuid) -> Result<()> {
    for table in ORG_TABLES {
        sqlx::query(&format!("DELETE FROM \"{table}\" WHERE org_id = $1"))
            .bind(org_id)
            .execute(&mut **tx)
            .await?;
    }
    // Deleting the users clears `orgs.owner_user_id` (ON DELETE SET NULL).
    sqlx::query("DELETE FROM users WHERE org_id = $1")
        .bind(org_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM orgs WHERE id = $1")
        .bind(org_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// The unique constraints that make an Apple ID or a passkey belong to one account.
const IDENTITY_KEYS: [&str; 2] = [
    "user_identities_apple_sub_key",
    "user_identities_credential_id_key",
];

/// Inserts `identity` for `principal` and returns its id; [`Error::IdentityTaken`] when it already
/// belongs to an account.
async fn insert_identity(
    tx: &mut Transaction<'_, Postgres>,
    principal: Principal,
    identity: &Identity,
) -> Result<Uuid> {
    insert_identity_row(tx, principal, identity)
        .await
        .map_err(|error| match error {
            Error::Sqlx(sqlx::Error::Database(db))
                if db.is_unique_violation()
                    && db.constraint().is_some_and(|c| IDENTITY_KEYS.contains(&c)) =>
            {
                Error::IdentityTaken
            }
            other => other,
        })
}

async fn insert_identity_row(
    tx: &mut Transaction<'_, Postgres>,
    principal: Principal,
    identity: &Identity,
) -> Result<Uuid> {
    let id = new_uuid();
    match identity {
        Identity::Apple {
            sub,
            email,
            refresh_enc,
        } => {
            sqlx::query(
                "INSERT INTO user_identities \
                     (id, org_id, user_id, kind, apple_sub, apple_email, apple_refresh_token_enc) \
                 VALUES ($1, $2, $3, 'apple', $4, $5, $6)",
            )
            .bind(id)
            .bind(principal.org_id)
            .bind(principal.user_id)
            .bind(sub)
            .bind(email)
            .bind(refresh_enc)
            .execute(&mut **tx)
            .await?;
        }
        Identity::Passkey {
            credential_id,
            passkey_json,
            user_handle,
            name,
        } => {
            sqlx::query(
                "INSERT INTO user_identities \
                     (id, org_id, user_id, kind, credential_id, passkey, user_handle, name) \
                 VALUES ($1, $2, $3, 'passkey', $4, $5, $6, $7)",
            )
            .bind(id)
            .bind(principal.org_id)
            .bind(principal.user_id)
            .bind(credential_id)
            .bind(passkey_json)
            .bind(user_handle)
            .bind(name)
            .execute(&mut **tx)
            .await?;
        }
    }
    Ok(id)
}

/// Picks the device (see [`issue_session`]) and inserts its token. `tx` must carry
/// `principal.org_id`'s tenant context.
async fn create_session(
    tx: &mut Transaction<'_, Postgres>,
    principal: Principal,
    device: &DeviceSpec,
    reuse: Option<Uuid>,
) -> Result<Session> {
    let reused: Option<Uuid> = match reuse {
        Some(id) => {
            sqlx::query_scalar(
                "UPDATE devices SET name = $5 \
                 WHERE id = $1 AND org_id = $2 AND user_id = $3 AND platform = $4 \
                   AND revoked_at IS NULL \
                 RETURNING id",
            )
            .bind(id)
            .bind(principal.org_id)
            .bind(principal.user_id)
            .bind(device.platform.as_str())
            .bind(&device.name)
            .fetch_optional(&mut **tx)
            .await?
        }
        None => None,
    };
    let device_id = match reused {
        Some(id) => {
            sqlx::query("DELETE FROM device_tokens WHERE device_id = $1")
                .bind(id)
                .execute(&mut **tx)
                .await?;
            id
        }
        None => {
            let id = new_uuid();
            sqlx::query(
                "INSERT INTO devices (id, org_id, user_id, name, platform) \
                 VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(id)
            .bind(principal.org_id)
            .bind(principal.user_id)
            .bind(&device.name)
            .bind(device.platform.as_str())
            .execute(&mut **tx)
            .await?;
            id
        }
    };
    let token = new_token();
    sqlx::query(
        "INSERT INTO device_tokens (id, org_id, device_id, token_hash) VALUES ($1, $2, $3, $4)",
    )
    .bind(new_uuid())
    .bind(principal.org_id)
    .bind(device_id)
    .bind(&hash_token(&token)[..])
    .execute(&mut **tx)
    .await?;
    Ok(Session { device_id, token })
}
