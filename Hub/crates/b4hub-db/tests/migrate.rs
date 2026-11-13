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
    assert_eq!(status.applied, (1..=21).collect::<Vec<i64>>());

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
    assert_eq!(migrations, 21);
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

// The event-trigger fault is local to this disposable database. The real concurrent-runner
// regression lives in environment_history_controls; these controls make the grant retry and
// rollback boundaries deterministic without sleeping or weakening that public-runner test.
#[sqlx::test(migrations = false)]
async fn migration_grants_retry_catalog_collision_and_keep_restricted_tables_read_only(
    pool: PgPool,
) {
    let admin = admin_url(&pool);
    let app = app_url(&pool, common::APP_PASSWORD);
    b4hub_db::migrate::run(&admin, &app).await.unwrap();
    sqlx::raw_sql(
        "CREATE SEQUENCE grant_attempt_probe; \
         CREATE FUNCTION fail_first_default_grant() RETURNS event_trigger LANGUAGE plpgsql AS $$ \
         BEGIN IF nextval('grant_attempt_probe')=1 THEN \
           RAISE EXCEPTION USING ERRCODE='XX000', MESSAGE='tuple concurrently updated'; \
         END IF; END $$; \
         CREATE EVENT TRIGGER retry_default_grant ON ddl_command_start \
           WHEN TAG IN ('ALTER DEFAULT PRIVILEGES') EXECUTE FUNCTION fail_first_default_grant();",
    )
    .execute(&pool)
    .await
    .unwrap();
    b4hub_db::migrate::run(&admin, &app).await.unwrap();
    let attempts: i64 = sqlx::query_scalar("SELECT last_value FROM grant_attempt_probe")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(attempts, 3); // failed transaction's first DDL, then both DDLs after retry
    let permissions: (bool, bool, bool, bool, bool) = sqlx::query_as(
        "SELECT has_table_privilege('b4hub_app','orgs','INSERT'), \
         has_table_privilege('b4hub_app','_sqlx_migrations','SELECT'), \
         has_table_privilege('b4hub_app','_sqlx_migrations','INSERT'), \
         has_table_privilege('b4hub_app','hub_settings','SELECT'), \
         has_table_privilege('b4hub_app','hub_settings','UPDATE')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(permissions, (true, true, false, true, false));
    pool.close().await;
}

#[sqlx::test(migrations = false)]
async fn migration_grants_rollback_as_one_unit_on_nonretryable_failure(pool: PgPool) {
    let admin = admin_url(&pool);
    let app = app_url(&pool, common::APP_PASSWORD);
    b4hub_db::migrate::run(&admin, &app).await.unwrap();
    sqlx::raw_sql(
        "REVOKE ALL ON ALL TABLES IN SCHEMA public FROM b4hub_app; \
         CREATE SEQUENCE grant_refusal_probe; \
         CREATE FUNCTION refuse_default_grant() RETURNS event_trigger LANGUAGE plpgsql AS $$ \
         BEGIN PERFORM nextval('grant_refusal_probe'); \
           RAISE EXCEPTION 'deliberate default-grant refusal'; END $$; \
         CREATE EVENT TRIGGER refuse_default_grant ON ddl_command_start \
           WHEN TAG IN ('ALTER DEFAULT PRIVILEGES') EXECUTE FUNCTION refuse_default_grant();",
    )
    .execute(&pool)
    .await
    .unwrap();
    let outcome = b4hub_db::migrate::run(&admin, &app).await;
    let probe: (i64, bool) =
        sqlx::query_as("SELECT last_value, is_called FROM grant_refusal_probe")
            .fetch_one(&pool)
            .await
            .unwrap();
    let permissions: (bool, bool, bool) = sqlx::query_as(
        "SELECT has_table_privilege('b4hub_app','orgs','INSERT'), \
         has_table_privilege('b4hub_app','_sqlx_migrations','SELECT'), \
         has_table_privilege('b4hub_app','hub_settings','SELECT')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    pool.close().await;
    assert_eq!(probe, (1, true));
    match outcome {
        Err(b4hub_db::Error::Sqlx(sqlx::Error::Database(error))) => {
            assert_eq!(error.code().as_deref(), Some("P0001"));
            assert_eq!(error.message(), "deliberate default-grant refusal");
        }
        _ => panic!("the intended nonretryable default-grant fault must be returned"),
    }
    assert_eq!(permissions, (false, false, false));
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
    migrate_before(pool, "0018").await;
}

/// Applies every migration whose file name sorts before `first_excluded` (a version prefix such as
/// `0020`) to `pool`, as the ledger of a hub from before that migration.
async fn migrate_before(pool: &PgPool, first_excluded: &str) {
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
        if name.as_str() < first_excluded && name.ends_with(".sql") {
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

#[sqlx::test(migrations = false)]
async fn environments_rename_runner_preserves_opaque_json_update_history(pool: PgPool) {
    migrate_to_0017(&pool).await;
    let seeded = orgs::seed(
        &Db { pool: pool.clone() },
        "opaque-regression",
        "Fixture",
        "ann",
        "Ann",
        "ann@example.test",
    )
    .await
    .unwrap();
    let device: sqlx::types::Uuid = sqlx::query_scalar("INSERT INTO devices (id, org_id, user_id, name, platform) VALUES (gen_random_uuid(), $1, $2, 'Mac', 'macos') RETURNING id")
        .bind(seeded.org_id).bind(seeded.user_id).fetch_one(&pool).await.unwrap();
    let mut conn = pool.acquire().await.unwrap();
    let outcome = async {
        for statement in [
            r#"INSERT INTO "projects" (id,name,org_id,user_id,device_id,owner_device_id) VALUES ('p1','before',$1,$2,$3,$3)"#,
            r#"INSERT INTO "projectFolders" (id,"projectId",org_id,user_id,device_id,owner_device_id) VALUES ('f1','p1',$1,$2,$3,$3)"#,
            r#"INSERT INTO "threads" (id,"projectId",org_id,user_id,device_id,owner_device_id) VALUES ('t1','p1',$1,$2,$3,$3)"#,
            r#"INSERT INTO "connections" (id,"projectId",org_id,user_id,device_id,owner_device_id) VALUES ('c1','p1',$1,$2,$3,$3)"#,
            r#"INSERT INTO column_clocks (org_id,"table",row_id,"column",hlc) SELECT $1,v.tbl,v.row_id,v.col,'clock' FROM (VALUES ('projects','p1','name'),('threads','t1','projectId')) v(tbl,row_id,col) WHERE $2::uuid IS NOT NULL AND $3::uuid IS NOT NULL"#,
        ] {
            sqlx::query(statement).bind(seeded.org_id).bind(seeded.user_id).bind(device).execute(&mut *conn).await?;
        }
        sqlx::query(r#"-- One prepared INSERT, bind $1 org UUID, $2 user UUID, $3 enrolled fixture device UUID.
INSERT INTO changes (org_id, device_id, device_seq, user_id, wall, "table", row_id, op, "column", value, hlc, value_bytes)
SELECT $1, $3, s.seq, $2, s.seq, s.tbl, s.row_id, s.op, s.col, s.val, 'regression-' || s.seq::text, octet_length(s.val::text)
FROM (VALUES
 (1::bigint, 'projects', 'p1', 'insert', NULL::text, '{"id":"p1","name":"before"}'::jsonb),
 (2, 'projectFolders', 'f1', 'insert', NULL, '{"id":"f1","projectId":"p1"}'::jsonb),
 (3, 'threads', 't1', 'insert', NULL, '{"id":"t1","projectId":"p1"}'::jsonb),
 (4, 'threads', 't1', 'update', 'projectId', '"p1"'::jsonb),
 (5, 'connections', 'c1', 'insert', NULL, '{"id":"c1","projectId":"p1"}'::jsonb),
 (101, 'displayItems', 'opaque-single', 'update', 'payload', '{"projectId":"external"}'::jsonb),
 (102, 'displayItems', 'opaque-both', 'update', 'payload', '{"projectId":"external","environmentId":"keep","nested":{"projectId":"inside"}}'::jsonb),
 (103, 'displayItems', 'opaque-nested', 'update', 'payload', '{"nested":{"projectId":"inside"}}'::jsonb),
 (104, 'displayItems', 'opaque-array', 'update', 'payload', '[{"projectId":"external"}]'::jsonb),
 (105, 'connections', 'opaque-capabilities', 'update', 'capabilities', '{"projectId":"external","environmentId":"keep"}'::jsonb)
) AS s(seq,tbl,row_id,op,col,val);
"#).bind(seeded.org_id).bind(seeded.user_id).bind(device).execute(&mut *conn).await?;
        sqlx::raw_sql(r#"CREATE TEMP TABLE regression_opaque_before AS SELECT * FROM changes WHERE row_id LIKE 'opaque-%';
CREATE TEMP TABLE regression_count_before AS SELECT count(*) AS n FROM changes;
DO $$ BEGIN
 IF (SELECT count(*) FROM regression_opaque_before) <> 5 THEN RAISE EXCEPTION 'expected five opaque native change rows'; END IF;
END $$;
"#).execute(&mut *conn).await?;
        // Exercise the production runner on this test database; the acquired connection keeps
        // only its private TEMP beforeimages, outside any transaction, for the comparison below.
        b4hub_db::migrate::run(&admin_url(&pool), &app_url(&pool, "pw-test")).await?;
        sqlx::raw_sql(r#"-- Observe the production runner result using this connection's private beforeimages.
DO $$ BEGIN
 IF (SELECT count(*) FROM "environments" WHERE "id" = 'p1' AND "name" = 'before') <> 1
 OR (SELECT count(*) FROM "environmentFolders" WHERE "id" = 'f1' AND "environmentId" = 'p1') <> 1
 OR (SELECT count(*) FROM "threads" WHERE "id" = 't1' AND "environmentId" = 'p1') <> 1
 OR (SELECT count(*) FROM "connections" WHERE "id" = 'c1' AND "environmentId" = 'p1') <> 1 THEN
  RAISE EXCEPTION 'structural row rename failed';
 END IF;
 IF (SELECT count(*) FROM changes WHERE op = 'insert' AND "table" IN ('environmentFolders','threads','connections') AND value ->> 'environmentId' = 'p1' AND value_bytes = octet_length(value::text)) <> 3
 OR NOT EXISTS (SELECT 1 FROM changes WHERE "table" = 'threads' AND op = 'update' AND "column" = 'environmentId' AND value = '"p1"'::jsonb)
 OR EXISTS (SELECT 1 FROM changes WHERE "table" IN ('projects','projectFolders') OR "column" = 'projectId')
 OR NOT EXISTS (SELECT 1 FROM column_clocks WHERE "table" = 'environments' AND row_id = 'p1' AND "column" = 'name')
 OR NOT EXISTS (SELECT 1 FROM column_clocks WHERE "table" = 'threads' AND row_id = 't1' AND "column" = 'environmentId')
 OR EXISTS (SELECT 1 FROM column_clocks WHERE "table" IN ('projects','projectFolders') OR "column" = 'projectId') THEN
  RAISE EXCEPTION 'structural change/clock/size rename failed';
 END IF;
 IF (SELECT count(*) FROM changes) <> (SELECT n FROM regression_count_before) THEN RAISE EXCEPTION 'feed row count changed'; END IF;
 IF (SELECT count(*) FROM pg_class WHERE relname IN ('environments','environmentFolders','changes','column_clocks') AND relnamespace = 'public'::regnamespace AND relrowsecurity AND relforcerowsecurity) <> 4 THEN
  RAISE EXCEPTION 'RLS/force flags not preserved';
 END IF;
 -- Opaque whole-row history, including its original stored byte count, must remain exact.
 IF EXISTS (SELECT 1 FROM regression_opaque_before b LEFT JOIN changes a USING (org_id,hub_seq) WHERE to_jsonb(a) IS DISTINCT FROM to_jsonb(b)) THEN
  RAISE EXCEPTION 'opaque JSON update history changed during structural rename';
 END IF;
END $$;
"#).execute(&mut *conn).await?;
        Ok::<(), b4hub_db::Error>(())
    }.await;
    // Preserve the assertion/setup error until the explicitly owned test pool is normally closed.
    drop(conn);
    pool.close().await;
    outcome.unwrap();
}

/// `0020_user_settings_rows.sql` moves each settings row, with its clocks, to the id that names
/// its user, drops rows no device can reach, and leaves the log alone; a change pushed afterwards
/// lands on the moved row and still merges against the clock that came with it.
#[sqlx::test(migrations = false)]
async fn settings_rows_move_to_their_users(pool: PgPool) {
    use b4hub_core::change::{Change, ChangeOp};
    use b4hub_db::changes;
    use b4hub_db::devices::{AuthedDevice, Platform};
    use serde_json::json;

    // A typical owner is not a superuser, so lifting forced row security is what lets the
    // migration touch the rows; the tables are migrated by that owner, and the rows are seeded
    // by the superuser pool, which row security does not bind.
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
    let owner_pool = PgPool::connect(&owner_url).await.unwrap();
    migrate_before(&owner_pool, "0020").await;
    owner_pool.close().await;

    async fn seed_org(pool: &PgPool, slug: &str) -> (orgs::SeedOutcome, sqlx::types::Uuid) {
        let seeded = orgs::seed(
            &Db { pool: pool.clone() },
            slug,
            slug,
            slug,
            slug,
            &format!("{slug}@example.test"),
        )
        .await
        .unwrap();
        let device: sqlx::types::Uuid = sqlx::query_scalar(
            "INSERT INTO devices (id, org_id, user_id, name, platform) \
             VALUES (gen_random_uuid(), $1, $2, 'Mac', 'macos') RETURNING id",
        )
        .bind(seeded.org_id)
        .bind(seeded.user_id)
        .fetch_one(pool)
        .await
        .unwrap();
        (seeded, device)
    }
    let (seeded, device) = seed_org(&pool, "acme").await;
    let seeded_clock = format!("000001000000-0000-{device}");
    for statement in [
        r#"INSERT INTO "viewSettings" ("id", "arrangement", "quietThreads", org_id, user_id, device_id, owner_device_id)
           VALUES ('view', 'byEnvironment', 'tiny', $1, $2, $3, $3),
                  ('stray', 'needsYouFirst', 'small', $1, $2, $3, $3)"#,
        r#"INSERT INTO column_clocks (org_id, "table", row_id, "column", hlc)
           VALUES ($1, 'viewSettings', 'view', 'quietThreads', $4),
                  ($1, 'viewSettings', 'stray', 'arrangement', $4)"#,
        r#"INSERT INTO changes (org_id, device_id, device_seq, user_id, wall, "table", row_id, op, "column", value, hlc)
           VALUES ($1, $3, 1, $2, 1, 'viewSettings', 'view', 'insert', NULL,
                   '{"id": "view", "arrangement": "byEnvironment", "quietThreads": "tiny"}', $4)"#,
    ] {
        let mut query = sqlx::query(statement)
            .bind(seeded.org_id)
            .bind(seeded.user_id)
            .bind(device);
        if statement.contains("$4") {
            query = query.bind(&seeded_clock);
        }
        query.execute(&pool).await.unwrap();
    }
    // A second org with its own row and clock, which must end on its own user's id and clock.
    let (other, other_device) = seed_org(&pool, "beta").await;
    let other_clock = format!("000003000000-0000-{other_device}");
    sqlx::query(
        r#"INSERT INTO "viewSettings" ("id", "arrangement", org_id, user_id, device_id, owner_device_id)
           VALUES ('view', 'needsYouFirst', $1, $2, $3, $3)"#,
    )
    .bind(other.org_id)
    .bind(other.user_id)
    .bind(other_device)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query(
        r#"INSERT INTO column_clocks (org_id, "table", row_id, "column", hlc)
           VALUES ($1, 'viewSettings', 'view', 'arrangement', $2)"#,
    )
    .bind(other.org_id)
    .bind(&other_clock)
    .execute(&pool)
    .await
    .unwrap();
    // A third org holds a clock under `view` but no row (an update that reached a missing row).
    let (orphan, _) = seed_org(&pool, "gamma").await;
    sqlx::query(
        r#"INSERT INTO column_clocks (org_id, "table", row_id, "column", hlc)
           VALUES ($1, 'viewSettings', 'view', 'arrangement', $2)"#,
    )
    .bind(orphan.org_id)
    .bind(&other_clock)
    .execute(&pool)
    .await
    .unwrap();

    // The full migrator, as the owner, applies 0020 (and provisions the application role). It
    // also applies 0021, which turns the moved row's `tiny` into `shown` with a `dense` density
    // and gives that density the `quietThreads` clock.
    let app_url = app_url(&pool, "pw-test");
    b4hub_db::migrate::run(&owner_url, &app_url).await.unwrap();

    let moved = format!("view:{}", seeded.user_id);
    let rows: Vec<(String, Option<String>, Option<String>)> = sqlx::query_as(
        r#"SELECT "id", "arrangement", "quietThreads" FROM "viewSettings" WHERE org_id = $1"#,
    )
    .bind(seeded.org_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(
        rows,
        vec![(
            moved.clone(),
            Some("byEnvironment".to_string()),
            Some("shown".to_string())
        )]
    );
    let clocks_of = |org_id: sqlx::types::Uuid| {
        let pool = pool.clone();
        async move {
            sqlx::query_as::<_, (String, String)>(
                r#"SELECT row_id, hlc FROM column_clocks
                   WHERE "table" = 'viewSettings' AND org_id = $1"#,
            )
            .bind(org_id)
            .fetch_all(&pool)
            .await
            .unwrap()
        }
    };
    assert_eq!(
        clocks_of(seeded.org_id).await,
        vec![
            (moved.clone(), seeded_clock.clone()),
            (moved.clone(), seeded_clock.clone())
        ]
    );
    // The other org's row and clock end on its own user's id; the orphan clock is gone.
    let other_rows: Vec<String> =
        sqlx::query_scalar(r#"SELECT "id" FROM "viewSettings" WHERE org_id = $1"#)
            .bind(other.org_id)
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(other_rows, vec![format!("view:{}", other.user_id)]);
    assert_eq!(
        clocks_of(other.org_id).await,
        vec![(format!("view:{}", other.user_id), other_clock.clone())]
    );
    assert!(clocks_of(orphan.org_id).await.is_empty());
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM changes WHERE "table" = 'viewSettings' AND row_id = 'view'"#
        )
        .await,
        1
    );
    assert_eq!(
        count(
            &pool,
            r#"SELECT count(*) FROM pg_class
               WHERE relname IN ('viewSettings', 'column_clocks') AND relforcerowsecurity"#
        )
        .await,
        2
    );

    // A change pushed afterwards merges against the clock that came with the row.
    let app = Db::connect(&app_url).await.unwrap();
    let who = AuthedDevice {
        org_id: seeded.org_id,
        user_id: seeded.user_id,
        device_id: device,
        platform: Platform::parse("macos").unwrap(),
    };
    let quiet = |seq: i64, clock: &str, value: &str| Change {
        device_seq: seq,
        wall: 1_761_900_000_000 + seq,
        table: "viewSettings".into(),
        row_id: "view".into(),
        op: ChangeOp::Update,
        column: Some("quietThreads".into()),
        value: Some(json!(value)),
        hlc: Some(format!("{clock}-0000-{device}")),
    };
    let quiet_threads = || async {
        let mut tx = app.tenant_tx(seeded.org_id).await.unwrap();
        let rows: Vec<(String, Option<String>)> =
            sqlx::query_as(r#"SELECT "id", "quietThreads" FROM "viewSettings""#)
                .fetch_all(&mut *tx)
                .await
                .unwrap();
        tx.commit().await.unwrap();
        rows
    };
    changes::push(&app, &who, &[quiet(2, "000000000001", "hidden")])
        .await
        .unwrap();
    assert_eq!(
        quiet_threads().await,
        vec![(moved.clone(), Some("shown".to_string()))]
    );
    changes::push(&app, &who, &[quiet(3, "000002100000", "hidden")])
        .await
        .unwrap();
    assert_eq!(
        quiet_threads().await,
        vec![(moved.clone(), Some("hidden".to_string()))]
    );
    let pulled = changes::pull(&app, &who, 0, 1000).await.unwrap();
    let ids: Vec<(&str, &str)> = pulled
        .changes
        .iter()
        .map(|change| (change.table.as_str(), change.row_id.as_str()))
        .collect();
    assert_eq!(ids, vec![("viewSettings", "view"); 3]);
    // The replay ends on the value the migrated row holds.
    assert_eq!(
        pulled.changes.last().unwrap().value,
        Some(serde_json::json!("hidden"))
    );
}

/// `0021_density.sql` splits the old four-way `quietThreads` into `density` and a three-way
/// `quietThreads`, gives each `density` it sets the clock of the row's `quietThreads`, leaves a row
/// with no `quietThreads` alone, and leaves the log and each table's forced row security as found.
#[sqlx::test(migrations = false)]
async fn density_is_split_from_the_sidebar_setting(pool: PgPool) {
    use b4hub_core::change::{Change, ChangeOp};
    use b4hub_db::changes;
    use b4hub_db::devices::{AuthedDevice, Platform};
    use serde_json::json;

    // As in `settings_rows_move_to_their_users`: migrated by a non-superuser owner, seeded by the
    // superuser pool.
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
    let owner_pool = PgPool::connect(&owner_url).await.unwrap();
    migrate_before(&owner_pool, "0021").await;
    owner_pool.close().await;

    struct Seeded {
        org_id: sqlx::types::Uuid,
        user_id: sqlx::types::Uuid,
        device: sqlx::types::Uuid,
        clock: String,
    }
    // One org per old value, each row with a `quietThreads` clock, and one whose row has no
    // `quietThreads` (only an `arrangement` and its clock).
    let cases: [(&str, Option<&str>); 5] = [
        ("small", Some("small")),
        ("tiny", Some("tiny")),
        ("collapsed", Some("collapsed")),
        ("hidden", Some("hidden")),
        ("unset", None),
    ];
    let mut seeded = Vec::new();
    for (index, (slug, quiet)) in cases.iter().enumerate() {
        let org = orgs::seed(
            &Db { pool: pool.clone() },
            slug,
            slug,
            slug,
            slug,
            &format!("{slug}@example.test"),
        )
        .await
        .unwrap();
        let device: sqlx::types::Uuid = sqlx::query_scalar(
            "INSERT INTO devices (id, org_id, user_id, name, platform) \
             VALUES (gen_random_uuid(), $1, $2, 'Mac', 'macos') RETURNING id",
        )
        .bind(org.org_id)
        .bind(org.user_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        let clock = format!("00000{}000000-0000-{device}", index + 1);
        let row_id = format!("view:{}", org.user_id);
        sqlx::query(
            r#"INSERT INTO "viewSettings" ("id", "arrangement", "quietThreads", org_id, user_id, device_id, owner_device_id)
               VALUES ($1, 'byEnvironment', $2, $3, $4, $5, $5)"#,
        )
        .bind(&row_id)
        .bind(quiet)
        .bind(org.org_id)
        .bind(org.user_id)
        .bind(device)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            r#"INSERT INTO column_clocks (org_id, "table", row_id, "column", hlc)
               VALUES ($1, 'viewSettings', $2, $3, $4)"#,
        )
        .bind(org.org_id)
        .bind(&row_id)
        .bind(if quiet.is_some() {
            "quietThreads"
        } else {
            "arrangement"
        })
        .bind(&clock)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            r#"INSERT INTO changes (org_id, device_id, device_seq, user_id, wall, "table", row_id, op, "column", value, hlc)
               VALUES ($1, $2, 1, $3, 1, 'viewSettings', 'view', 'insert', NULL, $4, $5)"#,
        )
        .bind(org.org_id)
        .bind(device)
        .bind(org.user_id)
        .bind(json!({"id": "view", "arrangement": "byEnvironment", "quietThreads": quiet}))
        .bind(&clock)
        .execute(&pool)
        .await
        .unwrap();
        seeded.push(Seeded {
            org_id: org.org_id,
            user_id: org.user_id,
            device,
            clock,
        });
    }
    // The clocks table is left unforced, so restoring "as found" is told apart from forcing both.
    sqlx::query("ALTER TABLE column_clocks NO FORCE ROW LEVEL SECURITY")
        .execute(&pool)
        .await
        .unwrap();
    let changes_before: Vec<(i64, String, Option<serde_json::Value>)> =
        sqlx::query_as(r#"SELECT hub_seq, row_id, value FROM changes ORDER BY hub_seq"#)
            .fetch_all(&pool)
            .await
            .unwrap();

    // The full migrator, as the owner, applies 0021.
    let app_url = app_url(&pool, "pw-test");
    b4hub_db::migrate::run(&owner_url, &app_url).await.unwrap();

    let expected: [(Option<&str>, Option<&str>); 5] = [
        (Some("normal"), Some("shown")),
        (Some("dense"), Some("shown")),
        (Some("normal"), Some("collapsed")),
        (Some("normal"), Some("hidden")),
        (None, None),
    ];
    for (org, (density, quiet)) in seeded.iter().zip(expected) {
        let row: (Option<String>, Option<String>, Option<String>) = sqlx::query_as(
            r#"SELECT "density", "quietThreads", "arrangement" FROM "viewSettings" WHERE org_id = $1"#,
        )
        .bind(org.org_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(
            row,
            (
                density.map(String::from),
                quiet.map(String::from),
                Some("byEnvironment".to_string())
            )
        );
        let clocks: Vec<(String, String)> = sqlx::query_as(
            r#"SELECT "column", hlc FROM column_clocks
               WHERE "table" = 'viewSettings' AND org_id = $1 ORDER BY "column""#,
        )
        .bind(org.org_id)
        .fetch_all(&pool)
        .await
        .unwrap();
        let expected_clocks: Vec<(String, String)> = if density.is_some() {
            vec![
                ("density".to_string(), org.clock.clone()),
                ("quietThreads".to_string(), org.clock.clone()),
            ]
        } else {
            vec![("arrangement".to_string(), org.clock.clone())]
        };
        assert_eq!(clocks, expected_clocks);
        let row_ids: Vec<String> =
            sqlx::query_scalar(r#"SELECT DISTINCT row_id FROM column_clocks WHERE org_id = $1"#)
                .bind(org.org_id)
                .fetch_all(&pool)
                .await
                .unwrap();
        assert_eq!(row_ids, vec![format!("view:{}", org.user_id)]);
    }
    let changes_after: Vec<(i64, String, Option<serde_json::Value>)> =
        sqlx::query_as(r#"SELECT hub_seq, row_id, value FROM changes ORDER BY hub_seq"#)
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(changes_after, changes_before, "the log is left alone");
    let forced: Vec<(String, bool)> = sqlx::query_as(
        r#"SELECT relname::text, relforcerowsecurity FROM pg_class
           WHERE relname IN ('viewSettings', 'column_clocks') ORDER BY relname"#,
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(
        forced,
        vec![
            ("column_clocks".to_string(), false),
            ("viewSettings".to_string(), true)
        ]
    );

    // As the `tiny` org's device: a `density` write older than the carried clock loses, a newer
    // one lands.
    let tiny = &seeded[1];
    let app = Db::connect(&app_url).await.unwrap();
    let who = AuthedDevice {
        org_id: tiny.org_id,
        user_id: tiny.user_id,
        device_id: tiny.device,
        platform: Platform::parse("macos").unwrap(),
    };
    let density = |seq: i64, clock: &str, value: &str| Change {
        device_seq: seq,
        wall: 1_761_900_000_000 + seq,
        table: "viewSettings".into(),
        row_id: "view".into(),
        op: ChangeOp::Update,
        column: Some("density".into()),
        value: Some(json!(value)),
        hlc: Some(format!("{clock}-0000-{}", tiny.device)),
    };
    let stored_density = || async {
        let mut tx = app.tenant_tx(tiny.org_id).await.unwrap();
        let value: Option<String> = sqlx::query_scalar(r#"SELECT "density" FROM "viewSettings""#)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        value
    };
    changes::push(&app, &who, &[density(2, "000001000000", "normal")])
        .await
        .unwrap();
    assert_eq!(stored_density().await, Some("dense".to_string()));
    changes::push(&app, &who, &[density(3, "000003000000", "normal")])
        .await
        .unwrap();
    assert_eq!(stored_density().await, Some("normal".to_string()));
}
