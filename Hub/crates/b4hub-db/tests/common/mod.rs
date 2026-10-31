//! Helpers shared by the database integration tests. Run with `source <(./scripts/test-db.sh)`
//! first; `#[sqlx::test]` creates one database per test.

#![allow(dead_code)]

use b4hub_db::Db;
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
