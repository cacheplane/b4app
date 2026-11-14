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

/// A command a runtime runs when a message starts with `/name`, as the composer lists it. The
/// runtime owns what it does; the app only knows its name and what the runtime says about it.
public struct RuntimeCommand: Codable, Sendable, Equatable, Identifiable {
  /// The name without its slash ("compact", "superpowers:brainstorming").
  public var name: String
  public var description: String
  /// What the runtime says may follow the name ("[issue description]"); nil when it takes nothing.
  public var argumentHint: String?
  public var aliases: [String]?

  public var id: String { name }

  public init(name: String, description: String = "", argumentHint: String? = nil, aliases: [String]? = nil) {
    self.name = name
    self.description = description
    self.argumentHint = argumentHint
    self.aliases = aliases
  }

  public static let descriptionLimit = 160
  public static let listLimit = 300

  /// A runtime's list as the app keeps it: names a composer token can spell, no duplicates, one
  /// line of description cut to `descriptionLimit`, and at most `listLimit` commands.
  public static func normalized(_ commands: [RuntimeCommand]) -> [RuntimeCommand] {
    var seen = Set<String>()
    var kept: [RuntimeCommand] = []
    for var command in commands {
      if command.name.hasPrefix("/") { command.name.removeFirst() }
      guard isName(command.name), seen.insert(command.name).inserted else { continue }
      let line = command.description.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      command.description =
        trimmed.count > descriptionLimit ? trimmed.prefix(descriptionLimit - 1) + "\u{2026}" : trimmed
      let hint = command.argumentHint?.trimmingCharacters(in: .whitespaces) ?? ""
      command.argumentHint = hint.isEmpty ? nil : String(hint.prefix(descriptionLimit))
      let aliases = (command.aliases ?? []).filter { isName($0) && $0 != command.name }
      command.aliases = aliases.isEmpty ? nil : aliases
      kept.append(command)
      if kept.count == listLimit { break }
    }
    return kept
  }

  /// Letters, digits, and the marks command names use; what a composer token may hold.
  public static func isName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 80
      && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }
  }

  /// What to store when a runtime reports `reported` and `stored` is the list kept so far; nil
  /// leaves the stored list alone. A runtime's list can come back short while its plugins load, so
  /// a report that names nothing new changes nothing; one that names something new replaces the list.
  public static func replacement(stored: [RuntimeCommand]?, reported: [RuntimeCommand]) -> [RuntimeCommand]? {
    let reported = normalized(reported)
    guard let stored else { return reported }
    let known = Set(stored.map(\.name))
    return reported.contains { !known.contains($0.name) } ? reported : nil
  }

  /// The command a message starts with and the rest of it: ("review", "the auth change") for
  /// "/review the auth change". Nil when the text does not start with a command token.
  public static func parse(_ text: String) -> (name: String, arguments: String)? {
    guard text.first == "/" else { return nil }
    let body = text.dropFirst()
    let name = String(body.prefix { !$0.isWhitespace })
    guard isName(name) else { return nil }
    let arguments = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return (name, arguments)
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
