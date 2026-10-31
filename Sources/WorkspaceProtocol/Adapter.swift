import Foundation

/// Result of inspecting a connection without issuing inference (spec sections 3.2 and 6).
public struct ConnectionInspection: Codable, Sendable, Equatable {
  public var status: ConnectionStatus
  public var authStatus: AuthStatus
  public var executablePath: String?
  public var version: String?
  /// Native identity used to namespace thread ids, e.g. account email or endpoint origin.
  public var nativeScope: String?
  public var capabilities: Capabilities
  public var message: String?
  public var error: WorkspaceError?

  public init(
    status: ConnectionStatus = .unconfigured, authStatus: AuthStatus = .unknown,
    executablePath: String? = nil,
    version: String? = nil, nativeScope: String? = nil, capabilities: Capabilities = .unverified,
    message: String? = nil, error: WorkspaceError? = nil
  ) {
    self.status = status
    self.authStatus = authStatus
    self.executablePath = executablePath
    self.version = version
    self.nativeScope = nativeScope
    self.capabilities = capabilities
    self.message = message
    self.error = error
  }
}

public struct NewSessionInput: Sendable, Equatable {
  public var workingDirectory: String?
  public var routeKey: String?
  public var model: String?
  public init(workingDirectory: String? = nil, routeKey: String? = nil, model: String? = nil) {
    self.workingDirectory = workingDirectory
    self.routeKey = routeKey
    self.model = model
  }
}

public struct NativeSessionRef: Codable, Sendable, Equatable {
  public var nativeSessionId: String
  public var nativeScope: String
  public init(nativeSessionId: String, nativeScope: String) {
    self.nativeSessionId = nativeSessionId
    self.nativeScope = nativeScope
  }
}

public struct SnapshotItem: Codable, Sendable, Equatable {
  public var nativeItemId: String?
  public var role: String
  public var type: String
  public var payload: JSONValue
  public init(nativeItemId: String?, role: String, type: String, payload: JSONValue) {
    self.nativeItemId = nativeItemId
    self.role = role
    self.type = type
    self.payload = payload
  }
}

public struct ActiveTurnRef: Codable, Sendable, Equatable {
  public var nativeTurnId: String
  public init(nativeTurnId: String) { self.nativeTurnId = nativeTurnId }
}

public struct RuntimeRequestRef: Codable, Sendable, Equatable {
  public var nativeRequestId: String
  public var kind: RuntimeRequestKind
  public var adapterGeneration: Int
  public init(nativeRequestId: String, kind: RuntimeRequestKind, adapterGeneration: Int) {
    self.nativeRequestId = nativeRequestId
    self.kind = kind
    self.adapterGeneration = adapterGeneration
  }
}

public struct SessionSnapshot: Codable, Sendable, Equatable {
  public var ref: NativeSessionRef
  public var title: String?
  public var items: [SnapshotItem]
  public var activeTurn: ActiveTurnRef?
  public var pendingRequests: [RuntimeRequestRef]
  public var truncated: Bool
  public init(
    ref: NativeSessionRef, title: String?, items: [SnapshotItem], activeTurn: ActiveTurnRef?,
    pendingRequests: [RuntimeRequestRef], truncated: Bool
  ) {
    self.ref = ref
    self.title = title
    self.items = items
    self.activeTurn = activeTurn
    self.pendingRequests = pendingRequests
    self.truncated = truncated
  }
}

public struct TurnInput: Sendable, Equatable {
  public var operationId: String
  public var text: String
  public var workingDirectory: String?
  public init(operationId: String, text: String, workingDirectory: String? = nil) {
    self.operationId = operationId
    self.text = text
    self.workingDirectory = workingDirectory
  }
}

public struct SubmissionReceipt: Sendable, Equatable {
  public var nativeTurnId: String?
  public var acknowledged: Bool
  public init(nativeTurnId: String?, acknowledged: Bool) {
    self.nativeTurnId = nativeTurnId
    self.acknowledged = acknowledged
  }
}

public struct StopReceipt: Sendable, Equatable {
  public var confirmed: Bool
  public var outcome: TurnOutcome?
  public init(confirmed: Bool, outcome: TurnOutcome?) {
    self.confirmed = confirmed
    self.outcome = outcome
  }
}

public enum RuntimeDecision: String, Codable, Sendable, Equatable, CaseIterable {
  case allowOnce = "allow_once"
  case allowAlways = "allow_always"
  case deny
}

public enum RuntimeResponse: Sendable, Equatable {
  case decision(RuntimeDecision)
  case answers([String: [String]])
  case decline(reason: String)
}

public enum ActiveTurnOutcome: Sendable, Equatable {
  case known(TurnOutcome)
  case unknown
  /// The runtime is waiting on a durable prompt the adapter has re-opened as runtime requests.
  case parked
}

public struct ReconcileResult: Sendable, Equatable {
  public var snapshot: SessionSnapshot?
  public var activeTurnOutcome: ActiveTurnOutcome?
  public init(snapshot: SessionSnapshot?, activeTurnOutcome: ActiveTurnOutcome?) {
    self.snapshot = snapshot
    self.activeTurnOutcome = activeTurnOutcome
  }
}

/// The normalized adapter surface (spec section 6). Native details stay inside each adapter.
/// Authentication and server supervision are separate services, not adapter methods.
public protocol AgentAdapter: Sendable {
  var kind: ConnectionKind { get }
  func inspectConnection() async throws -> ConnectionInspection
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws
  /// Ask the runtime what became of `turn` (nil: just refresh). Never assumes success.
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult
  func events() -> AsyncStream<AdapterEvent>
  /// Closes adapter resources. Never an implicit remote cancel.
  func dispose() async
}

/// Result of starting a runtime's official sign-in. The caller opens `authUrl`; completion arrives as
/// a `connection.changed` event. Never carries tokens.
public struct LoginStart: Codable, Sendable, Equatable {
  public var authUrl: String
  public var loginId: String
  public init(authUrl: String, loginId: String) {
    self.authUrl = authUrl
    self.loginId = loginId
  }
}

/// Adapters whose runtime offers an official browser sign-in the app can start.
public protocol LoginCapable: Sendable {
  func startLogin() async throws -> LoginStart
}
