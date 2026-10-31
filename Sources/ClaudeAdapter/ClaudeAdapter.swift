import Foundation
import WorkspaceProtocol

/// Claude Code adapter. Only inspection is implemented; stream-json sessions, permission bridges,
/// and interruption land in M2 on top of the verified `ClaudeStream` frames.
public struct ClaudeAdapter: AgentAdapter {
  public let kind = ConnectionKind.claude
  public var executablePath: String?
  public var environment: [String: String]

  public init(executablePath: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.executablePath = executablePath
    self.environment = environment
  }

  public func inspectConnection() async throws -> ConnectionInspection {
    await ClaudeInspector.inspect(explicitPath: executablePath, environment: environment)
  }

  public func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    throw WorkspaceError.unsupported("claude.createSession", plannedFor: "M2")
  }

  public func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    throw WorkspaceError.unsupported("claude.loadSession", plannedFor: "M2")
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    throw WorkspaceError.unsupported("claude.sendTurn", plannedFor: "M2")
  }

  public func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    throw WorkspaceError.unsupported("claude.interrupt", plannedFor: "M2")
  }

  public func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    throw WorkspaceError.unsupported("claude.respond", plannedFor: "M2")
  }

  public func reconcile(_ ref: NativeSessionRef) async throws -> ReconcileResult {
    throw WorkspaceError.unsupported("claude.reconcile", plannedFor: "M2")
  }

  public func events() -> AsyncStream<AdapterEvent> {
    AsyncStream { $0.finish() }
  }

  public func dispose() async {}
}
