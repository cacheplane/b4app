//! The sign-in configuration `serve` reads at start: the sign-up policy, the WebAuthn relying
//! party, the public URL, the secret key, Sign in with Apple, and whether to trust
//! `X-Forwarded-For`.
//!
//! Every secret is a plain environment variable, never a file path, so any host's secret manager
//! can inject it. A missing or malformed setting is a [`ConfigError`] naming the variable and
//! never its value; `serve` exits 2 on one.

use std::fmt;

use b4hub_db::ceremonies;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use url::Url;
use webauthn_rs::prelude::{Webauthn, WebauthnBuilder};

use crate::cli::{ConfigError, Settings};

/// Where Apple's endpoints live unless `B4HUB_APPLE_BASE_URL` (tests only) says otherwise.
pub const DEFAULT_APPLE_BASE_URL: &str = "https://appleid.apple.com";

/// The four variables that configure Sign in with Apple; all or none must be set.
const APPLE_VARS: [&str; 4] = [
    "B4HUB_APPLE_TEAM_ID",
    "B4HUB_APPLE_KEY_ID",
    "B4HUB_APPLE_PRIVATE_KEY",
    "B4HUB_APPLE_AUDIENCES",
];

/// Whether a sign-in with a new Apple ID or passkey may create an account.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Signup {
    Open,
    Closed,
}

/// The hub's sign-in configuration. `Debug` leaves out the secret key.
#[derive(Clone, PartialEq, Eq)]
pub struct Config {
    /// `B4HUB_SIGNUP`, default closed, so an on-prem hub never grows accounts by accident.
    pub signup: Signup,
    /// `B4HUB_WEBAUTHN_RP_ID`, the site domain passkeys belong to; the origin is
    /// `https://{rp_id}`.
    pub rp_id: String,
    /// `B4HUB_PUBLIC_URL`: where clients reach the hub, when it is set.
    pub public_url: Option<Url>,
    /// `B4HUB_SECRET_KEY`: 32 bytes, for what the hub keeps encrypted at rest.
    pub secret_key: [u8; 32],
    /// Sign in with Apple, when every `B4HUB_APPLE_*` variable is set.
    pub apple: Option<AppleConfig>,
    /// `B4HUB_TRUST_X_FORWARDED_FOR=1`: the client is the right-most `X-Forwarded-For` entry,
    /// not the TCP peer. Only for a hub behind a proxy that sets the header.
    pub trust_forwarded_for: bool,
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("signup", &self.signup)
            .field("rp_id", &self.rp_id)
            .field("public_url", &self.public_url.as_ref().map(Url::as_str))
            .field("secret_key", &"<redacted>")
            .field("apple", &self.apple)
            .field("trust_forwarded_for", &self.trust_forwarded_for)
            .finish()
    }
}

/// Sign in with Apple's settings. `Debug` leaves out the private key.
#[derive(Clone, PartialEq, Eq)]
pub struct AppleConfig {
    /// `B4HUB_APPLE_TEAM_ID`, the client secret's issuer.
    pub team_id: String,
    /// `B4HUB_APPLE_KEY_ID`, the `.p8` key's id.
    pub key_id: String,
    /// `B4HUB_APPLE_PRIVATE_KEY`, the `.p8` file's PEM contents.
    pub private_key_pem: String,
    /// `B4HUB_APPLE_AUDIENCES`: the client ids an identity token may be for (the iOS bundle id
    /// and the Services ID).
    pub audiences: Vec<String>,
    /// `B4HUB_APPLE_BASE_URL`, tests only.
    pub base_url: Url,
}

impl fmt::Debug for AppleConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AppleConfig")
            .field("team_id", &self.team_id)
            .field("key_id", &self.key_id)
            .field("private_key_pem", &"<redacted>")
            .field("audiences", &self.audiences)
            .field("base_url", &self.base_url.as_str())
            .finish()
    }
}

impl Config {
    /// Reads and validates the sign-in configuration. `B4HUB_WEBAUTHN_RP_ID` and
    /// `B4HUB_SECRET_KEY` are required; the rest have defaults or are optional.
    pub fn from_settings(settings: &Settings) -> Result<Config, ConfigError> {
        Config {
            signup: signup(settings)?,
            rp_id: rp_id(settings)?,
            public_url: settings.public_url()?,
            secret_key: secret_key(settings)?,
            apple: apple(settings)?,
            trust_forwarded_for: flag(settings, "B4HUB_TRUST_X_FORWARDED_FOR")?,
        }
        .validated()
    }

    fn validated(self) -> Result<Config, ConfigError> {
        self.webauthn()?;
        Ok(self)
    }

    /// The WebAuthn relying party: `rp_id`, origin `https://{rp_id}`, named "Agent Workspace",
    /// with the ceremony lifetime as the authenticator timeout.
    pub fn webauthn(&self) -> Result<Webauthn, ConfigError> {
        let origin = self.origin()?;
        WebauthnBuilder::new(&self.rp_id, &origin)
            .and_then(|builder| {
                builder
                    .rp_name("Agent Workspace")
                    .timeout(ceremonies::CEREMONY_TTL)
                    .build()
            })
            .map_err(|_| {
                ConfigError::new(
                    "B4HUB_WEBAUTHN_RP_ID",
                    "is not a relying party id WebAuthn accepts",
                )
            })
    }

    /// The origin passkey responses must carry.
    pub fn origin(&self) -> Result<Url, ConfigError> {
        Url::parse(&format!("https://{}", self.rp_id))
            .map_err(|_| ConfigError::new("B4HUB_WEBAUTHN_RP_ID", "must be a domain name"))
    }
}

fn signup(settings: &Settings) -> Result<Signup, ConfigError> {
    match settings.var("B4HUB_SIGNUP") {
        None | Some("closed") => Ok(Signup::Closed),
        Some("open") => Ok(Signup::Open),
        Some(_) => Err(ConfigError::new("B4HUB_SIGNUP", "must be open or closed")),
    }
}

/// A domain name: dot-separated labels of lowercase letters, digits, and inner hyphens, with no
/// scheme, port, or path.
fn rp_id(settings: &Settings) -> Result<String, ConfigError> {
    const NAME: &str = "B4HUB_WEBAUTHN_RP_ID";
    let raw = settings.var(NAME).ok_or_else(|| {
        ConfigError::new(
            NAME,
            "is not set (the passkey relying party, for example local.b4.run)",
        )
    })?;
    let label_ok = |label: &str| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    };
    if raw.len() <= 253 && raw.split('.').all(label_ok) {
        Ok(raw.to_string())
    } else {
        Err(ConfigError::new(
            NAME,
            "must be a lowercase domain name with no scheme, port, or path",
        ))
    }
}

fn secret_key(settings: &Settings) -> Result<[u8; 32], ConfigError> {
    const NAME: &str = "B4HUB_SECRET_KEY";
    let raw = settings.var(NAME).ok_or_else(|| {
        ConfigError::new(
            NAME,
            "is not set (32 random bytes in base64: openssl rand -base64 32)",
        )
    })?;
    STANDARD
        .decode(raw.trim())
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| ConfigError::new(NAME, "must be exactly 32 bytes in base64"))
}

fn flag(settings: &Settings, name: &str) -> Result<bool, ConfigError> {
    match settings.var(name) {
        None | Some("0") => Ok(false),
        Some("1") => Ok(true),
        Some(_) => Err(ConfigError::new(name, "must be 1 or 0")),
    }
}

fn apple(settings: &Settings) -> Result<Option<AppleConfig>, ConfigError> {
    let set: Vec<&str> = APPLE_VARS
        .iter()
        .copied()
        .filter(|name| settings.var(name).is_some())
        .collect();
    if set.is_empty() {
        if settings.var("B4HUB_APPLE_BASE_URL").is_some() {
            return Err(ConfigError::new(
                "B4HUB_APPLE_BASE_URL",
                "is set without the other B4HUB_APPLE_* variables",
            ));
        }
        return Ok(None);
    }
    if let Some(missing) = APPLE_VARS.iter().find(|name| !set.contains(name)) {
        return Err(ConfigError::new(
            missing,
            "is not set; Sign in with Apple needs all of B4HUB_APPLE_TEAM_ID, \
             B4HUB_APPLE_KEY_ID, B4HUB_APPLE_PRIVATE_KEY, and B4HUB_APPLE_AUDIENCES, or none",
        ));
    }
    let var = |name: &str| settings.var(name).unwrap_or_default();

    let apple_id = |name: &str| {
        let value = var(name);
        if value.len() == 10
            && value
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        {
            Ok(value.to_string())
        } else {
            Err(ConfigError::new(
                name,
                "must be 10 uppercase letters and digits, as Apple shows it",
            ))
        }
    };
    let team_id = apple_id("B4HUB_APPLE_TEAM_ID")?;
    let key_id = apple_id("B4HUB_APPLE_KEY_ID")?;

    let private_key_pem = var("B4HUB_APPLE_PRIVATE_KEY").trim().to_string();
    if !is_pkcs8_pem(&private_key_pem) {
        return Err(ConfigError::new(
            "B4HUB_APPLE_PRIVATE_KEY",
            "must be the PEM contents of the .p8 key (-----BEGIN PRIVATE KEY----- ...), \
             not a path",
        ));
    }

    let audiences: Vec<String> = var("B4HUB_APPLE_AUDIENCES")
        .split(',')
        .map(str::trim)
        .map(str::to_string)
        .collect();
    if audiences
        .iter()
        .any(|a| a.is_empty() || a.contains(char::is_whitespace))
    {
        return Err(ConfigError::new(
            "B4HUB_APPLE_AUDIENCES",
            "must be a comma-separated list of client ids",
        ));
    }

    let base_url = match settings.var("B4HUB_APPLE_BASE_URL") {
        None => Url::parse(DEFAULT_APPLE_BASE_URL).expect("the default is a URL"),
        Some(raw) => match Url::parse(raw) {
            Ok(url) if matches!(url.scheme(), "http" | "https") && url.has_host() => url,
            _ => {
                return Err(ConfigError::new(
                    "B4HUB_APPLE_BASE_URL",
                    "must be an http or https URL",
                ))
            }
        },
    };

    Ok(Some(AppleConfig {
        team_id,
        key_id,
        private_key_pem,
        audiences,
        base_url,
    }))
}

/// Whether `pem` is one PKCS #8 `PRIVATE KEY` block whose body is base64 DER (a `SEQUENCE`), the
/// shape of Apple's `.p8` files. The key itself is parsed where it is used.
fn is_pkcs8_pem(pem: &str) -> bool {
    const BEGIN: &str = "-----BEGIN PRIVATE KEY-----";
    const END: &str = "-----END PRIVATE KEY-----";
    let Some(body) = pem
        .strip_prefix(BEGIN)
        .and_then(|rest| rest.strip_suffix(END))
    else {
        return false;
    };
    let body: String = body.chars().filter(|c| !c.is_whitespace()).collect();
    STANDARD
        .decode(body)
        .is_ok_and(|der| der.first() == Some(&0x30) && der.len() > 32)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";
    /// A P-256 PKCS #8 key in Apple's `.p8` layout (generated for these tests only).
    const PEM: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgqrZ+3DfzH9Dc5w8s
oewz0zDOE2Gmv6TrBIaeYAQQoEChRANCAASkVvaBeWp572RHzq7dFwzqBD5q28os
kZXiwkEnZYzZPc5fQx0VfT+fhjzYhYLgQ+KXi00zbyOb46KPzL6yEFza
-----END PRIVATE KEY-----";

    fn settings(pairs: &[(&str, &str)]) -> Settings {
        let mut all = vec![
            ("B4HUB_WEBAUTHN_RP_ID", "local.b4.run"),
            ("B4HUB_SECRET_KEY", KEY),
        ];
        all.extend_from_slice(pairs);
        Settings::from_pairs(all)
    }

    fn apple_pairs() -> Vec<(&'static str, &'static str)> {
        vec![
            ("B4HUB_APPLE_TEAM_ID", "ABCDE12345"),
            ("B4HUB_APPLE_KEY_ID", "KEY1234567"),
            ("B4HUB_APPLE_PRIVATE_KEY", PEM),
            (
                "B4HUB_APPLE_AUDIENCES",
                "com.cacheplane.b4app.ios, com.cacheplane.b4app.signin",
            ),
        ]
    }

    #[test]
    fn defaults() {
        let config = Config::from_settings(&settings(&[])).unwrap();
        assert_eq!(config.signup, Signup::Closed);
        assert_eq!(config.rp_id, "local.b4.run");
        assert_eq!(config.secret_key, [7; 32]);
        assert_eq!(config.public_url, None);
        assert_eq!(config.apple, None);
        assert!(!config.trust_forwarded_for);
        assert_eq!(config.origin().unwrap().as_str(), "https://local.b4.run/");
        assert!(!format!("{config:?}").contains("7, 7"));
    }

    #[test]
    fn signup_and_the_forwarded_for_flag_parse() {
        let open = Config::from_settings(&settings(&[
            ("B4HUB_SIGNUP", "open"),
            ("B4HUB_TRUST_X_FORWARDED_FOR", "1"),
        ]))
        .unwrap();
        assert_eq!(open.signup, Signup::Open);
        assert!(open.trust_forwarded_for);
        for (name, bad) in [
            ("B4HUB_SIGNUP", "yes"),
            ("B4HUB_SIGNUP", "Open"),
            ("B4HUB_TRUST_X_FORWARDED_FOR", "true"),
        ] {
            let error = Config::from_settings(&settings(&[(name, bad)])).unwrap_err();
            assert_eq!(error.name, name, "{bad}");
        }
    }

    #[test]
    fn rp_id_is_required_and_a_bare_domain() {
        let error =
            Config::from_settings(&Settings::from_pairs([("B4HUB_SECRET_KEY", KEY)])).unwrap_err();
        assert_eq!(error.name, "B4HUB_WEBAUTHN_RP_ID");
        for bad in [
            "https://b4.run",
            "b4.run:443",
            "b4.run/x",
            "B4.run",
            "-b4.run",
            "b4..run",
            "b4.run.",
        ] {
            let error =
                Config::from_settings(&settings(&[("B4HUB_WEBAUTHN_RP_ID", bad)])).unwrap_err();
            assert_eq!(error.name, "B4HUB_WEBAUTHN_RP_ID", "{bad}");
        }
        for good in ["b4.run", "test.b4.run", "localhost"] {
            assert!(Config::from_settings(&settings(&[("B4HUB_WEBAUTHN_RP_ID", good)])).is_ok());
        }
    }

    #[test]
    fn secret_key_is_32_bytes_of_base64_and_never_echoed() {
        let missing =
            Config::from_settings(&Settings::from_pairs([("B4HUB_WEBAUTHN_RP_ID", "b4.run")]))
                .unwrap_err();
        assert_eq!(missing.name, "B4HUB_SECRET_KEY");
        for bad in [
            "c2hvcnQ=",
            "not base64 at all!!",
            "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcH",
        ] {
            let error = Config::from_settings(&settings(&[("B4HUB_SECRET_KEY", bad)])).unwrap_err();
            assert_eq!(error.name, "B4HUB_SECRET_KEY", "{bad}");
            assert!(!error.to_string().contains(bad));
        }
    }

    #[test]
    fn apple_is_all_or_nothing() {
        let config = Config::from_settings(&settings(&apple_pairs())).unwrap();
        let apple = config.apple.expect("Apple is configured");
        assert_eq!(apple.team_id, "ABCDE12345");
        assert_eq!(apple.key_id, "KEY1234567");
        assert_eq!(
            apple.audiences,
            vec!["com.cacheplane.b4app.ios", "com.cacheplane.b4app.signin"]
        );
        assert_eq!(apple.base_url.as_str(), "https://appleid.apple.com/");
        assert!(!format!("{apple:?}").contains("MIGHAgEA"));

        for skip in APPLE_VARS {
            let pairs: Vec<_> = apple_pairs()
                .into_iter()
                .filter(|(name, _)| *name != skip)
                .collect();
            let error = Config::from_settings(&settings(&pairs)).unwrap_err();
            assert_eq!(error.name, skip);
        }
        let error =
            Config::from_settings(&settings(&[("B4HUB_APPLE_BASE_URL", "http://127.0.0.1:9")]))
                .unwrap_err();
        assert_eq!(error.name, "B4HUB_APPLE_BASE_URL");

        let mut with_base = apple_pairs();
        with_base.push(("B4HUB_APPLE_BASE_URL", "http://127.0.0.1:9"));
        let apple = Config::from_settings(&settings(&with_base))
            .unwrap()
            .apple
            .unwrap();
        assert_eq!(apple.base_url.as_str(), "http://127.0.0.1:9/");
    }

    #[test]
    fn apple_values_are_validated_and_never_echoed() {
        for (name, bad) in [
            ("B4HUB_APPLE_TEAM_ID", "abcde12345"),
            ("B4HUB_APPLE_KEY_ID", "SHORT"),
            ("B4HUB_APPLE_PRIVATE_KEY", "/run/secrets/AuthKey.p8"),
            (
                "B4HUB_APPLE_PRIVATE_KEY",
                "-----BEGIN PRIVATE KEY-----\nnot-base64\n-----END PRIVATE KEY-----",
            ),
            ("B4HUB_APPLE_AUDIENCES", "com.a,,com.b"),
            ("B4HUB_APPLE_BASE_URL", "ftp://apple"),
        ] {
            let mut pairs = apple_pairs();
            pairs.retain(|(n, _)| *n != name);
            pairs.push((name, bad));
            let error = Config::from_settings(&settings(&pairs)).unwrap_err();
            assert_eq!(error.name, name, "{bad}");
            assert!(!error.to_string().contains(bad), "{error}");
        }
    }
}
