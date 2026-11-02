//! Passkey sign-in and sign-up (`/v1/auth/config`, `/v1/auth/passkey/begin`,
//! `/v1/auth/passkey/finish`) over a loopback listener, with a software authenticator for
//! `https://local.b4.run`. Run with `source <(../scripts/test-db.sh)` first; `#[sqlx::test]`
//! creates one database per test.

mod common;

use std::io::Write;
use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use b4hub::cli::Settings;
use b4hub::config::{Config, Signup};
use b4hub_db::accounts;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use common::authenticator::Authenticator;
use common::{config, Answer, Hub, ORIGIN, RP_ID};
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;
use tracing_subscriber::fmt::MakeWriter;

const BEGIN: &str = "/v1/auth/passkey/begin";
const FINISH: &str = "/v1/auth/passkey/finish";

async fn hub(pool: &PgPool, signup: Signup) -> Hub {
    hub_with(pool, config(signup)).await
}

async fn hub_with(pool: &PgPool, config: Config) -> Hub {
    let (_admin, app) = common::migrated(pool).await;
    Hub::start(app, config).await
}

/// A second hub process on the same database with another configuration, as after a restart
/// or on another replica.
async fn another_hub(first: &Hub, config: Config) -> Hub {
    Hub::start(first.state.db.clone(), config).await
}

fn device(name: &str, platform: &str) -> Value {
    json!({"deviceName": name, "platform": platform})
}

fn finish_body(ceremony: &Value, field: &str, response: Value, device: Value) -> Value {
    json!({"ceremonyId": ceremony.clone(), field: response, "device": device})
}

async fn begin(hub: &Hub) -> Value {
    let answer = hub.post(BEGIN, None).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    answer.body
}

/// Signs up with a new passkey on `authenticator`, from a Mac.
async fn sign_up(hub: &Hub, authenticator: &mut Authenticator) -> Value {
    let begun = begin(hub).await;
    let attestation = authenticator.register(&begun["registration"]);
    let answer = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Brian's Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    answer.body
}

/// Signs in with `authenticator`'s latest passkey, sending `device`.
async fn sign_in(hub: &Hub, authenticator: &mut Authenticator, device: Value) -> Answer {
    let begun = begin(hub).await;
    let assertion = authenticator.assert(&begun["authentication"]);
    hub.post(
        FINISH,
        Some(&finish_body(
            &begun["ceremonyId"],
            "assertion",
            assertion,
            device,
        )),
    )
    .await
}

fn assert_session_shape(session: &Value) {
    assert!(session["deviceId"].as_str().is_some(), "{session}");
    assert_eq!(
        session["token"].as_str().map(str::len),
        Some(43),
        "{session}"
    );
    assert!(session["org"]["slug"]
        .as_str()
        .is_some_and(|s| s.starts_with("o-")));
    assert!(session["user"]["username"]
        .as_str()
        .is_some_and(|s| s.starts_with("u-")));
    assert!(session["needsOnboarding"].is_boolean(), "{session}");
}

/// The stored passkey JSON and `last_used_at` of the identity with `credential_id`.
async fn stored_passkey(hub: &Hub, credential_id: &[u8]) -> (Value, Option<String>) {
    sqlx::query_as(
        "SELECT passkey, last_used_at::text FROM user_identities WHERE credential_id = $1",
    )
    .bind(credential_id)
    .fetch_one(&hub.state.db.pool)
    .await
    .unwrap()
}

#[sqlx::test(migrations = false)]
async fn config_reports_policy(pool: PgPool) {
    let open = hub(&pool, Signup::Open).await;
    let answer = open.get("/v1/auth/config", None).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    assert_eq!(
        answer.body,
        json!({
            "passkeys": {"rpId": RP_ID},
            "apple": {"native": false, "web": false},
            "signup": "open",
        })
    );

    let closed = another_hub(&open, config(Signup::Closed)).await;
    let answer = closed.get("/v1/auth/config", None).await;
    assert_eq!(answer.body["signup"], "closed");
}

#[sqlx::test(migrations = false)]
async fn register_then_sign_in_same_user(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let begun = begin(&hub).await;

    // The registration options are exactly the sign-up policy's.
    let options = &begun["registration"]["publicKey"];
    assert_eq!(options["rp"]["id"], RP_ID);
    assert_eq!(options["user"]["name"], "Agent Workspace account");
    assert_eq!(options["user"]["displayName"], "Agent Workspace account");
    assert_eq!(
        options["authenticatorSelection"]["residentKey"], "required",
        "{options}"
    );
    assert_eq!(
        options["authenticatorSelection"]["requireResidentKey"],
        true
    );
    assert_eq!(
        options["authenticatorSelection"]["userVerification"],
        "required"
    );
    assert_eq!(options["attestation"], "none");
    // The assertion has no allow-list, so the OS offers any passkey for this relying party.
    let request = &begun["authentication"]["publicKey"];
    assert_eq!(request["rpId"], RP_ID);
    assert_eq!(request["userVerification"], "required");
    assert!(
        request["allowCredentials"]
            .as_array()
            .is_none_or(Vec::is_empty),
        "{request}"
    );
    assert!(Uuid::parse_str(begun["ceremonyId"].as_str().unwrap()).is_ok());

    let mut authenticator = Authenticator::new(ORIGIN);
    let attestation = authenticator.register(&begun["registration"]);
    let signed_up = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Brian's Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(signed_up.status, StatusCode::OK, "{}", signed_up.body);
    let signed_up = signed_up.body;
    assert_session_shape(&signed_up);
    assert_eq!(signed_up["needsOnboarding"], true);
    assert_eq!(signed_up["org"]["name"], "My Org");
    assert_eq!(signed_up["user"]["displayName"], "");

    // The token works, for the device the sign-up made.
    let me = hub.get("/v1/me", signed_up["token"].as_str()).await;
    assert_eq!(me.status, StatusCode::OK, "{}", me.body);
    assert_eq!(me.body["deviceId"], signed_up["deviceId"]);
    assert_eq!(me.body["deviceName"], "Brian's Mac");
    assert_eq!(me.body["platform"], "macos");

    // Signing in with the same passkey reaches the same user, still not onboarded.
    let signed_in = sign_in(&hub, &mut authenticator, device("Brian's iPhone", "ios")).await;
    assert_eq!(signed_in.status, StatusCode::OK, "{}", signed_in.body);
    assert_session_shape(&signed_in.body);
    assert_eq!(signed_in.body["org"], signed_up["org"]);
    assert_eq!(signed_in.body["user"], signed_up["user"]);
    assert_eq!(signed_in.body["needsOnboarding"], true);
    assert_ne!(signed_in.body["deviceId"], signed_up["deviceId"]);
    assert_ne!(signed_in.body["token"], signed_up["token"]);

    // Once the user has a profile, a sign-in says so.
    let who = b4hub_db::devices::authenticate(&hub.state.db, signed_up["token"].as_str().unwrap())
        .await
        .unwrap()
        .unwrap();
    let mut tx = hub.state.db.tenant_tx(who.org_id).await.unwrap();
    accounts::set_profile(&mut tx, who.user_id, "Brian Love")
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let onboarded = sign_in(&hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    assert_eq!(onboarded.status, StatusCode::OK, "{}", onboarded.body);
    assert_eq!(onboarded.body["needsOnboarding"], false);
    assert_eq!(onboarded.body["org"]["name"], "Brian's Org");
    assert_eq!(onboarded.body["user"]["displayName"], "Brian Love");
    assert_eq!(
        onboarded.body["user"]["username"],
        signed_up["user"]["username"]
    );
}

#[sqlx::test(migrations = false)]
async fn begin_omits_registration_when_closed(pool: PgPool) {
    let hub = hub(&pool, Signup::Closed).await;
    let begun = begin(&hub).await;
    assert!(begun.get("registration").is_none(), "{begun}");
    assert!(begun["authentication"]["publicKey"]["challenge"].is_string());
    assert!(begun["ceremonyId"].is_string());
}

#[sqlx::test(migrations = false)]
async fn finish_attestation_when_closed_is_signup_closed(pool: PgPool) {
    // A ceremony begun while sign-up was open, finished after it closed.
    let open = hub(&pool, Signup::Open).await;
    let closed = another_hub(&open, config(Signup::Closed)).await;
    let begun = begin(&open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    let attestation = authenticator.register(&begun["registration"]);
    let answer = closed
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::FORBIDDEN, "{}", answer.body);
    assert_eq!(answer.code(), "signup_closed");
    assert_eq!(answer.body["error"]["kind"], "request_error");
    let users: i64 = sqlx::query_scalar("SELECT count(*) FROM user_identities")
        .fetch_one(&closed.state.db.pool)
        .await
        .unwrap();
    assert_eq!(users, 0);

    // An existing account still signs in while sign-up is closed.
    let mut existing = Authenticator::new(ORIGIN);
    sign_up(&open, &mut existing).await;
    let answer = sign_in(&closed, &mut existing, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
}

#[sqlx::test(migrations = false)]
async fn wrong_origin_rejected(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;

    let mut elsewhere = Authenticator::new("https://evil.example");
    let begun = begin(&hub).await;
    let attestation = elsewhere.register(&begun["registration"]);
    let answer = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");

    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;
    authenticator.origin = "https://local.b4.run.evil.example".into();
    let answer = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");
}

#[sqlx::test(migrations = false)]
async fn unknown_or_mismatched_credential_rejected(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;

    // A credential the hub never registered.
    let mut stranger = Authenticator::new(ORIGIN);
    let begun = begin(&hub).await;
    stranger.register(&begun["registration"]);
    let answer = sign_in(&hub, &mut stranger, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");

    // A registered credential presented with another user handle.
    authenticator.credentials[0].user_handle = Uuid::new_v4().as_bytes().to_vec();
    let answer = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");

    // Registering a credential id that already belongs to an account.
    let begun = begin(&hub).await;
    let mut twin = Authenticator::new(ORIGIN);
    let mut attestation = twin.register(&begun["registration"]);
    let taken = URL_SAFE_NO_PAD.encode(&authenticator.credentials[0].id);
    let raw = common::authenticator::decode(
        attestation["response"]["attestationObject"]
            .as_str()
            .unwrap(),
    );
    let fresh = &twin.credentials[0].id;
    let swapped: Vec<u8> = replace(&raw, fresh, &authenticator.credentials[0].id);
    attestation["response"]["attestationObject"] = json!(URL_SAFE_NO_PAD.encode(swapped));
    attestation["id"] = json!(taken);
    attestation["rawId"] = json!(taken);
    let answer = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");
}

fn replace(haystack: &[u8], needle: &[u8], with: &[u8]) -> Vec<u8> {
    assert_eq!(needle.len(), with.len());
    let at = haystack
        .windows(needle.len())
        .position(|w| w == needle)
        .expect("the needle is there");
    let mut out = haystack.to_vec();
    out[at..at + needle.len()].copy_from_slice(with);
    out
}

#[sqlx::test(migrations = false)]
async fn finish_validates_the_request(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;
    let begun = begin(&hub).await;
    let assertion = authenticator.assert(&begun["authentication"]);
    let id = &begun["ceremonyId"];

    for (body, why) in [
        (
            json!({"ceremonyId": id, "device": device("Mac", "macos")}),
            "neither response",
        ),
        (
            json!({"ceremonyId": id, "assertion": assertion, "attestation": assertion,
                   "device": device("Mac", "macos")}),
            "both responses",
        ),
        (
            finish_body(id, "assertion", assertion.clone(), device("  ", "macos")),
            "a blank device name",
        ),
        (
            finish_body(id, "assertion", assertion.clone(), device("Mac", "windows")),
            "an unknown platform",
        ),
        (
            json!({"ceremonyId": id, "assertion": assertion, "device": device("Mac", "macos"),
                   "extra": 1}),
            "an unknown field",
        ),
        (
            json!({"ceremonyId": "not-a-uuid", "assertion": assertion,
                   "device": device("Mac", "macos")}),
            "a malformed ceremony id",
        ),
    ] {
        let answer = hub.post(FINISH, Some(&body)).await;
        assert_eq!(
            answer.status,
            StatusCode::BAD_REQUEST,
            "{why}: {}",
            answer.body
        );
        assert_eq!(answer.code(), "invalid_request", "{why}");
    }

    // None of those used the ceremony up.
    let answer = hub
        .post(
            FINISH,
            Some(&finish_body(
                id,
                "assertion",
                assertion,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
}

#[sqlx::test(migrations = false)]
async fn replayed_finish_is_ceremony_expired(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;

    let begun = begin(&hub).await;
    let body = finish_body(
        &begun["ceremonyId"],
        "assertion",
        authenticator.assert(&begun["authentication"]),
        device("Mac", "macos"),
    );
    let first = hub.post(FINISH, Some(&body)).await;
    assert_eq!(first.status, StatusCode::OK, "{}", first.body);
    let again = hub.post(FINISH, Some(&body)).await;
    assert_eq!(again.status, StatusCode::BAD_REQUEST, "{}", again.body);
    assert_eq!(again.code(), "ceremony_expired");

    // An unknown ceremony answers the same.
    let mut unknown = body.clone();
    unknown["ceremonyId"] = json!(Uuid::new_v4().to_string());
    let answer = hub.post(FINISH, Some(&unknown)).await;
    assert_eq!(answer.status, StatusCode::BAD_REQUEST, "{}", answer.body);
    assert_eq!(answer.code(), "ceremony_expired");

    // And so does an expired one.
    let begun = begin(&hub).await;
    sqlx::query(
        "UPDATE auth_ceremonies SET expires_at = now() - interval '1 second' WHERE id = $1",
    )
    .bind(Uuid::parse_str(begun["ceremonyId"].as_str().unwrap()).unwrap())
    .execute(&hub.state.db.pool)
    .await
    .unwrap();
    let body = finish_body(
        &begun["ceremonyId"],
        "assertion",
        authenticator.assert(&begun["authentication"]),
        device("Mac", "macos"),
    );
    let answer = hub.post(FINISH, Some(&body)).await;
    assert_eq!(answer.status, StatusCode::BAD_REQUEST, "{}", answer.body);
    assert_eq!(answer.code(), "ceremony_expired");
}

#[sqlx::test(migrations = false)]
async fn concurrent_finish_one_token(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;

    // Each round on a fresh hub process, so the finish rate limit (10 a minute) stays out of it.
    for round in 0..10 {
        let hub = another_hub(&hub, config(Signup::Open)).await;
        let begun = begin(&hub).await;
        let body = finish_body(
            &begun["ceremonyId"],
            "assertion",
            authenticator.assert(&begun["authentication"]),
            device("Mac", "macos"),
        );
        let (a, b) = tokio::join!(hub.post(FINISH, Some(&body)), hub.post(FINISH, Some(&body)));
        let mut statuses = [a.status, b.status];
        statuses.sort();
        assert_eq!(
            statuses,
            [StatusCode::OK, StatusCode::BAD_REQUEST],
            "round {round}: {} / {}",
            a.body,
            b.body
        );
        let loser = if a.status == StatusCode::OK { &b } else { &a };
        assert_eq!(loser.code(), "ceremony_expired", "round {round}");
    }

    // Concurrent sign-ups from one ceremony make one account.
    let hub = another_hub(&hub, config(Signup::Open)).await;
    let begun = begin(&hub).await;
    let mut newcomer = Authenticator::new(ORIGIN);
    let body = finish_body(
        &begun["ceremonyId"],
        "attestation",
        newcomer.register(&begun["registration"]),
        device("Mac", "macos"),
    );
    let (a, b) = tokio::join!(hub.post(FINISH, Some(&body)), hub.post(FINISH, Some(&body)));
    assert_ne!(a.status, b.status, "{} / {}", a.body, b.body);
    let orgs: i64 = sqlx::query_scalar("SELECT count(*) FROM orgs")
        .fetch_one(&hub.state.db.pool)
        .await
        .unwrap();
    assert_eq!(orgs, 2);
}

#[sqlx::test(migrations = false)]
async fn counter_updated(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;
    let credential = authenticator.credentials[0].id.clone();
    let (passkey, used) = stored_passkey(&hub, &credential).await;
    assert_eq!(passkey["cred"]["counter"], 0, "{passkey}");
    assert_eq!(passkey["cred"]["backup_state"], false, "{passkey}");
    assert_eq!(used, None);

    for expected in [1, 2] {
        let answer = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
        assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
        let (passkey, used) = stored_passkey(&hub, &credential).await;
        assert_eq!(passkey["cred"]["counter"], expected, "{passkey}");
        assert!(used.is_some());
    }

    // A counter that goes backwards suggests a cloned key: refused, and nothing changes.
    authenticator.credentials[0].counter = 0;
    let answer = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");
    assert_eq!(
        stored_passkey(&hub, &credential).await.0["cred"]["counter"],
        2
    );

    // The backup state follows the authenticator.
    authenticator.credentials[0].counter = 2;
    authenticator.backed_up = true;
    let answer = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    let (passkey, _) = stored_passkey(&hub, &credential).await;
    assert_eq!(passkey["cred"]["counter"], 3);
    assert_eq!(passkey["cred"]["backup_state"], true, "{passkey}");

    // A synced passkey (counter always 0, as iCloud Keychain's) keeps signing in.
    let mut synced = Authenticator::new(ORIGIN);
    synced.counts = false;
    sign_up(&hub, &mut synced).await;
    for _ in 0..2 {
        let answer = sign_in(&hub, &mut synced, device("Mac", "macos")).await;
        assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    }
}

#[sqlx::test(migrations = false)]
async fn device_id_reused_on_second_sign_in(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    let signed_up = sign_up(&hub, &mut authenticator).await;
    let device_id = signed_up["deviceId"].as_str().unwrap();

    let mut reuse = device("Brian's MacBook Pro", "macos");
    reuse["deviceId"] = json!(device_id);
    let answer = sign_in(&hub, &mut authenticator, reuse).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    assert_eq!(answer.body["deviceId"], device_id);
    // The device's earlier token is replaced, and it is renamed.
    let old = hub.get("/v1/me", signed_up["token"].as_str()).await;
    assert_eq!(old.status, StatusCode::UNAUTHORIZED);
    let me = hub.get("/v1/me", answer.body["token"].as_str()).await;
    assert_eq!(me.body["deviceName"], "Brian's MacBook Pro");

    // Without a device id, or with one for another platform, the sign-in makes a new device.
    let fresh = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_ne!(fresh.body["deviceId"], device_id);
    let mut wrong_platform = device("iPhone", "ios");
    wrong_platform["deviceId"] = json!(device_id);
    let phone = sign_in(&hub, &mut authenticator, wrong_platform).await;
    assert_eq!(phone.status, StatusCode::OK, "{}", phone.body);
    assert_ne!(phone.body["deviceId"], device_id);
}

/// Signs in once with `authenticator` after `tamper` changed it, expecting `credential_rejected`,
/// then checks an honest sign-in still works (so the rejection was the tampering's).
async fn assert_rejected_then_recovers(
    hub: &Hub,
    authenticator: &mut Authenticator,
    why: &str,
    tamper: impl FnOnce(&mut Authenticator),
    restore: impl FnOnce(&mut Authenticator),
) {
    tamper(authenticator);
    let answer = sign_in(hub, authenticator, device("Mac", "macos")).await;
    assert_eq!(
        answer.status,
        StatusCode::UNAUTHORIZED,
        "{why}: {}",
        answer.body
    );
    assert_eq!(answer.code(), "credential_rejected", "{why}");
    restore(authenticator);
}

#[sqlx::test(migrations = false)]
async fn assertion_crypto_checks_are_enforced(pool: PgPool) {
    // Every case below is a well-formed assertion for a registered passkey, the right origin,
    // and a live ceremony, with one thing wrong; only the check for that thing can refuse it.
    let hub = hub(&pool, Signup::Open).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    sign_up(&hub, &mut authenticator).await;

    // Signed by a key the hub never registered.
    let mut impostor = Authenticator::new(ORIGIN);
    {
        let begun = begin(&hub).await;
        impostor.register(&begun["registration"]);
    }
    impostor.credentials[0].id = authenticator.credentials[0].id.clone();
    impostor.credentials[0].user_handle = authenticator.credentials[0].user_handle.clone();
    impostor.credentials[0].counter = 50;
    impostor.replace_key(0);
    let answer = sign_in(&hub, &mut impostor, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");

    // UV unset.
    assert_rejected_then_recovers(
        &hub,
        &mut authenticator,
        "without user verification",
        |a| a.user_verified = false,
        |a| a.user_verified = true,
    )
    .await;

    // The rp id hash of another domain, correctly signed.
    assert_rejected_then_recovers(
        &hub,
        &mut authenticator,
        "another relying party's hash",
        |a| a.rp_id_hash_for = Some("evil.example".into()),
        |a| a.rp_id_hash_for = None,
    )
    .await;

    // One authenticator-data byte changed after signing: the counter's third byte, so the
    // counter only goes up and nothing but the signature check can catch it.
    let begun = begin(&hub).await;
    let mut assertion = authenticator.assert(&begun["authentication"]);
    let mut data =
        common::authenticator::decode(assertion["response"]["authenticatorData"].as_str().unwrap());
    data[35] ^= 0x01;
    assertion["response"]["authenticatorData"] = json!(URL_SAFE_NO_PAD.encode(&data));
    let answer = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "assertion",
                assertion,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");

    // None of those moved the stored counter, and the honest key still signs in.
    let counter = stored_passkey(&hub, &authenticator.credentials[0].id)
        .await
        .0["cred"]["counter"]
        .clone();
    assert_eq!(counter, 0, "only refused assertions so far");
    let answer = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
}

#[sqlx::test(migrations = false)]
async fn registration_without_user_verification_rejected(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    let begun = begin(&hub).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    authenticator.user_verified = false;
    let attestation = authenticator.register(&begun["registration"]);
    let answer = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");
    let identities: i64 = sqlx::query_scalar("SELECT count(*) FROM user_identities")
        .fetch_one(&hub.state.db.pool)
        .await
        .unwrap();
    assert_eq!(identities, 0);
}

fn assert_rate_limited(answer: &Answer) {
    assert_eq!(
        answer.status,
        StatusCode::TOO_MANY_REQUESTS,
        "{}",
        answer.body
    );
    assert_eq!(answer.code(), "rate_limited");
    let retry = answer.body["error"]["details"]["retryAfterMs"]
        .as_u64()
        .expect("retryAfterMs");
    assert!(retry > 0 && retry <= 60_000, "{retry}");
    let header: u64 = answer.headers["retry-after"]
        .to_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!((1..=60).contains(&header), "{header}");
}

#[sqlx::test(migrations = false)]
async fn begin_rate_limited_after_20(pool: PgPool) {
    let hub = hub(&pool, Signup::Open).await;
    for n in 0..20 {
        let answer = hub.post(BEGIN, None).await;
        assert_eq!(answer.status, StatusCode::OK, "begin {n}: {}", answer.body);
    }
    assert_rate_limited(&hub.post(BEGIN, None).await);
    // The config route is not limited.
    assert_eq!(
        hub.get("/v1/auth/config", None).await.status,
        StatusCode::OK
    );

    // Finish has its own, smaller limit.
    let body = json!({"ceremonyId": Uuid::new_v4().to_string(), "assertion": {},
                      "device": device("Mac", "macos")});
    for n in 0..10 {
        let answer = hub.post(FINISH, Some(&body)).await;
        assert_ne!(answer.status, StatusCode::TOO_MANY_REQUESTS, "finish {n}");
    }
    assert_rate_limited(&hub.post(FINISH, Some(&body)).await);
}

#[sqlx::test(migrations = false)]
async fn forwarded_for_used_only_when_trusted(pool: PgPool) {
    async fn begin_from(hub: &Hub, forwarded: &str) -> Answer {
        hub.send("POST", BEGIN, None, &[("x-forwarded-for", forwarded)])
            .await
    }

    // Untrusted: the header is ignored and every request is the TCP peer's.
    let untrusted = hub(&pool, Signup::Closed).await;
    for _ in 0..20 {
        assert_eq!(
            begin_from(&untrusted, "203.0.113.1").await.status,
            StatusCode::OK
        );
    }
    assert_rate_limited(&begin_from(&untrusted, "203.0.113.2").await);

    // Trusted: the right-most entry is the client, whatever a client put before it.
    let trusted = another_hub(
        &untrusted,
        Config {
            trust_forwarded_for: true,
            ..config(Signup::Closed)
        },
    )
    .await;
    for _ in 0..20 {
        assert_eq!(
            begin_from(&trusted, "198.51.100.7, 203.0.113.1")
                .await
                .status,
            StatusCode::OK
        );
    }
    assert_rate_limited(&begin_from(&trusted, "203.0.113.1").await);
    assert_rate_limited(&begin_from(&trusted, "203.0.113.9, 203.0.113.1").await);
    assert_eq!(
        begin_from(&trusted, "203.0.113.1, 203.0.113.2")
            .await
            .status,
        StatusCode::OK
    );
}

/// Everything a subscriber writes, kept for the assertion.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> MakeWriter<'a> for Captured {
    type Writer = Captured;

    fn make_writer(&'a self) -> Captured {
        self.clone()
    }
}

#[sqlx::test(migrations = false)]
async fn no_secret_in_logs(pool: PgPool) {
    // The hub's own subscriber, with the most verbose filter an operator could write (including
    // module-qualified directives for webauthn-rs, which outrank a crate-level `off`), writing
    // to a buffer, as the process-wide subscriber: a thread-local one is not enough, because
    // tracing caches a callsite's interest from whichever thread reaches it first, and the other
    // tests run on other threads. Their lines land in the buffer too, which only widens the check.
    let filter = Settings::from_pairs([(
        "B4HUB_LOG",
        "trace,webauthn_rs_core::core=trace,webauthn_rs=trace,webauthn_attestation_ca=trace",
    )])
    .log_filter()
    .unwrap();
    let captured = Captured::default();
    let subscriber = b4hub::logging::subscriber(filter, captured.clone());
    tracing::subscriber::set_global_default(subscriber)
        .expect("no other test in this binary sets a subscriber");

    let hub = hub(&pool, Signup::Open).await;
    let mut secrets: Vec<String> = Vec::new();

    // Sign up, sign in, a rejected sign-in, and a replay.
    let begun = begin(&hub).await;
    let mut authenticator = Authenticator::new(ORIGIN);
    let attestation = authenticator.register(&begun["registration"]);
    secrets.push(
        attestation["response"]["clientDataJSON"]
            .as_str()
            .unwrap()
            .into(),
    );
    secrets.push(
        attestation["response"]["attestationObject"]
            .as_str()
            .unwrap()
            .into(),
    );
    let signed_up = hub
        .post(
            FINISH,
            Some(&finish_body(
                &begun["ceremonyId"],
                "attestation",
                attestation,
                device("Mac", "macos"),
            )),
        )
        .await;
    assert_eq!(signed_up.status, StatusCode::OK, "{}", signed_up.body);
    secrets.push(signed_up.body["token"].as_str().unwrap().into());
    let credential = &authenticator.credentials[0];
    secrets.push(URL_SAFE_NO_PAD.encode(&credential.id));
    secrets.push(format!("{:?}", credential.id));

    let begun = begin(&hub).await;
    let assertion = authenticator.assert(&begun["authentication"]);
    secrets.push(
        assertion["response"]["clientDataJSON"]
            .as_str()
            .unwrap()
            .into(),
    );
    secrets.push(assertion["response"]["signature"].as_str().unwrap().into());
    secrets.push(
        begun["authentication"]["publicKey"]["challenge"]
            .as_str()
            .unwrap()
            .into(),
    );
    let body = finish_body(
        &begun["ceremonyId"],
        "assertion",
        assertion,
        device("Mac", "macos"),
    );
    let signed_in = hub.post(FINISH, Some(&body)).await;
    assert_eq!(signed_in.status, StatusCode::OK, "{}", signed_in.body);
    secrets.push(signed_in.body["token"].as_str().unwrap().into());
    assert_eq!(
        hub.post(FINISH, Some(&body)).await.code(),
        "ceremony_expired"
    );

    authenticator.origin = "https://evil.example".into();
    let rejected = sign_in(&hub, &mut authenticator, device("Mac", "macos")).await;
    assert_eq!(rejected.code(), "credential_rejected");

    let text = captured.text();
    // The capture works: the hub's own sign-in lines are there.
    assert!(text.contains("signed in with a passkey"), "{text}");
    assert!(text.contains("signed up with a passkey"), "{text}");
    assert!(text.contains("passkey verification failed"), "{text}");
    for secret in &secrets {
        assert!(
            !text.contains(secret.as_str()),
            "{secret} is in the log:\n{text}"
        );
    }
    // Nothing from webauthn-rs's own targets, and the client data's own fields never appear.
    assert!(!text.contains("webauthn_rs"), "{text}");
    assert!(!text.contains("webauthn.get"), "{text}");
    assert!(!text.contains("webauthn.create"), "{text}");
}
