//! "Continue with Apple" and "Connect Apple ID": the native flow for the iPhone
//! (`POST /v1/auth/apple/begin`, `POST /v1/auth/apple/native`), the web flow for the Mac
//! (`GET /v1/auth/apple/start`, Apple's form post to `POST /v1/auth/apple/callback`, then
//! `POST /v1/auth/handoff`), and linking an Apple ID to the signed-in account
//! (`POST /v1/me/apple`, then `POST /v1/me/apple/native`, or the web flow ending in
//! `POST /v1/me/apple/handoff`).
//!
//! Every route answers `not_found` unless `B4HUB_APPLE_*` configures Sign in with Apple; the web
//! flow also needs `B4HUB_APPLE_SERVICES_ID` and `B4HUB_PUBLIC_URL`. A ceremony holds a random
//! nonce; Apple is handed its SHA-256 in hex, and the identity token must carry exactly that.
//! A web ceremony also holds the SHA-256 of a verifier the app keeps and the app's URL scheme
//! (one of [`SCHEMES`]): the callback redirects only to that scheme, never one from the request,
//! and the handoff it carries is redeemed only with the verifier. The callback changes no account
//! and exchanges no code: it records the verified result, sealed to the handoff, and everything
//! happens at the redemption (for a link, only from a device of the account that began it).
//! An account links at most one Apple ID (`apple_linked`).
//!
//! A new Apple ID signs up while sign-up is open (`signup_closed` otherwise, before the code is
//! exchanged, so Apple keeps no grant for it). Apple's email is stored with the identity but
//! never used to find or merge an account. Every failed check answers `credential_rejected`;
//! the log says why with a fixed reason, never a token, code, Apple ID, handoff, or verifier.

use std::fmt;
use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::{FromRequestParts, RawQuery, State};
use axum::http::request::Parts;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use b4hub_core::ids::new_uuid;
use b4hub_core::tokens::{hash_token, new_token};
use b4hub_db::accounts::{self, Identity, Principal};
use b4hub_db::ceremonies;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::apple::{
    open_pending, seal_pending, seal_refresh_token, sha256_hex, AppleClient, AppleError,
    AppleGrant, Claims, PendingApple, Tokens,
};
use crate::auth::AuthedDevice;
use crate::auth_limits::{BeginAllowed, FinishAllowed};
use crate::config::Signup;
use crate::error::{ApiError, ApiJson, OptionalJson};
use crate::routes::auth::{answer, AuthSession, DeviceRequest};
use crate::routes::me::{identity_json, MAX_FULL_NAME_CHARS};
use crate::serve::AppState;

/// The ceremony kind a sign-in (or sign-up) with Apple stores.
pub const APPLE_CEREMONY: &str = "apple";

/// The ceremony kind linking an Apple ID to a signed-in account stores; a sign-in's ceremony
/// cannot finish a link, nor a link's a sign-in.
pub const APPLE_LINK_CEREMONY: &str = "apple_link";

/// The URL schemes the web flow may hand a result back to: one per build flavour.
pub const SCHEMES: [&str; 3] = ["b4app", "b4app-beta", "b4app-local"];

/// The longest identity token and authorization code accepted, in bytes.
const MAX_TOKEN_BYTES: usize = 16 * 1024;
const MAX_CODE_BYTES: usize = 1024;

/// A verifier's length bounds, in characters (as PKCE's `code_verifier`).
const VERIFIER_CHARS: std::ops::RangeInclusive<usize> = 43..=128;

/// The path Apple posts back to, under `B4HUB_PUBLIC_URL`.
const CALLBACK_PATH: &str = "/v1/auth/apple/callback";

// ---- Wire types ----

/// `POST /v1/auth/apple/begin`'s and `POST /v1/me/apple`'s body, which may be empty. The web
/// flow sends both fields; the native flow neither.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AppleBeginRequest {
    /// The lowercase hex SHA-256 of a random verifier the app keeps for `POST /v1/auth/handoff`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verifier_hash: Option<String>,
    /// The app's URL scheme, one of [`SCHEMES`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheme: Option<String>,
}

/// The begin routes' answer. The native app passes `sha256_hex(nonce)` to Apple.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AppleBeginResponse {
    pub ceremony_id: Uuid,
    pub nonce: String,
}

/// `POST /v1/auth/apple/native`'s body. `fullName` is what Apple gave the app on the first
/// sign-in only. `Debug` leaves out the token and the code.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AppleNativeRequest {
    pub ceremony_id: Uuid,
    pub identity_token: String,
    pub authorization_code: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub full_name: Option<String>,
    pub device: DeviceRequest,
}

impl fmt::Debug for AppleNativeRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppleNativeRequest")
            .field("ceremony_id", &self.ceremony_id)
            .field("identity_token", &"<redacted>")
            .field("authorization_code", &"<redacted>")
            .field("device", &self.device)
            .finish_non_exhaustive()
    }
}

/// `POST /v1/me/apple/native`'s body. `Debug` leaves out the token and the code.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AppleLinkNativeRequest {
    pub ceremony_id: Uuid,
    pub identity_token: String,
    pub authorization_code: String,
}

impl fmt::Debug for AppleLinkNativeRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppleLinkNativeRequest")
            .field("ceremony_id", &self.ceremony_id)
            .finish_non_exhaustive()
    }
}

/// `POST /v1/auth/handoff`'s body: the code a sign-in's callback redirect carried, the verifier
/// whose hash the ceremony recorded, and the device to sign in. `Debug` leaves out the code and
/// the verifier.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct HandoffRequest {
    pub handoff: String,
    pub verifier: String,
    pub device: DeviceRequest,
}

impl fmt::Debug for HandoffRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HandoffRequest")
            .field("device", &self.device)
            .finish_non_exhaustive()
    }
}

/// `POST /v1/me/apple/handoff`'s body: the code a link's callback redirect carried, and the
/// verifier. `Debug` leaves both out.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AppleLinkHandoffRequest {
    pub handoff: String,
    pub verifier: String,
}

impl fmt::Debug for AppleLinkHandoffRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppleLinkHandoffRequest")
            .finish_non_exhaustive()
    }
}

/// What an Apple ceremony keeps between begin and finish, as the ceremony row's `state`.
#[derive(Serialize, Deserialize)]
struct AppleCeremony {
    /// Apple is handed its SHA-256 in hex.
    nonce: String,
    /// Present for the web flow.
    web: Option<WebFlow>,
    /// Present for a link: who began it.
    link: Option<LinkTo>,
}

#[derive(Serialize, Deserialize)]
struct WebFlow {
    /// The lowercase hex SHA-256 of the app's verifier.
    verifier_hash: String,
    /// One of [`SCHEMES`].
    scheme: String,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
struct LinkTo {
    org_id: Uuid,
    user_id: Uuid,
}

impl From<LinkTo> for Principal {
    fn from(link: LinkTo) -> Principal {
        Principal {
            org_id: link.org_id,
            user_id: link.user_id,
        }
    }
}

// ---- Extractors ----

/// The hub's Apple client; extracting it answers `not_found` on a hub without Sign in with
/// Apple, before anything else (a rate limit, a token, the body) is looked at.
pub struct Apple(pub Arc<AppleClient>);

impl FromRequestParts<AppState> for Apple {
    type Rejection = ApiError;

    async fn from_request_parts(_parts: &mut Parts, state: &AppState) -> Result<Apple, ApiError> {
        state
            .apple
            .clone()
            .map(Apple)
            .ok_or_else(ApiError::not_found)
    }
}

// ---- Begin ----

/// Whether this hub offers the web flow, and where Apple posts back to it.
pub fn callback_url(state: &AppState) -> Option<String> {
    let apple = state.apple.as_ref()?;
    apple.services_id()?;
    let public = state.config.public_url.as_ref()?;
    Some(format!(
        "{}{CALLBACK_PATH}",
        public.as_str().trim_end_matches('/')
    ))
}

/// The web flow a begin body asks for, validated; `None` for the native flow.
fn web_flow(state: &AppState, request: AppleBeginRequest) -> Result<Option<WebFlow>, ApiError> {
    match (request.verifier_hash, request.scheme) {
        (None, None) => Ok(None),
        (Some(verifier_hash), Some(scheme)) => {
            if verifier_hash.len() != 64
                || !verifier_hash
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(ApiError::invalid_request(
                    "verifierHash must be a SHA-256 in lowercase hex",
                ));
            }
            if !SCHEMES.contains(&scheme.as_str()) {
                return Err(ApiError::invalid_request(
                    "scheme must be one of b4app, b4app-beta, b4app-local",
                ));
            }
            if callback_url(state).is_none() {
                // This hub offers only the native flow (`apple.web` is false).
                return Err(ApiError::not_found());
            }
            Ok(Some(WebFlow {
                verifier_hash,
                scheme,
            }))
        }
        _ => Err(ApiError::invalid_request(
            "send verifierHash and scheme together, or neither",
        )),
    }
}

async fn create_ceremony(
    state: &AppState,
    kind: &str,
    web: Option<WebFlow>,
    link: Option<LinkTo>,
) -> Result<Json<AppleBeginResponse>, ApiError> {
    let nonce = new_token();
    let stored = serde_json::to_value(AppleCeremony {
        nonce: nonce.clone(),
        web,
        link,
    })
    .map_err(|error| {
        tracing::error!(%error, "could not serialise an Apple ceremony");
        ApiError::internal()
    })?;
    let ceremony_id = ceremonies::create(&state.db, kind, stored).await?;
    Ok(Json(AppleBeginResponse { ceremony_id, nonce }))
}

/// `POST /v1/auth/apple/begin`.
pub async fn begin(
    State(state): State<AppState>,
    _apple: Apple,
    _allowed: BeginAllowed,
    OptionalJson(request): OptionalJson<AppleBeginRequest>,
) -> Result<Json<AppleBeginResponse>, ApiError> {
    let web = web_flow(&state, request)?;
    create_ceremony(&state, APPLE_CEREMONY, web, None).await
}

/// `POST /v1/me/apple`: begins linking an Apple ID to the caller's account, natively or on the
/// web, as `POST /v1/auth/apple/begin` begins a sign-in.
pub async fn link_begin(
    State(state): State<AppState>,
    _apple: Apple,
    _allowed: BeginAllowed,
    device: AuthedDevice,
    OptionalJson(request): OptionalJson<AppleBeginRequest>,
) -> Result<Json<AppleBeginResponse>, ApiError> {
    let web = web_flow(&state, request)?;
    let link = LinkTo {
        org_id: device.org_id,
        user_id: device.user_id,
    };
    if accounts::has_apple_identity(&state.db, link.into()).await? {
        return Err(ApiError::apple_linked());
    }
    create_ceremony(&state, APPLE_LINK_CEREMONY, web, Some(link)).await
}

// ---- The native flow ----

/// `POST /v1/auth/apple/native`: verifies the identity token against the ceremony, exchanges
/// the code, and signs the Apple ID's account in, or signs up.
pub async fn native(
    State(state): State<AppState>,
    Apple(apple): Apple,
    _allowed: FinishAllowed,
    ApiJson(request): ApiJson<AppleNativeRequest>,
) -> Result<Json<AuthSession>, ApiError> {
    // Everything that can be refused without the ceremony is refused first.
    let device = request.device.validate()?;
    let full_name = full_name(request.full_name.as_deref())?;
    check_sizes(&request.identity_token, &request.authorization_code)?;

    let ceremony = take(&state, request.ceremony_id, APPLE_CEREMONY).await?;
    if ceremony.web.is_some() {
        tracing::info!(
            reason = "a web ceremony was finished natively",
            "Apple verification failed"
        );
        return Err(ApiError::ceremony_expired());
    }
    let claims = verify(&apple, &request.identity_token, &ceremony.nonce).await?;
    let client_id = claims.aud.clone();
    let principal = sign_in_or_up(
        &state,
        &apple,
        &claims,
        &request.authorization_code,
        &client_id,
        None,
        full_name.as_deref(),
    )
    .await?;
    let session =
        accounts::issue_session(&state.db, principal, device, request.device.device_id).await?;
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        device_id = %session.device_id,
        "issued a session for Apple's native flow"
    );
    answer(&state, principal, session.device_id, session.token)
        .await
        .map(Json)
}

/// `POST /v1/me/apple/native`: verifies the identity token against a link ceremony the caller
/// began and adds the Apple ID to their account; answers the identity.
pub async fn link_native(
    State(state): State<AppState>,
    Apple(apple): Apple,
    _allowed: FinishAllowed,
    device: AuthedDevice,
    ApiJson(request): ApiJson<AppleLinkNativeRequest>,
) -> Result<Json<Value>, ApiError> {
    check_sizes(&request.identity_token, &request.authorization_code)?;
    let principal = Principal::from(*device);
    let ceremony = take(&state, request.ceremony_id, APPLE_LINK_CEREMONY).await?;
    let began_here = ceremony
        .link
        .is_some_and(|link| Principal::from(link) == principal);
    if !began_here || ceremony.web.is_some() {
        // To this caller (or this flow) the ceremony does not exist.
        tracing::info!(
            reason = "the ceremony was begun by another user or for the web flow",
            "Apple verification failed"
        );
        return Err(ApiError::ceremony_expired());
    }
    let claims = verify(&apple, &request.identity_token, &ceremony.nonce).await?;
    let client_id = claims.aud.clone();
    let id = link(
        &state,
        &apple,
        principal,
        &claims,
        &request.authorization_code,
        &client_id,
        None,
    )
    .await?;
    identity_answer(&state, principal, id).await
}

// ---- The web flow ----

/// `GET /v1/auth/apple/start?ceremony=<id>`: a 302 to Apple's authorize page for a web
/// ceremony. It does not use the ceremony up, so a reloaded page starts again.
pub async fn start(
    State(state): State<AppState>,
    Apple(apple): Apple,
    _allowed: BeginAllowed,
    RawQuery(query): RawQuery,
) -> Result<Response, ApiError> {
    let mut ceremony_id = None;
    for (name, value) in url::form_urlencoded::parse(query.unwrap_or_default().as_bytes()) {
        match (name.as_ref(), ceremony_id) {
            ("ceremony", None) => {
                ceremony_id =
                    Some(Uuid::parse_str(&value).map_err(|_| {
                        ApiError::invalid_request("ceremony must be a ceremony id")
                    })?);
            }
            _ => {
                return Err(ApiError::invalid_request(
                    "the only query parameter is one ceremony",
                ))
            }
        }
    }
    let ceremony_id =
        ceremony_id.ok_or_else(|| ApiError::invalid_request("ceremony is required"))?;
    let redirect_uri = callback_url(&state).ok_or_else(ApiError::not_found)?;
    let (_, stored) = ceremonies::peek(
        &state.db,
        ceremony_id,
        &[APPLE_CEREMONY, APPLE_LINK_CEREMONY],
    )
    .await?;
    let ceremony = stored_ceremony(stored)?;
    if ceremony.web.is_none() {
        return Err(ApiError::ceremony_expired());
    }
    let url = apple
        .authorize_url(
            &redirect_uri,
            &ceremony_id.to_string(),
            &sha256_hex(&ceremony.nonce),
        )
        .ok_or_else(ApiError::not_found)?;
    Ok(redirect(url.as_str()))
}

/// The fields of Apple's form post the hub reads. Others are ignored: Apple may add fields.
#[derive(Default)]
struct CallbackForm {
    state: Option<String>,
    code: Option<String>,
    id_token: Option<String>,
    user: Option<String>,
    error: Option<String>,
}

impl CallbackForm {
    fn parse(body: &[u8]) -> Result<CallbackForm, ApiError> {
        let mut form = CallbackForm::default();
        for (name, value) in url::form_urlencoded::parse(body) {
            let slot = match name.as_ref() {
                "state" => &mut form.state,
                "code" => &mut form.code,
                "id_token" => &mut form.id_token,
                "user" => &mut form.user,
                "error" => &mut form.error,
                _ => continue,
            };
            if slot.is_some() {
                return Err(ApiError::invalid_request("a form field is repeated"));
            }
            *slot = Some(value.into_owned());
        }
        Ok(form)
    }

    /// The name in Apple's `user` field (first sign-in only), when it is a usable full name.
    fn name(&self) -> Option<String> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Name {
            first_name: Option<String>,
            last_name: Option<String>,
        }
        #[derive(Deserialize)]
        struct User {
            name: Option<Name>,
        }
        let user: User = serde_json::from_str(self.user.as_deref()?).ok()?;
        let name = user.name?;
        let joined = [name.first_name, name.last_name]
            .into_iter()
            .flatten()
            .map(|part| part.trim().to_string())
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        full_name(Some(&joined)).ok().flatten()
    }
}

/// `POST /v1/auth/apple/callback`: Apple's form post. Once the ceremony is known, every outcome
/// is a 302 to the ceremony's scheme: `<scheme>://auth?handoff=<code>` on success, or
/// `<scheme>://auth?error=<code>` (`cancelled` when the person cancelled on Apple's page). A post
/// whose ceremony is unknown, spent, or not a web one answers JSON, having nowhere to go.
pub async fn callback(
    State(state): State<AppState>,
    Apple(apple): Apple,
    _allowed: FinishAllowed,
    body: Bytes,
) -> Result<Response, ApiError> {
    let form = CallbackForm::parse(&body)?;
    callback_url(&state).ok_or_else(ApiError::not_found)?;
    let ceremony_id = form
        .state
        .as_deref()
        .ok_or_else(|| ApiError::invalid_request("state is required"))?;
    let ceremony_id = Uuid::parse_str(ceremony_id).map_err(|_| ApiError::ceremony_expired())?;
    let (kind, stored) = ceremonies::take_any(
        &state.db,
        ceremony_id,
        &[APPLE_CEREMONY, APPLE_LINK_CEREMONY],
    )
    .await?;
    let ceremony = stored_ceremony(stored)?;
    let Some(web) = &ceremony.web else {
        return Err(ApiError::ceremony_expired());
    };
    if !SCHEMES.contains(&web.scheme.as_str()) {
        tracing::error!("a stored Apple ceremony names a scheme outside the allow-list");
        return Err(ApiError::internal());
    }

    let outcome = match &form.error {
        Some(error) => {
            tracing::info!(
                reason = if error == "user_cancelled_authorize" {
                    "the person cancelled on Apple's page"
                } else {
                    "Apple answered an error"
                },
                "Apple sign-in did not finish"
            );
            Err(if error == "user_cancelled_authorize" {
                "cancelled"
            } else {
                "credential_rejected"
            })
        }
        None => finish_web(&state, &apple, &kind, ceremony_id, &ceremony, web, &form)
            .await
            .map_err(|error| error.code),
    };
    Ok(match outcome {
        Ok(handoff) => redirect(&format!("{}://auth?handoff={handoff}", web.scheme)),
        Err(code) => redirect(&format!("{}://auth?error={code}", web.scheme)),
    })
}

/// Verifies Apple's post for a web ceremony and records the handoff that carries the result,
/// sealed, to the app; answers its code. No account changes here and the code is not exchanged:
/// both happen when the app redeems the handoff with the verifier, so a browser that is not the
/// app's (a start URL forwarded to someone else, or a leaked ceremony id) achieves nothing.
async fn finish_web(
    state: &AppState,
    apple: &AppleClient,
    kind: &str,
    ceremony_id: Uuid,
    ceremony: &AppleCeremony,
    web: &WebFlow,
    form: &CallbackForm,
) -> Result<String, ApiError> {
    let (Some(code), Some(id_token)) = (&form.code, &form.id_token) else {
        tracing::info!(
            reason = "Apple's post has no code or identity token",
            "Apple verification failed"
        );
        return Err(ApiError::credential_rejected());
    };
    check_sizes(id_token, code).map_err(|_| ApiError::credential_rejected())?;
    let claims = verify(apple, id_token, &ceremony.nonce).await?;
    let services_id = apple.services_id().ok_or_else(ApiError::not_found)?;
    if claims.aud != services_id {
        tracing::info!(
            reason = "the identity token is not for the Services ID",
            "Apple verification failed"
        );
        return Err(ApiError::credential_rejected());
    }
    let owner = accounts::find_apple_identity(&state.db, &claims.sub).await?;
    let link = if kind == APPLE_LINK_CEREMONY {
        let to: Principal = ceremony
            .link
            .ok_or_else(|| {
                tracing::error!("a stored Apple link ceremony names no account");
                ApiError::internal()
            })?
            .into();
        check_linkable(state, to, owner).await?;
        Some(to)
    } else {
        // Refused early so the browser hears it; checked again at the redemption.
        if owner.is_none() && state.config.signup == Signup::Closed {
            tracing::info!("a new Apple ID was refused: sign-up is closed");
            return Err(ApiError::signup_closed());
        }
        None
    };
    let pending = PendingApple {
        sub: claims.sub,
        email: claims.email,
        name: if link.is_none() { form.name() } else { None },
        client_id: services_id.to_string(),
        code: code.clone(),
    };
    let verifier_hash = decode_hex(&web.verifier_hash).ok_or_else(|| {
        tracing::error!("a stored Apple ceremony's verifier hash is not hex");
        ApiError::internal()
    })?;
    let handoff = new_token();
    let sealed = seal_pending(&state.config.secret_key, &hash_token(&handoff), &pending).map_err(
        |error| {
            tracing::error!(%error, "could not seal an Apple handoff");
            ApiError::internal()
        },
    )?;
    ceremonies::create_apple_handoff(
        &state.db,
        &handoff,
        ceremony_id,
        link,
        &verifier_hash,
        &sealed,
    )
    .await?;
    tracing::info!("recorded an Apple handoff");
    Ok(handoff)
}

/// Checks a handoff request's code and verifier and answers their hashes.
fn handoff_hashes(handoff: &str, verifier: &str) -> Result<([u8; 32], [u8; 32]), ApiError> {
    if handoff.is_empty() || handoff.len() > 256 {
        return Err(ApiError::invalid_request(
            "handoff must be 1 to 256 characters",
        ));
    }
    if !VERIFIER_CHARS.contains(&verifier.chars().count())
        || !verifier
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~".contains(&b))
    {
        return Err(ApiError::invalid_request(
            "verifier must be 43 to 128 letters, digits, or -._~",
        ));
    }
    Ok((
        hash_token(handoff),
        Sha256::digest(verifier.as_bytes()).into(),
    ))
}

/// Redeems the Apple handoff `code_hash` once, for a ceremony of `kind` (and, for a link, the
/// account `link`), and opens what it carries. A live handoff presented to the wrong route or by
/// the wrong account is `credential_rejected` and stays redeemable where it belongs; an unknown,
/// expired, or spent one, or a wrong verifier, is `ceremony_expired`.
async fn redeem_pending(
    state: &AppState,
    code_hash: &[u8; 32],
    verifier_hash: &[u8; 32],
    kind: &str,
    link: Option<Principal>,
) -> Result<PendingApple, ApiError> {
    let sealed =
        match ceremonies::redeem_apple_handoff(&state.db, code_hash, verifier_hash, kind, link)
            .await
        {
            Err(b4hub_db::Error::CeremonyExpired) => {
                if ceremonies::handoff_is_live(&state.db, code_hash, verifier_hash).await? {
                    tracing::info!(
                        reason = "the handoff belongs to another route or account",
                        "Apple verification failed"
                    );
                    return Err(ApiError::credential_rejected());
                }
                return Err(ApiError::ceremony_expired());
            }
            other => other?,
        };
    open_pending(&state.config.secret_key, code_hash, &sealed).map_err(|error| {
        tracing::error!(%error, "a stored Apple handoff does not open");
        ApiError::internal()
    })
}

/// The claims a redeemed handoff carries, as the callback verified them.
fn pending_claims(pending: &PendingApple) -> Claims {
    Claims {
        sub: pending.sub.clone(),
        aud: pending.client_id.clone(),
        email: pending.email.clone(),
    }
}

/// `POST /v1/auth/handoff`: redeems a sign-in's handoff with the verifier, once; exchanges the
/// code, signs the Apple ID's account in or signs up, and answers the session for `device`. A
/// link's handoff is `credential_rejected` here (and stays redeemable at `POST /v1/me/apple/handoff`).
pub async fn handoff(
    State(state): State<AppState>,
    Apple(apple): Apple,
    _allowed: FinishAllowed,
    ApiJson(request): ApiJson<HandoffRequest>,
) -> Result<Json<AuthSession>, ApiError> {
    let device = request.device.validate()?;
    let (code_hash, verifier_hash) = handoff_hashes(&request.handoff, &request.verifier)?;
    let redirect_uri = callback_url(&state).ok_or_else(ApiError::not_found)?;
    let pending = redeem_pending(&state, &code_hash, &verifier_hash, APPLE_CEREMONY, None).await?;
    let principal = sign_in_or_up(
        &state,
        &apple,
        &pending_claims(&pending),
        &pending.code,
        &pending.client_id,
        Some(&redirect_uri),
        pending.name.as_deref(),
    )
    .await?;
    let session =
        accounts::issue_session(&state.db, principal, device, request.device.device_id).await?;
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        device_id = %session.device_id,
        "redeemed a handoff"
    );
    answer(&state, principal, session.device_id, session.token)
        .await
        .map(Json)
}

/// `POST /v1/me/apple/handoff`: redeems a link's handoff with the verifier, once, from a device
/// of the account that began the link; exchanges the code and adds the Apple ID. Answers the
/// identity.
pub async fn link_handoff(
    State(state): State<AppState>,
    Apple(apple): Apple,
    _allowed: FinishAllowed,
    device: AuthedDevice,
    ApiJson(request): ApiJson<AppleLinkHandoffRequest>,
) -> Result<Json<Value>, ApiError> {
    let principal = Principal::from(*device);
    let (code_hash, verifier_hash) = handoff_hashes(&request.handoff, &request.verifier)?;
    let redirect_uri = callback_url(&state).ok_or_else(ApiError::not_found)?;
    let pending = redeem_pending(
        &state,
        &code_hash,
        &verifier_hash,
        APPLE_LINK_CEREMONY,
        Some(principal),
    )
    .await?;
    let id = link(
        &state,
        &apple,
        principal,
        &pending_claims(&pending),
        &pending.code,
        &pending.client_id,
        Some(&redirect_uri),
    )
    .await?;
    identity_answer(&state, principal, id).await
}

async fn identity_answer(
    state: &AppState,
    principal: Principal,
    id: Uuid,
) -> Result<Json<Value>, ApiError> {
    let identity = accounts::list_identities(&state.db, principal)
        .await?
        .into_iter()
        .find(|identity| identity.id == id)
        .ok_or_else(ApiError::not_found)?;
    Ok(Json(identity_json(&identity)))
}

// ---- Shared ----

/// The account of `claims.sub`, signed in (its refresh token replaced with the exchange's), or,
/// for a new Apple ID while sign-up is open, a new account named `display_name` (the onboarding
/// prefill). The code is exchanged as `client_id`, after the sign-up policy is checked.
async fn sign_in_or_up(
    state: &AppState,
    apple: &AppleClient,
    claims: &Claims,
    code: &str,
    client_id: &str,
    redirect_uri: Option<&str>,
    display_name: Option<&str>,
) -> Result<Principal, ApiError> {
    if let Some((principal, identity_id)) =
        accounts::find_apple_identity(&state.db, &claims.sub).await?
    {
        let tokens = exchange(apple, code, client_id, redirect_uri, &claims.sub).await?;
        let sealed = seal(state, identity_id, client_id, tokens)?;
        accounts::record_apple_use(&state.db, identity_id, sealed.as_deref()).await?;
        tracing::info!(
            org_id = %principal.org_id,
            user_id = %principal.user_id,
            "signed in with Apple"
        );
        return Ok(principal);
    }
    if state.config.signup == Signup::Closed {
        tracing::info!("a new Apple ID was refused: sign-up is closed");
        return Err(ApiError::signup_closed());
    }
    let tokens = exchange(apple, code, client_id, redirect_uri, &claims.sub).await?;
    let identity_id = new_uuid();
    let refresh = tokens.refresh_token.clone();
    let identity = Identity::Apple {
        id: identity_id,
        sub: claims.sub.clone(),
        email: claims.email.clone(),
        refresh_enc: seal(state, identity_id, client_id, tokens)?,
    };
    match accounts::create_personal_with(&state.db, identity, display_name.unwrap_or(""), None)
        .await
    {
        Ok((principal, _)) => {
            tracing::info!(
                org_id = %principal.org_id,
                user_id = %principal.user_id,
                "signed up with Apple"
            );
            Ok(principal)
        }
        Err(b4hub_db::Error::IdentityTaken) => {
            // A concurrent sign-up with the same Apple ID won: this is a sign-in to it.
            let Some((principal, identity_id)) =
                accounts::find_apple_identity(&state.db, &claims.sub).await?
            else {
                return Err(ApiError::credential_rejected());
            };
            let tokens = Tokens {
                refresh_token: refresh,
            };
            let sealed = seal(state, identity_id, client_id, tokens)?;
            accounts::record_apple_use(&state.db, identity_id, sealed.as_deref()).await?;
            tracing::info!(
                org_id = %principal.org_id,
                user_id = %principal.user_id,
                "signed in with Apple"
            );
            Ok(principal)
        }
        Err(other) => Err(other.into()),
    }
}

/// Adds the Apple ID of `claims` to `principal`'s account and answers the identity's id; one
/// already theirs answers its id. One that belongs to another account is `credential_rejected`,
/// and any Apple ID while the account has another is `apple_linked`, both before the code is
/// exchanged.
async fn link(
    state: &AppState,
    apple: &AppleClient,
    principal: Principal,
    claims: &Claims,
    code: &str,
    client_id: &str,
    redirect_uri: Option<&str>,
) -> Result<Uuid, ApiError> {
    let owner = accounts::find_apple_identity(&state.db, &claims.sub).await?;
    if let Some((owner, id)) = owner {
        if owner == principal {
            return Ok(id);
        }
    }
    check_linkable(state, principal, owner).await?;
    let tokens = exchange(apple, code, client_id, redirect_uri, &claims.sub).await?;
    let identity_id = new_uuid();
    let identity = Identity::Apple {
        id: identity_id,
        sub: claims.sub.clone(),
        email: claims.email.clone(),
        refresh_enc: seal(state, identity_id, client_id, tokens)?,
    };
    let id = match accounts::add_apple_identity(&state.db, principal, identity).await {
        Err(b4hub_db::Error::IdentityTaken) => {
            tracing::info!(
                reason = "the Apple ID belongs to another account",
                "Apple verification failed"
            );
            return Err(ApiError::credential_rejected());
        }
        other => other?,
    };
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        identity_id = %id,
        "linked an Apple ID"
    );
    Ok(id)
}

/// Whether the Apple ID whose account is `owner` may be linked to `principal`: not when another
/// account holds it (`credential_rejected`), nor when `principal` already has an Apple ID
/// (`apple_linked`; one per account).
async fn check_linkable(
    state: &AppState,
    principal: Principal,
    owner: Option<(Principal, Uuid)>,
) -> Result<(), ApiError> {
    match owner {
        Some((owner, _)) if owner == principal => Ok(()),
        Some(_) => {
            tracing::info!(
                reason = "the Apple ID belongs to another account",
                "Apple verification failed"
            );
            Err(ApiError::credential_rejected())
        }
        None if accounts::has_apple_identity(&state.db, principal).await? => {
            Err(ApiError::apple_linked())
        }
        None => Ok(()),
    }
}

async fn verify(apple: &AppleClient, token: &str, nonce: &str) -> Result<Claims, ApiError> {
    apple
        .verify_identity_token(token, nonce)
        .await
        .map_err(|error| apple_failed(&error))
}

async fn exchange(
    apple: &AppleClient,
    code: &str,
    client_id: &str,
    redirect_uri: Option<&str>,
    sub: &str,
) -> Result<Tokens, ApiError> {
    apple
        .exchange_code(code, client_id, redirect_uri, sub)
        .await
        .map_err(|error| apple_failed(&error))
}

/// Logs why Apple's side failed (a fixed reason) and answers the deliberately vague
/// `credential_rejected`.
fn apple_failed(error: &AppleError) -> ApiError {
    match error {
        AppleError::Rejected(reason) => {
            tracing::info!(%reason, "Apple verification failed");
        }
        AppleError::Unavailable(reason) => {
            tracing::warn!(%reason, "Apple could not be asked");
        }
    }
    ApiError::credential_rejected()
}

/// The refresh token of `tokens`, sealed to the identity row `identity_id`.
fn seal(
    state: &AppState,
    identity_id: Uuid,
    client_id: &str,
    tokens: Tokens,
) -> Result<Option<Vec<u8>>, ApiError> {
    let Some(refresh_token) = tokens.refresh_token else {
        return Ok(None);
    };
    let grant = AppleGrant {
        client_id: client_id.to_string(),
        refresh_token,
    };
    seal_refresh_token(&state.config.secret_key, identity_id, &grant)
        .map(Some)
        .map_err(|error| {
            tracing::error!(%error, "could not seal an Apple refresh token");
            ApiError::internal()
        })
}

async fn take(state: &AppState, id: Uuid, kind: &str) -> Result<AppleCeremony, ApiError> {
    let stored = ceremonies::take(&state.db, id, kind).await?;
    stored_ceremony(stored)
}

fn stored_ceremony(stored: Value) -> Result<AppleCeremony, ApiError> {
    serde_json::from_value(stored).map_err(|error| {
        tracing::error!(%error, "a stored Apple ceremony does not deserialise");
        ApiError::internal()
    })
}

/// A full name as Apple gave it: trimmed, `None` when empty, at most 200 characters.
fn full_name(name: Option<&str>) -> Result<Option<String>, ApiError> {
    let Some(name) = name.map(str::trim).filter(|name| !name.is_empty()) else {
        return Ok(None);
    };
    if name.chars().count() > MAX_FULL_NAME_CHARS {
        return Err(ApiError::invalid_request(
            "fullName must be at most 200 characters",
        ));
    }
    Ok(Some(name.to_string()))
}

fn check_sizes(identity_token: &str, code: &str) -> Result<(), ApiError> {
    if identity_token.len() > MAX_TOKEN_BYTES || code.len() > MAX_CODE_BYTES {
        return Err(ApiError::invalid_request(
            "identityToken or authorizationCode is too long",
        ));
    }
    Ok(())
}

fn decode_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(text.get(at..at + 2)?, 16).ok())
        .collect()
}

/// A 302 to `location`, never cached.
fn redirect(location: &str) -> Response {
    let mut response = StatusCode::FOUND.into_response();
    match HeaderValue::from_str(location) {
        Ok(value) => {
            response.headers_mut().insert(header::LOCATION, value);
            response
                .headers_mut()
                .insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
            response
        }
        Err(_) => {
            tracing::error!("a redirect location is not a header value");
            ApiError::internal().into_response()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_decodes_only_hex() {
        assert_eq!(decode_hex("00ff10"), Some(vec![0, 255, 16]));
        assert_eq!(decode_hex("0"), None);
        assert_eq!(decode_hex("zz"), None);
    }

    #[test]
    fn apple_user_field_gives_a_full_name() {
        let form = |user: &str| CallbackForm {
            user: Some(user.into()),
            ..CallbackForm::default()
        };
        assert_eq!(
            form(r#"{"name":{"firstName":" Bea ","lastName":"Beta"},"email":"b@x"}"#).name(),
            Some("Bea Beta".into())
        );
        assert_eq!(
            form(r#"{"name":{"firstName":"Bea"}}"#).name(),
            Some("Bea".into())
        );
        assert_eq!(form(r#"{"email":"b@x"}"#).name(), None);
        assert_eq!(form("not json").name(), None);
        let long = format!(r#"{{"name":{{"firstName":"{}"}}}}"#, "x".repeat(201));
        assert_eq!(form(&long).name(), None);
        assert_eq!(CallbackForm::default().name(), None);
    }

    #[test]
    fn a_repeated_field_is_refused() {
        assert!(CallbackForm::parse(b"state=a&state=b").is_err());
        let form = CallbackForm::parse(b"state=a&code=c&id_token=t&extra=x").unwrap();
        assert_eq!(form.state.as_deref(), Some("a"));
    }
}
