//! Helpers shared by the database integration tests. Run with `source <(./scripts/test-db.sh)`
//! first; `#[sqlx::test]` creates one database per test.

#![allow(dead_code)]

use std::time::Duration;

use b4hub_core::change::Change;
use b4hub_db::devices::{self, AuthedDevice, Platform};
use b4hub_db::{orgs, Db};
use serde_json::{json, Value};
use sqlx::PgPool;
use url::Url;

/// The password the tests give the `b4hub_app` role.
pub const APP_PASSWORD: &str = "pw-test";

/// The test pool's database, reached as the `DATABASE_URL` user.
pub fn admin_url(pool: &PgPool) -> String {
    let base = std::env::var("DATABASE_URL").expect("DATABASE_URL is set by test-db.sh");
    let mut url = Url::parse(&base).unwrap();
    let database = pool
        .connect_options()
        .get_database()
        .expect("test pool has a database")
        .to_string();
    url.set_path(&format!("/{database}"));
    url.to_string()
}

/// The same database reached as `user`.
pub fn url_as(pool: &PgPool, user: &str, password: &str) -> String {
    let mut url = Url::parse(&admin_url(pool)).unwrap();
    url.set_username(user).unwrap();
    url.set_password(Some(password)).unwrap();
    url.to_string()
}

/// The same database reached as the application role.
pub fn app_url(pool: &PgPool, password: &str) -> String {
    url_as(pool, "b4hub_app", password)
}

/// Migrates the test database and provisions `b4hub_app`, then returns a handle connected as the
/// owner (the `DATABASE_URL` user) and one connected as `b4hub_app`.
pub async fn migrated(pool: &PgPool) -> (Db, Db) {
    let admin_url = admin_url(pool);
    let app_url = app_url(pool, APP_PASSWORD);
    b4hub_db::migrate::run(&admin_url, &app_url).await.unwrap();
    let admin = Db::connect(&admin_url).await.unwrap();
    let app = Db::connect(&app_url).await.unwrap();
    (admin, app)
}

/// Seeds `username` in the org `org_slug` and enrolls one macOS device for them through the real
/// enrollment path.
pub async fn enrolled_in(admin: &Db, app: &Db, org_slug: &str, username: &str) -> AuthedDevice {
    enrolled_in_as(admin, app, org_slug, username, "macos").await
}

/// Like [`enrolled_in`], for a device of `platform` (`macos`, `ios` or `cli`). Enrolling the same
/// user again adds another device of theirs.
pub async fn enrolled_in_as(
    admin: &Db,
    app: &Db,
    org_slug: &str,
    username: &str,
    platform: &str,
) -> AuthedDevice {
    let seeded = orgs::seed(
        admin,
        org_slug,
        org_slug,
        username,
        username,
        &format!("{username}@example.test"),
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        admin,
        seeded.org_id,
        seeded.user_id,
        Duration::from_secs(600),
    )
    .await
    .unwrap();
    let enrolled = devices::redeem(app, &code, "test device", platform)
        .await
        .unwrap();
    AuthedDevice {
        org_id: enrolled.org_id,
        user_id: enrolled.user_id,
        device_id: enrolled.device_id,
        platform: Platform::parse(platform).expect("a platform the devices table accepts"),
    }
}

/// A device of `username` in the org `cacheplane`, of `platform`.
pub async fn enrolled_as(admin: &Db, app: &Db, username: &str, platform: &str) -> AuthedDevice {
    enrolled_in_as(admin, app, "cacheplane", username, platform).await
}

/// A device of `username` in the org `cacheplane`.
pub async fn enrolled(admin: &Db, app: &Db, username: &str) -> AuthedDevice {
    enrolled_in(admin, app, "cacheplane", username).await
}

/// The shared wire fixture, exactly as the Mac would record it.
pub fn fixture() -> Vec<Change> {
    serde_json::from_str(include_str!(
        "../../../../../Tests/Fixtures/sync/changes.json"
    ))
    .unwrap()
}

/// The fixture after the coordinator's upload filter, applied by hand: `connections.authReference`,
/// `localServerId` and `target` blanked, and a `displayItems.payload` over 1 MiB replaced by its
/// truncation marker.
pub fn filtered_fixture() -> Vec<Change> {
    let mut changes = fixture();
    for change in &mut changes {
        let Some(Value::Object(row)) = change.value.as_mut() else {
            continue;
        };
        if change.table == "connections" {
            for column in ["authReference", "localServerId", "target"] {
                row.insert(column.into(), Value::Null);
            }
        }
        if change.table == "displayItems" {
            let bytes = serde_json::to_vec(&row["payload"]).unwrap().len();
            if bytes > 1_048_576 {
                row.insert("payload".into(), json!({"truncated": true, "bytes": bytes}));
            }
        }
    }
    changes
}
