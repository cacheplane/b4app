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
  /// An environment, or the set of its folders, changed. `payload["environmentId"]` names it.
  case environmentChanged = "environment.changed"
  /// A runtime reported its plan allowance. `payload["reading"]` is a `UsageReading`.
  case usageChanged = "usage.changed"
  /// The phone's view of its hub link and of one Mac's presence (M8c). Only the phone's
  /// `MirrorTransport` emits it; the Mac never does. The payload is described on `HostPresence`.
  case hostPresence = "host.presence"
  /// The Mac's signed-in account changed (sign-in plan, Task 9). The payload is the new
  /// `AccountStatus.Result`; only the coordinator emits it.
  case accountChanged = "account.changed"
  /// The account's view settings changed, by a local `viewSettings.set` or a pulled edit. The payload's
  /// `settings` is the stored `ViewSettings`.
  case viewSettingsChanged = "viewSettings.changed"
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
    message: String? = nil, adapterGeneration: Int = 0, attempt: Int? = nil, attempts: Int? = nil
  ) -> AdapterEvent {
    var payload: [String: JSONValue] = [
      "status": .string(status.rawValue), "authStatus": .string(authStatus.rawValue),
      "transport": .string(transport.rawValue), "message": message.map(JSONValue.string) ?? .null,
    ]
    // A check in progress says which try it is on, so the card can show "try 2 of 3".
    if let attempt, let attempts {
      payload["attempt"] = .number(Double(attempt))
      payload["attempts"] = .number(Double(attempts))
    }
    return AdapterEvent(
      kind: .connectionChanged, connectionId: connectionId, adapterGeneration: adapterGeneration,
      payload: .object(payload))
  }

  /// A managed server row changed (health, pid, port, routes). Not tied to a connection.
  public static func serverChanged(_ server: LocalServer) throws -> AdapterEvent {
    AdapterEvent(kind: .serverChanged, connectionId: "", payload: ["server": try JSONValue(encoding: server)])
  }

  /// An environment was created, renamed, deleted, or gained or lost a folder. Not tied to a connection.
  public static func environmentChanged(environmentId: String) -> AdapterEvent {
    AdapterEvent(
      kind: .environmentChanged, connectionId: "", payload: ["environmentId": .string(environmentId)])
  }

  /// The account's view settings changed. Not tied to a connection.
  public static func viewSettingsChanged(_ settings: ViewSettings) throws -> AdapterEvent {
    AdapterEvent(
      kind: .viewSettingsChanged, connectionId: "", payload: ["settings": try JSONValue(encoding: settings)])
  }

  public static func threadUpdated(_ thread: ConversationThread) throws -> AdapterEvent {
    AdapterEvent(
      kind: .threadUpdated, connectionId: thread.connectionId, threadId: thread.id,
      payload: ["thread": try JSONValue(encoding: thread)])
  }
}
