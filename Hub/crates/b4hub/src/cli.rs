//! Command line, environment settings, and the five commands (`serve`, `migrate`, `seed`,
//! `enroll`, `prune`).
//!
//! A missing or malformed setting is a [`ConfigError`] that names the setting and never echoes
//! its value (the database URLs carry passwords); `main` prints it on one line and exits 2.
//! Everything else that fails exits 1.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::Duration;

use clap::{Args, Parser, Subcommand};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;
use url::Url;

use b4hub_db::orgs::{self, OrgChoice};
use b4hub_db::{devices, Db};

use crate::serve::{self, AppState};

const DEFAULT_PORT: u16 = 8080;
const DEFAULT_SHUTDOWN_WAIT_MS: u64 = 30_000;
const DEFAULT_RETENTION_DAYS: u32 = 30;
const SECONDS_PER_DAY: u64 = 24 * 60 * 60;

/// How long an enrollment code stays redeemable.
const ENROLLMENT_TTL: Duration = Duration::from_secs(600);

#[derive(Debug, Parser)]
#[command(
    name = "b4hub",
    version,
    about = "The Personal Agent Workspace sync hub"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Run the HTTP service (connects with DATABASE_URL).
    Serve {
        /// Address to listen on; defaults to 0.0.0.0 on B4HUB_PORT (8080).
        #[arg(long)]
        bind: Option<SocketAddr>,
    },
    /// Apply migrations and provision the b4hub_app role (DATABASE_ADMIN_URL and DATABASE_URL).
    Migrate,
    /// Create an org and a user in it if they do not exist (connects with DATABASE_ADMIN_URL).
    Seed(SeedArgs),
    /// Print a one-time enrollment code for a user (connects with DATABASE_ADMIN_URL).
    Enroll(EnrollArgs),
    /// Delete change-log entries older than a number of days, once (connects with
    /// DATABASE_ADMIN_URL). `serve` does this itself every 24 hours.
    Prune(PruneArgs),
}

#[derive(Debug, Args)]
pub struct PruneArgs {
    /// Keep changes received within this many days; delete older ones.
    #[arg(long = "older-than-days", value_parser = clap::value_parser!(u32).range(1..))]
    pub older_than_days: u32,
    /// Org slug; every org when omitted.
    #[arg(long = "org", value_parser = parse_slug)]
    pub org: Option<String>,
}

#[derive(Debug, Args)]
pub struct EnrollArgs {
    /// Username of the user the device will belong to.
    #[arg(long = "user", value_parser = parse_non_empty)]
    pub user: String,
    /// Org slug; optional when exactly one org exists.
    #[arg(long = "org", value_parser = parse_slug)]
    pub org: Option<String>,
}

#[derive(Debug, Args)]
pub struct SeedArgs {
    /// Org slug: lowercase letters, digits, and hyphens.
    #[arg(long = "org", value_parser = parse_slug)]
    pub org: String,
    /// Org display name.
    #[arg(long = "org-name", value_parser = parse_non_empty)]
    pub org_name: String,
    /// Username, unique within the org.
    #[arg(long = "user", value_parser = parse_non_empty)]
    pub user: String,
    /// The user's display name.
    #[arg(long = "name", value_parser = parse_non_empty)]
    pub name: String,
    /// The user's email address.
    #[arg(long = "email", value_parser = parse_email)]
    pub email: String,
}

fn parse_non_empty(value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty() {
        Err("must not be empty".to_string())
    } else {
        Ok(value.to_string())
    }
}

fn parse_slug(value: &str) -> Result<String, String> {
    let ok = !value.is_empty()
        && value.len() <= 63
        && value
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !value.starts_with('-')
        && !value.ends_with('-');
    if ok {
        Ok(value.to_string())
    } else {
        Err("must be 1-63 lowercase letters, digits, or hyphens, not starting or ending with a hyphen".to_string())
    }
}

fn parse_email(value: &str) -> Result<String, String> {
    let value = parse_non_empty(value)?;
    match value.split_once('@') {
        Some((local, domain)) if !local.is_empty() && !domain.is_empty() => Ok(value),
        _ => Err("must look like name@example.com".to_string()),
    }
}

/// A setting that is missing or malformed. Displays as `<NAME>: <reason>`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{name}: {reason}")]
pub struct ConfigError {
    pub name: String,
    pub reason: String,
}

impl ConfigError {
    fn new(name: &str, reason: impl Into<String>) -> ConfigError {
        ConfigError {
            name: name.to_string(),
            reason: reason.into(),
        }
    }
}

/// Why a command stopped.
#[derive(Debug, thiserror::Error)]
pub enum CliError {
    /// Exit status 2.
    #[error("configuration error: {0}")]
    Config(#[from] ConfigError),
    /// Exit status 1.
    #[error("{0}")]
    Db(#[from] b4hub_db::Error),
    /// Exit status 1.
    #[error("{0}")]
    Io(#[from] std::io::Error),
}

impl CliError {
    pub fn exit_code(&self) -> u8 {
        match self {
            CliError::Config(_) => 2,
            CliError::Db(_) | CliError::Io(_) => 1,
        }
    }
}

/// A snapshot of the environment, so settings parse the same way in tests as in production.
#[derive(Debug, Clone, Default)]
pub struct Settings {
    vars: HashMap<String, String>,
}

impl Settings {
    pub fn from_env() -> Settings {
        Settings::from_pairs(std::env::vars())
    }

    pub fn from_pairs<K: Into<String>, V: Into<String>>(
        pairs: impl IntoIterator<Item = (K, V)>,
    ) -> Settings {
        Settings {
            vars: pairs
                .into_iter()
                .map(|(k, v)| (k.into(), v.into()))
                .collect(),
        }
    }

    fn var(&self, name: &str) -> Option<&str> {
        self.vars
            .get(name)
            .map(String::as_str)
            .filter(|v| !v.is_empty())
    }

    /// `B4HUB_PORT`, default 8080.
    pub fn port(&self) -> Result<u16, ConfigError> {
        match self.var("B4HUB_PORT") {
            None => Ok(DEFAULT_PORT),
            Some(raw) => raw
                .parse::<u16>()
                .ok()
                .filter(|port| *port != 0)
                .ok_or_else(|| {
                    ConfigError::new("B4HUB_PORT", "must be a port number from 1 to 65535")
                }),
        }
    }

    /// `B4HUB_SHUTDOWN_WAIT_MS`, default 30000.
    pub fn shutdown_wait(&self) -> Result<Duration, ConfigError> {
        match self.var("B4HUB_SHUTDOWN_WAIT_MS") {
            None => Ok(Duration::from_millis(DEFAULT_SHUTDOWN_WAIT_MS)),
            Some(raw) => raw.parse::<u64>().map(Duration::from_millis).map_err(|_| {
                ConfigError::new(
                    "B4HUB_SHUTDOWN_WAIT_MS",
                    "must be a whole number of milliseconds",
                )
            }),
        }
    }

    /// `B4HUB_RETENTION_DAYS`, default 30: how long `serve` keeps the change log. A whole number
    /// of days, at least 1 (0 would delete the feed on every pass).
    pub fn retention(&self) -> Result<Duration, ConfigError> {
        let days = match self.var("B4HUB_RETENTION_DAYS") {
            None => DEFAULT_RETENTION_DAYS,
            Some(raw) => raw
                .parse::<u32>()
                .ok()
                .filter(|days| *days >= 1)
                .ok_or_else(|| {
                    ConfigError::new(
                        "B4HUB_RETENTION_DAYS",
                        "must be a whole number of days, at least 1",
                    )
                })?,
        };
        Ok(Duration::from_secs(u64::from(days) * SECONDS_PER_DAY))
    }

    /// `B4HUB_PUBLIC_URL`, when set: the URL clients reach the hub at.
    pub fn public_url(&self) -> Result<Option<Url>, ConfigError> {
        match self.var("B4HUB_PUBLIC_URL") {
            None => Ok(None),
            Some(raw) => match Url::parse(raw) {
                Ok(url) if matches!(url.scheme(), "http" | "https") && url.has_host() => {
                    Ok(Some(url))
                }
                _ => Err(ConfigError::new(
                    "B4HUB_PUBLIC_URL",
                    "must be an http or https URL",
                )),
            },
        }
    }

    /// `B4HUB_LOG`, a tracing filter, default `info`.
    pub fn log_filter(&self) -> Result<EnvFilter, ConfigError> {
        EnvFilter::try_new(self.var("B4HUB_LOG").unwrap_or("info"))
            .map_err(|_| ConfigError::new("B4HUB_LOG", "is not a valid tracing filter"))
    }

    /// `DATABASE_URL` (or the contents of the file `DATABASE_URL_FILE` names): the `b4hub_app`
    /// connection.
    pub fn database_url(&self) -> Result<String, ConfigError> {
        self.secret_url("DATABASE_URL")
    }

    /// `DATABASE_URL` as `migrate` needs it: the connection must be as `b4hub_app` with a usable
    /// password, because `migrate` provisions that role from it.
    pub fn provisioning_url(&self) -> Result<String, ConfigError> {
        let url = self.database_url()?;
        b4hub_db::migrate::validate_app_url(&url)
            .map_err(|reason| ConfigError::new("DATABASE_URL", reason))?;
        Ok(url)
    }

    /// `DATABASE_ADMIN_URL` (or `DATABASE_ADMIN_URL_FILE`): the owner connection.
    pub fn admin_url(&self) -> Result<String, ConfigError> {
        self.secret_url("DATABASE_ADMIN_URL")
    }

    fn secret_url(&self, name: &str) -> Result<String, ConfigError> {
        let file_name = format!("{name}_FILE");
        let value = match (self.var(name), self.var(&file_name)) {
            (Some(_), Some(_)) => {
                return Err(ConfigError::new(
                    name,
                    format!("and {file_name} are both set; set only one"),
                ))
            }
            (Some(value), None) => value.to_string(),
            (None, Some(path)) => std::fs::read_to_string(path)
                .map_err(|_| ConfigError::new(&file_name, "the file cannot be read"))?
                .trim()
                .to_string(),
            (None, None) => {
                return Err(ConfigError::new(
                    name,
                    format!("is not set (set {name} or {file_name})"),
                ))
            }
        };
        match Url::parse(&value) {
            Ok(url) if matches!(url.scheme(), "postgres" | "postgresql") && url.has_host() => {
                Ok(value)
            }
            _ => Err(ConfigError::new(
                name,
                "must be a postgres:// or postgresql:// URL",
            )),
        }
    }
}

/// Runs a parsed command.
pub async fn run(cli: Cli, settings: &Settings) -> Result<(), CliError> {
    match cli.command {
        Command::Serve { bind } => serve_command(bind, settings).await,
        Command::Migrate => migrate_command(settings).await,
        Command::Seed(args) => seed_command(args, settings).await,
        Command::Enroll(args) => enroll_command(args, settings).await,
        Command::Prune(args) => prune_command(args, settings).await,
    }
}

async fn serve_command(bind: Option<SocketAddr>, settings: &Settings) -> Result<(), CliError> {
    let addr = match bind {
        Some(addr) => addr,
        None => SocketAddr::from(([0, 0, 0, 0], settings.port()?)),
    };
    let wait = settings.shutdown_wait()?;
    let public_url = settings.public_url()?;
    let retention = settings.retention()?;
    let db = Db::connect(&settings.database_url()?).await?;
    refuse_privileged_connection(&db).await?;
    let listener = TcpListener::bind(addr).await?;
    tracing::info!(
        %addr,
        public_url = public_url.as_ref().map(Url::as_str),
        shutdown_wait_ms = wait.as_millis() as u64,
        retention_days = retention.as_secs() / SECONDS_PER_DAY,
        "serving"
    );
    let state = AppState::new(db.clone());
    let pruning = tokio::spawn(serve::prune_loop(
        db,
        retention,
        serve::PRUNE_INTERVAL,
        state.shutdown.clone(),
    ));
    let shutdown = state.shutdown.clone();
    let served = serve::run(listener, state, wait, serve::os_signal()).await;
    // However `run` ended, the prune task stops with it; it ends at once on the flag.
    shutdown.trigger();
    let _ = tokio::time::timeout(Duration::from_secs(2), pruning).await;
    served?;
    tracing::info!("stopped");
    Ok(())
}

/// `serve`'s startup check: the service must connect as `b4hub_app`, never as a role that the
/// tenant policies do not bind (a superuser, a `BYPASSRLS` role, or the table owner, such as the
/// admin URL pasted into `DATABASE_URL`). A configuration error, so `serve` exits 2 before binding.
pub async fn refuse_privileged_connection(db: &Db) -> Result<(), CliError> {
    if b4hub_db::migrate::connected_role_is_privileged(db).await? {
        return Err(ConfigError::new(
            "DATABASE_URL",
            "connects as a superuser, a BYPASSRLS role, or the table owner; \
             serve must connect as b4hub_app",
        )
        .into());
    }
    Ok(())
}

async fn migrate_command(settings: &Settings) -> Result<(), CliError> {
    let admin_url = settings.admin_url()?;
    let app_url = settings.provisioning_url()?;
    b4hub_db::migrate::run(&admin_url, &app_url).await?;
    let db = Db::connect(&admin_url).await?;
    let status = b4hub_db::migrate::status(&db).await?;
    println!(
        "migrated: {} applied, {} pending",
        status.applied.len(),
        status.pending
    );
    Ok(())
}

async fn prune_command(args: PruneArgs, settings: &Settings) -> Result<(), CliError> {
    let db = Db::connect(&settings.admin_url()?).await?;
    let retention = Duration::from_secs(u64::from(args.older_than_days) * SECONDS_PER_DAY);
    let orgs = match args.org.as_deref() {
        Some(slug) => match orgs::resolve_org(&db, Some(slug)).await? {
            OrgChoice::Found(id) => vec![(id, slug.to_string())],
            _ => return Err(ConfigError::new("--org", "no org has that slug").into()),
        },
        None => orgs::list(&db).await?,
    };
    for (org_id, slug) in orgs {
        let horizon = b4hub_db::prune::prune(&db, org_id, retention).await?;
        println!(
            "pruned org {slug}: changes up to hubSeq {horizon} are gone ({} days kept)",
            args.older_than_days
        );
    }
    Ok(())
}

async fn seed_command(args: SeedArgs, settings: &Settings) -> Result<(), CliError> {
    let db = Db::connect(&settings.admin_url()?).await?;
    let outcome = b4hub_db::orgs::seed(
        &db,
        &args.org,
        &args.org_name,
        &args.user,
        &args.name,
        &args.email,
    )
    .await?;
    println!(
        "{} org {} ({}) user {} ({})",
        if outcome.created {
            "seeded"
        } else {
            "already present:"
        },
        args.org,
        outcome.org_id,
        args.user,
        outcome.user_id,
    );
    Ok(())
}

async fn enroll_command(args: EnrollArgs, settings: &Settings) -> Result<(), CliError> {
    let db = Db::connect(&settings.admin_url()?).await?;
    let code = issue_enrollment_code(&db, &args.user, args.org.as_deref()).await?;
    println!(
        "Enrollment code: {code} (expires in {} minutes)",
        ENROLLMENT_TTL.as_secs() / 60
    );
    Ok(())
}

/// Resolves the org (by `org`, or the only org when there is exactly one) and the user in it,
/// then mints a code for that user. A missing, unknown, or ambiguous org and an unknown user are
/// configuration errors naming the flag to fix.
pub async fn issue_enrollment_code(
    db: &Db,
    username: &str,
    org: Option<&str>,
) -> Result<String, CliError> {
    let org_id = match orgs::resolve_org(db, org).await? {
        OrgChoice::Found(id) => id,
        OrgChoice::UnknownSlug => {
            return Err(ConfigError::new("--org", "no org has that slug").into())
        }
        OrgChoice::Ambiguous => {
            return Err(ConfigError::new(
                "--org",
                "several orgs exist; pass --org <slug> to choose one",
            )
            .into())
        }
        OrgChoice::NoOrgs => {
            return Err(ConfigError::new("--org", "no org exists; run `b4hub seed` first").into())
        }
    };
    let user_id = orgs::find_user(db, org_id, username)
        .await?
        .ok_or_else(|| ConfigError::new("--user", "no such user in that org"))?;
    Ok(devices::create_enrollment_code(db, org_id, user_id, ENROLLMENT_TTL).await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(pairs: &[(&str, &str)]) -> Settings {
        Settings::from_pairs(pairs.iter().copied())
    }

    #[test]
    fn defaults() {
        let s = settings(&[]);
        assert_eq!(s.port().unwrap(), 8080);
        assert_eq!(s.shutdown_wait().unwrap(), Duration::from_millis(30_000));
        assert_eq!(s.public_url().unwrap(), None);
        assert_eq!(s.retention().unwrap(), Duration::from_secs(30 * 86_400));
        assert!(s.log_filter().is_ok());
    }

    #[test]
    fn retention_is_a_whole_number_of_days() {
        let days = |raw: &str| settings(&[("B4HUB_RETENTION_DAYS", raw)]).retention();
        assert_eq!(days("7").unwrap(), Duration::from_secs(7 * 86_400));
        for bad in ["0", "-3", "1.5", "thirty", "30d"] {
            let error = days(bad).unwrap_err();
            assert_eq!(error.name, "B4HUB_RETENTION_DAYS", "{bad}");
        }
        assert!(!days("thirty").unwrap_err().to_string().contains("thirty"));
    }

    #[tokio::test]
    async fn serve_with_a_bad_retention_is_a_configuration_error() {
        let cli = Cli::try_parse_from(["b4hub", "serve", "--bind", "127.0.0.1:0"]).unwrap();
        let settings = settings(&[
            ("DATABASE_URL", "postgres://b4hub_app:pw@127.0.0.1:1/none"),
            ("B4HUB_RETENTION_DAYS", "soon"),
        ]);
        let error = run(cli, &settings).await.unwrap_err();
        assert!(matches!(error, CliError::Config(_)), "{error}");
        assert_eq!(error.exit_code(), 2);
    }

    #[test]
    fn malformed_settings_name_themselves_and_not_their_value() {
        let e = settings(&[("B4HUB_PORT", "eighty")]).port().unwrap_err();
        assert_eq!(e.name, "B4HUB_PORT");
        assert!(!e.to_string().contains("eighty"));
        assert_eq!(
            settings(&[("B4HUB_PORT", "0")]).port().unwrap_err().name,
            "B4HUB_PORT"
        );
        assert_eq!(
            settings(&[("B4HUB_SHUTDOWN_WAIT_MS", "-1")])
                .shutdown_wait()
                .unwrap_err()
                .name,
            "B4HUB_SHUTDOWN_WAIT_MS"
        );
        assert_eq!(
            settings(&[("B4HUB_PUBLIC_URL", "ftp://hub")])
                .public_url()
                .unwrap_err()
                .name,
            "B4HUB_PUBLIC_URL"
        );
        assert_eq!(
            settings(&[("B4HUB_LOG", "info,=bad[")])
                .log_filter()
                .unwrap_err()
                .name,
            "B4HUB_LOG"
        );
    }

    #[test]
    fn database_urls_are_required_validated_and_never_echoed() {
        let missing = settings(&[]).database_url().unwrap_err();
        assert_eq!(missing.name, "DATABASE_URL");

        let bad = settings(&[("DATABASE_ADMIN_URL", "mysql://root:hunter2@host/db")])
            .admin_url()
            .unwrap_err();
        assert_eq!(bad.name, "DATABASE_ADMIN_URL");
        assert!(!bad.to_string().contains("hunter2"));

        let both = settings(&[
            ("DATABASE_URL", "postgres://h/d"),
            ("DATABASE_URL_FILE", "/x"),
        ])
        .database_url()
        .unwrap_err();
        assert!(both.reason.contains("both set"));
    }

    #[test]
    fn url_file_variant_is_read_and_trimmed() {
        let dir = std::env::temp_dir().join(format!("b4hub-cli-{}", b4hub_core::ids::new_uuid()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("url");
        std::fs::write(&path, "postgres://b4hub_app:pw@db/b4hub\n").unwrap();
        let s = settings(&[("DATABASE_URL_FILE", path.to_str().unwrap())]);
        assert_eq!(
            s.database_url().unwrap(),
            "postgres://b4hub_app:pw@db/b4hub"
        );

        let missing = settings(&[("DATABASE_URL_FILE", dir.join("nope").to_str().unwrap())])
            .database_url()
            .unwrap_err();
        assert_eq!(missing.name, "DATABASE_URL_FILE");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provisioning_url_must_be_b4hub_app_with_a_password() {
        let ok = settings(&[("DATABASE_URL", "postgres://b4hub_app:pw@db/b4hub")]);
        assert!(ok.provisioning_url().is_ok());

        for url in [
            "postgres://postgres:hunter2@db/b4hub",
            "postgres://b4hub_app@db/b4hub",
            "postgres://b4hub_app:@db/b4hub",
            "postgres://b4hub_app:p%C3%A9@db/b4hub",
        ] {
            let error = settings(&[("DATABASE_URL", url)])
                .provisioning_url()
                .unwrap_err();
            assert_eq!(error.name, "DATABASE_URL", "{url}");
            assert!(!error.to_string().contains("hunter2"));
        }
    }

    #[tokio::test]
    async fn migrate_with_a_bad_app_url_is_a_configuration_error_before_any_connection() {
        let cli = Cli::try_parse_from(["b4hub", "migrate"]).unwrap();
        let settings = settings(&[
            ("DATABASE_ADMIN_URL", "postgres://admin@127.0.0.1:1/none"),
            (
                "DATABASE_URL",
                "postgres://postgres:hunter2@127.0.0.1:1/none",
            ),
        ]);
        let error = run(cli, &settings).await.unwrap_err();
        assert!(matches!(error, CliError::Config(_)), "{error}");
        assert_eq!(error.exit_code(), 2);
        assert!(!error.to_string().contains("hunter2"));
    }

    #[test]
    fn config_errors_exit_2_and_everything_else_1() {
        let config = CliError::from(ConfigError::new("X", "bad"));
        assert_eq!(config.exit_code(), 2);
        let io = CliError::from(std::io::Error::other("boom"));
        assert_eq!(io.exit_code(), 1);
    }

    #[test]
    fn seed_arguments_are_validated() {
        assert!(parse_slug("acme-1").is_ok());
        assert!(parse_slug("Acme").is_err());
        assert!(parse_slug("-acme").is_err());
        assert!(parse_slug("").is_err());
        assert!(parse_email("brian@example.com").is_ok());
        assert!(parse_email("brian").is_err());
        assert!(parse_non_empty("  ").is_err());
    }
}
