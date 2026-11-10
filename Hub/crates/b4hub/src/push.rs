//! Sending to a phone (decisions D-123 and D-131 onward). A [`PushSender`] takes one [`Message`]
//! the hub decided on inside the push transaction: an alert, a silent mirror refresh, or a withdrawal of alerts
//! whose request was answered or whose turn was read. [`deliver`] runs the sends after the commit
//! on a task of their own, so a push never waits on, or fails because of, a sender, and deletes a
//! token Apple says is dead. Two senders exist: [`SpoolSender`] writes `.apns` files that `xcrun
//! simctl push` reads (the Simulator), and [`ApnsSender`] speaks HTTP/2 to Apple with an ES256
//! provider token.
//!
//! Nothing here logs or returns a device token, the private key, or a provider token.

use std::fmt;
use std::future::Future;
use std::io::Write;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use b4hub_core::push::{
    payload, refresh_payload, spool_payload, spool_refresh_payload, spool_withdrawal_payload,
    withdrawal_payload,
};
use b4hub_db::push::{Notification, Refresh, Withdrawal};
use b4hub_db::Db;
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use url::Url;
use uuid::Uuid;

/// One thing to send to one phone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// A visible notification.
    Alert(Notification),
    /// A background push naming the delivered notifications the app removes.
    Withdraw(Withdrawal),
    /// A silent hint that archive metadata changed and the mirror should catch up.
    Refresh(Refresh),
}

impl Message {
    pub fn device_id(&self) -> Uuid {
        match self {
            Message::Alert(n) => n.device_id,
            Message::Withdraw(w) => w.device_id,
            Message::Refresh(r) => r.device_id,
        }
    }

    /// The APNs device token. Never log it.
    pub fn token(&self) -> &str {
        match self {
            Message::Alert(n) => &n.token,
            Message::Withdraw(w) => &w.token,
            Message::Refresh(r) => &r.token,
        }
    }

    /// `sandbox` or `production`, the APNs environment the token belongs to.
    pub fn environment(&self) -> &str {
        match self {
            Message::Alert(n) => &n.environment,
            Message::Withdraw(w) => &w.environment,
            Message::Refresh(r) => &r.environment,
        }
    }

    /// The app's bundle id, the APNs topic.
    pub fn bundle_id(&self) -> &str {
        match self {
            Message::Alert(n) => &n.bundle_id,
            Message::Withdraw(w) => &w.bundle_id,
            Message::Refresh(r) => &r.bundle_id,
        }
    }

    /// The notification keys it carries, comma-separated, for the log.
    pub fn keys(&self) -> String {
        match self {
            Message::Alert(n) => n.key.clone(),
            Message::Withdraw(w) => w.keys.join(","),
            Message::Refresh(_) => String::new(),
        }
    }

    /// `alert`, `withdraw`, or `refresh`, for the log.
    pub fn kind(&self) -> &'static str {
        match self {
            Message::Alert(_) => "alert",
            Message::Withdraw(_) => "withdraw",
            Message::Refresh(_) => "refresh",
        }
    }
}

/// What became of a send that did not fail.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sent {
    Delivered,
    /// Apple says the token is no longer valid (the app was deleted, or the token belongs to
    /// another build); [`deliver`] deletes it.
    DeadToken,
}

#[derive(Debug, thiserror::Error)]
pub enum PushError {
    #[error("spool write failed: {0}")]
    Io(#[from] std::io::Error),
    /// The payload could not be serialized. It never holds the token, and the error's text is
    /// not shown.
    #[error("the push payload could not be serialized")]
    Encode,
    #[error("the APNs private key is not a P-256 private key")]
    BadKey,
    #[error("the APNs HTTP client could not be built")]
    Client,
    #[error("the push token's environment {0:?} is neither sandbox nor production")]
    Environment(String),
    /// Apple answered, and not with success. Its `reason` and `apns-id` are safe to log.
    #[error(
        "APNs refused it: status {status}, reason {}, apns-id {}",
        .reason.as_deref().unwrap_or("none"),
        .apns_id.as_deref().unwrap_or("none")
    )]
    Rejected {
        status: u16,
        reason: Option<String>,
        apns_id: Option<String>,
    },
    /// APNs could not be reached or did not answer in time. Never carries the URL, which holds
    /// the device token.
    #[error("APNs could not be reached: {0}")]
    Transport(&'static str),
}

/// Delivers one message. An error is logged by [`deliver`] and not retried there: the ledger has
/// already recorded the notification as sent, so delivery is at most once.
pub trait PushSender: Send + Sync {
    fn send<'a>(
        &'a self,
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, PushError>> + Send + 'a>>;

    /// `spool` or `apns`, for the startup log.
    fn name(&self) -> &'static str;
}

/// Writes each message as `<dir>/<unix ms>-<uuid>.apns`, the file `xcrun simctl push
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
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, PushError>> + Send + 'a>> {
        Box::pin(async move {
            let payload = match message {
                Message::Alert(n) => spool_payload(
                    &n.thread_id,
                    &n.title,
                    n.reason,
                    &n.key,
                    n.badge,
                    &n.bundle_id,
                ),
                Message::Withdraw(w) => spool_withdrawal_payload(&w.keys, &w.bundle_id),
                Message::Refresh(r) => spool_refresh_payload(&r.bundle_id),
            };
            let bytes = serde_json::to_vec_pretty(&payload).map_err(|_| PushError::Encode)?;
            let dir = self.dir.clone();
            tokio::task::spawn_blocking(move || write_spool_file(&dir, &bytes))
                .await
                .map_err(std::io::Error::other)??;
            Ok(Sent::Delivered)
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

/// Apple's endpoint for `sandbox` tokens (development builds and the Simulator).
pub const APNS_SANDBOX_URL: &str = "https://api.sandbox.push.apple.com/";
/// Apple's endpoint for `production` tokens (TestFlight and App Store builds).
pub const APNS_PRODUCTION_URL: &str = "https://api.push.apple.com/";

/// How long a provider token is reused. Apple refuses one older than an hour and rate-limits
/// minting more often than every 20 minutes.
const PROVIDER_TOKEN_REUSE_SECS: u64 = 50 * 60;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
/// The wait before the one retry of a 429, a 5xx, or a transport failure.
const RETRY_WAIT: Duration = Duration::from_millis(500);
/// How long Apple keeps trying an alert a phone cannot take yet: an approval stays useful for
/// hours.
const ALERT_LIFETIME_SECS: u64 = 4 * 60 * 60;
/// How long Apple keeps trying a withdrawal: past that the app's own clean-up after its next
/// sync has done the work.
const WITHDRAWAL_LIFETIME_SECS: u64 = 15 * 60;
/// Apple's limit on `apns-collapse-id`.
const MAX_COLLAPSE_ID_BYTES: usize = 64;

/// The APNs signing key: `B4HUB_APNS_KEY_ID`, `B4HUB_APNS_TEAM_ID`, and `B4HUB_APNS_PRIVATE_KEY`
/// (the `.p8` file's PEM contents). `Debug` leaves out the key.
#[derive(Clone, PartialEq, Eq)]
pub struct ApnsConfig {
    pub key_id: String,
    pub team_id: String,
    pub private_key_pem: String,
}

impl fmt::Debug for ApnsConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApnsConfig")
            .field("key_id", &self.key_id)
            .field("team_id", &self.team_id)
            .field("private_key_pem", &"<redacted>")
            .finish()
    }
}

/// The time in Unix seconds. [`ApnsSender::with_clock`] replaces it in tests.
pub type Clock = Arc<dyn Fn() -> u64 + Send + Sync>;

fn system_clock() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// One APNs endpoint and the client that keeps its HTTP/2 connection open between sends.
struct Endpoint {
    url: Url,
    http: reqwest::Client,
}

impl Endpoint {
    /// HTTP/2 over TLS (ALPN `h2`) for `https`; HTTP/2 with prior knowledge for `http`, which
    /// only a test's fake APNs uses.
    fn new(url: Url) -> Result<Endpoint, PushError> {
        let mut builder = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .http2_keep_alive_interval(Duration::from_secs(60))
            .http2_keep_alive_while_idle(true)
            .pool_idle_timeout(None);
        if url.scheme() == "http" {
            builder = builder.http2_prior_knowledge();
        }
        let http = builder.build().map_err(|_| PushError::Client)?;
        Ok(Endpoint { url, http })
    }
}

/// A minted provider token and when.
struct ProviderToken {
    jwt: String,
    minted_at: u64,
}

/// What Apple answered.
struct Answer {
    status: u16,
    reason: Option<String>,
    apns_id: Option<String>,
}

impl Answer {
    /// 410 (`Unregistered`, `ExpiredToken`), 400 `BadDeviceToken`, and 400
    /// `DeviceTokenNotForTopic`: the token will never work again for this topic.
    fn is_dead_token(&self) -> bool {
        self.status == 410
            || (self.status == 400
                && matches!(
                    self.reason.as_deref(),
                    Some("BadDeviceToken" | "DeviceTokenNotForTopic")
                ))
    }

    fn is_stale_provider_token(&self) -> bool {
        self.status == 403
            && matches!(
                self.reason.as_deref(),
                Some("ExpiredProviderToken" | "InvalidProviderToken")
            )
    }

    fn is_retryable(&self) -> bool {
        self.status == 429 || self.status >= 500
    }
}

#[derive(Deserialize)]
struct ReasonBody {
    reason: String,
}

#[derive(Serialize)]
struct ProviderClaims<'a> {
    iss: &'a str,
    iat: u64,
}

/// Sends through Apple Push Notification service: `sandbox` tokens to
/// [`APNS_SANDBOX_URL`], `production` tokens to [`APNS_PRODUCTION_URL`], authenticated by an ES256
/// provider token minted from the `.p8` key and reused for 50 minutes.
pub struct ApnsSender {
    sandbox: Endpoint,
    production: Endpoint,
    key_id: String,
    team_id: String,
    signing_key: EncodingKey,
    clock: Clock,
    provider_token: Mutex<Option<ProviderToken>>,
}

impl fmt::Debug for ApnsSender {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ApnsSender")
            .field("sandbox", &self.sandbox.url.as_str())
            .field("production", &self.production.url.as_str())
            .field("key_id", &self.key_id)
            .field("team_id", &self.team_id)
            .finish_non_exhaustive()
    }
}

impl ApnsSender {
    /// The sender for Apple's endpoints. A key that does not sign is [`PushError::BadKey`].
    pub fn new(config: ApnsConfig) -> Result<ApnsSender, PushError> {
        ApnsSender::with_endpoints(
            config,
            Url::parse(APNS_SANDBOX_URL).expect("the sandbox URL parses"),
            Url::parse(APNS_PRODUCTION_URL).expect("the production URL parses"),
        )
    }

    /// The sender with other endpoints, for tests.
    pub fn with_endpoints(
        config: ApnsConfig,
        sandbox: Url,
        production: Url,
    ) -> Result<ApnsSender, PushError> {
        let signing_key = EncodingKey::from_ec_pem(config.private_key_pem.as_bytes())
            .map_err(|_| PushError::BadKey)?;
        let sender = ApnsSender {
            sandbox: Endpoint::new(sandbox)?,
            production: Endpoint::new(production)?,
            key_id: config.key_id,
            team_id: config.team_id,
            signing_key,
            clock: Arc::new(system_clock),
            provider_token: Mutex::new(None),
        };
        // The PEM parses lazily; signing once proves the key is usable before `serve` starts.
        sender.mint(system_clock()).map_err(|_| PushError::BadKey)?;
        Ok(sender)
    }

    /// Replaces the clock the provider token and `apns-expiration` are read from, for tests.
    pub fn with_clock(mut self, clock: Clock) -> ApnsSender {
        self.clock = clock;
        self
    }

    fn mint(&self, now: u64) -> Result<String, PushError> {
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let claims = ProviderClaims {
            iss: &self.team_id,
            iat: now,
        };
        jsonwebtoken::encode(&header, &claims, &self.signing_key).map_err(|_| PushError::BadKey)
    }

    /// The cached provider token while it is younger than 50 minutes, or a new one. `refused`,
    /// the token Apple just refused as expired or invalid, is re-minted unless another send
    /// already replaced it.
    fn provider_token(&self, refused: Option<&str>) -> Result<String, PushError> {
        let now = (self.clock)();
        let mut cached = self
            .provider_token
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(token) = cached.as_ref() {
            let fresh = now.saturating_sub(token.minted_at) < PROVIDER_TOKEN_REUSE_SECS;
            if fresh && refused != Some(token.jwt.as_str()) {
                return Ok(token.jwt.clone());
            }
        }
        let jwt = self.mint(now)?;
        *cached = Some(ProviderToken {
            jwt: jwt.clone(),
            minted_at: now,
        });
        Ok(jwt)
    }

    fn endpoint(&self, environment: &str) -> Result<&Endpoint, PushError> {
        match environment {
            "sandbox" => Ok(&self.sandbox),
            "production" => Ok(&self.production),
            other => Err(PushError::Environment(other.to_string())),
        }
    }

    /// One POST to `/3/device/<token>`.
    async fn post(
        &self,
        endpoint: &Endpoint,
        message: &Message,
        jwt: &str,
        body: &[u8],
    ) -> Result<Answer, PushError> {
        let url = endpoint
            .url
            .join(&format!("3/device/{}", message.token()))
            .map_err(|_| PushError::Transport("the device URL could not be formed"))?;
        let mut authorization = reqwest::header::HeaderValue::try_from(format!("bearer {jwt}"))
            .map_err(|_| PushError::BadKey)?;
        // Kept out of any `Debug` of the request.
        authorization.set_sensitive(true);
        let now = (self.clock)();
        let (push_type, priority, lifetime) = match message {
            Message::Alert(_) => ("alert", "10", ALERT_LIFETIME_SECS),
            Message::Withdraw(_) | Message::Refresh(_) => {
                ("background", "5", WITHDRAWAL_LIFETIME_SECS)
            }
        };
        let mut request = endpoint
            .http
            .post(url)
            .header(reqwest::header::AUTHORIZATION, authorization)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header("apns-topic", message.bundle_id())
            .header("apns-push-type", push_type)
            .header("apns-priority", priority)
            .header("apns-expiration", (now + lifetime).to_string())
            .body(body.to_vec());
        if let Message::Alert(n) = message {
            // A resend under the same key replaces the notification rather than stacking.
            if n.key.len() <= MAX_COLLAPSE_ID_BYTES {
                request = request.header("apns-collapse-id", n.key.as_str());
            }
        } else if let Message::Refresh(_) = message {
            request = request.header("apns-collapse-id", "mirror-refresh");
        }
        let response = request.send().await.map_err(|error| {
            // `reqwest`'s error names the URL, which holds the token: only its kind is kept.
            PushError::Transport(if error.is_timeout() {
                "timed out"
            } else if error.is_connect() {
                "the connection failed"
            } else {
                "the request failed"
            })
        })?;
        let status = response.status().as_u16();
        let apns_id = response
            .headers()
            .get("apns-id")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let reason = match status {
            200 => None,
            _ => response
                .bytes()
                .await
                .ok()
                .and_then(|bytes| serde_json::from_slice::<ReasonBody>(&bytes).ok())
                .map(|body| body.reason),
        };
        Ok(Answer {
            status,
            reason,
            apns_id,
        })
    }
}

impl PushSender for ApnsSender {
    /// Sends `message` and reads Apple's answer: 200 is delivered; a dead token is
    /// [`Sent::DeadToken`]; an expired or invalid provider token is re-minted and the send tried
    /// once more; a 429, a 5xx, or a transport failure is tried once more after a short wait;
    /// anything else is [`PushError::Rejected`].
    fn send<'a>(
        &'a self,
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, PushError>> + Send + 'a>> {
        Box::pin(async move {
            let endpoint = self.endpoint(message.environment())?;
            let body = match message {
                Message::Alert(n) => payload(&n.thread_id, &n.title, n.reason, &n.key, n.badge),
                Message::Withdraw(w) => withdrawal_payload(&w.keys),
                Message::Refresh(_) => refresh_payload(),
            };
            let body = serde_json::to_vec(&body).map_err(|_| PushError::Encode)?;
            let mut jwt = self.provider_token(None)?;
            let (mut reminted, mut retried) = (false, false);
            loop {
                match self.post(endpoint, message, &jwt, &body).await {
                    Ok(answer) if answer.status == 200 => {
                        tracing::info!(
                            device = %message.device_id(),
                            kind = message.kind(),
                            keys = %message.keys(),
                            status = answer.status,
                            apns_id = answer.apns_id.as_deref().unwrap_or("none"),
                            "APNs accepted"
                        );
                        return Ok(Sent::Delivered);
                    }
                    Ok(answer) if answer.is_dead_token() => return Ok(Sent::DeadToken),
                    Ok(answer) if answer.is_stale_provider_token() && !reminted => {
                        reminted = true;
                        jwt = self.provider_token(Some(&jwt))?;
                    }
                    Ok(answer) if answer.is_retryable() && !retried => {
                        retried = true;
                        tokio::time::sleep(RETRY_WAIT).await;
                    }
                    Ok(answer) => {
                        return Err(PushError::Rejected {
                            status: answer.status,
                            reason: answer.reason,
                            apns_id: answer.apns_id,
                        })
                    }
                    Err(PushError::Transport(_)) if !retried => {
                        retried = true;
                        tokio::time::sleep(RETRY_WAIT).await;
                    }
                    Err(error) => return Err(error),
                }
            }
        })
    }

    fn name(&self) -> &'static str {
        "apns"
    }
}

/// Sends `messages` in order on one spawned task and returns at once. A dead token is deleted
/// from `org_id`'s push tokens (only if the phone has not saved a newer one meanwhile). A failure
/// is logged with the device, the notification keys, and Apple's status, reason, and `apns-id`,
/// never the token or the title, and the rest still go out.
pub fn deliver(sender: Arc<dyn PushSender>, db: Db, org_id: Uuid, messages: Vec<Message>) {
    if messages.is_empty() {
        return;
    }
    tokio::spawn(async move {
        for message in messages {
            let device = message.device_id();
            match sender.send(&message).await {
                Ok(Sent::Delivered) => {}
                Ok(Sent::DeadToken) => {
                    let deleted =
                        b4hub_db::push::delete_token(&db, org_id, device, message.token()).await;
                    match deleted {
                        Ok(()) => tracing::info!(
                            %device,
                            kind = message.kind(),
                            keys = %message.keys(),
                            "push token no longer valid; deleted"
                        ),
                        Err(error) => tracing::warn!(
                            %device,
                            %error,
                            "push token no longer valid; deleting it failed"
                        ),
                    }
                }
                Err(PushError::Rejected {
                    status,
                    reason,
                    apns_id,
                }) => tracing::warn!(
                    %device,
                    kind = message.kind(),
                    keys = %message.keys(),
                    status,
                    reason = reason.as_deref().unwrap_or("none"),
                    apns_id = apns_id.as_deref().unwrap_or("none"),
                    "push delivery failed"
                ),
                Err(error) => tracing::warn!(
                    %device,
                    kind = message.kind(),
                    keys = %message.keys(),
                    %error,
                    "push delivery failed"
                ),
            }
        }
    });
}
