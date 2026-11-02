//! Per-IP rate limits for the sign-in routes: a fixed one-minute window per client address, in
//! memory per process (a hub with several replicas lets a client through once per replica).
//!
//! The client is the TCP peer, or, with `B4HUB_TRUST_X_FORWARDED_FOR=1`, the right-most
//! `X-Forwarded-For` entry: the one the hub's own proxy appended, which a client cannot forge.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::{ConnectInfo, FromRequestParts};
use axum::http::request::Parts;
use axum::http::HeaderMap;

use crate::error::ApiError;
use crate::serve::AppState;

/// The window every limit counts in.
pub const WINDOW: Duration = Duration::from_secs(60);

/// Requests per client per window to a `begin` route.
pub const BEGIN_PER_MINUTE: u32 = 20;

/// Requests per client per window to a `finish` route.
pub const FINISH_PER_MINUTE: u32 = 10;

/// Above this many tracked clients, windows that have ended are swept on the next check.
const SWEEP_ABOVE: usize = 10_000;

/// One limit: at most `limit` requests per client in each window.
#[derive(Debug)]
pub struct RateLimiter {
    limit: u32,
    window: Duration,
    windows: Mutex<HashMap<IpAddr, (Instant, u32)>>,
}

impl RateLimiter {
    pub fn new(limit: u32, window: Duration) -> RateLimiter {
        RateLimiter {
            limit,
            window,
            windows: Mutex::new(HashMap::new()),
        }
    }

    /// Counts a request from `client` at `now`. `Err` holds how long until its window ends, when
    /// the client has used up this window.
    pub fn check(&self, client: IpAddr, now: Instant) -> Result<(), Duration> {
        let mut windows = self
            .windows
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if windows.len() > SWEEP_ABOVE {
            let window = self.window;
            windows.retain(|_, (start, _)| now.saturating_duration_since(*start) < window);
        }
        let (start, count) = windows.entry(client).or_insert((now, 0));
        if now.saturating_duration_since(*start) >= self.window {
            *start = now;
            *count = 0;
        }
        if *count >= self.limit {
            return Err(self
                .window
                .saturating_sub(now.saturating_duration_since(*start)));
        }
        *count += 1;
        Ok(())
    }
}

/// The sign-in routes' limits. Cheap to clone.
#[derive(Clone, Debug)]
pub struct AuthLimits {
    pub begin: Arc<RateLimiter>,
    pub finish: Arc<RateLimiter>,
}

impl Default for AuthLimits {
    fn default() -> AuthLimits {
        AuthLimits {
            begin: Arc::new(RateLimiter::new(BEGIN_PER_MINUTE, WINDOW)),
            finish: Arc::new(RateLimiter::new(FINISH_PER_MINUTE, WINDOW)),
        }
    }
}

impl AuthLimits {
    /// Counts a request from `client` against `limiter`; over the limit, `rate_limited`.
    pub fn admit(limiter: &RateLimiter, client: ClientIp) -> Result<(), ApiError> {
        limiter
            .check(client.0, Instant::now())
            .map_err(ApiError::rate_limited)
    }
}

/// The client address a limit counts against (see the module documentation).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClientIp(pub IpAddr);

impl FromRequestParts<AppState> for ClientIp {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<ClientIp, ApiError> {
        // `serve` builds the service with connect info; a router driven without it is a bug.
        let Some(ConnectInfo(peer)) = parts.extensions.get::<ConnectInfo<SocketAddr>>() else {
            tracing::error!("a sign-in request arrived without its peer address");
            return Err(ApiError::internal());
        };
        Ok(ClientIp(client_ip(
            *peer,
            &parts.headers,
            state.config.trust_forwarded_for,
        )))
    }
}

/// Extracting this counts the request against the `begin` limit; over it, the request is
/// refused `rate_limited` before anything else is read.
#[derive(Debug, Clone, Copy)]
pub struct BeginAllowed;

impl FromRequestParts<AppState> for BeginAllowed {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<BeginAllowed, ApiError> {
        let client = ClientIp::from_request_parts(parts, state).await?;
        AuthLimits::admit(&state.limits.begin, client)?;
        Ok(BeginAllowed)
    }
}

/// Extracting this counts the request against the `finish` limit, before its body is read.
#[derive(Debug, Clone, Copy)]
pub struct FinishAllowed;

impl FromRequestParts<AppState> for FinishAllowed {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<FinishAllowed, ApiError> {
        let client = ClientIp::from_request_parts(parts, state).await?;
        AuthLimits::admit(&state.limits.finish, client)?;
        Ok(FinishAllowed)
    }
}

/// The TCP peer, or, when `trust_forwarded_for`, the right-most `X-Forwarded-For` entry (across
/// every such header, in order). A missing or unparsable entry falls back to the peer.
pub fn client_ip(peer: SocketAddr, headers: &HeaderMap, trust_forwarded_for: bool) -> IpAddr {
    if trust_forwarded_for {
        let last = headers
            .get_all("x-forwarded-for")
            .iter()
            .filter_map(|value| value.to_str().ok())
            .flat_map(|value| value.split(','))
            .map(str::trim)
            .rfind(|entry| !entry.is_empty());
        if let Some(ip) = last.and_then(|entry| entry.parse::<IpAddr>().ok()) {
            return ip;
        }
    }
    peer.ip()
}

#[cfg(test)]
mod tests {
    use axum::http::HeaderValue;

    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn a_window_admits_the_limit_then_says_how_long_to_wait() {
        let limiter = RateLimiter::new(3, WINDOW);
        let start = Instant::now();
        let client = ip("192.0.2.1");
        for _ in 0..3 {
            assert_eq!(limiter.check(client, start), Ok(()));
        }
        assert_eq!(
            limiter.check(client, start + Duration::from_secs(20)),
            Err(Duration::from_secs(40))
        );
        // Another client has its own window.
        assert_eq!(limiter.check(ip("192.0.2.2"), start), Ok(()));
        // The next window starts fresh.
        assert_eq!(limiter.check(client, start + WINDOW), Ok(()));
    }

    #[test]
    fn ended_windows_are_swept_once_many_clients_are_tracked() {
        let limiter = RateLimiter::new(1, WINDOW);
        let start = Instant::now();
        for n in 0..=SWEEP_ABOVE as u32 {
            limiter.check(IpAddr::from(n.to_be_bytes()), start).unwrap();
        }
        limiter
            .check(ip("192.0.2.1"), start + WINDOW + Duration::from_secs(1))
            .unwrap();
        assert_eq!(limiter.windows.lock().unwrap().len(), 1);
    }

    #[test]
    fn forwarded_for_is_read_only_when_trusted() {
        let peer: SocketAddr = "10.0.0.1:5000".parse().unwrap();
        let mut headers = HeaderMap::new();
        headers.append(
            "x-forwarded-for",
            HeaderValue::from_static("198.51.100.1, 203.0.113.5"),
        );
        assert_eq!(client_ip(peer, &headers, false), ip("10.0.0.1"));
        assert_eq!(client_ip(peer, &headers, true), ip("203.0.113.5"));

        headers.append("x-forwarded-for", HeaderValue::from_static("2001:db8::7"));
        assert_eq!(client_ip(peer, &headers, true), ip("2001:db8::7"));

        let mut junk = HeaderMap::new();
        junk.append("x-forwarded-for", HeaderValue::from_static("unknown"));
        assert_eq!(client_ip(peer, &junk, true), ip("10.0.0.1"));
        assert_eq!(client_ip(peer, &HeaderMap::new(), true), ip("10.0.0.1"));
    }
}
