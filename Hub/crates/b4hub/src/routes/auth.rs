//! Signing in and signing up: `GET /v1/auth/config` and "Continue with a passkey"
//! (`POST /v1/auth/passkey/begin`, `POST /v1/auth/passkey/finish`). No bearer token; the
//! credential is the passkey.
//!
//! One ceremony serves both a sign-in and a sign-up: begin answers discoverable assertion
//! options (no allow-list, so the OS offers any passkey for the relying party) and, while
//! sign-up is open, registration options for a new user. Finish verifies whichever response the
//! client sends, then signs the passkey's account in, or creates the account. The ceremony is
//! stored in the database, so any hub instance can finish one another began, and is taken once.
//!
//! The WebAuthn responses, the challenges, and the token are never logged; a failed
//! verification logs only webauthn-rs's fixed reason text.

use std::fmt;

use axum::extract::State;
use axum::Json;
use b4hub_db::accounts::{self, DeviceSpec, Identity, Principal};
use b4hub_db::ceremonies;
use b4hub_db::devices::Platform;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;
use webauthn_rs::prelude::{
    CreationChallengeResponse, DiscoverableAuthentication, Passkey, PasskeyRegistration,
    PublicKeyCredential, RegisterPublicKeyCredential, RequestChallengeResponse,
};
use webauthn_rs_proto::{
    AuthenticatorSelectionCriteria, ResidentKeyRequirement, UserVerificationPolicy,
};

use crate::auth_limits::{BeginAllowed, FinishAllowed};
use crate::config::Signup;
use crate::error::{ApiError, ApiJson};
use crate::routes::enroll::MAX_DEVICE_NAME_CHARS;
use crate::serve::AppState;

/// The ceremony kind passkey sign-ins store.
pub const PASSKEY_CEREMONY: &str = "passkey";

/// The name and display name a new passkey is registered with. The client renames it to the
/// person's full name after onboarding; it is also the identity's name until then.
pub const ACCOUNT_LABEL: &str = "Agent Workspace account";

// ---- Wire types ----

/// The device a sign-in is for. `deviceId`, when it names an unrevoked device of the signing-in
/// user on the same platform, is reused (and renamed); otherwise a new device is made.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct DeviceRequest {
    pub device_name: String,
    pub platform: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<Uuid>,
}

impl DeviceRequest {
    fn validate(&self) -> Result<DeviceSpec, ApiError> {
        let name = self.device_name.trim();
        if name.is_empty() || name.chars().count() > MAX_DEVICE_NAME_CHARS {
            return Err(ApiError::invalid_request(
                "deviceName must be 1 to 200 characters",
            ));
        }
        let platform = Platform::parse(&self.platform)
            .ok_or_else(|| ApiError::invalid_request("platform must be one of macos, ios, cli"))?;
        Ok(DeviceSpec {
            name: name.to_string(),
            platform,
        })
    }
}

/// `POST /v1/auth/passkey/finish`'s body: the ceremony, exactly one of the authenticator's
/// `assertion` (sign in) or `attestation` (sign up), and the device. `Debug` leaves out the
/// responses.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PasskeyFinishRequest {
    pub ceremony_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assertion: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attestation: Option<Value>,
    pub device: DeviceRequest,
}

impl fmt::Debug for PasskeyFinishRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PasskeyFinishRequest")
            .field("ceremony_id", &self.ceremony_id)
            .field("assertion", &self.assertion.as_ref().map(|_| "<redacted>"))
            .field(
                "attestation",
                &self.attestation.as_ref().map(|_| "<redacted>"),
            )
            .field("device", &self.device)
            .finish()
    }
}

/// `GET /v1/auth/config`: what this hub offers, so a client hides the rest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AuthConfigResponse {
    pub passkeys: PasskeysOffered,
    pub apple: AppleOffered,
    pub signup: Signup,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PasskeysOffered {
    pub rp_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppleOffered {
    pub native: bool,
    pub web: bool,
}

/// `POST /v1/auth/passkey/begin`'s answer. `registration` is absent while sign-up is closed.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PasskeyBeginResponse {
    pub ceremony_id: Uuid,
    pub authentication: RequestChallengeResponse,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration: Option<CreationChallengeResponse>,
}

/// What every route that signs a device in answers: the enrollment shape plus whether the user
/// still has to onboard. `token` is in this response and nowhere else; `Debug` leaves it out.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AuthSession {
    pub device_id: Uuid,
    pub token: String,
    pub org: OrgRef,
    pub user: UserRef,
    pub needs_onboarding: bool,
}

impl fmt::Debug for AuthSession {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AuthSession")
            .field("device_id", &self.device_id)
            .field("token", &"<redacted>")
            .field("org", &self.org)
            .field("user", &self.user)
            .field("needs_onboarding", &self.needs_onboarding)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OrgRef {
    pub slug: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct UserRef {
    pub username: String,
    pub display_name: String,
}

/// What a passkey ceremony keeps between begin and finish (webauthn-rs's own state, which holds
/// the challenges), as the ceremony row's `state`.
#[derive(Serialize, Deserialize)]
struct PasskeyCeremony {
    authentication: DiscoverableAuthentication,
    /// Present when sign-up was open at begin, with the new user's handle.
    registration: Option<(PasskeyRegistration, Uuid)>,
}

// ---- Handlers ----

pub async fn config(State(state): State<AppState>) -> Json<AuthConfigResponse> {
    Json(AuthConfigResponse {
        passkeys: PasskeysOffered {
            rp_id: state.config.rp_id.clone(),
        },
        // Sign in with Apple's routes are not built yet (sign-in plan Task 13), so the hub does
        // not offer it whatever B4HUB_APPLE_* says.
        apple: AppleOffered {
            native: false,
            web: false,
        },
        signup: state.config.signup,
    })
}

pub async fn passkey_begin(
    State(state): State<AppState>,
    _allowed: BeginAllowed,
) -> Result<Json<PasskeyBeginResponse>, ApiError> {
    let (mut authentication, auth_state) = state
        .webauthn
        .start_discoverable_authentication()
        .map_err(|error| internal("starting a passkey assertion", &error))?;
    // The client runs a modal request when the person presses the button, not autofill.
    authentication.mediation = None;

    let (registration, reg_state) = match state.config.signup {
        Signup::Closed => (None, None),
        Signup::Open => {
            let handle = Uuid::new_v4();
            let (mut options, reg_state) = state
                .webauthn
                .start_passkey_registration(handle, ACCOUNT_LABEL, ACCOUNT_LABEL, None)
                .map_err(|error| internal("starting a passkey registration", &error))?;
            // A sign-in finds the account from the credential alone, so it must be discoverable.
            options.public_key.authenticator_selection = Some(AuthenticatorSelectionCriteria {
                authenticator_attachment: None,
                resident_key: Some(ResidentKeyRequirement::Required),
                require_resident_key: true,
                user_verification: UserVerificationPolicy::Required,
            });
            (Some(options), Some((reg_state, handle)))
        }
    };

    let ceremony = PasskeyCeremony {
        authentication: auth_state,
        registration: reg_state,
    };
    let stored = serde_json::to_value(&ceremony).map_err(|error| {
        tracing::error!(%error, "could not serialise a passkey ceremony");
        ApiError::internal()
    })?;
    let ceremony_id = ceremonies::create(&state.db, PASSKEY_CEREMONY, stored).await?;
    Ok(Json(PasskeyBeginResponse {
        ceremony_id,
        authentication,
        registration,
    }))
}

pub async fn passkey_finish(
    State(state): State<AppState>,
    _allowed: FinishAllowed,
    ApiJson(request): ApiJson<PasskeyFinishRequest>,
) -> Result<Json<AuthSession>, ApiError> {
    // Everything that can be refused without the ceremony is refused first, so a malformed
    // request does not use it up.
    let device = request.device.validate()?;
    let response = match (request.assertion, request.attestation) {
        (Some(assertion), None) => Response::Assertion(parse(assertion)?),
        (None, Some(attestation)) => {
            if state.config.signup == Signup::Closed {
                return Err(ApiError::signup_closed());
            }
            Response::Attestation(parse(attestation)?)
        }
        _ => {
            return Err(ApiError::invalid_request(
                "send exactly one of assertion or attestation",
            ))
        }
    };

    let stored = ceremonies::take(&state.db, request.ceremony_id, PASSKEY_CEREMONY).await?;
    let ceremony: PasskeyCeremony = serde_json::from_value(stored).map_err(|error| {
        tracing::error!(%error, "a stored passkey ceremony does not deserialise");
        ApiError::internal()
    })?;

    match response {
        Response::Assertion(assertion) => {
            sign_in(
                &state,
                ceremony,
                &assertion,
                device,
                request.device.device_id,
            )
            .await
        }
        Response::Attestation(attestation) => sign_up(&state, ceremony, &attestation, device).await,
    }
    .map(Json)
}

enum Response {
    Assertion(PublicKeyCredential),
    Attestation(RegisterPublicKeyCredential),
}

/// Reads an authenticator response; one that is not even well formed fails verification.
fn parse<T: serde::de::DeserializeOwned>(value: Value) -> Result<T, ApiError> {
    serde_json::from_value(value).map_err(|_| {
        tracing::info!(
            reason = "the response is not a WebAuthn credential",
            "passkey verification failed"
        );
        ApiError::credential_rejected()
    })
}

async fn sign_in(
    state: &AppState,
    ceremony: PasskeyCeremony,
    assertion: &PublicKeyCredential,
    device: DeviceSpec,
    reuse: Option<Uuid>,
) -> Result<AuthSession, ApiError> {
    let (user_handle, credential_id) = state
        .webauthn
        .identify_discoverable_authentication(assertion)
        .map_err(|error| rejected(&error))?;
    let Some((principal, stored)) = accounts::find_by_credential(&state.db, credential_id).await?
    else {
        tracing::info!(
            reason = "no account has this credential",
            "passkey verification failed"
        );
        return Err(ApiError::credential_rejected());
    };
    if stored.user_handle != user_handle.as_bytes() {
        tracing::info!(
            reason = "the user handle is not the credential's",
            "passkey verification failed"
        );
        return Err(ApiError::credential_rejected());
    }
    let mut passkey: Passkey = serde_json::from_value(stored.passkey).map_err(|error| {
        tracing::error!(%error, "a stored passkey does not deserialise");
        ApiError::internal()
    })?;
    let result = state
        .webauthn
        .finish_discoverable_authentication_v2(assertion, ceremony.authentication, &passkey)
        .map_err(|error| rejected(&error))?;

    let updated = match passkey.update_credential(&result) {
        Some(true) => Some(serde_json::to_value(&passkey).map_err(|error| {
            tracing::error!(%error, "could not serialise a passkey");
            ApiError::internal()
        })?),
        _ => None,
    };
    accounts::record_passkey_use(&state.db, stored.identity_id, updated.as_ref()).await?;
    let session = accounts::issue_session(&state.db, principal, device, reuse).await?;
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        device_id = %session.device_id,
        "signed in with a passkey"
    );
    answer(state, principal, session.device_id, session.token).await
}

async fn sign_up(
    state: &AppState,
    ceremony: PasskeyCeremony,
    attestation: &RegisterPublicKeyCredential,
    device: DeviceSpec,
) -> Result<AuthSession, ApiError> {
    // Begun while sign-up was closed: there are no registration options to finish against.
    let Some((registration, user_handle)) = ceremony.registration else {
        return Err(ApiError::ceremony_expired());
    };
    let passkey = state
        .webauthn
        .finish_passkey_registration(attestation, &registration)
        .map_err(|error| rejected(&error))?;
    let identity = Identity::Passkey {
        credential_id: passkey.cred_id().to_vec(),
        passkey_json: serde_json::to_value(&passkey).map_err(|error| {
            tracing::error!(%error, "could not serialise a passkey");
            ApiError::internal()
        })?,
        user_handle: user_handle.as_bytes().to_vec(),
        name: ACCOUNT_LABEL.to_string(),
    };
    let created = match accounts::create_personal(&state.db, identity, device).await {
        Err(b4hub_db::Error::IdentityTaken) => {
            tracing::info!(
                reason = "the credential already belongs to an account",
                "passkey verification failed"
            );
            return Err(ApiError::credential_rejected());
        }
        other => other?,
    };
    let principal = Principal {
        org_id: created.org_id,
        user_id: created.user_id,
    };
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        device_id = %created.device_id,
        "signed up with a passkey"
    );
    answer(state, principal, created.device_id, created.token).await
}

async fn answer(
    state: &AppState,
    principal: Principal,
    device_id: Uuid,
    token: String,
) -> Result<AuthSession, ApiError> {
    let Some(summary) = accounts::account_summary(&state.db, principal).await? else {
        // The account was deleted between the sign-in and this read.
        tracing::warn!(user_id = %principal.user_id, "a signed-in account vanished");
        return Err(ApiError::credential_rejected());
    };
    Ok(AuthSession {
        device_id,
        token,
        org: OrgRef {
            slug: summary.org_slug,
            name: summary.org_name,
        },
        user: UserRef {
            username: summary.username,
            display_name: summary.display_name,
        },
        needs_onboarding: !summary.onboarded,
    })
}

/// A failed verification: logged with webauthn-rs's reason (fixed text, never request data),
/// answered with the deliberately vague `credential_rejected`.
fn rejected(error: &webauthn_rs::prelude::WebauthnError) -> ApiError {
    tracing::info!(reason = %error, "passkey verification failed");
    ApiError::credential_rejected()
}

fn internal(what: &str, error: &webauthn_rs::prelude::WebauthnError) -> ApiError {
    tracing::error!(reason = %error, "{what} failed");
    ApiError::internal()
}
