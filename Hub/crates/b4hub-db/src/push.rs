//! Push tokens and the notification decision. A phone registers its APNs token (`save_token`);
//! when a push applies a turn or a runtime request, the hub decides, inside that same
//! transaction, whether it notifies the user's other phones (decision D-121). The rules are
//! `b4hub_core::push`; this module reads the rows, asks the rules, and writes the at-most-once
//! ledger `notifications_sent`, so a retried batch or a later update to the same row notifies
//! nobody twice. Sending happens after the commit, elsewhere.
//!
//! The same transaction withdraws what is over: a notified request that is no longer pending, a
//! notified turn its thread's `readTurnId` now covers, and everything notified in a thread that
//! was deleted. Each ledger row is withdrawn once (`withdrawn_at`). Every alert carries the
//! badge, the number of threads that need the user, from the attention rules in SQL
//! ([`bands`]), which follow `Attention.band(of:)` and are checked by the shared fixture.

use std::collections::HashMap;
use std::fmt;

use b4hub_core::push::{
    alert_title, key, request_reason, turn_reason, Kind, Reason, TURN_RECENCY_SECS,
};
use sqlx::postgres::PgConnection;
use sqlx::types::Uuid;
use sqlx::{Acquire, FromRow, Postgres, Transaction};

use crate::changes::is_data_error;
use crate::devices::AuthedDevice;
use crate::{Db, Error, Result};

/// A notification to deliver after the push commits: one per phone with a token.
#[derive(Clone, PartialEq, Eq)]
pub struct Notification {
    pub device_id: Uuid,
    pub token: String,
    pub environment: String,
    pub bundle_id: String,
    pub thread_id: String,
    pub title: String,
    pub reason: Reason,
    /// `request:<id>` or `turn:<id>`, the key a withdrawal names.
    pub key: String,
    /// The user's needs-you count after the whole push, the app icon badge.
    pub badge: i64,
}

impl fmt::Debug for Notification {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Notification")
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .field("environment", &self.environment)
            .field("bundle_id", &self.bundle_id)
            .field("thread_id", &self.thread_id)
            .field("title", &self.title)
            .field("reason", &self.reason)
            .field("key", &self.key)
            .field("badge", &self.badge)
            .finish()
    }
}

/// A background push to deliver after the push commits: one per phone with a token, naming every
/// notification the push withdrew.
#[derive(Clone, PartialEq, Eq)]
pub struct Withdrawal {
    pub device_id: Uuid,
    pub token: String,
    pub environment: String,
    pub bundle_id: String,
    pub keys: Vec<String>,
}

impl fmt::Debug for Withdrawal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Withdrawal")
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .field("environment", &self.environment)
            .field("bundle_id", &self.bundle_id)
            .field("keys", &self.keys)
            .finish()
    }
}

/// Where a thread sits in the list, as `Attention.band(of:)` decides it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Band {
    NeedsInput,
    Unread,
    Working,
    Quiet,
}

impl Band {
    /// The wire name, as the shared fixture spells it.
    pub fn as_str(&self) -> &'static str {
        match self {
            Band::NeedsInput => "needsInput",
            Band::Unread => "unread",
            Band::Working => "working",
            Band::Quiet => "quiet",
        }
    }

    fn parse(text: &str) -> Option<Band> {
        match text {
            "needsInput" => Some(Band::NeedsInput),
            "unread" => Some(Band::Unread),
            "working" => Some(Band::Working),
            "quiet" => Some(Band::Quiet),
            _ => None,
        }
    }
}

/// The kind of notification a change to `table` can cause, if any.
pub(crate) fn kind_of_table(table: &str) -> Option<Kind> {
    match table {
        "runtimeRequests" => Some(Kind::Request),
        "turns" => Some(Kind::Turn),
        _ => None,
    }
}

/// Stores `token` as `auth`'s device's push token, replacing any it had. The caller has checked
/// that the device is an iOS device and that `environment` is `sandbox` or `production`; the
/// table's check constraint refuses anything else. Any other device of the org holding the same
/// token gives it up: a phone that re-enrolled while the hub still holds its old device would
/// otherwise be told everything twice.
pub async fn save_token(
    db: &Db,
    auth: &AuthedDevice,
    token: &str,
    environment: &str,
    bundle_id: &str,
) -> Result<()> {
    let mut tx = db.tenant_tx(auth.org_id).await?;
    sqlx::query("DELETE FROM push_tokens WHERE org_id = $1 AND token = $2 AND device_id <> $3")
        .bind(auth.org_id)
        .bind(token)
        .bind(auth.device_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO push_tokens (org_id, device_id, token, environment, bundle_id) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (device_id) DO UPDATE \
         SET token = EXCLUDED.token, environment = EXCLUDED.environment, \
             bundle_id = EXCLUDED.bundle_id, updated_at = now()",
    )
    .bind(auth.org_id)
    .bind(auth.device_id)
    .bind(token)
    .bind(environment)
    .bind(bundle_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// Forgets `device_id`'s push token `token`, for a token Apple says is no longer valid. The phone
/// is told nothing until it registers a token again. Only that token is deleted: a newer one the
/// phone saved while the send was in flight survives. A device with no such token is not an error.
pub async fn delete_token(db: &Db, org_id: Uuid, device_id: Uuid, token: &str) -> Result<()> {
    let mut tx = db.tenant_tx(org_id).await?;
    sqlx::query("DELETE FROM push_tokens WHERE org_id = $1 AND device_id = $2 AND token = $3")
        .bind(org_id)
        .bind(device_id)
        .bind(token)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

/// A phone that is told: iOS, not revoked, signed in, with a push token.
#[derive(FromRow)]
struct Phone {
    device_id: Uuid,
    token: String,
    environment: String,
    bundle_id: String,
}

/// The user's phones that are told, ordered by device id, leaving out `skip` (the pusher, for a
/// notification).
async fn phones(
    conn: &mut PgConnection,
    auth: &AuthedDevice,
    skip: Option<Uuid>,
) -> Result<Vec<Phone>> {
    let phones = sqlx::query_as(
        "SELECT d.id AS device_id, p.token, p.environment, p.bundle_id \
         FROM push_tokens p \
         JOIN devices d ON d.id = p.device_id AND d.org_id = p.org_id \
         WHERE p.org_id = $1 AND d.user_id = $2 AND d.platform = 'ios' \
           AND d.revoked_at IS NULL AND ($3::uuid IS NULL OR d.id <> $3) \
           AND EXISTS (SELECT 1 FROM device_tokens t \
                       WHERE t.device_id = d.id AND t.org_id = d.org_id \
                         AND t.revoked_at IS NULL) \
         ORDER BY d.id",
    )
    .bind(auth.org_id)
    .bind(auth.user_id)
    .bind(skip)
    .fetch_all(conn)
    .await?;
    Ok(phones)
}

/// Everything a push's applied changes decide, in its transaction: the notifications for the
/// rows in `touched` (turns and runtime requests, in batch order and without repeats) and the
/// withdrawals for what those rows and the `threads` rows the push changed have ended. A
/// notification whose subject also ended in this push is neither sent nor withdrawn (its ledger
/// row is written and withdrawn at once). Every notification carries the badge as it stands
/// after the whole batch.
pub(crate) async fn decide(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthedDevice,
    touched: &[(Kind, String)],
    threads: &[String],
) -> Result<(Vec<Notification>, Vec<Withdrawal>)> {
    let (mut notifications, fresh) = detect(tx, auth, touched).await?;
    let ended = withdraw(tx, auth, touched, threads).await?;
    notifications.retain(|n| !ended.contains(&n.key));
    let keys: Vec<String> = ended.into_iter().filter(|k| !fresh.contains(k)).collect();

    if !notifications.is_empty() {
        let badge = needs_you_count(tx, auth.org_id, auth.user_id).await?;
        for notification in &mut notifications {
            notification.badge = badge;
        }
    }
    let withdrawals = if keys.is_empty() {
        Vec::new()
    } else {
        phones(tx, auth, None)
            .await?
            .into_iter()
            .map(|phone| Withdrawal {
                device_id: phone.device_id,
                token: phone.token,
                environment: phone.environment,
                bundle_id: phone.bundle_id,
                keys: keys.clone(),
            })
            .collect()
    };
    Ok((notifications, withdrawals))
}

/// Marks withdrawn every outstanding ledger row of the user that is over, and returns their keys,
/// sorted: a touched request that is no longer pending (or is deleted or gone); in a touched
/// thread that is deleted (D-089's `deleted_at` or the owner's `userDeletedAt`), every row; in a
/// touched thread whose `readTurnId` names one of its turns, every turn created at or before
/// that turn (ties by id).
async fn withdraw(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthedDevice,
    touched: &[(Kind, String)],
    threads: &[String],
) -> Result<Vec<String>> {
    let requests: Vec<&str> = touched
        .iter()
        .filter(|(kind, _)| *kind == Kind::Request)
        .map(|(_, id)| id.as_str())
        .collect();
    let mut ended: Vec<(String, String)> = Vec::new();
    if !requests.is_empty() {
        ended.extend(
            sqlx::query_as::<_, (String, String)>(
                "UPDATE notifications_sent n SET withdrawn_at = now() \
                 WHERE n.org_id = $1 AND n.user_id = $2 AND n.kind = 'request' \
                   AND n.row_id = ANY($3) AND n.withdrawn_at IS NULL \
                   AND NOT EXISTS (SELECT 1 FROM \"runtimeRequests\" r \
                                   WHERE r.org_id = n.org_id AND r.user_id = n.user_id \
                                     AND r.\"id\" = n.row_id AND r.deleted_at IS NULL \
                                     AND r.\"state\" = 'pending') \
                 RETURNING n.kind, n.row_id",
            )
            .bind(auth.org_id)
            .bind(auth.user_id)
            .bind(&requests)
            .fetch_all(&mut **tx)
            .await?,
        );
    }
    if !threads.is_empty() {
        ended.extend(
            sqlx::query_as::<_, (String, String)>(
                "UPDATE notifications_sent n SET withdrawn_at = now() \
                 FROM \"threads\" t \
                 WHERE n.org_id = $1 AND n.user_id = $2 AND n.withdrawn_at IS NULL \
                   AND t.org_id = n.org_id AND t.user_id = n.user_id \
                   AND t.\"id\" = n.thread_id AND t.\"id\" = ANY($3) \
                   AND (t.deleted_at IS NOT NULL OR t.\"userDeletedAt\" IS NOT NULL) \
                 RETURNING n.kind, n.row_id",
            )
            .bind(auth.org_id)
            .bind(auth.user_id)
            .bind(threads)
            .fetch_all(&mut **tx)
            .await?,
        );
        ended.extend(
            sqlx::query_as::<_, (String, String)>(
                "UPDATE notifications_sent n SET withdrawn_at = now() \
                 FROM \"threads\" t \
                 JOIN \"turns\" r ON r.org_id = t.org_id AND r.user_id = t.user_id \
                                  AND r.\"id\" = t.\"readTurnId\" AND r.\"threadId\" = t.\"id\" \
                 JOIN \"turns\" u ON u.org_id = t.org_id AND u.user_id = t.user_id \
                                  AND u.\"threadId\" = t.\"id\" \
                 WHERE n.org_id = $1 AND n.user_id = $2 AND n.kind = 'turn' \
                   AND n.withdrawn_at IS NULL \
                   AND t.org_id = n.org_id AND t.user_id = n.user_id \
                   AND t.\"id\" = n.thread_id AND t.\"id\" = ANY($3) \
                   AND u.\"id\" = n.row_id \
                   AND (u.\"id\" = r.\"id\" \
                        OR u.\"createdAt\" COLLATE \"C\" < r.\"createdAt\" COLLATE \"C\" \
                        OR (u.\"createdAt\" COLLATE \"C\" = r.\"createdAt\" COLLATE \"C\" \
                            AND u.\"id\" COLLATE \"C\" < r.\"id\" COLLATE \"C\")) \
                 RETURNING n.kind, n.row_id",
            )
            .bind(auth.org_id)
            .bind(auth.user_id)
            .bind(threads)
            .fetch_all(&mut **tx)
            .await?,
        );
    }
    let mut keys: Vec<String> = ended
        .into_iter()
        .filter_map(|(kind, row_id)| {
            let kind = match kind.as_str() {
                "request" => Kind::Request,
                "turn" => Kind::Turn,
                _ => return None,
            };
            Some(key(kind, &row_id))
        })
        .collect();
    keys.sort();
    keys.dedup();
    Ok(keys)
}

/// Every live thread of the user with its band and whether it is archived. A thread is left out
/// when it is deleted (`deleted_at`) or the owner deleted it (`userDeletedAt`); deleted turns and
/// requests do not count. The rule is `Attention.band(of:)`: needs input when any request of the
/// thread is pending; else quiet with no turn; else working when the latest turn (greatest
/// `createdAt`, ties by greatest `id`, timestamps compared bytewise) has not finished; else unread
/// when that turn is not the thread's `readTurnId`; else quiet.
const BANDS: &str = "\
    SELECT t.\"id\" AS thread_id, COALESCE(t.\"archived\", false) AS archived, \
           CASE WHEN pr.n > 0 THEN 'needsInput' \
                WHEN lt.\"status\" IS NULL THEN 'quiet' \
                WHEN lt.\"status\" <> 'terminal' THEN 'working' \
                WHEN t.\"readTurnId\" IS DISTINCT FROM lt.\"id\" THEN 'unread' \
                ELSE 'quiet' END AS band \
    FROM \"threads\" t \
    LEFT JOIN LATERAL ( \
        SELECT u.\"id\", u.\"status\" FROM \"turns\" u \
        WHERE u.org_id = t.org_id AND u.user_id = t.user_id AND u.\"threadId\" = t.\"id\" \
          AND u.deleted_at IS NULL \
        ORDER BY u.\"createdAt\" COLLATE \"C\" DESC NULLS LAST, u.\"id\" COLLATE \"C\" DESC \
        LIMIT 1) lt ON true \
    CROSS JOIN LATERAL ( \
        SELECT count(*) AS n FROM \"runtimeRequests\" r \
        WHERE r.org_id = t.org_id AND r.user_id = t.user_id AND r.\"threadId\" = t.\"id\" \
          AND r.deleted_at IS NULL AND r.\"state\" = 'pending') pr \
    WHERE t.org_id = $1 AND t.user_id = $2 \
      AND t.deleted_at IS NULL AND t.\"userDeletedAt\" IS NULL";

/// The band of each of the user's live threads, by thread id.
pub async fn bands(
    conn: &mut PgConnection,
    org_id: Uuid,
    user_id: Uuid,
) -> Result<HashMap<String, Band>> {
    let rows: Vec<(String, bool, String)> = sqlx::query_as(BANDS)
        .bind(org_id)
        .bind(user_id)
        .fetch_all(conn)
        .await?;
    Ok(rows
        .into_iter()
        .filter_map(|(id, _, band)| Band::parse(&band).map(|band| (id, band)))
        .collect())
}

/// The badge: how many of the user's live, non-archived threads need input or have an unread
/// reply.
pub async fn needs_you_count(conn: &mut PgConnection, org_id: Uuid, user_id: Uuid) -> Result<i64> {
    let count = sqlx::query_scalar(&format!(
        "SELECT count(*) FROM ({BANDS}) b \
         WHERE NOT b.archived AND b.band IN ('needsInput', 'unread')"
    ))
    .bind(org_id)
    .bind(user_id)
    .fetch_one(conn)
    .await?;
    Ok(count)
}

/// What the rules need to know about one changed row.
struct Subject {
    reason: Reason,
    thread_id: String,
    title: String,
}

/// Decides, for each row a push applied (`touched`, in batch order and without repeats), whether
/// it notifies, records the decision in the ledger, and returns one [`Notification`] per
/// registered phone of the user (other than the pusher's own device) for every row the ledger
/// had not seen (its badge still 0), with the keys of those new ledger rows. Runs in the push's
/// transaction. A row whose time cannot be read is treated as not recent rather than failing the
/// batch.
async fn detect(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthedDevice,
    touched: &[(Kind, String)],
) -> Result<(Vec<Notification>, Vec<String>)> {
    let mut notifications = Vec::new();
    let mut fresh_keys = Vec::new();
    let mut told: Option<Vec<Phone>> = None;
    for (kind, row_id) in touched {
        // A savepoint per row, so a timestamp the cast refuses costs that row only.
        let mut savepoint = tx.begin().await?;
        let subject = match subject(&mut savepoint, auth, *kind, row_id).await {
            Ok(subject) => subject,
            Err(Error::Sqlx(error)) if is_data_error(&error) => {
                savepoint.rollback().await?;
                continue;
            }
            Err(error) => return Err(error),
        };
        savepoint.commit().await?;
        let Some(subject) = subject else { continue };

        let fresh: Option<i32> = sqlx::query_scalar(
            "INSERT INTO notifications_sent (org_id, kind, row_id, user_id, thread_id, reason) \
             VALUES ($1, $2, $3, $4, $5, $6) \
             ON CONFLICT (org_id, kind, row_id) DO NOTHING \
             RETURNING 1",
        )
        .bind(auth.org_id)
        .bind(kind.as_str())
        .bind(row_id)
        .bind(auth.user_id)
        .bind(&subject.thread_id)
        .bind(subject.reason.as_str())
        .fetch_optional(&mut **tx)
        .await?;
        if fresh.is_none() {
            continue;
        }
        let key = key(*kind, row_id);
        fresh_keys.push(key.clone());

        if told.is_none() {
            told = Some(phones(tx, auth, Some(auth.device_id)).await?);
        }
        for phone in told.iter().flatten() {
            notifications.push(Notification {
                device_id: phone.device_id,
                token: phone.token.clone(),
                environment: phone.environment.clone(),
                bundle_id: phone.bundle_id.clone(),
                thread_id: subject.thread_id.clone(),
                title: subject.title.clone(),
                reason: subject.reason,
                key: key.clone(),
                badge: 0,
            });
        }
    }
    Ok((notifications, fresh_keys))
}

/// Reads the row (scoped to the org and the pushing user) with its thread's title and applies
/// the rules. `None` when the row is gone or deleted (D-089: `deleted_at` set), has no thread to
/// open, or the rules say no. A row whose thread is deleted (`deleted_at`, or the owner's
/// `userDeletedAt`, D-119) never notifies either: a deleted thread cannot be opened, so the alert
/// would lead nowhere.
async fn subject(
    conn: &mut sqlx::postgres::PgConnection,
    auth: &AuthedDevice,
    kind: Kind,
    row_id: &str,
) -> Result<Option<Subject>> {
    match kind {
        Kind::Request => {
            let row: Option<RequestRow> = sqlx::query_as(
                "SELECT r.\"kind\" AS request_kind, r.\"state\" AS state, \
                        r.\"threadId\" AS thread_id, t.\"title\" AS title, \
                        COALESCE(t.deleted_at IS NOT NULL OR t.\"userDeletedAt\" IS NOT NULL, false) \
                            AS thread_deleted \
                 FROM \"runtimeRequests\" r \
                 LEFT JOIN \"threads\" t ON t.org_id = r.org_id AND t.user_id = r.user_id \
                                        AND t.\"id\" = r.\"threadId\" \
                 WHERE r.org_id = $1 AND r.user_id = $2 AND r.\"id\" = $3 \
                   AND r.deleted_at IS NULL",
            )
            .bind(auth.org_id)
            .bind(auth.user_id)
            .bind(row_id)
            .fetch_optional(conn)
            .await?;
            let Some(RequestRow {
                request_kind,
                state,
                thread_id: Some(thread_id),
                title,
                thread_deleted: false,
            }) = row
            else {
                return Ok(None);
            };
            Ok(request_reason(
                request_kind.as_deref().unwrap_or(""),
                state.as_deref().unwrap_or(""),
            )
            .map(|reason| Subject {
                reason,
                thread_id,
                title: alert_title(title.as_deref()),
            }))
        }
        Kind::Turn => {
            let row: Option<TurnRow> = sqlx::query_as(
                "SELECT u.\"status\" AS status, u.\"outcome\" AS outcome, \
                        u.\"threadId\" AS thread_id, t.\"title\" AS title, \
                        COALESCE(t.deleted_at IS NOT NULL OR t.\"userDeletedAt\" IS NOT NULL, false) \
                            AS thread_deleted, \
                        CASE WHEN u.\"updatedAt\" ~ '^\\d{4}-\\d{2}-\\d{2}T' \
                             THEN u.\"updatedAt\"::timestamptz > now() - make_interval(secs => $4) \
                             ELSE false END AS recent \
                 FROM \"turns\" u \
                 LEFT JOIN \"threads\" t ON t.org_id = u.org_id AND t.user_id = u.user_id \
                                        AND t.\"id\" = u.\"threadId\" \
                 WHERE u.org_id = $1 AND u.user_id = $2 AND u.\"id\" = $3 \
                   AND u.deleted_at IS NULL",
            )
            .bind(auth.org_id)
            .bind(auth.user_id)
            .bind(row_id)
            .bind(TURN_RECENCY_SECS as f64)
            .fetch_optional(conn)
            .await?;
            let Some(TurnRow {
                status,
                outcome,
                thread_id: Some(thread_id),
                title,
                thread_deleted: false,
                recent,
            }) = row
            else {
                return Ok(None);
            };
            Ok(
                turn_reason(status.as_deref().unwrap_or(""), outcome.as_deref(), recent).map(
                    |reason| Subject {
                        reason,
                        thread_id,
                        title: alert_title(title.as_deref()),
                    },
                ),
            )
        }
    }
}

#[derive(FromRow)]
struct RequestRow {
    request_kind: Option<String>,
    state: Option<String>,
    thread_id: Option<String>,
    title: Option<String>,
    thread_deleted: bool,
}

#[derive(FromRow)]
struct TurnRow {
    status: Option<String>,
    outcome: Option<String>,
    thread_id: Option<String>,
    title: Option<String>,
    thread_deleted: bool,
    recent: bool,
}
