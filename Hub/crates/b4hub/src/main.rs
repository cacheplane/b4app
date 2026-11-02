use std::io::IsTerminal;
use std::process::ExitCode;

use b4hub::cli::{self, Cli, ConfigError, LogFormat, Settings};
use clap::Parser;

#[tokio::main]
async fn main() -> ExitCode {
    // clap exits 2 on a usage error and prints --help / --version itself.
    let cli = Cli::parse();
    let settings = Settings::from_env();

    let filter = match settings.log_filter() {
        Ok(filter) => filter,
        Err(error) => return config_failure(&error),
    };
    let format = match settings.log_format(std::io::stderr().is_terminal()) {
        Ok(format) => format,
        Err(error) => return config_failure(&error),
    };
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr);
    match format {
        LogFormat::Text => subscriber.init(),
        // One object per line; the `request` span's fields (`request_id`, `method`, `path`,
        // `device_id`) ride on every event under `span`, and the event's own fields are top-level.
        LogFormat::Json => subscriber
            .json()
            .flatten_event(true)
            .with_current_span(true)
            .with_span_list(false)
            .init(),
    }

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
