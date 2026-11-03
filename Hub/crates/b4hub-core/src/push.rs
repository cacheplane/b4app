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

/// The APNs payload. It carries the thread id and no URL; the app builds the link itself.
pub fn payload(thread_id: &str, title: &str, reason: Reason) -> Value {
    json!({
        "aps": {
            "alert": { "title": title, "body": reason.body() },
            "sound": "default",
            "content-available": 1,
            "thread-id": thread_id,
        },
        "threadId": thread_id,
        "reason": reason.as_str(),
    })
}

/// [`payload`] plus the `Simulator Target Bundle` key `simctl push` reads from a `.apns` file.
pub fn spool_payload(thread_id: &str, title: &str, reason: Reason, bundle_id: &str) -> Value {
    let mut value = payload(thread_id, title, reason);
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
            let bundle = str_of(case, "bundleId");
            assert_eq!(
                spool_payload(&thread_id, &title, reason, &bundle),
                case["expected"],
                "spool payload for {thread_id}"
            );
            let mut plain = case["expected"].clone();
            plain
                .as_object_mut()
                .unwrap()
                .remove("Simulator Target Bundle");
            assert_eq!(payload(&thread_id, &title, reason), plain);
        }
    }

    #[test]
    fn bodies_are_the_four_phrases() {
        assert_eq!(Reason::Approval.body(), "Waiting for your approval");
        assert_eq!(Reason::Question.body(), "Has a question for you");
        assert_eq!(Reason::Replied.body(), "Replied");
        assert_eq!(Reason::Failed.body(), "Turn failed");
    }
}
