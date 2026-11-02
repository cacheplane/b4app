//! Sending a notification to a phone (decision D-123). A [`PushSender`] takes one
//! [`Notification`] the hub decided on inside the push transaction; [`deliver`] runs the sends
//! after the commit on a task of their own, so a push never waits on, or fails because of, a
//! sender. Two senders exist: [`SpoolSender`] writes `.apns` files that `xcrun simctl push` reads
//! (the Simulator), and [`ApnsSender`], which is not built yet and says so rather than pretend.

use std::future::Future;
use std::io::Write;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use b4hub_core::push::spool_payload;
use b4hub_db::push::Notification;
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum PushError {
    #[error("push sender unsupported: {0}")]
    Unsupported(&'static str),
    #[error("spool write failed: {0}")]
    Io(#[from] std::io::Error),
}

/// Delivers one notification. An error is logged by [`deliver`] and not retried: the ledger has
/// already recorded the notification as sent, so delivery is at most once.
pub trait PushSender: Send + Sync {
    fn send<'a>(
        &'a self,
        message: &'a Notification,
    ) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>>;

    /// `spool` or `apns`, for the startup log.
    fn name(&self) -> &'static str;
}

/// Writes each notification as `<dir>/<unix ms>-<uuid>.apns`, the file `xcrun simctl push
/// booted - < file` reads, naming the app in its `Simulator Target Bundle` key. The file is
/// written under a hidden `.tmp` name and renamed when complete, so a watcher never reads half a
/// file.
#[derive(Debug)]
pub struct SpoolSender {
    dir: PathBuf,
}

impl SpoolSender {
    /// Creates `dir` (and its parents) when it does not exist.
    pub fn new(dir: PathBuf) -> Result<SpoolSender, PushError> {
        std::fs::create_dir_all(&dir)?;
        Ok(SpoolSender { dir })
    }
}

impl PushSender for SpoolSender {
    fn send<'a>(
        &'a self,
        message: &'a Notification,
    ) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>> {
        Box::pin(async move {
            let payload = spool_payload(
                &message.thread_id,
                &message.title,
                message.reason,
                &message.bundle_id,
            );
            let bytes = serde_json::to_vec_pretty(&payload).map_err(std::io::Error::from)?;
            let dir = self.dir.clone();
            tokio::task::spawn_blocking(move || write_spool_file(&dir, &bytes))
                .await
                .map_err(std::io::Error::other)??;
            Ok(())
        })
    }

    fn name(&self) -> &'static str {
        "spool"
    }
}

/// Writes `bytes` to a hidden temporary file in `dir`, then renames it to its `.apns` name. The
/// uuid is a v7 (the workspace enables only that generator), so names sort by creation time.
fn write_spool_file(dir: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let name = format!("{millis}-{}.apns", Uuid::now_v7());
    let temporary = dir.join(format!(".{name}.tmp"));
    let written = (|| {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()
    })();
    if let Err(error) = written {
        let _ = std::fs::remove_file(&temporary);
        return Err(error);
    }
    std::fs::rename(&temporary, dir.join(name)).inspect_err(|_| {
        let _ = std::fs::remove_file(&temporary);
    })
}

/// The real APNs sender. Not built yet (the deploy slice); it never pretends to send.
#[derive(Debug)]
pub struct ApnsSender;

const APNS_UNSUPPORTED: &str = "APNs delivery is not built yet (the deploy slice)";

impl ApnsSender {
    pub fn new() -> Result<ApnsSender, PushError> {
        Err(PushError::Unsupported(APNS_UNSUPPORTED))
    }
}

impl PushSender for ApnsSender {
    fn send<'a>(
        &'a self,
        _message: &'a Notification,
    ) -> Pin<Box<dyn Future<Output = Result<(), PushError>> + Send + 'a>> {
        Box::pin(async { Err(PushError::Unsupported(APNS_UNSUPPORTED)) })
    }

    fn name(&self) -> &'static str {
        "apns"
    }
}

/// Sends `notifications` in order on one spawned task and returns at once. A failure is logged
/// with the device and the reason, never the token or the title, and the rest still go out.
pub fn deliver(sender: Arc<dyn PushSender>, notifications: Vec<Notification>) {
    if notifications.is_empty() {
        return;
    }
    tokio::spawn(async move {
        for n in notifications {
            if let Err(error) = sender.send(&n).await {
                tracing::warn!(
                    device = %n.device_id,
                    reason = n.reason.as_str(),
                    %error,
                    "push delivery failed"
                );
            }
        }
    });
}
