import Foundation
import WorkspaceProtocol

/// B4 Agent Protocol adapter. Only endpoint inspection is implemented; thread creation, streaming,
/// resume, reattach, and cancel land in M3 on top of `SSEParser` and `B4StreamEvent`.
public struct B4Adapter: AgentAdapter {
  public let kind = ConnectionKind.b4
  public var baseURL: String
  public var routeKey: String
  /// Full Authorization header value resolved from SecretStore by the coordinator.
  public var authorization: String?

  public init(baseURL: String, routeKey: String, authorization: String?) {
    self.baseURL = baseURL
    self.routeKey = routeKey
    self.authorization = authorization
  }

  public func inspectConnection() async throws -> ConnectionInspection {
    await B4Inspector.inspect(baseURL: baseURL, authorization: authorization)
  }

  public func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    throw WorkspaceError.unsupported("b4.createSession", plannedFor: "M3")
  }

  public func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    throw WorkspaceError.unsupported("b4.loadSession", plannedFor: "M3")
  }

  public func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    throw WorkspaceError.unsupported("b4.sendTurn", plannedFor: "M3")
  }

  public func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    throw WorkspaceError.unsupported("b4.interrupt", plannedFor: "M3")
  }

  public func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    throw WorkspaceError.unsupported("b4.respond", plannedFor: "M3")
  }

  public func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    throw WorkspaceError.unsupported("b4.reconcile", plannedFor: "M3")
  }

  public func events() -> AsyncStream<AdapterEvent> {
    AsyncStream { $0.finish() }
  }

  public func dispose() async {}
}
