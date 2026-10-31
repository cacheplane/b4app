import Foundation
import WorkspaceProtocol

/// Codex adapter. Only inspection is implemented; session methods throw `unsupported_capability`
/// until M1 delivers the app-server bridge.
public struct CodexAdapter: AgentAdapter {
  public let kind = ConnectionKind.codex
  public var executablePath: String?
  public var environment: [String: String]

  public init(executablePath: String?, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.executablePath = executablePath
    self.environment = environment
  }

  public func inspectConnection() async throws -> ConnectionInspection {
    await CodexInspector.inspect(explicitPath: executablePath, environment: environment)
  }

  public func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    throw WorkspaceError.unsupported("codex.createSession", plannedFor: "M1")
  }

  public func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    throw WorkspaceError.unsupported("codex.loadSession", plannedFor: "M1")
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    throw WorkspaceError.unsupported("codex.sendTurn", plannedFor: "M1")
  }

  public func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    throw WorkspaceError.unsupported("codex.interrupt", plannedFor: "M1")
  }

  public func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    throw WorkspaceError.unsupported("codex.respond", plannedFor: "M1")
  }

  public func reconcile(_ ref: NativeSessionRef) async throws -> ReconcileResult {
    throw WorkspaceError.unsupported("codex.reconcile", plannedFor: "M1")
  }

  public func events() -> AsyncStream<AdapterEvent> {
    AsyncStream { $0.finish() }
  }

  public func dispose() async {}
}
