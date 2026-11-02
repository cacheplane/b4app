//! The hub-wide settings table: the maintenance switch, and the application role's read-only
//! access to it. Run with `source <(./scripts/test-db.sh)` first.

mod common;

use b4hub_db::settings::{self, Maintenance, MaintenanceMode};
use sqlx::PgPool;

fn sqlstate(error: &sqlx::Error) -> Option<String> {
    error
        .as_database_error()
        .and_then(|e| e.code())
        .map(|c| c.into_owned())
}

#[sqlx::test(migrations = false)]
async fn maintenance_is_off_until_set_and_reads_back_what_was_written(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    assert_eq!(settings::maintenance(&app).await.unwrap(), None);

    let on = Maintenance::read_only(Some("swapping the disk".to_string()));
    assert!(on.since.ends_with('Z'), "{}", on.since);
    settings::set_maintenance(&admin, Some(&on)).await.unwrap();
    let read = settings::maintenance(&app).await.unwrap().expect("on");
    assert_eq!(read.mode, MaintenanceMode::ReadOnly);
    assert_eq!(read.message.as_deref(), Some("swapping the disk"));
    assert_eq!(read.since, on.since);

    // Turning it on again replaces the message and the timestamp.
    let again = Maintenance::read_only(None);
    settings::set_maintenance(&admin, Some(&again))
        .await
        .unwrap();
    let read = settings::maintenance(&app).await.unwrap().expect("on");
    assert_eq!(read.message, None);

    settings::set_maintenance(&admin, None).await.unwrap();
    assert_eq!(settings::maintenance(&app).await.unwrap(), None);
    // Off twice is fine.
    settings::set_maintenance(&admin, None).await.unwrap();
    assert_eq!(settings::maintenance(&app).await.unwrap(), None);
}

#[sqlx::test(migrations = false)]
async fn the_app_role_can_only_read_hub_settings(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    settings::set_maintenance(&admin, Some(&Maintenance::read_only(None)))
        .await
        .unwrap();

    let keys: Vec<String> = sqlx::query_scalar("SELECT key FROM hub_settings")
        .fetch_all(&app.pool)
        .await
        .unwrap();
    assert_eq!(keys, vec!["maintenance"]);

    for statement in [
        "INSERT INTO hub_settings (key, value) VALUES ('other', '{}'::jsonb)",
        "UPDATE hub_settings SET value = '{}'::jsonb WHERE key = 'maintenance'",
        "DELETE FROM hub_settings WHERE key = 'maintenance'",
    ] {
        let error = sqlx::query(statement).execute(&app.pool).await.unwrap_err();
        // 42501 insufficient_privilege
        assert_eq!(sqlstate(&error).as_deref(), Some("42501"), "{statement}");
    }
    assert!(settings::maintenance(&app).await.unwrap().is_some());

    // The writer path refuses too (the CLI connects as the owner, never as the app role).
    let error = settings::set_maintenance(&app, None).await.unwrap_err();
    assert!(error.to_string().contains("permission denied"), "{error}");
}

#[test]
fn since_is_rfc3339_utc() {
    use std::time::{Duration, UNIX_EPOCH};
    assert_eq!(
        settings::rfc3339_utc(UNIX_EPOCH + Duration::from_secs(1_761_900_000)),
        "2025-10-31T08:40:00Z"
    );
    assert_eq!(settings::rfc3339_utc(UNIX_EPOCH), "1970-01-01T00:00:00Z");
    assert_eq!(
        settings::rfc3339_utc(UNIX_EPOCH + Duration::from_secs(951_782_400)),
        "2000-02-29T00:00:00Z"
    );
}
