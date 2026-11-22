//! Signals between instances, over PostgreSQL `LISTEN` / `NOTIFY`. Each instance holds one
//! [`Listener`] on both channels:
//!
//! - [`CHANGES`]: after a push commits, the instance that took it [`announce`]s the org, and every
//!   other instance wakes its long-polls for that org (D-161).
//! - [`LINKS`]: after a session ends or a device or account goes (log-out, revocation, account
//!   deletion, a merge), the instance that did it asks for a [`recheck`] of the user's links, and
//!   the instance that serves them looks each link's session up again and closes the dead ones
//!   (D-162).
//! - [`ECHO`]: every instance heartbeat also [`echo`]es, so a listener always hears something; one
//!   that hears nothing for a liveness window is presumed cut off (a half-open connection reports
//!   no error) and reconnects (D-164).
//!
//! The payloads name the sending instance, which skips its own (it acted already), and carry ids
//! only, never a token or its hash. A signal is a hint, never the data: a lost one (a failed
//! `NOTIFY`, which callers log, or a dropped listener connection) costs a long-poll at most its
//! wait, and a link at most the once-a-minute check of its session.

use sqlx::postgres::PgListener;
use sqlx::types::Uuid;

use crate::{Db, Result};

/// The channel of push wake-ups.
pub const CHANGES: &str = "b4hub_changes";

/// The channel of link re-checks.
pub const LINKS: &str = "b4hub_links";

/// The channel of heartbeat echoes.
pub const ECHO: &str = "b4hub_echo";
/// The monotonic protocol-floor transaction committed. Payload is intentionally empty.
pub const PROTOCOL: &str = "b4hub_protocol";

/// Tells every listening instance that `org` has new changes, from `instance`. Call it after the
/// push has committed.
pub async fn announce(db: &Db, org: Uuid, instance: Uuid) -> Result<()> {
    notify(db, CHANGES, format!("{org} {instance}")).await
}

/// Asks every listening instance to look the sessions of `user`'s links up again, from
/// `instance`. Call it after the change that ended them has committed.
pub async fn recheck(db: &Db, org: Uuid, user: Uuid, instance: Uuid) -> Result<()> {
    notify(db, LINKS, format!("{org} {user} {instance}")).await
}

/// Sends `instance`'s heartbeat echo, which proves every listener's connection still delivers.
pub async fn echo(db: &Db, instance: Uuid) -> Result<()> {
    notify(db, ECHO, instance.to_string()).await
}

async fn notify(db: &Db, channel: &str, payload: String) -> Result<()> {
    sqlx::query("SELECT pg_notify($1, $2)")
        .bind(channel)
        .bind(payload)
        .execute(&db.pool)
        .await?;
    Ok(())
}

/// What [`Listener::next`] heard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    ProtocolFloor,
    /// `org` has new changes, announced by `instance`.
    Changes {
        org: Uuid,
        instance: Uuid,
    },
    /// `user`'s links should be checked again, asked by `instance`.
    Recheck {
        org: Uuid,
        user: Uuid,
        instance: Uuid,
    },
    /// `instance`'s heartbeat echo: nothing to do but note that the connection works.
    Echo {
        instance: Uuid,
    },
    /// The connection dropped and was re-established; signals in between are lost.
    Lost,
}

/// A `LISTEN` on [`CHANGES`], [`LINKS`], and [`ECHO`] over [`Db::dedicated`], so it never takes one of the
/// service pool's connections. It reconnects and listens again on its own.
pub struct Listener(PgListener);

impl Listener {
    /// Connects with `db`'s settings and starts listening.
    pub async fn connect(db: &Db) -> Result<Listener> {
        let mut listener = PgListener::connect_with(&db.dedicated().pool).await?;
        listener
            .listen_all([CHANGES, LINKS, ECHO, PROTOCOL])
            .await?;
        Ok(Listener(listener))
    }

    /// The next signal. A payload that does not parse is skipped.
    pub async fn next(&mut self) -> Result<Signal> {
        loop {
            let Some(notification) = self.0.try_recv().await? else {
                return Ok(Signal::Lost);
            };
            if let Some(signal) = parse(notification.channel(), notification.payload()) {
                return Ok(signal);
            }
        }
    }
}

fn parse(channel: &str, payload: &str) -> Option<Signal> {
    if channel == PROTOCOL {
        return payload.is_empty().then_some(Signal::ProtocolFloor);
    }
    let ids = payload
        .split(' ')
        .map(|id| id.parse::<Uuid>().ok())
        .collect::<Option<Vec<_>>>()?;
    match (channel, ids.as_slice()) {
        (CHANGES, &[org, instance]) => Some(Signal::Changes { org, instance }),
        (LINKS, &[org, user, instance]) => Some(Signal::Recheck {
            org,
            user,
            instance,
        }),
        (ECHO, &[instance]) => Some(Signal::Echo { instance }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_what_announce_and_recheck_send() {
        let (org, user, instance) = (Uuid::from_u128(1), Uuid::from_u128(2), Uuid::from_u128(3));
        assert_eq!(
            parse(CHANGES, &format!("{org} {instance}")),
            Some(Signal::Changes { org, instance })
        );
        assert_eq!(
            parse(LINKS, &format!("{org} {user} {instance}")),
            Some(Signal::Recheck {
                org,
                user,
                instance
            })
        );
        assert_eq!(
            parse(ECHO, &instance.to_string()),
            Some(Signal::Echo { instance })
        );
        assert_eq!(parse(CHANGES, &format!("{org} {user} {instance}")), None);
        assert_eq!(parse(LINKS, &format!("{org} {instance}")), None);
        assert_eq!(parse(CHANGES, "not a signal"), None);
        assert_eq!(parse("other", &format!("{org} {instance}")), None);
    }
}
