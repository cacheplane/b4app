//! The row-level-security proof: what `b4hub_app` can see and write with and without a tenant
//! context. Run with `source <(./scripts/test-db.sh)` first.

mod common;

use b4hub_db::orgs;
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

/// Seeds, as the owner, a thread, a runtime request on it, and a project, all owned by `owner`
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
        "INSERT INTO \"projects\" (\"id\", org_id, user_id, device_id, owner_device_id) \
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
    use b4hub_db::relay::{owner_device, owner_of_project, owner_of_request, owner_of_thread};

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
    assert!(owner_of_project(&app, mac.org_id, mac.user_id, "project-1")
        .await
        .unwrap()
        .is_some());
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
    assert!(owner_of_project(&app, other, mac.user_id, "project-1")
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
