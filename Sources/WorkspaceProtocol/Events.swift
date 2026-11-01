import Foundation

/// Event kinds from spec section 6.1 plus `thread.updated` so viewers refresh without polling.
public enum EventKind: String, Codable, Sendable, CaseIterable {
  case connectionChanged = "connection.changed"
  case sessionCreated = "session.created"
  case turnAcknowledged = "turn.acknowledged"
  case messageStarted = "message.started"
  case messageDelta = "message.delta"
  case messageCompleted = "message.completed"
  case toolStarted = "tool.started"
  case toolCompleted = "tool.completed"
  case runtimeRequestOpened = "runtime_request.opened"
  case runtimeRequestResolved = "runtime_request.resolved"
  case runtimeRequestExpired = "runtime_request.expired"
  case turnStateChanged = "turn.state_changed"
  case turnFinished = "turn.finished"
  case reconciliationSnapshot = "reconciliation.snapshot"
  case adapterError = "adapter.error"
  case threadUpdated = "thread.updated"
  case serverChanged = "server.changed"
  /// A project, or the set of its folders, changed. `payload["projectId"]` names it.
  case projectChanged = "project.changed"
}

/// One normalized adapter event. Identity fields are always present; the payload shape depends on `kind`.
public struct AdapterEvent: Codable, Sendable, Equatable {
  public var kind: EventKind
  public var connectionId: String
  public var threadId: String?
  public var turnId: String?
  public var nativeIds: [String: String]
  public var adapterGeneration: Int
  public var at: String
  public var payload: JSONValue

  public init(
    kind: EventKind, connectionId: String, threadId: String? = nil, turnId: String? = nil,
    nativeIds: [String: String] = [:], adapterGeneration: Int = 0, at: String = Timestamp.now(),
    payload: JSONValue = .object([:])
  ) {
    self.kind = kind
    self.connectionId = connectionId
    self.threadId = threadId
    self.turnId = turnId
    self.nativeIds = nativeIds
    self.adapterGeneration = adapterGeneration
    self.at = at
    self.payload = payload
  }

  public static func connectionChanged(
    connectionId: String, status: ConnectionStatus, authStatus: AuthStatus, transport: TransportStatus,
    message: String? = nil, adapterGeneration: Int = 0
  ) -> AdapterEvent {
    AdapterEvent(
      kind: .connectionChanged, connectionId: connectionId, adapterGeneration: adapterGeneration,
      payload: [
        "status": .string(status.rawValue), "authStatus": .string(authStatus.rawValue),
        "transport": .string(transport.rawValue), "message": message.map(JSONValue.string) ?? .null,
      ])
  }

  /// A managed server row changed (health, pid, port, routes). Not tied to a connection.
  public static func serverChanged(_ server: LocalServer) throws -> AdapterEvent {
    AdapterEvent(kind: .serverChanged, connectionId: "", payload: ["server": try JSONValue(encoding: server)])
  }

  /// A project was created, renamed, deleted, or gained or lost a folder. Not tied to a connection.
  public static func projectChanged(projectId: String) -> AdapterEvent {
    AdapterEvent(kind: .projectChanged, connectionId: "", payload: ["projectId": .string(projectId)])
  }

  public static func threadUpdated(_ thread: ConversationThread) throws -> AdapterEvent {
    AdapterEvent(
      kind: .threadUpdated, connectionId: thread.connectionId, threadId: thread.id,
      payload: ["thread": try JSONValue(encoding: thread)])
  }
}
