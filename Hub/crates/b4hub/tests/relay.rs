//! The device link (`GET /v1/devices/self/link`) against a real PostgreSQL and a real loopback
//! listener, with fake Macs and phones as WebSocket clients. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.
//!
//! Tests that depend on time pause the tokio clock (see `relay_support`): the hub's link tasks
//! read time through `tokio::time`, so advancing the clock is advancing the hub.

mod relay_support;

use std::time::{Duration, SystemTime};

use b4hub::relay::{close_code, rfc3339_millis};
use b4hub_core::relay::{RelayMessage, Role};
use serde_json::json;
use sqlx::PgPool;

use relay_support::{
    epoch_seconds, eventually, pause_clock, settle, spawn_hub, FakeDevice, FRAME_WAIT,
};

/// The `hello` a link starts with, as `(role, heartbeatSeconds, deviceId)`.
fn hello_of(frame: RelayMessage) -> (Role, u32, sqlx::types::Uuid) {
    match frame {
        RelayMessage::Hello {
            protocol,
            role,
            heartbeat_seconds,
            device_id,
            ..
        } => {
            assert_eq!(protocol, 1);
            (role, heartbeat_seconds, device_id)
        }
        other => panic!("expected hello, got {other:?}"),
    }
}

fn hosts_of(frame: RelayMessage) -> Vec<b4hub_core::relay::HostPresence> {
    match frame {
        RelayMessage::Presence { hosts } => hosts,
        other => panic!("expected presence, got {other:?}"),
    }
}

#[sqlx::test(migrations = false)]
async fn a_bad_token_is_refused_before_the_upgrade(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, _) = hub.enroll(&blove, "macos", "Mac").await;

    for bad in [None, Some("not-a-token"), Some(&*format!("{token}x"))] {
        let refused = FakeDevice::try_connect(hub.addr, bad, None)
            .await
            .err()
            .expect("no socket for a bad token");
        assert_eq!(refused.status, 401, "{refused:?}");
        assert_eq!(refused.code(), "unauthorized");
    }
}

#[sqlx::test(migrations = false)]
async fn a_request_that_is_not_an_upgrade_is_a_json_400(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, _) = hub.enroll(&blove, "macos", "Mac").await;
    let (status, body) = hub.http("GET", "/v1/devices/self/link", Some(&token)).await;
    assert_eq!(status, 400, "{body}");
    assert_eq!(body["error"]["details"]["code"], "invalid_request");
}

#[sqlx::test(migrations = false)]
async fn hello_names_the_role(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Brian's Mac").await;
    let (phone_token, phone_id) = hub.enroll(&blove, "ios", "iPhone").await;
    let (cli_token, cli_id) = hub.enroll(&blove, "cli", "agent-workspace").await;

    let mut mac = FakeDevice::connect(hub.addr, &mac_token).await;
    assert_eq!(hello_of(mac.next().await), (Role::Host, 10, mac_id));
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    assert_eq!(hello_of(phone.next().await), (Role::Client, 10, phone_id));
    let mut cli = FakeDevice::connect(hub.addr, &cli_token).await;
    assert_eq!(hello_of(cli.next().await), (Role::Client, 10, cli_id));

    assert!(hub.state.relay.online(mac_id));
    assert!(hub.state.relay.online(phone_id));
}

#[sqlx::test(migrations = false)]
async fn ping_gets_pong_with_hub_time(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, _) = hub.enroll(&blove, "macos", "Mac").await;
    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    mac.next().await; // hello

    let before = rfc3339_millis(SystemTime::now());
    mac.send(&RelayMessage::Ping).await;
    let RelayMessage::Pong { hub_time } = mac.next().await else {
        panic!("expected pong");
    };
    let after = rfc3339_millis(SystemTime::now());
    // Fixed-width UTC strings sort like the times they name.
    assert!(
        before <= hub_time && hub_time <= after,
        "{before} <= {hub_time} <= {after}"
    );
}

#[sqlx::test(migrations = false)]
async fn client_too_old_is_refused(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, phone_id) = hub.enroll(&blove, "ios", "iPhone").await;
    hub.state.relay.set_min_client_protocol(2);

    // A missing header counts as protocol 1.
    let mut phone = FakeDevice::connect(hub.addr, &token).await;
    let RelayMessage::Error {
        code,
        details: Some(details),
        ..
    } = phone.next().await
    else {
        panic!("expected an error frame");
    };
    assert_eq!(code, "client_too_old");
    assert_eq!(details["minClientProtocol"], 2);
    assert_eq!(phone.expect_close().await, close_code::CLIENT_TOO_OLD);
    assert!(!hub.state.relay.online(phone_id));

    // A newer client is served, and `hello` names the floor.
    let mut current = FakeDevice::try_connect(hub.addr, Some(&token), Some("2"))
        .await
        .unwrap();
    match current.next().await {
        RelayMessage::Hello {
            min_client_protocol,
            ..
        } => assert_eq!(min_client_protocol, 2),
        other => panic!("expected hello, got {other:?}"),
    }
}

#[sqlx::test(migrations = false)]
async fn a_second_link_replaces_the_first(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await; // hello
    phone.next().await; // presence

    let mut first = FakeDevice::connect(hub.addr, &mac_token).await;
    first.next().await; // hello
    assert!(hosts_of(phone.next().await)[0].online);

    let mut second = FakeDevice::connect(hub.addr, &mac_token).await;
    hello_of(second.next().await);

    match first.next().await {
        RelayMessage::Error { code, .. } => assert_eq!(code, "link_replaced"),
        other => panic!("expected link_replaced, got {other:?}"),
    }
    assert_eq!(first.expect_close().await, close_code::REPLACED);

    // The Mac never went offline: the phone hears nothing, and the new link works.
    assert!(hub.state.relay.online(mac_id));
    phone.expect_no_frame(Duration::from_millis(300)).await;
    second.send(&RelayMessage::Ping).await;
    assert!(matches!(second.next().await, RelayMessage::Pong { .. }));
}

#[sqlx::test(migrations = false)]
async fn a_silent_link_is_closed_after_thirty_seconds(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    mac.next().await; // hello
    clock.advance(Duration::from_secs(29)).await;
    mac.expect_no_frame(Duration::from_millis(200)).await;
    assert!(hub.state.relay.online(mac_id));

    // Timers fire on millisecond ticks, so cross the 30 second mark rather than land on it.
    clock.advance(Duration::from_millis(1_005)).await;
    assert_eq!(mac.expect_close().await, close_code::SILENT);
    eventually("the link to be forgotten", || async {
        (!hub.state.relay.online(mac_id)).then_some(())
    })
    .await;
}

#[sqlx::test(migrations = false)]
async fn a_ping_keeps_a_link_alive(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    mac.next().await; // hello
    for _ in 0..4 {
        clock.advance(Duration::from_secs(10)).await;
        mac.send(&RelayMessage::Ping).await;
        assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
    }
    assert!(hub.state.relay.online(mac_id)); // 40 s in, with a ping every 10
}

#[sqlx::test(migrations = false)]
async fn last_seen_is_refreshed_once_a_minute_while_a_link_is_open(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    let RelayMessage::Hello { hub_time, .. } = mac.next().await else {
        panic!("expected hello");
    };
    let opened = epoch_seconds(&hub_time);
    for second in (10..=60).step_by(10) {
        clock.advance(Duration::from_secs(10)).await;
        mac.send(&RelayMessage::Ping).await;
        assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
        if second == 50 {
            // Frames keep arriving, but the minute is not up: nothing was written since open.
            let seen = hub.last_seen(&blove, mac_id).await.unwrap();
            assert!(seen < opened + 1.0, "{seen} vs opened {opened}");
        }
    }
    // The frame at t = 60 is the first past the minute, and the write happens off the link's task.
    let seen = eventually("the once-a-minute write", || async {
        let seen = hub.last_seen(&blove, mac_id).await?;
        (seen > opened + 30.0).then_some(seen)
    })
    .await;
    assert!(
        (seen - (opened + 60.0)).abs() < 0.1,
        "{seen} vs {opened} + 60"
    );
}

#[sqlx::test(migrations = false)]
async fn presence_reaches_clients_on_connect_and_drop(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Brian's Mac").await;
    let (phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;

    // The phone connects first: hello, then every Mac of the user, offline.
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    hello_of(phone.next().await);
    let hosts = hosts_of(phone.next().await);
    assert_eq!(hosts.len(), 1);
    assert_eq!(
        (hosts[0].device_id, hosts[0].name.as_str()),
        (mac_id, "Brian's Mac")
    );
    assert!(!hosts[0].online);

    // The Mac connects: online.
    let mut mac = FakeDevice::connect(hub.addr, &mac_token).await;
    hello_of(mac.next().await);
    let hosts = hosts_of(phone.next().await);
    assert_eq!(hosts.len(), 1);
    assert!(hosts[0].online);

    // The Mac drops without a goodbye: offline, with the time it was last heard from.
    drop(mac);
    let hosts = hosts_of(phone.next().await);
    assert!(!hosts[0].online);
    let last_seen = hosts[0].last_seen_at.as_deref().expect("a last-seen time");
    let stored = hub.last_seen(&blove, mac_id).await.unwrap();
    assert!(
        (epoch_seconds(last_seen) - stored).abs() < 0.01,
        "{last_seen} vs {stored}"
    );
}

#[sqlx::test(migrations = false)]
async fn a_device_that_says_goodbye_goes_offline_too(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await; // hello
    phone.next().await; // presence
    let mut mac = FakeDevice::connect(hub.addr, &mac_token).await;
    mac.next().await; // hello
    assert!(hosts_of(phone.next().await)[0].online);

    mac.close().await;
    assert!(!hosts_of(phone.next().await)[0].online);
    assert!(!hub.state.relay.online(mac_id));
}

#[sqlx::test(migrations = false)]
async fn last_seen_is_the_last_frame_heard_after_a_dead_link_close(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    let RelayMessage::Hello { hub_time, .. } = mac.next().await else {
        panic!("expected hello");
    };
    let opened = epoch_seconds(&hub_time);

    clock.advance(Duration::from_secs(5)).await;
    mac.send(&RelayMessage::Ping).await; // the last frame, at t = 5
    assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
    clock.advance(Duration::from_millis(30_005)).await; // silent until t = 35
    assert_eq!(mac.expect_close().await, close_code::SILENT);

    // The close is noticed at t = 35, but `last_seen_at` is the time of the frame at t = 5.
    let seen = eventually("last_seen_at to be written on close", || async {
        let seen = hub.last_seen(&blove, mac_id).await?;
        (seen > opened + 1.0).then_some(seen)
    })
    .await;
    assert!(
        (seen - (opened + 5.0)).abs() < 0.1,
        "last_seen_at {seen} should be about {} (t = 5), not t = 35",
        opened + 5.0
    );
}

#[sqlx::test(migrations = false)]
async fn revoking_closes_the_link(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await; // hello
    phone.next().await; // presence
    let mut mac = FakeDevice::connect(hub.addr, &mac_token).await;
    mac.next().await; // hello
    assert!(hosts_of(phone.next().await)[0].online);

    let (status, _) = hub
        .http("DELETE", "/v1/devices/self", Some(&mac_token))
        .await;
    assert_eq!(status, 204);
    assert_eq!(mac.expect_close().await, close_code::REVOKED);

    // The Mac has left the hub: the phone's list no longer has it. And it cannot link again.
    assert!(hosts_of(phone.next().await).is_empty());
    assert!(!hub.state.relay.online(mac_id));
    let refused = FakeDevice::try_connect(hub.addr, Some(&mac_token), None)
        .await
        .err()
        .expect("a revoked device gets no socket");
    assert_eq!(refused.status, 401);
}

#[sqlx::test(migrations = false)]
async fn shutdown_closes_links_with_1001(pool: PgPool) {
    let mut hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let (phone_token, phone_id) = hub.enroll(&blove, "ios", "iPhone").await;
    let mut mac = FakeDevice::connect(hub.addr, &mac_token).await;
    mac.next().await;
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await;

    hub.state.shutdown.trigger();
    assert_eq!(mac.expect_close().await, close_code::SHUTDOWN);
    assert_eq!(phone.expect_close().await, close_code::SHUTDOWN);
    // The drain waits for the links, and then the server is done, well inside its five seconds.
    tokio::time::timeout(FRAME_WAIT * 2, &mut hub.server)
        .await
        .expect("the server finishes its drain")
        .unwrap()
        .unwrap();
    assert!(!hub.state.relay.online(mac_id) && !hub.state.relay.online(phone_id));
    // Each link recorded when it was last heard from.
    assert!(hub.last_seen(&blove, mac_id).await.is_some());
}

#[sqlx::test(migrations = false)]
async fn eleven_upgrades_in_a_minute_are_limited(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, _) = hub.enroll(&blove, "macos", "Mac").await;
    let (other_token, _) = hub.enroll(&blove, "ios", "iPhone").await;

    for attempt in 1..=10 {
        let mut link = FakeDevice::connect(hub.addr, &token).await;
        link.next().await;
        assert!(attempt <= 10);
    }
    let refused = FakeDevice::try_connect(hub.addr, Some(&token), None)
        .await
        .err()
        .expect("the eleventh upgrade is limited");
    assert_eq!(refused.status, 429, "{refused:?}");
    assert_eq!(refused.code(), "rate_limited");
    let retry = refused.body["error"]["details"]["retryAfterMs"]
        .as_u64()
        .unwrap();
    assert!((1..=60_000).contains(&retry), "{retry}");

    // The limit is per device.
    FakeDevice::connect(hub.addr, &other_token).await;
}

#[sqlx::test(migrations = false)]
async fn presence_never_lists_another_users_mac(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let colleague = hub.user("cacheplane", "colleague").await;
    let stranger = hub.user("elsewhere", "stranger").await;
    let (blove_mac_token, blove_mac) = hub.enroll(&blove, "macos", "Brian's Mac").await;
    let (blove_phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;
    let (colleague_mac_token, _) = hub.enroll(&colleague, "macos", "Colleague's Mac").await;
    let (stranger_mac_token, _) = hub.enroll(&stranger, "macos", "Stranger's Mac").await;

    let mut phone = FakeDevice::connect(hub.addr, &blove_phone_token).await;
    phone.next().await;
    let hosts = hosts_of(phone.next().await);
    assert_eq!(
        hosts.iter().map(|h| h.device_id).collect::<Vec<_>>(),
        [blove_mac]
    );

    // Other users' Macs come and go; this phone hears nothing about them.
    let mut colleague_mac = FakeDevice::connect(hub.addr, &colleague_mac_token).await;
    colleague_mac.next().await;
    let mut stranger_mac = FakeDevice::connect(hub.addr, &stranger_mac_token).await;
    stranger_mac.next().await;
    drop(colleague_mac);
    drop(stranger_mac);
    phone.expect_no_frame(Duration::from_millis(400)).await;

    // And its own Mac still reaches it.
    let mut mac = FakeDevice::connect(hub.addr, &blove_mac_token).await;
    mac.next().await;
    let hosts = hosts_of(phone.next().await);
    assert_eq!(hosts.len(), 1);
    assert!(hosts[0].online);
}

#[sqlx::test(migrations = false)]
async fn a_frame_the_hub_cannot_use_gets_an_error_and_the_link_stays(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, _) = hub.enroll(&blove, "macos", "Mac").await;
    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    mac.next().await;

    for text in ["not json", &json!({"type": "teleport"}).to_string()] {
        mac.send_text(text).await;
        match mac.next().await {
            RelayMessage::Error { code, .. } => assert_eq!(code, "invalid_request"),
            other => panic!("expected an error frame, got {other:?}"),
        }
    }
    // A hub-to-device frame is not one a device sends.
    mac.send(&RelayMessage::Pong {
        hub_time: "x".into(),
    })
    .await;
    assert!(matches!(mac.next().await, RelayMessage::Error { .. }));

    mac.send(&RelayMessage::Ping).await;
    assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
    settle().await;
}
