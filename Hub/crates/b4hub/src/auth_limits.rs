//! Per-IP rate limits for the sign-in routes: a fixed one-minute window per client address, in
//! memory per process (a hub with several replicas lets a client through once per replica).
//!
//! The client is the TCP peer, or, with `B4HUB_TRUST_X_FORWARDED_FOR=1`, the right-most
//! `X-Forwarded-For` entry: the one the hub's own proxy appended, which a client cannot forge.
//! That assumes exactly one proxy hop in front of the hub; behind two, the right-most entry is
//! the outer proxy, and every client would share its limit.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
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

/// The most clients one limit tracks. Past it, a client it is not already tracking is refused
/// (`rate_limited`) until the next sweep frees room, so a flood of fresh addresses costs a
/// bounded amount of memory instead of growing the map.
pub const MAX_TRACKED_CLIENTS: usize = 100_000;

/// One limit: at most `limit` requests per client in each window. Clients are keyed by
/// [`client_key`]: an IPv4 address, or an IPv6 address's /64 prefix.
#[derive(Debug)]
pub struct RateLimiter {
    limit: u32,
    window: Duration,
    max_clients: usize,
    state: Mutex<Windows>,
}

#[derive(Debug, Default)]
struct Windows {
    by_client: HashMap<IpAddr, (Instant, u32)>,
    /// When ended windows were last swept; at most once per window, so a check is O(1) apart
    /// from one O(n) pass a minute.
    last_sweep: Option<Instant>,
}

impl RateLimiter {
    pub fn new(limit: u32, window: Duration) -> RateLimiter {
        RateLimiter::with_max_clients(limit, window, MAX_TRACKED_CLIENTS)
    }

    pub fn with_max_clients(limit: u32, window: Duration, max_clients: usize) -> RateLimiter {
        RateLimiter {
            limit,
            window,
            max_clients,
            state: Mutex::new(Windows::default()),
        }
    }

    /// Counts a request from `client` at `now`. `Err` holds how long to wait: until the client's
    /// window ends when it has used it up, or until the next sweep when the limit is tracking as
    /// many clients as it may and this is a new one.
    pub fn check(&self, client: IpAddr, now: Instant) -> Result<(), Duration> {
        let key = client_key(client);
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let window = self.window;
        let swept = *state.last_sweep.get_or_insert(now);
        if now.saturating_duration_since(swept) >= window {
            state
                .by_client
                .retain(|_, (start, _)| now.saturating_duration_since(*start) < window);
            state.last_sweep = Some(now);
        }
        let until_sweep = || {
            let since = now.saturating_duration_since(state.last_sweep.unwrap_or(now));
            window.saturating_sub(since).max(Duration::from_millis(1))
        };
        if !state.by_client.contains_key(&key) && state.by_client.len() >= self.max_clients {
            return Err(until_sweep());
        }
        let (start, count) = state.by_client.entry(key).or_insert((now, 0));
        if now.saturating_duration_since(*start) >= window {
            *start = now;
            *count = 0;
        }
        if *count >= self.limit {
            return Err(window.saturating_sub(now.saturating_duration_since(*start)));
        }
        *count += 1;
        Ok(())
    }
}

/// What a limit counts a client as: an IPv4 address itself (an IPv4-mapped IPv6 address, as a
/// dual-stack listener reports IPv4 peers, counts as that IPv4 address), or an IPv6 address's
/// /64 prefix, since one host or network is routinely given a whole /64.
pub fn client_key(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(_) => ip,
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => {
                let s = v6.segments();
                IpAddr::V6(Ipv6Addr::new(s[0], s[1], s[2], s[3], 0, 0, 0, 0))
            }
        },
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
/// every such header, in order; a port or brackets are allowed). A missing or unparsable entry
/// falls back to the peer.
pub fn client_ip(peer: SocketAddr, headers: &HeaderMap, trust_forwarded_for: bool) -> IpAddr {
    if trust_forwarded_for {
        let last = headers
            .get_all("x-forwarded-for")
            .iter()
            .filter_map(|value| value.to_str().ok())
            .flat_map(|value| value.split(','))
            .map(str::trim)
            .rfind(|entry| !entry.is_empty());
        if let Some(ip) = last.and_then(parse_forwarded) {
            return ip;
        }
    }
    peer.ip()
}

/// One `X-Forwarded-For` entry: a bare address, `a.b.c.d:port`, `[v6]`, or `[v6]:port`.
fn parse_forwarded(entry: &str) -> Option<IpAddr> {
    entry
        .parse::<IpAddr>()
        .ok()
        .or_else(|| entry.parse::<SocketAddr>().ok().map(|addr| addr.ip()))
        .or_else(|| {
            entry
                .strip_prefix('[')
                .and_then(|rest| rest.strip_suffix(']'))
                .and_then(|inner| inner.parse::<IpAddr>().ok())
        })
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
    fn past_the_cap_new_clients_wait_for_the_sweep() {
        let limiter = RateLimiter::with_max_clients(5, WINDOW, 3);
        let start = Instant::now();
        for n in 1..=3 {
            limiter.check(ip(&format!("192.0.2.{n}")), start).unwrap();
        }
        // A fourth client is refused until the next sweep, and nothing grows.
        let later = start + Duration::from_secs(15);
        assert_eq!(
            limiter.check(ip("192.0.2.4"), later),
            Err(Duration::from_secs(45))
        );
        assert_eq!(limiter.state.lock().unwrap().by_client.len(), 3);
        // A tracked client still gets its own limit.
        assert_eq!(limiter.check(ip("192.0.2.1"), later), Ok(()));
        // Once the window has passed, the sweep frees the ended windows and the newcomer fits.
        assert_eq!(limiter.check(ip("192.0.2.4"), start + WINDOW), Ok(()));
        assert_eq!(limiter.state.lock().unwrap().by_client.len(), 1);
    }

    #[test]
    fn sweeps_run_at_most_once_a_window() {
        let limiter = RateLimiter::new(1, WINDOW);
        let start = Instant::now();
        limiter.check(ip("192.0.2.1"), start).unwrap();
        // Ended, but the last sweep was less than a window ago, so it is still tracked.
        limiter
            .check(ip("192.0.2.2"), start + Duration::from_secs(59))
            .unwrap();
        assert_eq!(limiter.state.lock().unwrap().by_client.len(), 2);
        limiter
            .check(ip("192.0.2.3"), start + Duration::from_secs(61))
            .unwrap();
        // The sweep at 61 s dropped 192.0.2.1 (61 s old) and kept 192.0.2.2 (2 s old).
        let tracked = limiter.state.lock().unwrap().by_client.len();
        assert_eq!(tracked, 2);
    }

    #[test]
    fn ipv6_clients_share_their_64_and_ipv4_stays_per_address() {
        let limiter = RateLimiter::new(2, WINDOW);
        let now = Instant::now();
        limiter.check(ip("2001:db8:1:2::1"), now).unwrap();
        limiter.check(ip("2001:db8:1:2:ffff::9"), now).unwrap();
        assert!(limiter.check(ip("2001:db8:1:2:abcd::"), now).is_err());
        // Another /64 has its own window.
        assert_eq!(limiter.check(ip("2001:db8:1:3::1"), now), Ok(()));
        // IPv4 neighbours are separate, including as dual-stack mapped addresses.
        for _ in 0..2 {
            limiter.check(ip("198.51.100.1"), now).unwrap();
        }
        assert!(limiter.check(ip("::ffff:198.51.100.1"), now).is_err());
        assert_eq!(limiter.check(ip("::ffff:198.51.100.2"), now), Ok(()));
        assert_eq!(client_key(ip("2001:db8:1:2:3:4:5:6")), ip("2001:db8:1:2::"));
        assert_eq!(client_key(ip("::ffff:10.0.0.1")), ip("10.0.0.1"));
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

        for (entry, expected) in [
            ("203.0.113.5:4711", "203.0.113.5"),
            ("[2001:db8::7]", "2001:db8::7"),
            ("[2001:db8::7]:443", "2001:db8::7"),
        ] {
            let mut with_port = HeaderMap::new();
            with_port.append("x-forwarded-for", HeaderValue::from_str(entry).unwrap());
            assert_eq!(client_ip(peer, &with_port, true), ip(expected), "{entry}");
        }

        let mut junk = HeaderMap::new();
        junk.append("x-forwarded-for", HeaderValue::from_static("unknown"));
        assert_eq!(client_ip(peer, &junk, true), ip("10.0.0.1"));
        assert_eq!(client_ip(peer, &HeaderMap::new(), true), ip("10.0.0.1"));
    }
}
