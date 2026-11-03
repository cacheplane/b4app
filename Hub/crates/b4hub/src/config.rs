//! The sign-in configuration `serve` reads at start: the sign-up policy, the WebAuthn relying
//! party, the public URL, the secret key, Sign in with Apple, and whether to trust
//! `X-Forwarded-For`.
//!
//! Every secret is an environment variable holding the value itself (`B4HUB_APPLE_PRIVATE_KEY` holds
//! the PEM contents, not a path), so any host's secret manager can inject it. `B4HUB_SECRET_KEY` and
//! the Apple team id, key id, and private key also have a `_FILE` form naming a file that holds the
//! value, for Docker and Kubernetes secrets mounted as files; the two forms are mutually
//! exclusive (see [`Settings::secret_value`]). A missing or malformed setting is a [`ConfigError`]
//! naming the variable and never its value; `serve` exits 2 on one.

use std::fmt;

use b4hub_db::ceremonies;
use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use url::Url;
use webauthn_rs::prelude::{Webauthn, WebauthnBuilder};

use crate::cli::{ConfigError, Settings};
use crate::routes::apple::SCHEMES;

/// Where Apple's endpoints live unless `B4HUB_APPLE_BASE_URL` (tests only) says otherwise.
pub const DEFAULT_APPLE_BASE_URL: &str = "https://appleid.apple.com";

/// The four variables that configure Sign in with Apple; all or none must be set. The first
/// three are secrets and may be given as `NAME_FILE` instead.
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
    /// `B4HUB_APPLE_SERVICES_ID` (optional, one of `audiences`): the client id the web flow
    /// signs in with. Without it (or without `B4HUB_PUBLIC_URL`) the hub offers only the
    /// native flow.
    pub services_id: Option<String>,
    /// `B4HUB_APPLE_CALLBACK_SCHEME` (with `services_id`, and only with it): the one app URL
    /// scheme the web flow hands a result back to, the flavour this hub serves (one of
    /// [`SCHEMES`]). Begin refuses any other (D-140).
    pub callback_scheme: Option<String>,
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
            .field("services_id", &self.services_id)
            .field("callback_scheme", &self.callback_scheme)
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
            trust_forwarded_for: settings.trust_proxy()?,
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
    let raw = settings.secret_value(NAME)?.ok_or_else(|| {
        ConfigError::new(
            NAME,
            "is not set (set B4HUB_SECRET_KEY or B4HUB_SECRET_KEY_FILE; 32 random bytes in \
             base64: openssl rand -base64 32)",
        )
    })?;
    STANDARD
        .decode(raw.trim())
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| ConfigError::new(NAME, "must be exactly 32 bytes in base64"))
}

fn apple(settings: &Settings) -> Result<Option<AppleConfig>, ConfigError> {
    let set: Vec<&str> = APPLE_VARS
        .iter()
        .copied()
        .filter(|name| match *name {
            "B4HUB_APPLE_AUDIENCES" => settings.var(name).is_some(),
            // `NAME_FILE` sets `NAME` as far as this rule goes.
            _ => settings.secret_is_set(name),
        })
        .collect();
    if set.is_empty() {
        for name in [
            "B4HUB_APPLE_BASE_URL",
            "B4HUB_APPLE_SERVICES_ID",
            "B4HUB_APPLE_CALLBACK_SCHEME",
        ] {
            if settings.var(name).is_some() {
                return Err(ConfigError::new(
                    name,
                    "is set without the other B4HUB_APPLE_* variables",
                ));
            }
        }
        return Ok(None);
    }
    if let Some(missing) = APPLE_VARS.iter().find(|name| !set.contains(name)) {
        return Err(ConfigError::new(
            missing,
            "is not set; Sign in with Apple needs all of B4HUB_APPLE_TEAM_ID, \
             B4HUB_APPLE_KEY_ID, B4HUB_APPLE_PRIVATE_KEY (each also as NAME_FILE), and \
             B4HUB_APPLE_AUDIENCES, or none",
        ));
    }
    // Every name here is in `set`, so a secret is `Some` once its `_FILE` is read.
    let secret = |name: &str| settings.secret_value(name).map(Option::unwrap_or_default);

    let team_id = apple_id("B4HUB_APPLE_TEAM_ID", secret("B4HUB_APPLE_TEAM_ID")?)?;
    let key_id = apple_id("B4HUB_APPLE_KEY_ID", secret("B4HUB_APPLE_KEY_ID")?)?;
    let private_key_pem = p8_pem(
        "B4HUB_APPLE_PRIVATE_KEY",
        &secret("B4HUB_APPLE_PRIVATE_KEY")?,
    )?;

    let audiences: Vec<String> = settings
        .var("B4HUB_APPLE_AUDIENCES")
        .unwrap_or_default()
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

    let services_id = match settings.var("B4HUB_APPLE_SERVICES_ID").map(str::trim) {
        None => None,
        Some(id) if audiences.iter().any(|a| a == id) => Some(id.to_string()),
        Some(_) => {
            return Err(ConfigError::new(
                "B4HUB_APPLE_SERVICES_ID",
                "must be one of the client ids in B4HUB_APPLE_AUDIENCES",
            ))
        }
    };

    let callback_scheme = callback_scheme(settings, services_id.is_some())?;

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
        services_id,
        callback_scheme,
        base_url,
    }))
}

/// The Apple id setting `name` (a team id or a key id) holding `value`: 10 uppercase letters and
/// digits, as Apple shows it. Sign in with Apple and APNs both use it; the value is not echoed.
pub(crate) fn apple_id(name: &str, value: String) -> Result<String, ConfigError> {
    if value.len() == 10
        && value
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
    {
        Ok(value)
    } else {
        Err(ConfigError::new(
            name,
            "must be 10 uppercase letters and digits, as Apple shows it",
        ))
    }
}

/// The `.p8` key setting `name` holding `value`, trimmed: one PKCS #8 PEM block (see
/// [`is_pkcs8_pem`]). Sign in with Apple and APNs both use it; the key is not echoed, and it is
/// parsed where it is used.
pub(crate) fn p8_pem(name: &str, value: &str) -> Result<String, ConfigError> {
    let pem = value.trim();
    if is_pkcs8_pem(pem) {
        Ok(pem.to_string())
    } else {
        Err(ConfigError::new(
            name,
            "must be the PEM contents of the .p8 key (-----BEGIN PRIVATE KEY----- ...), \
             not a path",
        ))
    }
}

/// `B4HUB_APPLE_CALLBACK_SCHEME`: required with the web flow's Services ID and refused without
/// it, so a hub that offers the web flow always names the one scheme it hands back to.
fn callback_scheme(settings: &Settings, web: bool) -> Result<Option<String>, ConfigError> {
    const NAME: &str = "B4HUB_APPLE_CALLBACK_SCHEME";
    match (settings.var(NAME).map(str::trim), web) {
        (None, false) => Ok(None),
        (Some(scheme), true) if SCHEMES.contains(&scheme) => Ok(Some(scheme.to_string())),
        (Some(_), true) => Err(ConfigError::new(
            NAME,
            "must be one of b4app, b4app-beta, b4app-local: the app flavour this hub serves",
        )),
        (None, true) => Err(ConfigError::new(
            NAME,
            "is not set; the web flow (B4HUB_APPLE_SERVICES_ID) needs the one app URL scheme it \
             hands back to: b4app, b4app-beta, or b4app-local",
        )),
        (Some(_), false) => Err(ConfigError::new(
            NAME,
            "is set without B4HUB_APPLE_SERVICES_ID; only the web flow uses it",
        )),
    }
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
            ("B4HUB_TRUST_X_FORWARDED_FOR", "yes"),
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
        assert_eq!(apple.services_id, None);
    }

    #[test]
    fn the_services_id_is_one_of_the_audiences() {
        let mut pairs = apple_pairs();
        pairs.push(("B4HUB_APPLE_SERVICES_ID", "com.cacheplane.b4app.signin"));
        pairs.push(("B4HUB_APPLE_CALLBACK_SCHEME", "b4app"));
        let apple = Config::from_settings(&settings(&pairs))
            .unwrap()
            .apple
            .unwrap();
        assert_eq!(
            apple.services_id.as_deref(),
            Some("com.cacheplane.b4app.signin")
        );

        let mut pairs = apple_pairs();
        pairs.push(("B4HUB_APPLE_SERVICES_ID", "com.example.other"));
        pairs.push(("B4HUB_APPLE_CALLBACK_SCHEME", "b4app"));
        let error = Config::from_settings(&settings(&pairs)).unwrap_err();
        assert_eq!(error.name, "B4HUB_APPLE_SERVICES_ID");

        let error = Config::from_settings(&settings(&[(
            "B4HUB_APPLE_SERVICES_ID",
            "com.cacheplane.b4app.signin",
        )]))
        .unwrap_err();
        assert_eq!(error.name, "B4HUB_APPLE_SERVICES_ID");
    }

    #[test]
    fn the_web_flow_names_its_one_callback_scheme() {
        let web = |scheme: Option<&'static str>| {
            let mut pairs = apple_pairs();
            pairs.push(("B4HUB_APPLE_SERVICES_ID", "com.cacheplane.b4app.signin"));
            if let Some(scheme) = scheme {
                pairs.push(("B4HUB_APPLE_CALLBACK_SCHEME", scheme));
            }
            Config::from_settings(&settings(&pairs))
        };
        for scheme in SCHEMES {
            let apple = web(Some(scheme)).unwrap().apple.unwrap();
            assert_eq!(apple.callback_scheme.as_deref(), Some(scheme));
        }

        // The web flow without a scheme, or with one no flavour claims, does not start.
        for scheme in [
            None,
            Some(""),
            Some("https"),
            Some("B4APP"),
            Some("b4app,b4app-beta"),
        ] {
            let error = web(scheme).unwrap_err();
            assert_eq!(error.name, "B4HUB_APPLE_CALLBACK_SCHEME", "{scheme:?}");
        }

        // Only the web flow uses it: without the Services ID, or without Apple, it is refused.
        let mut native = apple_pairs();
        native.push(("B4HUB_APPLE_CALLBACK_SCHEME", "b4app"));
        assert_eq!(
            Config::from_settings(&settings(&native)).unwrap_err().name,
            "B4HUB_APPLE_CALLBACK_SCHEME"
        );
        assert_eq!(
            Config::from_settings(&settings(&[("B4HUB_APPLE_CALLBACK_SCHEME", "b4app")]))
                .unwrap_err()
                .name,
            "B4HUB_APPLE_CALLBACK_SCHEME"
        );
        assert_eq!(
            Config::from_settings(&settings(&apple_pairs()))
                .unwrap()
                .apple
                .unwrap()
                .callback_scheme,
            None
        );
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

    /// A scratch directory of secret files, removed on drop.
    struct SecretFiles(std::path::PathBuf);

    impl SecretFiles {
        fn new() -> SecretFiles {
            let dir =
                std::env::temp_dir().join(format!("b4hub-config-{}", b4hub_core::ids::new_uuid()));
            std::fs::create_dir_all(&dir).unwrap();
            SecretFiles(dir)
        }

        /// Writes `contents` verbatim to a file and returns its path.
        fn write(&self, name: &str, contents: &str) -> String {
            let path = self.0.join(name);
            std::fs::write(&path, contents).unwrap();
            path.to_str().unwrap().to_string()
        }

        fn missing(&self, name: &str) -> String {
            self.0.join(name).to_str().unwrap().to_string()
        }
    }

    impl Drop for SecretFiles {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Settings with the rp id and the given pairs only (no `B4HUB_SECRET_KEY`).
    fn bare(pairs: &[(&str, &str)]) -> Settings {
        let mut all = vec![("B4HUB_WEBAUTHN_RP_ID", "local.b4.run")];
        all.extend_from_slice(pairs);
        Settings::from_pairs(all)
    }

    /// Every `_FILE` variant of the sign-in secrets, with a good value for each.
    fn file_variants() -> Vec<(&'static str, &'static str)> {
        vec![
            ("B4HUB_SECRET_KEY", KEY),
            ("B4HUB_APPLE_TEAM_ID", "ABCDE12345"),
            ("B4HUB_APPLE_KEY_ID", "KEY1234567"),
            ("B4HUB_APPLE_PRIVATE_KEY", PEM),
        ]
    }

    #[test]
    fn every_secret_can_come_from_a_file() {
        let files = SecretFiles::new();
        let mut pairs: Vec<(String, String)> = vec![(
            "B4HUB_APPLE_AUDIENCES".into(),
            "com.cacheplane.b4app.ios".into(),
        )];
        for (name, value) in file_variants() {
            let path = files.write(name, &format!("{value}\n"));
            pairs.push((format!("{name}_FILE"), path));
        }
        let pairs: Vec<(&str, &str)> = pairs
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        let config = Config::from_settings(&bare(&pairs)).unwrap();
        assert_eq!(config.secret_key, [7u8; 32]);
        let apple = config.apple.expect("Apple is configured");
        assert_eq!(apple.team_id, "ABCDE12345");
        assert_eq!(apple.key_id, "KEY1234567");
        assert_eq!(apple.private_key_pem, PEM);
    }

    #[test]
    fn a_trailing_newline_is_trimmed_and_the_pem_is_read_verbatim() {
        let files = SecretFiles::new();
        for ending in ["", "\n", "\r\n"] {
            let key = files.write("key", &format!("{KEY}{ending}"));
            let team = files.write("team", &format!("ABCDE12345{ending}"));
            let key_id = files.write("key_id", &format!("KEY1234567{ending}"));
            let pem = files.write("pem", &format!("{PEM}{ending}"));
            let mut config = Config::from_settings(&bare(&[
                ("B4HUB_SECRET_KEY_FILE", &key),
                ("B4HUB_APPLE_TEAM_ID_FILE", &team),
                ("B4HUB_APPLE_KEY_ID_FILE", &key_id),
                ("B4HUB_APPLE_PRIVATE_KEY_FILE", &pem),
                ("B4HUB_APPLE_AUDIENCES", "com.cacheplane.b4app.ios"),
            ]))
            .unwrap_or_else(|e| panic!("{ending:?}: {e}"));
            let apple = config.apple.take().unwrap();
            assert_eq!(apple.team_id, "ABCDE12345", "{ending:?}");
            assert_eq!(apple.key_id, "KEY1234567", "{ending:?}");
            // Multi-line, with its inner newlines intact.
            assert_eq!(apple.private_key_pem, PEM, "{ending:?}");
            // And it still parses as the signing key.
            crate::apple::AppleClient::new(&apple).unwrap_or_else(|e| panic!("{ending:?}: {e}"));
            assert_eq!(config.secret_key, [7u8; 32], "{ending:?}");
        }
    }

    #[test]
    fn a_variable_and_its_file_form_are_mutually_exclusive() {
        let files = SecretFiles::new();
        for (name, value) in file_variants() {
            let path = files.write(name, value);
            let file_name = format!("{name}_FILE");
            let mut pairs = apple_pairs();
            pairs.retain(|(n, _)| *n != name);
            pairs.push((name, value));
            pairs.push((&file_name, &path));
            let settings = if name == "B4HUB_SECRET_KEY" {
                // `settings` already sets the key; use the bare form so it is set once.
                let mut all = apple_pairs();
                all.push((name, value));
                all.push((&file_name, &path));
                bare(&all)
            } else {
                settings(&pairs)
            };
            let error = Config::from_settings(&settings).unwrap_err();
            assert_eq!(error.name, name);
            let text = error.to_string();
            assert!(text.contains(name) && text.contains(&file_name), "{text}");
            assert!(text.contains("both set"), "{text}");
            assert!(!text.contains(value), "{text}");
        }
    }

    #[test]
    fn a_missing_or_unreadable_file_names_the_file_variable() {
        let files = SecretFiles::new();
        let dir = files.0.to_str().unwrap().to_string();
        for (name, _) in file_variants() {
            let file_name = format!("{name}_FILE");
            for path in [files.missing("nope"), dir.clone()] {
                let others: Vec<(&str, &str)> = apple_pairs()
                    .into_iter()
                    .filter(|(n, _)| *n != name)
                    .collect();
                let mut pairs = others.clone();
                pairs.push((&file_name, &path));
                let settings = if name == "B4HUB_SECRET_KEY" {
                    bare(&pairs)
                } else {
                    settings(&pairs)
                };
                let error = Config::from_settings(&settings).unwrap_err();
                assert_eq!(error.name, file_name, "{path}");
            }
        }
    }

    #[test]
    fn the_apple_rule_counts_a_file_form_as_setting_the_variable() {
        let files = SecretFiles::new();
        let paths: Vec<(String, String)> = file_variants()
            .into_iter()
            .skip(1)
            .map(|(name, value)| (format!("{name}_FILE"), files.write(name, value)))
            .collect();
        let with_files = |skip: &str| {
            let mut pairs: Vec<(&str, &str)> = apple_pairs()
                .into_iter()
                .filter(|(n, _)| *n == "B4HUB_APPLE_AUDIENCES")
                .collect();
            for (name, path) in &paths {
                if name.trim_end_matches("_FILE") != skip {
                    pairs.push((name, path));
                }
            }
            Config::from_settings(&settings(&pairs))
        };
        assert!(with_files("").unwrap().apple.is_some());
        for skip in [
            "B4HUB_APPLE_TEAM_ID",
            "B4HUB_APPLE_KEY_ID",
            "B4HUB_APPLE_PRIVATE_KEY",
        ] {
            let error = with_files(skip).unwrap_err();
            assert_eq!(error.name, skip);
            assert!(error.reason.contains("is not set"), "{error}");
        }

        // One file form alone is the same error as the plain variable alone.
        let key_file = &paths[2].1;
        let alone_file =
            Config::from_settings(&settings(&[("B4HUB_APPLE_PRIVATE_KEY_FILE", key_file)]))
                .unwrap_err();
        let alone_plain =
            Config::from_settings(&settings(&[("B4HUB_APPLE_PRIVATE_KEY", PEM)])).unwrap_err();
        assert_eq!(alone_file.name, alone_plain.name);
        assert_eq!(alone_file.name, "B4HUB_APPLE_TEAM_ID");

        // And the tests-only extras still need Apple configured.
        let error =
            Config::from_settings(&settings(&[("B4HUB_APPLE_BASE_URL", "http://h")])).unwrap_err();
        assert_eq!(error.name, "B4HUB_APPLE_BASE_URL");
    }

    #[test]
    fn errors_about_file_contents_never_contain_them() {
        let files = SecretFiles::new();
        let bad_key = "hunter2-not-a-key";
        let key = files.write("key", bad_key);
        let error = Config::from_settings(&bare(&[("B4HUB_SECRET_KEY_FILE", &key)])).unwrap_err();
        assert_eq!(error.name, "B4HUB_SECRET_KEY");
        assert!(!error.to_string().contains(bad_key), "{error}");

        for (name, bad) in [
            ("B4HUB_APPLE_TEAM_ID", "hunter2-team"),
            ("B4HUB_APPLE_KEY_ID", "hunter2-key"),
            ("B4HUB_APPLE_PRIVATE_KEY", "hunter2-not-a-pem"),
        ] {
            let path = files.write(name, bad);
            let file_name = format!("{name}_FILE");
            let mut pairs: Vec<(&str, &str)> = apple_pairs()
                .into_iter()
                .filter(|(n, _)| *n != name)
                .collect();
            pairs.push((&file_name, &path));
            let error = Config::from_settings(&settings(&pairs)).unwrap_err();
            assert_eq!(error.name, name);
            assert!(!error.to_string().contains(bad), "{error}");
        }

        // A file that is not UTF-8 is unreadable, and the error says nothing of its bytes.
        let path = files.0.join("binary");
        std::fs::write(&path, b"hunter2\xff\xfe").unwrap();
        let error =
            Config::from_settings(&bare(&[("B4HUB_SECRET_KEY_FILE", path.to_str().unwrap())]))
                .unwrap_err();
        assert_eq!(error.name, "B4HUB_SECRET_KEY_FILE");
        assert!(!error.to_string().contains("hunter2"), "{error}");
    }
}
