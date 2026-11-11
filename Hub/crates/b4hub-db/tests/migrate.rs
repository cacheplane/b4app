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
    assert_eq!(status.applied, (1..=19).collect::<Vec<i64>>());

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
    assert_eq!(migrations, 19);
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
        ("connectionUsage", true, true),
        ("connections", true, true),
        ("device_tokens", false, false),
        ("devices", true, true),
        ("displayItems", true, true),
        ("drafts", true, true),
        ("enrollment_codes", false, false),
        ("environmentFolders", true, true),
        ("environments", true, true),
        ("hub_instances", false, false),
        ("hub_settings", false, false),
        ("notifications_sent", true, true),
        ("org_sync_horizons", true, true),
        ("orgs", false, false),
        ("pairing_mints", true, true),
        ("push_tokens", true, true),
        ("runtimeRequests", true, true),
        ("step_up_grants", false, false),
        ("threads", true, true),
        ("turns", true, true),
        ("user_identities", false, false),
        ("user_links", false, false),
        ("users", true, true),
        ("viewSettings", true, true),
    ];
    assert_eq!(flags.len(), expected.len(), "{flags:?}");
    for (relname, secured, forced) in expected {
        assert!(
            flags.contains(&(relname.to_string(), secured, forced)),
            "{relname}: {flags:?}"
        );
    }
}

/// The hub's migrations are numbered by the branch that claims them, so a lower-numbered one can
/// land after a higher one is already applied (0006 landed before 0004 and 0005 did, and 0007
/// after it). sqlx 0.8 applies whatever the ledger lacks, in version order, and refuses nothing: the
/// finding `docs/compatibility.md` records.
#[sqlx::test(migrations = false)]
async fn sqlx_applies_a_lower_numbered_migration_added_later(pool: PgPool) {
    use sqlx::migrate::Migrator;

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let scratch = Scratch(std::env::temp_dir().join(format!(
        "b4hub-migrations-{}",
        b4hub_core::ids::new_uuid().simple()
    )));
    let dir = scratch.0.clone();
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("0001_a.sql"), "CREATE TABLE a (id int)").unwrap();
    std::fs::write(dir.join("0003_c.sql"), "CREATE TABLE c (id int)").unwrap();
    Migrator::new(dir.as_path())
        .await
        .unwrap()
        .run(&pool)
        .await
        .unwrap();

    std::fs::write(dir.join("0002_b.sql"), "CREATE TABLE b (id int)").unwrap();
    Migrator::new(dir.as_path())
        .await
        .unwrap()
        .run(&pool)
        .await
        .unwrap();
    let applied: Vec<i64> =
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success ORDER BY version")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(applied, vec![1, 2, 3]);
    let b: i64 = sqlx::query_scalar("SELECT count(*) FROM b")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(b, 0);

    // The other direction is refused: a binary without a migration the ledger holds (a deploy of
    // a branch that lacks 0002 against this database) fails with VersionMissing.
    std::fs::remove_file(dir.join("0002_b.sql")).unwrap();
    let error = Migrator::new(dir.as_path())
        .await
        .unwrap()
        .run(&pool)
        .await
        .unwrap_err();
    assert!(
        matches!(error, sqlx::migrate::MigrateError::VersionMissing(2)),
        "{error}"
    );
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

/// `0016_passkey_names.sql` (D-169) clears only the old placeholder name of passkeys: a passkey
/// named after its device keeps its name, and an Apple ID's name is never touched.
#[sqlx::test(migrations = false)]
async fn the_passkey_placeholder_name_is_cleared(pool: PgPool) {
    let admin_url = admin_url(&pool);
    b4hub_db::migrate::run(&admin_url, &app_url(&pool, "pw-test"))
        .await
        .unwrap();
    let seeded = orgs::seed(
        &Db { pool: pool.clone() },
        "acme",
        "Acme",
        "ann",
        "Ann",
        "ann@example.test",
    )
    .await
    .unwrap();
    for (kind, name, credential) in [
        ("passkey", "Agent Workspace account", Some(vec![1u8; 16])),
        ("passkey", "Ann's Mac", Some(vec![2u8; 16])),
        ("apple", "Agent Workspace account", None),
    ] {
        sqlx::query(
            "INSERT INTO user_identities \
             (id, org_id, user_id, kind, name, credential_id, passkey, user_handle, apple_sub) \
             VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, \
                     CASE WHEN $5 IS NULL THEN NULL ELSE '{}'::jsonb END, $5, $6)",
        )
        .bind(seeded.org_id)
        .bind(seeded.user_id)
        .bind(kind)
        .bind(name)
        .bind(credential)
        .bind((kind == "apple").then_some("001.ann"))
        .execute(&pool)
        .await
        .unwrap();
    }
    sqlx::raw_sql(include_str!("../migrations/0016_passkey_names.sql"))
        .execute(&pool)
        .await
        .unwrap();
    let names: Vec<(String, Option<String>)> =
        sqlx::query_as("SELECT kind, name FROM user_identities ORDER BY kind, name NULLS FIRST")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        names,
        [
            (
                "apple".to_string(),
                Some("Agent Workspace account".to_string())
            ),
            ("passkey".to_string(), None),
            ("passkey".to_string(), Some("Ann's Mac".to_string())),
        ]
    );
}

/// Applies `0001`..`0017` from the migrations directory to `pool`, as the ledger of a hub from
/// before the environments rename.
async fn migrate_to_0017(pool: &PgPool) {
    use sqlx::migrate::Migrator;

    struct Scratch(std::path::PathBuf);
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let scratch = Scratch(std::env::temp_dir().join(format!(
        "b4hub-migrations-{}",
        b4hub_core::ids::new_uuid().simple()
    )));
    std::fs::create_dir_all(&scratch.0).unwrap();
    let source = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    for entry in std::fs::read_dir(&source).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_str().unwrap().to_string();
        if name.as_str() < "0018" && name.ends_with(".sql") {
            std::fs::copy(&path, scratch.0.join(&name)).unwrap();
        }
    }
    Migrator::new(scratch.0.as_path())
        .await
        .unwrap()
        .run(pool)
        .await
        .unwrap();
}

async fn count(pool: &PgPool, sql: &str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

/// `0018_environments.sql` renames the project tables and columns and rewrites the names the feed
/// and the column clocks store as data, so an older write cannot win after the upgrade and an
/// unpushed change still applies under the new names.
#[sqlx::test(migrations = false)]
async fn environments_rename_carries_rows_changes_and_clocks(pool: PgPool) {
    migrate_to_0017(&pool).await;
    let seeded = orgs::seed(
        &Db { pool: pool.clone() },
        "acme",
        "Acme",
        "ann",
        "Ann",
        "ann@example.test",
    )
    .await
    .unwrap();
    let device: sqlx::types::Uuid = sqlx::query_scalar(
        "INSERT INTO devices (id, org_id, user_id, name, platform) \
         VALUES (gen_random_uuid(), $1, $2, 'Mac', 'macos') RETURNING id",
    )
    .bind(seeded.org_id)
    .bind(seeded.user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    for statement in [
        r#"INSERT INTO "projects" ("id", "name", org_id, user_id, device_id, owner_device_id)
           VALUES ('proj-1', 'b4app', $1, $2, $3, $3)"#,
        r#"INSERT INTO "projectFolders" ("id", "projectId", org_id, user_id, device_id, owner_device_id)
           VALUES ('folder-1', 'proj-1', $1, $2, $3, $3)"#,
        r#"INSERT INTO "threads" ("id", "projectId", org_id, user_id, device_id, owner_device_id)
           VALUES ('thread-1', 'proj-1', $1, $2, $3, $3)"#,
        r#"INSERT INTO "connections" ("id", "projectId", org_id, user_id, device_id, owner_device_id)
           VALUES ('conn-1', 'proj-1', $1, $2, $3, $3)"#,
        // The feed: an insert of the project, an insert of the thread whose value carries the
        // `projectId` key, an update of that column, and a rename of the project.
        r#"INSERT INTO changes (org_id, device_id, device_seq, user_id, wall, "table", row_id, op, "column", value, hlc)
           VALUES ($1, $3, 1, $2, 1, 'projects', 'proj-1', 'insert', NULL, '{"id": "proj-1", "name": "b4app"}', 'a-1'),
                  ($1, $3, 2, $2, 2, 'threads', 'thread-1', 'insert', NULL, '{"id": "thread-1", "projectId": "proj-1"}', 'a-2'),
                  ($1, $3, 3, $2, 3, 'threads', 'thread-1', 'update', 'projectId', '"proj-1"', 'a-3'),
                  ($1, $3, 4, $2, 4, 'projectFolders', 'folder-1', 'insert', NULL, '{"id": "folder-1", "projectId": "proj-1"}', 'a-4'),
                  ($1, $3, 5, $2, 5, 'projects', 'proj-1', 'update', 'name', '"b4app"', 'a-5')"#,
        r#"INSERT INTO column_clocks (org_id, "table", row_id, "column", hlc)
           VALUES ($1, 'projects', 'proj-1', 'name', 'a-5'),
                  ($1, 'threads', 'thread-1', 'projectId', 'a-3'),
                  ($1, 'threads', 'thread-1', 'readTurnId', 'a-9')"#,
    ] {
        sqlx::query(statement)
            .bind(seeded.org_id)
            .bind(seeded.user_id)
            .bind(device)
            .execute(&pool)
            .await
            .unwrap();
    }

    sqlx::raw_sql(include_str!("../migrations/0018_environments.sql"))
        .execute(&pool)
        .await
        .unwrap();

    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM "environments" WHERE name = 'b4app'"#
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM "environmentFolders" WHERE "environmentId" = 'proj-1'"#
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM "threads" WHERE "environmentId" = 'proj-1'"#
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM "connections" WHERE "environmentId" = 'proj-1'"#
        )
        .await,
        1
    );
    // No stored name survives as data, in the feed or in the clocks.
    assert_eq!(
        count(
            &pool,
            r#"SELECT (SELECT count(*) FROM changes
                       WHERE "table" IN ('projects', 'projectFolders') OR "column" = 'projectId'
                          OR value ? 'projectId')
                    + (SELECT count(*) FROM column_clocks
                       WHERE "table" IN ('projects', 'projectFolders') OR "column" = 'projectId')"#
        )
        .await,
        0
    );
    // The rewritten rows are the same five rows, now under the new names.
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM changes
               WHERE "table" IN ('environments', 'environmentFolders') OR "column" = 'environmentId'
                  OR value ? 'environmentId'"#
        )
        .await,
        5
    );
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM changes
               WHERE value_bytes = octet_length(value::text) AND value -> 'environmentId' = '"proj-1"'"#
        )
        .await,
        2
    );
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM column_clocks
               WHERE ("table", "column", hlc) IN
                     (('environments', 'name', 'a-5'), ('threads', 'environmentId', 'a-3'),
                      ('threads', 'readTurnId', 'a-9'))"#
        )
        .await,
        3
    );
    let tables: Vec<String> = sqlx::query_scalar(
        "SELECT tablename::text FROM pg_tables \
         WHERE schemaname = 'public' AND tablename IN ('projects', 'projectFolders')",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert!(tables.is_empty(), "{tables:?}");
    let indexes: Vec<String> = sqlx::query_scalar(
        "SELECT indexname::text FROM pg_indexes WHERE schemaname = 'public' \
         AND indexname IN ('environments_by_user', 'environmentFolders_by_user') ORDER BY 1",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(
        indexes,
        ["environmentFolders_by_user", "environments_by_user"]
    );
    // Row-level security followed the renamed tables (also asserted, for a fresh database, by
    // `tenant_tables_force_row_level_security`).
    let secured: Vec<(String, bool, bool)> = sqlx::query_as(
        "SELECT relname::text, relrowsecurity, relforcerowsecurity FROM pg_class \
         WHERE relname IN ('environments', 'environmentFolders', 'changes', 'column_clocks') ORDER BY 1",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(secured.len(), 4);
    assert!(
        secured.iter().all(|(_, on, forced)| *on && *forced),
        "{secured:?}"
    );
}
