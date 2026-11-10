//! When the hub notifies a phone, and what the notification says (decisions D-121 and D-124).
//! Pure rules and payloads; the database detection and the sender live elsewhere. A notification
//! body is one of four fixed phrases, never transcript, command, or path text.

use serde_json::{json, Value};

/// A turn notifies only when it changed within this many seconds of the hub's clock, so an upload
/// of old history does not flood the phone.
pub const TURN_RECENCY_SECS: i64 = 600;

/// The longest notification title, in characters.
const TITLE_LIMIT: usize = 100;

/// Why the user is being notified.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
    Approval,
    Question,
    Replied,
    Failed,
}

impl Reason {
    /// The wire name carried in the payload's `reason`.
    pub fn as_str(&self) -> &'static str {
        match self {
            Reason::Approval => "approval",
            Reason::Question => "question",
            Reason::Replied => "replied",
            Reason::Failed => "failed",
        }
    }

    /// The notification body.
    pub fn body(&self) -> &'static str {
        match self {
            Reason::Approval => "Waiting for your approval",
            Reason::Question => "Has a question for you",
            Reason::Replied => "Replied",
            Reason::Failed => "Turn failed",
        }
    }
}

/// A request notifies while it is `pending`. Questions and elicitations say so; every other kind,
/// including one this hub does not know, asks for approval.
pub fn request_reason(kind: &str, state: &str) -> Option<Reason> {
    if state != "pending" {
        return None;
    }
    match kind {
        "user_question" | "elicitation" => Some(Reason::Question),
        _ => Some(Reason::Approval),
    }
}

/// A turn notifies when it is `terminal` with a `completed` or `failed` outcome and changed
/// recently (`recent`, within [`TURN_RECENCY_SECS`]). A cancelled turn, a terminal turn with no
/// outcome yet, and any status or outcome this hub does not know never notify.
pub fn turn_reason(status: &str, outcome: Option<&str>, recent: bool) -> Option<Reason> {
    if status != "terminal" || !recent {
        return None;
    }
    match outcome {
        Some("completed") => Some(Reason::Replied),
        Some("failed") => Some(Reason::Failed),
        _ => None,
    }
}

/// The notification title: the thread title trimmed, `Untitled thread` when it is missing or
/// blank, cut to 100 characters on a character boundary.
pub fn alert_title(thread_title: Option<&str>) -> String {
    let trimmed = thread_title.map(str::trim).unwrap_or("");
    if trimmed.is_empty() {
        return "Untitled thread".to_string();
    }
    trimmed.chars().take(TITLE_LIMIT).collect()
}

/// What a notification key names: a request or a turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Request,
    Turn,
}

impl Kind {
    /// The prefix of a notification key.
    pub fn as_str(&self) -> &'static str {
        match self {
            Kind::Request => "request",
            Kind::Turn => "turn",
        }
    }
}

/// The notification key, `request:<id>` or `turn:<id>`. It rides in the payload and is the APNs
/// collapse id, so the app and the hub name one notification the same way.
pub fn key(kind: Kind, row_id: &str) -> String {
    format!("{}:{row_id}", kind.as_str())
}

/// The APNs alert payload. It carries the thread id, the notification `key`, and the app icon
/// `badge`, and no URL; the app builds the link itself.
pub fn payload(thread_id: &str, title: &str, reason: Reason, key: &str, badge: i64) -> Value {
    json!({
        "aps": {
            "alert": { "title": title, "body": reason.body() },
            "sound": "default",
            "badge": badge,
            "content-available": 1,
            "thread-id": thread_id,
        },
        "threadId": thread_id,
        "reason": reason.as_str(),
        "key": key,
    })
}

/// [`payload`] plus the `Simulator Target Bundle` key `simctl push` reads from a `.apns` file.
pub fn spool_payload(
    thread_id: &str,
    title: &str,
    reason: Reason,
    key: &str,
    badge: i64,
    bundle_id: &str,
) -> Value {
    with_bundle(payload(thread_id, title, reason, key, badge), bundle_id)
}

/// The background push that withdraws delivered notifications: it names their `keys` and carries
/// no alert, sound, or badge, which Apple requires of a `content-available` background push.
pub fn withdrawal_payload(keys: &[String]) -> Value {
    json!({
        "aps": { "content-available": 1 },
        "withdraw": keys,
    })
}

/// A silent hint to catch up the mirror, without navigation or notification removal semantics.
pub fn refresh_payload() -> Value {
    json!({ "aps": { "content-available": 1 }, "refresh": true })
}

/// [`refresh_payload`] plus the Simulator's target bundle.
pub fn spool_refresh_payload(bundle_id: &str) -> Value {
    with_bundle(refresh_payload(), bundle_id)
}

/// [`withdrawal_payload`] plus the `Simulator Target Bundle` key.
pub fn spool_withdrawal_payload(keys: &[String], bundle_id: &str) -> Value {
    with_bundle(withdrawal_payload(keys), bundle_id)
}

fn with_bundle(mut value: Value, bundle_id: &str) -> Value {
    value["Simulator Target Bundle"] = Value::String(bundle_id.to_string());
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const FIXTURE: &str = include_str!("../../../../Tests/Fixtures/sync/push.json");

    fn reason_name(reason: Option<Reason>) -> Option<&'static str> {
        reason.map(|r| r.as_str())
    }

    #[test]
    fn fixture_cases() {
        let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
        let str_of = |v: &Value, key: &str| v[key].as_str().unwrap().to_string();
        let opt_of = |v: &Value, key: &str| v[key].as_str().map(str::to_string);

        let requests = fixture["requests"].as_array().unwrap();
        assert!(!requests.is_empty());
        for case in requests {
            let (kind, state) = (str_of(case, "kind"), str_of(case, "state"));
            assert_eq!(
                reason_name(request_reason(&kind, &state)),
                opt_of(case, "reason").as_deref(),
                "request {kind} {state}"
            );
        }

        let turns = fixture["turns"].as_array().unwrap();
        assert!(!turns.is_empty());
        for case in turns {
            let status = str_of(case, "status");
            let outcome = opt_of(case, "outcome");
            let recent = case["recent"].as_bool().unwrap();
            assert_eq!(
                reason_name(turn_reason(&status, outcome.as_deref(), recent)),
                opt_of(case, "reason").as_deref(),
                "turn {status} {outcome:?} recent={recent}"
            );
        }

        let titles = fixture["titles"].as_array().unwrap();
        assert!(!titles.is_empty());
        for case in titles {
            let input = opt_of(case, "input");
            assert_eq!(
                alert_title(input.as_deref()),
                str_of(case, "expected"),
                "title {input:?}"
            );
        }

        let payloads = fixture["payloads"].as_array().unwrap();
        assert!(!payloads.is_empty());
        for case in payloads {
            let reason = match str_of(case, "reason").as_str() {
                "approval" => Reason::Approval,
                "question" => Reason::Question,
                "replied" => Reason::Replied,
                "failed" => Reason::Failed,
                other => panic!("unknown reason {other}"),
            };
            let (thread_id, title) = (str_of(case, "threadId"), str_of(case, "title"));
            let (key, badge) = (str_of(case, "key"), case["badge"].as_i64().unwrap());
            let bundle = str_of(case, "bundleId");
            assert_eq!(
                spool_payload(&thread_id, &title, reason, &key, badge, &bundle),
                case["expected"],
                "spool payload for {thread_id}"
            );
            let mut plain = case["expected"].clone();
            plain
                .as_object_mut()
                .unwrap()
                .remove("Simulator Target Bundle");
            assert_eq!(payload(&thread_id, &title, reason, &key, badge), plain);
        }

        let withdrawals = fixture["withdrawals"].as_array().unwrap();
        assert!(withdrawals.len() >= 2);
        for case in withdrawals {
            let keys: Vec<String> = case["keys"]
                .as_array()
                .unwrap()
                .iter()
                .map(|k| k.as_str().unwrap().to_string())
                .collect();
            let bundle = str_of(case, "bundleId");
            assert_eq!(
                spool_withdrawal_payload(&keys, &bundle),
                case["expected"],
                "spool withdrawal for {keys:?}"
            );
            let mut plain = case["expected"].clone();
            plain
                .as_object_mut()
                .unwrap()
                .remove("Simulator Target Bundle");
            assert_eq!(withdrawal_payload(&keys), plain);
        }
    }

    #[test]
    fn refresh_fixture() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../../../Tests/Fixtures/sync/push.json"))
                .unwrap();
        let entries = fixture["refreshes"].as_array().unwrap();
        assert!(!entries.is_empty());
        for entry in entries {
            let bundle = entry["bundleId"].as_str().unwrap();
            assert_eq!(spool_refresh_payload(bundle), entry["expected"]);
            let mut plain = entry["expected"].clone();
            plain
                .as_object_mut()
                .unwrap()
                .remove("Simulator Target Bundle");
            assert_eq!(refresh_payload(), plain);
        }
    }

    #[test]
    fn keys_name_their_kind() {
        assert_eq!(Kind::Request.as_str(), "request");
        assert_eq!(Kind::Turn.as_str(), "turn");
        assert_eq!(key(Kind::Request, "req-1"), "request:req-1");
        assert_eq!(key(Kind::Turn, "turn-9"), "turn:turn-9");
    }

    #[test]
    fn a_withdrawal_carries_no_alert_sound_or_badge() {
        let value = withdrawal_payload(&["request:a".to_string()]);
        assert_eq!(
            value,
            json!({ "aps": { "content-available": 1 }, "withdraw": ["request:a"] })
        );
        assert!(value["aps"].get("alert").is_none());
        assert!(value["aps"].get("sound").is_none());
        assert!(value["aps"].get("badge").is_none());
    }

    #[test]
    fn bodies_are_the_four_phrases() {
        assert_eq!(Reason::Approval.body(), "Waiting for your approval");
        assert_eq!(Reason::Question.body(), "Has a question for you");
        assert_eq!(Reason::Replied.body(), "Replied");
        assert_eq!(Reason::Failed.body(), "Turn failed");
    }
}
