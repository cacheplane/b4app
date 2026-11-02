//! The signed-in account's own routes, all behind a device token: `GET /v1/me` (the device, its
//! org and user, and the account's sign-in methods), `PUT /v1/me/profile` (onboarding's full
//! name), adding a passkey (`POST /v1/me/passkeys/begin`, `POST /v1/me/passkeys/finish`),
//! unlinking a sign-in method (`DELETE /v1/me/identities/{id}`; linking an Apple ID is in
//! [`crate::routes::apple`]), logging out
//! (`DELETE /v1/sessions/self`), and deleting the account (`DELETE /v1/me`).
//!
//! The principal is always the token's; nothing in a body names a user. An identity is listed
//! with its id, kind, name, and timestamps only: never a credential id, a passkey's stored
//! state, an Apple `sub`, or a refresh token.

use std::fmt;

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::Json;
use b4hub_db::accounts::{self, Deletion, Identity, IdentitySummary, Principal, SealedAppleTokens};
use b4hub_db::{ceremonies, devices};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;
use webauthn_rs::prelude::{
    CreationChallengeResponse, PasskeyRegistration, RegisterPublicKeyCredential,
};

use crate::apple::open_refresh_token;
use crate::auth::{bearer_token, AuthedDevice};
use crate::auth_limits::{BeginAllowed, FinishAllowed};
use crate::error::{ApiError, ApiJson};
use crate::routes::auth::{parse, rejected, start_registration, ACCOUNT_LABEL};
use crate::serve::AppState;

/// The ceremony kind adding a passkey stores; a sign-in's ceremony cannot finish an add.
pub const ADD_PASSKEY_CEREMONY: &str = "passkey_add";

/// The longest full name accepted, in characters after trimming.
pub const MAX_FULL_NAME_CHARS: usize = 200;

/// How many times deleting an account revokes newly found Apple tokens and tries again before
/// giving up (each round only happens when an Apple ID was linked during the one before).
const DELETE_ROUNDS: usize = 3;

// ---- Wire types ----

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ProfileRequest {
    pub full_name: String,
}

/// `POST /v1/me/passkeys/begin`'s answer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AddPasskeyBeginResponse {
    pub ceremony_id: Uuid,
    pub registration: CreationChallengeResponse,
}

/// `POST /v1/me/passkeys/finish`'s body. `Debug` leaves out the attestation.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AddPasskeyFinishRequest {
    pub ceremony_id: Uuid,
    pub attestation: Value,
}

impl fmt::Debug for AddPasskeyFinishRequest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AddPasskeyFinishRequest")
            .field("ceremony_id", &self.ceremony_id)
            .field("attestation", &"<redacted>")
            .finish()
    }
}

/// What adding a passkey keeps between begin and finish: who began it, the user handle, and
/// webauthn-rs's registration state.
#[derive(Serialize, Deserialize)]
struct AddPasskeyCeremony {
    org_id: Uuid,
    user_id: Uuid,
    user_handle: Uuid,
    registration: PasskeyRegistration,
}

// ---- Handlers ----

/// `GET /v1/me`.
pub async fn me(
    State(state): State<AppState>,
    device: AuthedDevice,
) -> Result<Json<Value>, ApiError> {
    describe(&state, &device).await.map(Json)
}

/// `PUT /v1/me/profile`: stores the full name, marks the user onboarded, and renames their
/// personal org; answers as `GET /v1/me`.
pub async fn profile(
    State(state): State<AppState>,
    device: AuthedDevice,
    ApiJson(request): ApiJson<ProfileRequest>,
) -> Result<Json<Value>, ApiError> {
    let name = request.full_name.trim();
    if name.is_empty() || name.chars().count() > MAX_FULL_NAME_CHARS {
        return Err(ApiError::invalid_request(
            "fullName must be 1 to 200 characters",
        ));
    }
    accounts::update_profile(&state.db, Principal::from(*device), name).await?;
    describe(&state, &device).await.map(Json)
}

/// `POST /v1/me/passkeys/begin`: registration options for another passkey of the signed-in
/// user, excluding the passkeys they have.
pub async fn passkey_begin(
    State(state): State<AppState>,
    _allowed: BeginAllowed,
    device: AuthedDevice,
) -> Result<Json<AddPasskeyBeginResponse>, ApiError> {
    let principal = Principal::from(*device);
    let existing = accounts::passkey_credentials(&state.db, principal).await?;
    // The user's passkeys share one user handle, the first one's; an account with none (made
    // with Apple, or enrolled by an operator) gets a fresh one.
    let user_handle = existing
        .first()
        .and_then(|passkey| Uuid::from_slice(&passkey.user_handle).ok())
        .unwrap_or_else(Uuid::new_v4);
    let exclude = existing
        .into_iter()
        .map(|passkey| passkey.credential_id)
        .collect();
    let (registration, reg_state) = start_registration(&state, user_handle, exclude)?;

    let ceremony = AddPasskeyCeremony {
        org_id: principal.org_id,
        user_id: principal.user_id,
        user_handle,
        registration: reg_state,
    };
    let stored = serde_json::to_value(&ceremony).map_err(|error| {
        tracing::error!(%error, "could not serialise a passkey ceremony");
        ApiError::internal()
    })?;
    let ceremony_id = ceremonies::create(&state.db, ADD_PASSKEY_CEREMONY, stored).await?;
    Ok(Json(AddPasskeyBeginResponse {
        ceremony_id,
        registration,
    }))
}

/// `POST /v1/me/passkeys/finish`: verifies the attestation against a ceremony the same user
/// began and adds the passkey; answers the new identity.
pub async fn passkey_finish(
    State(state): State<AppState>,
    _allowed: FinishAllowed,
    device: AuthedDevice,
    ApiJson(request): ApiJson<AddPasskeyFinishRequest>,
) -> Result<Json<Value>, ApiError> {
    let principal = Principal::from(*device);
    let attestation: RegisterPublicKeyCredential = parse(request.attestation)?;
    let stored = ceremonies::take(&state.db, request.ceremony_id, ADD_PASSKEY_CEREMONY).await?;
    let ceremony: AddPasskeyCeremony = serde_json::from_value(stored).map_err(|error| {
        tracing::error!(%error, "a stored passkey ceremony does not deserialise");
        ApiError::internal()
    })?;
    if ceremony.org_id != principal.org_id || ceremony.user_id != principal.user_id {
        // To this user the ceremony does not exist.
        tracing::info!(
            reason = "the ceremony was begun by another user",
            "passkey verification failed"
        );
        return Err(ApiError::ceremony_expired());
    }

    let passkey = state
        .webauthn
        .finish_passkey_registration(&attestation, &ceremony.registration)
        .map_err(|error| rejected(&error))?;
    let identity = Identity::Passkey {
        credential_id: passkey.cred_id().to_vec(),
        passkey_json: serde_json::to_value(&passkey).map_err(|error| {
            tracing::error!(%error, "could not serialise a passkey");
            ApiError::internal()
        })?,
        user_handle: ceremony.user_handle.as_bytes().to_vec(),
        name: ACCOUNT_LABEL.to_string(),
    };
    let id = match accounts::add_identity(&state.db, principal, identity).await {
        Err(b4hub_db::Error::IdentityTaken) => {
            tracing::info!(
                reason = "the credential already belongs to an account",
                "passkey verification failed"
            );
            return Err(ApiError::credential_rejected());
        }
        other => other?,
    };
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        identity_id = %id,
        "added a passkey"
    );
    let added = accounts::list_identities(&state.db, principal)
        .await?
        .into_iter()
        .find(|identity| identity.id == id)
        // Removed again between the insert and this read.
        .ok_or_else(ApiError::not_found)?;
    Ok(Json(identity_json(&added)))
}

/// `DELETE /v1/me/identities/{id}`: unlinks one of the caller's sign-in methods. An id that is
/// not one of theirs (or not an id) is `not_found`; their last one is `last_identity`.
pub async fn remove_identity(
    State(state): State<AppState>,
    device: AuthedDevice,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let id = Uuid::parse_str(&id).map_err(|_| ApiError::not_found())?;
    let principal = Principal::from(*device);
    if !accounts::remove_identity(&state.db, principal, id).await? {
        return Err(ApiError::not_found());
    }
    tracing::info!(
        org_id = %principal.org_id,
        user_id = %principal.user_id,
        identity_id = %id,
        "removed a sign-in method"
    );
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /v1/sessions/self`: log out. Deletes the presented token only; the device stays
/// enrolled and unrevoked, so signing back in with its id reuses it.
pub async fn end_session(
    State(state): State<AppState>,
    device: AuthedDevice,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    // The extractor just verified this header.
    let token = bearer_token(&headers).ok_or_else(ApiError::unauthorized)?;
    devices::end_session(&state.db, token).await?;
    tracing::info!(device_id = %device.device_id, "ended a session");
    Ok(StatusCode::NO_CONTENT)
}

/// `DELETE /v1/me`: deletes the account. Every stored Apple refresh token is opened first, and
/// only when all of them open is each revoked at Apple; a token that does not open revokes
/// nothing, and a failed revoke deletes nothing, and either fails the request so it can be
/// retried. Then the user, their tokens, identities, devices, and every row of their personal
/// org go in one transaction. An account in a shared org is `shared_org`, before anything is
/// revoked.
pub async fn delete_me(
    State(state): State<AppState>,
    device: AuthedDevice,
) -> Result<StatusCode, ApiError> {
    let principal = Principal::from(*device);
    let mut to_revoke = accounts::apple_tokens_to_revoke(&state.db, principal).await?;
    let mut revoked = SealedAppleTokens::default();
    for _ in 0..DELETE_ROUNDS {
        let grants = to_revoke
            .0
            .iter()
            .map(|token| {
                open_refresh_token(&state.config.secret_key, token.identity_id, &token.sealed)
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(|error| {
                tracing::error!(%error, user_id = %principal.user_id, "deleting an account failed");
                ApiError::internal()
            })?;
        for grant in &grants {
            state.apple_revoker.revoke(grant).await.map_err(|error| {
                tracing::error!(%error, user_id = %principal.user_id, "deleting an account failed");
                ApiError::internal()
            })?;
        }
        revoked.0.extend(to_revoke.0);
        match accounts::delete_user(&state.db, principal, &revoked).await? {
            Deletion::Deleted => {
                tracing::info!(
                    org_id = %principal.org_id,
                    user_id = %principal.user_id,
                    "deleted an account"
                );
                return Ok(StatusCode::NO_CONTENT);
            }
            Deletion::Unrevoked(more) => to_revoke = more,
        }
    }
    tracing::error!(
        user_id = %principal.user_id,
        "deleting an account failed: Apple IDs kept being linked while it was deleted"
    );
    Err(ApiError::internal())
}

// ---- Shapes ----

/// `GET /v1/me`'s answer for `device`: the enrollment-era fields unchanged, plus the user's full
/// name, whether they have onboarded, and their identities.
async fn describe(state: &AppState, device: &AuthedDevice) -> Result<Value, ApiError> {
    // The device was valid a moment ago; if it is gone now it was revoked in between.
    let info = devices::me(&state.db, device.org_id, device.device_id)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    let identities = accounts::list_identities(&state.db, Principal::from(**device)).await?;
    Ok(json!({
        "deviceId": info.device_id.to_string(),
        "deviceName": info.device_name,
        "platform": info.platform,
        "org": { "slug": info.org_slug, "name": info.org_name },
        "user": {
            "username": info.username,
            "displayName": info.display_name,
            "fullName": info.full_name,
        },
        "createdAt": info.created_at,
        "onboarded": info.onboarded,
        "identities": identities.iter().map(identity_json).collect::<Vec<_>>(),
    }))
}

pub(crate) fn identity_json(identity: &IdentitySummary) -> Value {
    json!({
        "id": identity.id.to_string(),
        "kind": identity.kind,
        "name": identity.name,
        "createdAt": identity.created_at,
        "lastUsedAt": identity.last_used_at,
    })
}
