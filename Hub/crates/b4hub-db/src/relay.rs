//! What the relay reads and writes in the database: a user's Macs for the presence frame,
//! `devices.last_seen_at` as a link reports it, and the device that owns the thread, runtime
//! request, or environment a command names.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::devices::{self, AuthedDevice, SessionKey};
use b4hub_core::protocol::{ClientProtocol, ProtocolFloor};
use sqlx::types::Uuid;
use sqlx::{PgConnection, Postgres, Transaction};

use crate::{Db, Result};

/// One of a user's Macs: its id, its name, and when it was last heard from as RFC 3339 in UTC with
/// milliseconds (`None` for a Mac never seen).
pub type HostRow = (Uuid, String, Option<String>);

/// The user's non-revoked `macos` devices, oldest first. This is the host list of a `presence`
/// frame: it is filtered by org and user, so one user's Macs never reach another user.
pub async fn host_devices(db: &Db, org_id: Uuid, user_id: Uuid) -> Result<Vec<HostRow>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let value = host_devices_in(&mut tx, org_id, user_id).await?;
    tx.commit().await?;
    Ok(value)
}

async fn host_devices_in(
    conn: &mut PgConnection,
    org_id: Uuid,
    user_id: Uuid,
) -> Result<Vec<HostRow>> {
    let hosts = sqlx::query_as(
        "SELECT id, name, \
                to_char(last_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') \
         FROM devices \
         WHERE org_id = $1 AND user_id = $2 AND platform = 'macos' AND revoked_at IS NULL \
         ORDER BY created_at, id",
    )
    .bind(org_id)
    .bind(user_id)
    .fetch_all(conn)
    .await?;
    Ok(hosts)
}

/// Records that the device was heard from at `at`. It never moves `last_seen_at` backwards: a
/// link that closes late reports the time of its last frame, and by then a newer link of the same
/// device (or the request throttle) may already have written a later time.
pub async fn set_last_seen(db: &Db, org_id: Uuid, device_id: Uuid, at: SystemTime) -> Result<()> {
    let seconds = at
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64());
    let mut tx = db.tenant_tx(org_id).await?;
    sqlx::query(
        "UPDATE devices SET last_seen_at = GREATEST(last_seen_at, to_timestamp($2)) WHERE id = $1",
    )
    .bind(device_id)
    .bind(seconds)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// The device that owns a row a command names, as the router needs it: who it is, whether it may
/// receive commands (a `macos` device of the caller's user that is not revoked), and when it was
/// last heard from.
#[derive(Debug, Clone, PartialEq)]
pub struct Owner {
    pub device_id: Uuid,
    pub user_id: Uuid,
    pub name: String,
    /// `macos`, `ios`, or `cli`.
    pub platform: String,
    pub revoked: bool,
    /// `devices.last_seen_at`; `None` for a device never seen.
    pub last_seen_at: Option<SystemTime>,
}

/// A runtime request's owner (the owner of the request's thread) and the request's materialised
/// `state` (`pending`, `resolved`, ...; `None` when the row has none).
#[derive(Debug, Clone, PartialEq)]
pub struct RequestOwner {
    pub owner: Owner,
    pub state: Option<String>,
}

type OwnerRow = (Uuid, Uuid, String, String, bool, Option<f64>);
/// An [`OwnerRow`] and the request's state.
type RequestRow = (
    Uuid,
    Uuid,
    String,
    String,
    bool,
    Option<f64>,
    Option<String>,
);

/// The same owner projection plus a connection's native protocol classification inputs.
type ConnectionOwnerRow = (
    Uuid,
    Uuid,
    String,
    String,
    bool,
    Option<f64>,
    Option<String>,
    bool,
);

/// The columns of an [`OwnerRow`], from the `devices` row aliased `d`.
const OWNER_COLUMNS: &str = "d.id, d.user_id, d.name, d.platform, d.revoked_at IS NOT NULL, \
                             extract(epoch FROM d.last_seen_at)::float8";

fn owner((device_id, user_id, name, platform, revoked, seen): OwnerRow) -> Owner {
    Owner {
        device_id,
        user_id,
        name,
        platform,
        revoked,
        last_seen_at: seen
            .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
            .map(|seconds| UNIX_EPOCH + Duration::from_secs_f64(seconds)),
    }
}

/// The owner of the user's thread `thread_id` (`threads.owner_device_id`). `None` when the org has
/// no such thread, when it is another user's or deleted, or when its owner is not a device of this
/// org.
pub async fn owner_of_thread(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    thread_id: &str,
) -> Result<Option<Owner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let value = owner_of_thread_in(&mut tx, org_id, user_id, thread_id).await?;
    tx.commit().await?;
    Ok(value)
}

async fn owner_of_thread_in(
    conn: &mut PgConnection,
    org_id: Uuid,
    user_id: Uuid,
    thread_id: &str,
) -> Result<Option<Owner>> {
    let row: Option<OwnerRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS} FROM \"threads\" t \
         JOIN devices d ON d.id = t.owner_device_id AND d.org_id = t.org_id \
         WHERE t.org_id = $1 AND t.user_id = $2 AND t.\"id\" = $3 AND t.deleted_at IS NULL"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(thread_id)
    .fetch_optional(conn)
    .await?;
    Ok(row.map(owner))
}

/// The owner of the thread of the user's runtime request `request_id` (through
/// `"runtimeRequests"."threadId"`), with the request's state. `None` when either row is missing,
/// deleted, or not the user's.
pub async fn owner_of_request(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    request_id: &str,
) -> Result<Option<RequestOwner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let value = owner_of_request_in(&mut tx, org_id, user_id, request_id).await?;
    tx.commit().await?;
    Ok(value)
}

async fn owner_of_request_in(
    conn: &mut PgConnection,
    org_id: Uuid,
    user_id: Uuid,
    request_id: &str,
) -> Result<Option<RequestOwner>> {
    let row: Option<RequestRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS}, r.\"state\" FROM \"runtimeRequests\" r \
         JOIN \"threads\" t ON t.org_id = r.org_id AND t.\"id\" = r.\"threadId\" \
         JOIN devices d ON d.id = t.owner_device_id AND d.org_id = t.org_id \
         WHERE r.org_id = $1 AND r.user_id = $2 AND r.\"id\" = $3 AND t.user_id = $2 \
               AND r.deleted_at IS NULL AND t.deleted_at IS NULL"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(request_id)
    .fetch_optional(conn)
    .await?;
    Ok(row.map(
        |(device, user, name, platform, revoked, seen, state)| RequestOwner {
            owner: owner((device, user, name, platform, revoked, seen)),
            state,
        },
    ))
}

/// The owner of the user's environment `environment_id` (`environments.owner_device_id`).
pub async fn owner_of_environment(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    environment_id: &str,
) -> Result<Option<Owner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let value = owner_of_environment_in(&mut tx, org_id, user_id, environment_id).await?;
    tx.commit().await?;
    Ok(value)
}

async fn owner_of_environment_in(
    conn: &mut PgConnection,
    org_id: Uuid,
    user_id: Uuid,
    environment_id: &str,
) -> Result<Option<Owner>> {
    let row: Option<OwnerRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS} FROM \"environments\" p \
         JOIN devices d ON d.id = p.owner_device_id AND d.org_id = p.org_id \
         WHERE p.org_id = $1 AND p.user_id = $2 AND p.\"id\" = $3 AND p.deleted_at IS NULL"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(environment_id)
    .fetch_optional(conn)
    .await?;
    Ok(row.map(owner))
}

/// The user's device `device_id` as an [`Owner`]: how the router re-reads an owner it already
/// knows (a thread started moments ago, or a Mac that just went offline, whose `last_seen_at` is
/// then current). `None` when it is not a device of this user.
pub async fn owner_device(
    db: &Db,
    org_id: Uuid,
    user_id: Uuid,
    device_id: Uuid,
) -> Result<Option<Owner>> {
    let mut tx = db.tenant_tx(org_id).await?;
    let value = owner_device_in(&mut tx, org_id, user_id, device_id).await?;
    tx.commit().await?;
    Ok(value)
}

async fn owner_device_in(
    conn: &mut PgConnection,
    org_id: Uuid,
    user_id: Uuid,
    device_id: Uuid,
) -> Result<Option<Owner>> {
    let row: Option<OwnerRow> = sqlx::query_as(&format!(
        "SELECT {OWNER_COLUMNS} FROM devices d \
         WHERE d.org_id = $1 AND d.user_id = $2 AND d.id = $3"
    ))
    .bind(org_id)
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(conn)
    .await?;
    Ok(row.map(owner))
}

/// A native session and the floor that admitted it, retaining its AS lock and owned transaction.
/// Not Clone; commit consumes it. Do not retain it across queue, offline or command waits.
pub struct Admission {
    tx: Transaction<'static, Postgres>,
    identity: AuthedDevice,
    device_name: String,
    session: SessionKey,
    client: ClientProtocol,
    floor: ProtocolFloor,
    registration_used: bool,
}
impl Admission {
    pub async fn open(
        db: &Db,
        session: &SessionKey,
        client: ClientProtocol,
    ) -> Result<Option<Self>> {
        let (mut tx, floor) = db.protocol_untenanted_read_tx(client).await?;
        let Some(identity) = devices::authenticate_session_in(&mut tx, session).await? else {
            tx.rollback().await?;
            return Ok(None);
        };
        let device_name: String = sqlx::query_scalar(
            "SELECT name FROM devices WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL",
        )
        .bind(identity.device_id)
        .bind(identity.user_id)
        .fetch_one(&mut *tx)
        .await?;
        Ok(Some(Self {
            tx,
            identity,
            device_name,
            session: *session,
            client,
            floor,
            registration_used: false,
        }))
    }
    pub fn identity(&self) -> &AuthedDevice {
        &self.identity
    }
    pub fn device_name(&self) -> &str {
        &self.device_name
    }
    pub fn session(&self) -> SessionKey {
        self.session
    }
    pub fn client(&self) -> ClientProtocol {
        self.client
    }
    pub fn floor(&self) -> ProtocolFloor {
        self.floor
    }
    /// A valid registration uses this live admission once. The caller commits after its short
    /// synchronous registry operation; an invalid identity attempt does not consume it.
    pub fn claim_registration(&mut self) -> bool {
        if self.registration_used {
            false
        } else {
            self.registration_used = true;
            true
        }
    }
    pub async fn commit(self) -> Result<()> {
        self.tx.commit().await?;
        Ok(())
    }
    pub async fn host_devices(&mut self) -> Result<Vec<HostRow>> {
        host_devices_in(&mut self.tx, self.identity.org_id, self.identity.user_id).await
    }
    pub async fn device(&mut self, id: Uuid) -> Result<Option<Owner>> {
        owner_device_in(
            &mut self.tx,
            self.identity.org_id,
            self.identity.user_id,
            id,
        )
        .await
    }
    pub async fn environment(&mut self, id: &str) -> Result<Option<Owner>> {
        owner_of_environment_in(
            &mut self.tx,
            self.identity.org_id,
            self.identity.user_id,
            id,
        )
        .await
    }
    pub async fn thread(&mut self, id: &str) -> Result<Option<RoutedTarget>> {
        let Some(owner) = owner_of_thread_in(
            &mut self.tx,
            self.identity.org_id,
            self.identity.user_id,
            id,
        )
        .await?
        else {
            return Ok(None);
        };
        let protocol = self.thread_protocol(id).await?;
        Ok(Some(RoutedTarget { owner, protocol }))
    }
    pub async fn request(&mut self, id: &str) -> Result<Option<RequestTarget>> {
        let Some(found) = owner_of_request_in(
            &mut self.tx,
            self.identity.org_id,
            self.identity.user_id,
            id,
        )
        .await?
        else {
            return Ok(None);
        };
        let thread:Option<String>=sqlx::query_scalar("SELECT \"threadId\" FROM \"runtimeRequests\" WHERE org_id=$1 AND user_id=$2 AND id=$3 AND deleted_at IS NULL")
            .bind(self.identity.org_id).bind(self.identity.user_id).bind(id).fetch_optional(&mut *self.tx).await?;
        let protocol = match thread {
            Some(id) => self.thread_protocol(&id).await?,
            None => TargetProtocol::Unknown,
        };
        Ok(Some(RequestTarget {
            target: RoutedTarget {
                owner: found.owner,
                protocol,
            },
            state: found.state,
        }))
    }
    pub async fn connection(&mut self, id: &str) -> Result<Option<RoutedTarget>> {
        let row:Option<ConnectionOwnerRow>=sqlx::query_as(&format!(
            "SELECT {OWNER_COLUMNS},c.kind,(c.\"peerProfile\" IS NOT NULL OR c.\"agentId\" IS NOT NULL OR c.\"protocolRetiredAt\" IS NOT NULL OR c.\"protocolRetiredReason\" IS NOT NULL) FROM connections c JOIN devices d ON d.id=c.owner_device_id AND d.org_id=c.org_id WHERE c.org_id=$1 AND c.user_id=$2 AND c.id=$3 AND c.deleted_at IS NULL"))
            .bind(self.identity.org_id).bind(self.identity.user_id).bind(id).fetch_optional(&mut *self.tx).await?;
        Ok(row.map(
            |(device, user, name, platform, revoked, seen, kind, metadata)| RoutedTarget {
                owner: owner((device, user, name, platform, revoked, seen)),
                protocol: TargetProtocol::native(kind.as_deref(), metadata),
            },
        ))
    }
    pub async fn thread_connection_matches(&mut self, id: &str, connection: &str) -> Result<bool> {
        let found:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM threads WHERE org_id=$1 AND user_id=$2 AND id=$3 AND \"connectionId\"=$4 AND deleted_at IS NULL)")
            .bind(self.identity.org_id).bind(self.identity.user_id).bind(id).bind(connection).fetch_one(&mut *self.tx).await?;
        Ok(found)
    }
    async fn thread_protocol(&mut self, id: &str) -> Result<TargetProtocol> {
        let row:Option<(Option<String>,bool)>=sqlx::query_as("SELECT c.kind,(c.\"peerProfile\" IS NOT NULL OR c.\"agentId\" IS NOT NULL OR c.\"protocolRetiredAt\" IS NOT NULL OR c.\"protocolRetiredReason\" IS NOT NULL) FROM threads t JOIN connections c ON c.org_id=t.org_id AND c.user_id=t.user_id AND c.id=t.\"connectionId\" WHERE t.org_id=$1 AND t.user_id=$2 AND t.id=$3 AND t.deleted_at IS NULL AND c.deleted_at IS NULL")
            .bind(self.identity.org_id).bind(self.identity.user_id).bind(id).fetch_optional(&mut *self.tx).await?;
        Ok(row.map_or(TargetProtocol::Unknown, |(kind, metadata)| {
            TargetProtocol::native(kind.as_deref(), metadata)
        }))
    }
}

/// Native classification, not a request/header claim. Unknown never implies a legacy target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetProtocol {
    Legacy,
    Protocol2,
    Unknown,
}
impl TargetProtocol {
    fn native(kind: Option<&str>, metadata: bool) -> Self {
        if metadata || kind == Some("agentProtocol") {
            Self::Protocol2
        } else if matches!(kind, Some("codex" | "claude" | "b4")) {
            Self::Legacy
        } else {
            Self::Unknown
        }
    }
    pub fn required(self) -> Option<ClientProtocol> {
        match self {
            Self::Legacy => Some(ClientProtocol::LEGACY),
            Self::Protocol2 => Some(ClientProtocol::SUPPORTED),
            Self::Unknown => None,
        }
    }
}
#[derive(Debug, Clone, PartialEq)]
pub struct RoutedTarget {
    pub owner: Owner,
    pub protocol: TargetProtocol,
}
#[derive(Debug, Clone, PartialEq)]
pub struct RequestTarget {
    pub target: RoutedTarget,
    pub state: Option<String>,
}

/// Readiness has no synthetic device/session. This distinct capability retains only a real
/// database floor barrier and cannot be passed to ordinary device registration or target APIs.
pub struct ProbeAdmission {
    tx: Transaction<'static, Postgres>,
    floor: ProtocolFloor,
    client: ClientProtocol,
    used: bool,
}
impl ProbeAdmission {
    pub async fn open(db: &Db, client: ClientProtocol) -> Result<Self> {
        let (tx, floor) = db.protocol_untenanted_read_tx(client).await?;
        Ok(Self {
            tx,
            floor,
            client,
            used: false,
        })
    }
    pub fn floor(&self) -> ProtocolFloor {
        self.floor
    }
    pub fn client(&self) -> ClientProtocol {
        self.client
    }
    pub fn claim_registration(&mut self) -> bool {
        if self.used {
            false
        } else {
            self.used = true;
            true
        }
    }
    pub async fn commit(self) -> Result<()> {
        self.tx.commit().await?;
        Ok(())
    }
}
