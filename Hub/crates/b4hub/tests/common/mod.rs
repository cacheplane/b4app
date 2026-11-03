//! Helpers shared by the hub's HTTP tests. Run with `source <(../scripts/test-db.sh)` first;
//! `#[sqlx::test]` creates one database per test.

#![allow(dead_code)]

pub mod authenticator;

use std::net::SocketAddr;
use std::time::Duration;

use axum::http::{HeaderMap, StatusCode};
use b4hub::config::{Config, Signup};
use b4hub::serve::{self, AppState};
use b4hub_db::Db;
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::Value;
use sqlx::PgPool;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use url::Url;

/// The relying party the tests' hubs use, and the origin a real client on it signs.
pub const RP_ID: &str = "local.b4.run";
pub const ORIGIN: &str = "https://local.b4.run";

pub fn admin_url(pool: &PgPool) -> String {
    let base = std::env::var("DATABASE_URL").expect("DATABASE_URL is set by test-db.sh");
    let mut url = Url::parse(&base).unwrap();
    let database = pool
        .connect_options()
        .get_database()
        .expect("test pool has a database")
        .to_string();
    url.set_path(&format!("/{database}"));
    url.to_string()
}

pub fn app_url(pool: &PgPool) -> String {
    let mut url = Url::parse(&admin_url(pool)).unwrap();
    url.set_username("b4hub_app").unwrap();
    url.set_password(Some("pw-test")).unwrap();
    url.to_string()
}

/// A configuration for tests: passkeys on `local.b4.run`, no Apple, the given sign-up policy.
pub fn config(signup: Signup) -> Config {
    Config {
        signup,
        rp_id: RP_ID.to_string(),
        public_url: None,
        secret_key: [7; 32],
        apple: None,
        trust_forwarded_for: false,
    }
}

/// App state over `db` with sign-up closed, the hub's default.
pub fn state(db: Db) -> AppState {
    AppState::new(db, config(Signup::Closed)).expect("the test configuration is valid")
}

/// Migrates the test database, then returns the owner handle and one connected as `b4hub_app`.
pub async fn migrated(pool: &PgPool) -> (Db, Db) {
    b4hub_db::migrate::run(&admin_url(pool), &app_url(pool))
        .await
        .unwrap();
    let admin = Db::connect(&admin_url(pool)).await.unwrap();
    let app = Db::connect(&app_url(pool)).await.unwrap();
    (admin, app)
}

type HttpClient = Client<HttpConnector, Full<Bytes>>;

/// A hub serving on a loopback port through `serve::run`, as `b4hub serve` does.
pub struct Hub {
    pub base: String,
    pub state: AppState,
    client: HttpClient,
    server: JoinHandle<()>,
}

/// One answer: status, headers, and the JSON body (`Null` when empty).
pub struct Answer {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Value,
}

impl Answer {
    pub fn code(&self) -> &str {
        self.body["error"]["details"]["code"]
            .as_str()
            .unwrap_or_default()
    }

    /// `details.reason`, when the error carries one.
    pub fn reason(&self) -> Option<&str> {
        self.body["error"]["details"]["reason"].as_str()
    }
}

impl Hub {
    pub async fn start(db: Db, config: Config) -> Hub {
        Hub::start_state(AppState::new(db, config).expect("the test configuration is valid")).await
    }

    /// A hub serving `state` as given (a test's own Apple revoker, say).
    pub async fn start_state(state: AppState) -> Hub {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr: SocketAddr = listener.local_addr().unwrap();
        let served = state.clone();
        let server = tokio::spawn(async move {
            serve::run(
                listener,
                served,
                Duration::from_secs(1),
                std::future::pending(),
            )
            .await
            .unwrap();
        });
        Hub {
            base: format!("http://{addr}"),
            state,
            client: Client::builder(TokioExecutor::new()).build_http(),
            server,
        }
    }

    pub async fn send(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        headers: &[(&str, &str)],
    ) -> Answer {
        let mut request = hyper::Request::builder()
            .method(method)
            .uri(format!("{}{path}", self.base));
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let request = match body {
            Some(body) => request
                .header("content-type", "application/json")
                .body(Full::new(Bytes::from(body.to_string()))),
            None => request.body(Full::new(Bytes::new())),
        }
        .unwrap();
        let response = self.client.request(request).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or_else(|_| {
                panic!(
                    "{method} {path} answered {status} with a body that is not JSON: {:?}",
                    String::from_utf8_lossy(&bytes)
                )
            })
        };
        Answer {
            status,
            headers,
            body,
        }
    }

    /// Posts `pairs` as an `application/x-www-form-urlencoded` body, as a browser posts a form.
    pub async fn post_form(&self, path: &str, pairs: &[(&str, &str)]) -> Answer {
        let body: String = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(pairs)
            .finish();
        let request = hyper::Request::builder()
            .method("POST")
            .uri(format!("{}{path}", self.base))
            .header("content-type", "application/x-www-form-urlencoded")
            .body(Full::new(Bytes::from(body)))
            .unwrap();
        let response = self.client.request(request).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).unwrap_or(Value::Null)
        };
        Answer {
            status,
            headers,
            body,
        }
    }

    pub async fn get(&self, path: &str, token: Option<&str>) -> Answer {
        let bearer = token.map(|t| format!("Bearer {t}"));
        let headers: Vec<(&str, &str)> = bearer
            .as_deref()
            .map(|b| vec![("authorization", b)])
            .unwrap_or_default();
        self.send("GET", path, None, &headers).await
    }

    pub async fn post(&self, path: &str, body: Option<&Value>) -> Answer {
        self.send("POST", path, body, &[]).await
    }
}

/// The step-up routes (D-135) and the header a gated change carries its grant in.
pub const STEP_UP_BEGIN: &str = "/v1/me/step-up/passkey/begin";
pub const STEP_UP_FINISH: &str = "/v1/me/step-up/passkey/finish";
pub const STEP_UP_HEADER: &str = "b4-step-up";

impl Hub {
    /// Sends with the device token `token` and, when given, the step-up grant `grant`.
    pub async fn stepped(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        token: &str,
        grant: Option<&str>,
    ) -> Answer {
        let bearer = format!("Bearer {token}");
        let mut headers = vec![("authorization", bearer.as_str())];
        if let Some(grant) = grant {
            headers.push((STEP_UP_HEADER, grant));
        }
        self.send(method, path, body, &headers).await
    }

    /// Earns a step-up grant for the device of `token` with `authenticator`'s credential `index`.
    pub async fn step_up(
        &self,
        authenticator: &mut authenticator::Authenticator,
        index: usize,
        token: &str,
    ) -> String {
        let begun = self.stepped("POST", STEP_UP_BEGIN, None, token, None).await;
        assert_eq!(begun.status, StatusCode::OK, "{}", begun.body);
        let assertion = authenticator.assert_with(index, &begun.body["authentication"]);
        let body = serde_json::json!({
            "ceremonyId": begun.body["ceremonyId"],
            "assertion": assertion,
        });
        let finished = self
            .stepped("POST", STEP_UP_FINISH, Some(&body), token, None)
            .await;
        assert_eq!(finished.status, StatusCode::OK, "{}", finished.body);
        finished.body["stepUp"].as_str().unwrap().to_string()
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.server.abort();
    }
}
