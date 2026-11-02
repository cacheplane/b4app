//! The relay's rate limits. They are in memory, per hub process (a restart forgets them, which
//! only ever lets one extra burst through), and read time through `tokio::time::Instant` so a
//! paused clock moves their windows.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::time::Instant;
use uuid::Uuid;

/// The link upgrades one device may attempt in [`UPGRADE_WINDOW`].
pub const UPGRADES_PER_WINDOW: usize = 10;
/// The window the upgrade limit counts over.
pub const UPGRADE_WINDOW: Duration = Duration::from_secs(60);

/// The commands one client device may send in [`COMMAND_WINDOW`].
pub const COMMANDS_PER_WINDOW: usize = 60;
/// The most commands one client device may send at once, after which they are spaced at the
/// minute's rate (one a second).
pub const COMMAND_BURST: usize = 20;
/// The `turn.send` and `thread.start` commands, together, one user may send in
/// [`COMMAND_WINDOW`], across all of their devices.
pub const STARTS_PER_WINDOW: usize = 20;
/// The window the command limits count over.
pub const COMMAND_WINDOW: Duration = Duration::from_secs(60);

/// A sliding-window counter per device: at most `limit` events in any `window`.
#[derive(Debug, Clone)]
pub struct SlidingWindow {
    limit: usize,
    window: Duration,
    seen: Arc<Mutex<HashMap<Uuid, VecDeque<Instant>>>>,
}

impl SlidingWindow {
    pub fn new(limit: usize, window: Duration) -> SlidingWindow {
        SlidingWindow {
            limit,
            window,
            seen: Arc::default(),
        }
    }

    /// The limit on link upgrades: [`UPGRADES_PER_WINDOW`] a device every [`UPGRADE_WINDOW`].
    pub fn upgrades() -> SlidingWindow {
        SlidingWindow::new(UPGRADES_PER_WINDOW, UPGRADE_WINDOW)
    }

    /// How long until `key` could have an event counted at `now` (zero when it could now), without
    /// counting one.
    pub fn wait(&self, key: Uuid, now: Instant) -> Duration {
        let seen = self
            .seen
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let Some(events) = seen.get(&key) else {
            return Duration::ZERO;
        };
        let live: Vec<&Instant> = events
            .iter()
            .filter(|at| now.saturating_duration_since(**at) < self.window)
            .collect();
        if live.len() < self.limit {
            return Duration::ZERO;
        }
        // The event that must age out is the one `limit` from the newest.
        let oldest = *live[live.len() - self.limit];
        (oldest + self.window).saturating_duration_since(now)
    }

    /// Counts one event for `key` at `now`. `Err` carries how long until the oldest counted event
    /// leaves the window, and then the event is not counted.
    pub fn hit(&self, key: Uuid, now: Instant) -> Result<(), Duration> {
        let mut seen = self
            .seen
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Keys that have gone quiet would otherwise stay forever.
        if seen.len() > 1024 {
            seen.retain(|_, events| {
                events
                    .back()
                    .is_some_and(|last| now.saturating_duration_since(*last) < self.window)
            });
        }
        let events = seen.entry(key).or_default();
        while events
            .front()
            .is_some_and(|first| now.saturating_duration_since(*first) >= self.window)
        {
            events.pop_front();
        }
        if events.len() >= self.limit {
            let oldest = events.front().copied().unwrap_or(now);
            return Err((oldest + self.window).saturating_duration_since(now));
        }
        events.push_back(now);
        Ok(())
    }
}

/// A rate with a burst, per key: at most `limit` events in any `window`, and at most `burst` at
/// once, after which events are spaced `window / limit` apart (a token bucket of `burst` that
/// refills at the window's rate, kept as a theoretical arrival time). An event is counted only
/// when both allow it.
#[derive(Debug, Clone)]
pub struct RateWithBurst {
    window: SlidingWindow,
    /// The spacing the bucket refills at: `window / limit`.
    spacing: Duration,
    /// How far ahead of now the bucket's arrival time may run: `(burst - 1) * spacing`.
    slack: Duration,
    due: Arc<Mutex<HashMap<Uuid, Instant>>>,
}

impl RateWithBurst {
    pub fn new(limit: usize, window: Duration, burst: usize) -> RateWithBurst {
        let spacing = window / u32::try_from(limit.max(1)).unwrap_or(u32::MAX);
        RateWithBurst {
            window: SlidingWindow::new(limit, window),
            spacing,
            slack: spacing * u32::try_from(burst.max(1) - 1).unwrap_or(u32::MAX),
            due: Arc::default(),
        }
    }

    /// The limit on a client device's commands: [`COMMANDS_PER_WINDOW`] a [`COMMAND_WINDOW`], in
    /// bursts of at most [`COMMAND_BURST`].
    pub fn commands() -> RateWithBurst {
        RateWithBurst::new(COMMANDS_PER_WINDOW, COMMAND_WINDOW, COMMAND_BURST)
    }

    /// Counts one event for `key` at `now`, or says how long until one would be allowed.
    pub fn hit(&self, key: Uuid, now: Instant) -> Result<(), Duration> {
        let mut due = self
            .due
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if due.len() > 1024 {
            due.retain(|_, at| *at > now);
        }
        let arrival = due.get(&key).copied().unwrap_or(now).max(now);
        let ahead = arrival.saturating_duration_since(now);
        if ahead > self.slack {
            // The window may refuse too; the caller waits for whichever ends later.
            let burst_wait = ahead - self.slack;
            let window_wait = self.window.wait(key, now);
            return Err(burst_wait.max(window_wait));
        }
        self.window.hit(key, now)?;
        due.insert(key, arrival + self.spacing);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_eleventh_hit_in_a_minute_waits_for_the_first_to_age_out() {
        let limit = SlidingWindow::upgrades();
        let device = Uuid::from_u128(1);
        let start = Instant::now();
        for second in 0..10 {
            limit
                .hit(device, start + Duration::from_secs(second))
                .expect("within the limit");
        }
        let wait = limit
            .hit(device, start + Duration::from_secs(10))
            .expect_err("the eleventh is limited");
        assert_eq!(wait, Duration::from_secs(50));
        // A refused hit is not counted: the window still ends when the first hit leaves it.
        limit
            .hit(device, start + Duration::from_secs(60))
            .expect("the first hit has aged out");
        assert!(limit.hit(device, start + Duration::from_secs(60)).is_err());
    }

    #[test]
    fn a_burst_of_twenty_then_one_a_second_and_sixty_a_minute() {
        let limit = RateWithBurst::commands();
        let device = Uuid::from_u128(1);
        let start = Instant::now();
        for _ in 0..20 {
            limit.hit(device, start).expect("within the burst");
        }
        assert_eq!(limit.hit(device, start), Err(Duration::from_secs(1)));
        // One more each second.
        limit.hit(device, start + Duration::from_secs(1)).unwrap();
        assert!(limit.hit(device, start + Duration::from_secs(1)).is_err());
        // Bursts at 20 s and 40 s fill the minute: 20 + 1 + 19 + 20 = 60.
        for _ in 0..19 {
            limit.hit(device, start + Duration::from_secs(20)).unwrap();
        }
        for _ in 0..20 {
            limit.hit(device, start + Duration::from_secs(40)).unwrap();
        }
        // At 50 s the bucket has ten to spare, but the minute is full until the first twenty age
        // out at 60 s.
        assert_eq!(
            limit.hit(device, start + Duration::from_secs(50)),
            Err(Duration::from_secs(10))
        );
        limit.hit(device, start + Duration::from_secs(60)).unwrap();
        // Another device has its own.
        limit.hit(Uuid::from_u128(2), start).unwrap();
    }

    #[test]
    fn devices_are_counted_separately() {
        let limit = SlidingWindow::new(1, Duration::from_secs(60));
        let now = Instant::now();
        limit.hit(Uuid::from_u128(1), now).unwrap();
        limit.hit(Uuid::from_u128(2), now).unwrap();
        assert!(limit.hit(Uuid::from_u128(1), now).is_err());
    }
}
