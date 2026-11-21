//! Registry authority contract; ordinary link producers are deliberately converted later.
mod common;
use b4hub::relay::registry::Identity;
use b4hub::relay::Relay;
use b4hub_core::{
    protocol::{ClientProtocol, ProtocolFloor},
    relay::Role,
};
use b4hub_db::{devices, orgs, relay::Admission, settings};
use sqlx::PgPool;

#[sqlx::test(migrations = false)]
async fn only_live_native_admission_can_register_and_floor_observation_closes_older_links(
    pool: PgPool,
) {
    let (admin, app) = common::migrated(&pool).await;
    let user = orgs::seed(
        &admin,
        "registration-floor",
        "Registry",
        "owner",
        "Owner",
        "owner@example.test",
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        &admin,
        user.org_id,
        user.user_id,
        std::time::Duration::from_secs(60),
    )
    .await
    .unwrap();
    let enrolled = devices::redeem(&app, &code, "owned", "macos")
        .await
        .unwrap();
    let session = devices::SessionKey::of(&enrolled.token);
    let identity = Identity {
        device_id: enrolled.device_id,
        name: "owned".into(),
        role: Role::Host,
        user_id: user.user_id,
        org_id: user.org_id,
        session: Some(session),
        probe: false,
    };
    let relay = Relay::new();
    let refused = relay.register(identity.clone());
    assert!(!refused.handle.is_admitted());
    assert!(!relay.online(enrolled.device_id));
    assert!(relay.links_of(user.user_id).is_empty());
    let mut native = Admission::open(&app, &session, ClientProtocol::LEGACY)
        .await
        .unwrap()
        .unwrap();
    let mut wrong = identity.clone();
    wrong.user_id = sqlx::types::Uuid::from_u128(999);
    assert!(relay.register_admitted(wrong, &mut native).is_err());
    assert!(relay.links_of(user.user_id).is_empty());
    let mut claimed = identity.clone();
    claimed.name = "caller-name-is-not-native-authority".into();
    let mut registered = relay.register_admitted(claimed, &mut native).unwrap();
    assert_eq!(registered.handle.name, "owned");
    assert_eq!(
        registered.handle.generation, 1,
        "the refused old entrypoint must not allocate a generation"
    );
    let refused_again = relay.register(identity.clone());
    assert!(!refused_again.handle.is_admitted());
    assert_eq!(
        relay.handle(enrolled.device_id).unwrap().generation,
        registered.handle.generation
    );
    assert!(
        matches!(
            registered.closing.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty)
        ),
        "refused old calls must not replace/close a valid entry"
    );
    assert!(registered.handle.is_admitted());
    assert_eq!(registered.handle.client_protocol, ClientProtocol::LEGACY);
    assert!(relay.online(enrolled.device_id));
    assert!(
        relay.register_admitted(identity, &mut native).is_err(),
        "one admission cannot authorize two registrations"
    );
    native.commit().await.unwrap();
    // A synthetic newer local observation is denial only. Header2 plus a native floor1
    // admission cannot overwrite it or manufacture protocol2 activation/registration.
    let denying = Relay::new();
    denying
        .observe_floor(ProtocolFloor::new(2).unwrap())
        .unwrap();
    let mut stale = Admission::open(&app, &session, ClientProtocol::SUPPORTED)
        .await
        .unwrap()
        .unwrap();
    let actual = stale.identity();
    let candidate = Identity {
        device_id: actual.device_id,
        name: "ignored".into(),
        role: Role::Host,
        user_id: actual.user_id,
        org_id: actual.org_id,
        session: Some(session),
        probe: false,
    };
    assert!(denying.register_admitted(candidate, &mut stale).is_err());
    assert!(denying.links_of(user.user_id).is_empty());
    stale.commit().await.unwrap();
    assert_eq!(settings::protocol_floor(&app).await.unwrap().minimum(), 1);
    let floor = settings::raise_protocol_floor(&admin, 2).await.unwrap();
    relay.observe_floor(floor).unwrap();
    assert_eq!(relay.min_client_protocol(), 2);
    let closed = registered
        .closing
        .try_recv()
        .expect("the actual old registration must receive its close");
    assert_eq!(closed.reason, "client too old");
    assert!(relay.observe_floor(ProtocolFloor::new(1).unwrap()).is_err());
    assert_eq!(relay.min_client_protocol(), 2);
}
