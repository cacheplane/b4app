//! Sign in with Apple's side of the hub: verifying identity tokens against Apple's key set, the
//! client secret, the authorization code exchange, revoking a refresh token, and sealing the
//! refresh tokens the hub keeps so that deleting an account can revoke them.
//!
//! Apple's endpoints are `{base}/auth/keys`, `/auth/token`, `/auth/revoke`, and the browser's
//! `/auth/authorize`, under `B4HUB_APPLE_BASE_URL` (tests only; `https://appleid.apple.com`
//! otherwise). An identity token's issuer must be that base URL without its trailing slash, so
//! production checks `https://appleid.apple.com` and a test's fake Apple issues its own URL.
//!
//! **Identity tokens** are verified with the key their header's `kid` names in Apple's key set.
//! The key decides the algorithm: Apple publishes RSA keys (`RS256`), and an EC P-256 key
//! (`ES256`) is accepted too; a header whose `alg` is not its key's is refused. The key set is
//! cached and fetched again only for an unknown `kid`, at most once a minute. The token's `iss`,
//! `aud` (one of `B4HUB_APPLE_AUDIENCES`), `exp` (60 s leeway), and `nonce` are checked: the
//! nonce must be the lowercase hex SHA-256 of the ceremony's nonce, in both flows (the native
//! app and the web flow's authorize URL both hand Apple that hash).
//!
//! **The client secret** is an ES256 JWT signed with the `.p8` key, minted for each call:
//! `iss` the team id, `sub` the client id in use, `aud` `https://appleid.apple.com`, five
//! minutes to `exp`, and the key id as the header's `kid`.
//!
//! **A sealed refresh token** is AES-256-GCM under `B4HUB_SECRET_KEY`: a random 96-bit nonce,
//! then the ciphertext and its 16-byte tag. The plaintext is the client id the token was issued
//! to and the token (revoking needs both), as JSON; the associated data is the id of the
//! identity row that stores it, so a sealed token copied to another row does not open. The web
//! flow's pending handoff ([`PendingApple`]) is sealed the same way, with the handoff code's
//! hash as the associated data.
//!
//! Neither a token, a code, a client secret, nor a sealed or opened refresh token is ever
//! logged; every failure carries a fixed reason.

use std::collections::HashMap;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use jsonwebtoken::jwk::{AlgorithmParameters, EllipticCurve, Jwk};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio::sync::Mutex;
use url::Url;
use uuid::Uuid;

use crate::cli::ConfigError;
use crate::config::AppleConfig;

/// The nonce length of a sealed token, in bytes.
const NONCE_LEN: usize = 12;

/// The client secret's audience, which Apple requires literally.
pub const CLIENT_SECRET_AUDIENCE: &str = "https://appleid.apple.com";

/// How long a client secret is valid. Each call mints its own.
pub const CLIENT_SECRET_TTL: Duration = Duration::from_secs(5 * 60);

/// An unknown `kid` fetches the key set again at most this often.
pub const JWKS_REFETCH_INTERVAL: Duration = Duration::from_secs(60);

/// How far past `exp` an identity token is still accepted, for clock skew.
const LEEWAY_SECS: u64 = 60;

/// Each call to Apple gives up after this long.
const HTTP_TIMEOUT: Duration = Duration::from_secs(10);

/// The most of an Apple answer the hub reads.
const MAX_ANSWER_BYTES: usize = 64 * 1024;

/// What a query value is percent-encoded against: everything but RFC 3986's unreserved
/// characters, so a space is `%20` (never `+`).
const QUERY_VALUE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

/// The lowercase hex SHA-256 of `text`: what Apple is handed for a ceremony's nonce, and what a
/// client sends for its verifier.
pub fn sha256_hex(text: &str) -> String {
    hex(&Sha256::digest(text.as_bytes()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

// ---- Errors ----

/// Why Apple refused, or could not be asked. The text is fixed, never a token or Apple's answer.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AppleError {
    /// A token or code did not verify, or Apple refused it.
    #[error("{0}")]
    Rejected(&'static str),
    /// Apple could not be reached, or answered something unusable.
    #[error("{0}")]
    Unavailable(&'static str),
}

/// Revoking an Apple refresh token failed; the account must not be deleted. The text is fixed,
/// never Apple's answer or the token.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RevokeError {
    #[error("revoking an Apple refresh token failed: {0}")]
    Failed(&'static str),
}

// ---- What Apple's answers carry ----

/// What a verified identity token says. `Debug` shows only the audience.
#[derive(Clone, PartialEq, Eq)]
pub struct Claims {
    /// The Apple ID, stable for this team.
    pub sub: String,
    /// The client id the token is for: the iOS bundle id (native) or the Services ID (web).
    pub aud: String,
    /// The (often relay) email, when the token carries one. Stored, never used to merge.
    pub email: Option<String>,
}

impl fmt::Debug for Claims {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Claims")
            .field("aud", &self.aud)
            .finish_non_exhaustive()
    }
}

/// What the code exchange gave the hub to keep. `Debug` leaves the token out.
#[derive(Clone, PartialEq, Eq)]
pub struct Tokens {
    pub refresh_token: Option<String>,
}

impl fmt::Debug for Tokens {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Tokens")
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "<redacted>"),
            )
            .finish()
    }
}

/// A refresh token and the client id Apple issued it to, as the hub seals it. `Debug` leaves
/// the token out.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppleGrant {
    pub client_id: String,
    pub refresh_token: String,
}

impl fmt::Debug for AppleGrant {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppleGrant")
            .field("client_id", &self.client_id)
            .field("refresh_token", &"<redacted>")
            .finish()
    }
}

// ---- Revoking ----

/// Revokes an Apple refresh token at Apple (`/auth/revoke`). [`AppleClient`] is the real one;
/// a test may record calls instead. Implement it with
/// `async fn revoke(&self, grant: &AppleGrant) -> Result<(), RevokeError>`; the trait spells
/// the future out only to require that it is `Send`, as axum's handlers need.
pub trait AppleRevoker: Send + Sync + 'static {
    fn revoke(&self, grant: &AppleGrant) -> impl Future<Output = Result<(), RevokeError>> + Send;
}

/// [`AppleRevoker`] made object safe, so [`crate::serve::AppState`] can hold any revoker. Every
/// `AppleRevoker` is one.
pub trait ErasedAppleRevoker: Send + Sync {
    fn revoke<'a>(
        &'a self,
        grant: &'a AppleGrant,
    ) -> Pin<Box<dyn Future<Output = Result<(), RevokeError>> + Send + 'a>>;
}

impl<T: AppleRevoker> ErasedAppleRevoker for T {
    fn revoke<'a>(
        &'a self,
        grant: &'a AppleGrant,
    ) -> Pin<Box<dyn Future<Output = Result<(), RevokeError>> + Send + 'a>> {
        Box::pin(AppleRevoker::revoke(self, grant))
    }
}

/// The revoker of a hub without Sign in with Apple. No route stores a refresh token then, but an
/// account may still hold one from when Apple was configured; it cannot be revoked, so deleting
/// that account fails rather than pretend.
#[derive(Debug, Clone, Copy, Default)]
pub struct UnconfiguredRevoker;

impl AppleRevoker for UnconfiguredRevoker {
    async fn revoke(&self, _grant: &AppleGrant) -> Result<(), RevokeError> {
        Err(RevokeError::Failed(
            "Sign in with Apple is not configured on this hub",
        ))
    }
}

// ---- The client ----

/// A key from Apple's key set, with the one algorithm it verifies.
#[derive(Clone)]
struct KnownKey {
    algorithm: Algorithm,
    key: DecodingKey,
}

#[derive(Default)]
struct KeyCache {
    keys: HashMap<String, KnownKey>,
    /// When the key set was last fetched (or a fetch was last tried).
    fetched_at: Option<Instant>,
}

/// Talks to Apple for one hub: built from [`AppleConfig`] at start. Cheap to share behind an
/// `Arc`; the key set cache is shared by every request.
pub struct AppleClient {
    http: reqwest::Client,
    base_url: Url,
    issuer: String,
    team_id: String,
    key_id: String,
    signing_key: EncodingKey,
    audiences: Vec<String>,
    services_id: Option<String>,
    jwks: Mutex<KeyCache>,
}

impl fmt::Debug for AppleClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppleClient")
            .field("base_url", &self.base_url.as_str())
            .field("team_id", &self.team_id)
            .field("key_id", &self.key_id)
            .field("audiences", &self.audiences)
            .field("services_id", &self.services_id)
            .finish_non_exhaustive()
    }
}

impl AppleClient {
    /// The client for `config`. A private key that does not sign is a configuration error
    /// naming `B4HUB_APPLE_PRIVATE_KEY`; the key itself is never echoed.
    pub fn new(config: &AppleConfig) -> Result<AppleClient, ConfigError> {
        let bad_key = || {
            ConfigError::new(
                "B4HUB_APPLE_PRIVATE_KEY",
                "is not a P-256 private key (the .p8 file's PEM contents)",
            )
        };
        let signing_key =
            EncodingKey::from_ec_pem(config.private_key_pem.as_bytes()).map_err(|_| bad_key())?;
        let http = reqwest::Client::builder()
            .timeout(HTTP_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| {
                ConfigError::new(
                    "B4HUB_APPLE_BASE_URL",
                    "could not build an HTTPS client for Apple",
                )
            })?;
        let client = AppleClient {
            http,
            issuer: config.base_url.as_str().trim_end_matches('/').to_string(),
            base_url: config.base_url.clone(),
            team_id: config.team_id.clone(),
            key_id: config.key_id.clone(),
            signing_key,
            audiences: config.audiences.clone(),
            services_id: config.services_id.clone(),
            jwks: Mutex::new(KeyCache::default()),
        };
        // The PEM parses lazily; signing once proves the key is usable before `serve` starts.
        client
            .client_secret("b4hub.startup-check")
            .map_err(|_| bad_key())?;
        Ok(client)
    }

    /// The issuer identity tokens must name: the base URL without its trailing slash.
    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    /// The Services ID the web flow signs in with, when `B4HUB_APPLE_SERVICES_ID` is set.
    pub fn services_id(&self) -> Option<&str> {
        self.services_id.as_deref()
    }

    /// Apple's authorize page for the web flow: the Services ID, `redirect_uri`, an identity
    /// token and a code posted back as a form, the name and email scopes, `state`, and
    /// `nonce_claim` (the hashed ceremony nonce). `None` without a Services ID.
    pub fn authorize_url(&self, redirect_uri: &str, state: &str, nonce_claim: &str) -> Option<Url> {
        let client_id = self.services_id.as_deref()?;
        let query = [
            ("client_id", client_id),
            ("redirect_uri", redirect_uri),
            ("response_type", "code id_token"),
            ("response_mode", "form_post"),
            ("scope", "name email"),
            ("state", state),
            ("nonce", nonce_claim),
        ]
        .iter()
        .map(|(name, value)| format!("{name}={}", utf8_percent_encode(value, QUERY_VALUE)))
        .collect::<Vec<_>>()
        .join("&");
        let mut url = self.endpoint("auth/authorize").ok()?;
        url.set_query(Some(&query));
        Some(url)
    }

    /// Verifies `token`, an identity token from Apple, for a ceremony whose nonce is `nonce`:
    /// its signature against Apple's key set, `iss`, `aud` (any configured audience), `exp`, and
    /// that its `nonce` claim is `sha256_hex(nonce)`.
    pub async fn verify_identity_token(
        &self,
        token: &str,
        nonce: &str,
    ) -> Result<Claims, AppleError> {
        self.verify(token, &self.audiences, Some(&sha256_hex(nonce)))
            .await
    }

    /// Exchanges an authorization code Apple issued to `client_id` (with the web flow's
    /// `redirect_uri`) for the tokens the hub keeps. Apple's answer must carry an identity token,
    /// for `client_id` and for the Apple ID `sub` (the one the caller already verified), so a
    /// code for another Apple ID cannot attach its refresh token to this one.
    pub async fn exchange_code(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: Option<&str>,
        sub: &str,
    ) -> Result<Tokens, AppleError> {
        #[derive(Deserialize)]
        struct TokenAnswer {
            refresh_token: Option<String>,
            id_token: Option<String>,
        }

        let secret = self.client_secret(client_id)?;
        let mut form = vec![
            ("client_id", client_id),
            ("client_secret", secret.as_str()),
            ("code", code),
            ("grant_type", "authorization_code"),
        ];
        if let Some(uri) = redirect_uri {
            form.push(("redirect_uri", uri));
        }
        let (status, body) = self.post_form("auth/token", &form).await?;
        if status == reqwest::StatusCode::BAD_REQUEST {
            return Err(AppleError::Rejected("Apple refused the authorization code"));
        }
        if status != reqwest::StatusCode::OK {
            return Err(AppleError::Unavailable("Apple's token endpoint failed"));
        }
        let answer: TokenAnswer = serde_json::from_slice(&body)
            .map_err(|_| AppleError::Unavailable("Apple's token answer is not JSON"))?;
        let id_token = answer.id_token.ok_or(AppleError::Rejected(
            "Apple's token answer has no identity token",
        ))?;
        let claims = self
            .verify(&id_token, &[client_id.to_string()], None)
            .await?;
        if claims.sub != sub {
            return Err(AppleError::Rejected(
                "the authorization code is for another Apple ID",
            ));
        }
        Ok(Tokens {
            refresh_token: answer.refresh_token,
        })
    }

    /// Revokes `grant` at Apple.
    pub async fn revoke_grant(&self, grant: &AppleGrant) -> Result<(), RevokeError> {
        let secret = self
            .client_secret(&grant.client_id)
            .map_err(|_| RevokeError::Failed("the client secret could not be signed"))?;
        let form = [
            ("client_id", grant.client_id.as_str()),
            ("client_secret", secret.as_str()),
            ("token", grant.refresh_token.as_str()),
            ("token_type_hint", "refresh_token"),
        ];
        let (status, _) = self
            .post_form("auth/revoke", &form)
            .await
            .map_err(|_| RevokeError::Failed("Apple could not be reached"))?;
        if status == reqwest::StatusCode::OK {
            Ok(())
        } else {
            Err(RevokeError::Failed("Apple refused to revoke the token"))
        }
    }

    /// A client secret for `client_id`, valid for [`CLIENT_SECRET_TTL`].
    fn client_secret(&self, client_id: &str) -> Result<String, AppleError> {
        #[derive(Serialize)]
        struct SecretClaims<'a> {
            iss: &'a str,
            iat: u64,
            exp: u64,
            aud: &'a str,
            sub: &'a str,
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let claims = SecretClaims {
            iss: &self.team_id,
            iat: now,
            exp: now + CLIENT_SECRET_TTL.as_secs(),
            aud: CLIENT_SECRET_AUDIENCE,
            sub: client_id,
        };
        jsonwebtoken::encode(&header, &claims, &self.signing_key)
            .map_err(|_| AppleError::Unavailable("the client secret could not be signed"))
    }

    /// Verifies `token` against Apple's key set, the issuer, one of `audiences`, `exp`, and,
    /// when given, that its `nonce` claim is `nonce_claim`.
    async fn verify(
        &self,
        token: &str,
        audiences: &[String],
        nonce_claim: Option<&str>,
    ) -> Result<Claims, AppleError> {
        #[derive(Deserialize)]
        struct TokenClaims {
            sub: String,
            aud: String,
            nonce: Option<String>,
            email: Option<String>,
        }

        let header = jsonwebtoken::decode_header(token)
            .map_err(|_| AppleError::Rejected("the identity token is not a JWT"))?;
        let kid = header
            .kid
            .ok_or(AppleError::Rejected("the identity token names no key"))?;
        let known = self.key(&kid).await?;
        if header.alg != known.algorithm {
            return Err(AppleError::Rejected(
                "the identity token's algorithm is not its key's",
            ));
        }
        let mut validation = Validation::new(known.algorithm);
        validation.set_issuer(&[&self.issuer]);
        validation.set_audience(audiences);
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
        validation.leeway = LEEWAY_SECS;
        let data = jsonwebtoken::decode::<TokenClaims>(token, &known.key, &validation)
            .map_err(|error| AppleError::Rejected(rejection(error.kind())))?;
        let claims = data.claims;
        if let Some(expected) = nonce_claim {
            if claims.nonce.as_deref() != Some(expected) {
                return Err(AppleError::Rejected(
                    "the identity token's nonce is not the ceremony's",
                ));
            }
        }
        if claims.sub.is_empty() {
            return Err(AppleError::Rejected("the identity token names no Apple ID"));
        }
        Ok(Claims {
            sub: claims.sub,
            aud: claims.aud,
            email: claims.email.filter(|email| !email.is_empty()),
        })
    }

    /// The key `kid` names: from the cache, or from Apple's key set fetched again when the
    /// cache does not have it and was not fetched in the last [`JWKS_REFETCH_INTERVAL`].
    async fn key(&self, kid: &str) -> Result<KnownKey, AppleError> {
        let mut cache = self.jwks.lock().await;
        if let Some(known) = cache.keys.get(kid) {
            return Ok(known.clone());
        }
        let recently = cache
            .fetched_at
            .is_some_and(|at| at.elapsed() < JWKS_REFETCH_INTERVAL);
        if !recently {
            // Counted before the fetch, so a failing Apple is not asked again within the minute.
            cache.fetched_at = Some(Instant::now());
            cache.keys = self.fetch_keys().await?;
            if let Some(known) = cache.keys.get(kid) {
                return Ok(known.clone());
            }
        }
        Err(AppleError::Rejected(
            "the identity token's key is not in Apple's key set",
        ))
    }

    /// Apple's key set, each usable key by its `kid`. A key of another type, curve, or
    /// algorithm is skipped.
    async fn fetch_keys(&self) -> Result<HashMap<String, KnownKey>, AppleError> {
        #[derive(Deserialize)]
        struct KeySet {
            keys: Vec<Value>,
        }

        let url = self
            .endpoint("auth/keys")
            .map_err(|_| AppleError::Unavailable("Apple's key set URL is not valid"))?;
        let response = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|_| AppleError::Unavailable("Apple's key set could not be fetched"))?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(AppleError::Unavailable(
                "Apple's key set could not be fetched",
            ));
        }
        let body = read_body(response).await?;
        let set: KeySet = serde_json::from_slice(&body)
            .map_err(|_| AppleError::Unavailable("Apple's key set is not a JWKS"))?;
        let mut keys = HashMap::new();
        for value in set.keys {
            let declared = value.get("alg").and_then(Value::as_str).map(str::to_string);
            let Ok(jwk) = serde_json::from_value::<Jwk>(value) else {
                continue;
            };
            let Some(kid) = jwk.common.key_id.clone() else {
                continue;
            };
            let algorithm = match &jwk.algorithm {
                AlgorithmParameters::RSA(_) => Algorithm::RS256,
                AlgorithmParameters::EllipticCurve(ec) if ec.curve == EllipticCurve::P256 => {
                    Algorithm::ES256
                }
                _ => continue,
            };
            let name = if algorithm == Algorithm::RS256 {
                "RS256"
            } else {
                "ES256"
            };
            if declared.is_some_and(|alg| alg != name) {
                continue;
            }
            if let Ok(key) = DecodingKey::from_jwk(&jwk) {
                keys.insert(kid, KnownKey { algorithm, key });
            }
        }
        Ok(keys)
    }

    async fn post_form(
        &self,
        path: &str,
        form: &[(&str, &str)],
    ) -> Result<(reqwest::StatusCode, Vec<u8>), AppleError> {
        let url = self
            .endpoint(path)
            .map_err(|_| AppleError::Unavailable("Apple's URL is not valid"))?;
        let response = self
            .http
            .post(url)
            .form(form)
            .send()
            .await
            .map_err(|_| AppleError::Unavailable("Apple could not be reached"))?;
        let status = response.status();
        Ok((status, read_body(response).await?))
    }

    fn endpoint(&self, path: &str) -> Result<Url, url::ParseError> {
        self.base_url.join(path)
    }
}

impl AppleRevoker for AppleClient {
    async fn revoke(&self, grant: &AppleGrant) -> Result<(), RevokeError> {
        self.revoke_grant(grant).await
    }
}

async fn read_body(response: reqwest::Response) -> Result<Vec<u8>, AppleError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_ANSWER_BYTES as u64)
    {
        return Err(AppleError::Unavailable("Apple's answer is too large"));
    }
    let body = response
        .bytes()
        .await
        .map_err(|_| AppleError::Unavailable("Apple's answer could not be read"))?;
    if body.len() > MAX_ANSWER_BYTES {
        return Err(AppleError::Unavailable("Apple's answer is too large"));
    }
    Ok(body.to_vec())
}

/// A fixed reason for a token jsonwebtoken refused.
fn rejection(kind: &jsonwebtoken::errors::ErrorKind) -> &'static str {
    use jsonwebtoken::errors::ErrorKind;
    match kind {
        ErrorKind::ExpiredSignature => "the identity token has expired",
        ErrorKind::InvalidAudience => "the identity token is for another client",
        ErrorKind::InvalidIssuer => "the identity token was not issued by Apple",
        ErrorKind::InvalidSignature => "the identity token's signature does not verify",
        ErrorKind::MissingRequiredClaim(_) => "the identity token is missing a claim",
        _ => "the identity token is malformed",
    }
}

// ---- Sealing ----

/// A sealed token that does not open (the wrong key, the wrong identity row, or corrupt), or
/// sealing found no randomness. Fixed text only.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SealError {
    #[error("a sealed Apple refresh token does not open")]
    Unopenable,
    #[error("the operating system has no source of randomness")]
    Entropy,
}

/// Seals `grant` under `key` for the `apple_refresh_token_enc` column of the identity row
/// `identity_id`.
pub fn seal_refresh_token(
    key: &[u8; 32],
    identity_id: Uuid,
    grant: &AppleGrant,
) -> Result<Vec<u8>, SealError> {
    seal(key, identity_id.as_bytes(), grant)
}

/// Opens a grant [`seal_refresh_token`] sealed under `key` for the row `identity_id`.
pub fn open_refresh_token(
    key: &[u8; 32],
    identity_id: Uuid,
    sealed: &[u8],
) -> Result<AppleGrant, SealError> {
    open(key, identity_id.as_bytes(), sealed)
}

/// What the web flow's callback verified, kept (sealed) with its handoff until the app redeems
/// it: the Apple ID, its email and name (the name on a first sign-in only), the client id the
/// code was issued to, and the authorization code, not yet exchanged. `Debug` shows none of it.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PendingApple {
    pub sub: String,
    pub email: Option<String>,
    pub name: Option<String>,
    pub client_id: String,
    pub code: String,
}

impl fmt::Debug for PendingApple {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PendingApple").finish_non_exhaustive()
    }
}

/// Seals `pending` under `key` for the handoff whose code hashes to `code_hash`, which is the
/// associated data: it opens only for the handoff it was recorded with.
pub fn seal_pending(
    key: &[u8; 32],
    code_hash: &[u8],
    pending: &PendingApple,
) -> Result<Vec<u8>, SealError> {
    seal(key, code_hash, pending)
}

/// Opens what [`seal_pending`] sealed for the handoff `code_hash`.
pub fn open_pending(
    key: &[u8; 32],
    code_hash: &[u8],
    sealed: &[u8],
) -> Result<PendingApple, SealError> {
    open(key, code_hash, sealed)
}

/// `value` as JSON, AES-256-GCM under `key` with `aad`: a random 96-bit nonce, then the
/// ciphertext and its tag.
fn seal<T: Serialize>(key: &[u8; 32], aad: &[u8], value: &T) -> Result<Vec<u8>, SealError> {
    let plaintext = serde_json::to_vec(value).map_err(|_| SealError::Unopenable)?;
    let mut nonce = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce).map_err(|_| SealError::Entropy)?;
    let ciphertext = cipher(key)
        .encrypt(
            &Nonce::from(nonce),
            Payload {
                msg: &plaintext,
                aad,
            },
        )
        .map_err(|_| SealError::Unopenable)?;
    let mut sealed = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    sealed.extend_from_slice(&nonce);
    sealed.extend_from_slice(&ciphertext);
    Ok(sealed)
}

fn open<T: serde::de::DeserializeOwned>(
    key: &[u8; 32],
    aad: &[u8],
    sealed: &[u8],
) -> Result<T, SealError> {
    if sealed.len() < NONCE_LEN {
        return Err(SealError::Unopenable);
    }
    let (nonce, ciphertext) = sealed.split_at(NONCE_LEN);
    let nonce = Nonce::try_from(nonce).map_err(|_| SealError::Unopenable)?;
    let plaintext = cipher(key)
        .decrypt(
            &nonce,
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| SealError::Unopenable)?;
    serde_json::from_slice(&plaintext).map_err(|_| SealError::Unopenable)
}

fn cipher(key: &[u8; 32]) -> Aes256Gcm {
    Aes256Gcm::new(&(*key).into())
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex as StdMutex};

    use axum::routing::get;
    use axum::{Json, Router};
    use serde_json::json;

    use super::*;

    fn grant(token: &str) -> AppleGrant {
        AppleGrant {
            client_id: "com.cacheplane.b4app.ios".into(),
            refresh_token: token.into(),
        }
    }

    #[test]
    fn a_sealed_token_opens_only_under_its_key_and_row() {
        let key = [7; 32];
        let row = Uuid::from_u128(1);
        let sealed = seal_refresh_token(&key, row, &grant("rt.secret")).unwrap();
        assert!(!sealed.windows(9).any(|w| w == b"rt.secret"));
        assert_eq!(
            open_refresh_token(&key, row, &sealed).unwrap(),
            grant("rt.secret")
        );
        // A fresh nonce each time.
        assert_ne!(
            seal_refresh_token(&key, row, &grant("rt.secret")).unwrap(),
            sealed
        );

        assert_eq!(
            open_refresh_token(&[8; 32], row, &sealed),
            Err(SealError::Unopenable)
        );
        // Copied to another identity row, it does not open.
        assert_eq!(
            open_refresh_token(&key, Uuid::from_u128(2), &sealed),
            Err(SealError::Unopenable)
        );
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert_eq!(
            open_refresh_token(&key, row, &tampered),
            Err(SealError::Unopenable)
        );
        assert_eq!(
            open_refresh_token(&key, row, &sealed[..5]),
            Err(SealError::Unopenable)
        );
        assert!(!format!("{:?}", grant("rt.secret")).contains("rt.secret"));
    }

    #[test]
    fn a_pending_handoff_opens_only_for_its_handoff() {
        let key = [7; 32];
        let pending = PendingApple {
            sub: "001.p".into(),
            email: None,
            name: Some("Bea".into()),
            client_id: "com.cacheplane.b4app.signin".into(),
            code: "c.secret-code".into(),
        };
        let sealed = seal_pending(&key, b"hash-one", &pending).unwrap();
        assert!(!sealed.windows(13).any(|w| w == b"c.secret-code"));
        assert_eq!(open_pending(&key, b"hash-one", &sealed).unwrap(), pending);
        assert_eq!(
            open_pending(&key, b"hash-two", &sealed),
            Err(SealError::Unopenable)
        );
        assert_eq!(
            open_pending(&[8; 32], b"hash-one", &sealed),
            Err(SealError::Unopenable)
        );
        assert!(!format!("{pending:?}").contains("secret"));
    }

    #[test]
    fn sha256_hex_is_lowercase_hex() {
        assert_eq!(
            sha256_hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    /// A P-256 PKCS #8 key in Apple's `.p8` layout (generated for these tests only).
    const PEM: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgqrZ+3DfzH9Dc5w8s
oewz0zDOE2Gmv6TrBIaeYAQQoEChRANCAASkVvaBeWp572RHzq7dFwzqBD5q28os
kZXiwkEnZYzZPc5fQx0VfT+fhjzYhYLgQ+KXi00zbyOb46KPzL6yEFza
-----END PRIVATE KEY-----";

    fn config(base_url: &str) -> AppleConfig {
        AppleConfig {
            team_id: "ABCDE12345".into(),
            key_id: "KEY1234567".into(),
            private_key_pem: PEM.into(),
            audiences: vec!["com.cacheplane.b4app.ios".into()],
            services_id: None,
            base_url: Url::parse(base_url).unwrap(),
        }
    }

    #[test]
    fn a_key_that_does_not_sign_is_a_configuration_error() {
        let mut bad = config("https://appleid.apple.com");
        bad.private_key_pem =
            "-----BEGIN PRIVATE KEY-----\nMIIBAAAA\n-----END PRIVATE KEY-----".into();
        let error = AppleClient::new(&bad).unwrap_err();
        assert_eq!(error.name, "B4HUB_APPLE_PRIVATE_KEY");
        let client = AppleClient::new(&config("https://appleid.apple.com/")).unwrap();
        assert_eq!(client.issuer(), "https://appleid.apple.com");
    }

    /// A key set server whose keys the test changes, counting fetches.
    #[derive(Clone, Default)]
    struct Keys {
        keys: Arc<StdMutex<Vec<Value>>>,
        fetches: Arc<AtomicUsize>,
    }

    fn ec_jwk(kid: &str) -> Value {
        // Any valid P-256 point will do: the cache test never verifies a signature.
        json!({
            "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
            "x": "pFb2gXlqee9kR86u3RcM6gQ-atvKLJGV4sJBJ2WM2T0",
            "y": "zl9DHRV9P5-GPNiFguBD4peLTTNvI5vjoo_MvrIQXNo",
        })
    }

    #[tokio::test]
    async fn an_unknown_kid_fetches_the_key_set_again_at_most_once_a_minute() {
        let served = Keys::default();
        served.keys.lock().unwrap().push(ec_jwk("A"));
        let app = Router::new().route(
            "/auth/keys",
            get({
                let served = served.clone();
                move || async move {
                    served.fetches.fetch_add(1, Ordering::SeqCst);
                    Json(json!({"keys": served.keys.lock().unwrap().clone()}))
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = AppleClient::new(&config(&base)).unwrap();
        let fetches = || served.fetches.load(Ordering::SeqCst);

        // The first lookup fetches; a known kid never does.
        assert!(client.key("A").await.is_ok());
        assert!(client.key("A").await.is_ok());
        assert_eq!(fetches(), 1);

        // Apple rotates in B. Within the minute an unknown kid is refused without a fetch.
        served.keys.lock().unwrap().push(ec_jwk("B"));
        assert!(client.key("B").await.is_err());
        assert_eq!(fetches(), 1);

        // A minute later, it fetches once and finds B.
        client.jwks.lock().await.fetched_at = Some(Instant::now() - JWKS_REFETCH_INTERVAL);
        assert!(client.key("B").await.is_ok());
        assert_eq!(fetches(), 2);
        assert!(client.key("C").await.is_err());
        assert_eq!(fetches(), 2);
        server.abort();
    }
}
