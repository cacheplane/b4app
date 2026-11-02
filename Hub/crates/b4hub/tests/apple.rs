//! Sign in with Apple against a fake Apple on a loopback port: the native flow
//! (`/v1/auth/apple/begin`, `/v1/auth/apple/native`), the web flow (`/v1/auth/apple/start`,
//! Apple's form post to `/v1/auth/apple/callback`, `/v1/auth/handoff`), linking
//! (`/v1/me/apple`, `/v1/me/apple/native`), and revoking at Apple when an account is deleted.
//! Run with `source <(../scripts/test-db.sh)` first; `#[sqlx::test]` creates one database per
//! test.
//!
//! The fake serves `/auth/keys` (an EC P-256 key generated here, and a fixed RSA test key, since
//! the real Apple signs with RS256), `/auth/token` (checks the client secret, answers a signed
//! `id_token` and a fresh refresh token for a code it was told about), and `/auth/revoke`
//! (checks the client secret and records the call).

mod common;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use b4hub::apple::{open_refresh_token, sha256_hex};
use b4hub::cli::Settings;
use b4hub::config::{AppleConfig, Config, Signup};
use b4hub_db::Db;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use common::authenticator::Authenticator;
use common::{Answer, Hub, ORIGIN};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use serde_json::{json, Value};
use sqlx::types::Uuid;
use sqlx::PgPool;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use url::Url;

const TEAM_ID: &str = "TEAM123456";
const KEY_ID: &str = "KEYID12345";
const BUNDLE_ID: &str = "com.cacheplane.b4app.ios";
const SERVICES_ID: &str = "com.cacheplane.b4app.signin";
const PUBLIC_URL: &str = "https://hub.local.test";
const CALLBACK_URL: &str = "https://hub.local.test/v1/auth/apple/callback";

const BEGIN: &str = "/v1/auth/apple/begin";
const NATIVE: &str = "/v1/auth/apple/native";
const CALLBACK: &str = "/v1/auth/apple/callback";
const HANDOFF: &str = "/v1/auth/handoff";
const LINK: &str = "/v1/me/apple";
const LINK_NATIVE: &str = "/v1/me/apple/native";

/// The EC key's id in the fake's key set, and the RSA key's.
const EC_KID: &str = "ec-1";
const RSA_KID: &str = "rsa-1";

/// A 2048-bit RSA key generated for these tests only, and its modulus in base64url.
const RSA_PEM: &str = "-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCx3UPGQfY+8tMV
s+/GNwaNpBOakOAoC0EKEbmYUWnkbU6JatmviLoA9WW1Pvd5wDJObJPN8H92qNs6
SXNqLa6kXccnj0cH1ozDrEwMcOEc/zDZWhamxvUshWAaR41vvgVyIchn7C5iB1jw
A5/H7sk9EeLoRYbk1vQLiIA19AHbxpRdaelMPEGyVST/89kGqAN4pcMtfkq6UF0k
tMz6pR16bTKib+2l4WDzwtoR8T9LwLkGwHB0dsffsbS5Utn5kprHwh+wDLdZPemx
ixL0lCSVoUs3T5v8Au7uMzxh+E/s68EpXIlkFqixmxUd8IM6TcONfNOrkL2RKgGV
ClEIm+sXAgMBAAECggEAA9EyV6ppvP8cHZ6fejsLFnYbf5k1XlajfjJUL9srcR4R
beyPoG9IQqYBmUqxJ/lCeyFkaKqNKcBE+DLEWdaCJX/nuscd6KKnoblsZmXzxtoJ
M9j1nH2vnFV+cwHvHKNQ3ZqxAN32Pt9WfswtHS7YPcnI+2AmnXmpgifbTI0gjxVi
Qzb3Y02iUvVrv0czNTpnUc32YpFn+b93aJA+JqWmMQn9Cqh+a0GXyvSDikF6JkLt
Ek2rxQrTiOqE/gWRxXIQonYWKHrG4x1YtxHhip3VGTHDWeTJAPcopzeG/QwcEvph
GADuWJJQW2tTAqmZRkdn9SjnGzZC3/gHe30rtSA3WQKBgQDjfFqmY/c+YTQgfX5d
jiONlAiJlPdE+YEw2WdpF6mHqvKW3SScRUYfgVHP9jcYy/DUj67sv9dyL/vKNRsm
eFarSHxBq8sVqxFAU1CzJt4xptuG7EordWcj2Y0li7ZXQjgUqzGe2+smRxHpKaIt
KZ7qR90yRw9k8MGaj6baBOGZXwKBgQDIKKPDuQiP0DhHFv2J9Cyhib0iM6PFv3Rp
WpBU5AUrknjdW/5nWvZAtdI8HNDrTUo8JzZEgjAFMWJjo1SWeJ5MaNhdgQmYmXk6
ibYfR90iKPNaPhLWCv4mM0jz4IYFkt3jNXMFMjss60bABghF42uNXGaFbtAkQZjT
loPrFZQxSQKBgGpdc7lHFozJQGlMpDA0TLVfGRrTV0ad7uUbUfnWgYMY0DLwFbUn
wuDqQ4mcUyi5+tI4mI7EKIWQoAdtC1PSgpu12buPCvcHtJpCGoKZ0tyeaxjMFOX7
EA24JAIBMHHeWYB4h0wDAhE0u9AsklLRmidrEKb4iN8mny+YqWhZTe67AoGARAo8
kR3nISwA1XmlOi38tfTijCvNsj0Az4dvpMvWThd+apEJDA1JxHmKO9D32+TsJUKX
Gfa/aCR/c6tj57qc5RCG7FIe9vbE1PdXJ48ARspw3u5W7NfTyRyJ4g0iweZI8yGK
Nev7Xauk40Wprkg+mVEdsKIYsxpxXwu9UD6Hn7ECgYBS2A0QUtqD1ZQ6rfS6oTzS
8ttEtz4KQoxXD5W2XrIr4mYFO3axbiLks17gGgElK5neeDUYj5srGecW5HmWppX2
nG56VkpLGb8+vke/PAC+nOUrzmciTDcDMh6oZgb4uB18QxSPPCFm5uiVilsDIetW
lWzs/4gB6mcRXKZjJFyqwg==
-----END PRIVATE KEY-----";
const RSA_N: &str = "sd1DxkH2PvLTFbPvxjcGjaQTmpDgKAtBChG5mFFp5G1OiWrZr4i6APVltT73ecAyTmyTzfB_dqjbOklzai2upF3HJ49HB9aMw6xMDHDhHP8w2VoWpsb1LIVgGkeNb74FciHIZ-wuYgdY8AOfx-7JPRHi6EWG5Nb0C4iANfQB28aUXWnpTDxBslUk__PZBqgDeKXDLX5KulBdJLTM-qUdem0yom_tpeFg88LaEfE_S8C5BsBwdHbH37G0uVLZ-ZKax8IfsAy3WT3psYsS9JQklaFLN0-b_ALu7jM8YfhP7OvBKVyJZBaosZsVHfCDOk3DjXzTq5C9kSoBlQpRCJvrFw";

/// The DER of a PKCS #8 `PrivateKeyInfo` for a P-256 key, up to the 32-byte scalar (no
/// optional public key), as an Apple `.p8` file holds it.
const PKCS8_P256_PREFIX: [u8; 35] = [
    0x30, 0x41, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x27, 0x30, 0x25, 0x02, 0x01,
    0x01, 0x04, 0x20,
];

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).expect("randomness");
    bytes
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// A fresh P-256 key and its scalar.
fn ec_key() -> (SigningKey, [u8; 32]) {
    let scalar = random::<32>();
    (
        SigningKey::from_bytes(&scalar.into()).expect("a valid scalar"),
        scalar,
    )
}

fn ec_jwk(kid: &str, key: &SigningKey) -> Value {
    let point = key.verifying_key().to_sec1_point(false);
    json!({
        "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
        "x": b64(point.x().unwrap()), "y": b64(point.y().unwrap()),
    })
}

/// Signs `claims` as an ES256 JWS by hand (independently of the hub's JWT library).
fn sign_es256(kid: &str, key: &SigningKey, claims: &Value) -> String {
    let header = json!({"alg": "ES256", "kid": kid, "typ": "JWT"});
    let input = format!(
        "{}.{}",
        b64(header.to_string().as_bytes()),
        b64(claims.to_string().as_bytes())
    );
    let signature: Signature = key.sign(input.as_bytes());
    format!("{input}.{}", b64(&signature.to_bytes()))
}

fn sign_rs256(kid: &str, claims: &Value) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(kid.into());
    jsonwebtoken::encode(
        &header,
        claims,
        &EncodingKey::from_rsa_pem(RSA_PEM.as_bytes()).unwrap(),
    )
    .unwrap()
}

// ---- The fake Apple ----

/// A code the fake will exchange once: for whom, and which client and redirect it was issued to.
#[derive(Clone)]
struct Grant {
    sub: String,
    client_id: String,
    redirect_uri: Option<String>,
}

#[derive(Default)]
struct Calls {
    jwks_fetches: usize,
    /// `(client_id, redirect_uri)` of each successful exchange.
    exchanges: Vec<(String, Option<String>)>,
    /// `(client_id, token)` of each revoke.
    revoked: Vec<(String, String)>,
    /// Every refresh token issued and every client secret seen, for the log test.
    refresh_tokens: Vec<String>,
    client_secrets: Vec<String>,
    /// Client secrets that did not verify.
    bad_secrets: usize,
}

struct FakeState {
    issuer: String,
    keys: Vec<Value>,
    signing: SigningKey,
    team_key: DecodingKey,
    codes: HashMap<String, Grant>,
    calls: Calls,
    fail_revoke: bool,
}

type Shared = Arc<Mutex<FakeState>>;

struct FakeApple {
    base: String,
    state: Shared,
    /// The team's `.p8` key, for the hub's configuration.
    team_pem: String,
    server: JoinHandle<()>,
}

impl Drop for FakeApple {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl FakeApple {
    async fn start() -> FakeApple {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let (signing, _) = ec_key();
        let (team, team_scalar) = ec_key();
        let point = team.verifying_key().to_sec1_point(false);
        let team_key =
            DecodingKey::from_ec_components(&b64(point.x().unwrap()), &b64(point.y().unwrap()))
                .unwrap();
        let mut der = PKCS8_P256_PREFIX.to_vec();
        der.extend_from_slice(&team_scalar);
        let team_pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
            STANDARD.encode(der)
        );
        let keys = vec![
            ec_jwk(EC_KID, &signing),
            json!({"kty": "RSA", "kid": RSA_KID, "use": "sig", "alg": "RS256",
                   "n": RSA_N, "e": "AQAB"}),
        ];
        let state = Arc::new(Mutex::new(FakeState {
            issuer: base.clone(),
            keys,
            signing,
            team_key,
            codes: HashMap::new(),
            calls: Calls::default(),
            fail_revoke: false,
        }));
        let app = Router::new()
            .route("/auth/keys", get(keys_route))
            .route("/auth/token", post(token_route))
            .route("/auth/revoke", post(revoke_route))
            .with_state(state.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        FakeApple {
            base,
            state,
            team_pem,
            server,
        }
    }

    fn calls<T>(&self, read: impl FnOnce(&Calls) -> T) -> T {
        read(&self.state.lock().unwrap().calls)
    }

    /// An identity token as Apple would issue it, signed with the EC key.
    fn token(&self, sub: &str, aud: &str, nonce: Option<&str>) -> String {
        self.token_with(EC_KID, &self.claims(sub, aud, nonce))
    }

    fn claims(&self, sub: &str, aud: &str, nonce: Option<&str>) -> Value {
        let issuer = self.state.lock().unwrap().issuer.clone();
        let mut claims = json!({
            "iss": issuer, "aud": aud, "sub": sub, "iat": now(), "exp": now() + 600,
            "email": format!("{sub}@privaterelay.appleid.com"), "email_verified": true,
            "is_private_email": true,
        });
        if let Some(nonce) = nonce {
            claims["nonce"] = json!(nonce);
        }
        claims
    }

    /// `claims` signed with the key `kid` names (the EC or the RSA key).
    fn token_with(&self, kid: &str, claims: &Value) -> String {
        if kid == RSA_KID {
            sign_rs256(kid, claims)
        } else {
            let state = self.state.lock().unwrap();
            sign_es256(kid, &state.signing, claims)
        }
    }

    /// A code the fake will exchange once for `sub`, issued to `client_id`.
    fn code(&self, sub: &str, client_id: &str, redirect_uri: Option<&str>) -> String {
        let code = format!("c.{}", b64(&random::<16>()));
        self.state.lock().unwrap().codes.insert(
            code.clone(),
            Grant {
                sub: sub.into(),
                client_id: client_id.into(),
                redirect_uri: redirect_uri.map(str::to_string),
            },
        );
        code
    }
}

fn form(body: &Bytes) -> HashMap<String, String> {
    url::form_urlencoded::parse(body).into_owned().collect()
}

/// Whether `secret` is a client secret the team key signed for `client_id`, as Apple checks it.
fn secret_ok(state: &FakeState, secret: &str, client_id: &str) -> bool {
    let Ok(header) = jsonwebtoken::decode_header(secret) else {
        return false;
    };
    let mut validation = Validation::new(Algorithm::ES256);
    validation.set_issuer(&[TEAM_ID]);
    validation.set_audience(&["https://appleid.apple.com"]);
    validation.sub = Some(client_id.into());
    validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
    let Ok(data) = jsonwebtoken::decode::<Value>(secret, &state.team_key, &validation) else {
        return false;
    };
    let lifetime =
        data.claims["exp"].as_u64().unwrap_or(0) - data.claims["iat"].as_u64().unwrap_or(0);
    header.kid.as_deref() == Some(KEY_ID) && lifetime == 300
}

async fn keys_route(State(state): State<Shared>) -> Json<Value> {
    let mut state = state.lock().unwrap();
    state.calls.jwks_fetches += 1;
    Json(json!({"keys": state.keys}))
}

async fn token_route(State(state): State<Shared>, body: Bytes) -> axum::response::Response {
    let fields = form(&body);
    let field = |name: &str| fields.get(name).cloned().unwrap_or_default();
    let mut state = state.lock().unwrap();
    let client_id = field("client_id");
    state.calls.client_secrets.push(field("client_secret"));
    if !secret_ok(&state, &field("client_secret"), &client_id) {
        state.calls.bad_secrets += 1;
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({"error": "invalid_client"})),
        )
            .into_response();
    }
    let redirect_uri = fields.get("redirect_uri").cloned();
    let grant = match state.codes.remove(&field("code")) {
        Some(grant)
            if field("grant_type") == "authorization_code"
                && grant.client_id == client_id
                && grant.redirect_uri == redirect_uri =>
        {
            grant
        }
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({"error": "invalid_grant"})),
            )
                .into_response()
        }
    };
    let refresh = format!("r.{}", b64(&random::<24>()));
    state.calls.refresh_tokens.push(refresh.clone());
    state
        .calls
        .exchanges
        .push((client_id.clone(), redirect_uri));
    let claims = json!({
        "iss": state.issuer, "aud": client_id, "sub": grant.sub, "iat": now(),
        "exp": now() + 600,
    });
    let id_token = sign_es256(EC_KID, &state.signing, &claims);
    Json(json!({
        "access_token": "a.unused", "token_type": "Bearer", "expires_in": 3600,
        "refresh_token": refresh, "id_token": id_token,
    }))
    .into_response()
}

async fn revoke_route(State(state): State<Shared>, body: Bytes) -> StatusCode {
    let fields = form(&body);
    let field = |name: &str| fields.get(name).cloned().unwrap_or_default();
    let mut state = state.lock().unwrap();
    state.calls.client_secrets.push(field("client_secret"));
    if !secret_ok(&state, &field("client_secret"), &field("client_id"))
        || field("token_type_hint") != "refresh_token"
    {
        state.calls.bad_secrets += 1;
        return StatusCode::BAD_REQUEST;
    }
    state
        .calls
        .revoked
        .push((field("client_id"), field("token")));
    if state.fail_revoke {
        StatusCode::SERVICE_UNAVAILABLE
    } else {
        StatusCode::OK
    }
}

// ---- The hub ----

fn apple_config(fake: &FakeApple, signup: Signup) -> Config {
    let mut config = common::config(signup);
    config.public_url = Some(Url::parse(PUBLIC_URL).unwrap());
    config.apple = Some(AppleConfig {
        team_id: TEAM_ID.into(),
        key_id: KEY_ID.into(),
        private_key_pem: fake.team_pem.clone(),
        audiences: vec![BUNDLE_ID.into(), SERVICES_ID.into()],
        services_id: Some(SERVICES_ID.into()),
        base_url: Url::parse(&fake.base).unwrap(),
    });
    config
}

struct Setup {
    admin: Db,
    hub: Hub,
    fake: FakeApple,
}

async fn setup(pool: &PgPool, signup: Signup) -> Setup {
    let fake = FakeApple::start().await;
    let (admin, app) = common::migrated(pool).await;
    let hub = Hub::start(app, apple_config(&fake, signup)).await;
    Setup { admin, hub, fake }
}

fn device(name: &str, platform: &str) -> Value {
    json!({"deviceName": name, "platform": platform})
}

fn bearer(token: &str) -> String {
    format!("Bearer {token}")
}

async fn authed(hub: &Hub, method: &str, path: &str, body: Option<&Value>, token: &str) -> Answer {
    let auth = bearer(token);
    hub.send(method, path, body, &[("authorization", auth.as_str())])
        .await
}

fn token_of(session: &Value) -> &str {
    session["token"].as_str().expect("a session has a token")
}

/// Begins a native ceremony; answers `(ceremonyId, nonce)`.
async fn begin_native(hub: &Hub) -> (Value, String) {
    let begun = hub.post(BEGIN, Some(&json!({}))).await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    (
        begun.body["ceremonyId"].clone(),
        begun.body["nonce"].as_str().unwrap().to_string(),
    )
}

/// The native flow end to end for `sub` on an iPhone, with the identity token signed by `kid`.
async fn native(setup: &Setup, sub: &str, kid: &str, full_name: Option<&str>) -> Answer {
    let (ceremony, nonce) = begin_native(&setup.hub).await;
    let token = setup.fake.token_with(
        kid,
        &setup.fake.claims(sub, BUNDLE_ID, Some(&sha256_hex(&nonce))),
    );
    let code = setup.fake.code(sub, BUNDLE_ID, None);
    let mut body = json!({
        "ceremonyId": ceremony, "identityToken": token, "authorizationCode": code,
        "device": device("Brian's iPhone", "ios"),
    });
    if let Some(name) = full_name {
        body["fullName"] = json!(name);
    }
    setup.hub.post(NATIVE, Some(&body)).await
}

/// A random verifier and the `verifierHash` that goes with it.
fn new_verifier() -> (String, String) {
    let verifier = b64(&random::<32>());
    let hash = sha256_hex(&verifier);
    (verifier, hash)
}

/// The query of `location` as pairs.
fn query(location: &str) -> HashMap<String, String> {
    Url::parse(location)
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}

fn location(answer: &Answer) -> String {
    assert_eq!(answer.status, StatusCode::FOUND, "{}", answer.body);
    answer.headers["location"].to_str().unwrap().to_string()
}

/// A web ceremony begun at `begin_path` (with `token` when it is the link route), started:
/// answers the ceremony id and the nonce claim the authorize URL carried.
async fn begin_web(
    hub: &Hub,
    begin_path: &str,
    token: Option<&str>,
    verifier_hash: &str,
    scheme: &str,
) -> (String, String) {
    let body = json!({"verifierHash": verifier_hash, "scheme": scheme});
    let begun = match token {
        Some(token) => authed(hub, "POST", begin_path, Some(&body), token).await,
        None => hub.post(begin_path, Some(&body)).await,
    };
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    let ceremony = begun.body["ceremonyId"].as_str().unwrap().to_string();
    let started = hub
        .get(&format!("/v1/auth/apple/start?ceremony={ceremony}"), None)
        .await;
    let params = query(&location(&started));
    assert_eq!(params["state"], ceremony);
    let nonce_claim = params["nonce"].clone();
    assert_eq!(
        nonce_claim,
        sha256_hex(begun.body["nonce"].as_str().unwrap())
    );
    (ceremony, nonce_claim)
}

/// Apple's form post for a web ceremony, for `sub`; answers the hub's redirect.
async fn apple_posts(
    setup: &Setup,
    ceremony: &str,
    nonce_claim: &str,
    sub: &str,
    user: Option<&str>,
) -> Answer {
    let token = setup.fake.token(sub, SERVICES_ID, Some(nonce_claim));
    let code = setup.fake.code(sub, SERVICES_ID, Some(CALLBACK_URL));
    let mut fields = vec![
        ("state", ceremony),
        ("code", code.as_str()),
        ("id_token", token.as_str()),
    ];
    if let Some(user) = user {
        fields.push(("user", user));
    }
    setup.hub.post_form(CALLBACK, &fields).await
}

/// The handoff code a callback's redirect to `scheme` carries.
fn handoff_in(location: &str, scheme: &str) -> String {
    let prefix = format!("{scheme}://auth?handoff=");
    location
        .strip_prefix(&prefix)
        .unwrap_or_else(|| panic!("{location} is not a {scheme} handoff"))
        .to_string()
}

async fn redeem(hub: &Hub, handoff: &str, verifier: &str) -> Answer {
    hub.post(
        HANDOFF,
        Some(&json!({"handoff": handoff, "verifier": verifier,
                     "device": device("Brian's MacBook Pro", "macos")})),
    )
    .await
}

async fn count(pool: &PgPool, sql: &str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

// ---- The native flow ----

#[sqlx::test(migrations = false)]
async fn native_sign_up_then_sign_in_same_sub(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;

    let up = native(&setup, "001.alice", EC_KID, Some("  Alice Appleseed ")).await;
    assert_eq!(up.status, StatusCode::OK, "{}", up.body);
    assert_eq!(up.body["needsOnboarding"], true);
    assert_eq!(up.body["user"]["displayName"], "Alice Appleseed");
    assert_eq!(up.body["org"]["name"], "My Org");
    // The code was exchanged as the iOS app's (no redirect URI in the native flow).
    assert_eq!(
        setup.fake.calls(|c| c.exchanges.clone()),
        [(BUNDLE_ID.to_string(), None)]
    );
    assert_eq!(setup.fake.calls(|c| c.bad_secrets), 0);

    // Apple's own algorithm (RS256) signs the next one; the name is not sent again.
    let again = native(&setup, "001.alice", RSA_KID, None).await;
    assert_eq!(again.status, StatusCode::OK, "{}", again.body);
    assert_eq!(again.body["org"], up.body["org"]);
    assert_eq!(again.body["user"], up.body["user"]);
    assert_ne!(again.body["deviceId"], up.body["deviceId"]);
    // Still onboarding: Apple's name is only the prefill.
    assert_eq!(again.body["needsOnboarding"], true);

    let me = setup.hub.get("/v1/me", Some(token_of(&again.body))).await;
    assert_eq!(me.status, StatusCode::OK, "{}", me.body);
    assert_eq!(me.body["onboarded"], false);
    assert_eq!(me.body["user"]["fullName"], Value::Null);
    let identities = me.body["identities"].as_array().unwrap();
    assert_eq!(identities.len(), 1);
    assert_eq!(identities[0]["kind"], "apple");
    assert_eq!(identities[0]["name"], "001.alice@privaterelay.appleid.com");
    assert!(identities[0]["lastUsedAt"].is_string());
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 1);
}

#[sqlx::test(migrations = false)]
async fn native_validates_before_using_the_ceremony(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let (ceremony, nonce) = begin_native(&setup.hub).await;
    let token = setup
        .fake
        .token("001.v", BUNDLE_ID, Some(&sha256_hex(&nonce)));
    let code = setup.fake.code("001.v", BUNDLE_ID, None);
    let good = json!({
        "ceremonyId": ceremony, "identityToken": token, "authorizationCode": code,
        "device": device("iPhone", "ios"),
    });
    let mut long_name = good.clone();
    long_name["fullName"] = json!("x".repeat(201));
    let mut extra = good.clone();
    extra["email"] = json!("a@b.c");
    let mut bad_device = good.clone();
    bad_device["device"]["platform"] = json!("android");
    for body in [long_name, extra, bad_device] {
        let answer = setup.hub.post(NATIVE, Some(&body)).await;
        assert_eq!(answer.code(), "invalid_request", "{}", answer.body);
    }
    // None of those used the ceremony.
    let answer = setup.hub.post(NATIVE, Some(&good)).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
    // It is single use.
    let replay = setup.hub.post(NATIVE, Some(&good)).await;
    assert_eq!(replay.code(), "ceremony_expired");
}

#[sqlx::test(migrations = false)]
async fn native_new_sub_when_signup_closed_is_signup_closed(pool: PgPool) {
    let setup = setup(&pool, Signup::Closed).await;
    let answer = native(&setup, "001.new", EC_KID, Some("New Person")).await;
    assert_eq!(answer.status, StatusCode::FORBIDDEN, "{}", answer.body);
    assert_eq!(answer.code(), "signup_closed");
    // Refused before the code was exchanged, so Apple holds no grant for it.
    assert!(setup.fake.calls(|c| c.exchanges.is_empty()));
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 0);
}

/// Sends `token` through the native flow for a fresh ceremony whose nonce `nonce_for` turns
/// into the token's claims; asserts it is rejected and nothing was exchanged or created.
async fn assert_native_rejected(setup: &Setup, pool: &PgPool, token: impl Fn(&str) -> String) {
    let (ceremony, nonce) = begin_native(&setup.hub).await;
    let answer = setup
        .hub
        .post(
            NATIVE,
            Some(&json!({
                "ceremonyId": ceremony, "identityToken": token(&nonce),
                "authorizationCode": setup.fake.code("001.x", BUNDLE_ID, None),
                "device": device("iPhone", "ios"),
            })),
        )
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED, "{}", answer.body);
    assert_eq!(answer.code(), "credential_rejected");
    assert_eq!(
        answer.body["error"]["message"],
        "the credential could not be verified"
    );
    assert!(setup.fake.calls(|c| c.exchanges.is_empty()));
    assert_eq!(count(pool, "SELECT count(*) FROM users").await, 0);
}

#[sqlx::test(migrations = false)]
async fn wrong_aud_rejected(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let fake = &setup.fake;
    assert_native_rejected(&setup, &pool, |nonce| {
        fake.token("001.x", "com.example.other", Some(&sha256_hex(nonce)))
    })
    .await;
    // The wrong issuer, too.
    assert_native_rejected(&setup, &pool, |nonce| {
        let mut claims = fake.claims("001.x", BUNDLE_ID, Some(&sha256_hex(nonce)));
        claims["iss"] = json!("https://appleid.apple.com.evil");
        fake.token_with(EC_KID, &claims)
    })
    .await;
}

#[sqlx::test(migrations = false)]
async fn wrong_nonce_rejected(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let fake = &setup.fake;
    // Another ceremony's nonce, the raw nonce instead of its hash, and none at all.
    assert_native_rejected(&setup, &pool, |_| {
        fake.token("001.x", BUNDLE_ID, Some(&sha256_hex("another ceremony")))
    })
    .await;
    assert_native_rejected(&setup, &pool, |nonce| {
        fake.token("001.x", BUNDLE_ID, Some(nonce))
    })
    .await;
    assert_native_rejected(&setup, &pool, |_| fake.token("001.x", BUNDLE_ID, None)).await;
}

#[sqlx::test(migrations = false)]
async fn expired_token_rejected(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let fake = &setup.fake;
    assert_native_rejected(&setup, &pool, |nonce| {
        let mut claims = fake.claims("001.x", BUNDLE_ID, Some(&sha256_hex(nonce)));
        claims["iat"] = json!(now() - 7200);
        claims["exp"] = json!(now() - 3600);
        fake.token_with(EC_KID, &claims)
    })
    .await;
}

#[sqlx::test(migrations = false)]
async fn forged_tokens_rejected(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let fake = &setup.fake;
    // Signed by a key Apple never published, under a kid it did.
    assert_native_rejected(&setup, &pool, |nonce| {
        let (stranger, _) = ec_key();
        sign_es256(
            EC_KID,
            &stranger,
            &fake.claims("001.x", BUNDLE_ID, Some(&sha256_hex(nonce))),
        )
    })
    .await;
    // An RS256 header on the EC key's kid.
    assert_native_rejected(&setup, &pool, |nonce| {
        sign_rs256(
            EC_KID,
            &fake.claims("001.x", BUNDLE_ID, Some(&sha256_hex(nonce))),
        )
    })
    .await;
    // Not a JWT at all, and a JWT naming no key.
    assert_native_rejected(&setup, &pool, |_| "not.a.jwt".into()).await;
    assert_native_rejected(&setup, &pool, |nonce| {
        let claims = fake.claims("001.x", BUNDLE_ID, Some(&sha256_hex(nonce)));
        let header = json!({"alg": "ES256"});
        format!(
            "{}.{}.{}",
            b64(header.to_string().as_bytes()),
            b64(claims.to_string().as_bytes()),
            b64(&[0; 64])
        )
    })
    .await;
}

#[sqlx::test(migrations = false)]
async fn a_code_for_another_apple_id_rejected(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let (ceremony, nonce) = begin_native(&setup.hub).await;
    let answer = setup
        .hub
        .post(
            NATIVE,
            Some(&json!({
                "ceremonyId": ceremony,
                "identityToken": setup.fake.token("001.me", BUNDLE_ID, Some(&sha256_hex(&nonce))),
                "authorizationCode": setup.fake.code("001.someone-else", BUNDLE_ID, None),
                "device": device("iPhone", "ios"),
            })),
        )
        .await;
    assert_eq!(answer.code(), "credential_rejected", "{}", answer.body);
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 0);
    // An unknown code too.
    let (ceremony, nonce) = begin_native(&setup.hub).await;
    let answer = setup
        .hub
        .post(
            NATIVE,
            Some(&json!({
                "ceremonyId": ceremony,
                "identityToken": setup.fake.token("001.me", BUNDLE_ID, Some(&sha256_hex(&nonce))),
                "authorizationCode": "c.never-issued",
                "device": device("iPhone", "ios"),
            })),
        )
        .await;
    assert_eq!(answer.code(), "credential_rejected", "{}", answer.body);
}

#[sqlx::test(migrations = false)]
async fn unknown_kid_refetches_jwks_once(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    assert_eq!(setup.fake.calls(|c| c.jwks_fetches), 0);

    // The first token's kid is unknown to the empty cache: one fetch, and it verifies.
    let up = native(&setup, "001.k", EC_KID, None).await;
    assert_eq!(up.status, StatusCode::OK, "{}", up.body);
    assert_eq!(setup.fake.calls(|c| c.jwks_fetches), 1);
    // A kid in that set needs no fetch.
    let again = native(&setup, "001.k", RSA_KID, None).await;
    assert_eq!(again.status, StatusCode::OK, "{}", again.body);
    assert_eq!(setup.fake.calls(|c| c.jwks_fetches), 1);

    // Apple rotates in a key. Within the minute an unknown kid is refused without fetching
    // again, however often it is tried (the unit test in `apple.rs` covers the fetch a minute
    // later).
    let (rotated, _) = ec_key();
    setup
        .fake
        .state
        .lock()
        .unwrap()
        .keys
        .push(ec_jwk("ec-2", &rotated));
    for _ in 0..3 {
        let (ceremony, nonce) = begin_native(&setup.hub).await;
        let token = sign_es256(
            "ec-2",
            &rotated,
            &setup
                .fake
                .claims("001.k", BUNDLE_ID, Some(&sha256_hex(&nonce))),
        );
        let answer = setup
            .hub
            .post(
                NATIVE,
                Some(&json!({
                    "ceremonyId": ceremony, "identityToken": token,
                    "authorizationCode": setup.fake.code("001.k", BUNDLE_ID, None),
                    "device": device("iPhone", "ios"),
                })),
            )
            .await;
        assert_eq!(answer.code(), "credential_rejected", "{}", answer.body);
    }
    assert_eq!(setup.fake.calls(|c| c.jwks_fetches), 1);
}

// ---- The web flow ----

#[sqlx::test(migrations = false)]
async fn web_flow_start_redirects_with_state_and_nonce(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;
    let (_, hash) = new_verifier();
    let begun = hub
        .post(
            BEGIN,
            Some(&json!({"verifierHash": hash, "scheme": "b4app-local"})),
        )
        .await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    let ceremony = begun.body["ceremonyId"].as_str().unwrap();
    let nonce = begun.body["nonce"].as_str().unwrap();

    let start = format!("/v1/auth/apple/start?ceremony={ceremony}");
    let started = hub.get(&start, None).await;
    let target = location(&started);
    let url = Url::parse(&target).unwrap();
    assert_eq!(
        format!("{}{}", url.origin().ascii_serialization(), url.path()),
        format!("{}/auth/authorize", setup.fake.base)
    );
    let params = query(&target);
    let expected: HashMap<String, String> = [
        ("client_id", SERVICES_ID.to_string()),
        ("redirect_uri", CALLBACK_URL.to_string()),
        ("response_type", "code id_token".to_string()),
        ("response_mode", "form_post".to_string()),
        ("scope", "name email".to_string()),
        ("state", ceremony.to_string()),
        ("nonce", sha256_hex(nonce)),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    assert_eq!(params, expected);
    // Spaces are %20, as Apple's documentation spells them.
    assert!(url
        .query()
        .unwrap()
        .contains("response_type=code%20id_token"));
    assert!(
        !target.contains(&hash),
        "the verifier hash stays on the hub"
    );

    // Starting does not use the ceremony up (a reloaded page starts again).
    assert_eq!(hub.get(&start, None).await.status, StatusCode::FOUND);

    // A native ceremony, an unknown one, and a malformed query cannot start.
    let (native_ceremony, _) = begin_native(hub).await;
    for path in [
        format!(
            "/v1/auth/apple/start?ceremony={}",
            native_ceremony.as_str().unwrap()
        ),
        format!("/v1/auth/apple/start?ceremony={}", Uuid::new_v4()),
    ] {
        let answer = hub.get(&path, None).await;
        assert_eq!(answer.code(), "ceremony_expired", "{path}: {}", answer.body);
    }
    for path in [
        "/v1/auth/apple/start".to_string(),
        "/v1/auth/apple/start?ceremony=nope".to_string(),
        format!("{start}&verifierHash={hash}"),
    ] {
        let answer = hub.get(&path, None).await;
        assert_eq!(answer.code(), "invalid_request", "{path}: {}", answer.body);
    }

    // Begin's own validation: both fields or neither, a known scheme, a SHA-256 in hex.
    for body in [
        json!({"verifierHash": hash}),
        json!({"scheme": "b4app"}),
        json!({"verifierHash": hash, "scheme": "https"}),
        json!({"verifierHash": hash, "scheme": "B4APP"}),
        json!({"verifierHash": "abc", "scheme": "b4app"}),
        json!({"verifierHash": hash.to_uppercase(), "scheme": "b4app"}),
        json!({"verifierHash": hash, "scheme": "b4app", "other": 1}),
    ] {
        let answer = hub.post(BEGIN, Some(&body)).await;
        assert_eq!(answer.code(), "invalid_request", "{body}: {}", answer.body);
    }
    // No body at all is a native ceremony.
    assert_eq!(hub.post(BEGIN, None).await.status, StatusCode::OK);
}

#[sqlx::test(migrations = false)]
async fn callback_exchanges_and_redirects_to_scheme_with_handoff(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(hub, BEGIN, None, &hash, "b4app-beta").await;

    let user = r#"{"name":{"firstName":"Bea","lastName":"Beta"},"email":"bea@example.test"}"#;
    let token = setup.fake.token("001.bea", SERVICES_ID, Some(&nonce_claim));
    let code = setup.fake.code("001.bea", SERVICES_ID, Some(CALLBACK_URL));
    // A scheme in the post is ignored: the redirect goes where the ceremony said.
    let posted = hub
        .post_form(
            CALLBACK,
            &[
                ("state", &ceremony),
                ("code", &code),
                ("id_token", &token),
                ("user", user),
                ("scheme", "evil"),
            ],
        )
        .await;
    let target = location(&posted);
    let handoff = handoff_in(&target, "b4app-beta");
    assert_eq!(handoff.len(), 43, "{target}");
    assert_eq!(
        setup.fake.calls(|c| c.exchanges.clone()),
        [(SERVICES_ID.to_string(), Some(CALLBACK_URL.to_string()))]
    );
    // The account exists from the callback on; the device only from the handoff.
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 1);
    assert_eq!(count(&pool, "SELECT count(*) FROM devices").await, 0);

    let session = redeem(hub, &handoff, &verifier).await;
    assert_eq!(session.status, StatusCode::OK, "{}", session.body);
    assert_eq!(session.body["needsOnboarding"], true);
    assert_eq!(session.body["user"]["displayName"], "Bea Beta");
    let me = hub.get("/v1/me", Some(token_of(&session.body))).await;
    assert_eq!(me.body["platform"], "macos");
    assert_eq!(me.body["identities"][0]["kind"], "apple");

    // Apple's post is single use: the ceremony is gone.
    let replay = hub
        .post_form(
            CALLBACK,
            &[("state", &ceremony), ("code", &code), ("id_token", &token)],
        )
        .await;
    assert_eq!(replay.status, StatusCode::BAD_REQUEST);
    assert_eq!(replay.code(), "ceremony_expired");

    // Signing in again on the web finds the same account.
    let (verifier2, hash2) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(hub, BEGIN, None, &hash2, "b4app").await;
    let target = location(&apple_posts(&setup, &ceremony, &nonce_claim, "001.bea", None).await);
    let again = redeem(hub, &handoff_in(&target, "b4app"), &verifier2).await;
    assert_eq!(again.status, StatusCode::OK, "{}", again.body);
    assert_eq!(again.body["user"], session.body["user"]);
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 1);
}

#[sqlx::test(migrations = false)]
async fn callback_failures_redirect_with_an_error(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;

    // A token that does not verify.
    let (_, hash) = new_verifier();
    let (ceremony, _) = begin_web(hub, BEGIN, None, &hash, "b4app-local").await;
    let wrong = apple_posts(&setup, &ceremony, &sha256_hex("not it"), "001.f", None).await;
    assert_eq!(
        location(&wrong),
        "b4app-local://auth?error=credential_rejected"
    );

    // A native-audience token posted to the web flow.
    let (ceremony, nonce_claim) = begin_web(hub, BEGIN, None, &hash, "b4app-local").await;
    let token = setup.fake.token("001.f", BUNDLE_ID, Some(&nonce_claim));
    let posted = hub
        .post_form(
            CALLBACK,
            &[("state", &ceremony), ("code", "c.x"), ("id_token", &token)],
        )
        .await;
    assert_eq!(
        location(&posted),
        "b4app-local://auth?error=credential_rejected"
    );

    // The person cancelled on Apple's page.
    let (ceremony, _) = begin_web(hub, BEGIN, None, &hash, "b4app-local").await;
    let cancelled = hub
        .post_form(
            CALLBACK,
            &[("state", &ceremony), ("error", "user_cancelled_authorize")],
        )
        .await;
    assert_eq!(location(&cancelled), "b4app-local://auth?error=cancelled");

    // An unknown state cannot be redirected anywhere.
    let lost = hub
        .post_form(CALLBACK, &[("state", &Uuid::new_v4().to_string())])
        .await;
    assert_eq!(lost.code(), "ceremony_expired");
    let lost = hub.post_form(CALLBACK, &[("code", "c.x")]).await;
    assert_eq!(lost.code(), "invalid_request");

    // A native ceremony's id is not a web state.
    let (native_ceremony, _) = begin_native(hub).await;
    let lost = hub
        .post_form(CALLBACK, &[("state", native_ceremony.as_str().unwrap())])
        .await;
    assert_eq!(lost.code(), "ceremony_expired");

    assert!(setup.fake.calls(|c| c.exchanges.is_empty()));
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 0);
}

#[sqlx::test(migrations = false)]
async fn callback_new_sub_when_signup_closed_redirects_signup_closed(pool: PgPool) {
    let setup = setup(&pool, Signup::Closed).await;
    let (_, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(&setup.hub, BEGIN, None, &hash, "b4app").await;
    let posted = apple_posts(&setup, &ceremony, &nonce_claim, "001.new", None).await;
    assert_eq!(location(&posted), "b4app://auth?error=signup_closed");
    assert!(setup.fake.calls(|c| c.exchanges.is_empty()));
}

/// A web sign-up for `sub` up to the redirect; answers the handoff and its verifier.
async fn web_handoff(setup: &Setup, sub: &str) -> (String, String) {
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(&setup.hub, BEGIN, None, &hash, "b4app").await;
    let target = location(&apple_posts(setup, &ceremony, &nonce_claim, sub, None).await);
    (handoff_in(&target, "b4app"), verifier)
}

#[sqlx::test(migrations = false)]
async fn handoff_requires_verifier(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let (handoff, verifier) = web_handoff(&setup, "001.h").await;

    // A wrong verifier, or the hash in place of the verifier, is refused like an unknown code...
    for wrong in [b64(&random::<32>()), sha256_hex(&verifier)] {
        let answer = redeem(&setup.hub, &handoff, &wrong).await;
        assert_eq!(answer.status, StatusCode::BAD_REQUEST, "{}", answer.body);
        assert_eq!(answer.code(), "ceremony_expired");
    }
    let answer = redeem(&setup.hub, &b64(&random::<32>()), &verifier).await;
    assert_eq!(answer.code(), "ceremony_expired");
    // ...and validated before it is looked up.
    let short = redeem(&setup.hub, &handoff, "short").await;
    assert_eq!(short.code(), "invalid_request");
    let no_device = setup
        .hub
        .post(
            HANDOFF,
            Some(&json!({"handoff": handoff, "verifier": verifier})),
        )
        .await;
    assert_eq!(no_device.code(), "invalid_request");

    // The rightful holder still redeems it.
    let answer = redeem(&setup.hub, &handoff, &verifier).await;
    assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
}

#[sqlx::test(migrations = false)]
async fn handoff_single_use(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let (handoff, verifier) = web_handoff(&setup, "001.once").await;
    let first = redeem(&setup.hub, &handoff, &verifier).await;
    assert_eq!(first.status, StatusCode::OK, "{}", first.body);
    let second = redeem(&setup.hub, &handoff, &verifier).await;
    assert_eq!(second.code(), "ceremony_expired");
    assert_eq!(count(&pool, "SELECT count(*) FROM device_tokens").await, 1);
}

#[sqlx::test(migrations = false)]
async fn handoff_concurrent_one_token(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    for round in 0..3 {
        let (handoff, verifier) = web_handoff(&setup, &format!("001.race{round}")).await;
        let (one, two) = tokio::join!(
            redeem(&setup.hub, &handoff, &verifier),
            redeem(&setup.hub, &handoff, &verifier)
        );
        let mut statuses = [one.status, two.status];
        statuses.sort();
        assert_eq!(
            statuses,
            [StatusCode::OK, StatusCode::BAD_REQUEST],
            "{} / {}",
            one.body,
            two.body
        );
        let loser = if one.status == StatusCode::OK {
            &two
        } else {
            &one
        };
        assert_eq!(loser.code(), "ceremony_expired");
    }
    assert_eq!(count(&pool, "SELECT count(*) FROM device_tokens").await, 3);
}

// ---- What the hub keeps, and deletion ----

async fn stored_refresh(admin: &Db) -> Vec<(Uuid, Vec<u8>)> {
    sqlx::query_as(
        "SELECT id, apple_refresh_token_enc FROM user_identities \
         WHERE kind = 'apple' ORDER BY created_at",
    )
    .fetch_all(&admin.pool)
    .await
    .unwrap()
}

#[sqlx::test(migrations = false)]
async fn refresh_token_stored_encrypted(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let key = setup.hub.state.config.secret_key;
    let up = native(&setup, "001.enc", EC_KID, None).await;
    assert_eq!(up.status, StatusCode::OK, "{}", up.body);

    let issued = setup.fake.calls(|c| c.refresh_tokens.clone());
    let stored = stored_refresh(&setup.admin).await;
    assert_eq!(stored.len(), 1);
    let (identity_id, sealed) = &stored[0];
    assert_ne!(sealed.as_slice(), issued[0].as_bytes());
    assert!(!sealed
        .windows(issued[0].len())
        .any(|w| w == issued[0].as_bytes()));
    let grant = open_refresh_token(&key, *identity_id, sealed).unwrap();
    assert_eq!(grant.refresh_token, issued[0]);
    assert_eq!(grant.client_id, BUNDLE_ID);
    // Sealed to its row: under another row's id it does not open.
    assert!(open_refresh_token(&key, Uuid::new_v4(), sealed).is_err());

    // A sign-in keeps the newest refresh token.
    let again = native(&setup, "001.enc", EC_KID, None).await;
    assert_eq!(again.status, StatusCode::OK, "{}", again.body);
    let issued = setup.fake.calls(|c| c.refresh_tokens.clone());
    let stored = stored_refresh(&setup.admin).await;
    let grant = open_refresh_token(&key, stored[0].0, &stored[0].1).unwrap();
    assert_eq!(grant.refresh_token, issued[1]);
}

#[sqlx::test(migrations = false)]
async fn delete_revokes_at_apple(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;
    let up = native(&setup, "001.del", EC_KID, None).await;
    assert_eq!(up.status, StatusCode::OK, "{}", up.body);
    let token = token_of(&up.body).to_string();
    // A second Apple ID linked on the web: its token was issued to the Services ID.
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(hub, LINK, Some(&token), &hash, "b4app").await;
    let target = location(&apple_posts(&setup, &ceremony, &nonce_claim, "001.del2", None).await);
    let linked = redeem(hub, &handoff_in(&target, "b4app"), &verifier).await;
    assert_eq!(linked.status, StatusCode::OK, "{}", linked.body);
    let issued = setup.fake.calls(|c| c.refresh_tokens.clone());
    assert_eq!(issued.len(), 2);

    // Apple refuses: nothing is deleted.
    setup.fake.state.lock().unwrap().fail_revoke = true;
    let failed = authed(hub, "DELETE", "/v1/me", None, &token).await;
    assert_eq!(failed.code(), "internal_error", "{}", failed.body);
    assert_eq!(hub.get("/v1/me", Some(&token)).await.status, StatusCode::OK);
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 1);

    setup.fake.state.lock().unwrap().fail_revoke = false;
    setup.fake.state.lock().unwrap().calls.revoked.clear();
    let deleted = authed(hub, "DELETE", "/v1/me", None, &token).await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT, "{}", deleted.body);
    let mut revoked = setup.fake.calls(|c| c.revoked.clone());
    revoked.sort();
    let mut expected = vec![
        (BUNDLE_ID.to_string(), issued[0].clone()),
        (SERVICES_ID.to_string(), issued[1].clone()),
    ];
    expected.sort();
    assert_eq!(revoked, expected);
    assert_eq!(setup.fake.calls(|c| c.bad_secrets), 0);
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 0);
    assert_eq!(
        hub.get("/v1/me", Some(&token)).await.status,
        StatusCode::UNAUTHORIZED
    );
}

#[sqlx::test(migrations = false)]
async fn delete_with_a_token_that_does_not_open_revokes_nothing(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let up = native(&setup, "001.a", EC_KID, None).await;
    let token = token_of(&up.body).to_string();
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(&setup.hub, LINK, Some(&token), &hash, "b4app").await;
    let target = location(&apple_posts(&setup, &ceremony, &nonce_claim, "001.b", None).await);
    redeem(&setup.hub, &handoff_in(&target, "b4app"), &verifier).await;
    // The second row's sealed token is moved onto the first: it no longer opens there.
    let stored = stored_refresh(&setup.admin).await;
    sqlx::query("UPDATE user_identities SET apple_refresh_token_enc = $2 WHERE id = $1")
        .bind(stored[1].0)
        .bind(&stored[0].1)
        .execute(&setup.admin.pool)
        .await
        .unwrap();

    let failed = authed(&setup.hub, "DELETE", "/v1/me", None, &token).await;
    assert_eq!(failed.code(), "internal_error", "{}", failed.body);
    // The good token was not revoked either.
    assert!(setup.fake.calls(|c| c.revoked.is_empty()));
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 1);
}

#[sqlx::test(migrations = false)]
async fn delete_on_a_hub_without_apple_cannot_revoke_and_deletes_nothing(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let up = native(&setup, "001.later", EC_KID, None).await;
    let token = token_of(&up.body).to_string();
    // The same database, served later by a hub whose Apple configuration was removed.
    let mut config = common::config(Signup::Open);
    config.secret_key = setup.hub.state.config.secret_key;
    let bare = Hub::start(setup.hub.state.db.clone(), config).await;
    let failed = authed(&bare, "DELETE", "/v1/me", None, &token).await;
    assert_eq!(failed.code(), "internal_error", "{}", failed.body);
    assert_eq!(count(&pool, "SELECT count(*) FROM users").await, 1);
    assert!(setup.fake.calls(|c| c.revoked.is_empty()));
}

// ---- Linking ----

#[sqlx::test(migrations = false)]
async fn link_apple_to_passkey_account(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;
    let mut authenticator = Authenticator::new(ORIGIN);
    let begun = hub.post("/v1/auth/passkey/begin", None).await;
    let attestation = authenticator.register(&begun.body["registration"]);
    let session = hub
        .post(
            "/v1/auth/passkey/finish",
            Some(
                &json!({"ceremonyId": begun.body["ceremonyId"], "attestation": attestation,
                         "device": device("Brian's MacBook Pro", "macos")}),
            ),
        )
        .await;
    assert_eq!(session.status, StatusCode::OK, "{}", session.body);
    let token = token_of(&session.body).to_string();

    // The Mac links on the web: the callback links, and the handoff only confirms it.
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(hub, LINK, Some(&token), &hash, "b4app").await;
    let target = location(&apple_posts(&setup, &ceremony, &nonce_claim, "001.link", None).await);
    let handoff = handoff_in(&target, "b4app");
    let linked = redeem(hub, &handoff, &verifier).await;
    assert_eq!(linked.status, StatusCode::OK, "{}", linked.body);
    assert_eq!(linked.body, json!({"linked": true}));
    assert_eq!(count(&pool, "SELECT count(*) FROM device_tokens").await, 1);
    let me = hub.get("/v1/me", Some(&token)).await;
    let kinds: Vec<&str> = me.body["identities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["passkey", "apple"]);

    // Signing in with that Apple ID now reaches the passkey's account.
    let apple = native(&setup, "001.link", EC_KID, None).await;
    assert_eq!(apple.status, StatusCode::OK, "{}", apple.body);
    assert_eq!(apple.body["org"], session.body["org"]);
    assert_eq!(apple.body["user"], session.body["user"]);

    // The iPhone links natively; the answer is the new identity.
    let begun = authed(hub, "POST", LINK, Some(&json!({})), &token).await;
    assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
    let nonce = begun.body["nonce"].as_str().unwrap();
    let body = json!({
        "ceremonyId": begun.body["ceremonyId"],
        "identityToken": setup.fake.token("001.link2", BUNDLE_ID, Some(&sha256_hex(nonce))),
        "authorizationCode": setup.fake.code("001.link2", BUNDLE_ID, None),
    });
    let identity = authed(hub, "POST", LINK_NATIVE, Some(&body), &token).await;
    assert_eq!(identity.status, StatusCode::OK, "{}", identity.body);
    assert_eq!(identity.body["kind"], "apple");
    assert_eq!(identity.body["name"], "001.link2@privaterelay.appleid.com");

    // Another account cannot take an Apple ID that is already linked, and a sign-in ceremony
    // cannot finish a link (nor a link ceremony a sign-in).
    let other = native(&setup, "001.other", EC_KID, None).await;
    let other_token = token_of(&other.body).to_string();
    let begun = authed(hub, "POST", LINK, None, &other_token).await;
    let nonce = begun.body["nonce"].as_str().unwrap();
    let steal = json!({
        "ceremonyId": begun.body["ceremonyId"],
        "identityToken": setup.fake.token("001.link", BUNDLE_ID, Some(&sha256_hex(nonce))),
        "authorizationCode": setup.fake.code("001.link", BUNDLE_ID, None),
    });
    let refused = authed(hub, "POST", LINK_NATIVE, Some(&steal), &other_token).await;
    assert_eq!(refused.code(), "credential_rejected", "{}", refused.body);

    let (sign_in_ceremony, nonce) = begin_native(hub).await;
    let crossed = json!({
        "ceremonyId": sign_in_ceremony,
        "identityToken": setup.fake.token("001.x", BUNDLE_ID, Some(&sha256_hex(&nonce))),
        "authorizationCode": setup.fake.code("001.x", BUNDLE_ID, None),
    });
    let refused = authed(hub, "POST", LINK_NATIVE, Some(&crossed), &other_token).await;
    assert_eq!(refused.code(), "ceremony_expired", "{}", refused.body);

    let begun = authed(hub, "POST", LINK, None, &other_token).await;
    let nonce = begun.body["nonce"].as_str().unwrap();
    let crossed = json!({
        "ceremonyId": begun.body["ceremonyId"],
        "identityToken": setup.fake.token("001.y", BUNDLE_ID, Some(&sha256_hex(nonce))),
        "authorizationCode": setup.fake.code("001.y", BUNDLE_ID, None),
        "device": device("iPhone", "ios"),
    });
    let refused = hub.post(NATIVE, Some(&crossed)).await;
    assert_eq!(refused.code(), "ceremony_expired", "{}", refused.body);

    // Linking needs a device token.
    let anonymous = hub.post(LINK, Some(&json!({}))).await;
    assert_eq!(anonymous.status, StatusCode::UNAUTHORIZED);
}

// ---- Configuration and limits ----

#[sqlx::test(migrations = false)]
async fn routes_404_without_apple_config(pool: PgPool) {
    let (_admin, app) = common::migrated(&pool).await;
    let mut config = common::config(Signup::Open);
    config.public_url = Some(Url::parse(PUBLIC_URL).unwrap());
    let hub = Hub::start(app.clone(), config).await;

    let offered = hub.get("/v1/auth/config", None).await;
    assert_eq!(
        offered.body["apple"],
        json!({"native": false, "web": false})
    );

    let mut authenticator = Authenticator::new(ORIGIN);
    let begun = hub.post("/v1/auth/passkey/begin", None).await;
    let attestation = authenticator.register(&begun.body["registration"]);
    let session = hub
        .post(
            "/v1/auth/passkey/finish",
            Some(
                &json!({"ceremonyId": begun.body["ceremonyId"], "attestation": attestation,
                         "device": device("Mac", "macos")}),
            ),
        )
        .await;
    let token = token_of(&session.body).to_string();

    let answers = [
        hub.post(BEGIN, Some(&json!({}))).await,
        hub.post(NATIVE, Some(&json!({}))).await,
        hub.get(
            &format!("/v1/auth/apple/start?ceremony={}", Uuid::new_v4()),
            None,
        )
        .await,
        hub.post_form(CALLBACK, &[("state", "x")]).await,
        hub.post(HANDOFF, Some(&json!({}))).await,
        authed(&hub, "POST", LINK, Some(&json!({})), &token).await,
        authed(&hub, "POST", LINK_NATIVE, Some(&json!({})), &token).await,
    ];
    for answer in answers {
        assert_eq!(answer.status, StatusCode::NOT_FOUND, "{}", answer.body);
        assert_eq!(answer.code(), "not_found");
    }

    // Apple configured but no public URL: native only.
    let fake = FakeApple::start().await;
    let mut config = apple_config(&fake, Signup::Open);
    config.public_url = None;
    let native_only = Hub::start(app.clone(), config).await;
    let offered = native_only.get("/v1/auth/config", None).await;
    assert_eq!(offered.body["apple"], json!({"native": true, "web": false}));
    let (_, hash) = new_verifier();
    let web = native_only
        .post(
            BEGIN,
            Some(&json!({"verifierHash": hash, "scheme": "b4app"})),
        )
        .await;
    assert_eq!(web.code(), "not_found", "{}", web.body);
    assert_eq!(native_only.post(BEGIN, None).await.status, StatusCode::OK);

    // Without a Services ID: native only too.
    let mut config = apple_config(&fake, Signup::Open);
    config.apple.as_mut().unwrap().services_id = None;
    let no_services = Hub::start(app.clone(), config).await;
    let offered = no_services.get("/v1/auth/config", None).await;
    assert_eq!(offered.body["apple"], json!({"native": true, "web": false}));

    // Fully configured: both.
    let both = Hub::start(app, apple_config(&fake, Signup::Open)).await;
    let offered = both.get("/v1/auth/config", None).await;
    assert_eq!(offered.body["apple"], json!({"native": true, "web": true}));
}

fn assert_rate_limited(answer: &Answer) {
    assert_eq!(
        answer.status,
        StatusCode::TOO_MANY_REQUESTS,
        "{}",
        answer.body
    );
    assert_eq!(answer.code(), "rate_limited");
}

#[sqlx::test(migrations = false)]
async fn apple_routes_are_rate_limited(pool: PgPool) {
    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;
    for _ in 0..20 {
        assert_eq!(hub.post(BEGIN, None).await.status, StatusCode::OK);
    }
    assert_rate_limited(&hub.post(BEGIN, None).await);
    // `start` counts against the begin limit too.
    assert_rate_limited(
        &hub.get(
            &format!("/v1/auth/apple/start?ceremony={}", Uuid::new_v4()),
            None,
        )
        .await,
    );

    // `native`, `callback`, and `handoff` share the finish limit, counted before the body.
    for _ in 0..4 {
        assert_eq!(
            hub.post(NATIVE, Some(&json!({}))).await.code(),
            "invalid_request"
        );
    }
    for _ in 0..3 {
        hub.post_form(CALLBACK, &[]).await;
    }
    for _ in 0..3 {
        hub.post(HANDOFF, Some(&json!({}))).await;
    }
    assert_rate_limited(&hub.post(NATIVE, Some(&json!({}))).await);
    assert_rate_limited(&hub.post_form(CALLBACK, &[]).await);
    assert_rate_limited(&hub.post(HANDOFF, Some(&json!({}))).await);
}

// ---- Logging ----

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
    use tracing_subscriber::util::SubscriberInitExt;

    // The hub's own subscriber at the most verbose filter, installed as `main` installs it
    // (`init`, which also routes the `log` crate's records, such as reqwest's and rustls's,
    // into it), as the process-wide subscriber.
    let filter = Settings::from_pairs([("B4HUB_LOG", "trace")])
        .log_filter()
        .unwrap();
    let captured = Captured::default();
    b4hub::logging::subscriber(filter, captured.clone())
        .try_init()
        .expect("no other test in this binary sets a subscriber");

    let setup = setup(&pool, Signup::Open).await;
    let hub = &setup.hub;
    let mut secrets: Vec<String> = Vec::new();

    // Native sign-up and sign-in.
    for _ in 0..2 {
        let (ceremony, nonce) = begin_native(hub).await;
        let token = setup
            .fake
            .token("001.log", BUNDLE_ID, Some(&sha256_hex(&nonce)));
        let code = setup.fake.code("001.log", BUNDLE_ID, None);
        let answer = hub
            .post(
                NATIVE,
                Some(&json!({
                    "ceremonyId": ceremony, "identityToken": token, "authorizationCode": code,
                    "fullName": "Logan Log", "device": device("iPhone", "ios"),
                })),
            )
            .await;
        assert_eq!(answer.status, StatusCode::OK, "{}", answer.body);
        secrets.extend([token, code, nonce, token_of(&answer.body).to_string()]);
    }
    let token = secrets.last().unwrap().clone();

    // A web sign-in, with a refused attempt, and a web link.
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(hub, BEGIN, None, &hash, "b4app").await;
    let id_token = setup.fake.token("001.log", SERVICES_ID, Some(&nonce_claim));
    let code = setup.fake.code("001.log", SERVICES_ID, Some(CALLBACK_URL));
    let target = location(
        &hub.post_form(
            CALLBACK,
            &[
                ("state", &ceremony),
                ("code", &code),
                ("id_token", &id_token),
            ],
        )
        .await,
    );
    let handoff = handoff_in(&target, "b4app");
    assert_eq!(
        redeem(hub, &handoff, &b64(&random::<32>())).await.code(),
        "ceremony_expired"
    );
    let web = redeem(hub, &handoff, &verifier).await;
    assert_eq!(web.status, StatusCode::OK, "{}", web.body);
    secrets.extend([
        verifier.clone(),
        hash,
        id_token,
        code,
        handoff,
        token_of(&web.body).to_string(),
    ]);
    let (verifier, hash) = new_verifier();
    let (ceremony, nonce_claim) = begin_web(hub, LINK, Some(&token), &hash, "b4app").await;
    let target = location(&apple_posts(&setup, &ceremony, &nonce_claim, "001.log2", None).await);
    let handoff = handoff_in(&target, "b4app");
    assert_eq!(
        redeem(hub, &handoff, &verifier).await.status,
        StatusCode::OK
    );
    secrets.extend([verifier, hash, handoff]);

    // A token Apple's checks refuse.
    let (ceremony, nonce) = begin_native(hub).await;
    let refused = setup
        .fake
        .token("001.log", "com.example.other", Some(&sha256_hex(&nonce)));
    hub.post(
        NATIVE,
        Some(&json!({"ceremonyId": ceremony, "identityToken": refused,
                     "authorizationCode": "c.refused", "device": device("iPhone", "ios")})),
    )
    .await;
    secrets.push(refused);

    // Delete the account, revoking both refresh tokens.
    let deleted = authed(hub, "DELETE", "/v1/me", None, &token).await;
    assert_eq!(deleted.status, StatusCode::NO_CONTENT, "{}", deleted.body);
    secrets.extend(setup.fake.calls(|c| c.refresh_tokens.clone()));
    secrets.extend(setup.fake.calls(|c| c.client_secrets.clone()));
    assert!(setup.fake.calls(|c| c.client_secrets.len()) >= 5);
    for (_, sealed) in stored_refresh(&setup.admin).await {
        secrets.push(format!("{sealed:?}"));
    }

    let text = captured.text();
    for line in [
        "signed up with Apple",
        "signed in with Apple",
        "redeemed a handoff",
        "linked an Apple ID",
        "Apple verification failed",
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
    assert!(
        !text.contains("001.log"),
        "an Apple ID is in the log:\n{text}"
    );
}
