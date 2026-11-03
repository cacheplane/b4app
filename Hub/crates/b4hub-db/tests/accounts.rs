//! Accounts, identities, personal orgs, and sign-in ceremonies against a real PostgreSQL. Run with
//! `source <(./scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use std::borrow::Cow;
use std::time::Duration;

use b4hub_core::change::{Change, ChangeOp};
use b4hub_core::ids::new_uuid;
use b4hub_core::tokens::hash_token;
use b4hub_db::accounts::{
    self, Deletion, DeviceSpec, Identity, Principal, Removal, SealedAppleToken, SealedAppleTokens,
};
use b4hub_db::devices::{self, AuthedDevice, Platform};
use b4hub_db::{ceremonies, changes, orgs, Db, Error, MergeRefusal};
use serde_json::json;
use sqlx::migrate::Migrator;
use sqlx::types::Uuid;
use sqlx::{Connection, PgConnection, PgPool};

fn passkey(credential: &[u8]) -> Identity {
    Identity::Passkey {
        credential_id: credential.to_vec(),
        passkey_json: json!({"cred": {"cred_id": credential}}),
        user_handle: b"handle".to_vec(),
        name: "iCloud Keychain".into(),
    }
}

fn apple(sub: &str) -> Identity {
    Identity::Apple {
        id: new_uuid(),
        sub: sub.into(),
        email: Some(format!("{sub}@privaterelay.appleid.com")),
        refresh_enc: Some(format!("enc-{sub}").into_bytes()),
    }
}

fn device(name: &str, platform: Platform) -> DeviceSpec {
    DeviceSpec {
        name: name.into(),
        platform,
    }
}

/// The device a token just issued authenticates as.
async fn authed(app: &Db, token: &str) -> AuthedDevice {
    devices::authenticate(app, token)
        .await
        .unwrap()
        .expect("the token just issued authenticates")
}

#[test]
fn principal_comes_from_an_authed_device() {
    let (org_id, user_id) = (Uuid::from_u128(1), Uuid::from_u128(2));
    let device = AuthedDevice {
        org_id,
        user_id,
        device_id: Uuid::from_u128(3),
        platform: Platform::Ios,
    };
    assert_eq!(Principal::from(device), Principal { org_id, user_id });
}

#[sqlx::test(migrations = false)]
async fn migration_backfills_existing_users(pool: PgPool) {
    // Migrate to just before 0005, seed the way an existing hub was, then apply the rest.
    let full = sqlx::migrate!("./migrations");
    let before = Migrator {
        migrations: Cow::Owned(
            full.iter()
                .filter(|m| m.version < 5)
                .cloned()
                .collect::<Vec<_>>(),
        ),
        ..Migrator::DEFAULT
    };
    let mut conn = PgConnection::connect(&common::admin_url(&pool))
        .await
        .unwrap();
    before.run(&mut conn).await.unwrap();
    conn.close().await.unwrap();
    // What `seed` wrote before 0005 (it now also writes the columns 0005 adds). The test pool's
    // user is the cluster superuser, which bypasses row-level security.
    let org_id = b4hub_core::ids::new_uuid();
    sqlx::query("INSERT INTO orgs (id, slug, name) VALUES ($1, 'cacheplane', 'cacheplane')")
        .bind(org_id)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO users (id, org_id, username, display_name, email) \
         VALUES ($1, $2, 'blove', 'Brian Love', 'b@example.test')",
    )
    .bind(b4hub_core::ids::new_uuid())
    .bind(org_id)
    .execute(&pool)
    .await
    .unwrap();

    common::migrated(&pool).await;

    let (full_name, onboarded, email): (Option<String>, bool, Option<String>) = sqlx::query_as(
        "SELECT full_name, onboarded_at = created_at, email FROM users WHERE username = 'blove'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(full_name.as_deref(), Some("Brian Love"));
    assert!(onboarded);
    assert_eq!(email.as_deref(), Some("b@example.test"));
    let (personal, owner_user): (bool, Option<Uuid>) =
        sqlx::query_as("SELECT personal, owner_user_id FROM orgs WHERE slug = 'cacheplane'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(!personal);
    assert_eq!(owner_user, None);

    // An operator's `seed` after the migration onboards the user it names, the same way.
    let owner = Db { pool: pool.clone() };
    orgs::seed(
        &owner,
        "cacheplane",
        "cacheplane",
        "sam",
        "Sam Doe",
        "s@example.test",
    )
    .await
    .unwrap();
    let (full_name, onboarded): (Option<String>, bool) = sqlx::query_as(
        "SELECT full_name, onboarded_at IS NOT NULL FROM users WHERE username = 'sam'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(full_name.as_deref(), Some("Sam Doe"));
    assert!(onboarded);
}

#[sqlx::test(migrations = false)]
async fn create_personal_makes_user_org_device_token(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(
        &app,
        passkey(b"cred-1"),
        device("Brian's iPhone", Platform::Ios),
    )
    .await
    .unwrap();

    let who = authed(&app, &created.token).await;
    assert_eq!(
        (who.org_id, who.user_id, who.device_id, who.platform),
        (
            created.org_id,
            created.user_id,
            created.device_id,
            Platform::Ios
        )
    );
    let info = devices::me(&app, created.org_id, created.device_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(info.org_name, "My Org");
    assert_eq!(info.device_name, "Brian's iPhone");
    assert!(info.username.starts_with("u-"), "{}", info.username);
    assert_eq!(info.username.len(), 10);
    assert!(info.org_slug.starts_with("o-"), "{}", info.org_slug);
    assert_eq!(info.org_slug.len(), 10);

    let (personal, owner): (bool, Option<Uuid>) =
        sqlx::query_as("SELECT personal, owner_user_id FROM orgs WHERE id = $1")
            .bind(created.org_id)
            .fetch_one(&app.pool)
            .await
            .unwrap();
    assert!(personal);
    assert_eq!(owner, Some(created.user_id));

    // A new user has not onboarded and has no email or full name yet.
    let mut tx = app.tenant_tx(created.org_id).await.unwrap();
    let (onboarded, full_name, email): (Option<String>, Option<String>, Option<String>) =
        sqlx::query_as("SELECT onboarded_at::text, full_name, email FROM users WHERE id = $1")
            .bind(created.user_id)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
    tx.rollback().await.unwrap();
    assert_eq!((onboarded, full_name, email), (None, None, None));

    let found = accounts::find_by_credential(&app, b"cred-1")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        found.0,
        Principal {
            org_id: created.org_id,
            user_id: created.user_id
        }
    );
    assert_eq!(found.1.passkey, json!({"cred": {"cred_id": b"cred-1"}}));
    assert_eq!(found.1.user_handle, b"handle");
    assert!(accounts::find_by_credential(&app, b"cred-2")
        .await
        .unwrap()
        .is_none());

    let by_apple =
        accounts::create_personal(&app, apple("001.abc"), device("Mac", Platform::Macos))
            .await
            .unwrap();
    assert_ne!(by_apple.org_id, created.org_id);
    assert_eq!(
        accounts::find_by_apple_sub(&app, "001.abc").await.unwrap(),
        Some(Principal {
            org_id: by_apple.org_id,
            user_id: by_apple.user_id
        })
    );
    assert_eq!(
        accounts::find_by_apple_sub(&app, "001.xyz").await.unwrap(),
        None
    );

    // The token is redacted from Debug output.
    assert!(!format!("{created:?}").contains(&created.token));
}

#[sqlx::test(migrations = false)]
async fn set_profile_onboards_and_renames_the_personal_org(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"c"), device("iPhone", Platform::Ios))
        .await
        .unwrap();
    let mut tx = app.tenant_tx(created.org_id).await.unwrap();
    accounts::set_profile(&mut tx, created.user_id, "Brian Love")
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let info = devices::me(&app, created.org_id, created.device_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(info.org_name, "Brian's Org");
    assert_eq!(info.display_name, "Brian Love");

    // A shared org keeps its name when a member sets a profile.
    let member = common::enrolled(&admin, &app, "blove").await;
    let mut tx = app.tenant_tx(member.org_id).await.unwrap();
    accounts::set_profile(&mut tx, member.user_id, "Brian Love")
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let info = devices::me(&app, member.org_id, member.device_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(info.org_name, "cacheplane");
}

#[sqlx::test(migrations = false)]
async fn take_is_single_use(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let state = json!({"registration": {"challenge": "abc"}});
    let id = ceremonies::create(&app, "passkey", state.clone())
        .await
        .unwrap();
    assert!(matches!(
        ceremonies::take(&app, id, "apple").await,
        Err(Error::CeremonyExpired)
    ));
    assert_eq!(ceremonies::take(&app, id, "passkey").await.unwrap(), state);
    assert!(matches!(
        ceremonies::take(&app, id, "passkey").await,
        Err(Error::CeremonyExpired)
    ));
    assert!(matches!(
        ceremonies::take(&app, Uuid::from_u128(7), "passkey").await,
        Err(Error::CeremonyExpired)
    ));
}

#[sqlx::test(migrations = false)]
async fn take_concurrent_one_wins(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    for _ in 0..20 {
        let id = ceremonies::create(&app, "passkey", json!({}))
            .await
            .unwrap();
        let (one, two) = (app.clone(), app.clone());
        let first = tokio::spawn(async move { ceremonies::take(&one, id, "passkey").await });
        let second = tokio::spawn(async move { ceremonies::take(&two, id, "passkey").await });
        let results = [first.await.unwrap(), second.await.unwrap()];
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert!(results
            .iter()
            .any(|r| matches!(r, Err(Error::CeremonyExpired))));
    }
}

#[sqlx::test(migrations = false)]
async fn take_expired(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let id = ceremonies::create(&app, "passkey", json!({}))
        .await
        .unwrap();
    let lifetime: f64 = sqlx::query_scalar(
        "SELECT extract(epoch FROM expires_at - created_at)::float8 FROM auth_ceremonies \
         WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(lifetime, 300.0);
    sqlx::query("UPDATE auth_ceremonies SET expires_at = now() - interval '1 second'")
        .execute(&pool)
        .await
        .unwrap();
    assert!(matches!(
        ceremonies::take(&app, id, "passkey").await,
        Err(Error::CeremonyExpired)
    ));
}

#[sqlx::test(migrations = false)]
async fn handoff_needs_the_verifier_and_is_single_use(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, apple("001.a"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let verifier_hash = hash_token("verifier");
    let ceremony = ceremonies::create(&app, "apple", json!({"verifierHash": "…"}))
        .await
        .unwrap();
    let code = ceremonies::create_handoff(&app, ceremony, principal, &verifier_hash)
        .await
        .unwrap();
    let lifetime: f64 = sqlx::query_scalar(
        "SELECT extract(epoch FROM expires_at - now())::float8 FROM auth_handoffs",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!((115.0..=120.0).contains(&lifetime), "{lifetime}");
    let code_hash = hash_token(&code);

    // A wrong verifier looks exactly like an expired handoff, and does not spend it.
    assert!(matches!(
        ceremonies::take_handoff(&app, &code_hash, &hash_token("guess")).await,
        Err(Error::CeremonyExpired)
    ));
    assert!(matches!(
        ceremonies::take_handoff(&app, &hash_token("other code"), &verifier_hash).await,
        Err(Error::CeremonyExpired)
    ));
    assert_eq!(
        ceremonies::take_handoff(&app, &code_hash, &verifier_hash)
            .await
            .unwrap(),
        principal
    );
    assert!(matches!(
        ceremonies::take_handoff(&app, &code_hash, &verifier_hash).await,
        Err(Error::CeremonyExpired)
    ));

    // Concurrent takes: exactly one wins.
    let code = ceremonies::create_handoff(&app, ceremony, principal, &verifier_hash)
        .await
        .unwrap();
    let code_hash = hash_token(&code);
    let (one, two) = (app.clone(), app.clone());
    let first =
        tokio::spawn(
            async move { ceremonies::take_handoff(&one, &code_hash, &verifier_hash).await },
        );
    let second =
        tokio::spawn(
            async move { ceremonies::take_handoff(&two, &code_hash, &verifier_hash).await },
        );
    let results = [first.await.unwrap(), second.await.unwrap()];
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);

    // Expired.
    let code = ceremonies::create_handoff(&app, ceremony, principal, &verifier_hash)
        .await
        .unwrap();
    sqlx::query("UPDATE auth_handoffs SET expires_at = now() - interval '1 second'")
        .execute(&pool)
        .await
        .unwrap();
    assert!(matches!(
        ceremonies::take_handoff(&app, &hash_token(&code), &verifier_hash).await,
        Err(Error::CeremonyExpired)
    ));
}

#[sqlx::test(migrations = false)]
async fn prune_expired_removes_old_ceremonies_and_handoffs(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, apple("001.a"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let old = ceremonies::create(&app, "apple", json!({})).await.unwrap();
    ceremonies::create_handoff(&app, old, principal, &hash_token("v"))
        .await
        .unwrap();
    let live = ceremonies::create(&app, "passkey", json!({}))
        .await
        .unwrap();
    sqlx::query(
        "UPDATE auth_ceremonies SET expires_at = now() - interval '1 second' WHERE id = $1",
    )
    .bind(old)
    .execute(&pool)
    .await
    .unwrap();

    // Nothing goes within a minute of its expiry, so a finish racing the deadline never has its
    // row deleted from under it.
    sqlx::query("UPDATE auth_handoffs SET expires_at = now() - interval '1 second'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(ceremonies::prune_expired(&app).await.unwrap(), 0);
    sqlx::query(
        "UPDATE auth_ceremonies SET expires_at = now() - interval '61 seconds' WHERE id = $1",
    )
    .bind(old)
    .execute(&pool)
    .await
    .unwrap();

    // The expired ceremony stays while a handoff still points at it.
    assert_eq!(ceremonies::prune_expired(&app).await.unwrap(), 0);
    sqlx::query("UPDATE auth_handoffs SET expires_at = now() - interval '61 seconds'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(ceremonies::prune_expired(&app).await.unwrap(), 2);
    let left: Vec<Uuid> = sqlx::query_scalar("SELECT id FROM auth_ceremonies")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert_eq!(left, vec![live]);
}

#[sqlx::test(migrations = false)]
async fn a_step_up_grant_is_taken_once_by_its_own_user_and_device(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"c"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let other = accounts::issue_session(&app, principal, device("iPhone", Platform::Ios), None)
        .await
        .unwrap();
    let grant = ceremonies::create_step_up(&app, principal, created.device_id, "passkey")
        .await
        .unwrap();
    assert!(grant.expires_at.ends_with('Z'), "{}", grant.expires_at);
    // Only the hash is stored.
    let stored: Vec<u8> = sqlx::query_scalar("SELECT token_hash FROM step_up_grants")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(stored, hash_token(&grant.token).to_vec());

    // Another device of the same user, another user, and a wrong token take nothing.
    for (token, who, device) in [
        (grant.token.as_str(), principal, other.device_id),
        (
            grant.token.as_str(),
            Principal {
                org_id: principal.org_id,
                user_id: new_uuid(),
            },
            created.device_id,
        ),
        ("not-the-grant", principal, created.device_id),
    ] {
        assert!(!ceremonies::take_step_up(&app, token, who, device)
            .await
            .unwrap());
    }
    assert!(
        ceremonies::take_step_up(&app, &grant.token, principal, created.device_id)
            .await
            .unwrap()
    );
    assert!(
        !ceremonies::take_step_up(&app, &grant.token, principal, created.device_id)
            .await
            .unwrap(),
        "a grant is used once"
    );

    // An expired grant is refused, and pruned a minute after it expired.
    let expired = ceremonies::create_step_up(&app, principal, created.device_id, "apple")
        .await
        .unwrap();
    sqlx::query("UPDATE step_up_grants SET expires_at = now() - interval '1 second'")
        .execute(&pool)
        .await
        .unwrap();
    assert!(
        !ceremonies::take_step_up(&app, &expired.token, principal, created.device_id)
            .await
            .unwrap()
    );
    assert_eq!(ceremonies::prune_expired(&app).await.unwrap(), 0);
    sqlx::query("UPDATE step_up_grants SET expires_at = now() - interval '61 seconds'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(ceremonies::prune_expired(&app).await.unwrap(), 2);
}

#[sqlx::test(migrations = false)]
async fn an_operator_code_is_taken_once_by_its_own_user(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"c"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let other = accounts::create_personal(&app, passkey(b"d"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let other = Principal {
        org_id: other.org_id,
        user_id: other.user_id,
    };
    let ten_minutes = Duration::from_secs(600);
    let code =
        devices::create_enrollment_code(&admin, principal.org_id, principal.user_id, ten_minutes)
            .await
            .unwrap();
    let (pairing, _) =
        devices::create_pairing_code(&app, principal.org_id, principal.user_id, created.device_id)
            .await
            .unwrap();
    let expired = devices::create_enrollment_code(
        &admin,
        principal.org_id,
        principal.user_id,
        Duration::ZERO,
    )
    .await
    .unwrap();
    let theirs = devices::create_enrollment_code(&admin, other.org_id, other.user_id, ten_minutes)
        .await
        .unwrap();

    // Another user, a pairing code, an expired code, another user's code, and an unknown one take
    // nothing.
    for (code, who) in [
        (code.as_str(), other),
        (pairing.as_str(), principal),
        (expired.as_str(), principal),
        (theirs.as_str(), principal),
        ("BCDFGHJK", principal),
    ] {
        assert!(!devices::take_operator_code(&app, code, who).await.unwrap());
    }
    let unused: i64 =
        sqlx::query_scalar("SELECT count(*) FROM enrollment_codes WHERE used_at IS NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(unused, 4, "every refusal left its code as it was");

    // The operator's code of the user's own is taken, in any case, once.
    assert!(
        devices::take_operator_code(&app, &code.to_lowercase(), principal)
            .await
            .unwrap()
    );
    assert!(
        !devices::take_operator_code(&app, &code, principal)
            .await
            .unwrap(),
        "a code is used once"
    );
    assert!(matches!(
        devices::redeem(&app, &code, "iPhone", "ios").await,
        Err(Error::InvalidCode)
    ));
    // The others stay redeemable.
    devices::redeem(&app, &theirs, "iPhone", "ios")
        .await
        .unwrap();
    devices::redeem(&app, &pairing, "iPhone", "ios")
        .await
        .unwrap();

    // The grant a code earns is recorded as one.
    let grant = ceremonies::create_step_up(&app, principal, created.device_id, "code")
        .await
        .unwrap();
    assert!(
        ceremonies::take_step_up(&app, &grant.token, principal, created.device_id)
            .await
            .unwrap()
    );
}

#[sqlx::test(migrations = false)]
async fn issue_session_reuses_own_device(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"c"), device("iPhone", Platform::Ios))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let session = accounts::issue_session(
        &app,
        principal,
        device("Brian's iPhone", Platform::Ios),
        Some(created.device_id),
    )
    .await
    .unwrap();
    assert_eq!(session.device_id, created.device_id);
    assert_ne!(session.token, created.token);
    // The new token works; the device's earlier one is replaced.
    assert_eq!(
        authed(&app, &session.token).await.device_id,
        created.device_id
    );
    assert!(devices::authenticate(&app, &created.token)
        .await
        .unwrap()
        .is_none());
    let info = devices::me(&app, created.org_id, created.device_id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(info.device_name, "Brian's iPhone");
    let listed = devices::list(&app, created.org_id, created.user_id)
        .await
        .unwrap();
    assert_eq!(listed.len(), 1);

    // Without a device id, a new device.
    let fresh = accounts::issue_session(&app, principal, device("iPad", Platform::Ios), None)
        .await
        .unwrap();
    assert_ne!(fresh.device_id, created.device_id);
    assert_eq!(authed(&app, &fresh.token).await.device_id, fresh.device_id);
}

#[sqlx::test(migrations = false)]
async fn issue_session_reuses_the_first_own_candidate(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let mine = accounts::create_personal(&app, passkey(b"m1"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let theirs = accounts::create_personal(&app, passkey(b"t1"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: mine.org_id,
        user_id: mine.user_id,
    };
    let second = accounts::issue_session(&app, principal, device("Mac 2", Platform::Macos), None)
        .await
        .unwrap();

    // The foreign and unknown candidates are skipped; the first of mine wins.
    let session = accounts::issue_session_reusing(
        &app,
        principal,
        device("Mac", Platform::Macos),
        &[
            theirs.device_id,
            Uuid::from_u128(5),
            second.device_id,
            mine.device_id,
        ],
    )
    .await
    .unwrap();
    assert_eq!(session.device_id, second.device_id);
    assert_eq!(
        authed(&app, &theirs.token).await.device_id,
        theirs.device_id
    );
    // The other of mine keeps its session.
    assert_eq!(authed(&app, &mine.token).await.device_id, mine.device_id);

    // No candidate of mine: a new device.
    let fresh = accounts::issue_session_reusing(
        &app,
        principal,
        device("Mac", Platform::Macos),
        &[theirs.device_id],
    )
    .await
    .unwrap();
    assert!(![mine.device_id, second.device_id, theirs.device_id].contains(&fresh.device_id));
}

#[sqlx::test(migrations = false)]
async fn issue_session_ignores_foreign_or_revoked_device(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let mine = accounts::create_personal(&app, passkey(b"m"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let theirs = accounts::create_personal(&app, passkey(b"t"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: mine.org_id,
        user_id: mine.user_id,
    };

    let foreign = accounts::issue_session(
        &app,
        principal,
        device("Mac", Platform::Macos),
        Some(theirs.device_id),
    )
    .await
    .unwrap();
    assert_ne!(foreign.device_id, theirs.device_id);
    assert_ne!(foreign.device_id, mine.device_id);
    // The other account's session is untouched.
    assert_eq!(
        authed(&app, &theirs.token).await.device_id,
        theirs.device_id
    );

    // A device id of mine, but for another platform, is not reused either: platform decides what
    // a device may write.
    let other_platform = accounts::issue_session(
        &app,
        principal,
        device("Phone", Platform::Ios),
        Some(mine.device_id),
    )
    .await
    .unwrap();
    assert_ne!(other_platform.device_id, mine.device_id);
    assert_eq!(authed(&app, &mine.token).await.device_id, mine.device_id);

    devices::revoke_self(&app, mine.org_id, mine.device_id)
        .await
        .unwrap();
    let revoked = accounts::issue_session(
        &app,
        principal,
        device("Mac", Platform::Macos),
        Some(mine.device_id),
    )
    .await
    .unwrap();
    assert_ne!(revoked.device_id, mine.device_id);
    assert_eq!(
        authed(&app, &revoked.token).await.device_id,
        revoked.device_id
    );
}

#[sqlx::test(migrations = false)]
async fn identities_are_listed_added_and_removed(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"one"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let added = accounts::add_identity(&app, principal, apple("001.z"))
        .await
        .unwrap();
    let listed = accounts::list_identities(&app, principal).await.unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0].kind, "passkey");
    assert_eq!(listed[0].name.as_deref(), Some("iCloud Keychain"));
    assert_eq!(listed[1].id, added);
    assert_eq!(listed[1].kind, "apple");
    assert_eq!(
        listed[1].name.as_deref(),
        Some("001.z@privaterelay.appleid.com")
    );
    assert!(
        listed[1].created_at.ends_with('Z'),
        "{}",
        listed[1].created_at
    );
    assert_eq!(listed[1].last_used_at, None);

    // Another user cannot remove (or see) these identities.
    let other = accounts::create_personal(&app, passkey(b"two"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let outsider = Principal {
        org_id: other.org_id,
        user_id: other.user_id,
    };
    assert_eq!(
        accounts::remove_identity(&app, outsider, added, None)
            .await
            .unwrap(),
        Removal::NotFound
    );
    assert_eq!(
        accounts::list_identities(&app, outsider)
            .await
            .unwrap()
            .len(),
        1
    );

    // The Apple ID holds a refresh token: it stays until the caller says it revoked that token.
    let held = SealedAppleToken {
        identity_id: added,
        sealed: b"enc-001.z".to_vec(),
    };
    assert_eq!(
        accounts::remove_identity(&app, principal, added, None)
            .await
            .unwrap(),
        Removal::Unrevoked(held.clone())
    );
    let stale = SealedAppleToken {
        identity_id: added,
        sealed: b"enc-older".to_vec(),
    };
    assert_eq!(
        accounts::remove_identity(&app, principal, added, Some(&stale))
            .await
            .unwrap(),
        Removal::Unrevoked(held.clone())
    );
    assert!(accounts::find_by_apple_sub(&app, "001.z")
        .await
        .unwrap()
        .is_some());
    assert_eq!(
        accounts::remove_identity(&app, principal, added, Some(&held))
            .await
            .unwrap(),
        Removal::Removed
    );
    assert_eq!(
        accounts::find_by_apple_sub(&app, "001.z").await.unwrap(),
        None
    );
}

#[sqlx::test(migrations = false)]
async fn remove_last_identity_refused(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"one"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let only = accounts::list_identities(&app, principal).await.unwrap()[0].id;
    assert!(matches!(
        accounts::remove_identity(&app, principal, only, None).await,
        Err(Error::LastIdentity)
    ));
    assert!(accounts::find_by_credential(&app, b"one")
        .await
        .unwrap()
        .is_some());

    // Two concurrent removals of a user's two identities: one succeeds, the other is refused.
    let second = accounts::add_identity(&app, principal, passkey(b"two"))
        .await
        .unwrap();
    let (one, two) = (app.clone(), app.clone());
    let a =
        tokio::spawn(async move { accounts::remove_identity(&one, principal, only, None).await });
    let b =
        tokio::spawn(async move { accounts::remove_identity(&two, principal, second, None).await });
    let results = [a.await.unwrap(), b.await.unwrap()];
    assert_eq!(
        results
            .iter()
            .filter(|r| matches!(r, Ok(Removal::Removed)))
            .count(),
        1,
        "{results:?}"
    );
    assert_eq!(
        results
            .iter()
            .filter(|r| matches!(r, Err(Error::LastIdentity)))
            .count(),
        1,
        "{results:?}"
    );
    assert_eq!(
        accounts::list_identities(&app, principal)
            .await
            .unwrap()
            .len(),
        1
    );
}

/// Every table with an `org_id` column. A new one fails `delete_user_removes_every_tenant_row`
/// until it is listed here and `delete_user` clears it.
const ORG_TABLES: [&str; 22] = [
    "auth_handoffs",
    "changes",
    "column_clocks",
    "connectionUsage",
    "connections",
    "device_tokens",
    "devices",
    "displayItems",
    "drafts",
    "enrollment_codes",
    "notifications_sent",
    "org_sync_horizons",
    "pairing_mints",
    "projectFolders",
    "projects",
    "push_tokens",
    "runtimeRequests",
    "step_up_grants",
    "threads",
    "turns",
    "user_identities",
    "users",
];

async fn org_counts(pool: &PgPool, org_id: Uuid) -> Vec<(String, i64)> {
    let mut counts = Vec::new();
    for table in ORG_TABLES {
        // The test pool's user is the cluster superuser, which bypasses row-level security.
        let n: i64 = sqlx::query_scalar(&format!(
            "SELECT count(*) FROM \"{table}\" WHERE org_id = $1"
        ))
        .bind(org_id)
        .fetch_one(pool)
        .await
        .unwrap();
        counts.push((table.to_string(), n));
    }
    counts
}

fn insert(seq: i64, table: &str, row: &str, value: serde_json::Value) -> Change {
    Change {
        device_seq: seq,
        wall: 1_761_900_000_000 + seq,
        table: table.into(),
        row_id: row.into(),
        op: ChangeOp::Insert,
        column: None,
        value: Some(value),
        hlc: None,
    }
}

/// Fills every org table for `who`'s org: the fixture (feed, mirror, clocks), a project and its
/// folder, a draft, a connection's usage, an enrollment code, a pairing code (and its mint), a handoff, and a horizon.
async fn fill_org(admin: &Db, app: &Db, pool: &PgPool, created: &accounts::Created) {
    let who = authed(app, &created.token).await;
    let mut batch = common::filtered_fixture();
    batch.extend([
        insert(
            13,
            "projects",
            "proj-1",
            json!({"id": "proj-1", "name": "b4app", "manual": false}),
        ),
        insert(
            14,
            "projectFolders",
            "folder-1",
            json!({"id": "folder-1", "projectId": "proj-1", "path": "/tmp/b4app"}),
        ),
        insert(
            15,
            "drafts",
            "thread-1",
            json!({"threadId": "thread-1", "text": "hello"}),
        ),
        insert(
            16,
            "connectionUsage",
            "conn-1",
            json!({"connectionId": "conn-1", "reading": null, "tokens": {"today": 5}}),
        ),
    ]);
    let outcome = changes::push(app, &who, &batch).await.unwrap();
    assert_eq!(outcome.accepted_through, 16);
    devices::create_enrollment_code(
        admin,
        created.org_id,
        created.user_id,
        Duration::from_secs(600),
    )
    .await
    .unwrap();
    devices::create_pairing_code(app, created.org_id, created.user_id, created.device_id)
        .await
        .unwrap();
    let principal = Principal::from(who);
    let ceremony = ceremonies::create(app, "apple", json!({})).await.unwrap();
    ceremonies::create_handoff(app, ceremony, principal, &hash_token("v"))
        .await
        .unwrap();
    ceremonies::create_step_up(app, principal, created.device_id, "passkey")
        .await
        .unwrap();
    sqlx::query("INSERT INTO org_sync_horizons (org_id, horizon) VALUES ($1, 0)")
        .bind(created.org_id)
        .execute(pool)
        .await
        .unwrap();
    // A push token (M8f); the fixture's pending request already wrote a `notifications_sent` row.
    sqlx::query(
        "INSERT INTO push_tokens (org_id, device_id, token, environment, bundle_id) \
         VALUES ($1, $2, 'token', 'sandbox', 'com.example.app')",
    )
    .bind(created.org_id)
    .bind(created.device_id)
    .execute(pool)
    .await
    .unwrap();
}

/// Gives `user_id` a relay link claim (`user_links`), as an instance serving its links writes.
async fn claim_links(pool: &PgPool, user_id: Uuid) {
    sqlx::query("INSERT INTO user_links (user_id, instance_id, claimed_at) VALUES ($1, $2, now())")
        .bind(user_id)
        .bind(new_uuid())
        .execute(pool)
        .await
        .unwrap();
}

async fn has_link_claim(pool: &PgPool, user_id: Uuid) -> bool {
    sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM user_links WHERE user_id = $1)")
        .bind(user_id)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[sqlx::test(migrations = false)]
async fn delete_user_removes_every_tenant_row(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;

    // The list above is every table with an `org_id` column.
    let tables: Vec<String> = sqlx::query_scalar(
        "SELECT table_name::text FROM information_schema.columns \
         WHERE table_schema = 'public' AND column_name = 'org_id' ORDER BY table_name COLLATE \"C\"",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let mut expected: Vec<String> = ORG_TABLES.iter().map(|t| t.to_string()).collect();
    expected.sort();
    assert_eq!(tables, expected);

    let doomed = accounts::create_personal(&app, apple("001.gone"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    accounts::add_identity(
        &app,
        Principal {
            org_id: doomed.org_id,
            user_id: doomed.user_id,
        },
        passkey(b"gone"),
    )
    .await
    .unwrap();
    accounts::add_identity(
        &app,
        Principal {
            org_id: doomed.org_id,
            user_id: doomed.user_id,
        },
        apple("001.gone2"),
    )
    .await
    .unwrap();
    fill_org(&admin, &app, &pool, &doomed).await;
    let kept = accounts::create_personal(&app, apple("001.kept"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    fill_org(&admin, &app, &pool, &kept).await;

    let before = org_counts(&pool, doomed.org_id).await;
    for (table, n) in &before {
        assert!(
            *n > 0,
            "the test leaves {table} empty, so it proves nothing"
        );
    }
    let kept_before = org_counts(&pool, kept.org_id).await;
    claim_links(&pool, doomed.user_id).await;
    claim_links(&pool, kept.user_id).await;

    let doomed_principal = Principal {
        org_id: doomed.org_id,
        user_id: doomed.user_id,
    };
    let to_revoke = accounts::apple_tokens_to_revoke(&app, doomed_principal)
        .await
        .unwrap();
    let mut tokens: Vec<Vec<u8>> = to_revoke.0.iter().map(|t| t.sealed.clone()).collect();
    tokens.sort();
    assert_eq!(
        tokens,
        vec![b"enc-001.gone".to_vec(), b"enc-001.gone2".to_vec()]
    );
    // Reading them deletes nothing.
    assert_eq!(org_counts(&pool, doomed.org_id).await, before);

    assert_eq!(
        accounts::delete_user(&app, doomed_principal, &to_revoke)
            .await
            .unwrap(),
        Deletion::Deleted
    );

    for (table, n) in org_counts(&pool, doomed.org_id).await {
        assert_eq!(n, 0, "{table} still has rows of the deleted org");
    }
    let orgs_left: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs WHERE id = $1")
        .bind(doomed.org_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(orgs_left, 0);
    assert_eq!(org_counts(&pool, kept.org_id).await, kept_before);
    // The deleted user's relay link claim went with it; the other user's stays.
    assert!(!has_link_claim(&pool, doomed.user_id).await);
    assert!(has_link_claim(&pool, kept.user_id).await);
    assert!(devices::authenticate(&app, &doomed.token)
        .await
        .unwrap()
        .is_none());
    assert_eq!(
        accounts::find_by_apple_sub(&app, "001.gone").await.unwrap(),
        None
    );
    // Deleted means the identity can sign up afresh.
    accounts::create_personal(&app, apple("001.gone"), device("Mac", Platform::Macos))
        .await
        .unwrap();
}

#[sqlx::test(migrations = false)]
async fn delete_user_refuses_a_shared_org(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let enrolled = common::enrolled(&admin, &app, "blove").await;
    let member = Principal::from(enrolled);
    accounts::add_identity(&app, member, apple("001.member"))
        .await
        .unwrap();
    // Refused before any token is handed out to revoke, and again at the delete.
    assert!(matches!(
        accounts::apple_tokens_to_revoke(&app, member).await,
        Err(Error::SharedOrg)
    ));
    assert!(matches!(
        accounts::delete_user(&app, member, &SealedAppleTokens::default()).await,
        Err(Error::SharedOrg)
    ));
    assert!(devices::me(&app, enrolled.org_id, enrolled.device_id)
        .await
        .unwrap()
        .is_some());
}

#[sqlx::test(migrations = false)]
async fn delete_user_refuses_while_a_token_is_unrevoked(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, apple("001.one"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let revoked = accounts::apple_tokens_to_revoke(&app, principal)
        .await
        .unwrap();
    // An Apple ID is linked between the revoke and the delete.
    let two = accounts::add_identity(&app, principal, apple("001.two"))
        .await
        .unwrap();

    assert_eq!(
        accounts::delete_user(&app, principal, &revoked)
            .await
            .unwrap(),
        Deletion::Unrevoked(SealedAppleTokens(vec![SealedAppleToken {
            identity_id: two,
            sealed: b"enc-001.two".to_vec(),
        }]))
    );
    assert_eq!(authed(&app, &created.token).await.user_id, created.user_id);

    let all = accounts::apple_tokens_to_revoke(&app, principal)
        .await
        .unwrap();
    assert_eq!(
        accounts::delete_user(&app, principal, &all).await.unwrap(),
        Deletion::Deleted
    );
    assert!(devices::authenticate(&app, &created.token)
        .await
        .unwrap()
        .is_none());
    // Deleting an account that is already gone is not an error.
    assert_eq!(
        accounts::delete_user(&app, principal, &all).await.unwrap(),
        Deletion::Deleted
    );
}

#[sqlx::test(migrations = false)]
async fn merge_moves_identities_and_deletes_empty_user(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    // The phone signed up on its own, then pairs with the Mac's account.
    let phone = accounts::create_personal(&app, passkey(b"phone"), device("iPhone", Platform::Ios))
        .await
        .unwrap();
    let phone_principal = Principal {
        org_id: phone.org_id,
        user_id: phone.user_id,
    };
    accounts::add_identity(&app, phone_principal, apple("001.phone"))
        .await
        .unwrap();
    let mac = common::enrolled(&admin, &app, "blove").await;
    let into = Principal::from(mac);
    claim_links(&pool, phone.user_id).await;
    claim_links(&pool, into.user_id).await;

    accounts::merge_phone_only(&app, phone_principal, into)
        .await
        .unwrap();
    assert!(!has_link_claim(&pool, phone.user_id).await);
    assert!(has_link_claim(&pool, into.user_id).await);

    assert_eq!(
        accounts::find_by_credential(&app, b"phone")
            .await
            .unwrap()
            .unwrap()
            .0,
        into
    );
    assert_eq!(
        accounts::find_by_apple_sub(&app, "001.phone")
            .await
            .unwrap(),
        Some(into)
    );
    assert_eq!(
        accounts::list_identities(&app, into).await.unwrap().len(),
        2
    );
    assert!(devices::authenticate(&app, &phone.token)
        .await
        .unwrap()
        .is_none());
    for (table, n) in org_counts(&pool, phone.org_id).await {
        assert_eq!(n, 0, "{table} still has rows of the merged-away org");
    }
    let orgs_left: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs WHERE id = $1")
        .bind(phone.org_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(orgs_left, 0);
    // The target is untouched otherwise.
    assert!(devices::me(&app, mac.org_id, mac.device_id)
        .await
        .unwrap()
        .is_some());
}

#[sqlx::test(migrations = false)]
async fn merge_refused_when_source_has_macos_device(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let source = accounts::create_personal(&app, passkey(b"src"), device("iPhone", Platform::Ios))
        .await
        .unwrap();
    let from = Principal {
        org_id: source.org_id,
        user_id: source.user_id,
    };
    // A Mac signed in once and was revoked since: still refused.
    let mac = accounts::issue_session(&app, from, device("Mac", Platform::Macos), None)
        .await
        .unwrap();
    devices::revoke_self(&app, source.org_id, mac.device_id)
        .await
        .unwrap();
    let into = Principal::from(common::enrolled(&admin, &app, "blove").await);

    assert!(matches!(
        accounts::merge_phone_only(&app, from, into).await,
        Err(Error::MergeRefused(Some(MergeRefusal::HasMac)))
    ));
    // Nothing moved.
    assert_eq!(
        accounts::find_by_credential(&app, b"src")
            .await
            .unwrap()
            .unwrap()
            .0,
        from
    );
    assert_eq!(authed(&app, &source.token).await.user_id, source.user_id);

    // Merging an account into itself is refused too.
    let phone_only =
        accounts::create_personal(&app, passkey(b"self"), device("iPhone", Platform::Ios))
            .await
            .unwrap();
    let me = Principal {
        org_id: phone_only.org_id,
        user_id: phone_only.user_id,
    };
    assert!(matches!(
        accounts::merge_phone_only(&app, me, me).await,
        Err(Error::MergeRefused(Some(MergeRefusal::SameAccount)))
    ));
}

#[sqlx::test(migrations = false)]
async fn merge_refusals_name_their_reason(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let blove = Principal::from(common::enrolled(&admin, &app, "blove").await);
    let phone = accounts::create_personal(&app, passkey(b"ph"), device("iPhone", Platform::Ios))
        .await
        .unwrap();
    let phone = Principal {
        org_id: phone.org_id,
        user_id: phone.user_id,
    };

    // Another user of the code's own org: already in it, checked before anything else.
    let colleague = Principal::from(
        common::enrolled_in_as(&admin, &app, "cacheplane", "colleague", "ios").await,
    );
    assert_eq!(colleague.org_id, blove.org_id);
    assert!(matches!(
        accounts::merge_phone_only(&app, colleague, blove).await,
        Err(Error::MergeRefused(Some(MergeRefusal::SameAccount)))
    ));
    // A member of a shared org (the operator-seeded user), merging into a personal account.
    assert!(matches!(
        accounts::merge_phone_only(&app, blove, phone).await,
        Err(Error::MergeRefused(Some(MergeRefusal::SharedOrg)))
    ));
    // A user whose row is gone: refused, with no reason to give.
    let gone = Principal {
        org_id: phone.org_id,
        user_id: b4hub_core::ids::new_uuid(),
    };
    assert!(matches!(
        accounts::merge_phone_only(&app, gone, blove).await,
        Err(Error::MergeRefused(None))
    ));
    // The wire names.
    assert_eq!(MergeRefusal::SameAccount.as_str(), "same_account");
    assert_eq!(MergeRefusal::HasMac.as_str(), "has_mac");
    assert_eq!(MergeRefusal::SharedOrg.as_str(), "shared_org");
}

#[sqlx::test(migrations = false)]
async fn ceremony_ids_are_random(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let id = ceremonies::create(&app, "passkey", json!({}))
        .await
        .unwrap();
    // Version 4: 122 random bits and no timestamp, since the id is all a finish presents.
    assert_eq!(id.get_version_num(), 4);
}

#[sqlx::test(migrations = false)]
async fn an_identity_belongs_to_one_account(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let first = accounts::create_personal(&app, passkey(b"cred"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    accounts::add_identity(
        &app,
        Principal {
            org_id: first.org_id,
            user_id: first.user_id,
        },
        apple("001.taken"),
    )
    .await
    .unwrap();

    for identity in [passkey(b"cred"), apple("001.taken")] {
        let again = accounts::create_personal(&app, identity, device("Mac", Platform::Macos)).await;
        assert!(matches!(again, Err(Error::IdentityTaken)), "{again:?}");
    }
    let other = accounts::create_personal(&app, passkey(b"other"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let other = Principal {
        org_id: other.org_id,
        user_id: other.user_id,
    };
    for identity in [passkey(b"cred"), apple("001.taken")] {
        let added = accounts::add_identity(&app, other, identity).await;
        assert!(matches!(added, Err(Error::IdentityTaken)), "{added:?}");
    }
    // A failed sign-up leaves nothing behind: the only orgs are the two that succeeded.
    let orgs: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(orgs, 2);
}

#[sqlx::test(migrations = false)]
async fn passkey_use_is_recorded(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    accounts::create_personal(&app, passkey(b"cred"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let (_, stored) = accounts::find_by_credential(&app, b"cred")
        .await
        .unwrap()
        .unwrap();

    // Without a changed passkey only the time moves.
    accounts::record_passkey_use(&app, stored.identity_id, None)
        .await
        .unwrap();
    let (_, unchanged) = accounts::find_by_credential(&app, b"cred")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(unchanged.passkey, stored.passkey);

    let updated = json!({"cred": {"cred_id": b"cred", "counter": 7}});
    accounts::record_passkey_use(&app, stored.identity_id, Some(&updated))
        .await
        .unwrap();
    let (_, after) = accounts::find_by_credential(&app, b"cred")
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after.passkey, updated);
    let used: Option<String> =
        sqlx::query_scalar("SELECT last_used_at::text FROM user_identities WHERE id = $1")
            .bind(stored.identity_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(used.is_some());
}

#[sqlx::test(migrations = false)]
async fn account_summary_reports_onboarding(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let created = accounts::create_personal(&app, passkey(b"cred"), device("Mac", Platform::Macos))
        .await
        .unwrap();
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    let summary = accounts::account_summary(&app, principal)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(summary.org_name, "My Org");
    assert!(summary.org_slug.starts_with("o-"));
    assert!(summary.username.starts_with("u-"));
    assert_eq!(summary.display_name, "");
    assert!(!summary.onboarded);

    let mut tx = app.tenant_tx(created.org_id).await.unwrap();
    accounts::set_profile(&mut tx, created.user_id, "Brian Love")
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let summary = accounts::account_summary(&app, principal)
        .await
        .unwrap()
        .unwrap();
    assert!(summary.onboarded);
    assert_eq!(summary.org_name, "Brian's Org");
    assert_eq!(summary.display_name, "Brian Love");

    // An operator-seeded user counts as onboarded; an unknown user is `None`.
    let seeded = orgs::seed(&admin, "acme", "Acme", "blove", "Brian Love", "b@x.test")
        .await
        .unwrap();
    let seeded = Principal {
        org_id: seeded.org_id,
        user_id: seeded.user_id,
    };
    assert!(
        accounts::account_summary(&app, seeded)
            .await
            .unwrap()
            .unwrap()
            .onboarded
    );
    let nobody = Principal {
        org_id: created.org_id,
        user_id: Uuid::from_u128(9),
    };
    assert_eq!(accounts::account_summary(&app, nobody).await.unwrap(), None);
}
