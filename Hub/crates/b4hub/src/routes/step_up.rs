//! Step-up (D-150): adding or removing a sign-in method and deleting the account need proof that
//! the signed-in user just finished an assertion on the device that asks, not only its token. The
//! device earns a grant here with a passkey (`POST /v1/me/step-up/passkey/begin`, then `/finish`)
//! or in [`crate::routes::apple`] with an Apple ID (`POST /v1/me/step-up/apple`, then `/native` or
//! `/handoff`), and sends it once, within two minutes, in the [`STEP_UP_HEADER`] of the change.
//! An account that can no longer assert (its only passkey gone from the keychain) earns one with an
//! operator's enrollment code instead (`POST /v1/me/step-up/code`); a pairing code never counts.
//!
//! A grant is bound to the user and the device whose token earned it, stored only as its hash, and
//! taken once. A missing, unknown, expired, spent, or another device's grant is `403
//! step_up_required` with `details.methods`, the kinds of identity the account can assert with. An
//! account with no identity at all (operator-enrolled, never signed in) has nothing to assert with
//! and passes on its token alone, as before. The grant, the assertion, and the challenges are never
//! logged.

use std::fmt;

use axum::extract::{FromRequestParts, State};
use axum::http::request::Parts;
use axum::Json;
use b4hub_db::accounts::{self, Principal};
use b4hub_db::{ceremonies, devices};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;
use webauthn_rs::prelude::{
    Passkey, PasskeyAuthentication, PublicKeyCredential, RequestChallengeResponse,
};

use crate::auth::AuthedDevice;
use crate::auth_limits::{BeginAllowed, FinishAllowed};
use crate::error::{ApiError, ApiJson};
use crate::maintenance::WritesAllowed;
use crate::routes::auth::{internal, parse, rejected};
use crate::serve::AppState;

/// The header a gated change carries its grant in.
pub const STEP_UP_HEADER: &str = "b4-step-up";

/// The ceremony kind a passkey step-up stores; no other ceremony can finish one.
pub const STEP_UP_PASSKEY_CEREMONY: &str = "step_up_passkey";

/// The longest grant accepted in the header, in bytes (a grant is 43).
const MAX_GRANT_LEN: usize = 128;

// ---- Wire types ----

/// `POST /v1/me/step-up/passkey/begin`'s answer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StepUpBeginResponse {
    pub ceremony_id: Uuid,
    pub authentication: RequestChallengeResponse,
}

/// `POST /v1/me/step-up/passkey/finish`'s body. `Debug` leaves out the assertion.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StepUpFinishRequest {
    pub ceremony_id: Uuid,
    pub assertion: Value,
}

impl fmt::Debug for StepUpFinishRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StepUpFinishRequest")
            .field("ceremony_id", &self.ceremony_id)
            .field("assertion", &"<redacted>")
            .finish()
    }
}

/// `POST /v1/me/step-up/code`'s body: an operator's enrollment code. `Debug` leaves out the code.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StepUpCodeRequest {
    pub code: String,
}

impl fmt::Debug for StepUpCodeRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StepUpCodeRequest")
            .field("code", &"<redacted>")
            .finish()
    }
}

/// What every step-up finish answers. `stepUp` is in this response and nowhere else; `Debug`
/// leaves it out.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct StepUpResponse {
    pub step_up: String,
    pub expires_at: String,
}

impl fmt::Debug for StepUpResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StepUpResponse")
            .field("step_up", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// What a passkey step-up keeps between begin and finish: who began it, on which device, and
/// webauthn-rs's state (which holds the challenge and the allowed credentials).
#[derive(Serialize, Deserialize)]
struct StepUpCeremony {
    org_id: Uuid,
    user_id: Uuid,
    device_id: Uuid,
    authentication: PasskeyAuthentication,
}

// ---- The grant a change carries ----

/// The [`STEP_UP_HEADER`] of a request, unread until the handler calls [`StepUp::require`], so
/// refusals that need no grant (`not_found`, `last_identity`, `apple_linked`, `shared_org`) come
/// first and spend nothing.
pub struct StepUp(Option<String>);

impl FromRequestParts<AppState> for StepUp {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _state: &AppState) -> Result<StepUp, ApiError> {
        let grant = parts
            .headers
            .get(STEP_UP_HEADER)
            .and_then(|value| value.to_str().ok())
            .map(str::trim)
            .filter(|grant| !grant.is_empty() && grant.len() <= MAX_GRANT_LEN)
            .map(str::to_string);
        Ok(StepUp(grant))
    }
}

impl StepUp {
    /// Takes the grant for `device`, once; `step_up_required` unless it is live and was earned by
    /// this user on this device. An account with no identity passes without one.
    pub async fn require(self, state: &AppState, device: &AuthedDevice) -> Result<(), ApiError> {
        let principal = Principal::from(**device);
        let methods = methods(state, principal).await?;
        if methods.is_empty() {
            return Ok(());
        }
        if let Some(grant) = &self.0 {
            if ceremonies::take_step_up(&state.db, grant, principal, device.device_id).await? {
                return Ok(());
            }
        }
        tracing::info!(
            user_id = %principal.user_id,
            device_id = %device.device_id,
            presented = self.0.is_some(),
            "a change was refused: it needs a step-up"
        );
        Err(step_up_required(&methods))
    }
}

/// The kinds of identity `principal` can step up with, `passkey` before `apple`, each once.
async fn methods(state: &AppState, principal: Principal) -> Result<Vec<&'static str>, ApiError> {
    let identities = accounts::list_identities(&state.db, principal).await?;
    Ok(["passkey", "apple"]
        .into_iter()
        .filter(|kind| identities.iter().any(|identity| identity.kind == *kind))
        .collect())
}

/// `403 step_up_required`, naming the kinds the account can assert with.
pub fn step_up_required(methods: &[&str]) -> ApiError {
    let mut error = ApiError::step_up_required();
    error.extra.insert("methods".into(), json!(methods));
    error
}

/// Records the grant a finished step-up of `method` earned for `device`, and answers it.
pub(crate) async fn grant(
    state: &AppState,
    device: &AuthedDevice,
    method: &str,
) -> Result<Json<StepUpResponse>, ApiError> {
    let principal = Principal::from(**device);
    let grant = ceremonies::create_step_up(&state.db, principal, device.device_id, method).await?;
    tracing::info!(
        user_id = %principal.user_id,
        device_id = %device.device_id,
        method,
        "stepped up"
    );
    Ok(Json(StepUpResponse {
        step_up: grant.token,
        expires_at: grant.expires_at,
    }))
}

// ---- The passkey step-up ----

/// `POST /v1/me/step-up/passkey/begin`: assertion options for one of the caller's own passkeys
/// (`allowCredentials` lists them; user verification required). An account with none is
/// `not_found`.
pub async fn passkey_begin(
    State(state): State<AppState>,
    _allowed: BeginAllowed,
    device: AuthedDevice,
    _writes: WritesAllowed,
) -> Result<Json<StepUpBeginResponse>, ApiError> {
    let principal = Principal::from(*device);
    let passkeys = accounts::passkeys(&state.db, principal)
        .await?
        .into_iter()
        .map(|(_, stored)| {
            serde_json::from_value::<Passkey>(stored).map_err(|error| {
                tracing::error!(%error, "a stored passkey does not deserialise");
                ApiError::internal()
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    if passkeys.is_empty() {
        return Err(ApiError::not_found());
    }
    let (mut authentication, auth_state) =
        state
            .webauthn
            .start_passkey_authentication(&passkeys)
            .map_err(|error| internal("starting a step-up assertion", &error))?;
    authentication.mediation = None;
    let ceremony = StepUpCeremony {
        org_id: principal.org_id,
        user_id: principal.user_id,
        device_id: device.device_id,
        authentication: auth_state,
    };
    let stored = serde_json::to_value(&ceremony).map_err(|error| {
        tracing::error!(%error, "could not serialise a step-up ceremony");
        ApiError::internal()
    })?;
    let ceremony_id = ceremonies::create(&state.db, STEP_UP_PASSKEY_CEREMONY, stored).await?;
    Ok(Json(StepUpBeginResponse {
        ceremony_id,
        authentication,
    }))
}

/// `POST /v1/me/step-up/passkey/finish`: verifies the assertion against a step-up the same user
/// began on this device, with one of their passkeys; answers the grant.
pub async fn passkey_finish(
    State(state): State<AppState>,
    _allowed: FinishAllowed,
    device: AuthedDevice,
    _writes: WritesAllowed,
    ApiJson(request): ApiJson<StepUpFinishRequest>,
) -> Result<Json<StepUpResponse>, ApiError> {
    let principal = Principal::from(*device);
    let assertion: PublicKeyCredential = parse(request.assertion)?;
    let stored = ceremonies::take(&state.db, request.ceremony_id, STEP_UP_PASSKEY_CEREMONY).await?;
    let ceremony: StepUpCeremony = serde_json::from_value(stored).map_err(|error| {
        tracing::error!(%error, "a stored step-up ceremony does not deserialise");
        ApiError::internal()
    })?;
    if ceremony.org_id != principal.org_id
        || ceremony.user_id != principal.user_id
        || ceremony.device_id != device.device_id
    {
        // To this device the ceremony does not exist.
        tracing::info!(
            reason = "the step-up was begun by another user or device",
            "passkey verification failed"
        );
        return Err(ApiError::ceremony_expired());
    }
    let result = state
        .webauthn
        .finish_passkey_authentication(&assertion, &ceremony.authentication)
        .map_err(|error| rejected(&error))?;
    // The allow-list held only this user's passkeys, but the stored row is what is updated.
    let Some((owner, stored)) =
        accounts::find_by_credential(&state.db, result.cred_id().as_slice()).await?
    else {
        tracing::info!(
            reason = "the passkey was removed during the step-up",
            "passkey verification failed"
        );
        return Err(ApiError::credential_rejected());
    };
    if owner != principal {
        tracing::info!(
            reason = "the passkey is another account's",
            "passkey verification failed"
        );
        return Err(ApiError::credential_rejected());
    }
    let mut passkey: Passkey = serde_json::from_value(stored.passkey).map_err(|error| {
        tracing::error!(%error, "a stored passkey does not deserialise");
        ApiError::internal()
    })?;
    let updated = match passkey.update_credential(&result) {
        Some(true) => Some(serde_json::to_value(&passkey).map_err(|error| {
            tracing::error!(%error, "could not serialise a passkey");
            ApiError::internal()
        })?),
        _ => None,
    };
    accounts::record_passkey_use(&state.db, stored.identity_id, updated.as_ref()).await?;
    grant(&state, &device, "passkey").await
}

// ---- The operator's code ----

/// `POST /v1/me/step-up/code`: takes, once, an operator's enrollment code (`b4hub enroll`) issued
/// for the caller's own user, and answers the grant. For an account that can no longer assert: its
/// only passkey gone from the keychain. A pairing code (one a Mac minted) never counts, nor does an
/// unknown, expired, used, or another user's code: each is `401 invalid_code` and changes nothing.
pub async fn code(
    State(state): State<AppState>,
    _allowed: FinishAllowed,
    device: AuthedDevice,
    _writes: WritesAllowed,
    ApiJson(request): ApiJson<StepUpCodeRequest>,
) -> Result<Json<StepUpResponse>, ApiError> {
    let principal = Principal::from(*device);
    if !devices::take_operator_code(&state.db, &request.code, principal).await? {
        tracing::info!(
            user_id = %principal.user_id,
            device_id = %device.device_id,
            "a step-up code was refused"
        );
        return Err(ApiError::invalid_code());
    }
    grant(&state, &device, "code").await
}
