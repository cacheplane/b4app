//! The relay: the WebSocket links that let a phone drive conversations on a Mac through the hub.
//! `registry` holds the live links and the presence they imply, `link` is the endpoint and the
//! task that serves one link, and `limits` holds the in-memory rate limits. The wire frames are
//! `b4hub_core::relay`; `Hub/API.md` ("Link") is the reference.
//!
//! # Time
//!
//! Everything here reads time through `tokio::time::Instant`, so a test that calls
//! `tokio::time::pause()` controls heartbeats, the dead-link timeout, and rate-limit windows. A
//! wall-clock time (`hubTime`, the `last_seen_at` a link writes) is the `SystemTime` the relay
//! was created at plus the `tokio::time::Instant` elapsed since, so it moves with a paused clock
//! too and a link's "last frame" can be dated exactly.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use b4hub_core::relay::RelayMessage;
use tokio::time::Instant;

use crate::error::relay_code;

pub mod limits;
pub mod link;
pub mod registry;

pub use registry::{Close, LinkHandle, Registration, Relay, SendError};

/// The link protocol this hub speaks, sent as `protocol` in `hello`.
pub const PROTOCOL: u32 = 1;
/// The oldest client protocol this hub serves, sent as `minClientProtocol` in `hello`.
pub const MIN_CLIENT_PROTOCOL: u32 = 1;

/// The WebSocket close codes the hub uses. 1001 is the standard "going away" for shutdown; the
/// 4xxx codes are the hub's own and tell a device whether reconnecting can help.
pub mod close_code {
    /// The hub is shutting down. Reconnect with backoff.
    pub const SHUTDOWN: u16 = 1001;
    /// The same device opened a newer link. Do not reconnect: the newer one is the link.
    pub const REPLACED: u16 = 4000;
    /// The device was revoked. Stop until it joins again.
    pub const REVOKED: u16 = 4001;
    /// The device's protocol is older than the hub's `minClientProtocol`.
    pub const CLIENT_TOO_OLD: u16 = 4002;
    /// The link sent nothing for [`b4hub_core::relay::DEAD_LINK`]. Reconnect with backoff.
    pub const SILENT: u16 = 4003;
}

/// A hub-to-device `error` frame.
pub fn error_frame(code: &str, message: &str) -> RelayMessage {
    RelayMessage::Error {
        code: code.to_string(),
        message: message.to_string(),
        details: None,
    }
}

/// The `error` frame for a frame the link does not accept: not JSON, not a relay message, or not
/// one this end of the link may send. The link stays up.
pub fn invalid_frame(message: &str) -> RelayMessage {
    error_frame("invalid_request", message)
}

/// The error frame a device's link gets when a newer link from the same device replaces it.
pub fn link_replaced() -> RelayMessage {
    error_frame(relay_code::LINK_REPLACED, "this device opened a newer link")
}

/// The hub's wall clock, read through the (possibly paused) tokio clock. See the module docs.
#[derive(Debug, Clone, Copy)]
pub struct WallClock {
    wall: SystemTime,
    instant: Instant,
}

impl WallClock {
    pub fn new() -> WallClock {
        WallClock {
            wall: SystemTime::now(),
            instant: Instant::now(),
        }
    }

    /// The wall-clock time at `at`.
    pub fn at(&self, at: Instant) -> SystemTime {
        match at.checked_duration_since(self.instant) {
            Some(elapsed) => self.wall + elapsed,
            None => self.wall - self.instant.duration_since(at),
        }
    }

    pub fn now(&self) -> SystemTime {
        self.at(Instant::now())
    }
}

impl Default for WallClock {
    fn default() -> WallClock {
        WallClock::new()
    }
}

/// `time` as RFC 3339 in UTC with milliseconds, the format of every time on the link
/// (`2026-11-01T09:30:00.123Z`). A time before the epoch is the epoch.
pub fn rfc3339_millis(time: SystemTime) -> String {
    let since_epoch = time.duration_since(UNIX_EPOCH).unwrap_or(Duration::ZERO);
    let seconds = since_epoch.as_secs();
    let (year, month, day) = civil_from_days(i64::try_from(seconds / 86_400).unwrap_or(i64::MAX));
    let in_day = seconds % 86_400;
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        in_day / 3_600,
        in_day % 3_600 / 60,
        in_day % 60,
        since_epoch.subsec_millis()
    )
}

/// The proleptic Gregorian date of a day count since 1970-01-01 (Howard Hinnant's
/// `civil_from_days`).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = u32::try_from(day_of_year - (153 * shifted_month + 2) / 5 + 1).unwrap_or(1);
    let month = u32::try_from(if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    })
    .unwrap_or(1);
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: u64, millis: u32) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds) + Duration::from_millis(u64::from(millis))
    }

    #[test]
    fn times_render_as_rfc3339_with_milliseconds() {
        assert_eq!(rfc3339_millis(at(0, 0)), "1970-01-01T00:00:00.000Z");
        assert_eq!(
            rfc3339_millis(at(1_000_000_000, 7)),
            "2001-09-09T01:46:40.007Z"
        );
        // A leap day, the last second of a year, and the first of the next.
        assert_eq!(
            rfc3339_millis(at(1_709_164_800, 999)),
            "2024-02-29T00:00:00.999Z"
        );
        assert_eq!(
            rfc3339_millis(at(1_798_761_599, 0)),
            "2026-12-31T23:59:59.000Z"
        );
        assert_eq!(
            rfc3339_millis(at(1_798_761_600, 0)),
            "2027-01-01T00:00:00.000Z"
        );
        assert_eq!(
            rfc3339_millis(UNIX_EPOCH - Duration::from_secs(5)),
            "1970-01-01T00:00:00.000Z"
        );
    }

    #[test]
    fn rendered_times_sort_like_the_times() {
        let early = rfc3339_millis(at(1_700_000_000, 999));
        let late = rfc3339_millis(at(1_700_000_001, 0));
        assert!(early < late);
    }

    #[tokio::test(start_paused = true)]
    async fn wall_time_follows_the_tokio_clock() {
        let clock = WallClock::new();
        let start = clock.now();
        tokio::time::advance(Duration::from_secs(5)).await;
        let later = clock.now();
        assert_eq!(later.duration_since(start).unwrap(), Duration::from_secs(5));
        let started_at = clock.at(Instant::now() - Duration::from_secs(5));
        assert_eq!(started_at, start);
    }
}
