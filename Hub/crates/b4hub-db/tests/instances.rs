//! Instances and the per-user link claim (`hub_instances`, `user_links`). Run with
//! `source <(./scripts/test-db.sh)` first.

mod common;

use std::time::Duration;

use b4hub_db::instances::{self, Claim, Pruned};
use b4hub_db::Db;
use sqlx::types::Uuid;
use sqlx::PgPool;

const WINDOW: Duration = Duration::from_secs(20);

/// Makes `instance`'s heartbeat `seconds` old, as if it had stopped writing then.
async fn age(admin: &Db, instance: Uuid, seconds: i32) {
    sqlx::query(
        "UPDATE hub_instances SET heartbeat_at = now() - make_interval(secs => $2) \
         WHERE instance_id = $1",
    )
    .bind(instance)
    .bind(f64::from(seconds))
    .execute(&admin.pool)
    .await
    .unwrap();
}

#[sqlx::test(migrations = false)]
async fn a_live_owner_keeps_its_claim_and_a_dead_one_loses_it(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (a, b) = (Uuid::now_v7(), Uuid::now_v7());
    let user = Uuid::now_v7();
    instances::register(&app, a, Some("https://hub.example.test"))
        .await
        .unwrap();
    instances::register(&app, b, None).await.unwrap();

    // Nobody holds the user: the first instance to ask gets it, and keeps it on asking again.
    assert_eq!(
        instances::claim_user(&app, user, a, WINDOW).await.unwrap(),
        Claim::Ours
    );
    assert_eq!(
        instances::claim_user(&app, user, a, WINDOW).await.unwrap(),
        Claim::Ours
    );
    // The other instance is told who holds it.
    assert_eq!(
        instances::claim_user(&app, user, b, WINDOW).await.unwrap(),
        Claim::Other(a)
    );
    assert_eq!(instances::owner_of(&app, user).await.unwrap(), Some(a));

    // `a` stops heartbeating: within the window it still holds the user, after it it does not.
    age(&admin, a, 10).await;
    assert_eq!(
        instances::claim_user(&app, user, b, WINDOW).await.unwrap(),
        Claim::Other(a)
    );
    age(&admin, a, 25).await;
    assert_eq!(
        instances::claim_user(&app, user, b, WINDOW).await.unwrap(),
        Claim::Ours
    );
    // `a` comes back and finds the user served elsewhere, and is told to look there.
    assert!(instances::heartbeat(&app, a).await.unwrap());
    assert_eq!(
        instances::claim_user(&app, user, a, WINDOW).await.unwrap(),
        Claim::Other(b)
    );
    assert_eq!(
        instances::lost_claims(&app, a, &[user, Uuid::now_v7()])
            .await
            .unwrap(),
        vec![user]
    );
    assert!(instances::lost_claims(&app, b, &[user])
        .await
        .unwrap()
        .is_empty());
}

#[sqlx::test(migrations = false)]
async fn an_unregistered_owner_counts_as_dead(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let (ghost, live) = (Uuid::now_v7(), Uuid::now_v7());
    let user = Uuid::now_v7();
    instances::register(&app, live, None).await.unwrap();
    assert_eq!(
        instances::claim_user(&app, user, ghost, WINDOW)
            .await
            .unwrap(),
        Claim::Ours
    );
    assert_eq!(
        instances::claim_user(&app, user, live, WINDOW)
            .await
            .unwrap(),
        Claim::Ours
    );
}

#[sqlx::test(migrations = false)]
async fn concurrent_claims_agree_on_one_winner(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let (a, b) = (Uuid::now_v7(), Uuid::now_v7());
    instances::register(&app, a, None).await.unwrap();
    instances::register(&app, b, None).await.unwrap();
    for _ in 0..20 {
        let user = Uuid::now_v7();
        let (left, right) = tokio::join!(
            instances::claim_user(&app, user, a, WINDOW),
            instances::claim_user(&app, user, b, WINDOW)
        );
        let owner = instances::owner_of(&app, user).await.unwrap().unwrap();
        let expect = |me: Uuid| {
            if owner == me {
                Claim::Ours
            } else {
                Claim::Other(owner)
            }
        };
        assert_eq!(left.unwrap(), expect(a));
        assert_eq!(right.unwrap(), expect(b));
    }
}

#[sqlx::test(migrations = false)]
async fn release_and_prune_clear_claims(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let (a, b, dead) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
    let (u1, u2, u3) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
    for instance in [a, b, dead] {
        instances::register(&app, instance, None).await.unwrap();
    }
    instances::claim_user(&app, u1, a, WINDOW).await.unwrap();
    instances::claim_user(&app, u2, b, WINDOW).await.unwrap();
    instances::claim_user(&app, u3, dead, WINDOW).await.unwrap();

    // A draining instance gives up its users and its row.
    assert_eq!(instances::release_claims(&app, a).await.unwrap(), 1);
    assert_eq!(instances::owner_of(&app, u1).await.unwrap(), None);
    assert!(!instances::heartbeat(&app, a).await.unwrap());
    assert_eq!(
        instances::claim_user(&app, u1, b, WINDOW).await.unwrap(),
        Claim::Ours
    );

    // The prune drops the dead instance and its claim, and leaves the live ones alone.
    age(&admin, dead, 60).await;
    assert_eq!(
        instances::prune(&app, WINDOW).await.unwrap(),
        Pruned {
            instances: 1,
            claims: 1
        }
    );
    assert_eq!(instances::owner_of(&app, u3).await.unwrap(), None);
    assert_eq!(instances::owner_of(&app, u2).await.unwrap(), Some(b));
    assert_eq!(
        instances::prune(&app, WINDOW).await.unwrap(),
        Pruned::default()
    );
}
