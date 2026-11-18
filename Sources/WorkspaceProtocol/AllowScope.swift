import Foundation

/// How far a request's wider allow reaches, as its adapter wrote it into the request's payload
/// (`request.allowScope`). A request with none can be allowed once or denied and nothing wider: the
/// card offers no wider button and the coordinator refuses `allow_always` for it (D-248).
public enum AllowScope: String, Sendable, Equatable, CaseIterable {
  /// The runtime stops asking for the rest of the session (Codex).
  case session
  /// The runtime keeps the grant itself, past the session (B4).
  case always

  public static let payloadKey = "allowScope"

  /// The scope in a runtime request's payload, or nil when it has none or one this build does not know.
  public init?(requestPayload: JSONValue) {
    guard let raw = requestPayload["request"]?[Self.payloadKey]?.stringValue, let scope = Self(rawValue: raw)
    else { return nil }
    self = scope
  }
}
