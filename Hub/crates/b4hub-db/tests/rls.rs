//! The row-level-security proof: what `b4hub_app` can see and write with and without a tenant
//! context. Run with `source <(./scripts/test-db.sh)` first.

mod common;

use b4hub_core::change::{Change, ChangeOp};
use b4hub_db::accounts::{self, DeviceSpec, Identity, Principal};
use b4hub_db::changes;
use b4hub_db::devices::{self, Platform};
use b4hub_db::orgs;
use serde_json::json;
use sqlx::types::Uuid;
use sqlx::PgPool;

/// The SQLSTATE of a database error, if `error` is one.
fn sqlstate(error: &sqlx::Error) -> Option<String> {
    error
        .as_database_error()
        .and_then(|e| e.code())
        .map(|c| c.into_owned())
}

#[sqlx::test(migrations = false)]
async fn app_role_sees_only_its_org(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let a = orgs::seed(
        &admin,
        "cacheplane",
        "cacheplane",
        "blove",
        "Brian Love",
        "b@example.test",
    )
    .await
    .unwrap();
    let b = orgs::seed(&admin, "other", "Other", "eve", "Eve", "e@example.test")
        .await
        .unwrap();

    let mut tx = app.tenant_tx(a.org_id).await.unwrap();
    let names: Vec<String> = sqlx::query_scalar("SELECT username FROM users")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    assert_eq!(names, vec!["blove"]);
    // A hand-written cross-tenant query under org A's context still yields nothing of B's.
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM users WHERE org_id = $1")
        .bind(b.org_id)
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    assert_eq!(n, 0);
    tx.rollback().await.unwrap();

    // The context is transaction-local: the next transaction on the pool starts without one.
    let leaked: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(leaked, 0);
}

#[sqlx::test(migrations = false)]
async fn no_context_sees_nothing_and_cannot_insert(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let a = orgs::seed(
        &admin,
        "cacheplane",
        "cacheplane",
        "blove",
        "Brian Love",
        "b@example.test",
    )
    .await
    .unwrap();
    let b = orgs::seed(&admin, "other", "Other", "eve", "Eve", "e@example.test")
        .await
        .unwrap();

    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(n, 0);

    const INSERT: &str = "INSERT INTO users (id, org_id, username, display_name, email) \
                          VALUES ($1, $2, 'mallory', 'Mallory', 'm@example.test')";
    let error = sqlx::query(INSERT)
        .bind(b4hub_core::ids::new_uuid())
        .bind(b.org_id)
        .execute(&app.pool)
        .await
        .unwrap_err();
    // new row violates row-level security policy
    assert_eq!(sqlstate(&error).as_deref(), Some("42501"), "{error}");

    // Under org A's context, writing a row for org B is refused too.
    let mut tx = app.tenant_tx(a.org_id).await.unwrap();
    let error = sqlx::query(INSERT)
        .bind(b4hub_core::ids::new_uuid())
        .bind(b.org_id)
        .execute(&mut *tx)
        .await
        .unwrap_err();
    assert_eq!(sqlstate(&error).as_deref(), Some("42501"), "{error}");
}

#[sqlx::test(migrations = false)]
async fn owner_role_with_row_security_off_errors_instead_of_filtering(pool: PgPool) {
    // The export rule: an export reads with `SET row_security = off`, so a role that does not
    // bypass RLS gets an error rather than silently filtered (incomplete) rows. The test pool's
    // user is the cluster superuser, which bypasses RLS altogether, so the check runs as the
    // unprivileged application role.
    let (admin, app) = common::migrated(&pool).await;
    orgs::seed(
        &admin,
        "cacheplane",
        "cacheplane",
        "blove",
        "Brian Love",
        "b@example.test",
    )
    .await
    .unwrap();

    let mut conn = app.pool.acquire().await.unwrap();
    sqlx::query("SET row_security = off")
        .execute(&mut *conn)
        .await
        .unwrap();
    let error = sqlx::query_scalar::<_, i64>("SELECT count(*) FROM users")
        .fetch_one(&mut *conn)
        .await
        .unwrap_err();
    // query would be affected by row-level security policy
    assert_eq!(sqlstate(&error).as_deref(), Some("42501"), "{error}");
}

fn phone(credential: &[u8]) -> (Identity, DeviceSpec) {
    (
        Identity::Passkey {
            credential_id: credential.to_vec(),
            passkey_json: json!({}),
            user_handle: credential.to_vec(),
            name: "passkey".into(),
        },
        DeviceSpec {
            name: "iPhone".into(),
            platform: Platform::Ios,
        },
    )
}

#[sqlx::test(migrations = false)]
async fn two_personal_orgs_are_isolated(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let a = {
        let (identity, spec) = phone(b"a");
        accounts::create_personal(&app, identity, spec)
    }
    .await
    .unwrap();
    let b = {
        let (identity, spec) = phone(b"b");
        accounts::create_personal(&app, identity, spec)
    }
    .await
    .unwrap();

    let mut tx = app.tenant_tx(a.org_id).await.unwrap();
    let users: Vec<Uuid> = sqlx::query_scalar("SELECT id FROM users")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    let device_ids: Vec<Uuid> = sqlx::query_scalar("SELECT id FROM devices")
        .fetch_all(&mut *tx)
        .await
        .unwrap();
    tx.rollback().await.unwrap();
    assert_eq!(users, vec![a.user_id]);
    assert_eq!(device_ids, vec![a.device_id]);
    assert!(devices::me(&app, a.org_id, b.device_id)
        .await
        .unwrap()
        .is_none());

    // Without a tenant the application role sees neither org's users.
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(n, 0);

    // A session issued for A cannot reuse B's device.
    let session = accounts::issue_session(
        &app,
        Principal {
            org_id: a.org_id,
            user_id: a.user_id,
        },
        phone(b"x").1,
        Some(b.device_id),
    )
    .await
    .unwrap();
    assert_ne!(session.device_id, b.device_id);
}

/// Seeds, as the owner, a thread, a runtime request on it, and an environment, all owned by `owner`
/// and belonging to `who`.
async fn seed_owned_rows(
    admin: &b4hub_db::Db,
    who: &b4hub_db::devices::AuthedDevice,
    owner: sqlx::types::Uuid,
) {
    for statement in [
        "INSERT INTO \"threads\" (\"id\", org_id, user_id, device_id, owner_device_id) \
         VALUES ('thread-1', $1, $2, $3, $3)",
        "INSERT INTO \"runtimeRequests\" (\"id\", \"threadId\", \"state\", org_id, user_id, \
         device_id, owner_device_id) VALUES ('request-1', 'thread-1', 'pending', $1, $2, $3, $3)",
        "INSERT INTO \"environments\" (\"id\", org_id, user_id, device_id, owner_device_id) \
         VALUES ('project-1', $1, $2, $3, $3)",
    ] {
        sqlx::query(statement)
            .bind(who.org_id)
            .bind(who.user_id)
            .bind(owner)
            .execute(&admin.pool)
            .await
            .unwrap();
    }
}

#[sqlx::test(migrations = false)]
async fn relay_lookups_respect_rls(pool: PgPool) {
    use b4hub_db::relay::{owner_device, owner_of_environment, owner_of_request, owner_of_thread};

    let (admin, app) = common::migrated(&pool).await;
    let mac = common::enrolled_in(&admin, &app, "cacheplane", "blove").await;
    let stranger = common::enrolled_in(&admin, &app, "elsewhere", "eve").await;
    seed_owned_rows(&admin, &mac, mac.device_id).await;

    // As `b4hub_app`, in the right tenant, each lookup finds the Mac.
    let found = owner_of_thread(&app, mac.org_id, mac.user_id, "thread-1")
        .await
        .unwrap()
        .expect("the user's own thread");
    assert_eq!(
        (found.device_id, found.platform.as_str(), found.revoked),
        (mac.device_id, "macos", false)
    );
    let request = owner_of_request(&app, mac.org_id, mac.user_id, "request-1")
        .await
        .unwrap()
        .expect("the user's own request");
    assert_eq!(request.owner.device_id, mac.device_id);
    assert_eq!(request.state.as_deref(), Some("pending"));
    assert!(
        owner_of_environment(&app, mac.org_id, mac.user_id, "project-1")
            .await
            .unwrap()
            .is_some()
    );
    assert!(owner_device(&app, mac.org_id, mac.user_id, mac.device_id)
        .await
        .unwrap()
        .is_some());

    // With another org's id, nothing: not the rows, and not the device.
    let other = stranger.org_id;
    assert!(owner_of_thread(&app, other, mac.user_id, "thread-1")
        .await
        .unwrap()
        .is_none());
    assert!(owner_of_request(&app, other, mac.user_id, "request-1")
        .await
        .unwrap()
        .is_none());
    assert!(owner_of_environment(&app, other, mac.user_id, "project-1")
        .await
        .unwrap()
        .is_none());
    assert!(owner_device(&app, other, mac.user_id, mac.device_id)
        .await
        .unwrap()
        .is_none());
    // Another user's id in the right org: nothing either.
    let colleague = common::enrolled(&admin, &app, "colleague").await;
    assert!(
        owner_of_thread(&app, mac.org_id, colleague.user_id, "thread-1")
            .await
            .unwrap()
            .is_none()
    );

    // A row of this org whose owner is a device of another org (the foreign key does not stop it):
    // the lookup keeps to the org and row-level security hides that device anyway, so the answer
    // is nothing, never another tenant's device.
    sqlx::query("UPDATE \"threads\" SET owner_device_id = $1 WHERE \"id\" = 'thread-1'")
        .bind(stranger.device_id)
        .execute(&admin.pool)
        .await
        .unwrap();
    assert!(owner_of_thread(&app, mac.org_id, mac.user_id, "thread-1")
        .await
        .unwrap()
        .is_none());
    assert!(owner_of_request(&app, mac.org_id, mac.user_id, "request-1")
        .await
        .unwrap()
        .is_none());
}

#[sqlx::test(migrations = false)]
async fn push_tables_isolate_by_org(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let phone = common::enrolled_as(&admin, &app, "blove", "ios").await;
    let stranger = common::enrolled_in(&admin, &app, "elsewhere", "eve").await;
    b4hub_db::push::save_token(&app, &phone, "token", "sandbox", "com.example.app")
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO notifications_sent (org_id, kind, row_id, user_id, thread_id, reason) \
         VALUES ($1, 'request', 'request-1', $2, 'thread-1', 'approval')",
    )
    .bind(phone.org_id)
    .bind(phone.user_id)
    .execute(&admin.pool)
    .await
    .unwrap();

    for (who, expected) in [(&phone, 1_i64), (&stranger, 0)] {
        let mut tx = app.tenant_tx(who.org_id).await.unwrap();
        for table in ["push_tokens", "notifications_sent"] {
            let n: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
                .fetch_one(&mut *tx)
                .await
                .unwrap();
            assert_eq!(n, expected, "{table}");
        }
        tx.rollback().await.unwrap();
    }
    // Without a tenant context, nothing, and no insert for another org.
    for table in ["push_tokens", "notifications_sent"] {
        let n: i64 = sqlx::query_scalar(&format!("SELECT count(*) FROM {table}"))
            .fetch_one(&app.pool)
            .await
            .unwrap();
        assert_eq!(n, 0, "{table}");
    }
}

/// The settings row of `who`'s org, read under its tenant context.
async fn view_row(
    app: &b4hub_db::Db,
    who: &b4hub_db::devices::AuthedDevice,
) -> Option<serde_json::Value> {
    let mut tx = app.tenant_tx(who.org_id).await.unwrap();
    let found =
        sqlx::query_scalar("SELECT to_jsonb(v) FROM \"viewSettings\" v WHERE \"id\" LIKE 'view:%'")
            .fetch_optional(&mut *tx)
            .await
            .unwrap();
    tx.rollback().await.unwrap();
    found
}

#[sqlx::test(migrations = false)]
async fn another_org_never_sees_view_settings(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let mine = common::enrolled(&admin, &app, "blove").await;
    let theirs = common::enrolled_in(&admin, &app, "elsewhere", "eve").await;
    let view = |arrangement: &str| Change {
        device_seq: 1,
        wall: 1_761_900_000_000,
        table: "viewSettings".into(),
        row_id: "view".into(),
        op: ChangeOp::Insert,
        column: None,
        value: Some(json!({"id": "view", "arrangement": arrangement, "quietThreads": "small"})),
        hlc: None,
    };
    changes::push(&app, &mine, &[view("needsYouFirst")])
        .await
        .unwrap();

    assert!(view_row(&app, &theirs).await.is_none());
    // Without a tenant context, nothing.
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM \"viewSettings\"")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(n, 0);
    // Nor through the feed or a snapshot.
    let page = changes::pull(&app, &theirs, 0, 1000).await.unwrap();
    assert!(page.changes.is_empty());
    let snapshot = b4hub_db::snapshot::take(&app, &theirs).await.unwrap();
    assert!(snapshot.changes.is_empty() && snapshot.clocks.is_empty());

    // The other org's own `view` row is its own: each org keeps its value.
    changes::push(&app, &theirs, &[view("byEnvironment")])
        .await
        .unwrap();
    assert_eq!(
        view_row(&app, &mine).await.unwrap()["arrangement"],
        "needsYouFirst"
    );
    assert_eq!(
        view_row(&app, &theirs).await.unwrap()["arrangement"],
        "byEnvironment"
    );
}
