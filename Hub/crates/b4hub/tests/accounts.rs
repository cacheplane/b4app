//! The signed-in account's own routes: the profile (`PUT /v1/me/profile`), `GET /v1/me`'s account
//! fields, adding a passkey (`/v1/me/passkeys/*`), unlinking an identity, ending a session
//! (`DELETE /v1/sessions/self`), deleting the account (`DELETE /v1/me`), and the phone-only merge
//! on `POST /v1/enroll`. Run with `source <(../scripts/test-db.sh)` first; `#[sqlx::test]`
//! creates one database per test.

mod common;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::http::StatusCode;
use b4hub::apple::{seal_refresh_token, AppleRevoker, RevokeError};
use b4hub::config::Signup;
use b4hub::serve::AppState;
use b4hub_core::change::{Change, ChangeOp};
use b4hub_db::accounts::{self, Identity, Principal};
use b4hub_db::{changes, devices, orgs, Db};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use common::authenticator::{decode, Authenticator};
use common::{config, Answer, Hub, ORIGIN};
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;

const BEGIN: &str = "/v1/auth/passkey/begin";
const FINISH: &str = "/v1/auth/passkey/finish";
const ADD_BEGIN: &str = "/v1/me/passkeys/begin";
const ADD_FINISH: &str = "/v1/me/passkeys/finish";
const TEN_MINUTES: Duration = Duration::from_secs(600);

/// A revoker that records every refresh token it is handed, and fails each call when `fail`.
#[derive(Clone, Default)]
struct Recording {
    seen: Arc<Mutex<Vec<String>>>,
    fail: bool,
}

impl Recording {
    fn seen(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }
}

impl AppleRevoker for Recording {
    async fn revoke(&self, refresh_token: &str) -> Result<(), RevokeError> {
        self.seen.lock().unwrap().push(refresh_token.to_string());
        if self.fail {
            Err(RevokeError::Failed("the test revoker refuses"))
        } else {
            Ok(())
        }
    }
}

struct Setup {
    admin: Db,
    hub: Hub,
}

/// A hub with sign-up open and the no-op revoker.
async fn setup(pool: &PgPool) -> Setup {
    setup_with(pool, None).await
}

async fn setup_with(pool: &PgPool, revoker: Option<Recording>) -> Setup {
    let (admin, app) = common::migrated(pool).await;
    let mut state = AppState::new(app, config(Signup::Open)).unwrap();
    if let Some(revoker) = revoker {
        state = state.with_apple_revoker(revoker);
    }
    Setup {
        admin,
        hub: Hub::start_state(state).await,
    }
}

fn device(name: &str, platform: &str) -> Value {
    json!({"deviceName": name, "platform": platform})
}

fn bearer(token: &str) -> String {
    format!("Bearer {token}")
}

async fn call(hub: &Hub, method: &str, path: &str, body: Option<&Value>, token: &str) -> Answer {
    let auth = bearer(token);
    hub.send(method, path, body, &[("authorization", auth.as_str())])
        .await
}

/// Signs up with a new passkey on `authenticator`, from `device`; answers the session.
async fn sign_up(hub: &Hub, authenticator: &mut Authenticator, device: Value) -> Value {
    let begun = hub.post(BEGIN, None).await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    let attestation = authenticator.register(&begun.body["registration"]);
    let answer = hub
        .post(
            FINISH,
            Some(&json!({
                "ceremonyId": begun.body["ceremonyId"],
                "attestation": attestation,
                "device": device,
            })),
        )
        .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    answer.body
}

/// Signs in with `authenticator`'s credential `index`, sending `device`.
async fn sign_in(
    hub: &Hub,
    authenticator: &mut Authenticator,
    index: usize,
    device: Value,
) -> Answer {
    let begun = hub.post(BEGIN, None).await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    let assertion = authenticator.assert_with(index, &begun.body["authentication"]);
    hub.post(
        FINISH,
        Some(&json!({
            "ceremonyId": begun.body["ceremonyId"],
            "assertion": assertion,
            "device": device,
        })),
    )
    .await
}

fn token(session: &Value) -> &str {
    session["token"].as_str().unwrap()
}

async fn principal(hub: &Hub, token: &str) -> Principal {
    Principal::from(
        devices::authenticate(&hub.state.db, token)
            .await
            .unwrap()
            .expect("the token authenticates"),
    )
}

/// Seeds `blove` in the shared (non-personal) org `cacheplane` and enrolls a Mac for them.
async fn enrolled_blove(setup: &Setup) -> (orgs::SeedOutcome, Value) {
    let seeded = orgs::seed(
        &setup.admin,
        "cacheplane",
        "Cacheplane",
        "blove",
        "Brian Love",
        "b@example.test",
    )
    .await
    .unwrap();
    let code = mint_code(setup, &seeded).await;
    let answer = setup
        .hub
        .post(
            "/v1/enroll",
            Some(&json!({"code": code, "deviceName": "Brian's Mac", "platform": "macos"})),
        )
        .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    (seeded, answer.body)
}

async fn mint_code(setup: &Setup, seeded: &orgs::SeedOutcome) -> String {
    devices::create_enrollment_code(&setup.admin, seeded.org_id, seeded.user_id, TEN_MINUTES)
        .await
        .unwrap()
}

/// How many rows of `org_id` each table with an `org_id` column holds (as the superuser, which
/// row-level security does not filter).
async fn org_rows(pool: &PgPool, org_id: Uuid) -> Vec<(String, i64)> {
    let tables: Vec<String> = sqlx::query_scalar(
        "SELECT table_name::text FROM information_schema.columns \
         WHERE table_schema = 'public' AND column_name = 'org_id' ORDER BY 1",
    )
    .fetch_all(pool)
    .await
    .unwrap();
    let mut counts = Vec::new();
    for table in tables {
        let n: i64 = sqlx::query_scalar(&format!(
            "SELECT count(*) FROM \"{table}\" WHERE org_id = $1"
        ))
        .bind(org_id)
        .fetch_one(pool)
        .await
        .unwrap();
        counts.push((table, n));
    }
    counts
}

async fn exists(pool: &PgPool, table: &str, id: Uuid) -> bool {
    sqlx::query_scalar(&format!(
        "SELECT EXISTS (SELECT 1 FROM {table} WHERE id = $1)"
    ))
    .bind(id)
    .fetch_one(pool)
    .await
    .unwrap()
}

fn apple(sub: &str, sealed: Option<Vec<u8>>) -> Identity {
    Identity::Apple {
        sub: sub.into(),
        email: Some(format!("{sub}@privaterelay.appleid.com")),
        refresh_enc: sealed,
    }
}

// ---- Profile and GET /v1/me ----

#[sqlx::test(migrations = false)]
async fn profile_sets_onboarded_and_renames_org(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let mut authenticator = Authenticator::new(ORIGIN);
    let session = sign_up(hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    let t = token(&session);

    let before = hub.get("/v1/me", Some(t)).await;
    assert_eq!(before.status, StatusCode::OK, "{}", before.body);
    assert_eq!(before.body["onboarded"], false);
    assert_eq!(before.body["user"]["fullName"], Value::Null);
    assert_eq!(before.body["org"]["name"], "My Org");

    // Refused names change nothing.
    for bad in [String::new(), "   ".to_string(), "x".repeat(201)] {
        let answer = call(
            hub,
            "PUT",
            "/v1/me/profile",
            Some(&json!({"fullName": bad})),
            t,
        )
        .await;
        assert_eq!(answer.status, StatusCode::BAD_REQUEST, "{}", answer.body);
        assert_eq!(answer.code(), "invalid_request");
    }
    let unknown_field = call(
        hub,
        "PUT",
        "/v1/me/profile",
        Some(&json!({"fullName": "Brian Love", "org": "x"})),
        t,
    )
    .await;
    assert_eq!(unknown_field.code(), "invalid_request");
    assert_eq!(hub.get("/v1/me", Some(t)).await.body["onboarded"], false);

    let unauthenticated = hub
        .send(
            "PUT",
            "/v1/me/profile",
            Some(&json!({"fullName": "Brian Love"})),
            &[],
        )
        .await;
    assert_eq!(unauthenticated.status, StatusCode::UNAUTHORIZED);

    let answer = call(
        hub,
        "PUT",
        "/v1/me/profile",
        Some(&json!({"fullName": "  Brian Love  "})),
        t,
    )
    .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    assert_eq!(answer.body["onboarded"], true);
    assert_eq!(answer.body["org"]["name"], "Brian's Org");
    assert_eq!(answer.body["user"]["fullName"], "Brian Love");
    assert_eq!(answer.body["user"]["displayName"], "Brian Love");

    let me = hub.get("/v1/me", Some(t)).await;
    assert_eq!(me.body["onboarded"], true);
    assert_eq!(me.body["org"]["name"], "Brian's Org");
    assert_eq!(me.body["user"]["fullName"], "Brian Love");

    // A sign-in now says the user has onboarded.
    let signed_in = sign_in(hub, &mut authenticator, 0, device("iPhone", "ios")).await;
    assert_eq!(signed_in.body["needsOnboarding"], false);

    // 200 characters is the most accepted; a later rename renames the personal org again.
    let longest = format!("Brianna {}", "x".repeat(192));
    let answer = call(
        hub,
        "PUT",
        "/v1/me/profile",
        Some(&json!({"fullName": longest})),
        t,
    )
    .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    assert_eq!(answer.body["org"]["name"], "Brianna's Org");

    // A user in a shared org keeps the org's name.
    let (_, blove) = enrolled_blove(&setup).await;
    let answer = call(
        hub,
        "PUT",
        "/v1/me/profile",
        Some(&json!({"fullName": "Brian F. Love"})),
        token(&blove),
    )
    .await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    assert_eq!(answer.body["org"]["name"], "Cacheplane");
    assert_eq!(answer.body["user"]["fullName"], "Brian F. Love");
    assert_eq!(answer.body["onboarded"], true);
}

#[sqlx::test(migrations = false)]
async fn me_lists_identities(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let mut authenticator = Authenticator::new(ORIGIN);
    let session = sign_up(hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    let t = token(&session);
    let who = principal(hub, t).await;
    let sealed = seal_refresh_token(&hub.state.config.secret_key, "rt-secret").unwrap();
    accounts::add_identity(&hub.state.db, who, apple("001.me", Some(sealed)))
        .await
        .unwrap();

    let me = hub.get("/v1/me", Some(t)).await;
    assert_eq!(me.status, StatusCode::OK, "{}", me.body);
    // The fields older clients decode are all still there.
    for field in ["deviceId", "deviceName", "platform", "createdAt"] {
        assert!(me.body[field].is_string(), "{field}: {}", me.body);
    }
    assert!(me.body["org"]["slug"].is_string());
    assert!(me.body["org"]["name"].is_string());
    assert!(me.body["user"]["username"].is_string());
    assert!(me.body["user"]["displayName"].is_string());

    let identities = me.body["identities"].as_array().expect("identities");
    assert_eq!(identities.len(), 2, "{}", me.body);
    for identity in identities {
        let mut keys: Vec<&str> = identity
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(keys, ["createdAt", "id", "kind", "lastUsedAt", "name"]);
        assert!(Uuid::parse_str(identity["id"].as_str().unwrap()).is_ok());
        assert!(identity["createdAt"]
            .as_str()
            .is_some_and(|s| s.ends_with('Z')));
    }
    assert_eq!(identities[0]["kind"], "passkey");
    assert_eq!(identities[0]["name"], "Agent Workspace account");
    assert_eq!(identities[1]["kind"], "apple");
    assert_eq!(identities[1]["name"], "001.me@privaterelay.appleid.com");
    assert_eq!(identities[1]["lastUsedAt"], Value::Null);

    // Nothing secret or credential-shaped is in the answer.
    let text = me.body.to_string();
    let credential_id = URL_SAFE_NO_PAD.encode(&authenticator.credentials[0].id);
    assert!(!text.contains(&credential_id), "{text}");
    assert!(!text.contains("rt-secret"), "{text}");
    assert!(
        !text.contains("001.me\""),
        "the Apple sub is not listed: {text}"
    );

    // A sign-in records when the passkey was last used.
    sign_in(hub, &mut authenticator, 0, device("iPhone", "ios")).await;
    let me = hub.get("/v1/me", Some(t)).await;
    assert!(me.body["identities"][0]["lastUsedAt"].is_string());
}

// ---- Adding a passkey ----

#[sqlx::test(migrations = false)]
async fn add_second_passkey_then_sign_in_with_either(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let mut first = Authenticator::new(ORIGIN);
    let session = sign_up(hub, &mut first, device("Brian's Mac", "macos")).await;
    let t = token(&session);

    assert_eq!(
        hub.post(ADD_BEGIN, None).await.status,
        StatusCode::UNAUTHORIZED
    );

    let begun = call(hub, "POST", ADD_BEGIN, None, t).await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    let options = &begun.body["registration"]["publicKey"];
    assert_eq!(options["user"]["name"], "Agent Workspace account");
    assert_eq!(options["user"]["displayName"], "Agent Workspace account");
    assert_eq!(options["authenticatorSelection"]["residentKey"], "required");
    assert_eq!(
        options["authenticatorSelection"]["userVerification"],
        "required"
    );
    assert_eq!(options["attestation"], "none");
    // The user's existing passkey is excluded, so an authenticator holding it is not reused.
    let excluded: Vec<Vec<u8>> = options["excludeCredentials"]
        .as_array()
        .expect("excludeCredentials")
        .iter()
        .map(|c| decode(c["id"].as_str().unwrap()))
        .collect();
    assert_eq!(excluded, vec![first.credentials[0].id.clone()]);

    let mut second = Authenticator::new(ORIGIN);
    let attestation = second.register(&begun.body["registration"]);
    let finish = json!({"ceremonyId": begun.body["ceremonyId"], "attestation": attestation});

    // The ceremony belongs to the user who began it: another signed-in user cannot finish it,
    // and a sign-in ceremony is not an add ceremony.
    let (_, blove) = enrolled_blove(&setup).await;
    let stolen = call(hub, "POST", ADD_FINISH, Some(&finish), token(&blove)).await;
    assert_eq!(stolen.status, StatusCode::BAD_REQUEST, "{}", stolen.body);
    assert_eq!(stolen.code(), "ceremony_expired");
    assert_eq!(
        hub.get("/v1/me", Some(token(&blove))).await.body["identities"],
        json!([])
    );

    let begun = call(hub, "POST", ADD_BEGIN, None, t).await;
    let attestation = second.register(&begun.body["registration"]);
    let sign_in_ceremony = hub.post(BEGIN, None).await.body["ceremonyId"].clone();
    let wrong_kind = call(
        hub,
        "POST",
        ADD_FINISH,
        Some(&json!({"ceremonyId": sign_in_ceremony, "attestation": attestation})),
        t,
    )
    .await;
    assert_eq!(wrong_kind.code(), "ceremony_expired");

    let added = call(
        hub,
        "POST",
        ADD_FINISH,
        Some(&json!({"ceremonyId": begun.body["ceremonyId"], "attestation": attestation})),
        t,
    )
    .await;
    assert_eq!(added.status, StatusCode::OK, "{}", added.body);
    assert_eq!(added.body["kind"], "passkey");
    assert!(added.body["id"].is_string());

    let me = hub.get("/v1/me", Some(t)).await;
    let identities = me.body["identities"].as_array().unwrap();
    assert_eq!(identities.len(), 2, "{}", me.body);
    assert_eq!(identities[1]["id"], added.body["id"]);

    // Either passkey signs in to the same account.
    let username = me.body["user"]["username"].clone();
    let with_first = sign_in(hub, &mut first, 0, device("iPhone", "ios")).await;
    assert_eq!(with_first.status, StatusCode::OK, "{}", with_first.body);
    assert_eq!(with_first.body["user"]["username"], username);
    let newest = second.credentials.len() - 1;
    let with_second = sign_in(hub, &mut second, newest, device("iPad", "ios")).await;
    assert_eq!(with_second.status, StatusCode::OK, "{}", with_second.body);
    assert_eq!(with_second.body["user"]["username"], username);

    // An enrolled user with no identity adds their first passkey the same way.
    let begun = call(hub, "POST", ADD_BEGIN, None, token(&blove)).await;
    assert_eq!(
        begun.body["registration"]["publicKey"]["excludeCredentials"]
            .as_array()
            .map_or(0, Vec::len),
        0
    );
    let mut third = Authenticator::new(ORIGIN);
    let attestation = third.register(&begun.body["registration"]);
    let added = call(
        hub,
        "POST",
        ADD_FINISH,
        Some(&json!({"ceremonyId": begun.body["ceremonyId"], "attestation": attestation})),
        token(&blove),
    )
    .await;
    assert_eq!(added.status, StatusCode::OK, "{}", added.body);
    let as_blove = sign_in(hub, &mut third, 0, device("Brian's iPhone", "ios")).await;
    assert_eq!(as_blove.status, StatusCode::OK, "{}", as_blove.body);
    assert_eq!(as_blove.body["user"]["username"], "blove");
    assert_eq!(as_blove.body["org"]["slug"], "cacheplane");
}

#[sqlx::test(migrations = false)]
async fn me_passkey_routes_are_rate_limited(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let (_, blove) = enrolled_blove(&setup).await;
    let t = token(&blove);
    for _ in 0..20 {
        let answer = call(hub, "POST", ADD_BEGIN, None, t).await;
        assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    }
    let over = call(hub, "POST", ADD_BEGIN, None, t).await;
    assert_eq!(over.status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(over.code(), "rate_limited");

    let body = json!({"ceremonyId": Uuid::new_v4(), "attestation": {}});
    for _ in 0..10 {
        let answer = call(hub, "POST", ADD_FINISH, Some(&body), t).await;
        assert_ne!(answer.status, StatusCode::TOO_MANY_REQUESTS);
    }
    let over = call(hub, "POST", ADD_FINISH, Some(&body), t).await;
    assert_eq!(over.code(), "rate_limited");
}

// ---- Unlinking ----

#[sqlx::test(migrations = false)]
async fn remove_last_identity_is_last_identity(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let mut authenticator = Authenticator::new(ORIGIN);
    let session = sign_up(hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    let t = token(&session);
    let passkey_id = hub.get("/v1/me", Some(t)).await.body["identities"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();

    let refused = call(
        hub,
        "DELETE",
        &format!("/v1/me/identities/{passkey_id}"),
        None,
        t,
    )
    .await;
    assert_eq!(refused.status, StatusCode::CONFLICT, "{}", refused.body);
    assert_eq!(refused.code(), "last_identity");
    assert_eq!(refused.body["error"]["kind"], "request_error");

    let who = principal(hub, t).await;
    accounts::add_identity(&hub.state.db, who, apple("001.second", None))
        .await
        .unwrap();

    // Another account's identity, an unknown id, and a malformed one are all not found.
    let mut other = Authenticator::new(ORIGIN);
    let stranger = sign_up(hub, &mut other, device("iPhone", "ios")).await;
    let stranger_id = hub.get("/v1/me", Some(token(&stranger))).await.body["identities"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();
    for id in [
        stranger_id.clone(),
        Uuid::new_v4().to_string(),
        "nope".into(),
    ] {
        let answer = call(hub, "DELETE", &format!("/v1/me/identities/{id}"), None, t).await;
        assert_eq!(
            answer.status,
            StatusCode::NOT_FOUND,
            "{id}: {}",
            answer.body
        );
        assert_eq!(answer.code(), "not_found");
    }
    assert_eq!(
        hub.get("/v1/me", Some(token(&stranger))).await.body["identities"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let removed = call(
        hub,
        "DELETE",
        &format!("/v1/me/identities/{passkey_id}"),
        None,
        t,
    )
    .await;
    assert_eq!(removed.status, StatusCode::NO_CONTENT, "{}", removed.body);
    let identities = hub.get("/v1/me", Some(t)).await.body["identities"].clone();
    assert_eq!(identities.as_array().unwrap().len(), 1);
    assert_eq!(identities[0]["kind"], "apple");
    // The removed passkey no longer signs in.
    let answer = sign_in(hub, &mut authenticator, 0, device("Mac", "macos")).await;
    assert_eq!(answer.code(), "credential_rejected");
}

// ---- Sessions ----

#[sqlx::test(migrations = false)]
async fn session_end_keeps_device(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let mut authenticator = Authenticator::new(ORIGIN);
    let mac = sign_up(hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    let phone = sign_in(hub, &mut authenticator, 0, device("iPhone", "ios")).await;
    assert_eq!(phone.status, StatusCode::OK, "{}", phone.body);
    let phone = phone.body;

    assert_eq!(
        hub.send("DELETE", "/v1/sessions/self", None, &[])
            .await
            .status,
        StatusCode::UNAUTHORIZED
    );
    let ended = call(hub, "DELETE", "/v1/sessions/self", None, token(&mac)).await;
    assert_eq!(ended.status, StatusCode::NO_CONTENT, "{}", ended.body);
    assert_eq!(ended.body, Value::Null);

    assert_eq!(
        hub.get("/v1/me", Some(token(&mac))).await.status,
        StatusCode::UNAUTHORIZED
    );
    // The phone's session is untouched, and the Mac is still a device of the account.
    let listed = hub.get("/v1/devices", Some(token(&phone))).await;
    assert_eq!(listed.status, StatusCode::OK, "{}", listed.body);
    let mac_row = listed.body["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["id"] == mac["deviceId"])
        .expect("the Mac is still listed")
        .clone();
    assert_eq!(mac_row["revokedAt"], Value::Null);

    // Signing back in with its device id reuses it.
    let back = sign_in(
        hub,
        &mut authenticator,
        0,
        json!({"deviceName": "Brian's Mac", "platform": "macos", "deviceId": mac["deviceId"]}),
    )
    .await;
    assert_eq!(back.status, StatusCode::OK, "{}", back.body);
    assert_eq!(back.body["deviceId"], mac["deviceId"]);
    assert_eq!(
        hub.get("/v1/me", Some(token(&back.body))).await.status,
        StatusCode::OK
    );

    // `DELETE /v1/devices/self` still revokes the device.
    let revoked = call(hub, "DELETE", "/v1/devices/self", None, token(&phone)).await;
    assert_eq!(revoked.status, StatusCode::NO_CONTENT);
    let listed = hub.get("/v1/devices", Some(token(&back.body))).await;
    let phone_row = listed.body["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["id"] == phone["deviceId"])
        .unwrap()
        .clone();
    assert!(phone_row["revokedAt"].is_string());
}

// ---- Deleting the account ----

fn project(seq: i64) -> Change {
    Change {
        device_seq: seq,
        wall: 1_761_900_000_000 + seq,
        table: "projects".into(),
        row_id: format!("proj-{seq}"),
        op: ChangeOp::Insert,
        column: None,
        value: Some(json!({"id": format!("proj-{seq}"), "name": "b4app", "manual": false})),
        hlc: None,
    }
}

#[sqlx::test(migrations = false)]
async fn delete_me_removes_org_rows_and_calls_revoker(pool: PgPool) {
    let revoker = Recording::default();
    let setup = setup_with(&pool, Some(revoker.clone())).await;
    let hub = &setup.hub;
    let key = hub.state.config.secret_key;

    let mut authenticator = Authenticator::new(ORIGIN);
    let doomed = sign_up(hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    let t = token(&doomed);
    let who = principal(hub, t).await;
    for (sub, refresh) in [
        ("001.a", Some("rt-one")),
        ("001.b", Some("rt-two")),
        ("001.c", None),
    ] {
        let sealed = refresh.map(|r| seal_refresh_token(&key, r).unwrap());
        accounts::add_identity(&hub.state.db, who, apple(sub, sealed))
            .await
            .unwrap();
    }
    let mac = devices::authenticate(&hub.state.db, t)
        .await
        .unwrap()
        .unwrap();
    changes::push(&hub.state.db, &mac, &[project(1), project(2)])
        .await
        .unwrap();
    let mut other = Authenticator::new(ORIGIN);
    let kept = sign_up(hub, &mut other, device("Mac", "macos")).await;
    let kept_who = principal(hub, token(&kept)).await;
    let kept_before = org_rows(&pool, kept_who.org_id).await;
    assert!(org_rows(&pool, who.org_id)
        .await
        .iter()
        .any(|(table, n)| table == "projects" && *n == 2));

    let deleted = call(hub, "DELETE", "/v1/me", None, t).await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT, "{}", deleted.body);

    // Each stored refresh token reached the revoker decrypted, once.
    let mut seen = revoker.seen();
    seen.sort();
    assert_eq!(seen, ["rt-one", "rt-two"]);

    for (table, n) in org_rows(&pool, who.org_id).await {
        assert_eq!(n, 0, "{table} still has rows of the deleted account");
    }
    assert!(!exists(&pool, "orgs", who.org_id).await);
    assert!(!exists(&pool, "users", who.user_id).await);
    assert_eq!(
        hub.get("/v1/me", Some(t)).await.status,
        StatusCode::UNAUTHORIZED
    );
    let gone = sign_in(hub, &mut authenticator, 0, device("Mac", "macos")).await;
    assert_eq!(gone.code(), "credential_rejected");
    assert_eq!(org_rows(&pool, kept_who.org_id).await, kept_before);
}

#[sqlx::test(migrations = false)]
async fn delete_me_with_a_failed_revoke_deletes_nothing(pool: PgPool) {
    let revoker = Recording {
        fail: true,
        ..Recording::default()
    };
    let setup = setup_with(&pool, Some(revoker.clone())).await;
    let hub = &setup.hub;
    let mut authenticator = Authenticator::new(ORIGIN);
    let session = sign_up(hub, &mut authenticator, device("Brian's Mac", "macos")).await;
    let t = token(&session);
    let who = principal(hub, t).await;
    let sealed = seal_refresh_token(&hub.state.config.secret_key, "rt-one").unwrap();
    accounts::add_identity(&hub.state.db, who, apple("001.a", Some(sealed)))
        .await
        .unwrap();
    let before = org_rows(&pool, who.org_id).await;

    let answer = call(hub, "DELETE", "/v1/me", None, t).await;
    assert_eq!(
        answer.status,
        StatusCode::INTERNAL_SERVER_ERROR,
        "{}",
        answer.body
    );
    assert_eq!(answer.code(), "internal_error");
    assert_eq!(revoker.seen(), ["rt-one"]);
    assert!(!answer.body.to_string().contains("rt-one"));
    assert_eq!(org_rows(&pool, who.org_id).await, before);
    assert_eq!(hub.get("/v1/me", Some(t)).await.status, StatusCode::OK);
}

#[sqlx::test(migrations = false)]
async fn delete_me_in_a_shared_org_is_shared_org(pool: PgPool) {
    let revoker = Recording::default();
    let setup = setup_with(&pool, Some(revoker.clone())).await;
    let hub = &setup.hub;
    let (seeded, blove) = enrolled_blove(&setup).await;
    let sealed = seal_refresh_token(&hub.state.config.secret_key, "rt-blove").unwrap();
    accounts::add_identity(
        &hub.state.db,
        Principal {
            org_id: seeded.org_id,
            user_id: seeded.user_id,
        },
        apple("001.blove", Some(sealed)),
    )
    .await
    .unwrap();

    let answer = call(hub, "DELETE", "/v1/me", None, token(&blove)).await;
    assert_eq!(answer.status, StatusCode::CONFLICT, "{}", answer.body);
    assert_eq!(answer.code(), "shared_org");
    // Refused before anything is revoked.
    assert!(revoker.seen().is_empty());
    assert_eq!(
        hub.get("/v1/me", Some(token(&blove))).await.status,
        StatusCode::OK
    );
}

// ---- Merge on pairing ----

#[sqlx::test(migrations = false)]
async fn enroll_with_phone_only_token_merges(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let (seeded, _mac) = enrolled_blove(&setup).await;

    // The phone signed up on its own, with no Mac.
    let mut phone_keys = Authenticator::new(ORIGIN);
    let phone = sign_up(hub, &mut phone_keys, device("Brian's iPhone", "ios")).await;
    let phone_token = token(&phone);
    let phone_who = principal(hub, phone_token).await;

    // A failed redemption (a spent code of the same account, or an unknown one) merges nothing.
    let spent = mint_code(&setup, &seeded).await;
    let used = hub
        .post(
            "/v1/enroll",
            Some(&json!({"code": spent, "deviceName": "iPad", "platform": "ios"})),
        )
        .await;
    assert_eq!(used.status, StatusCode::OK, "{}", used.body);
    for code in [spent.as_str(), "BCDFGHJK"] {
        let bad = call(
            hub,
            "POST",
            "/v1/enroll",
            Some(&json!({"code": code, "deviceName": "Brian's iPhone", "platform": "ios"})),
            phone_token,
        )
        .await;
        assert_eq!(bad.code(), "invalid_code", "{code}");
        assert_eq!(
            hub.get("/v1/me", Some(phone_token)).await.status,
            StatusCode::OK
        );
        assert!(exists(&pool, "users", phone_who.user_id).await);
    }

    let code = mint_code(&setup, &seeded).await;
    let enrolled = call(
        hub,
        "POST",
        "/v1/enroll",
        Some(&json!({"code": code, "deviceName": "Brian's iPhone", "platform": "ios"})),
        phone_token,
    )
    .await;
    assert_eq!(enrolled.status, StatusCode::OK, "{}", enrolled.body);
    assert_eq!(enrolled.body["org"]["slug"], "cacheplane");
    assert_eq!(enrolled.body["user"]["username"], "blove");

    // The new token is the code's account's; the phone's old device and user are gone.
    let me = hub.get("/v1/me", Some(token(&enrolled.body))).await;
    assert_eq!(me.status, StatusCode::OK, "{}", me.body);
    assert_eq!(me.body["platform"], "ios");
    let identities = me.body["identities"].as_array().unwrap();
    assert_eq!(identities.len(), 1, "{}", me.body);
    assert_eq!(identities[0]["kind"], "passkey");
    assert_eq!(
        hub.get("/v1/me", Some(phone_token)).await.status,
        StatusCode::UNAUTHORIZED
    );
    assert!(!exists(&pool, "users", phone_who.user_id).await);
    assert!(!exists(&pool, "orgs", phone_who.org_id).await);
    for (table, n) in org_rows(&pool, phone_who.org_id).await {
        assert_eq!(n, 0, "{table} still has rows of the merged-away account");
    }

    // The phone's passkey now signs in to the code's account.
    let signed_in = sign_in(hub, &mut phone_keys, 0, device("Brian's iPhone", "ios")).await;
    assert_eq!(signed_in.status, StatusCode::OK, "{}", signed_in.body);
    assert_eq!(signed_in.body["user"]["username"], "blove");
    assert_eq!(signed_in.body["org"]["slug"], "cacheplane");
}

#[sqlx::test(migrations = false)]
async fn enroll_with_token_of_account_with_mac_is_merge_refused(pool: PgPool) {
    let setup = setup(&pool).await;
    let hub = &setup.hub;
    let (seeded, blove_mac) = enrolled_blove(&setup).await;

    // An account that signed in on a Mac once.
    let mut keys = Authenticator::new(ORIGIN);
    let phone = sign_up(hub, &mut keys, device("iPhone", "ios")).await;
    let on_mac = sign_in(hub, &mut keys, 0, device("Other Mac", "macos")).await;
    assert_eq!(on_mac.status, StatusCode::OK);

    let code = mint_code(&setup, &seeded).await;
    let body = json!({"code": code, "deviceName": "iPhone", "platform": "ios"});
    let refused = call(hub, "POST", "/v1/enroll", Some(&body), token(&phone)).await;
    assert_eq!(refused.status, StatusCode::CONFLICT, "{}", refused.body);
    assert_eq!(refused.code(), "merge_refused");
    assert_eq!(refused.body["error"]["kind"], "request_error");
    // Nothing changed: the phone's session works and the code is still redeemable.
    assert_eq!(
        hub.get("/v1/me", Some(token(&phone))).await.status,
        StatusCode::OK
    );

    // The code's own account, and an account in a shared org, are refused too.
    let own = call(hub, "POST", "/v1/enroll", Some(&body), token(&blove_mac)).await;
    assert_eq!(own.code(), "merge_refused");

    // An invalid bearer is unauthorized, whatever the code.
    for auth in ["Bearer not-a-token", "Basic abc", "Bearer"] {
        let answer = hub
            .send(
                "POST",
                "/v1/enroll",
                Some(&body),
                &[("authorization", auth)],
            )
            .await;
        assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{auth}");
        assert_eq!(answer.code(), "unauthorized");
    }

    let plain = hub.post("/v1/enroll", Some(&body)).await;
    assert_eq!(plain.status, StatusCode::OK, "{}", plain.body);
}

#[sqlx::test(migrations = false)]
async fn enroll_without_token_unchanged(pool: PgPool) {
    let setup = setup(&pool).await;
    let (seeded, mac) = enrolled_blove(&setup).await;
    let mut keys: Vec<&str> = mac
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(keys, ["deviceId", "org", "token", "user"]);
    assert_eq!(
        mac["org"],
        json!({"slug": "cacheplane", "name": "Cacheplane"})
    );
    assert_eq!(
        mac["user"],
        json!({"username": "blove", "displayName": "Brian Love"})
    );

    // A second device of the same user, with no token, simply enrolls.
    let code = mint_code(&setup, &seeded).await;
    let phone = setup
        .hub
        .post(
            "/v1/enroll",
            Some(&json!({"code": code, "deviceName": "iPhone", "platform": "ios"})),
        )
        .await;
    assert_eq!(phone.status, StatusCode::OK, "{}", phone.body);
    assert_eq!(
        setup.hub.get("/v1/me", Some(token(&mac))).await.status,
        StatusCode::OK
    );
}

// ---- Logging ----

/// Everything a subscriber writes, kept for the assertion.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl std::io::Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Captured {
    type Writer = Captured;

    fn make_writer(&'a self) -> Captured {
        self.clone()
    }
}

#[sqlx::test(migrations = false)]
async fn no_secret_in_logs(pool: PgPool) {
    // The hub's own subscriber at the most verbose filter, as the process-wide subscriber (see
    // the same test in `auth.rs` for why a thread-local one is not enough).
    let filter = b4hub::cli::Settings::from_pairs([("B4HUB_LOG", "trace")])
        .log_filter()
        .unwrap();
    let captured = Captured::default();
    let subscriber = b4hub::logging::subscriber(filter, captured.clone());
    tracing::subscriber::set_global_default(subscriber)
        .expect("no other test in this binary sets a subscriber");

    let setup = setup_with(&pool, Some(Recording::default())).await;
    let hub = &setup.hub;
    let mut secrets: Vec<String> = Vec::new();

    // Add a passkey to an enrolled user.
    let (seeded, blove) = enrolled_blove(&setup).await;
    secrets.push(token(&blove).into());
    let begun = call(hub, "POST", ADD_BEGIN, None, token(&blove)).await;
    secrets.push(
        begun.body["registration"]["publicKey"]["challenge"]
            .as_str()
            .unwrap()
            .into(),
    );
    let mut keys = Authenticator::new(ORIGIN);
    let attestation = keys.register(&begun.body["registration"]);
    for field in ["clientDataJSON", "attestationObject"] {
        secrets.push(attestation["response"][field].as_str().unwrap().into());
    }
    secrets.push(URL_SAFE_NO_PAD.encode(&keys.credentials[0].id));
    let added = call(
        hub,
        "POST",
        ADD_FINISH,
        Some(&json!({"ceremonyId": begun.body["ceremonyId"], "attestation": attestation})),
        token(&blove),
    )
    .await;
    assert_eq!(added.status, StatusCode::OK, "{}", added.body);

    // A phone-only account merges while pairing.
    let mut phone_keys = Authenticator::new(ORIGIN);
    let phone = sign_up(hub, &mut phone_keys, device("iPhone", "ios")).await;
    secrets.push(token(&phone).into());
    let code = mint_code(&setup, &seeded).await;
    secrets.push(code.clone());
    let merged = call(
        hub,
        "POST",
        "/v1/enroll",
        Some(&json!({"code": code, "deviceName": "iPhone", "platform": "ios"})),
        token(&phone),
    )
    .await;
    assert_eq!(merged.status, StatusCode::OK, "{}", merged.body);
    secrets.push(token(&merged.body).into());

    // Log out, then delete an account holding an Apple refresh token.
    assert_eq!(
        call(
            hub,
            "DELETE",
            "/v1/sessions/self",
            None,
            token(&merged.body)
        )
        .await
        .status,
        StatusCode::NO_CONTENT
    );
    let mut doomed_keys = Authenticator::new(ORIGIN);
    let doomed = sign_up(hub, &mut doomed_keys, device("Mac", "macos")).await;
    secrets.push(token(&doomed).into());
    let sealed = seal_refresh_token(&hub.state.config.secret_key, "rt-plaintext-secret").unwrap();
    secrets.push(format!("{sealed:?}"));
    accounts::add_identity(
        &hub.state.db,
        principal(hub, token(&doomed)).await,
        apple("001.doomed", Some(sealed)),
    )
    .await
    .unwrap();
    secrets.push("rt-plaintext-secret".into());
    assert_eq!(
        call(hub, "DELETE", "/v1/me", None, token(&doomed))
            .await
            .status,
        StatusCode::NO_CONTENT
    );

    let text = captured.text();
    for line in [
        "added a passkey",
        "merged a phone-only account while pairing",
        "ended a session",
        "deleted an account",
    ] {
        assert!(text.contains(line), "{line} is not logged:\n{text}");
    }
    for secret in &secrets {
        assert!(
            !text.contains(secret.as_str()),
            "{secret} is in the log:\n{text}"
        );
    }
    assert!(!text.contains("webauthn.create"), "{text}");
}
