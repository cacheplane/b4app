import Foundation
import WorkspaceProtocol

/// Spec section 12: every failure gets a user-facing explanation and a specific next action. The
/// mapping lives here so the composer banner, the connections screen, and tests share one table.
public struct Remediation: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case none
    case signIn(connectionId: String)
    case openConnections
    case openServers(serverId: String?)
    case newThread
    case checkAgain
    case abandonTurn
    case openThread(threadId: String)
  }

  public var message: String
  public var action: Action
  public var actionTitle: String?

  public init(message: String, action: Action = .none, actionTitle: String? = nil) {
    self.message = message
    self.action = action
    self.actionTitle = actionTitle
  }

  /// The remedy for an error on `connection` (nil when the failure is not tied to one).
  public static func `for`(_ error: WorkspaceError, connection: Connection?) -> Remediation {
    let reason = error.details?["reason"]?.stringValue
    switch error.code {
    case .authRequired:
      switch connection?.kind {
      case .codex?:
        return Remediation(
          message:
            "Codex is signed out or the login expired. Sign in with ChatGPT again; nothing was re-sent.",
          action: .signIn(connectionId: connection!.id), actionTitle: "Sign in with ChatGPT")
      case .claude?:
        return Remediation(
          message: "Claude Code is signed out or the login expired. Sign in again; nothing was re-sent.",
          action: .signIn(connectionId: connection!.id), actionTitle: "Sign in to Claude")
      case .b4?:
        return Remediation(
          message:
            "The endpoint rejected the credential. Store a new one with `agent-workspace credential add` and attach the endpoint again with its reference.",
          action: .openConnections, actionTitle: "Open Connections")
      case nil:
        return Remediation(message: error.message, action: .openConnections, actionTitle: "Open Connections")
      }
    case .allowanceExceeded:
      return Remediation(
        message:
          "The plan's allowance or rate limit is exhausted. Wait for it to reset or change the plan; the app never switches to API billing and nothing was re-sent.",
        action: .none)
    case .authModeConflict:
      return Remediation(
        message:
          "An inherited API key would switch Claude Code to API billing. Remove ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN) from the environment the app and the coordinator start with, then check the connection again.",
        action: .openConnections, actionTitle: "Open Connections")
    case .incompatibleVersion, .missingExecutable:
      return Remediation(
        message: "\(error.message) Install or update the runtime, then check the connection.",
        action: .openConnections, actionTitle: "Open Connections")
    case .endpointUnavailable where reason == "server_stopped":
      return Remediation(
        message:
          "The managed server is stopped. Start it from Local servers; the thread continues on the same route.",
        action: .openServers(serverId: error.details?["serverId"]?.stringValue),
        actionTitle: "Open Local servers")
    case .endpointUnavailable:
      return Remediation(
        message:
          "\(error.message) Check that the server or runtime is running, then try again; nothing was re-sent.",
        action: .checkAgain, actionTitle: "Check again")
    case .nativeSessionMissing:
      return Remediation(
        message:
          "The runtime no longer has this thread's native session. The cached transcript stays; start a new thread to continue.",
        action: .newThread, actionTitle: "New thread")
    case .identityChanged:
      return Remediation(
        message:
          "The connection now presents a different account or server than this thread was created under. Start a new thread for the current identity; old threads are never retargeted.",
        action: .newThread, actionTitle: "New thread")
    case .submissionUnknown, .cancellationUnconfirmed:
      return Remediation(
        message:
          "\(error.message) Ask the runtime again, or abandon the turn to free the thread; nothing is re-sent either way.",
        action: .checkAgain, actionTitle: "Check again")
    case .staleRuntimeRequest:
      return Remediation(
        message:
          "That request is no longer pending; the runtime presents its current requests after a reconnect.",
        action: .checkAgain, actionTitle: "Check again")
    case .protocolInvalid where reason == "directory_locked":
      let other = error.details?["threadId"]?.stringValue
      return Remediation(
        message: error.message, action: other.map { .openThread(threadId: $0) } ?? .none,
        actionTitle: other == nil ? nil : "Open that thread")
    case .protocolInvalid where reason == "turn_active":
      let status = error.details?["status"]?.stringValue ?? "active"
      return Remediation(
        message:
          status == "reconciling"
          ? "The previous turn's outcome is unknown. Check again or abandon it before sending another message."
          : "A turn is still \(status). Wait for it or stop it; your draft stays here.",
        action: status == "reconciling" ? .abandonTurn : .none,
        actionTitle: status == "reconciling" ? "Abandon turn" : nil)
    case .ownedProcessConflict:
      return Remediation(
        message: "\(error.message) Nothing was stopped.", action: .openServers(serverId: nil),
        actionTitle: "Open Local servers")
    case .unsupportedCapability, .notImplemented:
      return Remediation(message: error.message, action: .none)
    case .protocolInvalid, .methodUnknown, .snapshotRequired, .notFound, .internalError:
      return Remediation(message: error.message, action: .none)
    }
  }
}
