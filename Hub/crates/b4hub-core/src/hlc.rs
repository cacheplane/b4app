//! Hybrid logical clock stamps, as text. The format is the Swift client's `HLC`: 12 lowercase hex
//! digits of epoch milliseconds, `-`, 4 lowercase hex digits of counter, `-`, then the device id
//! (which may itself contain `-`). Stamps compare as plain strings, which is the same as
//! comparing (millis, counter, device id) because the first two fields are fixed width; in
//! PostgreSQL compare them with `COLLATE "C"`.

use std::fmt;

/// A receiver rewrites a stamp more than this far ahead of its own wall clock.
pub const MAX_AHEAD_MILLIS: u64 = 300_000;

/// A parsed stamp. Ordering is by the text, as on every other device.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Hlc {
    millis: u64,
    counter: u16,
    device_id: String,
    text: String,
}

impl Hlc {
    pub fn new(millis: u64, counter: u16, device_id: &str) -> Hlc {
        Hlc {
            millis,
            counter,
            device_id: device_id.to_string(),
            text: format!("{millis:012x}-{counter:04x}-{device_id}"),
        }
    }

    /// Parses the first two `-` separated fields as millis and counter and takes the rest as the
    /// device id. Uppercase hex, wrong widths, and an empty device id are refused.
    pub fn parse(text: &str) -> Option<Hlc> {
        let mut parts = text.splitn(3, '-');
        let (millis, counter, device_id) = (parts.next()?, parts.next()?, parts.next()?);
        if millis.len() != 12 || counter.len() != 4 || device_id.is_empty() {
            return None;
        }
        Some(Hlc::new(
            parse_hex(millis)?,
            u16::try_from(parse_hex(counter)?).ok()?,
            device_id,
        ))
    }

    /// The stamp for a change that carries none (an M8a client): its wall clock, counter 0, and
    /// the device. Matches the Mac's migration backfill.
    pub fn derived(wall: i64, device_id: &str) -> Hlc {
        Hlc::new(u64::try_from(wall).unwrap_or(0), 0, device_id)
    }

    /// This stamp, or when it is more than five minutes ahead of `now_ms` the receiver's
    /// milliseconds with counter 0 and the original device id. Exactly five minutes ahead stays.
    pub fn clamped(&self, now_ms: u64) -> Hlc {
        if self.millis > now_ms && self.millis - now_ms > MAX_AHEAD_MILLIS {
            Hlc::new(now_ms, 0, &self.device_id)
        } else {
            self.clone()
        }
    }

    pub fn millis(&self) -> u64 {
        self.millis
    }

    pub fn counter(&self) -> u16 {
        self.counter
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn as_str(&self) -> &str {
        &self.text
    }
}

impl PartialOrd for Hlc {
    fn partial_cmp(&self, other: &Hlc) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Hlc {
    fn cmp(&self, other: &Hlc) -> std::cmp::Ordering {
        self.text.cmp(&other.text)
    }
}

impl fmt::Display for Hlc {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)
    }
}

fn parse_hex(text: &str) -> Option<u64> {
    if !text
        .bytes()
        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return None;
    }
    u64::from_str_radix(text, 16).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hlc_orders_and_clamps() {
        assert!(Hlc::new(1, 9, "b") < Hlc::new(2, 0, "a"));
        assert!(Hlc::new(2, 0, "a") < Hlc::new(2, 1, "a"));
        assert!(Hlc::new(2, 0, "a") < Hlc::new(2, 0, "b"));
        assert_eq!(
            Hlc::parse("0192e0f1a2b3-0000-dev").unwrap().millis(),
            0x0192_e0f1_a2b3
        );
        assert!(Hlc::parse("not-a-clock").is_none());

        // Within five minutes (300 000 ms) of the wall stays; beyond it is rewritten.
        let far = Hlc::new(1_000_000, 7, "p");
        assert_eq!(far.clamped(600_000), Hlc::new(600_000, 0, "p"));
        assert_eq!(Hlc::new(800_000, 7, "p").clamped(600_000).millis(), 800_000);
        assert_eq!(Hlc::new(900_000, 7, "p").clamped(600_000).millis(), 900_000);
        assert_eq!(Hlc::new(900_001, 7, "p").clamped(600_000).millis(), 600_000);
        // Behind the wall is never touched.
        assert_eq!(Hlc::new(5, 3, "p").clamped(600_000), Hlc::new(5, 3, "p"));
    }

    #[test]
    fn text_is_lowercase_hex_and_a_sorted_string() {
        let hlc = Hlc::new(
            0x0192_e0f1_a2b3,
            0xAB,
            "01a194cf-0d12-7418-b3b5-5559dbee2441",
        );
        assert_eq!(
            hlc.as_str(),
            "0192e0f1a2b3-00ab-01a194cf-0d12-7418-b3b5-5559dbee2441"
        );
        let (a, b) = (Hlc::new(9, 0, "x"), Hlc::new(10, 0, "x"));
        assert!(a.as_str() < b.as_str() && a < b);
    }

    #[test]
    fn a_device_id_may_contain_dashes() {
        let text = "0192e0f1a2b3-0007-01a194cf-0d12-7418-b3b5-5559dbee2441";
        let hlc = Hlc::parse(text).unwrap();
        assert_eq!(hlc.counter(), 7);
        assert_eq!(hlc.device_id(), "01a194cf-0d12-7418-b3b5-5559dbee2441");
        assert_eq!(hlc.as_str(), text);
    }

    #[test]
    fn rejects_uppercase_wrong_length_and_empty_device() {
        for bad in [
            "0192E0F1A2B3-0000-dev",
            "192e0f1a2b3-0000-dev",
            "0192e0f1a2b3-000-dev",
            "0192e0f1a2b3-00000-dev",
            "0192e0f1a2b3-0000-",
            "0192e0f1a2b3-0000",
            "0192e0f1a2bg-0000-dev",
            "",
        ] {
            assert!(Hlc::parse(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn derived_is_the_wall_with_a_zero_counter() {
        assert_eq!(
            Hlc::derived(1_761_900_001_000, "dev").as_str(),
            "019a396c76e8-0000-dev"
        );
        assert_eq!(Hlc::derived(-5, "dev").as_str(), "000000000000-0000-dev");
    }
}
