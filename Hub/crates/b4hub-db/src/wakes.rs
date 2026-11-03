//! Push wake-ups between instances, over PostgreSQL `LISTEN` / `NOTIFY` on one channel. After a
//! push commits, the instance that took it [`announce`]s the org; every instance holds a
//! [`Listener`] and wakes its own long-polls for that org. The instance that took the push has
//! already woken its own, so the payload names it and it skips its own announcements.
//!
//! A wake-up is a hint, never the data: a lost one (the listener's connection dropped, or the
//! announce failed) costs a long-poll at most its wait, after which it queries anyway. The
//! listener reports a dropped connection so its caller can wake everyone instead.

use sqlx::postgres::{PgListener, PgPoolOptions};
use sqlx::types::Uuid;

use crate::{Db, Result};

/// The notification channel.
pub const CHANNEL: &str = "b4hub_changes";

/// Tells every listening instance that `org` has new changes, from `instance`. Call it after the
/// push has committed.
pub async fn announce(db: &Db, org: Uuid, instance: Uuid) -> Result<()> {
    sqlx::query("SELECT pg_notify($1, $2)")
        .bind(CHANNEL)
        .bind(format!("{org} {instance}"))
        .execute(&db.pool)
        .await?;
    Ok(())
}

/// What [`Listener::next`] heard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Wake {
    /// `org` has new changes, announced by `instance`.
    Org { org: Uuid, instance: Uuid },
    /// The connection dropped and was (or will be) re-established; announcements in between are
    /// lost.
    Lost,
}

/// A `LISTEN` on [`CHANNEL`] over a connection of its own, outside the service's pool, so it
/// never takes one of the pool's connections. It reconnects and listens again on its own.
pub struct Listener(PgListener);

impl Listener {
    /// Connects with `db`'s settings and starts listening.
    pub async fn connect(db: &Db) -> Result<Listener> {
        let options = (*db.pool.connect_options()).clone();
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect_lazy_with(options);
        let mut listener = PgListener::connect_with(&pool).await?;
        listener.listen(CHANNEL).await?;
        Ok(Listener(listener))
    }

    /// The next wake-up. A payload that does not parse is skipped.
    pub async fn next(&mut self) -> Result<Wake> {
        loop {
            let Some(notification) = self.0.try_recv().await? else {
                return Ok(Wake::Lost);
            };
            if let Some(wake) = parse(notification.payload()) {
                return Ok(wake);
            }
        }
    }
}

fn parse(payload: &str) -> Option<Wake> {
    let (org, instance) = payload.split_once(' ')?;
    Some(Wake::Org {
        org: org.parse().ok()?,
        instance: instance.parse().ok()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_what_announce_sends() {
        let (org, instance) = (Uuid::from_u128(1), Uuid::from_u128(2));
        assert_eq!(
            parse(&format!("{org} {instance}")),
            Some(Wake::Org { org, instance })
        );
        assert_eq!(parse("not a wake"), None);
        assert_eq!(parse(&org.to_string()), None);
    }
}
