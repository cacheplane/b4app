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
    fn devices_are_counted_separately() {
        let limit = SlidingWindow::new(1, Duration::from_secs(60));
        let now = Instant::now();
        limit.hit(Uuid::from_u128(1), now).unwrap();
        limit.hit(Uuid::from_u128(2), now).unwrap();
        assert!(limit.hit(Uuid::from_u128(1), now).is_err());
    }
}
