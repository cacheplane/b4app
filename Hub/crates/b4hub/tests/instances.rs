//! The relay on more than one instance (M8e Part B): two `serve` instances in one test process,
//! each on its own loopback listener, sharing one database, with different instance ids and a
//! shortened heartbeat. Also the readiness probe and the stale-heartbeat report. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod relay_support;

use std::time::Duration;

use axum::http::StatusCode;
use b4hub::instances::DEFAULT_HEARTBEAT;
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
    a.state.instances.settle().await;
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
    // The default heartbeat: this test is about the relay, and with the short test heartbeat a
    // loaded runner could stall the writes long enough to report the instance stale as well.
    let hub = spawn_instance(&pool, DEFAULT_HEARTBEAT).await;
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
    // Ready once a heartbeat has landed within the window. A loaded runner can stall the writes for
    // longer than this test's short window, so wait for a fresh one rather than assume it.
    eventually("the heartbeat to be fresh", || async {
        (hub.http("GET", "/readyz", None).await.0 == StatusCode::OK).then_some(())
    })
    .await;

    hub.state.instances.pause_heartbeat(true);
    // A write already past the pause check may still land; once it has, the last write is behind
    // us and the window below is measured from no later than now.
    hub.state.instances.settle().await;
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

#[sqlx::test(migrations = false)]
async fn a_hold_that_was_forwarded_does_not_delay_the_drain(pool: PgPool) {
    let hub = spawn_instance(&pool, BEAT).await;
    let blove = user(&hub).await;
    let (mac, _) = link(&hub, &blove.mac_token, None).await;
    mac.close().await;
    eventually("the Mac to go offline", || async {
        (!hub.state.relay.online(blove.mac_id)).then_some(())
    })
    .await;
    let (mut phone, _) = link(&hub, &blove.phone_token, None).await;
    phone
        .command(
            "stop-1",
            RelayMethod::TurnInterrupt,
            json!({"threadId": "thread-1"}),
        )
        .await;
    eventually("the interrupt to be held", || async {
        (hub.state.relay.held(blove.mac_id) == 1).then_some(())
    })
    .await;
    // The Mac comes back and gets the command; it has not answered yet.
    let (mut mac, _) = link(&hub, &blove.mac_token, None).await;
    let (id, ..) = mac.expect_command().await;
    assert_eq!(id, "stop-1");

    // Nothing is held any more, so answering holds is immediate rather than the full bound.
    let started = std::time::Instant::now();
    hub.state.relay.release_holds(Duration::from_secs(1)).await;
    assert!(
        started.elapsed() < Duration::from_millis(200),
        "{:?}",
        started.elapsed()
    );
    mac.reply("stop-1", json!({})).await;
    assert_eq!(phone.expect_reply().await.0, "stop-1");
}

/// Pushes one change as `token` through `hub`.
async fn push_one(hub: &Hub, token: &str, seq: i64) {
    let row = format!("conn-{seq}");
    let change = json!({"changes": [{
        "deviceSeq": seq, "wall": 1_761_900_000_000_i64 + seq, "table": "connections",
        "rowId": row, "op": "insert", "column": null,
        "value": {"id": row, "kind": "codex", "label": row},
    }]});
    let (status, _) = hub
        .http_with("POST", "/v1/changes", Some(token), Some(&change))
        .await;
    assert_eq!(status, StatusCode::OK);
}

/// Long-polls `/v1/changes` on `poller` after `after` while `pusher` pushes change `seq` 300 ms
/// in; asserts the poll returned that change well before its 20 s wait.
async fn pull_wakes_on_push(poller: &Hub, pusher: &Hub, blove: &User, after: i64, seq: i64) {
    let started = std::time::Instant::now();
    let path = format!("/v1/changes?after={after}&wait=20");
    let poll = poller.http("GET", &path, Some(&blove.phone_token));
    let push = async {
        real_sleep(Duration::from_millis(300)).await;
        push_one(pusher, &blove.mac_token, seq).await;
    };
    let ((status, page), ()) = tokio::join!(poll, push);
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["changes"].as_array().map(Vec::len), Some(1), "{page}");
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the poll slept through the other instance's push: {:?}",
        started.elapsed()
    );
}

#[sqlx::test(migrations = false)]
async fn a_push_on_one_instance_wakes_a_long_poll_on_the_other(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    // Let both listeners subscribe first: a listener wakes every pull when it starts.
    real_sleep(Duration::from_millis(300)).await;
    pull_wakes_on_push(&b, &a, &blove, 0, 1).await;
    // And the other way round.
    pull_wakes_on_push(&a, &b, &blove, 1, 2).await;
}

#[sqlx::test(migrations = false)]
async fn the_change_listener_survives_a_dropped_connection(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    real_sleep(Duration::from_millis(300)).await;

    // Both instances' listener connections are cut, as a database failover would.
    let cut: Vec<bool> = sqlx::query_scalar(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
         WHERE datname = current_database() AND query LIKE 'LISTEN%'",
    )
    .fetch_all(&a.admin.pool)
    .await
    .unwrap();
    assert_eq!(cut, [true, true]);
    // The listeners notice on their next read and listen again on new connections.
    real_sleep(Duration::from_millis(500)).await;
    pull_wakes_on_push(&b, &a, &blove, 0, 1).await;
}

#[sqlx::test(migrations = false)]
async fn logging_out_on_another_instance_closes_the_link(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    real_sleep(Duration::from_millis(300)).await;
    let (mut phone, _) = link(&a, &blove.phone_token, None).await;
    let (status, _) = b
        .http("DELETE", "/v1/sessions/self", Some(&blove.phone_token))
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(phone.expect_close().await, close_code::REVOKED);
}

#[sqlx::test(migrations = false)]
async fn revoking_on_another_instance_closes_the_link(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    real_sleep(Duration::from_millis(300)).await;
    let (mut mac, _) = link(&a, &blove.mac_token, None).await;
    let (status, _) = b
        .http("DELETE", "/v1/devices/self", Some(&blove.mac_token))
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(mac.expect_close().await, close_code::REVOKED);
}

#[sqlx::test(migrations = false)]
async fn the_heartbeat_does_not_wait_behind_a_busy_pool(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    // Every connection of the request pool is taken, for longer than the liveness window.
    let mut held = Vec::new();
    for _ in 0..a.state.db.pool.options().get_max_connections() {
        held.push(a.state.db.pool.acquire().await.unwrap());
    }
    real_sleep(a.state.instances.alive_within() * 2).await;
    assert!(
        !a.state.instances.stale(),
        "the heartbeat queued behind requests"
    );
    drop(held);
}

#[sqlx::test(migrations = false)]
async fn a_draining_instance_frees_each_user_as_their_links_close(pool: PgPool) {
    let mut a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    // Another user's phone, also on `a`, that stops reading: it never answers the close, so `a`'s
    // drain waits out the close grace for it.
    let alice = a.user("cacheplane", "alice").await;
    let (alice_token, _) = a.enroll(&alice, "ios", "Alice's iPhone").await;
    let (_alice_phone, _) = link(&a, &alice_token, None).await;
    let (mut phone, _) = link(&a, &blove.phone_token, None).await;

    a.signal();
    assert_eq!(phone.expect_close().await, close_code::SHUTDOWN);
    // `a` is still draining, but blove's links are gone, so `b` takes blove at once.
    eventually("blove's claim to be released", || async {
        instances::owner_of(&b.state.db, blove.who.user_id)
            .await
            .unwrap()
            .is_none()
            .then_some(())
    })
    .await;
    assert!(!a.server.is_finished(), "the drain should still be waiting");
    let (_phone, set_cookie) = link(&b, &blove.phone_token, None).await;
    assert_eq!(set_cookie.as_deref(), Some(cookie_for(&b).as_str()));
}

#[sqlx::test(migrations = false)]
async fn a_listener_that_goes_quiet_reconnects_and_wakes_its_polls(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    real_sleep(Duration::from_millis(300)).await;
    // `b`'s listener stops hearing anything while its connection stays up, as a half-open TCP
    // connection would: `a`'s wake-up for the push below never reaches it.
    b.state.instances.deafen_listener(true);

    let started = std::time::Instant::now();
    let poll = b.http(
        "GET",
        "/v1/changes?after=0&wait=20",
        Some(&blove.phone_token),
    );
    let push = async {
        real_sleep(Duration::from_millis(100)).await;
        push_one(&a, &blove.mac_token, 1).await;
    };
    let ((status, page), ()) = tokio::join!(poll, push);
    assert_eq!(status, StatusCode::OK);
    assert_eq!(page["changes"].as_array().map(Vec::len), Some(1), "{page}");
    // Within about a liveness window of silence (800 ms here), not the poll's 20 s.
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the quiet listener went unnoticed: {:?}",
        started.elapsed()
    );
}

#[sqlx::test(migrations = false)]
async fn a_user_whose_last_link_here_ends_is_free_to_move_at_once(pool: PgPool) {
    let a = spawn_instance(&pool, BEAT).await;
    let b = spawn_instance(&pool, BEAT).await;
    let blove = user(&a).await;
    let (mac, _) = link(&a, &blove.mac_token, None).await;
    let (phone, _) = link(&a, &blove.phone_token, None).await;

    // The Mac's link ends while `a` is alive and not draining (as when the load balancer cuts the
    // links of a deregistered target, long before ECS stops it). The phone is still here, so `a`
    // keeps the user.
    mac.close().await;
    eventually("the Mac to go offline", || async {
        (!a.state.relay.online(blove.mac_id)).then_some(())
    })
    .await;
    assert_eq!(
        instances::owner_of(&a.state.db, blove.who.user_id)
            .await
            .unwrap(),
        Some(a.state.instances.id())
    );

    // With the phone gone too, nothing of the user is served here: the claim goes at once, and the
    // devices are served wherever they reconnect, with no `409 relocated` to wait out.
    phone.close().await;
    eventually("the claim to be released", || async {
        instances::owner_of(&a.state.db, blove.who.user_id)
            .await
            .unwrap()
            .is_none()
            .then_some(())
    })
    .await;
    assert!(a.state.instances.id() != b.state.instances.id() && !a.server.is_finished());
    let (_mac, set_cookie) = link(&b, &blove.mac_token, None).await;
    assert_eq!(set_cookie.as_deref(), Some(cookie_for(&b).as_str()));
    let refused = FakeDevice::try_connect(a.addr, Some(&blove.phone_token), None)
        .await
        .err()
        .expect("`a` no longer serves the user");
    assert_eq!(refused.code(), "relocated");
}
