//! First relay-admission contract. Existing managed SQLx fixture ownership, no new runner.
mod common;
use b4hub_core::protocol::ClientProtocol;
use b4hub_db::{devices, instances, orgs, relay, settings, Db, Error};
use sqlx::{types::Uuid, PgPool};

async fn session(admin: &Db, app: &Db, name: &str) -> devices::Enrolled {
    let user = orgs::seed(
        admin,
        "relay-floor",
        "Relay",
        name,
        name,
        &format!("{name}@example.test"),
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        admin,
        user.org_id,
        user.user_id,
        std::time::Duration::from_secs(60),
    )
    .await
    .unwrap();
    devices::redeem(app, &code, "owned Mac", "macos")
        .await
        .unwrap()
}

#[sqlx::test(migrations = false)]
async fn one_connection_admission_reuses_its_native_session_and_target_snapshot(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let who = session(&admin, &app, "borrowed").await;
    let scoped = app.dedicated();
    let mut admission = relay::Admission::open(
        &scoped,
        &devices::SessionKey::of(&who.token),
        ClientProtocol::SUPPORTED,
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(admission.floor().minimum(), 1);
    assert_eq!(admission.identity().device_id, who.device_id);
    assert_eq!(admission.client(), ClientProtocol::SUPPORTED);
    // A second pool lease cannot complete here: every query below must borrow the one held TX.
    let found = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        admission.device(who.device_id),
    )
    .await
    .unwrap()
    .unwrap()
    .unwrap();
    assert_eq!(found.device_id, who.device_id);
    assert_eq!(admission.host_devices().await.unwrap().len(), 1);
    assert!(admission.thread("missing").await.unwrap().is_none());
    assert!(admission.request("missing").await.unwrap().is_none());
    assert!(admission.environment("missing").await.unwrap().is_none());
    assert!(admission.connection("missing").await.unwrap().is_none());
    admission.commit().await.unwrap();
    devices::end_session(&app, &who.token).await.unwrap();
    assert!(relay::Admission::open(
        &scoped,
        &devices::SessionKey::of(&who.token),
        ClientProtocol::SUPPORTED
    )
    .await
    .unwrap()
    .is_none());
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    assert!(matches!(
        relay::Admission::open(
            &scoped,
            &devices::SessionKey::of("unknown"),
            ClientProtocol::LEGACY
        )
        .await,
        Err(Error::ClientTooOld { minimum: 2 })
    ));
}

#[sqlx::test(migrations = false)]
async fn startup_read_waits_for_cut_before_its_first_rr_snapshot(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let starting = app.dedicated();
    sqlx::query("SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&starting.pool)
        .await
        .unwrap();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&starting.pool)
        .await
        .unwrap();
    let id = Uuid::from_u128(201);
    let mut cut = admin.pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE public.hub_settings IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *cut)
        .await
        .unwrap();
    sqlx::query("LOCK TABLE public.hub_instances IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *cut)
        .await
        .unwrap();
    sqlx::query("UPDATE public.hub_settings SET value='{\"minClientProtocol\":2}'::jsonb WHERE key='client_protocol'").execute(&mut *cut).await.unwrap();
    let work =
        tokio::spawn(async move { instances::register_with_floor(&starting, id, None).await });
    let observed=tokio::time::timeout(std::time::Duration::from_secs(5),async {
        loop {
            let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_settings'::regclass AND mode='AccessShareLock' AND NOT granted)").bind(pid).fetch_one(&admin.pool).await?;
            if waiting { break Ok::<(),sqlx::Error>(()); }
            tokio::task::yield_now().await;
        }
    }).await;
    let released = cut.commit().await;
    let result = work.await;
    released.unwrap();
    observed
        .expect("startup must wait before its first floor snapshot")
        .unwrap();
    assert_eq!(result.unwrap().unwrap().minimum(), 2);
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM public.hub_instances WHERE instance_id=$1)",
    )
    .bind(id)
    .fetch_one(&admin.pool)
    .await
    .unwrap();
    assert!(exists);
}

#[sqlx::test(migrations = false)]
async fn registered_startup_holds_the_floor_until_its_row_is_committed(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let starting = app.dedicated();
    let id = Uuid::from_u128(202);
    let startup_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&starting.pool)
        .await
        .unwrap();
    let owner = admin.dedicated();
    let owner_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&owner.pool)
        .await
        .unwrap();
    let mut table_gate = admin.pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE public.hub_instances IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *table_gate)
        .await
        .unwrap();
    let startup =
        tokio::spawn(async move { instances::register_with_floor(&starting, id, None).await });
    let reached=tokio::time::timeout(std::time::Duration::from_secs(5),async {
        loop {
            let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_settings'::regclass AND mode='AccessShareLock' AND granted) AND EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_instances'::regclass AND mode='RowExclusiveLock' AND NOT granted)").bind(startup_pid).fetch_one(&admin.pool).await?;
            if waiting { break Ok::<(),sqlx::Error>(()); }tokio::task::yield_now().await;
        }
    }).await;
    // Even if startup was not observed, release its original table controller before joining.
    let raise = tokio::spawn(async move { settings::raise_protocol_floor(&owner, 2).await });
    let cut_wait=tokio::time::timeout(std::time::Duration::from_secs(5),async {
        loop {
            let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_settings'::regclass AND mode='AccessExclusiveLock' AND NOT granted)").bind(owner_pid).fetch_one(&admin.pool).await?;
            if waiting { break Ok::<(),sqlx::Error>(()); }tokio::task::yield_now().await;
        }
    }).await;
    let released = table_gate.commit().await;
    let startup_result = startup.await;
    let raise_result = raise.await;
    released.unwrap();
    reached
        .expect("startup must hold settings before its instance write")
        .unwrap();
    cut_wait.expect("cut must wait for startup").unwrap();
    assert_eq!(startup_result.unwrap().unwrap().minimum(), 1);
    assert!(matches!(
        raise_result.unwrap(),
        Err(Error::ProtocolInstancesPresent)
    ));
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 1);
}

#[sqlx::test(migrations = false)]
async fn borrowed_targets_use_native_owned_connection_facts_and_never_default_unknown_to_legacy(
    pool: PgPool,
) {
    use b4hub_core::change::{Change, ChangeOp};
    use b4hub_db::{changes, relay::TargetProtocol};
    use serde_json::json;
    let (admin, app) = common::migrated(&pool).await;
    let who = session(&admin, &app, "target-owner").await;
    let other = session(&admin, &app, "other-owner").await;
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    let auth = devices::authenticate(&app, &who.token)
        .await
        .unwrap()
        .unwrap();
    let row = |seq, table: &str, id: &str, value| Change {
        device_seq: seq,
        wall: 1,
        table: table.into(),
        row_id: id.into(),
        op: ChangeOp::Insert,
        column: None,
        value: Some(value),
        hlc: None,
    };
    let batch = [
        row(
            1,
            "connections",
            "legacy",
            json!({"id":"legacy","kind":"codex"}),
        ),
        row(
            2,
            "connections",
            "modern",
            json!({"id":"modern","kind":"agentProtocol"}),
        ),
        row(
            3,
            "connections",
            "unknown",
            json!({"id":"unknown","kind":"future-kind"}),
        ),
        row(
            4,
            "threads",
            "legacy-thread",
            json!({"id":"legacy-thread","connectionId":"legacy"}),
        ),
        row(
            5,
            "threads",
            "modern-thread",
            json!({"id":"modern-thread","connectionId":"modern"}),
        ),
        row(
            6,
            "threads",
            "unknown-thread",
            json!({"id":"unknown-thread","connectionId":"unknown"}),
        ),
        row(
            7,
            "runtimeRequests",
            "request",
            json!({"id":"request","threadId":"modern-thread","state":"pending"}),
        ),
        row(
            8,
            "environments",
            "environment",
            json!({"id":"environment","name":"owned"}),
        ),
    ];
    changes::push_for_protocol(&app, &auth, &batch, ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    let scoped = app.dedicated();
    let mut native = relay::Admission::open(
        &scoped,
        &devices::SessionKey::of(&who.token),
        ClientProtocol::SUPPORTED,
    )
    .await
    .unwrap()
    .unwrap();
    for (id, thread, expected) in [
        ("legacy", "legacy-thread", TargetProtocol::Legacy),
        ("modern", "modern-thread", TargetProtocol::Protocol2),
        ("unknown", "unknown-thread", TargetProtocol::Unknown),
    ] {
        let connection = native.connection(id).await.unwrap().unwrap();
        assert_eq!(connection.owner.device_id, who.device_id);
        assert_eq!(connection.protocol, expected);
        let target = native.thread(thread).await.unwrap().unwrap();
        assert_eq!(target.owner.device_id, who.device_id);
        assert_eq!(target.protocol, expected);
    }
    let request = native.request("request").await.unwrap().unwrap();
    assert_eq!(request.state.as_deref(), Some("pending"));
    assert_eq!(request.target.protocol, TargetProtocol::Protocol2);
    assert_eq!(
        native
            .environment("environment")
            .await
            .unwrap()
            .unwrap()
            .device_id,
        who.device_id
    );
    assert_eq!(native.host_devices().await.unwrap().len(), 1);
    native.commit().await.unwrap();
    let mut unowned = relay::Admission::open(
        &scoped,
        &devices::SessionKey::of(&other.token),
        ClientProtocol::SUPPORTED,
    )
    .await
    .unwrap()
    .unwrap();
    assert!(unowned.connection("modern").await.unwrap().is_none());
    assert!(unowned.thread("modern-thread").await.unwrap().is_none());
    assert!(unowned.request("request").await.unwrap().is_none());
    assert!(unowned.environment("environment").await.unwrap().is_none());
    unowned.commit().await.unwrap();
    assert_eq!(TargetProtocol::Unknown.required(), None);
}
