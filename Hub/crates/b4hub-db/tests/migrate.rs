//! Migration, role provisioning, and seed behaviour against a real PostgreSQL. Run with
//! `source <(./scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use b4hub_db::{orgs, Db};
use common::{admin_url, app_url, url_as};
use sqlx::{PgPool, Row};

#[sqlx::test(migrations = false)]
async fn migrate_is_idempotent_and_provisions_the_app_role(pool: PgPool) {
    let admin_url = admin_url(&pool);
    let app_url = app_url(&pool, "pw-test");
    b4hub_db::migrate::run(&admin_url, &app_url).await.unwrap();
    b4hub_db::migrate::run(&admin_url, &app_url).await.unwrap();

    let status = b4hub_db::migrate::status(&Db { pool: pool.clone() })
        .await
        .unwrap();
    assert_eq!(status.pending, 0);
    assert_eq!(status.applied, vec![1, 2, 3, 5]);

    let app = Db::connect(&app_url).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(n, 0);
    let migrations: i64 = sqlx::query_scalar("SELECT count(*) FROM _sqlx_migrations")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(migrations, 4);
    app.pool.close().await;

    let row =
        sqlx::query("SELECT rolbypassrls, rolsuper FROM pg_roles WHERE rolname = 'b4hub_app'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(!row.get::<bool, _>("rolbypassrls"));
    assert!(!row.get::<bool, _>("rolsuper"));

    // The server holds a SCRAM verifier, never the plaintext password.
    let stored: String =
        sqlx::query_scalar("SELECT rolpassword FROM pg_authid WHERE rolname = 'b4hub_app'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(stored.starts_with("SCRAM-SHA-256$4096:"), "{stored}");
    assert!(!stored.contains("pw-test"));
}

#[sqlx::test(migrations = false)]
async fn migrate_reruns_as_a_non_superuser_owner(pool: PgPool) {
    // A typical deployment's owner is `LOGIN CREATEROLE` without SUPERUSER. Roles are
    // cluster-global and other tests provision `b4hub_app` concurrently, so both roles are
    // created idempotently and the owner is given ADMIN on `b4hub_app` (as it would be as its
    // creator).
    for statement in [
        "DO $$ BEGIN CREATE ROLE b4hub_test_owner LOGIN CREATEROLE PASSWORD 'owner-pw'; \
         EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$",
        "DO $$ BEGIN CREATE ROLE b4hub_app LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD 'pw-test'; \
         EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$",
        "GRANT b4hub_app TO b4hub_test_owner WITH ADMIN OPTION",
        "GRANT ALL ON SCHEMA public TO b4hub_test_owner",
    ] {
        sqlx::query(statement).execute(&pool).await.unwrap();
    }
    let owner_url = url_as(&pool, "b4hub_test_owner", "owner-pw");
    let app_url = app_url(&pool, "pw-test");

    b4hub_db::migrate::run(&owner_url, &app_url).await.unwrap();
    // The second run takes the ALTER ROLE path, which a non-superuser may only use for LOGIN
    // and PASSWORD.
    b4hub_db::migrate::run(&owner_url, &app_url).await.unwrap();

    let owner: String =
        sqlx::query_scalar("SELECT tableowner FROM pg_tables WHERE tablename = 'orgs'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(owner, "b4hub_test_owner");
    let app = Db::connect(&app_url).await.unwrap();
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(n, 0);
    app.pool.close().await;
}

#[sqlx::test(migrations = false)]
async fn migrate_rejects_an_app_url_that_is_not_b4hub_app_with_a_password(pool: PgPool) {
    let admin = admin_url(&pool);
    for url in [
        url_as(&pool, "postgres", "pw-test"),
        admin.clone(), // no password
    ] {
        let error = b4hub_db::migrate::run(&admin, &url).await.unwrap_err();
        assert!(matches!(error, b4hub_db::Error::InvalidUrl(_)), "{error}");
        assert!(!error.to_string().contains("pw-test"));
    }
}

#[sqlx::test(migrations = false)]
async fn tenant_tables_force_row_level_security(pool: PgPool) {
    b4hub_db::migrate::run(&admin_url(&pool), &app_url(&pool, "pw-test"))
        .await
        .unwrap();
    let rows = sqlx::query(
        "SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class \
         WHERE relnamespace = 'public'::regnamespace AND relkind = 'r' AND relname <> '_sqlx_migrations' \
         ORDER BY relname",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    let flags: Vec<(String, bool, bool)> = rows
        .iter()
        .map(|r| {
            (
                r.get("relname"),
                r.get("relrowsecurity"),
                r.get("relforcerowsecurity"),
            )
        })
        .collect();
    let expected = [
        ("auth_ceremonies", false, false),
        ("auth_handoffs", false, false),
        ("changes", true, true),
        ("column_clocks", true, true),
        ("connections", true, true),
        ("device_tokens", false, false),
        ("devices", true, true),
        ("displayItems", true, true),
        ("drafts", true, true),
        ("enrollment_codes", false, false),
        ("org_sync_horizons", true, true),
        ("orgs", false, false),
        ("projectFolders", true, true),
        ("projects", true, true),
        ("runtimeRequests", true, true),
        ("threads", true, true),
        ("turns", true, true),
        ("user_identities", false, false),
        ("users", true, true),
    ];
    assert_eq!(flags.len(), expected.len(), "{flags:?}");
    for (relname, secured, forced) in expected {
        assert!(
            flags.contains(&(relname.to_string(), secured, forced)),
            "{relname}: {flags:?}"
        );
    }
}

#[sqlx::test(migrations = false)]
async fn seed_creates_once_and_is_idempotent(pool: PgPool) {
    b4hub_db::migrate::run(&admin_url(&pool), &app_url(&pool, "pw-test"))
        .await
        .unwrap();
    let db = Db { pool: pool.clone() };
    let first = orgs::seed(
        &db,
        "acme",
        "Acme Inc",
        "brian",
        "Brian Love",
        "brian@example.com",
    )
    .await
    .unwrap();
    assert!(first.created);
    let second = orgs::seed(
        &db,
        "acme",
        "Acme Inc",
        "brian",
        "Brian Love",
        "brian@example.com",
    )
    .await
    .unwrap();
    assert!(!second.created);
    assert_eq!(first.org_id, second.org_id);
    assert_eq!(first.user_id, second.user_id);
    assert_eq!(first.org_id.get_version_num(), 7);

    let orgs_n: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs")
        .fetch_one(&pool)
        .await
        .unwrap();
    let users_n: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!((orgs_n, users_n), (1, 1));

    // A second user in the same org reuses the org and is itself created.
    let other = orgs::seed(&db, "acme", "Acme Inc", "sam", "Sam", "sam@example.com")
        .await
        .unwrap();
    assert!(other.created);
    assert_eq!(other.org_id, first.org_id);
    assert_ne!(other.user_id, first.user_id);
}

#[sqlx::test(migrations = false)]
async fn seed_works_under_forced_row_level_security(pool: PgPool) {
    // The owner is subject to forced RLS unless it is a superuser, so seed must set the tenant
    // context itself; the unprivileged application role proves it.
    let app_url = app_url(&pool, "pw-test");
    b4hub_db::migrate::run(&admin_url(&pool), &app_url)
        .await
        .unwrap();
    let app = Db::connect(&app_url).await.unwrap();
    let outcome = orgs::seed(
        &app,
        "acme",
        "Acme Inc",
        "brian",
        "Brian Love",
        "brian@example.com",
    )
    .await
    .unwrap();
    assert!(outcome.created);
    let again = orgs::seed(
        &app,
        "acme",
        "Acme Inc",
        "brian",
        "Brian Love",
        "brian@example.com",
    )
    .await
    .unwrap();
    assert!(!again.created);
    assert_eq!(outcome.user_id, again.user_id);

    // Without a tenant context the application role sees no users; with the org's it sees one.
    let without: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&app.pool)
        .await
        .unwrap();
    assert_eq!(without, 0);
    let mut tx = app.pool.begin().await.unwrap();
    sqlx::query("SELECT set_config('b4hub.org_id', $1, true)")
        .bind(outcome.org_id.to_string())
        .execute(&mut *tx)
        .await
        .unwrap();
    let with: i64 = sqlx::query_scalar("SELECT count(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .unwrap();
    assert_eq!(with, 1);
    tx.rollback().await.unwrap();
    app.pool.close().await;
}

/// A role that is a member of a privileged role with `INHERIT` has that role's privileges, so the
/// service refuses it just as it refuses the privileged role itself.
#[sqlx::test(migrations = false)]
async fn serve_refuses_a_role_that_inherits_superuser(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    assert!(
        !b4hub_db::migrate::connected_role_is_privileged(&app)
            .await
            .unwrap(),
        "b4hub_app itself is unprivileged"
    );

    let suffix = b4hub_core::ids::new_uuid().simple().to_string();
    let (weak, quiet, chain) = (
        format!("weak_{suffix}"),
        format!("quiet_{suffix}"),
        format!("chain_{suffix}"),
    );
    // A password, because CI's PostgreSQL authenticates TCP connections with one.
    for statement in [
        format!("CREATE ROLE {weak} LOGIN PASSWORD 'x'"),
        format!("GRANT postgres TO {weak}"),
        // Membership without inheritance gives no privileges until `SET ROLE`.
        format!("CREATE ROLE {quiet} LOGIN NOINHERIT PASSWORD 'x'"),
        format!("GRANT postgres TO {quiet}"),
        // Two hops: chain -> weak -> postgres.
        format!("CREATE ROLE {chain} LOGIN PASSWORD 'x'"),
        format!("GRANT {weak} TO {chain}"),
    ] {
        sqlx::query(&statement).execute(&pool).await.unwrap();
    }

    let inherits = Db::connect(&url_as(&pool, &weak, "x")).await.unwrap();
    assert!(b4hub_db::migrate::connected_role_is_privileged(&inherits)
        .await
        .unwrap());
    let two_hops = Db::connect(&url_as(&pool, &chain, "x")).await.unwrap();
    assert!(b4hub_db::migrate::connected_role_is_privileged(&two_hops)
        .await
        .unwrap());
    let noinherit = Db::connect(&url_as(&pool, &quiet, "x")).await.unwrap();
    assert!(!b4hub_db::migrate::connected_role_is_privileged(&noinherit)
        .await
        .unwrap());

    // The owner of the tables stays privileged as before.
    let owner = Db::connect(&admin_url(&pool)).await.unwrap();
    assert!(b4hub_db::migrate::connected_role_is_privileged(&owner)
        .await
        .unwrap());

    for db in [inherits, two_hops, noinherit, owner, app] {
        db.pool.close().await;
    }
    for role in [chain, weak, quiet] {
        sqlx::query(&format!("DROP ROLE {role}"))
            .execute(&pool)
            .await
            .unwrap();
    }
}
