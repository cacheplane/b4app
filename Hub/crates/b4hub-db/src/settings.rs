//! Hub-wide settings (`hub_settings`, one jsonb value per key, no tenant), and the one key so far:
//! the maintenance switch. `serve` reads it as `b4hub_app`; the operator commands write it as the
//! owner, which is the only role `migrate` lets write the table.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::{Db, Result};

const MAINTENANCE_KEY: &str = "maintenance";

/// What the hub refuses while in maintenance. Only reads continue for now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MaintenanceMode {
    ReadOnly,
}

/// The maintenance switch's value while it is on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Maintenance {
    pub mode: MaintenanceMode,
    /// The operator's text, shown to clients in the error message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// When it was switched on, RFC 3339 in UTC (`2026-11-02T10:15:30Z`).
    pub since: String,
}

impl Maintenance {
    /// Read-only maintenance starting now.
    pub fn read_only(message: Option<String>) -> Maintenance {
        Maintenance {
            mode: MaintenanceMode::ReadOnly,
            message,
            since: rfc3339_utc(SystemTime::now()),
        }
    }
}

/// The maintenance switch, `None` when off. A malformed stored value is a database error, not a
/// silent "off".
pub async fn maintenance(db: &Db) -> Result<Option<Maintenance>> {
    let value: Option<serde_json::Value> =
        sqlx::query_scalar("SELECT value FROM hub_settings WHERE key = $1")
            .bind(MAINTENANCE_KEY)
            .fetch_optional(&db.pool)
            .await?;
    match value {
        None => Ok(None),
        Some(value) => Ok(Some(
            serde_json::from_value(value).map_err(|e| sqlx::Error::Decode(Box::new(e)))?,
        )),
    }
}

/// Switches maintenance on (replacing any previous value) or off.
pub async fn set_maintenance(db: &Db, maintenance: Option<&Maintenance>) -> Result<()> {
    match maintenance {
        Some(maintenance) => {
            let value =
                serde_json::to_value(maintenance).expect("Maintenance serialises as a JSON object");
            sqlx::query(
                "INSERT INTO hub_settings (key, value, updated_at) VALUES ($1, $2, now()) \
                 ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
            )
            .bind(MAINTENANCE_KEY)
            .bind(value)
            .execute(&db.pool)
            .await?;
        }
        None => {
            sqlx::query("DELETE FROM hub_settings WHERE key = $1")
                .bind(MAINTENANCE_KEY)
                .execute(&db.pool)
                .await?;
        }
    }
    Ok(())
}

/// `time` as `YYYY-MM-DDTHH:MM:SSZ`, whole seconds. Small enough not to need a date crate.
pub fn rfc3339_utc(time: SystemTime) -> String {
    let secs = time
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (year, month, day) = civil_from_days(days as i64);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}
