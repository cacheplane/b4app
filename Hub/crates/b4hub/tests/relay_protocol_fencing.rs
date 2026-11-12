//! Actual native floor races on the unchanged loopback relay fixture.
mod relay_support;
use b4hub::relay::close_code;
use b4hub_core::relay::{RelayMessage, RelayMethod};
use relay_support::{spawn_hub, FakeDevice};
use serde_json::json;
use sqlx::PgPool;

async fn owned_cut(pool: &PgPool, minimum: i64) {
    // Test-only direct native update: a live-link fault race deliberately bypasses the owner
    // command's required empty fleet. There is no public force or downgrade command.
    let mut tx = pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE public.hub_settings IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("LOCK TABLE public.hub_instances IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *tx)
        .await
        .unwrap();
    let changed=sqlx::query("UPDATE public.hub_settings SET value=jsonb_build_object('minClientProtocol',$1::bigint) WHERE key='client_protocol'").bind(minimum).execute(&mut *tx).await.unwrap();
    assert_eq!(changed.rows_affected(), 1);
    tx.commit().await.unwrap();
}

#[sqlx::test(migrations = false)]
async fn a_post_upgrade_registration_gate_cannot_publish_hello_after_the_cut(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("fence", "gate").await;
    let (token, id) = hub.enroll(&user, "ios", "old").await;
    let gate = hub.state.relay.gate_registration();
    let addr = hub.addr;
    let connecting = tokio::spawn(async move { FakeDevice::connect(addr, &token).await });
    let observed =
        tokio::time::timeout(std::time::Duration::from_secs(2), gate.reached.notified()).await;
    // Release the original gate even if observing/cutting fails; join both original tasks
    // before assertions. No spawned test worker is abandoned on a failed barrier assertion.
    let cut = tokio::spawn({
        let pool = pool.clone();
        async move { owned_cut(&pool, 2).await }
    });
    let cut_result = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while !cut.is_finished() {
            tokio::task::yield_now().await;
        }
    })
    .await;
    gate.release.notify_one();
    let peer_result = connecting.await;
    let cut_join = cut.await;
    observed.unwrap();
    cut_result.unwrap();
    cut_join.unwrap();
    let mut peer = peer_result.unwrap();
    let RelayMessage::Error {
        code,
        details: Some(details),
        ..
    } = peer.next().await
    else {
        panic!("old gated link emitted content instead of refusing");
    };
    assert_eq!(code, "client_too_old");
    assert_eq!(details["minClientProtocol"], 2);
    assert_eq!(peer.expect_close().await, close_code::CLIENT_TOO_OLD);
    assert!(!hub.state.relay.online(id));
    assert_eq!(
        b4hub_db::instances::owner_of(&hub.state.db, user.user_id)
            .await
            .unwrap(),
        None,
        "the upgraded but refused registration must release its committed claim"
    );
    let other = sqlx::types::Uuid::new_v4();
    b4hub_db::instances::register(&hub.state.db, other, None)
        .await
        .unwrap();
    assert_eq!(
        b4hub_db::instances::claim_user(
            &hub.state.db,
            user.user_id,
            other,
            std::time::Duration::from_secs(86400)
        )
        .await
        .unwrap(),
        b4hub_db::instances::Claim::Ours
    );
    b4hub_db::instances::release_user(&hub.state.db, user.user_id, other)
        .await
        .unwrap();
}

#[sqlx::test(migrations = false)]
async fn missing_floor_notification_never_authorizes_an_old_ping_or_shutdown_flush(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("fence", "ping").await;
    let (token, id) = hub.enroll(&user, "ios", "old").await;
    let mut peer = FakeDevice::connect(hub.addr, &token).await;
    peer.next().await;
    peer.next().await;
    hub.state.instances.pause_heartbeat(true);
    hub.state.instances.deafen_listener(true);
    owned_cut(&pool, 2).await; // deliberately no NOTIFY
    peer.send_text_regardless("{\"type\":\"ping\"}").await;
    let RelayMessage::Error { code, .. } = peer.next().await else {
        panic!("a post-cut old action emitted a non-refusal frame");
    };
    assert_eq!(code, "client_too_old");
    assert_eq!(peer.expect_close().await, close_code::CLIENT_TOO_OLD);
    assert!(!hub.state.relay.online(id));
}

#[sqlx::test(migrations = false)]
async fn header_two_does_not_activate_a_native_protocol_target_at_floor_one(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("fence", "target").await;
    let (mac_token, mac_id) = hub.enroll(&user, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&user, "ios", "Phone").await;
    hub.seed_thread(&user, mac_id, "modern-thread").await;
    sqlx::query("UPDATE connections SET kind='agentProtocol' WHERE org_id=$1 AND id=(SELECT \"connectionId\" FROM threads WHERE org_id=$1 AND id='modern-thread')").bind(user.org_id).execute(&hub.admin.pool).await.unwrap();
    let mut mac = FakeDevice::try_connect(hub.addr, Some(&mac_token), Some("2"))
        .await
        .unwrap();
    mac.next().await;
    mac.next().await;
    let mut phone = FakeDevice::try_connect(hub.addr, Some(&phone_token), Some("2"))
        .await
        .unwrap();
    phone.next().await;
    phone.next().await;
    phone
        .command(
            "blocked",
            RelayMethod::TurnSend,
            json!({"threadId":"modern-thread","text":"private"}),
        )
        .await;
    let (id, error) = phone.expect_refusal().await;
    assert_eq!(id, "blocked");
    assert_eq!(error.code, "protocol_not_activated");
    mac.expect_quiet(std::time::Duration::from_millis(100))
        .await;
}

#[sqlx::test(migrations = false)]
async fn two_instances_observe_a_cut_at_action_boundaries_without_a_notification(pool: PgPool) {
    let first = relay_support::spawn_instance(&pool, std::time::Duration::from_secs(60)).await;
    let second = relay_support::spawn_instance(&pool, std::time::Duration::from_secs(60)).await;
    let a = first.user("two-fences", "a").await;
    let b = second.user("two-fences", "b").await;
    let (token_a, id_a) = first.enroll(&a, "ios", "a").await;
    let (token_b, id_b) = second.enroll(&b, "ios", "b").await;
    let mut old_a = FakeDevice::connect(first.addr, &token_a).await;
    let mut old_b = FakeDevice::connect(second.addr, &token_b).await;
    old_a.next().await;
    old_a.next().await;
    old_b.next().await;
    old_b.next().await;
    for hub in [&first, &second] {
        hub.state.instances.pause_heartbeat(true);
        hub.state.instances.deafen_listener(true);
    }
    owned_cut(&pool, 2).await;
    old_a
        .send_text_regardless("{\"type\":\"unwatch\",\"threadId\":\"missing\"}")
        .await;
    old_b.send_text_regardless("{\"type\":\"ping\"}").await;
    for peer in [&mut old_a, &mut old_b] {
        let RelayMessage::Error { code, .. } = peer.next().await else {
            panic!("post-cut old link emitted content");
        };
        assert_eq!(code, "client_too_old");
        assert_eq!(peer.expect_close().await, close_code::CLIENT_TOO_OLD);
    }
    assert!(!first.state.relay.online(id_a));
    assert!(!second.state.relay.online(id_b));
    let mut current = FakeDevice::try_connect(first.addr, Some(&token_a), Some("2"))
        .await
        .unwrap();
    let RelayMessage::Hello {
        min_client_protocol,
        ..
    } = current.next().await
    else {
        panic!("current client did not reopen");
    };
    assert_eq!(min_client_protocol, 2);
    current.next().await;
    current.send(&RelayMessage::Ping).await;
    assert!(matches!(current.next().await, RelayMessage::Pong { .. }));
}

#[sqlx::test(migrations = false)]
async fn a_fresh_capable_recipient_receives_a_checked_legacy_completion_after_the_cut(
    pool: PgPool,
) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("late-fence", "owner").await;
    let (mac_token, mac_id) = hub.enroll(&user, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&user, "ios", "Phone").await;
    hub.seed_thread(&user, mac_id, "legacy-thread").await;
    let mut mac = FakeDevice::try_connect(hub.addr, Some(&mac_token), Some("2"))
        .await
        .unwrap();
    mac.next().await;
    mac.next().await;
    let mut phone = FakeDevice::try_connect(hub.addr, Some(&phone_token), Some("2"))
        .await
        .unwrap();
    phone.next().await;
    phone.next().await;
    phone
        .command(
            "late",
            RelayMethod::TurnLookup,
            json!({"threadId":"legacy-thread","operationId":"op"}),
        )
        .await;
    let (id, method, params, deadline, from) = mac.expect_command().await;
    assert_eq!(id, "late");
    assert_eq!(method, RelayMethod::TurnLookup);
    assert_eq!(
        params,
        json!({"threadId":"legacy-thread","operationId":"op"})
    );
    assert!(deadline.is_some() && from.is_some());
    hub.state.instances.pause_heartbeat(true);
    hub.state.instances.deafen_listener(true);
    owned_cut(&pool, 2).await;
    let result = json!({"operationId":"op","state":"completed","answer":"legacy-result"});
    mac.reply("late", result.clone()).await;
    let (received, actual, error) = phone.expect_reply().await;
    assert_eq!(received, "late");
    assert_eq!(actual, Some(result));
    assert!(error.is_none());
    assert_eq!(hub.state.relay.min_client_protocol(), 2);
}

/// Drive the real Axum extractor/on_failed_upgrade path using a public Hyper OnUpgrade that
/// has no underlying connection. It resolves to a real Hyper error, not a fake socket/result.
async fn failed_handshake(state: &b4hub::serve::AppState, token: &str) -> axum::http::StatusCode {
    use axum::{body::Body, http::Request};
    use tower::ServiceExt;
    relay_support::eventually("the actual owned instance registration", || async {
        sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM public.hub_instances WHERE instance_id=$1)",
        )
        .bind(state.instances.id())
        .fetch_one(&state.db.pool)
        .await
        .ok()
        .filter(|registered| *registered)
        .map(|_| ())
    })
    .await;
    let mut request = Request::builder()
        .uri("/v1/devices/self/link")
        .header("authorization", format!("Bearer {token}"))
        .header("connection", "upgrade")
        .header("upgrade", "websocket")
        .header("sec-websocket-version", "13")
        .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
        .body(Body::empty())
        .unwrap();
    let failed = hyper::upgrade::on(&mut request);
    request.extensions_mut().insert(failed);
    b4hub::serve::router(state.clone())
        .oneshot(request)
        .await
        .unwrap()
        .status()
}

#[sqlx::test(migrations = false)]
async fn axum_failed_upgrade_releases_its_claim_before_becoming_drained(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("failed-upgrade", "owner").await;
    let (token, device) = hub.enroll(&user, "ios", "never-linked").await;
    assert_eq!(
        failed_handshake(&hub.state, &token).await,
        axum::http::StatusCode::SWITCHING_PROTOCOLS
    );
    // The sole tracked handoff remains live until its failed-upgrade cleanup actually ends.
    // Await that original lifecycle, then query the committed claim independently.
    tokio::time::timeout(std::time::Duration::from_secs(5), hub.state.relay.drained())
        .await
        .unwrap();
    assert!(!hub.state.relay.online(device));
    assert!(hub.state.relay.links_of(user.user_id).is_empty());
    assert_eq!(
        b4hub_db::instances::owner_of(&hub.state.db, user.user_id)
            .await
            .unwrap(),
        None
    );
    let other = sqlx::types::Uuid::new_v4();
    b4hub_db::instances::register(&hub.state.db, other, None)
        .await
        .unwrap();
    assert_eq!(
        b4hub_db::instances::claim_user(
            &hub.state.db,
            user.user_id,
            other,
            std::time::Duration::from_secs(86400)
        )
        .await
        .unwrap(),
        b4hub_db::instances::Claim::Ours
    );
    b4hub_db::instances::release_user(&hub.state.db, user.user_id, other)
        .await
        .unwrap();
}

#[sqlx::test(migrations = false)]
async fn axum_failed_upgrade_keeps_an_existing_link_generation_and_instance_claim(pool: PgPool) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("failed-upgrade-live", "owner").await;
    let (live_token, live_device) = hub.enroll(&user, "ios", "live").await;
    let (failed_token, failed_device) = hub.enroll(&user, "cli", "never-linked").await;
    let mut peer = FakeDevice::ready(hub.addr, &live_token).await.0;
    let generation = hub.state.relay.handle(live_device).unwrap().generation;
    assert_eq!(
        failed_handshake(&hub.state, &failed_token).await,
        axum::http::StatusCode::SWITCHING_PROTOCOLS
    );
    relay_support::eventually("only the original real link to remain live", || async {
        (hub.state.relay.live_links() == 1).then_some(())
    })
    .await;
    assert!(!hub.state.relay.online(failed_device));
    assert_eq!(
        hub.state.relay.handle(live_device).unwrap().generation,
        generation
    );
    assert_eq!(
        b4hub_db::instances::owner_of(&hub.state.db, user.user_id)
            .await
            .unwrap(),
        Some(hub.state.instances.id())
    );
    let other = sqlx::types::Uuid::new_v4();
    b4hub_db::instances::register(&hub.state.db, other, None)
        .await
        .unwrap();
    assert_eq!(
        b4hub_db::instances::claim_user(
            &hub.state.db,
            user.user_id,
            other,
            std::time::Duration::from_secs(86400)
        )
        .await
        .unwrap(),
        b4hub_db::instances::Claim::Other(hub.state.instances.id())
    );
    peer.ping().await;
    peer.close().await;
    tokio::time::timeout(std::time::Duration::from_secs(5), hub.state.relay.drained())
        .await
        .unwrap();
}

fn harmless_connections() -> Vec<serde_json::Value> {
    vec![
        json!({"kind":"codex"}),
        json!({"kind":"codex","target":null,"authReference":null,"localServerId":null}),
        json!({"kind":"codex","target":""}),
    ]
}
fn private_connections() -> Vec<serde_json::Value> {
    vec![
        json!({"kind":"codex","target":"PRIVATE_TARGET_CANARY"}),
        json!({"kind":"codex","authReference":"PRIVATE_AUTH_REFERENCE_CANARY"}),
        json!({"kind":"codex","localServerId":"PRIVATE_LOCAL_SERVER_CANARY"}),
        json!({"kind":"codex","authMode":null}),
        json!({"kind":"codex","authHeaderName":null}),
    ]
}

#[sqlx::test(migrations = false)]
async fn typed_event_and_native_sender_exclude_private_connection_values_without_inspecting_user_text(
    pool: PgPool,
) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("private-events", "owner").await;
    let (mac_token, mac_id) = hub.enroll(&user, "macos", "Mac").await;
    let (phone_token, phone_id) = hub.enroll(&user, "ios", "Phone").await;
    hub.seed_thread(&user, mac_id, "projection-thread").await;
    let mut mac = FakeDevice::ready(hub.addr, &mac_token).await.0;
    let mut phone = FakeDevice::ready(hub.addr, &phone_token).await.0;
    phone.watch("projection-thread").await;
    assert_eq!(mac.expect_watching().await, ["projection-thread"]);
    for connection in harmless_connections() {
        let event = json!({"threadId":"projection-thread","kind":"message.delta","payload":{"connection":connection},"text":{"connection":{"target":"opaque-user-text","authReference":"ordinary-text"}}});
        mac.send(&RelayMessage::Event {
            event: event.clone(),
        })
        .await;
        assert_eq!(
            phone.next_skipping_chatter().await,
            RelayMessage::Event {
                event: event.clone()
            }
        );
        let mut native = b4hub_db::relay::Admission::open(
            &hub.state.db,
            &b4hub_db::devices::SessionKey::of(&phone_token),
            b4hub_core::protocol::ClientProtocol::LEGACY,
        )
        .await
        .unwrap()
        .unwrap();
        let sent = b4hub::relay::admission::try_send_native(
            &hub.state.relay,
            &mut native,
            phone_id,
            RelayMessage::Event {
                event: event.clone(),
            },
        )
        .await;
        native.commit().await.unwrap();
        assert_eq!(sent, Ok(()));
        assert_eq!(
            phone.next_skipping_chatter().await,
            RelayMessage::Event { event }
        );
    }
    for connection in private_connections() {
        let event = json!({"threadId":"projection-thread","kind":"message.delta","payload":{"connection":connection}});
        mac.send(&RelayMessage::Event {
            event: event.clone(),
        })
        .await;
        mac.ping().await; // Ordered host processing has finished the event before the witness.
        phone
            .expect_quiet(std::time::Duration::from_millis(100))
            .await;
        let mut native = b4hub_db::relay::Admission::open(
            &hub.state.db,
            &b4hub_db::devices::SessionKey::of(&phone_token),
            b4hub_core::protocol::ClientProtocol::LEGACY,
        )
        .await
        .unwrap()
        .unwrap();
        let sent = b4hub::relay::admission::try_send_native(
            &hub.state.relay,
            &mut native,
            phone_id,
            RelayMessage::Event { event },
        )
        .await;
        native.commit().await.unwrap();
        assert_eq!(
            sent,
            Err(b4hub::relay::SendError::Offline),
            "the actual native sender must refuse before enqueue"
        );
        phone
            .expect_quiet(std::time::Duration::from_millis(100))
            .await;
    }
    phone.close().await;
    mac.close().await;
}

#[sqlx::test(migrations = false)]
async fn typed_reply_preserves_harmless_legacy_fields_and_refuses_private_target_results(
    pool: PgPool,
) {
    let hub = spawn_hub(&pool).await;
    let user = hub.user("private-replies", "owner").await;
    let (mac_token, mac_id) = hub.enroll(&user, "macos", "Mac").await;
    let (phone_token, _) = hub.enroll(&user, "ios", "Phone").await;
    hub.seed_thread(&user, mac_id, "reply-thread").await;
    let mut mac = FakeDevice::ready(hub.addr, &mac_token).await.0;
    let mut phone = FakeDevice::ready(hub.addr, &phone_token).await.0;
    for (index, connection) in harmless_connections().into_iter().enumerate() {
        let id = format!("harmless-{index}");
        phone
            .command(
                &id,
                RelayMethod::TurnLookup,
                json!({"threadId":"reply-thread","operationId":"op"}),
            )
            .await;
        assert_eq!(mac.expect_command().await.0, id);
        let result = json!({"connection":connection,"text":{"connection":{"target":"opaque-user-text","authReference":"ordinary-text"}}});
        mac.reply(&id, result.clone()).await;
        let (actual, body, error) = phone.expect_reply().await;
        assert_eq!(actual, id);
        assert_eq!(body, Some(result));
        assert!(error.is_none());
    }
    phone
        .command(
            "private-result",
            RelayMethod::TurnLookup,
            json!({"threadId":"reply-thread","operationId":"op"}),
        )
        .await;
    assert_eq!(mac.expect_command().await.0, "private-result");
    mac.reply(
        "private-result",
        json!({"connection":{"kind":"codex","target":"REPLY_PRIVATE_TARGET_CANARY"}}),
    )
    .await;
    // Preserve the existing original15s command timeout. The extra FRAME_WAIT is only the
    // observation allowance; no command, socket or queue deadline changes.
    let frame = tokio::time::timeout(
        b4hub_core::relay::REPLY_WAIT_OTHER + relay_support::FRAME_WAIT,
        phone.next_skipping_chatter_within(
            b4hub_core::relay::REPLY_WAIT_OTHER + relay_support::FRAME_WAIT,
        ),
    )
    .await
    .unwrap()
    .unwrap();
    let RelayMessage::Reply { id, result, error } = frame else {
        panic!("a private typed reply escaped as another frame");
    };
    assert_eq!(id, "private-result");
    assert!(
        result.is_none(),
        "private target result must never reach the phone"
    );
    assert_eq!(error.unwrap().code, "relay_timeout");
    let RelayMessage::Error { code, .. } = mac.next().await else {
        panic!("private reply producer was not fenced");
    };
    assert_eq!(code, "link_replaced");
    assert_eq!(mac.expect_close().await, close_code::REPLACED);
    phone.close().await;
}
