//! A minimal software passkey authenticator for the hub's tests: ES256 keys from `p256`,
//! `none` attestation, discoverable credentials (it answers an assertion with no allow-list and
//! returns the user handle), user presence and verification always set. It speaks the JSON the
//! hub sends and expects, so the tests drive the routes the way a platform authenticator would.
//!
//! `webauthn-authenticator-rs`'s `SoftPasskey` refuses resident keys and needs an allow-list, so
//! it cannot do a discoverable sign-in; this is the smallest thing that can.

use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Authenticator data flags.
const UP: u8 = 0x01;
const UV: u8 = 0x04;
const BE: u8 = 0x08;
const BS: u8 = 0x10;
const AT: u8 = 0x40;

/// One credential the authenticator holds.
pub struct Credential {
    pub id: Vec<u8>,
    pub user_handle: Vec<u8>,
    pub counter: u32,
    pub rp_id: String,
    key: SigningKey,
}

pub struct Authenticator {
    /// The origin written into `clientDataJSON`, as a browser or the OS would.
    pub origin: String,
    /// Whether the counter goes up on each assertion (a hardware key) or stays 0 (a synced
    /// passkey, as iCloud Keychain's are).
    pub counts: bool,
    /// The backup-state flag reported with each assertion (backup eligibility is always set).
    pub backed_up: bool,
    pub credentials: Vec<Credential>,
}

impl Authenticator {
    pub fn new(origin: &str) -> Authenticator {
        Authenticator {
            origin: origin.to_string(),
            counts: true,
            backed_up: false,
            credentials: Vec::new(),
        }
    }

    /// Answers `navigator.credentials.create()` for `options` (the `registration` object a begin
    /// returned, `{"publicKey": {...}}`) with a `RegisterPublicKeyCredential`.
    pub fn register(&mut self, options: &Value) -> Value {
        let options = &options["publicKey"];
        let rp_id = options["rp"]["id"].as_str().expect("rp.id").to_string();
        let user_handle = decode(options["user"]["id"].as_str().expect("user.id"));
        let challenge = decode(options["challenge"].as_str().expect("challenge"));

        let id = random::<32>().to_vec();
        let key = SigningKey::from_bytes(&random::<32>().into()).expect("a valid scalar");
        let point = key.verifying_key().to_sec1_point(false);

        // COSE_Key: {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}
        let mut cose = vec![0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21];
        cbor_bytes(&mut cose, point.x().expect("x"));
        cose.push(0x22);
        cbor_bytes(&mut cose, point.y().expect("y"));

        let mut auth_data = Sha256::digest(rp_id.as_bytes()).to_vec();
        auth_data.push(UP | UV | BE | AT | if self.backed_up { BS } else { 0 });
        auth_data.extend_from_slice(&0u32.to_be_bytes());
        auth_data.extend_from_slice(&[0; 16]); // AAGUID
        auth_data.extend_from_slice(&(id.len() as u16).to_be_bytes());
        auth_data.extend_from_slice(&id);
        auth_data.extend_from_slice(&cose);

        // {"fmt": "none", "attStmt": {}, "authData": <bytes>}
        let mut attestation = vec![0xa3];
        cbor_text(&mut attestation, "fmt");
        cbor_text(&mut attestation, "none");
        cbor_text(&mut attestation, "attStmt");
        attestation.push(0xa0);
        cbor_text(&mut attestation, "authData");
        cbor_bytes(&mut attestation, &auth_data);

        let client_data = self.client_data("webauthn.create", &challenge);
        self.credentials.push(Credential {
            id: id.clone(),
            user_handle,
            counter: 0,
            rp_id,
            key,
        });
        json!({
            "id": URL_SAFE_NO_PAD.encode(&id),
            "rawId": URL_SAFE_NO_PAD.encode(&id),
            "response": {
                "attestationObject": URL_SAFE_NO_PAD.encode(&attestation),
                "clientDataJSON": URL_SAFE_NO_PAD.encode(&client_data),
            },
            "type": "public-key",
            "extensions": {},
        })
    }

    /// Answers `navigator.credentials.get()` for `options` (the `authentication` object a begin
    /// returned) with the most recently registered credential.
    pub fn assert(&mut self, options: &Value) -> Value {
        let last = self.credentials.len() - 1;
        self.assert_with(last, options)
    }

    /// Answers `navigator.credentials.get()` with credential `index`.
    pub fn assert_with(&mut self, index: usize, options: &Value) -> Value {
        let options = &options["publicKey"];
        let challenge = decode(options["challenge"].as_str().expect("challenge"));
        let rp_id = options["rpId"].as_str().expect("rpId");
        let client_data = self.client_data("webauthn.get", &challenge);
        let (counts, backed_up) = (self.counts, self.backed_up);
        let credential = &mut self.credentials[index];
        assert_eq!(
            credential.rp_id, rp_id,
            "the credential is for this relying party"
        );
        if counts {
            credential.counter += 1;
        }

        let mut auth_data = Sha256::digest(rp_id.as_bytes()).to_vec();
        auth_data.push(UP | UV | BE | if backed_up { BS } else { 0 });
        auth_data.extend_from_slice(&credential.counter.to_be_bytes());
        let mut signed = auth_data.clone();
        signed.extend_from_slice(&Sha256::digest(&client_data));
        let signature: Signature = credential.key.sign(&signed);

        json!({
            "id": URL_SAFE_NO_PAD.encode(&credential.id),
            "rawId": URL_SAFE_NO_PAD.encode(&credential.id),
            "response": {
                "authenticatorData": URL_SAFE_NO_PAD.encode(&auth_data),
                "clientDataJSON": URL_SAFE_NO_PAD.encode(&client_data),
                "signature": URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
                "userHandle": URL_SAFE_NO_PAD.encode(&credential.user_handle),
            },
            "type": "public-key",
            "extensions": {},
        })
    }

    fn client_data(&self, kind: &str, challenge: &[u8]) -> Vec<u8> {
        serde_json::to_vec(&json!({
            "type": kind,
            "challenge": URL_SAFE_NO_PAD.encode(challenge),
            "origin": self.origin,
            "crossOrigin": false,
        }))
        .unwrap()
    }
}

/// Decodes base64 in any of its four common spellings, as browsers are lenient too.
pub fn decode(text: &str) -> Vec<u8> {
    [URL_SAFE_NO_PAD, URL_SAFE, STANDARD_NO_PAD, STANDARD]
        .iter()
        .find_map(|engine| engine.decode(text).ok())
        .unwrap_or_else(|| panic!("not base64: {text}"))
}

fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes).expect("randomness");
    bytes
}

fn cbor_head(out: &mut Vec<u8>, major: u8, len: usize) {
    let major = major << 5;
    match len {
        0..=23 => out.push(major | len as u8),
        24..=0xff => out.extend_from_slice(&[major | 24, len as u8]),
        _ => {
            out.push(major | 25);
            out.extend_from_slice(&(len as u16).to_be_bytes());
        }
    }
}

fn cbor_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    cbor_head(out, 2, bytes.len());
    out.extend_from_slice(bytes);
}

fn cbor_text(out: &mut Vec<u8>, text: &str) {
    cbor_head(out, 3, text.len());
    out.extend_from_slice(text.as_bytes());
}
