//! Native floor admission controls; each SQLx test owns its fresh database.
mod common;

use b4hub_core::change::{Change, ChangeOp};
use b4hub_core::protocol::ClientProtocol;
use b4hub_db::{changes, settings, snapshot, Error};
use serde_json::json;
use sqlx::PgPool;

fn insert(seq: i64, kind: &str) -> Change {
    Change {
        device_seq: seq,
        wall: 1,
        table: "connections".into(),
        row_id: format!("c{seq}"),
        op: ChangeOp::Insert,
        column: None,
        value: Some(json!({"id":format!("c{seq}"),"kind":kind,"label":"fixture"})),
        hlc: None,
    }
}

#[sqlx::test(migrations = false)]
async fn floor_is_owner_only_monotonic_and_never_defaults_on_bad_data(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 1);
    assert!(settings::raise_protocol_floor(&app, 2).await.is_err());
    assert!(matches!(
        settings::raise_protocol_floor(&admin, 3).await,
        Err(Error::UnsupportedProtocolFloor)
    ));
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 1);
    let instance = sqlx::types::Uuid::from_u128(77);
    sqlx::query("INSERT INTO public.hub_instances(instance_id,started_at,heartbeat_at) VALUES($1,now()-interval '1 day',now()-interval '1 day')")
        .bind(instance).execute(&admin.pool).await.unwrap();
    assert!(matches!(
        settings::raise_protocol_floor(&admin, 2).await,
        Err(Error::ProtocolInstancesPresent)
    ));
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 1);
    sqlx::query("DELETE FROM public.hub_instances WHERE instance_id=$1")
        .bind(instance)
        .execute(&admin.pool)
        .await
        .unwrap();
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 2);
    assert!(matches!(
        settings::raise_protocol_floor(&admin, 1).await,
        Err(Error::ProtocolFloorDecrease)
    ));
    sqlx::query("UPDATE hub_settings SET value='{}'::jsonb WHERE key='client_protocol'")
        .execute(&admin.pool)
        .await
        .unwrap();
    assert!(matches!(
        settings::protocol_floor(&app).await,
        Err(Error::InvalidProtocolFloor)
    ));
    for value in [
        json!({"minClientProtocol":0}),
        json!({"minClientProtocol":3}),
        json!({"minClientProtocol":"2"}),
        json!({"minClientProtocol":2,"extra":true}),
    ] {
        sqlx::query("UPDATE public.hub_settings SET value=$1 WHERE key='client_protocol'")
            .bind(value)
            .execute(&admin.pool)
            .await
            .unwrap();
        assert!(matches!(
            settings::protocol_floor(&app).await,
            Err(Error::InvalidProtocolFloor)
        ));
    }
    sqlx::query("DELETE FROM hub_settings WHERE key='client_protocol'")
        .execute(&admin.pool)
        .await
        .unwrap();
    assert!(matches!(
        settings::protocol_floor(&app).await,
        Err(Error::InvalidProtocolFloor)
    ));
}

#[sqlx::test(migrations = false)]
async fn modern_batch_is_rejected_before_any_allocation_and_old_clients_are_fenced(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let who = common::enrolled(&admin, &app, "floor-batch").await;
    let before: (i64, bool) =
        sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
            .fetch_one(&admin.pool)
            .await
            .unwrap();
    let result = changes::push_for_protocol(
        &app,
        &who,
        &[insert(1, "codex"), insert(2, "agentProtocol")],
        ClientProtocol::SUPPORTED,
    )
    .await;
    assert!(matches!(result, Err(Error::ProtocolNotActivated)));
    let after: (i64, bool) = sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
        .fetch_one(&admin.pool)
        .await
        .unwrap();
    assert_eq!(before, after);
    for column in [
        "peerProfile",
        "agentId",
        "protocolRetiredAt",
        "protocolRetiredReason",
        "kind",
    ] {
        let mut update = insert(1, "codex");
        update.op = ChangeOp::Update;
        update.column = Some(column.into());
        update.value = Some(json!(if column == "kind" {
            "agentProtocol"
        } else {
            "modern"
        }));
        assert!(matches!(
            changes::push_for_protocol(&app, &who, &[update], ClientProtocol::SUPPORTED).await,
            Err(Error::ProtocolNotActivated)
        ));
    }
    let after_updates: (i64, bool) =
        sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
            .fetch_one(&admin.pool)
            .await
            .unwrap();
    assert_eq!(before, after_updates);
    assert_eq!(
        changes::push_for_protocol(&app, &who, &[], ClientProtocol::SUPPORTED)
            .await
            .unwrap()
            .accepted_through,
        0
    );
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    assert!(matches!(
        changes::push_for_protocol(&app, &who, &[], ClientProtocol::LEGACY).await,
        Err(Error::ClientTooOld { minimum: 2 })
    ));
    assert!(matches!(
        changes::pull_for_protocol(&app, &who, 0, 100, ClientProtocol::LEGACY).await,
        Err(Error::ClientTooOld { minimum: 2 })
    ));
    assert!(matches!(
        snapshot::take_for_protocol(&app, &who, ClientProtocol::LEGACY).await,
        Err(Error::ClientTooOld { minimum: 2 })
    ));
    changes::push_for_protocol(
        &app,
        &who,
        &[insert(1, "agentProtocol")],
        ClientProtocol::SUPPORTED,
    )
    .await
    .unwrap();
    let page = changes::pull_for_protocol(&app, &who, 0, 100, ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    assert_eq!(page.changes.len(), 1);
    assert_eq!(
        page.changes[0].value.as_ref().unwrap()["kind"],
        "agentProtocol"
    );
}

#[sqlx::test(migrations = false)]
async fn current_floor_is_read_after_a_waiting_rr_reader_acquires_the_barrier(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let who = common::enrolled(&admin, &app, "floor-snapshot").await;
    let reader = app.dedicated();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&reader.pool)
        .await
        .unwrap();
    let mut cut = admin.pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE public.hub_settings IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *cut)
        .await
        .unwrap();
    sqlx::query("UPDATE public.hub_settings SET value='{\"minClientProtocol\":2}'::jsonb WHERE key='client_protocol'").execute(&mut *cut).await.unwrap();
    let work = tokio::spawn(async move {
        reader
            .protocol_read_tx(who.org_id, ClientProtocol::LEGACY)
            .await
    });
    let observation=tokio::time::timeout(std::time::Duration::from_secs(5),async {
        loop {
            let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_settings'::regclass AND NOT granted)").bind(pid).fetch_one(&admin.pool).await?;
            if waiting { break Ok::<(), sqlx::Error>(()); }
            tokio::task::yield_now().await;
        }
    }).await;
    // Release the actual owner before joining the original reader even if the observation failed.
    let released = cut.commit().await;
    let outcome = work.await.unwrap();
    released.unwrap();
    observation
        .expect("the actual reader must wait at the floor barrier")
        .unwrap();
    assert!(matches!(outcome, Err(Error::ClientTooOld { minimum: 2 })));
}

#[sqlx::test(migrations = false)]
async fn a_cut_waits_for_the_original_admitted_write_transaction(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let who = common::enrolled(&admin, &app, "floor-write").await;
    let (writer, _) = app
        .protocol_write_tx(who.org_id, ClientProtocol::LEGACY)
        .await
        .unwrap();
    let owner = admin.dedicated();
    let pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&owner.pool)
        .await
        .unwrap();
    let cut = tokio::spawn(async move { settings::raise_protocol_floor(&owner, 2).await });
    let observation=tokio::time::timeout(std::time::Duration::from_secs(5),async {
        loop {
            let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_settings'::regclass AND NOT granted)")
                .bind(pid).fetch_one(&admin.pool).await?;
            if waiting { break Ok::<(),sqlx::Error>(()); }
            tokio::task::yield_now().await;
        }
    }).await;
    // No observation/assertion propagates while the original controller still owns the barrier.
    let released = writer.commit().await;
    let result = cut.await;
    released.unwrap();
    observation
        .expect("the owner cut waits for the admitted transaction")
        .unwrap();
    assert_eq!(result.unwrap().unwrap().minimum(), 2);
}

#[sqlx::test(migrations = false)]
async fn staged_snapshot_and_private_insert_update_paths_do_not_publish_local_data(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let who = common::enrolled(&admin, &app, "floor-private").await;
    let mut legacy = insert(1, "codex");
    legacy.value.as_mut().unwrap()["target"] = json!("LOCAL-TARGET-SENTINEL");
    changes::push_for_protocol(&app, &who, &[legacy], ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    let staged = snapshot::take_for_protocol(&app, &who, ClientProtocol::LEGACY)
        .await
        .unwrap();
    let row = staged
        .changes
        .iter()
        .find(|change| change.table == "connections")
        .unwrap()
        .value
        .as_ref()
        .unwrap();
    for key in b4hub_core::protocol::CONNECTION_COLUMNS {
        assert!(row.get(*key).is_none());
    }
    assert!(row["target"].is_null());
    let feed = changes::pull_for_protocol(&app, &who, 0, 100, ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    assert!(feed.changes[0].value.as_ref().unwrap()["target"].is_null());
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    let mut modern = insert(2, "agentProtocol");
    modern.value.as_mut().unwrap()["peerProfile"] = json!("agentProtocol");
    modern.value.as_mut().unwrap()["agentId"] = json!("agent");
    changes::push_for_protocol(&app, &who, &[modern], ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    let mut update = insert(3, "codex");
    update.row_id = "c2".into();
    update.op = ChangeOp::Update;
    update.column = Some("protocolRetiredReason".into());
    update.value = Some(json!("agent_protocol_cutover"));
    changes::push_for_protocol(&app, &who, &[update], ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    let before: (i64, bool) =
        sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
            .fetch_one(&admin.pool)
            .await
            .unwrap();
    let mut secret = insert(4, "agentProtocol");
    secret.value.as_mut().unwrap()["authHeaderName"] = json!("PRIVATE-SENTINEL");
    assert!(matches!(
        changes::push_for_protocol(
            &app,
            &who,
            &[insert(5, "codex"), secret],
            ClientProtocol::SUPPORTED
        )
        .await,
        Err(Error::PrivateProtocolData)
    ));
    for table in [
        "protocolSubscriptions",
        "protocolRunSegments",
        "protocolOperations",
        "protocolGrantSecrets",
        "protocolGrants",
        "protocolPromptAnswers",
        "protocolHistoryAnchors",
    ] {
        let mut private = insert(4, "codex");
        private.table = table.into();
        assert!(matches!(
            changes::push_for_protocol(&app, &who, &[private], ClientProtocol::SUPPORTED).await,
            Err(Error::PrivateProtocolData)
        ));
    }
    for column in ["authMode", "authHeaderName", "unknownPrivateExtension"] {
        let mut secret_update = insert(4, "codex");
        secret_update.op = ChangeOp::Update;
        secret_update.column = Some(column.into());
        secret_update.value = Some(json!("PRIVATE-SENTINEL"));
        assert!(matches!(
            changes::push_for_protocol(&app, &who, &[secret_update], ClientProtocol::SUPPORTED)
                .await,
            Err(Error::PrivateProtocolData)
        ));
    }
    let after: (i64, bool) = sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
        .fetch_one(&admin.pool)
        .await
        .unwrap();
    assert_eq!(before, after);
    let final_snapshot = snapshot::take_for_protocol(&app, &who, ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    let row = final_snapshot
        .changes
        .iter()
        .find(|change| change.row_id == "c2")
        .unwrap()
        .value
        .as_ref()
        .unwrap();
    assert_eq!(row["peerProfile"], "agentProtocol");
    assert_eq!(row["agentId"], "agent");
    assert_eq!(row["protocolRetiredReason"], "agent_protocol_cutover");
    assert!(row.get("authMode").is_none());
    assert!(row.get("authHeaderName").is_none());
}

#[sqlx::test(migrations = false)]
async fn moving_a_protocol_child_to_a_legacy_parent_refuses_the_whole_staged_batch(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let who = common::enrolled(&admin, &app, "floor-old-parent").await;
    settings::raise_protocol_floor(&admin, 2).await.unwrap();
    let row = |seq, table: &str, id: &str, value| {
        let mut change = insert(seq, "codex");
        change.table = table.into();
        change.row_id = id.into();
        change.value = Some(value);
        change
    };
    let seed = [
        insert(1, "agentProtocol"),
        insert(2, "codex"),
        row(
            3,
            "threads",
            "modern-thread",
            json!({"id":"modern-thread","connectionId":"c1"}),
        ),
        row(
            4,
            "threads",
            "legacy-thread",
            json!({"id":"legacy-thread","connectionId":"c2"}),
        ),
        row(
            5,
            "turns",
            "owned-turn",
            json!({"id":"owned-turn","threadId":"modern-thread"}),
        ),
        row(
            6,
            "displayItems",
            "owned-item",
            json!({"id":"owned-item","threadId":"modern-thread"}),
        ),
        row(
            7,
            "runtimeRequests",
            "owned-request",
            json!({"id":"owned-request","threadId":"modern-thread"}),
        ),
    ];
    changes::push_for_protocol(&app, &who, &seed, ClientProtocol::SUPPORTED)
        .await
        .unwrap();
    let children = [
        ("turns", "owned-turn"),
        ("displayItems", "owned-item"),
        ("runtimeRequests", "owned-request"),
    ];
    // Prove setup reached native mirrored children before exercising the ancestry refusal.
    for (table, id) in children {
        let parent: String = sqlx::query_scalar(&format!(
            "SELECT \"threadId\" FROM \"{table}\" WHERE org_id=$1 AND user_id=$2 AND id=$3"
        ))
        .bind(who.org_id)
        .bind(who.user_id)
        .bind(id)
        .fetch_one(&admin.pool)
        .await
        .unwrap();
        assert_eq!(parent, "modern-thread");
    }
    // Test-only native fault setup: the owner CLI deliberately has no downgrade/force path.
    // This simulates a pre-existing modern graph during a floor1 admission, not an operator API.
    let mut fault = admin.pool.begin().await.unwrap();
    sqlx::query("LOCK TABLE public.hub_settings IN ACCESS EXCLUSIVE MODE")
        .execute(&mut *fault)
        .await
        .unwrap();
    sqlx::query("UPDATE public.hub_settings SET value='{\"minClientProtocol\":1}'::jsonb WHERE key='client_protocol'").execute(&mut *fault).await.unwrap();
    fault.commit().await.unwrap();
    let before: (i64, bool) =
        sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
            .fetch_one(&admin.pool)
            .await
            .unwrap();
    for (table, id) in children {
        let mut update = row(9, table, id, json!("legacy-thread"));
        update.op = ChangeOp::Update;
        update.column = Some("threadId".into());
        let outcome = changes::push_for_protocol(
            &app,
            &who,
            &[insert(8, "codex"), update],
            ClientProtocol::SUPPORTED,
        )
        .await;
        assert!(
            matches!(outcome, Err(Error::ProtocolNotActivated)),
            "both existing and proposed ancestry must be admitted"
        );
        let parent: String = sqlx::query_scalar(&format!(
            "SELECT \"threadId\" FROM \"{table}\" WHERE org_id=$1 AND user_id=$2 AND id=$3"
        ))
        .bind(who.org_id)
        .bind(who.user_id)
        .bind(id)
        .fetch_one(&admin.pool)
        .await
        .unwrap();
        assert_eq!(parent, "modern-thread");
        let after: (i64, bool) =
            sqlx::query_as("SELECT last_value,is_called FROM changes_hub_seq_seq")
                .fetch_one(&admin.pool)
                .await
                .unwrap();
        assert_eq!(after, before);
        assert_eq!(
            changes::push_for_protocol(&app, &who, &[], ClientProtocol::SUPPORTED)
                .await
                .unwrap()
                .accepted_through,
            7
        );
    }
    let leaked: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM connections WHERE org_id=$1 AND id='c8')")
            .bind(who.org_id)
            .fetch_one(&admin.pool)
            .await
            .unwrap();
    assert!(
        !leaked,
        "the earlier compatible change in the refused batch must not land"
    );
}

#[sqlx::test(migrations = false)]
async fn rr_owner_sees_a_registration_committed_before_its_instances_lock(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let owner = admin.dedicated();
    sqlx::query("SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&owner.pool)
        .await
        .unwrap();
    let isolation: String = sqlx::query_scalar("SHOW default_transaction_isolation")
        .fetch_one(&owner.pool)
        .await
        .unwrap();
    assert_eq!(isolation, "repeatable read");
    let owner_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&owner.pool)
        .await
        .unwrap();
    let mut registrar = admin.pool.begin().await.unwrap();
    let registrar_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
        .fetch_one(&mut *registrar)
        .await
        .unwrap();
    let instance = sqlx::types::Uuid::from_u128(91);
    sqlx::query("INSERT INTO public.hub_instances(instance_id,started_at,heartbeat_at) VALUES($1,now(),now())")
        .bind(instance).execute(&mut *registrar).await.unwrap();
    let cut = tokio::spawn(async move { settings::raise_protocol_floor(&owner, 2).await });
    let observation=tokio::time::timeout(std::time::Duration::from_secs(5),async {
        loop {
            let waiting:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_instances'::regclass AND mode='AccessExclusiveLock' AND NOT granted) AND EXISTS(SELECT 1 FROM pg_locks WHERE pid=$1 AND relation='public.hub_settings'::regclass AND mode='AccessExclusiveLock' AND granted) AND $2=ANY(pg_blocking_pids($1))")
                .bind(owner_pid).bind(registrar_pid).fetch_one(&admin.pool).await?;
            if waiting { break Ok::<(),sqlx::Error>(()); }
            tokio::task::yield_now().await;
        }
    }).await;
    // Registration becomes visible before the owner's instances lock is granted. Always release
    // and join both original handles before propagating an observation error or assertion.
    let released = registrar.commit().await;
    let result = cut.await;
    released.unwrap();
    observation
        .expect("the actual owner waits behind registration")
        .unwrap();
    assert!(matches!(
        result.unwrap(),
        Err(Error::ProtocolInstancesPresent)
    ));
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 1);
    let present: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM public.hub_instances WHERE instance_id=$1)",
    )
    .bind(instance)
    .fetch_one(&admin.pool)
    .await
    .unwrap();
    assert!(present, "refusal must not remove the registered instance");
}
