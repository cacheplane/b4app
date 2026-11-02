//! The device link (`GET /v1/devices/self/link`) against a real PostgreSQL and a real loopback
//! listener, with fake Macs and phones as WebSocket clients. Run with
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.
//!
//! Tests that depend on time pause the tokio clock (see `relay_support`): the hub's link tasks
//! read time through `tokio::time`, so advancing the clock is advancing the hub.

mod relay_support;

use std::time::{Duration, SystemTime};

use b4hub::relay::{close_code, rfc3339_millis};
use b4hub_core::relay::{RelayMessage, RelayMethod, Role};
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;

use relay_support::{
    epoch_seconds, eventually, fill_queue, pause_clock, real_sleep, settle, spawn_hub,
    spawn_hub_paused, FakeDevice, Hub, Seeded, FRAME_WAIT,
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
    mac.next().await; // watching (a host is told its set after hello)

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
    first.next().await; // watching (a host is told its set after hello)
    assert!(hosts_of(phone.next().await)[0].online);

    let mut second = FakeDevice::connect(hub.addr, &mac_token).await;
    hello_of(second.next().await);
    second.next().await; // watching (a host is told its set after hello)

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
    let hub = spawn_hub_paused(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    mac.next().await; // hello
    mac.next().await; // watching (a host is told its set after hello)
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
    let hub = spawn_hub_paused(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    mac.next().await; // hello
    mac.next().await; // watching (a host is told its set after hello)
    for _ in 0..4 {
        clock.advance(Duration::from_secs(10)).await;
        mac.send(&RelayMessage::Ping).await;
        assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
    }
    assert!(hub.state.relay.online(mac_id)); // 40 s in, with a ping every 10
}

#[sqlx::test(migrations = false)]
async fn last_seen_is_refreshed_once_a_minute_while_a_link_is_open(pool: PgPool) {
    let hub = spawn_hub_paused(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    let RelayMessage::Hello { hub_time, .. } = mac.next().await else {
        panic!("expected hello");
    };
    mac.next().await; // watching (a host is told its set after hello)
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
    mac.next().await; // watching (a host is told its set after hello)
    assert!(hosts_of(phone.next().await)[0].online);

    mac.close().await;
    assert!(!hosts_of(phone.next().await)[0].online);
    assert!(!hub.state.relay.online(mac_id));
}

#[sqlx::test(migrations = false)]
async fn last_seen_is_the_last_frame_heard_after_a_dead_link_close(pool: PgPool) {
    let hub = spawn_hub_paused(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    let RelayMessage::Hello { hub_time, .. } = mac.next().await else {
        panic!("expected hello");
    };
    mac.next().await; // watching (a host is told its set after hello)
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
    mac.next().await; // watching (a host is told its set after hello)
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
    mac.next().await; // hello
    mac.next().await; // watching
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await;
    // The Mac is heard from once more, a while after it opened its link (not enough to trigger the
    // once-a-minute write): the shutdown has to record that frame, not the open.
    let opened = hub.last_seen(&blove, mac_id).await.unwrap();
    real_sleep(Duration::from_millis(500)).await;
    mac.send(&RelayMessage::Ping).await;
    assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));

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
    // Each link recorded when it was last heard from, on the way out.
    let seen = hub.last_seen(&blove, mac_id).await.unwrap();
    assert!(
        seen > opened + 0.4,
        "{seen} should be after the ping, not the open at {opened}"
    );
}

#[sqlx::test(migrations = false)]
async fn eleven_upgrades_in_a_minute_are_limited(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, _) = hub.enroll(&blove, "macos", "Mac").await;
    let (other_token, _) = hub.enroll(&blove, "ios", "iPhone").await;

    for _ in 1..=10 {
        let mut link = FakeDevice::connect(hub.addr, &token).await;
        hello_of(link.next().await);
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
    mac.next().await; // hello
    mac.next().await; // watching

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

#[sqlx::test(migrations = false)]
async fn a_device_never_reads_offline_before_its_last_seen_is_written(pool: PgPool) {
    let hub = spawn_hub_paused(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let clock = pause_clock();

    let mut mac = FakeDevice::connect(hub.addr, &token).await;
    let RelayMessage::Hello { hub_time, .. } = mac.next().await else {
        panic!("expected hello");
    };
    mac.next().await; // watching (a host is told its set after hello)
    let opened = epoch_seconds(&hub_time);
    clock.advance(Duration::from_secs(5)).await;
    mac.send(&RelayMessage::Ping).await;
    assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
    clock.advance(Duration::from_millis(30_005)).await;

    // Watch for the first moment the hub says "offline" and read the database at once: a command
    // judging how recently the Mac was seen must already find the last frame's time.
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while hub.state.relay.online(mac_id) {
        assert!(
            std::time::Instant::now() < deadline,
            "the link never closed"
        );
        tokio::task::yield_now().await;
    }
    let seen = hub.last_seen(&blove, mac_id).await.unwrap();
    assert!(
        (seen - (opened + 5.0)).abs() < 0.1,
        "last_seen_at {seen} should already be the last frame ({} )",
        opened + 5.0
    );
}

#[sqlx::test(migrations = false)]
async fn a_revocation_during_the_upgrade_still_closes_the_link(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await; // hello
    phone.next().await; // presence

    // The upgrade is accepted (the device was valid) but the link has not registered yet.
    let gate = hub.state.relay.gate_registration();
    let mut mac = FakeDevice::connect(hub.addr, &mac_token).await;
    gate.reached.notified().await;
    let (status, _) = hub
        .http("DELETE", "/v1/devices/self", Some(&mac_token))
        .await;
    assert_eq!(status, 204); // finds no link to close
    gate.release.notify_one();

    assert_eq!(mac.expect_close().await, close_code::REVOKED);
    assert!(!hub.state.relay.online(mac_id));
    // The Mac never read as online to anyone: the phone hears the list without it, nothing else.
    assert!(hosts_of(phone.next().await).is_empty());
}

#[sqlx::test(migrations = false)]
async fn revoking_an_offline_mac_updates_the_phones_list(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let blove = hub.user("cacheplane", "blove").await;
    let (mac_token, _) = hub.enroll(&blove, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&blove, "ios", "iPhone").await;
    let mut phone = FakeDevice::connect(hub.addr, &phone_token).await;
    phone.next().await; // hello
    assert_eq!(hosts_of(phone.next().await).len(), 1);

    let (status, _) = hub
        .http("DELETE", "/v1/devices/self", Some(&mac_token))
        .await;
    assert_eq!(status, 204);
    assert!(hosts_of(phone.next().await).is_empty());
}

// ---- commands ----------------------------------------------------------------------------------

const QUIET: Duration = Duration::from_millis(300);

const METHODS: [RelayMethod; 5] = [
    RelayMethod::TurnSend,
    RelayMethod::TurnInterrupt,
    RelayMethod::RequestRespond,
    RelayMethod::ThreadStart,
    RelayMethod::TurnLookup,
];

/// Params a phone would send for `method`, naming the seeded rows.
fn params_for(method: RelayMethod) -> Value {
    match method {
        RelayMethod::TurnSend => json!({"threadId": "thread-1", "text": "hello"}),
        RelayMethod::TurnInterrupt => json!({"threadId": "thread-1"}),
        RelayMethod::RequestRespond => json!({"requestId": "request-1", "decision": "accept"}),
        RelayMethod::ThreadStart => json!({
            "threadId": "new-thread",
            "projectId": "project-1",
            "connectionId": "conn-1",
            "folder": "/Users/blove/repos/b4app",
            "text": "start here",
        }),
        RelayMethod::TurnLookup => json!({"operationId": "op-1", "threadId": "thread-1"}),
    }
}

/// A user with a Mac and a phone, and a thread, a pending request on it, and a project, all owned
/// by the Mac.
struct World {
    hub: Hub,
    blove: Seeded,
    mac_token: String,
    mac_id: Uuid,
    phone_token: String,
    phone_id: Uuid,
}

impl World {
    async fn new(hub: Hub) -> World {
        let blove = hub.user("cacheplane", "blove").await;
        let (mac_token, mac_id) = hub.enroll(&blove, "macos", "Brian's Mac").await;
        let (phone_token, phone_id) = hub.enroll(&blove, "ios", "iPhone").await;
        hub.seed_thread(&blove, mac_id, "thread-1").await;
        hub.seed_request(&blove, mac_id, "request-1", "thread-1", "pending")
            .await;
        hub.seed_project(&blove, mac_id, "project-1").await;
        World {
            hub,
            blove,
            mac_token,
            mac_id,
            phone_token,
            phone_id,
        }
    }

    async fn mac(&self) -> FakeDevice {
        FakeDevice::ready(self.hub.addr, &self.mac_token).await.0
    }

    async fn phone(&self) -> FakeDevice {
        FakeDevice::ready(self.hub.addr, &self.phone_token).await.0
    }

    /// The Mac links and leaves again, so it is offline having just been seen.
    async fn mac_flaps(&self) {
        let mac = self.mac().await;
        mac.close().await;
        let mac_id = self.mac_id;
        eventually("the Mac to go offline", || async {
            (!self.hub.state.relay.online(mac_id)).then_some(())
        })
        .await;
    }
}

fn seconds_between(earlier: &str, later: &str) -> f64 {
    epoch_seconds(later) - epoch_seconds(earlier)
}

#[sqlx::test(migrations = false)]
async fn each_method_reaches_the_owning_mac_with_a_deadline(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let _clock = pause_clock();
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    for (n, method) in METHODS.into_iter().enumerate() {
        let id = format!("command-{n}");
        phone.command(&id, method, params_for(method)).await;

        let (got, got_method, params, deadline, from) = mac.expect_command().await;
        assert_eq!((got.as_str(), got_method), (id.as_str(), method));
        assert_eq!(params, params_for(method));
        let from = from.expect("the hub stamps who sent it");
        assert_eq!(
            (from.device_id, from.name.as_str()),
            (world.phone_id, "iPhone")
        );
        // The clock is paused, so the hub's time now is the time it stamped the command at.
        let hub_time = mac.ping().await;
        let deadline = deadline.expect("the hub stamps a deadline");
        let ahead = seconds_between(&hub_time, &deadline);
        assert!(
            (ahead - 10.0).abs() < 1e-6,
            "deadline {deadline} vs hub time {hub_time}"
        );

        mac.reply(&id, json!({"n": n})).await;
        assert_eq!(
            phone.expect_reply().await,
            (id, Some(json!({"n": n})), None)
        );
    }
}

#[sqlx::test(migrations = false)]
async fn another_users_thread_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let hub = &world.hub;
    let colleague = hub.user("cacheplane", "colleague").await;
    let (colleague_mac_token, colleague_mac) = hub.enroll(&colleague, "macos", "Their Mac").await;
    hub.seed_thread(&colleague, colleague_mac, "their-thread")
        .await;
    hub.seed_request(
        &colleague,
        colleague_mac,
        "their-request",
        "their-thread",
        "pending",
    )
    .await;
    hub.seed_project(&colleague, colleague_mac, "their-project")
        .await;
    let mut their_mac = FakeDevice::ready(hub.addr, &colleague_mac_token).await.0;
    let mut phone = world.phone().await;

    for (method, params) in [
        (
            RelayMethod::TurnSend,
            json!({"threadId": "their-thread", "text": "hi"}),
        ),
        (
            RelayMethod::TurnLookup,
            json!({"threadId": "their-thread", "operationId": "o"}),
        ),
        (
            RelayMethod::RequestRespond,
            json!({"requestId": "their-request"}),
        ),
        (
            RelayMethod::ThreadStart,
            json!({"threadId": "t", "projectId": "their-project"}),
        ),
    ] {
        phone.command(method.as_str(), method, params).await;
        let (id, error) = phone.expect_refusal().await;
        assert_eq!(
            (id.as_str(), error.code.as_str()),
            (method.as_str(), "not_found")
        );
    }
    their_mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn another_orgs_thread_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let hub = &world.hub;
    let stranger = hub.user("elsewhere", "stranger").await;
    let (stranger_mac_token, stranger_mac) = hub.enroll(&stranger, "macos", "Their Mac").await;
    // Ids are only unique within an org: the stranger's org has rows with blove's very ids, and
    // one thread blove's org does not have at all.
    hub.seed_thread(&stranger, stranger_mac, "thread-1").await;
    hub.seed_request(&stranger, stranger_mac, "request-1", "thread-1", "pending")
        .await;
    hub.seed_project(&stranger, stranger_mac, "project-1").await;
    hub.seed_thread(&stranger, stranger_mac, "their-thread")
        .await;
    let mut their_mac = FakeDevice::ready(hub.addr, &stranger_mac_token).await.0;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    // The colliding ids resolve within blove's org, to blove's Mac, never the stranger's.
    for method in [
        RelayMethod::TurnInterrupt,
        RelayMethod::RequestRespond,
        RelayMethod::ThreadStart,
    ] {
        phone
            .command(method.as_str(), method, params_for(method))
            .await;
        let (id, got, ..) = mac.expect_command().await;
        assert_eq!((id.as_str(), got), (method.as_str(), method));
        mac.reply(&id, json!({})).await;
        assert_eq!(phone.expect_reply().await.0, method.as_str());
    }
    // A thread only the other org has is not found.
    phone
        .command(
            "theirs",
            RelayMethod::TurnInterrupt,
            json!({"threadId": "their-thread"}),
        )
        .await;
    let (_, error) = phone.expect_refusal().await;
    assert_eq!(error.code, "not_found");
    their_mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn an_owner_that_is_not_the_users_mac_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let hub = &world.hub;
    let colleague = hub.user("cacheplane", "colleague").await;
    let (colleague_mac_token, colleague_mac) = hub.enroll(&colleague, "macos", "Their Mac").await;
    // Rows of blove's whose owner is someone else's Mac, or blove's own phone.
    hub.seed_thread(&world.blove, colleague_mac, "odd-thread")
        .await;
    hub.seed_thread(&world.blove, world.phone_id, "phone-thread")
        .await;
    let mut their_mac = FakeDevice::ready(hub.addr, &colleague_mac_token).await.0;
    let mut phone = world.phone().await;

    for thread in ["odd-thread", "phone-thread"] {
        phone
            .command(
                thread,
                RelayMethod::TurnInterrupt,
                json!({"threadId": thread}),
            )
            .await;
        let (_, error) = phone.expect_refusal().await;
        assert_eq!(error.code, "not_found", "{thread}");
    }
    their_mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn an_unknown_method_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    let unknown = json!({
        "type": "command",
        "id": "c-unknown",
        "method": "turn.delete",
        "params": {"threadId": "thread-1"},
    });
    phone.send_text(&unknown.to_string()).await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("c-unknown", "not_found")
    );
    mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_mac_sending_a_command_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let (other_mac_token, _) = world.hub.enroll(&world.blove, "macos", "Other Mac").await;
    let mut other_mac = FakeDevice::ready(world.hub.addr, &other_mac_token).await.0;

    other_mac
        .command(
            "from-a-mac",
            RelayMethod::TurnSend,
            params_for(RelayMethod::TurnSend),
        )
        .await;
    let (id, error) = other_mac.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("from-a-mac", "not_found")
    );
    mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_revoked_owner_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let (status, _) = world
        .hub
        .http("DELETE", "/v1/devices/self", Some(&world.mac_token))
        .await;
    assert_eq!(status, 204);
    let mut phone = world.phone().await;

    for method in METHODS {
        phone
            .command(method.as_str(), method, params_for(method))
            .await;
        let (_, error) = phone.expect_refusal().await;
        // Not `device_offline`: a revoked Mac is not the user's any more.
        assert_eq!(error.code, "not_found", "{}", method.as_str());
    }
}

#[sqlx::test(migrations = false)]
async fn send_to_an_offline_mac_is_refused_with_last_seen(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    world.mac_flaps().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "send-1",
            RelayMethod::TurnSend,
            params_for(RelayMethod::TurnSend),
        )
        .await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("send-1", "device_offline")
    );
    let details = error.details.expect("device_offline carries details");
    assert_eq!(details["deviceId"], world.mac_id.to_string());
    assert_eq!(details["deviceName"], "Brian's Mac");
    let last_seen = details["lastSeenAt"].as_str().expect("lastSeenAt");
    let stored = world
        .hub
        .last_seen(&world.blove, world.mac_id)
        .await
        .unwrap();
    assert!(
        (epoch_seconds(last_seen) - stored).abs() < 0.01,
        "{last_seen} vs {stored}"
    );
}

#[sqlx::test(migrations = false)]
async fn send_is_never_held(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    world.mac_flaps().await;
    let mut phone = world.phone().await;

    // The Mac was seen a moment ago, well inside the hold window, and still the answer is at once.
    // `turn.lookup` is not held either: it only reads, and the phone asks again later.
    for method in [
        RelayMethod::TurnSend,
        RelayMethod::ThreadStart,
        RelayMethod::TurnLookup,
    ] {
        phone
            .command(method.as_str(), method, params_for(method))
            .await;
        let (id, error) = phone.expect_refusal().await;
        assert_eq!(
            (id.as_str(), error.code.as_str()),
            (method.as_str(), "device_offline")
        );
    }
    assert_eq!(world.hub.state.relay.held(world.mac_id), 0);
}

#[sqlx::test(migrations = false)]
async fn interrupt_is_held_and_delivered_on_reconnect(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let clock = pause_clock();
    world.mac_flaps().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "stop-1",
            RelayMethod::TurnInterrupt,
            params_for(RelayMethod::TurnInterrupt),
        )
        .await;
    clock
        .advance_alive(Duration::from_secs(20), &mut [&mut phone])
        .await;
    phone.expect_quiet(QUIET).await;
    assert_eq!(world.hub.state.relay.held(world.mac_id), 1);

    // The Mac is back at t + 20 s: the command arrives after `hello`, with a deadline 10 s from
    // now, not from when the phone sent it.
    let (mut mac, hello_time) = FakeDevice::ready(world.hub.addr, &world.mac_token).await;
    let (id, method, _, deadline, _) = mac.expect_command().await;
    assert_eq!(
        (id.as_str(), method),
        ("stop-1", RelayMethod::TurnInterrupt)
    );
    let ahead = seconds_between(&hello_time, &deadline.unwrap());
    assert!((ahead - 10.0).abs() < 1e-6, "{ahead}");

    mac.reply("stop-1", json!({"turn": {"id": "turn-1"}})).await;
    let (id, result, error) = phone.expect_reply().await;
    assert_eq!((id.as_str(), error), ("stop-1", None));
    assert_eq!(result, Some(json!({"turn": {"id": "turn-1"}})));
    assert_eq!(world.hub.state.relay.held(world.mac_id), 0);
}

#[sqlx::test(migrations = false)]
async fn held_answer_expires_after_sixty_seconds(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let clock = pause_clock();
    world.mac_flaps().await;
    let mut phone = world.phone().await;

    // The window is measured from `last_seen_at`, which the upgrade's request may have stamped
    // with the database's (real, unpaused) clock a little after the hub's paused one.
    let last_seen = world
        .hub
        .last_seen(&world.blove, world.mac_id)
        .await
        .unwrap();
    let hub_now = epoch_seconds(&phone.ping().await);
    let left = Duration::from_secs_f64(last_seen + 60.0 - hub_now);
    assert!(
        left > Duration::from_secs(55) && left < Duration::from_secs(70),
        "{left:?}"
    );

    phone
        .command(
            "answer-1",
            RelayMethod::RequestRespond,
            params_for(RelayMethod::RequestRespond),
        )
        .await;
    clock
        .advance_alive(left - Duration::from_secs(1), &mut [&mut phone])
        .await;
    phone.expect_quiet(QUIET).await;

    // Sixty seconds after the Mac was last heard from, the hold gives up.
    clock.advance(Duration::from_millis(1_005)).await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("answer-1", "device_offline")
    );
    assert_eq!(error.details.unwrap()["deviceName"], "Brian's Mac");
    assert_eq!(world.hub.state.relay.held(world.mac_id), 0);

    // And the Mac, back later, never sees it.
    let mut mac = world.mac().await;
    mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn no_reply_in_thirty_seconds_is_relay_timeout(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let clock = pause_clock();
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "send-1",
            RelayMethod::TurnSend,
            params_for(RelayMethod::TurnSend),
        )
        .await;
    mac.expect_command().await;
    clock
        .advance_alive(Duration::from_secs(29), &mut [&mut mac, &mut phone])
        .await;
    phone.expect_quiet(QUIET).await;

    clock.advance(Duration::from_millis(1_005)).await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("send-1", "relay_timeout")
    );

    // A reply after the wait is dropped.
    mac.reply("send-1", json!({"turn": {}})).await;
    phone.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn the_other_methods_wait_fifteen_seconds(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let clock = pause_clock();
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "lookup-1",
            RelayMethod::TurnLookup,
            params_for(RelayMethod::TurnLookup),
        )
        .await;
    mac.expect_command().await;
    clock
        .advance_alive(Duration::from_secs(14), &mut [&mut mac, &mut phone])
        .await;
    phone.expect_quiet(QUIET).await;
    clock.advance(Duration::from_millis(1_005)).await;
    let (_, error) = phone.expect_refusal().await;
    assert_eq!(error.code, "relay_timeout");
}

#[sqlx::test(migrations = false)]
async fn a_duplicate_in_flight_is_forwarded_once(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    let params = params_for(RelayMethod::TurnSend);
    phone
        .command("send-1", RelayMethod::TurnSend, params.clone())
        .await;
    let (id, ..) = mac.expect_command().await;
    assert_eq!(id, "send-1");
    phone.command("send-1", RelayMethod::TurnSend, params).await;
    mac.expect_quiet(QUIET).await;

    mac.reply("send-1", json!({"turn": {"id": "turn-1"}})).await;
    let (id, result, _) = phone.expect_reply().await;
    assert_eq!(
        (id.as_str(), result),
        ("send-1", Some(json!({"turn": {"id": "turn-1"}})))
    );
    phone.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_reply_reaches_the_callers_new_link(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "send-1",
            RelayMethod::TurnSend,
            params_for(RelayMethod::TurnSend),
        )
        .await;
    mac.expect_command().await;
    // The phone's link drops mid-send, and it links again before the Mac answers.
    drop(phone);
    let mut phone = world.phone().await;

    mac.reply("send-1", json!({"turn": {"id": "turn-1"}})).await;
    let (id, result, _) = phone.expect_reply().await;
    assert_eq!(
        (id.as_str(), result),
        ("send-1", Some(json!({"turn": {"id": "turn-1"}})))
    );
}

#[sqlx::test(migrations = false)]
async fn a_resend_after_hub_restart_reaches_the_mac_again(pool: PgPool) {
    let mut world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    let params = params_for(RelayMethod::TurnSend);
    phone
        .command("send-1", RelayMethod::TurnSend, params.clone())
        .await;
    let (first, ..) = mac.expect_command().await;

    // The hub restarts before the Mac answers: its in-flight map is gone with it.
    world.hub.state.shutdown.trigger();
    assert_eq!(mac.expect_close().await, close_code::SHUTDOWN);
    assert_eq!(phone.expect_close().await, close_code::SHUTDOWN);
    tokio::time::timeout(FRAME_WAIT * 2, &mut world.hub.server)
        .await
        .expect("the old hub stops")
        .unwrap()
        .unwrap();
    world.hub = spawn_hub(&pool).await;

    // Both devices link to the new hub, and the phone resends the same id within its 30 s.
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    phone.command("send-1", RelayMethod::TurnSend, params).await;
    let (second, ..) = mac.expect_command().await;
    assert_eq!((first.as_str(), second.as_str()), ("send-1", "send-1"));

    // The Mac (which returns the turn it already made) answers, and the phone hears it, once.
    mac.reply("send-1", json!({"turn": {"id": "turn-1"}})).await;
    let (id, result, _) = phone.expect_reply().await;
    assert_eq!(
        (id.as_str(), result),
        ("send-1", Some(json!({"turn": {"id": "turn-1"}})))
    );
    mac.expect_quiet(QUIET).await;
    phone.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn answered_request_is_stale_without_forwarding(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    world
        .hub
        .seed_request(
            &world.blove,
            world.mac_id,
            "request-2",
            "thread-1",
            "resolved",
        )
        .await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "answer-2",
            RelayMethod::RequestRespond,
            json!({"requestId": "request-2"}),
        )
        .await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("answer-2", "stale_runtime_request")
    );
    mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_started_thread_is_routable_before_its_row_arrives(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let colleague = world.hub.user("cacheplane", "colleague").await;
    let (colleague_phone_token, _) = world.hub.enroll(&colleague, "ios", "Their iPhone").await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    phone
        .command(
            "start-1",
            RelayMethod::ThreadStart,
            params_for(RelayMethod::ThreadStart),
        )
        .await;
    let (id, method, ..) = mac.expect_command().await;
    assert_eq!((id.as_str(), method), ("start-1", RelayMethod::ThreadStart));

    // No `threads` row for "new-thread" exists on the hub yet, and a send to it still arrives.
    let send = json!({"threadId": "new-thread", "text": "and another thing"});
    phone
        .command("send-2", RelayMethod::TurnSend, send.clone())
        .await;
    let (id, method, params, ..) = mac.expect_command().await;
    assert_eq!(
        (id.as_str(), method, params),
        ("send-2", RelayMethod::TurnSend, send.clone())
    );
    assert_eq!(
        world
            .hub
            .state
            .relay
            .pending_thread_owner(world.blove.user_id, "new-thread"),
        Some(world.mac_id)
    );

    // The pending route is the user's alone.
    let mut their_phone = FakeDevice::ready(world.hub.addr, &colleague_phone_token)
        .await
        .0;
    their_phone
        .command("send-3", RelayMethod::TurnSend, send)
        .await;
    let (_, error) = their_phone.expect_refusal().await;
    assert_eq!(error.code, "not_found");
    mac.expect_quiet(QUIET).await;

    mac.reply("start-1", json!({"thread": {}, "turn": {}}))
        .await;
    mac.reply("send-2", json!({"turn": {}})).await;
    assert_eq!(phone.expect_reply().await.0, "start-1");
    assert_eq!(phone.expect_reply().await.0, "send-2");
}

/// Sends `count` commands to a thread that does not exist (so each is answered `not_found`, the
/// lookup running after the limits) and returns how many of them were `rate_limited`, with the
/// largest `retryAfterMs` among those.
async fn burst(phone: &mut FakeDevice, prefix: &str, count: usize) -> (usize, u64) {
    for n in 0..count {
        phone
            .command(
                &format!("{prefix}-{n}"),
                RelayMethod::TurnInterrupt,
                json!({"threadId": "missing"}),
            )
            .await;
    }
    let (mut limited, mut retry) = (0, 0);
    for _ in 0..count {
        let (_, error) = phone.expect_refusal().await;
        match error.code.as_str() {
            "not_found" => {}
            "rate_limited" => {
                limited += 1;
                retry = retry.max(error.details.unwrap()["retryAfterMs"].as_u64().unwrap());
            }
            other => panic!("unexpected {other}"),
        }
    }
    (limited, retry)
}

#[sqlx::test(migrations = false)]
async fn sixty_one_commands_in_a_minute_are_limited(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let clock = pause_clock();
    let mut phone = world.phone().await;

    // A burst of 20 at once, and the 21st waits a second for the bucket.
    assert_eq!(burst(&mut phone, "a", 21).await, (1, 1_000));
    // Twenty more at t = 20 s and at t = 40 s: sixty in the minute, every one within the burst.
    clock
        .advance_alive(Duration::from_secs(20), &mut [&mut phone])
        .await;
    assert_eq!(burst(&mut phone, "b", 20).await, (0, 0));
    clock
        .advance_alive(Duration::from_secs(20), &mut [&mut phone])
        .await;
    assert_eq!(burst(&mut phone, "c", 20).await, (0, 0));
    // At t = 50 s the bucket has room again, but the minute does not: the 61st waits until the
    // first twenty are a minute old.
    clock
        .advance_alive(Duration::from_secs(10), &mut [&mut phone])
        .await;
    assert_eq!(burst(&mut phone, "d", 1).await, (1, 10_000));
    clock.advance(Duration::from_millis(10_005)).await;
    assert_eq!(burst(&mut phone, "e", 1).await, (0, 0));
}

#[sqlx::test(migrations = false)]
async fn twenty_one_sends_per_user_are_limited(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let hub = &world.hub;
    let (cli_token, _) = hub.enroll(&world.blove, "cli", "agent-workspace").await;
    let colleague = hub.user("cacheplane", "colleague").await;
    let (their_token, _) = hub.enroll(&colleague, "ios", "Their iPhone").await;
    let mut phone = world.phone().await;
    let mut cli = FakeDevice::ready(hub.addr, &cli_token).await.0;
    let mut their_phone = FakeDevice::ready(hub.addr, &their_token).await.0;

    let missing_send = json!({"threadId": "missing", "text": "hi"});
    let missing_start = json!({"threadId": "t", "projectId": "missing"});
    // Twenty from two devices of one user, ten each: sends and starts count together.
    for n in 0..10 {
        phone
            .command(
                &format!("s{n}"),
                RelayMethod::TurnSend,
                missing_send.clone(),
            )
            .await;
        assert_eq!(phone.expect_refusal().await.1.code, "not_found");
        cli.command(
            &format!("t{n}"),
            RelayMethod::ThreadStart,
            missing_start.clone(),
        )
        .await;
        assert_eq!(cli.expect_refusal().await.1.code, "not_found");
    }
    phone
        .command("s-21", RelayMethod::TurnSend, missing_send.clone())
        .await;
    let (_, error) = phone.expect_refusal().await;
    assert_eq!(error.code, "rate_limited");
    let retry = error.details.unwrap()["retryAfterMs"].as_u64().unwrap();
    assert!((1..=60_000).contains(&retry), "{retry}");
    cli.command("t-21", RelayMethod::ThreadStart, missing_start)
        .await;
    assert_eq!(cli.expect_refusal().await.1.code, "rate_limited");

    // The other methods are not counted, and the limit is per user.
    phone
        .command(
            "i-1",
            RelayMethod::TurnInterrupt,
            json!({"threadId": "missing"}),
        )
        .await;
    assert_eq!(phone.expect_refusal().await.1.code, "not_found");
    their_phone
        .command("x-1", RelayMethod::TurnSend, missing_send)
        .await;
    assert_eq!(their_phone.expect_refusal().await.1.code, "not_found");
}

#[sqlx::test(migrations = false)]
async fn thirty_three_held_commands_overflow_to_device_offline(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let (cli_token, _) = world
        .hub
        .enroll(&world.blove, "cli", "agent-workspace")
        .await;
    world.mac_flaps().await;
    let mut phone = world.phone().await;
    let mut cli = FakeDevice::ready(world.hub.addr, &cli_token).await.0;

    // Thirty-two from two clients (each within its burst of twenty) are held.
    let interrupt = params_for(RelayMethod::TurnInterrupt);
    for n in 0..32 {
        let client = if n < 20 { &mut phone } else { &mut cli };
        client
            .command(
                &format!("h{n}"),
                RelayMethod::TurnInterrupt,
                interrupt.clone(),
            )
            .await;
    }
    eventually("thirty-two held commands", || async {
        (world.hub.state.relay.held(world.mac_id) == 32).then_some(())
    })
    .await;
    // The thirty-third is not.
    cli.command("h32", RelayMethod::TurnInterrupt, interrupt)
        .await;
    let (id, error) = cli.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("h32", "device_offline")
    );

    // When the Mac is back it gets the thirty-two.
    let mut mac = world.mac().await;
    let mut ids = Vec::new();
    for _ in 0..32 {
        ids.push(mac.expect_command().await.0);
    }
    ids.sort_by_key(|id| id[1..].parse::<u32>().unwrap());
    assert_eq!(ids, (0..32).map(|n| format!("h{n}")).collect::<Vec<_>>());
    mac.expect_quiet(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_resend_in_flight_is_not_counted_against_the_limits(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let (cli_token, _) = world
        .hub
        .enroll(&world.blove, "cli", "agent-workspace")
        .await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    let mut cli = FakeDevice::ready(world.hub.addr, &cli_token).await.0;

    // Nineteen sends from another device of the user, then the phone's, the twentieth of the
    // minute, which reaches the Mac.
    for n in 0..19 {
        cli.command(
            &format!("c{n}"),
            RelayMethod::TurnSend,
            json!({"threadId": "missing"}),
        )
        .await;
        assert_eq!(cli.expect_refusal().await.1.code, "not_found");
    }
    let send = params_for(RelayMethod::TurnSend);
    phone
        .command("send-20", RelayMethod::TurnSend, send.clone())
        .await;
    assert_eq!(mac.expect_command().await.0, "send-20");

    // The phone's link drops and it resends the same id, as it must: the window is full, but
    // the resend attaches to the send in flight rather than being refused.
    drop(phone);
    let mut phone = world.phone().await;
    phone.command("send-20", RelayMethod::TurnSend, send).await;
    // (A new send is refused: the window really is full.)
    phone
        .command(
            "send-21",
            RelayMethod::TurnSend,
            json!({"threadId": "missing"}),
        )
        .await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("send-21", "rate_limited")
    );
    mac.expect_quiet(QUIET).await;

    // Exactly one reply for send-20: the Mac's.
    mac.reply("send-20", json!({"turn": {"id": "turn-1"}}))
        .await;
    let (id, result, error) = phone.expect_reply().await;
    assert_eq!((id.as_str(), error), ("send-20", None));
    assert_eq!(result, Some(json!({"turn": {"id": "turn-1"}})));
    phone.expect_quiet(QUIET).await;
}

/// The next `reply`, past any `event` (the backlog `fill_queue` left), `pong`, or `presence`.
async fn reply_past_backlog(device: &mut FakeDevice) -> (String, Option<Value>) {
    loop {
        match device.next().await {
            RelayMessage::Event { .. }
            | RelayMessage::Pong { .. }
            | RelayMessage::Presence { .. } => {}
            RelayMessage::Reply { id, result, .. } => return (id, result),
            other => panic!("expected a reply, got {other:?}"),
        }
    }
}

#[sqlx::test(migrations = false)]
async fn a_reply_waits_for_room_in_the_callers_full_queue(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    phone
        .command(
            "send-1",
            RelayMethod::TurnSend,
            params_for(RelayMethod::TurnSend),
        )
        .await;
    mac.expect_command().await;

    // The phone stops reading until its queue is full, and the Mac answers meanwhile.
    fill_queue(&world.hub.state.relay, world.phone_id).await;
    mac.reply("send-1", json!({"turn": {"id": "turn-1"}})).await;
    real_sleep(Duration::from_millis(500)).await;

    // When it reads again (within the wait), the reply is there after the backlog.
    let (id, result) = reply_past_backlog(&mut phone).await;
    assert_eq!(
        (id.as_str(), result),
        ("send-1", Some(json!({"turn": {"id": "turn-1"}})))
    );
}

#[sqlx::test(migrations = false)]
async fn a_mac_whose_queue_stays_full_is_relay_timeout_not_offline(pool: PgPool) {
    let world = World::new(spawn_hub_paused(&pool).await).await;
    let clock = pause_clock();
    let _mac = world.mac().await; // links, then never reads
    let mut phone = world.phone().await;
    fill_queue(&world.hub.state.relay, world.mac_id).await;

    phone
        .command(
            "send-1",
            RelayMethod::TurnSend,
            params_for(RelayMethod::TurnSend),
        )
        .await;
    clock.advance(Duration::from_millis(4_900)).await;
    phone.expect_quiet(QUIET).await;
    // Five seconds without room: the Mac is online but not taking commands in time. That is a
    // timeout, not "offline", and it comes well before the 30 s reply wait.
    clock.advance(Duration::from_millis(105)).await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(
        (id.as_str(), error.code.as_str()),
        ("send-1", "relay_timeout")
    );
}

// ---- watching, live events, and frame limits ------------------------------------------------

/// A second phone of blove's.
async fn second_phone(world: &World) -> (FakeDevice, Uuid) {
    let (token, id) = world.hub.enroll(&world.blove, "ios", "iPad").await;
    (FakeDevice::ready(world.hub.addr, &token).await.0, id)
}

#[sqlx::test(migrations = false)]
async fn watching_tells_the_mac_the_full_set(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    world
        .hub
        .seed_thread(&world.blove, world.mac_id, "thread-2")
        .await;
    let (mut mac, _, first) =
        FakeDevice::ready_with_watching(world.hub.addr, &world.mac_token).await;
    // Nothing is watched yet, and the Mac is told so: the set is whole, never a delta.
    assert!(first.is_empty());
    let mut phone = world.phone().await;
    let (mut ipad, _) = second_phone(&world).await;

    phone.watch("thread-1").await;
    assert_eq!(mac.expect_watching().await, ["thread-1"]);
    phone.watch("thread-2").await;
    assert_eq!(mac.expect_watching().await, ["thread-1", "thread-2"]);
    phone.unwatch("thread-1").await;
    assert_eq!(mac.expect_watching().await, ["thread-2"]);

    // A second watcher of a thread already in the set changes nothing, so nothing is sent; nor
    // does the first one letting go of it.
    ipad.watch("thread-2").await;
    mac.expect_no_frame(QUIET).await;
    phone.unwatch("thread-2").await;
    mac.expect_no_frame(QUIET).await;
    // Watching twice, and unwatching what was never watched, are harmless.
    ipad.watch("thread-2").await;
    phone.unwatch("thread-1").await;
    mac.expect_no_frame(QUIET).await;
    ipad.unwatch("thread-2").await;
    assert!(mac.expect_watching().await.is_empty());

    // The watch outlives the Mac's link: a Mac that links again is told the set after `hello`.
    phone.watch("thread-1").await;
    assert_eq!(mac.expect_watching().await, ["thread-1"]);
    mac.close().await;
    let (_mac, _, again) = FakeDevice::ready_with_watching(world.hub.addr, &world.mac_token).await;
    assert_eq!(again, ["thread-1"]);
}

#[sqlx::test(migrations = false)]
async fn events_go_only_to_watchers(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut watcher = world.phone().await;
    let (mut bystander, _) = second_phone(&world).await;

    watcher.watch("thread-1").await;
    mac.expect_watching().await;
    for n in 0..3 {
        mac.event("thread-1", "message.delta", &format!("chunk {n}"))
            .await;
    }
    for n in 0..3 {
        let (thread, kind, text) = watcher.expect_event().await;
        assert_eq!(
            (thread.as_str(), kind.as_str(), text),
            ("thread-1", "message.delta", format!("chunk {n}"))
        );
    }
    bystander.expect_no_frame(QUIET).await;
    // The Mac hears nothing back for its events.
    mac.expect_no_frame(QUIET).await;

    // Once the bystander watches too, it gets them as well.
    bystander.watch("thread-1").await;
    settle().await;
    mac.event("thread-1", "turn.finished", "done").await;
    assert_eq!(watcher.expect_event().await.1, "turn.finished");
    assert_eq!(bystander.expect_event().await.1, "turn.finished");
}

#[sqlx::test(migrations = false)]
async fn an_unwatched_event_from_the_mac_is_dropped(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    // Nobody watches yet.
    mac.event("thread-1", "message.delta", "before").await;
    settle().await;
    phone.watch("thread-1").await;
    mac.expect_watching().await;
    // Another thread, an event with no thread, and one whose thread is not text: all dropped,
    // and none of them an error for the Mac.
    mac.event("thread-9", "message.delta", "elsewhere").await;
    mac.send_text(r#"{"type":"event","event":{"kind":"message.delta"}}"#)
        .await;
    mac.send_text(r#"{"type":"event","event":{"threadId":7}}"#)
        .await;
    mac.send_text(r#"{"type":"event","event":"not an object"}"#)
        .await;
    mac.event("thread-1", "message.delta", "after").await;
    // Only the one for the watched thread arrives, and it is the first thing the phone hears.
    assert_eq!(phone.expect_event().await.2, "after");
    phone.expect_no_frame(QUIET).await;
    mac.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_fifth_watch_is_refused(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    for n in 2..=6 {
        world
            .hub
            .seed_thread(&world.blove, world.mac_id, &format!("thread-{n}"))
            .await;
    }
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    let (mut ipad, _) = second_phone(&world).await;

    for n in 1..=4 {
        phone.watch(&format!("thread-{n}")).await;
        assert_eq!(mac.expect_watching().await.len(), n);
    }
    phone.watch("thread-5").await;
    let (code, _) = phone.expect_error().await;
    assert_eq!(code, "watch_limit");
    // The link survives and the refused thread is not in the set.
    phone.ping().await;
    mac.expect_no_frame(QUIET).await;
    // Watching one it already watches is not a fifth.
    phone.watch("thread-4").await;
    phone.expect_no_frame(QUIET).await;
    // The limit is per link: another phone has its own four.
    ipad.watch("thread-5").await;
    assert_eq!(mac.expect_watching().await.len(), 5);
    // Room again after an unwatch.
    phone.unwatch("thread-1").await;
    phone.watch("thread-5").await;
    phone.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn watching_another_users_thread_is_not_found(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let hub = &world.hub;
    let alice = hub.user("cacheplane", "alice").await;
    let (alice_token, alice_mac) = hub.enroll(&alice, "macos", "Alice's Mac").await;
    hub.seed_thread(&alice, alice_mac, "alice-thread").await;
    let stranger = hub.user("other-org", "blove").await;
    let (stranger_token, stranger_mac) = hub.enroll(&stranger, "macos", "Stranger's Mac").await;
    hub.seed_thread(&stranger, stranger_mac, "stranger-thread")
        .await;
    // A row of blove's whose owner is not his Mac.
    hub.seed_thread(&world.blove, world.phone_id, "phone-thread")
        .await;

    let mut alice_mac_link = FakeDevice::ready(hub.addr, &alice_token).await.0;
    let mut stranger_mac_link = FakeDevice::ready(hub.addr, &stranger_token).await.0;
    let mut phone = world.phone().await;

    let mut answers = Vec::new();
    for thread in [
        "alice-thread",
        "stranger-thread",
        "phone-thread",
        "no-such-thread",
    ] {
        phone.watch(thread).await;
        answers.push(phone.expect_error().await);
    }
    // Every miss reads the same: no difference between missing and someone else's.
    assert!(answers.iter().all(|answer| *answer == answers[0]));
    assert_eq!(answers[0].0, "not_found");
    // Nobody's Mac is told anything, and nothing is watched.
    alice_mac_link.expect_no_frame(QUIET).await;
    stranger_mac_link.expect_no_frame(QUIET).await;
    assert!(hub.state.relay.watched_by(alice_mac).is_empty());
    assert!(hub.state.relay.watched_by(stranger_mac).is_empty());

    // A thread of his own is fine, and so is one of an offline Mac of his.
    let mut mac = world.mac().await;
    assert!(matches!(phone.next().await, RelayMessage::Presence { .. }));
    phone.watch("thread-1").await;
    assert_eq!(mac.expect_watching().await, ["thread-1"]);
    phone.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn a_revoked_macs_thread_cannot_be_watched(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let (status, _) = world
        .hub
        .http("DELETE", "/v1/devices/self", Some(&world.mac_token))
        .await;
    assert_eq!(status, 204);
    let mut phone = world.phone().await;
    phone.watch("thread-1").await;
    assert_eq!(phone.expect_error().await.0, "not_found");
}

#[sqlx::test(migrations = false)]
async fn a_slow_phone_gets_a_stream_gap(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    phone.watch("thread-1").await;
    mac.expect_watching().await;

    // The phone stops reading until its queue is full; the Mac streams meanwhile.
    fill_queue(&world.hub.state.relay, world.phone_id).await;
    mac.event("thread-1", "message.delta", "lost one").await;
    mac.event("thread-1", "message.delta", "lost two").await;
    settle().await;

    // Reading again: the backlog, then exactly one `stream_gap`, and none of the lost events.
    let mut backlog = 0;
    loop {
        match phone.next().await {
            RelayMessage::Event { event } => {
                assert!(event.get("threadId").is_none(), "a dropped event came late");
                backlog += 1;
            }
            RelayMessage::StreamGap { thread_id } => {
                assert_eq!(thread_id, "thread-1");
                break;
            }
            RelayMessage::Pong { .. } | RelayMessage::Presence { .. } => {}
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(backlog > 100, "the backlog came first ({backlog})");
    phone.expect_no_frame(QUIET).await;

    // Live again: events flow, and no second gap.
    mac.event("thread-1", "message.delta", "live").await;
    assert_eq!(phone.expect_event().await.2, "live");
    phone.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn presence_is_sent_when_the_queue_has_room_again(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mac = world.mac().await;
    let mut phone = world.phone().await;

    // The phone stops reading until its queue is full. The Mac drops and comes back meanwhile:
    // two changes, neither of which fits.
    fill_queue(&world.hub.state.relay, world.phone_id).await;
    mac.close().await;
    let mac_id = world.mac_id;
    eventually("the Mac to go offline", || async {
        (!world.hub.state.relay.online(mac_id)).then_some(())
    })
    .await;
    settle().await;
    let mac = world.mac().await;
    settle().await;

    // Reading again: the backlog, then the current presence once (not the stale "offline").
    let mut presences = Vec::new();
    loop {
        match phone.next_within(QUIET).await {
            Some(RelayMessage::Event { .. }) => {}
            Some(RelayMessage::Presence { hosts }) => presences.push(hosts),
            Some(other) => panic!("unexpected {other:?}"),
            None => break,
        }
    }
    assert_eq!(presences.len(), 1, "{presences:?}");
    assert_eq!(presences[0].len(), 1);
    assert_eq!(presences[0][0].device_id, mac_id);
    assert!(presences[0][0].online, "{presences:?}");

    // The same when the last change is the Mac going away.
    fill_queue(&world.hub.state.relay, world.phone_id).await;
    mac.close().await;
    eventually("the Mac to go offline again", || async {
        (!world.hub.state.relay.online(mac_id)).then_some(())
    })
    .await;
    settle().await;
    let mut last = None;
    while let Some(frame) = phone.next_within(QUIET).await {
        if let RelayMessage::Presence { hosts } = frame {
            assert!(last.is_none(), "presence came twice");
            last = Some(hosts);
        }
    }
    assert!(!last.expect("presence arrived")[0].online);
}

/// `{"type":"ping"}` padded with trailing spaces to exactly `bytes` bytes: valid JSON, so only
/// its size can get it refused.
fn padded_ping(bytes: usize) -> String {
    let mut text = String::from(r#"{"type":"ping"}"#);
    text.push_str(&" ".repeat(bytes - text.len()));
    text
}

#[sqlx::test(migrations = false)]
async fn oversized_frames_are_refused_and_the_link_survives(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    // A client: 64 KiB is fine, one byte more is not, and the link carries on.
    phone.send_text(&padded_ping(64 * 1024)).await;
    assert!(matches!(phone.next().await, RelayMessage::Pong { .. }));
    for size in [64 * 1024 + 1, 100 * 1024, 300 * 1024] {
        phone.send_text(&padded_ping(size)).await;
        let (code, message) = phone.expect_error().await;
        assert_eq!(code, "invalid_request", "{size}");
        assert!(message.len() < 200, "the refusal does not echo the frame");
    }
    phone.ping().await;
    // An oversized frame is refused unread, whatever it says.
    phone
        .send_text(&format!(
            r#"{{"type":"command","id":"x","method":"turn.send","params":{{"text":"{}"}}}}"#,
            "a".repeat(100 * 1024)
        ))
        .await;
    assert_eq!(phone.expect_error().await.0, "invalid_request");
    phone.expect_no_frame(QUIET).await;
    mac.expect_no_frame(QUIET).await;

    // A host: 256 KiB is fine, one byte more is not.
    mac.send_text(&padded_ping(256 * 1024)).await;
    assert!(matches!(mac.next().await, RelayMessage::Pong { .. }));
    for size in [256 * 1024 + 1, 300 * 1024, 600 * 1024] {
        mac.send_text(&padded_ping(size)).await;
        assert_eq!(mac.expect_error().await.0, "invalid_request", "{size}");
    }
    mac.ping().await;

    // An event just under the host limit still reaches a watching phone; the phone's own limit
    // applies to what it sends, not to what it receives.
    phone.watch("thread-1").await;
    mac.expect_watching().await;
    mac.event("thread-1", "tool.completed", &"r".repeat(200 * 1024))
        .await;
    let (_, kind, text) = phone.expect_event().await;
    assert_eq!((kind.as_str(), text.len()), ("tool.completed", 200 * 1024));
    // One over the limit is refused, not forwarded.
    mac.event("thread-1", "tool.completed", &"r".repeat(300 * 1024))
        .await;
    assert_eq!(mac.expect_error().await.0, "invalid_request");
    phone.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn thread_start_auto_watches_the_new_thread(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    for n in 1..=4 {
        world
            .hub
            .seed_thread(&world.blove, world.mac_id, &format!("extra-{n}"))
            .await;
    }
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    let (mut ipad, _) = second_phone(&world).await;

    phone
        .command(
            "start-1",
            RelayMethod::ThreadStart,
            params_for(RelayMethod::ThreadStart),
        )
        .await;
    assert_eq!(mac.expect_command().await.0, "start-1");
    // The Mac is told the new thread is watched, before its row has reached the hub.
    eventually("the new thread to be watched", || async {
        (world.hub.state.relay.watched_by(world.mac_id) == ["new-thread"]).then_some(())
    })
    .await;
    mac.reply("start-1", json!({"thread": {"id": "new-thread"}}))
        .await;
    assert_eq!(phone.expect_reply().await.0, "start-1");
    mac.event("new-thread", "turn.acknowledged", "go").await;
    assert_eq!(phone.expect_event().await.0, "new-thread");
    // The caller's link only: another phone of the same user gets nothing.
    ipad.expect_no_frame(QUIET).await;

    // It counts toward the caller's four.
    for n in 1..=3 {
        phone.watch(&format!("extra-{n}")).await;
    }
    phone.expect_no_frame(QUIET).await;
    phone.watch("extra-4").await;
    assert_eq!(phone.expect_error().await.0, "watch_limit");
    // Letting it go ends the stream.
    phone.unwatch("new-thread").await;
    settle().await;
    mac.event("new-thread", "message.delta", "late").await;
    phone.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn closing_a_phone_clears_its_watches(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    world
        .hub
        .seed_thread(&world.blove, world.mac_id, "thread-2")
        .await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    let (mut ipad, _) = second_phone(&world).await;

    phone.watch("thread-1").await;
    mac.expect_watching().await;
    ipad.watch("thread-2").await;
    assert_eq!(mac.expect_watching().await, ["thread-1", "thread-2"]);

    // The phone goes away; only the iPad's watch is left.
    phone.close().await;
    assert_eq!(mac.expect_watching().await, ["thread-2"]);

    // And when the last watcher goes, the set is empty.
    ipad.close().await;
    assert!(mac.expect_watching().await.is_empty());
}

#[sqlx::test(migrations = false)]
async fn a_replaced_link_takes_its_watches_with_it(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut first = world.phone().await;
    first.watch("thread-1").await;
    mac.expect_watching().await;

    // The same phone links again: the old link is closed and its watches are gone.
    let mut second = world.phone().await;
    assert_eq!(first.expect_error().await.0, "link_replaced");
    assert!(mac.expect_watching().await.is_empty());
    // The old link finishing its cleanup later must not touch the new link's watches.
    second.watch("thread-1").await;
    assert_eq!(mac.expect_watching().await, ["thread-1"]);
    drop(first);
    settle().await;
    mac.event("thread-1", "message.delta", "still here").await;
    assert_eq!(second.expect_event().await.2, "still here");
    mac.expect_no_frame(QUIET).await;
}

#[sqlx::test(migrations = false)]
async fn frames_from_the_wrong_end_are_invalid(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;

    mac.watch("thread-1").await;
    assert_eq!(mac.expect_error().await.0, "invalid_request");
    mac.unwatch("thread-1").await;
    assert_eq!(mac.expect_error().await.0, "invalid_request");
    phone.event("thread-1", "message.delta", "forged").await;
    assert_eq!(phone.expect_error().await.0, "invalid_request");
    phone
        .send(&RelayMessage::Watching {
            thread_ids: vec!["thread-1".into()],
        })
        .await;
    assert_eq!(phone.expect_error().await.0, "invalid_request");
    phone
        .send(&RelayMessage::StreamGap {
            thread_id: "thread-1".into(),
        })
        .await;
    assert_eq!(phone.expect_error().await.0, "invalid_request");
    assert!(world.hub.state.relay.watched_by(world.mac_id).is_empty());
}

#[sqlx::test(migrations = false)]
async fn a_message_past_the_wire_cap_ends_only_that_connection(pool: PgPool) {
    let world = World::new(spawn_hub(&pool).await).await;
    let mut mac = world.mac().await;
    let mut phone = world.phone().await;
    // Past 1 MiB the socket layer refuses the message before the hub reads it.
    phone
        .send_text_regardless(&padded_ping(2 * 1024 * 1024))
        .await;
    phone.expect_close().await;
    let phone_id = world.phone_id;
    eventually("the phone's link to be forgotten", || async {
        (!world.hub.state.relay.online(phone_id)).then_some(())
    })
    .await;
    // Nobody else is affected.
    mac.ping().await;
}
