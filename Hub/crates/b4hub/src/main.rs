use std::process::ExitCode;

use b4hub::cli::{self, Cli, ConfigError, Settings};
use clap::Parser;
use tracing_subscriber::util::SubscriberInitExt;

#[tokio::main]
async fn main() -> ExitCode {
    // clap exits 2 on a usage error and prints --help / --version itself.
    let cli = Cli::parse();
    let settings = Settings::from_env();

    let filter = match settings.log_filter() {
        Ok(filter) => filter,
        Err(error) => return config_failure(&error),
    };
    b4hub::logging::subscriber(filter, std::io::stderr).init();

    match cli::run(cli, &settings).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("b4hub: {error}");
            ExitCode::from(error.exit_code())
        }
    }
}

fn config_failure(error: &ConfigError) -> ExitCode {
    eprintln!("b4hub: configuration error: {error}");
    ExitCode::from(2)
}
