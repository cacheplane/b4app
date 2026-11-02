//! Maintenance mode: the operator switch and what `serve` does while it is on. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

use b4hub::cli::{self, Cli, Settings};
use b4hub_db::settings::{self, Maintenance};
use b4hub_db::Db;
use clap::Parser;
use sqlx::PgPool;
use url::Url;

fn admin_url(pool: &PgPool) -> String {
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

fn app_url(pool: &PgPool) -> String {
    let mut url = Url::parse(&admin_url(pool)).unwrap();
    url.set_username("b4hub_app").unwrap();
    url.set_password(Some("pw-test")).unwrap();
    url.to_string()
}

async fn migrated(pool: &PgPool) -> Db {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    Db::connect(&admin_url(pool)).await.unwrap()
}

async fn run(settings: &Settings, args: &[&str]) -> Result<(), cli::CliError> {
    let cli = Cli::try_parse_from(
        ["b4hub", "maintenance"]
            .into_iter()
            .chain(args.iter().copied()),
    )
    .unwrap();
    cli::run(cli, settings).await
}

#[sqlx::test(migrations = false)]
async fn the_maintenance_command_switches_the_database_flag(pool: PgPool) {
    let admin = migrated(&pool).await;
    let settings = Settings::from_pairs([("DATABASE_ADMIN_URL", admin_url(&pool))]);

    run(&settings, &["status"]).await.unwrap();
    assert_eq!(settings::maintenance(&admin).await.unwrap(), None);

    run(&settings, &["on", "--message", "swapping the disk"])
        .await
        .unwrap();
    let on = settings::maintenance(&admin).await.unwrap().expect("on");
    assert_eq!(on.message.as_deref(), Some("swapping the disk"));
    run(&settings, &["status"]).await.unwrap();

    run(&settings, &["on"]).await.unwrap();
    assert_eq!(
        settings::maintenance(&admin)
            .await
            .unwrap()
            .unwrap()
            .message,
        None
    );

    run(&settings, &["off"]).await.unwrap();
    assert_eq!(settings::maintenance(&admin).await.unwrap(), None);

    // Like seed and enroll: no admin URL is a configuration error, exit 2.
    let error = run(&Settings::from_pairs::<&str, &str>([]), &["on"])
        .await
        .unwrap_err();
    assert_eq!(error.exit_code(), 2);
    assert!(Cli::try_parse_from(["b4hub", "maintenance"]).is_err());
    assert!(Cli::try_parse_from(["b4hub", "maintenance", "on", "--message", ""]).is_err());
    let _ = Maintenance::read_only(None);
}
