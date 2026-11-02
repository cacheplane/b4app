//! Helpers for the relay tests: a hub on a real loopback listener, enrolled devices, and fake
//! Macs and phones that speak the link protocol over `tokio-tungstenite`. Included from
//! `tests/relay.rs` with `mod relay_support;` (and from the later relay test files the same way).
//!
//! # Paused time
//!
//! Time-dependent tests call [`pause_clock`]. A paused tokio clock normally jumps forward on its
//! own whenever the runtime is idle, and "idle" includes waiting on the database or a socket, so
//! a pending 30 second timer would fire during any query. [`PausedClock`] therefore also parks a
//! `spawn_blocking` task, which stops that automatic jump on the current-thread runtime that
//! `#[sqlx::test]` uses: from then on time moves only through [`PausedClock::advance`]. Waiting
//! for the hub to react to an event must then use real time, which is what [`FakeDevice::next`],
//! [`eventually`], and [`settle`] do (a timer thread, not a tokio timer).
#![allow(dead_code)] // Later relay tests use more of this than the first does.

use std::future::Future;
use std::net::SocketAddr;
use std::time::Duration;

use axum::body::{to_bytes, Body};
use axum::http::{header, Request, StatusCode};
use b4hub::relay::{Relay, SendError, WallClock};
use b4hub::serve::{self, AppState};
use b4hub_core::relay::{RelayMessage, RelayMethod, WireError};
use b4hub_db::{devices, orgs, Db};
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use sqlx::types::Uuid;
use sqlx::PgPool;
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use tower::ServiceExt;
use url::Url;

/// How long a test waits for a frame the hub should send.
pub const FRAME_WAIT: Duration = Duration::from_secs(2);

// ---- real time -----------------------------------------------------------------------------

/// Sleeps for `duration` of real time, whatever state the tokio clock is in.
pub async fn real_sleep(duration: Duration) {
    let (done, wait) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        std::thread::sleep(duration);
        let _ = done.send(());
    });
    let _ = wait.await;
}

/// Lets the hub's tasks run to completion of whatever they are doing, in real time.
pub async fn settle() {
    real_sleep(Duration::from_millis(100)).await;
}

/// Polls `check` every 25 ms of real time until it returns `Some`, for up to five seconds.
pub async fn eventually<T, F, Fut>(what: &str, mut check: F) -> T
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Option<T>>,
{
    for _ in 0..200 {
        if let Some(found) = check().await {
            return found;
        }
        real_sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out waiting for {what}");
}

/// A paused tokio clock that moves only through [`PausedClock::advance`]. See the module docs.
pub struct PausedClock {
    _release: std::sync::mpsc::Sender<()>,
}

pub fn pause_clock() -> PausedClock {
    tokio::time::pause();
    let (release, parked) = std::sync::mpsc::channel::<()>();
    tokio::task::spawn_blocking(move || {
        // Returns when the guard (the sender) is dropped.
        let _ = parked.recv();
    });
    PausedClock { _release: release }
}

impl PausedClock {
    /// Moves the clock forward by `by` in steps of at most 10 seconds, with every device in
    /// `alive` pinging after each step, so none of them is closed as silent. Fails the test if one
    /// of them receives anything but its `pong` (or a `presence`).
    pub async fn advance_alive(&self, by: Duration, alive: &mut [&mut FakeDevice]) {
        let step = Duration::from_secs(10);
        let mut left = by;
        while !left.is_zero() {
            let now = left.min(step);
            self.advance(now).await;
            left -= now;
            for device in alive.iter_mut() {
                device.ping().await;
            }
        }
    }

    /// Moves the clock forward by `by`, after letting the hub finish what it is doing so a
    /// database call in flight does not straddle the jump.
    pub async fn advance(&self, by: Duration) {
        settle().await;
        tokio::time::advance(by).await;
    }
}

/// Fills `device_id`'s outbound queue and keeps it full: queues 16 KiB `event` frames until the
/// device's socket stops taking them (the device is not reading) and the queue stays full across
/// two pauses of real time. The device later reads them as `event` frames.
pub async fn fill_queue(relay: &Relay, device_id: Uuid) {
    let frame = RelayMessage::Event {
        event: serde_json::json!({ "kind": "padding", "pad": "x".repeat(16 * 1024) }),
    };
    let still_full = || relay.send(device_id, frame.clone()) == Err(SendError::Full);
    assert!(relay.online(device_id), "the device has no link");
    for _ in 0..200 {
        // Fill the queue in one go (the link task cannot run meanwhile), then give the link a
        // moment: if it could not drain a single frame, twice, its socket is blocked.
        while relay.send(device_id, frame.clone()).is_ok() {}
        real_sleep(Duration::from_millis(200)).await;
        if still_full() {
            real_sleep(Duration::from_millis(200)).await;
            if still_full() {
                return;
            }
        }
    }
    panic!("the queue never stayed full");
}

// ---- the hub ---------------------------------------------------------------------------------

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

/// A migrated database, the owner handle (for seeding), and the app state (as `b4hub_app`).
pub async fn migrated(pool: &PgPool) -> (Db, AppState) {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(pool)).await.unwrap();
    let app = Db::connect(&app_url(pool)).await.unwrap();
    (admin, AppState::new(app))
}

/// A user the tests seeded.
#[derive(Debug, Clone, Copy)]
pub struct Seeded {
    pub org_id: Uuid,
    pub user_id: Uuid,
}

/// A running hub on `127.0.0.1`, served by `serve::run` as `b4hub serve` does.
pub struct Hub {
    pub admin: Db,
    pub state: AppState,
    pub addr: SocketAddr,
    /// The server task; it finishes after `state.shutdown.trigger()` once its links are closed.
    pub server: JoinHandle<std::io::Result<()>>,
}

/// Migrates the database, opens a loopback listener, and serves the hub on it, on the real
/// system clock. The shutdown wait is five seconds. Trigger shutdown with
/// `hub.state.shutdown.trigger()`.
pub async fn spawn_hub(pool: &PgPool) -> Hub {
    spawn_hub_with_clock(pool, WallClock::system()).await
}

/// Like [`spawn_hub`], for a test that pauses the tokio clock with [`pause_clock`]: the hub's wall
/// time (`hubTime`, `last_seen_at`) is anchored to the tokio clock, so it moves when the test
/// advances it.
pub async fn spawn_hub_paused(pool: &PgPool) -> Hub {
    spawn_hub_with_clock(pool, WallClock::anchored_to_tokio()).await
}

pub async fn spawn_hub_with_clock(pool: &PgPool, clock: WallClock) -> Hub {
    let (admin, mut state) = migrated(pool).await;
    state.relay = Relay::with_clock(clock);
    // Open several connections now: a pool that must connect lazily while a test's clock is
    // paused would otherwise race its own acquire timeout.
    let mut warm = Vec::new();
    for _ in 0..4 {
        warm.push(state.db.pool.acquire().await.unwrap());
    }
    drop(warm);

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let mut stopping = state.shutdown.subscribe();
    let signal = async move {
        let _ = stopping.wait_for(|down| *down).await;
    };
    let server = tokio::spawn(serve::run(
        listener,
        state.clone(),
        Duration::from_secs(5),
        signal,
    ));
    Hub {
        admin,
        state,
        addr,
        server,
    }
}

impl Drop for Hub {
    /// Stops the listener, so its copy of the app state (and the database connections in it) is
    /// gone by the time `#[sqlx::test]` drops the test database.
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl Hub {
    /// Ensures `username` exists in the org `org_slug` (created if needed).
    pub async fn user(&self, org_slug: &str, username: &str) -> Seeded {
        let seeded = orgs::seed(
            &self.admin,
            org_slug,
            org_slug,
            username,
            username,
            &format!("{username}@example.test"),
        )
        .await
        .unwrap();
        Seeded {
            org_id: seeded.org_id,
            user_id: seeded.user_id,
        }
    }

    /// Enrolls a device of `platform` (`macos`, `ios` or `cli`) for `who`; returns its token and
    /// id.
    pub async fn enroll(&self, who: &Seeded, platform: &str, name: &str) -> (String, Uuid) {
        let code = devices::create_enrollment_code(
            &self.admin,
            who.org_id,
            who.user_id,
            Duration::from_secs(600),
        )
        .await
        .unwrap();
        let enrolled = devices::redeem(&self.state.db, &code, name, platform)
            .await
            .unwrap();
        (enrolled.token, enrolled.device_id)
    }

    /// One HTTP request, in process, through the same router and state the listener serves.
    pub async fn http(&self, method: &str, path: &str, token: Option<&str>) -> (StatusCode, Value) {
        let mut request = Request::builder().method(method).uri(path);
        if let Some(token) = token {
            request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }
        let response = serve::router(self.state.clone())
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).expect("a JSON body")
        };
        (status, body)
    }

    /// Inserts, as the owner, the thread `thread_id` of `who`, owned by `owner` (as if `owner`
    /// had pushed it).
    pub async fn seed_thread(&self, who: &Seeded, owner: Uuid, thread_id: &str) {
        self.seed(
            "INSERT INTO \"threads\" (\"id\", org_id, user_id, device_id, owner_device_id) \
             VALUES ($4, $1, $2, $3, $3)",
            who,
            owner,
            &[thread_id],
        )
        .await;
    }

    /// Inserts the runtime request `request_id` on `thread_id`, in `state`.
    pub async fn seed_request(
        &self,
        who: &Seeded,
        owner: Uuid,
        request_id: &str,
        thread_id: &str,
        state: &str,
    ) {
        self.seed(
            "INSERT INTO \"runtimeRequests\" (\"id\", \"threadId\", \"state\", org_id, user_id, \
             device_id, owner_device_id) VALUES ($4, $5, $6, $1, $2, $3, $3)",
            who,
            owner,
            &[request_id, thread_id, state],
        )
        .await;
    }

    /// Inserts the project `project_id`.
    pub async fn seed_project(&self, who: &Seeded, owner: Uuid, project_id: &str) {
        self.seed(
            "INSERT INTO \"projects\" (\"id\", org_id, user_id, device_id, owner_device_id) \
             VALUES ($4, $1, $2, $3, $3)",
            who,
            owner,
            &[project_id],
        )
        .await;
    }

    async fn seed(&self, statement: &str, who: &Seeded, owner: Uuid, text: &[&str]) {
        let mut query = sqlx::query(statement)
            .bind(who.org_id)
            .bind(who.user_id)
            .bind(owner);
        for value in text {
            query = query.bind(*value);
        }
        query.execute(&self.admin.pool).await.unwrap();
    }

    /// `devices.last_seen_at` of `device_id` as seconds since the epoch.
    pub async fn last_seen(&self, who: &Seeded, device_id: Uuid) -> Option<f64> {
        let mut tx = self.state.db.tenant_tx(who.org_id).await.unwrap();
        let seen: Option<f64> = sqlx::query_scalar(
            "SELECT extract(epoch FROM last_seen_at)::float8 FROM devices WHERE id = $1",
        )
        .bind(device_id)
        .fetch_one(&mut *tx)
        .await
        .unwrap();
        tx.commit().await.unwrap();
        seen
    }
}

// ---- fake devices ----------------------------------------------------------------------------

/// Why the hub refused an upgrade: the HTTP status and JSON body it answered instead.
#[derive(Debug)]
pub struct Refused {
    pub status: u16,
    pub body: Value,
}

impl Refused {
    /// `error.details.code` of the body.
    pub fn code(&self) -> &str {
        self.body["error"]["details"]["code"]
            .as_str()
            .unwrap_or_default()
    }
}

/// A fake Mac or phone: a WebSocket client of the link. Its methods fail the test on anything
/// unexpected, so a test reads as the conversation it checks.
pub struct FakeDevice {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

impl FakeDevice {
    /// Opens a link with `token`; fails the test if the hub refuses.
    pub async fn connect(addr: SocketAddr, token: &str) -> FakeDevice {
        FakeDevice::try_connect(addr, Some(token), None)
            .await
            .unwrap_or_else(|refused| panic!("the hub refused the upgrade: {refused:?}"))
    }

    /// Opens a link, with `protocol` as the `B4-Protocol` header when given.
    pub async fn try_connect(
        addr: SocketAddr,
        token: Option<&str>,
        protocol: Option<&str>,
    ) -> Result<FakeDevice, Refused> {
        let mut request = format!("ws://{addr}/v1/devices/self/link")
            .into_client_request()
            .unwrap();
        if let Some(token) = token {
            request.headers_mut().insert(
                header::AUTHORIZATION,
                format!("Bearer {token}").parse().unwrap(),
            );
        }
        if let Some(protocol) = protocol {
            request
                .headers_mut()
                .insert("B4-Protocol", protocol.parse().unwrap());
        }
        match connect_async(request).await {
            Ok((ws, _)) => Ok(FakeDevice { ws }),
            Err(tungstenite::Error::Http(response)) => Err(Refused {
                status: response.status().as_u16(),
                body: response
                    .body()
                    .as_deref()
                    .map(|bytes| serde_json::from_slice(bytes).expect("a JSON error body"))
                    .unwrap_or(Value::Null),
            }),
            Err(other) => panic!("could not connect: {other}"),
        }
    }

    /// Sends one frame.
    pub async fn send(&mut self, message: &RelayMessage) {
        self.send_text(&serde_json::to_string(message).unwrap())
            .await;
    }

    /// Sends `text` as one text frame, valid or not.
    pub async fn send_text(&mut self, text: &str) {
        self.ws
            .send(Message::Text(text.to_string().into()))
            .await
            .expect("the link accepts a frame");
    }

    /// The next message, with `wait` of real time to arrive. `None` on a timeout.
    async fn next_message(
        &mut self,
        wait: Duration,
    ) -> Option<Option<Result<Message, tungstenite::Error>>> {
        tokio::select! {
            message = self.ws.next() => Some(message),
            () = real_sleep(wait) => None,
        }
    }

    /// The next frame from the hub. Fails the test if none arrives within [`FRAME_WAIT`] or the
    /// link closes first.
    pub async fn next(&mut self) -> RelayMessage {
        loop {
            match self.next_message(FRAME_WAIT).await {
                None => panic!("no frame within {FRAME_WAIT:?}"),
                Some(Some(Ok(Message::Text(text)))) => {
                    return serde_json::from_str(text.as_str())
                        .unwrap_or_else(|error| panic!("not a relay frame ({error}): {text}"));
                }
                Some(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => {}
                Some(Some(Ok(Message::Close(frame)))) => {
                    panic!("the hub closed the link: {frame:?}")
                }
                Some(other) => panic!("the link ended: {other:?}"),
            }
        }
    }

    /// The next frame if one arrives within `wait` of real time; `None` if none does. Fails the
    /// test if the link closes meanwhile.
    pub async fn next_within(&mut self, wait: Duration) -> Option<RelayMessage> {
        loop {
            match self.next_message(wait).await? {
                Some(Ok(Message::Text(text))) => {
                    return Some(serde_json::from_str(text.as_str()).expect("a relay frame"));
                }
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                other => panic!("the link ended: {other:?}"),
            }
        }
    }

    /// Fails the test if any frame arrives within `wait` of real time.
    pub async fn expect_no_frame(&mut self, wait: Duration) {
        if let Some(frame) = self.next_within(wait).await {
            panic!("expected silence, got {frame:?}");
        }
    }

    /// Waits for the hub to close the link and returns its close code (1005 when the close
    /// frame names none). Frames that arrive before the close are skipped.
    pub async fn expect_close(&mut self) -> u16 {
        loop {
            match self.next_message(FRAME_WAIT).await {
                None => panic!("the link was not closed within {FRAME_WAIT:?}"),
                Some(Some(Ok(Message::Close(frame)))) => {
                    // Send our half of the close handshake now, not when the test next polls.
                    let _ = self.ws.flush().await;
                    return frame.map_or(1005, |frame| u16::from(frame.code));
                }
                Some(Some(Ok(_))) => {}
                // The hub dropped the connection without a close frame.
                Some(_) => return 1006,
            }
        }
    }

    /// Opens a link and reads its `hello` (returning its `hubTime`) and, for a client, the
    /// `presence` frame after it.
    pub async fn ready(addr: SocketAddr, token: &str) -> (FakeDevice, String) {
        let mut device = FakeDevice::connect(addr, token).await;
        let RelayMessage::Hello { hub_time, role, .. } = device.next().await else {
            panic!("expected hello");
        };
        if role == b4hub_core::relay::Role::Client {
            assert!(matches!(device.next().await, RelayMessage::Presence { .. }));
        }
        (device, hub_time)
    }

    /// Sends a `command` as a client does: `id`, `method`, and `params` only.
    pub async fn command(&mut self, id: &str, method: RelayMethod, params: Value) {
        self.send(&RelayMessage::Command {
            id: id.to_string(),
            method,
            params,
            deadline: None,
            from: None,
        })
        .await;
    }

    /// Sends a host's successful `reply`.
    pub async fn reply(&mut self, id: &str, result: Value) {
        self.send(&RelayMessage::Reply {
            id: id.to_string(),
            result: Some(result),
            error: None,
        })
        .await;
    }

    /// The next frame that is not a `pong` or a `presence`. Fails the test if none arrives within
    /// [`FRAME_WAIT`].
    pub async fn next_skipping_chatter(&mut self) -> RelayMessage {
        loop {
            match self.next().await {
                RelayMessage::Pong { .. } | RelayMessage::Presence { .. } => {}
                other => return other,
            }
        }
    }

    /// Like [`FakeDevice::next_skipping_chatter`], with `wait` of real time; `None` if nothing
    /// else arrives.
    pub async fn next_skipping_chatter_within(&mut self, wait: Duration) -> Option<RelayMessage> {
        loop {
            match self.next_within(wait).await? {
                RelayMessage::Pong { .. } | RelayMessage::Presence { .. } => {}
                other => return Some(other),
            }
        }
    }

    /// Fails the test if a frame other than `pong` or `presence` arrives within `wait`.
    pub async fn expect_quiet(&mut self, wait: Duration) {
        if let Some(frame) = self.next_skipping_chatter_within(wait).await {
            panic!("expected nothing, got {frame:?}");
        }
    }

    /// The next `command` frame: `(id, method, params, deadline, from)`.
    pub async fn expect_command(
        &mut self,
    ) -> (
        String,
        RelayMethod,
        Value,
        Option<String>,
        Option<b4hub_core::relay::From>,
    ) {
        match self.next_skipping_chatter().await {
            RelayMessage::Command {
                id,
                method,
                params,
                deadline,
                from,
            } => (id, method, params, deadline, from),
            other => panic!("expected a command, got {other:?}"),
        }
    }

    /// The next `reply` frame: `(id, result, error)`.
    pub async fn expect_reply(&mut self) -> (String, Option<Value>, Option<WireError>) {
        match self.next_skipping_chatter().await {
            RelayMessage::Reply { id, result, error } => (id, result, error),
            other => panic!("expected a reply, got {other:?}"),
        }
    }

    /// The next `reply`, which must be an error: `(id, error)`.
    pub async fn expect_refusal(&mut self) -> (String, WireError) {
        let (id, result, error) = self.expect_reply().await;
        assert!(result.is_none(), "expected an error, got {result:?}");
        (id, error.expect("a reply carries a result or an error"))
    }

    /// Sends `ping` and waits for its `pong`, failing the test if any other frame comes first.
    pub async fn ping(&mut self) -> String {
        self.send(&RelayMessage::Ping).await;
        loop {
            match self.next().await {
                RelayMessage::Pong { hub_time } => return hub_time,
                RelayMessage::Presence { .. } => {}
                other => panic!("expected pong, got {other:?}"),
            }
        }
    }

    /// Closes the link from this end, politely.
    pub async fn close(mut self) {
        let _ = self.ws.close(None).await;
    }
}

/// `rfc3339` (`2026-11-01T09:30:00.123Z`, with any number of fractional digits) as seconds since
/// the epoch.
pub fn epoch_seconds(rfc3339: &str) -> f64 {
    let (date, time) = rfc3339.trim_end_matches('Z').split_once('T').unwrap();
    let mut date = date.split('-').map(|part| part.parse::<i64>().unwrap());
    let (year, month, day) = (
        date.next().unwrap(),
        date.next().unwrap(),
        date.next().unwrap(),
    );
    let mut clock = time.split(':');
    let hours: f64 = clock.next().unwrap().parse().unwrap();
    let minutes: f64 = clock.next().unwrap().parse().unwrap();
    let seconds: f64 = clock.next().unwrap().parse().unwrap();
    // Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let day_of_year = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    days as f64 * 86_400.0 + hours * 3_600.0 + minutes * 60.0 + seconds
}
