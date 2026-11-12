import Foundation

/// A model a runtime accepts for a new conversation, as the composer lists it.
public struct RuntimeModel: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

/// One permission choice for a runtime; `id` is what the adapter receives.
public struct PermissionOption: Sendable, Equatable, Identifiable {
  public var id: String
  public var label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

/// The models and permission modes each runtime offers when a thread starts.
public enum RuntimeOptions {
  /// Shown when no permission choice was made: the runtime's own configuration applies.
  public static let asConfiguredLabel = "As configured"
  /// Shown when no model was chosen: the runtime picks its default.
  public static let defaultModelLabel = "Default"

  /// Claude Code's aliases for `--model`; the CLI resolves each to its current model.
  public static let claudeModels: [RuntimeModel] = [
    RuntimeModel(id: "opus", label: "Opus"),
    RuntimeModel(id: "sonnet", label: "Sonnet"),
    RuntimeModel(id: "haiku", label: "Haiku"),
  ]

  public static func permissions(for kind: ConnectionKind) -> [PermissionOption] {
    switch kind {
    case .claude:
      // Claude Code's `--permission-mode` values.
      return [
        PermissionOption(id: "default", label: "Ask permissions"),
        PermissionOption(id: "acceptEdits", label: "Accept edits"),
        PermissionOption(id: "plan", label: "Plan mode"),
        PermissionOption(id: "bypassPermissions", label: "Bypass permissions"),
      ]
    case .codex:
      return CodexPermission.allCases.map { PermissionOption(id: $0.rawValue, label: $0.label) }
    case .b4, .agentProtocol:
      return []
    }
  }

  /// The label for a stored permission id: "As configured" for none, the id itself when unknown.
  public static func permissionLabel(_ id: String?, kind: ConnectionKind) -> String {
    guard let id else { return asConfiguredLabel }
    return permissions(for: kind).first { $0.id == id }?.label ?? id
  }
}

/// Codex's three presets, the choices in its `/approvals` menu. Each maps to a pair of
/// `turn/start` parameters. The shapes come from `codex app-server generate-json-schema`
/// for codex-cli 0.166.0: `AskForApproval` (`untrusted`, `on-request`, `never`, ...) and
/// `TurnStartParams.sandboxPolicy`, a tagged object.
public enum CodexPermission: String, Sendable, CaseIterable {
  case readOnly = "read-only"
  case auto
  case fullAccess = "full-access"

  var label: String {
    switch self {
    case .readOnly: "Read only"
    case .auto: "Auto"
    case .fullAccess: "Full access"
    }
  }

  public var approvalPolicy: String {
    switch self {
    case .readOnly, .auto: "on-request"
    case .fullAccess: "never"
    }
  }

  /// `writableRoots` applies only to Auto, where Codex may write inside the project.
  public func sandboxPolicy(writableRoots: [String]) -> JSONValue {
    switch self {
    case .readOnly: ["type": "readOnly"]
    case .auto: ["type": "workspaceWrite", "writableRoots": .array(writableRoots.map { .string($0) })]
    case .fullAccess: ["type": "dangerFullAccess"]
    }
  }
}
