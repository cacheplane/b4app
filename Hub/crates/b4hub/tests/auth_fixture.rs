//! The contract `Tests/Fixtures/sync/auth.json` holds with the Swift client (`AuthWireTests`).
//! Each request example must deserialise into the hub's own request type, and each response
//! example must be what the hub's response type serialises, or (for the answers the routes build
//! as JSON) have the shape the running route answers. A renamed field breaks this suite or the
//! Swift one.
//!
//! The typed checks need no database. The last test runs the routes, so it needs
//! `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per test.

mod common;

use axum::http::StatusCode;
use b4hub::config::Signup;
use b4hub::routes::auth::{
    AuthConfigResponse, AuthSession, PasskeyBeginResponse, PasskeyFinishRequest,
};
use b4hub::routes::enroll::EnrollRequest;
use b4hub::routes::me::{AddPasskeyBeginResponse, AddPasskeyFinishRequest, ProfileRequest};
use b4hub_db::accounts::{self, Identity, Principal};
use b4hub_db::{devices, orgs};
use common::authenticator::Authenticator;
use common::{config, Hub, ORIGIN};
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use webauthn_rs::prelude::{PublicKeyCredential, RegisterPublicKeyCredential};

const FIXTURE: &str = include_str!("../../../../Tests/Fixtures/sync/auth.json");

fn example(name: &str) -> Value {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("auth.json is JSON");
    fixture
        .get(name)
        .unwrap_or_else(|| panic!("auth.json has no \"{name}\""))
        .clone()
}

/// Deserialises `name` into `T`, then serialises it back: what the hub would send is what the
/// fixture holds, key for key.
fn round_trips<T: DeserializeOwned + Serialize>(name: &str) -> T {
    let expected = example(name);
    let typed: T = serde_json::from_value(expected.clone())
        .unwrap_or_else(|error| panic!("\"{name}\" is not the hub's type: {error}"));
    assert_eq!(
        serde_json::to_value(&typed).unwrap(),
        expected,
        "\"{name}\" does not round-trip through the hub's type"
    );
    typed
}

#[test]
fn config_matches_the_hub_type() {
    let config: AuthConfigResponse = round_trips("config");
    assert_eq!(config.passkeys.rp_id, "local.b4.run");
    assert_eq!(config.signup, Signup::Open);
}

#[test]
fn passkey_begin_matches_the_hub_type() {
    let begun: PasskeyBeginResponse = round_trips("passkeyBegin");
    assert!(begun.registration.is_some());
}

#[test]
fn passkey_finish_variants_match_the_hub_type() {
    let assertion: PasskeyFinishRequest = round_trips("passkeyFinishAssertion");
    assert!(assertion.assertion.is_some() && assertion.attestation.is_none());
    assert!(assertion.device.device_id.is_some());
    // The opaque payload is a real WebAuthn response, not just any JSON.
    serde_json::from_value::<PublicKeyCredential>(assertion.assertion.unwrap())
        .expect("the assertion example is a PublicKeyCredential");

    let attestation: PasskeyFinishRequest = round_trips("passkeyFinishAttestation");
    assert!(attestation.attestation.is_some() && attestation.assertion.is_none());
    assert!(attestation.device.device_id.is_none());
    serde_json::from_value::<RegisterPublicKeyCredential>(attestation.attestation.unwrap())
        .expect("the attestation example is a RegisterPublicKeyCredential");
}

#[test]
fn auth_session_matches_the_hub_type() {
    let session: AuthSession = round_trips("authSession");
    assert!(session.needs_onboarding);
}

#[test]
fn profile_request_matches_the_hub_type() {
    let request: ProfileRequest = round_trips("profileRequest");
    assert_eq!(request.full_name, "Brian Love");
}

#[test]
fn add_passkey_matches_the_hub_types() {
    let begun: AddPasskeyBeginResponse = round_trips("addPasskeyBegin");
    assert_eq!(
        serde_json::to_value(&begun.registration).unwrap()["publicKey"]["rp"]["id"],
        "local.b4.run"
    );
    let finish: AddPasskeyFinishRequest = round_trips("addPasskeyFinish");
    serde_json::from_value::<RegisterPublicKeyCredential>(finish.attestation)
        .expect("the attestation example is a RegisterPublicKeyCredential");
}

#[test]
fn enroll_request_matches_the_hub_type() {
    // `EnrollRequest` only deserialises, and denies unknown fields.
    let request: EnrollRequest = serde_json::from_value(example("enrollRequest")).unwrap();
    assert_eq!(request.code, "ABCD2345");
    assert_eq!(request.device_name, "Brian's iPhone");
    assert_eq!(request.platform, "ios");
}

// ---- The answers the routes build as JSON ----

/// The JSON type of `value`, for comparing shapes.
fn kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

/// Asserts `real` (what a route answered) has the keys and value types of `example` (the
/// fixture). A `null` on either side matches anything, since a nullable field is null in one
/// answer and set in another; every object must have exactly the same keys, and every element
/// of an array is held to the example's first (an empty example array means an empty answer).
fn same_shape(path: &str, real: &Value, example: &Value) {
    match (real, example) {
        (Value::Null, _) | (_, Value::Null) => {}
        (Value::Object(real), Value::Object(example)) => {
            let mut real_keys: Vec<_> = real.keys().collect();
            let mut example_keys: Vec<_> = example.keys().collect();
            real_keys.sort_unstable();
            example_keys.sort_unstable();
            assert_eq!(real_keys, example_keys, "keys at {path}");
            for (key, value) in real {
                same_shape(&format!("{path}.{key}"), value, &example[key]);
            }
        }
        (Value::Array(real), Value::Array(example)) => match example.first() {
            Some(first) => {
                for (index, value) in real.iter().enumerate() {
                    same_shape(&format!("{path}[{index}]"), value, first);
                }
            }
            None => assert!(real.is_empty(), "{path} is empty in the example"),
        },
        (real, example) => assert_eq!(kind(real), kind(example), "type at {path}"),
    }
}

fn bearer(token: &str) -> String {
    format!("Bearer {token}")
}

#[sqlx::test(migrations = false)]
async fn routes_answer_the_shapes_the_fixture_holds(pool: PgPool) {
    let (admin, app) = common::migrated(&pool).await;
    let hub = Hub::start(app, config(Signup::Open)).await;
    let mut authenticator = Authenticator::new(ORIGIN);

    // Sign-up: the begin answer and the session.
    let begun = hub.post("/v1/auth/passkey/begin", None).await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    same_shape("passkeyBegin", &begun.body, &example("passkeyBegin"));
    let attestation = authenticator.register(&begun.body["registration"]);
    // The request is the fixture's, with the ceremony and the authenticator's response put in.
    let mut finish = example("passkeyFinishAttestation");
    finish["ceremonyId"] = begun.body["ceremonyId"].clone();
    finish["attestation"] = attestation;
    let session = hub.post("/v1/auth/passkey/finish", Some(&finish)).await;
    assert_eq!(session.status, StatusCode::OK, "{}", session.body);
    same_shape("authSession", &session.body, &example("authSession"));
    // Sign-in: the same ceremony shape, with an assertion.
    let begun = hub.post("/v1/auth/passkey/begin", None).await;
    let assertion = authenticator.assert(&begun.body["authentication"]);
    let mut finish = example("passkeyFinishAssertion");
    finish["ceremonyId"] = begun.body["ceremonyId"].clone();
    finish["assertion"] = assertion;
    // The example's `deviceId` names a device of the same user on the same platform: here, the
    // sign-up's (the attestation example's device is an iPhone).
    finish["device"]["deviceId"] = session.body["deviceId"].clone();
    finish["device"]["platform"] = json!("ios");
    let signed_in = hub.post("/v1/auth/passkey/finish", Some(&finish)).await;
    assert_eq!(signed_in.status, StatusCode::OK, "{}", signed_in.body);
    same_shape("authSession", &signed_in.body, &example("authSession"));
    // The device is reused, not made again, and its earlier token is gone: use the new one.
    assert_eq!(signed_in.body["deviceId"], session.body["deviceId"]);
    let token = signed_in.body["token"].as_str().unwrap().to_string();
    let auth = bearer(&token);
    let headers = [("authorization", auth.as_str())];

    // The profile request and the `me` answer, with a passkey and an Apple identity.
    let principal = Principal::from(
        devices::authenticate(&hub.state.db, &token)
            .await
            .unwrap()
            .expect("the token authenticates"),
    );
    accounts::add_identity(
        &hub.state.db,
        principal,
        Identity::Apple {
            sub: "001.fixture".into(),
            email: Some("x7k2@privaterelay.appleid.com".into()),
            refresh_enc: None,
        },
    )
    .await
    .unwrap();
    let profile = example("profileRequest");
    let me = hub
        .send("PUT", "/v1/me/profile", Some(&profile), &headers)
        .await;
    assert_eq!(me.status, StatusCode::OK, "{}", me.body);
    same_shape("me", &me.body, &example("me"));
    let me = hub.get("/v1/me", Some(&token)).await;
    same_shape("me", &me.body, &example("me"));
    assert_eq!(me.body["identities"].as_array().unwrap().len(), 2);

    // Adding a passkey: the begin answer and the identity it ends in.
    let added = hub
        .send("POST", "/v1/me/passkeys/begin", None, &headers)
        .await;
    assert_eq!(added.status, StatusCode::OK, "{}", added.body);
    same_shape("addPasskeyBegin", &added.body, &example("addPasskeyBegin"));
    let mut second = Authenticator::new(ORIGIN);
    let attestation = second.register(&added.body["registration"]);
    let mut finish = example("addPasskeyFinish");
    finish["ceremonyId"] = added.body["ceremonyId"].clone();
    finish["attestation"] = attestation;
    let identity = hub
        .send("POST", "/v1/me/passkeys/finish", Some(&finish), &headers)
        .await;
    assert_eq!(identity.status, StatusCode::OK, "{}", identity.body);
    same_shape("identity", &identity.body, &example("identity"));

    // Enrollment: an operator-minted code, the request, and the answer.
    let seeded = orgs::seed(
        &admin,
        "cacheplane",
        "Cacheplane",
        "blove",
        "Brian Love",
        "b@example.test",
    )
    .await
    .unwrap();
    let code = devices::create_enrollment_code(
        &admin,
        seeded.org_id,
        seeded.user_id,
        std::time::Duration::from_secs(600),
    )
    .await
    .unwrap();
    let mut request = example("enrollRequest");
    request["code"] = json!(code);
    let enrolled = hub.post("/v1/enroll", Some(&request)).await;
    assert_eq!(enrolled.status, StatusCode::OK, "{}", enrolled.body);
    same_shape("enrollResponse", &enrolled.body, &example("enrollResponse"));
}
