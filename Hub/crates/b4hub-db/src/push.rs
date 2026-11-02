//! Push tokens and the notification decision. A phone registers its APNs token (`save_token`);
//! when a push applies a turn or a runtime request, the hub decides, inside that same
//! transaction, whether it notifies the user's other phones (decision D-110). The rules are
//! `b4hub_core::push`; this module reads the rows, asks the rules, and writes the at-most-once
//! ledger `notifications_sent`, so a retried batch or a later update to the same row notifies
//! nobody twice. Sending happens after the commit, elsewhere.

use std::fmt;

use b4hub_core::push::{alert_title, request_reason, turn_reason, Reason, TURN_RECENCY_SECS};
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
            .finish()
    }
}

/// Which mirrored table a changed row came from, for the ledger's `kind`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Request,
    Turn,
}

impl Kind {
    /// The kind of notification a change to `table` can cause, if any.
    pub(crate) fn of_table(table: &str) -> Option<Kind> {
        match table {
            "runtimeRequests" => Some(Kind::Request),
            "turns" => Some(Kind::Turn),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Kind::Request => "request",
            Kind::Turn => "turn",
        }
    }
}

/// Stores `token` as `auth`'s device's push token, replacing any it had. The caller has checked
/// that the device is an iOS device and that `environment` is `sandbox` or `production`; the
/// table's check constraint refuses anything else.
pub async fn save_token(
    db: &Db,
    auth: &AuthedDevice,
    token: &str,
    environment: &str,
    bundle_id: &str,
) -> Result<()> {
    let mut tx = db.tenant_tx(auth.org_id).await?;
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

/// What the rules need to know about one changed row.
struct Subject {
    reason: Reason,
    thread_id: String,
    title: String,
}

/// Decides, for each row a push applied (`touched`, in batch order and without repeats), whether
/// it notifies, records the decision in the ledger, and returns one [`Notification`] per
/// registered phone of the user (other than the pusher's own device) for every row the ledger
/// had not seen. Runs in the push's transaction. A row whose time cannot be read is treated as
/// not recent rather than failing the batch.
pub(crate) async fn detect(
    tx: &mut Transaction<'_, Postgres>,
    auth: &AuthedDevice,
    touched: &[(Kind, String)],
) -> Result<Vec<Notification>> {
    let mut notifications = Vec::new();
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

        let phones: Vec<(Uuid, String, String, String)> = sqlx::query_as(
            "SELECT d.id, p.token, p.environment, p.bundle_id \
             FROM push_tokens p \
             JOIN devices d ON d.id = p.device_id AND d.org_id = p.org_id \
             WHERE p.org_id = $1 AND d.user_id = $2 AND d.platform = 'ios' \
               AND d.revoked_at IS NULL AND d.id <> $3 \
             ORDER BY d.id",
        )
        .bind(auth.org_id)
        .bind(auth.user_id)
        .bind(auth.device_id)
        .fetch_all(&mut **tx)
        .await?;
        for (device_id, token, environment, bundle_id) in phones {
            notifications.push(Notification {
                device_id,
                token,
                environment,
                bundle_id,
                thread_id: subject.thread_id.clone(),
                title: subject.title.clone(),
                reason: subject.reason,
            });
        }
    }
    Ok(notifications)
}

/// Reads the row (scoped to the org and the pushing user) with its thread's title and applies
/// the rules. `None` when the row is gone, has no thread to open, or the rules say no.
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
                        r.\"threadId\" AS thread_id, t.\"title\" AS title \
                 FROM \"runtimeRequests\" r \
                 LEFT JOIN \"threads\" t ON t.org_id = r.org_id AND t.user_id = r.user_id \
                                        AND t.\"id\" = r.\"threadId\" \
                 WHERE r.org_id = $1 AND r.user_id = $2 AND r.\"id\" = $3",
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
                        CASE WHEN u.\"updatedAt\" ~ '^\\d{4}-\\d{2}-\\d{2}T' \
                             THEN u.\"updatedAt\"::timestamptz > now() - make_interval(secs => $4) \
                             ELSE false END AS recent \
                 FROM \"turns\" u \
                 LEFT JOIN \"threads\" t ON t.org_id = u.org_id AND t.user_id = u.user_id \
                                        AND t.\"id\" = u.\"threadId\" \
                 WHERE u.org_id = $1 AND u.user_id = $2 AND u.\"id\" = $3",
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
}

#[derive(FromRow)]
struct TurnRow {
    status: Option<String>,
    outcome: Option<String>,
    thread_id: Option<String>,
    title: Option<String>,
    recent: bool,
}
