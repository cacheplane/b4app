//! The hub's log subscriber: `B4HUB_LOG`'s filter, plus a second, fixed filter that drops every
//! event and span from webauthn-rs (`webauthn_rs`, `webauthn_rs_core`, `webauthn_attestation_ca`
//! and their modules), which log whole WebAuthn responses and challenges at DEBUG and TRACE.
//!
//! The second filter is a separate layer rather than a directive in the first, because an
//! `EnvFilter` ranks a longer target first: `webauthn_rs_core::core=trace` would outrank any
//! `webauthn_rs_core=off` added to it. A layer that says no disables the callsite whatever the
//! `EnvFilter` allows.

use tracing::{Metadata, Subscriber};
use tracing_subscriber::filter::{filter_fn, EnvFilter};
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::layer::SubscriberExt;

use crate::cli::LogFormat;

/// Whether events and spans with this metadata may be logged at all: nothing from a target
/// that starts with `webauthn`.
pub fn may_log(metadata: &Metadata<'_>) -> bool {
    !metadata.target().starts_with("webauthn")
}

/// The subscriber `main` installs: `filter`, the fixed webauthn filter, and a `format` formatter
/// writing to `writer`.
pub fn subscriber<W>(
    filter: EnvFilter,
    format: LogFormat,
    writer: W,
) -> Box<dyn Subscriber + Send + Sync>
where
    W: for<'w> MakeWriter<'w> + Send + Sync + 'static,
{
    let registry = tracing_subscriber::registry()
        .with(filter)
        .with(filter_fn(may_log));
    match format {
        LogFormat::Text => {
            Box::new(registry.with(tracing_subscriber::fmt::layer().with_writer(writer)))
        }
        // One object per line; the `request` span's fields (`request_id`, `method`, `path`,
        // `device_id`) ride on every event under `span`, and the event's own fields are top-level.
        // Only the innermost span is named: an event inside a further span (a future
        // `#[instrument]`) would lose `request_id` unless `with_span_list(true)` is switched on.
        LogFormat::Json => Box::new(
            registry.with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .flatten_event(true)
                    .with_current_span(true)
                    .with_span_list(false)
                    .with_writer(writer),
            ),
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    use tracing::Level;

    use super::*;
    use crate::cli::Settings;

    #[derive(Clone, Default)]
    struct Captured(Arc<Mutex<Vec<u8>>>);

    impl Write for Captured {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    impl<'a> MakeWriter<'a> for Captured {
        type Writer = Captured;

        fn make_writer(&'a self) -> Captured {
            self.clone()
        }
    }

    #[test]
    fn module_qualified_directives_cannot_reenable_webauthn() {
        for format in [LogFormat::Text, LogFormat::Json] {
            assert_drops_webauthn(format);
        }
    }

    fn assert_drops_webauthn(format: LogFormat) {
        let filter = Settings::from_pairs([(
            "B4HUB_LOG",
            "info,webauthn_rs_core::core=trace,webauthn_rs::interface=trace,\
             webauthn_rs=trace,webauthn_attestation_ca=trace",
        )])
        .log_filter()
        .unwrap();
        let captured = Captured::default();
        tracing::subscriber::with_default(subscriber(filter, format, captured.clone()), || {
            tracing::event!(target: "webauthn_rs_core::core", Level::TRACE, "leak-core-trace");
            tracing::event!(target: "webauthn_rs_core::core", Level::ERROR, "leak-core-error");
            tracing::event!(target: "webauthn_rs_core", Level::DEBUG, "leak-core-debug");
            tracing::event!(target: "webauthn_rs::interface", Level::TRACE, "leak-rs-trace");
            tracing::event!(target: "webauthn_rs", Level::INFO, "leak-rs-info");
            tracing::event!(
                target: "webauthn_attestation_ca",
                Level::TRACE,
                "leak-ca-trace"
            );
            tracing::event!(target: "b4hub::routes::auth", Level::INFO, "kept-canary");
            tracing::event!(target: "webauth", Level::INFO, "kept-near-miss");
        });
        let text = String::from_utf8_lossy(&captured.0.lock().unwrap()).into_owned();
        assert!(text.contains("kept-canary"), "the capture works: {text}");
        assert!(text.contains("kept-near-miss"), "{text}");
        assert!(!text.contains("leak-"), "{text}");
    }
}
