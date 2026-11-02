//! The relay on more than one instance (M8e Part B): two `serve` instances in one test process,
//! each on its own loopback listener, sharing one database, with different instance ids and a
//! shortened heartbeat. Also the readiness probe and the stale-heartbeat report. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod relay_support;

use std::time::Duration;

use axum::http::StatusCode;
use b4hub::relay::close_code;
use b4hub_core::relay::RelayMethod;
use b4hub_db::instances;
use serde_json::json;
use sqlx::types::Uuid;
use sqlx::PgPool;

use relay_support::{eventually, real_sleep, spawn_instance, FakeDevice, Hub, Seeded};

/// The test heartbeat: the liveness window is four of these.
const BEAT: Duration = Duration::from_millis(200);

/// A user with a Mac and a phone, and a thread owned by the Mac, enrolled through `hub`.
struct User {
    who: Seeded,
    mac_token: String,
    mac_id: Uuid,
    phone_token: String,
    phone_id: Uuid,
}

async fn user(hub: &Hub) -> User {
    let who = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&who, "macos", "Brian's Mac").await;
    let (phone_token, phone_id) = hub.enroll(&who, "ios", "iPhone").await;
    hub.seed_thread(&who, mac_id, "thread-1").await;
    User {
        who,
        mac_token,
        mac_id,
        phone_token,
        phone_id,
    }
}

fn cookie_for(hub: &Hub) -> String {
    format!(
        "b4hub-instance={}; Path=/; Max-Age=3600; Secure; HttpOnly",
        hub.state.instances.id()
    )
}

/// Opens a link to `hub` with `token`; returns the device after its first frames, and the upgrade
/// response's `Set-Cookie`.
async fn link(hub: &Hub, token: &str, cookie: Option<&str>) -> (FakeDevice, Option<String>) {
    let (mut device, set_cookie) =
        FakeDevice::try_connect_with_cookie(hub.addr, Some(token), None, cookie)
            .await
            .unwrap_or_else(|refused| panic!("the hub refused the upgrade: {refused:?}"));
    device.next().await; // hello
    (device, set_cookie)
}

#[sqlx::test(migrations = false)]
async fn a_link_on_the_wrong_instance_is_relocated_and_the_retry_completes_a_command(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    assert_ne!(a.state.instances.id(), b.state.instances.id());
    let blove = user(&a).await;

    // The Mac reaches `a` first: `a` claims the user and names itself in the cookie.
    let (mut mac, set_cookie) = link(&a, &blove.mac_token, None).await;
    assert_eq!(set_cookie.as_deref(), Some(cookie_for(&a).as_str()));
    mac.expect_watching().await;

    // The phone reaches `b`: refused before any socket, naming `a`, with no cookie (the load
    // balancer would bind it to `b`), and nothing about it enters `b`'s relay.
    let refused = FakeDevice::try_connect(b.addr, Some(&blove.phone_token), None)
        .await
        .err()
        .expect("the wrong instance refuses the upgrade");
    assert_eq!(refused.status, 409);
    assert_eq!(refused.code(), "relocated");
    assert_eq!(refused.body["error"]["kind"], "request_error");
    assert_eq!(
        refused.body["error"]["details"]["instanceId"],
        a.state.instances.id().to_string()
    );
    assert_eq!(refused.set_cookie, None);
    assert!(!b.state.relay.online(blove.phone_id));
    assert!(b.state.relay.users().is_empty());
    assert_eq!(
        instances::owner_of(&a.state.db, blove.who.user_id)
            .await
            .unwrap(),
        Some(a.state.instances.id())
    );

    // The retry (with the cookie the device keeps) lands on `a` and is served there.
    let cookie = format!("b4hub-instance={}", a.state.instances.id());
    let (mut phone, set_cookie) = link(&a, &blove.phone_token, Some(&cookie)).await;
    assert_eq!(set_cookie.as_deref(), Some(cookie_for(&a).as_str()));
    phone
        .command(
            "send-1",
            RelayMethod::TurnSend,
            json!({"threadId": "thread-1", "text": "hello"}),
        )
        .await;
    let (id, method, ..) = mac.expect_command().await;
    assert_eq!((id.as_str(), method), ("send-1", RelayMethod::TurnSend));
    mac.reply("send-1", json!({"turnId": "turn-1"})).await;
    assert_eq!(
        phone.expect_reply().await,
        (
            "send-1".to_string(),
            Some(json!({"turnId": "turn-1"})),
            None
        )
    );
}

#[sqlx::test(migrations = false)]
async fn one_link_per_device_holds_across_instances(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    let (mut mac, _) = link(&a, &blove.mac_token, None).await;
    mac.expect_watching().await;

    // The same Mac trying `b` gets no second link; its link on `a` is untouched.
    for _ in 0..3 {
        let refused = FakeDevice::try_connect(b.addr, Some(&blove.mac_token), None)
            .await
            .err()
            .expect("refused");
        assert_eq!((refused.status, refused.code()), (409, "relocated"));
    }
    assert!(a.state.relay.online(blove.mac_id));
    assert!(!b.state.relay.online(blove.mac_id));
    mac.ping().await;

    // On `a`, a second link replaces the first, exactly as on one instance.
    let (_newer, _) = link(&a, &blove.mac_token, None).await;
    assert_eq!(mac.expect_close().await, close_code::REPLACED);
}

#[sqlx::test(migrations = false)]
async fn a_dead_heartbeat_lets_the_other_instance_claim_and_the_old_owner_lets_go(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    let (mut mac, _) = link(&a, &blove.mac_token, None).await;
    mac.expect_watching().await;
    assert_eq!(
        FakeDevice::try_connect(b.addr, Some(&blove.phone_token), None)
            .await
            .err()
            .expect("refused while `a` is alive")
            .status,
        409
    );

    // `a` stops writing its heartbeat (a database that refuses it). Within the window it still
    // holds the user; once the window passes, `b` claims the user for the phone.
    a.state.instances.pause_heartbeat(true);
    let window = a.state.instances.alive_within();
    real_sleep(window / 2).await;
    assert_eq!(
        FakeDevice::try_connect(b.addr, Some(&blove.phone_token), None)
            .await
            .err()
            .expect("still refused inside the window")
            .status,
        409
    );
    real_sleep(window / 2 + BEAT * 2).await;
    let mut phone = FakeDevice::try_connect(b.addr, Some(&blove.phone_token), None)
        .await
        .unwrap_or_else(|refused| panic!("`b` should claim the user now: {refused:?}"));
    phone.next().await; // hello
    assert_eq!(
        instances::owner_of(&b.state.db, blove.who.user_id)
            .await
            .unwrap(),
        Some(b.state.instances.id())
    );

    // `a` recovers, sees that `b` serves the user now, and closes the Mac's link (1001: reconnect),
    // so one user's links are not split. The Mac's reconnect to `a` is relocated to `b`.
    a.state.instances.pause_heartbeat(false);
    assert_eq!(mac.expect_close().await, close_code::SHUTDOWN);
    eventually("`a` to drop the Mac", || async {
        (!a.state.relay.online(blove.mac_id)).then_some(())
    })
    .await;
    let refused = FakeDevice::try_connect(a.addr, Some(&blove.mac_token), None)
        .await
        .err()
        .expect("relocated");
    assert_eq!(
        refused.body["error"]["details"]["instanceId"],
        b.state.instances.id().to_string()
    );
    let (mut mac, _) = link(&b, &blove.mac_token, None).await;
    mac.expect_watching().await;
    phone
        .command(
            "send-2",
            RelayMethod::TurnSend,
            json!({"threadId": "thread-1", "text": "again"}),
        )
        .await;
    let (id, ..) = mac.expect_command().await;
    assert_eq!(id, "send-2");
}

#[sqlx::test(migrations = false)]
async fn a_draining_instance_answers_holds_and_releases_its_claims(pool: PgPool) {
    let mut a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;

    // The Mac links to `a` and leaves: offline, seen a moment ago, so an interrupt is held.
    let (mac, _) = link(&a, &blove.mac_token, None).await;
    mac.close().await;
    eventually("the Mac to go offline", || async {
        (!a.state.relay.online(blove.mac_id)).then_some(())
    })
    .await;
    let (mut phone, _) = link(&a, &blove.phone_token, None).await;
    phone
        .command(
            "stop-1",
            RelayMethod::TurnInterrupt,
            json!({"threadId": "thread-1"}),
        )
        .await;
    eventually("the interrupt to be held", || async {
        (a.state.relay.held(blove.mac_id) == 1).then_some(())
    })
    .await;

    // SIGTERM: the hold is answered `device_offline` before the link closes with 1001.
    a.signal();
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("stop-1", "device_offline")
    );
    assert_eq!(phone.expect_close().await, close_code::SHUTDOWN);
    tokio::time::timeout(Duration::from_secs(5), &mut a.server)
        .await
        .expect("the drain finishes")
        .unwrap()
        .unwrap();

    // Its claims and its row are gone, so the phone is claimed at once by `b`, well inside the
    // heartbeat window.
    assert_eq!(
        instances::owner_of(&b.state.db, blove.who.user_id)
            .await
            .unwrap(),
        None
    );
    let (_phone, set_cookie) = link(&b, &blove.phone_token, None).await;
    assert_eq!(set_cookie.as_deref(), Some(cookie_for(&b).as_str()));
}

#[sqlx::test(migrations = false)]
async fn the_probe_passes_on_a_healthy_instance_and_fails_when_the_relay_cannot_serve(
    pool: PgPool,
) {
    let hub = spawn_instance(&pool, BEAT).await;
    let blove = user(&hub).await;
    let (mut phone, _) = link(&hub, &blove.phone_token, None).await;
    phone.next().await; // presence

    let (status, body) = hub.http("GET", "/readyz", None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        (body["relay"].as_str(), body["instances"].as_str()),
        (Some("ok"), Some("ok"))
    );
    // The probe never shows: not online, not a user, and the phone heard nothing about it.
    assert!(!hub.state.relay.online(Uuid::nil()));
    assert_eq!(hub.state.relay.users(), [blove.who.user_id]);
    phone.expect_quiet(Duration::from_millis(300)).await;

    // A relay that refuses the hub's own protocol cannot serve a link: the probe fails.
    hub.state.relay.set_min_client_protocol(2);
    let (status, body) = hub.http("GET", "/readyz", None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"]["details"]["code"], "not_ready");
    assert_eq!(body["error"]["details"]["relay"], "failed");
    assert_eq!(body["error"]["details"]["instances"], "ok");

    hub.state.relay.set_min_client_protocol(1);
    let (status, _) = hub.http("GET", "/readyz", None).await;
    assert_eq!(status, StatusCode::OK);
}

#[sqlx::test(migrations = false)]
async fn readiness_reports_a_stale_heartbeat(pool: PgPool) {
    let hub = spawn_instance(&pool, BEAT).await;
    let (status, _) = hub.http("GET", "/readyz", None).await;
    assert_eq!(status, StatusCode::OK);

    hub.state.instances.pause_heartbeat(true);
    real_sleep(hub.state.instances.alive_within() + BEAT).await;
    let (status, body) = hub.http("GET", "/readyz", None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(body["error"]["details"]["instances"], "stale");
    assert_eq!(body["error"]["details"]["relay"], "ok");

    hub.state.instances.pause_heartbeat(false);
    eventually("the heartbeat to be fresh again", || async {
        (hub.http("GET", "/readyz", None).await.0 == StatusCode::OK).then_some(())
    })
    .await;
}

#[sqlx::test(migrations = false)]
async fn readiness_names_the_instance_in_a_cookie(pool: PgPool) {
    let hub = spawn_instance(&pool, BEAT).await;
    assert_eq!(set_cookie_of(&hub, "/readyz").await, Some(cookie_for(&hub)));
    // A failing readiness answer names the instance too.
    hub.state.relay.set_min_client_protocol(2);
    assert_eq!(set_cookie_of(&hub, "/readyz").await, Some(cookie_for(&hub)));
}

/// The `Set-Cookie` of an in-process GET through the hub's router.
async fn set_cookie_of(hub: &Hub, path: &str) -> Option<String> {
    use axum::body::Body;
    use axum::http::{header, Request};
    use tower::ServiceExt;
    let response = b4hub::serve::router(hub.state.clone())
        .oneshot(Request::get(path).body(Body::empty()).unwrap())
        .await
        .unwrap();
    response
        .headers()
        .get(header::SET_COOKIE)
        .map(|value| value.to_str().unwrap().to_string())
}
