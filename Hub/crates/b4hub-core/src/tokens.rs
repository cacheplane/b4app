//! Device tokens and enrollment codes: how they are minted and how they are hashed for storage.
//! The hub stores only the SHA-256 of either; the plaintext exists in the one response (token)
//! or terminal line (code) that hands it over.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use sha2::{Digest, Sha256};

/// The characters an enrollment code is drawn from: no vowels (so no accidental words) and no
/// `0` or `1` (lookalikes of `O` and `I`), so a code survives being read aloud or typed.
pub const CODE_ALPHABET: &[u8; 28] = b"BCDFGHJKLMNPQRSTVWXZ23456789";

/// Characters in an enrollment code.
pub const CODE_LENGTH: usize = 8;

/// A fresh device token: 32 random bytes, base64url without padding (43 characters).
///
/// Panics only if the operating system has no source of randomness, in which case the hub cannot
/// issue a credential safely and must not pretend to.
pub fn new_token() -> String {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("the operating system provides randomness");
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The SHA-256 of a token, which is all the hub stores.
pub fn hash_token(token: &str) -> [u8; 32] {
    Sha256::digest(token.as_bytes()).into()
}

/// A fresh enrollment code: [`CODE_LENGTH`] characters from [`CODE_ALPHABET`], drawn without
/// modulo bias (a byte is used only when it falls below the largest multiple of 28 under 256).
pub fn new_code() -> String {
    const LIMIT: u8 = (256 / CODE_ALPHABET.len() * CODE_ALPHABET.len()) as u8;
    let mut code = String::with_capacity(CODE_LENGTH);
    let mut buffer = [0u8; 16];
    while code.len() < CODE_LENGTH {
        getrandom::fill(&mut buffer).expect("the operating system provides randomness");
        for byte in buffer {
            if byte < LIMIT && code.len() < CODE_LENGTH {
                code.push(CODE_ALPHABET[usize::from(byte) % CODE_ALPHABET.len()] as char);
            }
        }
    }
    code
}

/// The SHA-256 of a code after uppercasing it, so a code typed in lowercase still matches.
pub fn hash_code(code: &str) -> [u8; 32] {
    Sha256::digest(code.to_ascii_uppercase().as_bytes()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_use_the_unambiguous_alphabet_and_eight_chars() {
        for _ in 0..100 {
            let code = new_code();
            assert_eq!(code.len(), 8, "{code}");
            assert!(
                code.bytes().all(|b| CODE_ALPHABET.contains(&b)),
                "{code} has a character outside the alphabet"
            );
        }
    }

    #[test]
    fn code_hash_ignores_case() {
        assert_eq!(hash_code("bcdf2345"), hash_code("BCDF2345"));
        assert_ne!(hash_code("BCDF2345"), hash_code("BCDF2346"));
    }

    #[test]
    fn tokens_are_32_random_bytes_in_base64url_without_padding() {
        let token = new_token();
        assert_eq!(token.len(), 43);
        assert!(token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
        assert_ne!(token, new_token());
        let decoded = URL_SAFE_NO_PAD.decode(&token).unwrap();
        assert_eq!(decoded.len(), 32);
    }

    #[test]
    fn token_hash_is_the_sha256_of_the_token() {
        // SHA-256("abc")
        let expected = [
            0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae,
            0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61,
            0xf2, 0x00, 0x15, 0xad,
        ];
        assert_eq!(hash_token("abc"), expected);
    }
}
