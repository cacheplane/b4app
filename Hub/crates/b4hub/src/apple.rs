//! What deleting an account needs from Sign in with Apple: revoking each stored refresh token at
//! Apple, and opening the tokens `B4HUB_SECRET_KEY` sealed.
//!
//! The revoker is a trait so tests can record calls. Until Sign in with Apple is built (sign-in
//! plan Task 13, which replaces it with the real client), the hub runs [`NoopRevoker`]: nothing
//! stores a refresh token yet, so there is nothing to revoke.
//!
//! A sealed token is AES-256-GCM under `B4HUB_SECRET_KEY`: a random 96-bit nonce, then the
//! ciphertext and its 16-byte tag. Neither a token nor a sealed one is ever logged.

use std::future::Future;
use std::pin::Pin;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};

/// The nonce length of a sealed token, in bytes.
const NONCE_LEN: usize = 12;

/// Revoking an Apple refresh token failed; the account must not be deleted. The text is fixed,
/// never Apple's answer or the token.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RevokeError {
    #[error("revoking an Apple refresh token failed: {0}")]
    Failed(&'static str),
}

/// Revokes an Apple refresh token at Apple (`/auth/revoke`). Implement it with
/// `async fn revoke(&self, refresh_token: &str) -> Result<(), RevokeError>`; the trait spells
/// the future out only to require that it is `Send`, as axum's handlers need.
pub trait AppleRevoker: Send + Sync + 'static {
    fn revoke(&self, refresh_token: &str) -> impl Future<Output = Result<(), RevokeError>> + Send;
}

/// [`AppleRevoker`] made object safe, so [`crate::serve::AppState`] can hold any revoker. Every
/// `AppleRevoker` is one.
pub trait ErasedAppleRevoker: Send + Sync {
    fn revoke<'a>(
        &'a self,
        refresh_token: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<(), RevokeError>> + Send + 'a>>;
}

impl<T: AppleRevoker> ErasedAppleRevoker for T {
    fn revoke<'a>(
        &'a self,
        refresh_token: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<(), RevokeError>> + Send + 'a>> {
        Box::pin(AppleRevoker::revoke(self, refresh_token))
    }
}

/// The revoker until Sign in with Apple exists: it revokes nothing. No route stores a refresh
/// token yet, so it is never handed one; if it were, it says so in the log rather than pretend.
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopRevoker;

impl AppleRevoker for NoopRevoker {
    async fn revoke(&self, _refresh_token: &str) -> Result<(), RevokeError> {
        tracing::warn!("Apple revocation is not built yet; a stored refresh token was not revoked");
        Ok(())
    }
}

/// A sealed token that does not open (the wrong key, or corrupt), or sealing found no
/// randomness. Fixed text only.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SealError {
    #[error("a sealed Apple refresh token does not open")]
    Unopenable,
    #[error("the operating system has no source of randomness")]
    Entropy,
}

/// Seals `refresh_token` under `key` for `user_identities.apple_refresh_token_enc`.
pub fn seal_refresh_token(key: &[u8; 32], refresh_token: &str) -> Result<Vec<u8>, SealError> {
    let mut nonce = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce).map_err(|_| SealError::Entropy)?;
    let ciphertext = cipher(key)
        .encrypt(&Nonce::from(nonce), refresh_token.as_bytes())
        .map_err(|_| SealError::Unopenable)?;
    let mut sealed = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    sealed.extend_from_slice(&nonce);
    sealed.extend_from_slice(&ciphertext);
    Ok(sealed)
}

/// Opens a token [`seal_refresh_token`] sealed under `key`.
pub fn open_refresh_token(key: &[u8; 32], sealed: &[u8]) -> Result<String, SealError> {
    if sealed.len() < NONCE_LEN {
        return Err(SealError::Unopenable);
    }
    let (nonce, ciphertext) = sealed.split_at(NONCE_LEN);
    let nonce = Nonce::try_from(nonce).map_err(|_| SealError::Unopenable)?;
    let plaintext = cipher(key)
        .decrypt(&nonce, ciphertext)
        .map_err(|_| SealError::Unopenable)?;
    String::from_utf8(plaintext).map_err(|_| SealError::Unopenable)
}

fn cipher(key: &[u8; 32]) -> Aes256Gcm {
    Aes256Gcm::new(&(*key).into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sealed_token_opens_only_under_its_key() {
        let key = [7; 32];
        let sealed = seal_refresh_token(&key, "rt.secret").unwrap();
        assert!(!sealed.windows(9).any(|w| w == b"rt.secret"));
        assert_eq!(sealed.len(), NONCE_LEN + "rt.secret".len() + 16);
        assert_eq!(open_refresh_token(&key, &sealed).unwrap(), "rt.secret");
        // A fresh nonce each time.
        assert_ne!(seal_refresh_token(&key, "rt.secret").unwrap(), sealed);

        assert_eq!(
            open_refresh_token(&[8; 32], &sealed),
            Err(SealError::Unopenable)
        );
        let mut tampered = sealed.clone();
        *tampered.last_mut().unwrap() ^= 1;
        assert_eq!(
            open_refresh_token(&key, &tampered),
            Err(SealError::Unopenable)
        );
        assert_eq!(
            open_refresh_token(&key, &sealed[..5]),
            Err(SealError::Unopenable)
        );
    }
}
