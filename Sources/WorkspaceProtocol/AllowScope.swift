import Foundation

/// How far a request's wider allow reaches, as its adapter wrote it into the request's payload
/// (`request.allowScope`). A request with none can be allowed once or denied and nothing wider: the
/// card offers no wider button and the coordinator refuses `allow_always` for it (D-248).
public enum AllowScope: String, Sendable, Equatable, CaseIterable {
  /// The runtime stops asking for the rest of the session (Codex), or for the rule the request names
  /// (Claude Code).
  case session
  /// The runtime keeps the grant itself, past the session (B4).
  case always

  public static let payloadKey = "allowScope"
  /// Where a request says what its wider allow covers, when that is one rule and not the whole kind
  /// of request (`request.allowRule`; Claude Code, `Bash(touch one.txt)`).
  public static let rulePayloadKey = "allowRule"

  /// What the wider allow of a request covers, when its adapter said so.
  public static func rule(requestPayload: JSONValue) -> String? {
    guard AllowScope(requestPayload: requestPayload) != nil,
      let rule = requestPayload["request"]?[rulePayloadKey]?.stringValue, !rule.isEmpty
    else { return nil }
    return rule
  }

  /// The scope in a runtime request's payload, or nil when it has none or one this build does not know.
  public init?(requestPayload: JSONValue) {
    guard let raw = requestPayload["request"]?[Self.payloadKey]?.stringValue, let scope = Self(rawValue: raw)
    else { return nil }
    self = scope
  }
}
