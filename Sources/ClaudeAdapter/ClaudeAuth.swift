import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// Shape of `claude auth status --json` on Claude Code 2.1.x (verified on 2.1.282).
public struct ClaudeAuthStatus: Decodable, Sendable, Equatable {
  public var loggedIn: Bool
  public var authMethod: String
  public var apiProvider: String?
  public var configDirectory: String?
  public var email: String?
  public var orgId: String?
  public var orgName: String?
  public var subscriptionType: String?
  public var projectsDirectory: String?

  public static func parse(_ json: String) -> ClaudeAuthStatus? {
    try? JSONDecoder().decode(ClaudeAuthStatus.self, from: Data(json.utf8))
  }
}

public struct ClaudeAuthAssessment: Sendable, Equatable {
  public var authStatus: AuthStatus
  public var nativeScope: String?
  public var message: String
  public var error: WorkspaceError?
}

public enum ClaudeAuth {
  public static func inheritedCredentials(in env: [String: String]) -> [String] {
    ClaudeStream.inheritedCredentialVariables.filter { !(env[$0] ?? "").isEmpty }
  }

  /// Map native auth status to app state. The app intends subscription (claude.ai) auth; an inherited
  /// API key would silently switch billing mode, so it is a conflict, not success.
  public static func assess(
    _ status: ClaudeAuthStatus, environment env: [String: String]
  ) -> ClaudeAuthAssessment {
    let inherited = inheritedCredentials(in: env)
    let scope = status.email ?? status.configDirectory
    if !inherited.isEmpty {
      return ClaudeAuthAssessment(
        authStatus: .error, nativeScope: scope,
        message:
          "\(inherited.joined(separator: ", ")) is set in the environment and would override the Claude plan login. Unset it for this app or choose API billing explicitly.",
        error: WorkspaceError(
          .authModeConflict, "Inherited API credentials conflict with subscription auth.",
          details: ["variables": .array(inherited.map(JSONValue.string))]))
    }
    if !status.loggedIn || status.authMethod == "none" {
      return ClaudeAuthAssessment(
        authStatus: .required, nativeScope: nil,
        message: "Not signed in. Run `claude auth login` or use Sign in from the Connections screen.",
        error: WorkspaceError(.authRequired, "Claude Code is not signed in."))
    }
    if status.authMethod == "claude.ai" || status.authMethod == "oauth_token" {
      let plan = status.subscriptionType.map { " (\($0))" } ?? ""
      return ClaudeAuthAssessment(
        authStatus: .authenticated, nativeScope: scope,
        message: "Signed in as \(status.email ?? "unknown")\(plan) via \(status.authMethod).", error: nil)
    }
    return ClaudeAuthAssessment(
      authStatus: .error, nativeScope: scope,
      message:
        "Claude Code is using \"\(status.authMethod)\" authentication, not a Claude plan login. Sign in with `claude auth login` to use plan allowances.",
      error: WorkspaceError(.authModeConflict, "Unexpected auth method \"\(status.authMethod)\"."))
  }

  public static func readStatus(
    executable: String, environment env: [String: String]
  ) async -> (status: ClaudeAuthStatus?, raw: String) {
    guard
      let result = try? await CommandRunner.run(
        executable, ["auth", "status", "--json"],
        options: CommandOptions(timeout: .seconds(15), environment: env))
    else { return (nil, "") }
    return (ClaudeAuthStatus.parse(result.stdout), result.stdout)
  }
}
