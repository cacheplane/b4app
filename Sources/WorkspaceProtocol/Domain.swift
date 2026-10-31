import Foundation

// Status enums from spec section 5.3. Availability, authentication, transport, turn lifecycle,
// and outcome certainty are separate facts and stay separate types.

public enum ConnectionStatus: String, Codable, Sendable, CaseIterable {
  case unconfigured, connecting, ready, offline, incompatible, error
}

public enum AuthStatus: String, Codable, Sendable, CaseIterable {
  case notRequired = "not_required"
  case unknown, required, authenticating, authenticated, error
}

public enum TransportStatus: String, Codable, Sendable, CaseIterable {
  case disconnected, connecting, connected, reconnecting
}

public enum TurnStatus: String, Codable, Sendable, CaseIterable {
  case submitting, running
  case waitingForUser = "waiting_for_user"
  case stopping, reconciling, terminal
}

public enum TurnOutcome: String, Codable, Sendable, CaseIterable {
  case completed, cancelled, failed
}

public enum SubmissionState: String, Codable, Sendable, CaseIterable {
  case prepared, acknowledged, unknown
}

public enum ConnectionKind: String, Codable, Sendable, CaseIterable {
  case codex, claude, b4
}

/// B4 connections are managed (coordinator owns the process) or attached (local or remote).
public enum B4Mode: String, Codable, Sendable, CaseIterable {
  case managedLocal = "managed_local"
  case attachedLocal = "attached_local"
  case remote
}

public enum CapabilityKey: String, Codable, Sendable, CaseIterable, CodingKeyRepresentable {
  case streaming
  case nativeResume = "native_resume"
  case historyRetrieval = "history_retrieval"
  case explicitInterruption = "explicit_interruption"
  case reconnect
  case permissionDecisions = "permission_decisions"
  case userQuestions = "user_questions"
  case modelSelection = "model_selection"
}

public enum CapabilityState: String, Codable, Sendable, CaseIterable {
  case supported, unsupported, unverified
}

public typealias Capabilities = [CapabilityKey: CapabilityState]

extension Capabilities {
  public static var unverified: Capabilities {
    Dictionary(uniqueKeysWithValues: CapabilityKey.allCases.map { ($0, CapabilityState.unverified) })
  }
}

/// Connection profile. Secrets are referenced by id and never stored here.
public struct Connection: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var kind: ConnectionKind
  public var label: String
  public var enabled: Bool
  public var profileRevision: Int
  /// Executable path for codex and claude; API base URL for b4.
  public var target: String
  /// Exact B4 route key such as "/research#agent"; nil for harness connections.
  public var routeKey: String?
  public var b4Mode: B4Mode?
  public var localServerId: String?
  public var authReference: String?
  /// The native identity the connection last presented (account email, endpoint origin). Threads
  /// carry the scope they were created under; a different scope means another account or server
  /// and old threads are never retargeted (spec 5.1).
  public var nativeScope: String?
  public var capabilities: Capabilities
  public var status: ConnectionStatus
  public var authStatus: AuthStatus
  public var createdAt: String
  public var updatedAt: String

  public init(
    id: String, kind: ConnectionKind, label: String, enabled: Bool = true, profileRevision: Int = 0,
    target: String, routeKey: String? = nil, b4Mode: B4Mode? = nil, localServerId: String? = nil,
    authReference: String? = nil, nativeScope: String? = nil, capabilities: Capabilities = .unverified,
    status: ConnectionStatus = .unconfigured, authStatus: AuthStatus = .unknown,
    createdAt: String = Timestamp.now(), updatedAt: String = Timestamp.now()
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.enabled = enabled
    self.profileRevision = profileRevision
    self.target = target
    self.routeKey = routeKey
    self.b4Mode = b4Mode
    self.localServerId = localServerId
    self.authReference = authReference
    self.nativeScope = nativeScope
    self.capabilities = capabilities
    self.status = status
    self.authStatus = authStatus
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum LocalServerLaunchMode: String, Codable, Sendable, CaseIterable {
  case development, source
}

public enum LocalServerHealth: String, Codable, Sendable, CaseIterable {
  case stopped, starting, ready, unhealthy, unknown
}

/// One route of an inspected project, from `b4 routes --json`. The protocol route key is `id#kind`.
public struct LocalServerRoute: Codable, Sendable, Equatable, Hashable {
  public var id: String
  public var kind: String
  public var entryFile: String

  public init(id: String, kind: String, entryFile: String) {
    self.id = id
    self.kind = kind
    self.entryFile = entryFile
  }

  public var key: String { "\(id)#\(kind)" }
}

/// A registered local B4 project and its launch profile (spec 9.4). `pid` and `processStartedAt`
/// together with the argv are the verified child identity; a pid alone never establishes ownership.
public struct LocalServer: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  /// CLI handle; unique. Defaults to the project directory name.
  public var name: String
  public var projectPath: String
  public var nodePath: String
  public var cliPath: String
  public var cliVersion: String?
  public var launchMode: LocalServerLaunchMode
  public var envFilePath: String?
  public var requestedPort: Int?
  public var actualPort: Int?
  public var generation: Int
  public var pid: Int32?
  /// Seconds since the epoch at which the owned process started, read from the kernel.
  public var processStartedAt: Double?
  public var ownershipVerified: Bool
  public var health: LocalServerHealth
  public var statusMessage: String?
  public var routes: [LocalServerRoute]
  public var logPath: String?
  public var createdAt: String
  public var updatedAt: String

  public init(
    id: String, name: String, projectPath: String, nodePath: String, cliPath: String,
    cliVersion: String? = nil, launchMode: LocalServerLaunchMode, envFilePath: String? = nil,
    requestedPort: Int? = nil, actualPort: Int? = nil, generation: Int = 0, pid: Int32? = nil,
    processStartedAt: Double? = nil, ownershipVerified: Bool = false, health: LocalServerHealth = .stopped,
    statusMessage: String? = nil, routes: [LocalServerRoute] = [], logPath: String? = nil,
    createdAt: String = Timestamp.now(), updatedAt: String = Timestamp.now()
  ) {
    self.id = id
    self.name = name
    self.projectPath = projectPath
    self.nodePath = nodePath
    self.cliPath = cliPath
    self.cliVersion = cliVersion
    self.launchMode = launchMode
    self.envFilePath = envFilePath
    self.requestedPort = requestedPort
    self.actualPort = actualPort
    self.generation = generation
    self.pid = pid
    self.processStartedAt = processStartedAt
    self.ownershipVerified = ownershipVerified
    self.health = health
    self.statusMessage = statusMessage
    self.routes = routes
    self.logPath = logPath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// Whether the native session behind a thread can still be continued (spec 3.3, 5.1). The cached
/// transcript stays readable in every state; only `available` threads accept a new turn.
public enum ThreadContinuity: String, Codable, Sendable, CaseIterable {
  case available
  /// The runtime no longer has the native session (thread, transcript, or checkpoint).
  case missing
  /// The connection now presents another native identity (account or server) than the thread's.
  case identityChanged = "identity_changed"
}

public struct ConversationThread: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var connectionId: String
  public var nativeThreadId: String
  /// Namespace for native ids (account profile, server origin) so identical ids never collide.
  public var nativeScope: String
  public var title: String
  /// Working directory for harness threads, route key for B4 threads.
  public var context: String?
  public var pinned: Bool
  public var archived: Bool
  public var continuity: ThreadContinuity
  public var createdAt: String
  public var updatedAt: String

  public init(
    id: String, connectionId: String, nativeThreadId: String, nativeScope: String = "", title: String = "",
    context: String? = nil, pinned: Bool = false, archived: Bool = false,
    continuity: ThreadContinuity = .available,
    createdAt: String = Timestamp.now(), updatedAt: String = Timestamp.now()
  ) {
    self.id = id
    self.connectionId = connectionId
    self.nativeThreadId = nativeThreadId
    self.nativeScope = nativeScope
    self.title = title
    self.context = context
    self.pinned = pinned
    self.archived = archived
    self.continuity = continuity
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct Turn: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var threadId: String
  public var operationId: String
  public var nativeTurnId: String?
  public var inputRef: String?
  public var status: TurnStatus
  public var submission: SubmissionState
  public var outcome: TurnOutcome?
  public var createdAt: String
  public var updatedAt: String

  public init(
    id: String, threadId: String, operationId: String, nativeTurnId: String? = nil, inputRef: String? = nil,
    status: TurnStatus = .submitting, submission: SubmissionState = .prepared, outcome: TurnOutcome? = nil,
    createdAt: String = Timestamp.now(), updatedAt: String = Timestamp.now()
  ) {
    self.id = id
    self.threadId = threadId
    self.operationId = operationId
    self.nativeTurnId = nativeTurnId
    self.inputRef = inputRef
    self.status = status
    self.submission = submission
    self.outcome = outcome
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum DisplayItemRole: String, Codable, Sendable, CaseIterable {
  case user, assistant, tool, system
}

public enum DisplayProvenance: String, Codable, Sendable, CaseIterable {
  case live, snapshot, cache
}

public struct DisplayItem: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var threadId: String
  public var turnId: String?
  public var nativeItemId: String?
  public var role: DisplayItemRole
  public var type: String
  public var payload: JSONValue
  public var sequence: Int
  public var provenance: DisplayProvenance
  public var createdAt: String

  public init(
    id: String, threadId: String, turnId: String? = nil, nativeItemId: String? = nil, role: DisplayItemRole,
    type: String, payload: JSONValue, sequence: Int, provenance: DisplayProvenance,
    createdAt: String = Timestamp.now()
  ) {
    self.id = id
    self.threadId = threadId
    self.turnId = turnId
    self.nativeItemId = nativeItemId
    self.role = role
    self.type = type
    self.payload = payload
    self.sequence = sequence
    self.provenance = provenance
    self.createdAt = createdAt
  }
}

public enum RuntimeRequestKind: String, Codable, Sendable, CaseIterable {
  case commandApproval = "command_approval"
  case fileChangeApproval = "file_change_approval"
  case toolPermission = "tool_permission"
  case userQuestion = "user_question"
  case elicitation
  case unknown
}

public enum RuntimeRequestState: String, Codable, Sendable, CaseIterable {
  case pending, resolved, expired
}

public struct RuntimeRequest: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var nativeRequestId: String
  public var threadId: String
  public var turnId: String?
  public var adapterGeneration: Int
  public var kind: RuntimeRequestKind
  public var state: RuntimeRequestState
  public var payload: JSONValue
  public var createdAt: String
  public var updatedAt: String

  public init(
    id: String, nativeRequestId: String, threadId: String, turnId: String? = nil, adapterGeneration: Int,
    kind: RuntimeRequestKind, state: RuntimeRequestState = .pending, payload: JSONValue,
    createdAt: String = Timestamp.now(), updatedAt: String = Timestamp.now()
  ) {
    self.id = id
    self.nativeRequestId = nativeRequestId
    self.threadId = threadId
    self.turnId = turnId
    self.adapterGeneration = adapterGeneration
    self.kind = kind
    self.state = state
    self.payload = payload
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// Unsent user text. Never treated as a dispatched request.
public struct Draft: Codable, Sendable, Equatable {
  public var threadId: String
  public var text: String
  public var updatedAt: String

  public init(threadId: String, text: String, updatedAt: String = Timestamp.now()) {
    self.threadId = threadId
    self.text = text
    self.updatedAt = updatedAt
  }
}

public enum RuntimeKind: String, Codable, Sendable, CaseIterable {
  case node, codex, claude, b4
}

public enum ExecutableSource: String, Codable, Sendable, CaseIterable {
  case explicit, path, fallback, missing
}

public struct RuntimeDiagnostic: Codable, Sendable, Equatable {
  public var kind: RuntimeKind
  public var executablePath: String?
  public var source: ExecutableSource
  public var version: String?
  public var status: ConnectionStatus
  public var authStatus: AuthStatus
  public var message: String?

  public init(
    kind: RuntimeKind, executablePath: String?, source: ExecutableSource, version: String?,
    status: ConnectionStatus, authStatus: AuthStatus, message: String?
  ) {
    self.kind = kind
    self.executablePath = executablePath
    self.source = source
    self.version = version
    self.status = status
    self.authStatus = authStatus
    self.message = message
  }
}

public struct CoordinatorInfo: Codable, Sendable, Equatable {
  public var version: String
  public var pid: Int32
  public var startedAt: String
  public var epoch: String
  public var sequence: Int
  public var runtimeDir: String
  public var dataDir: String
  public var socketPath: String
  public var databasePath: String
  public var host: String

  public init(
    version: String, pid: Int32, startedAt: String, epoch: String, sequence: Int, runtimeDir: String,
    dataDir: String, socketPath: String, databasePath: String, host: String
  ) {
    self.version = version
    self.pid = pid
    self.startedAt = startedAt
    self.epoch = epoch
    self.sequence = sequence
    self.runtimeDir = runtimeDir
    self.dataDir = dataDir
    self.socketPath = socketPath
    self.databasePath = databasePath
    self.host = host
  }
}

public struct HostInfo: Codable, Sendable, Equatable {
  public var platform: String
  public var arch: String
  public var release: String

  public init(platform: String, arch: String, release: String) {
    self.platform = platform
    self.arch = arch
    self.release = release
  }
}

public struct RecentError: Codable, Sendable, Equatable {
  public var at: String
  public var scope: String
  public var code: String
  public var message: String

  public init(at: String = Timestamp.now(), scope: String, code: String, message: String) {
    self.at = at
    self.scope = scope
    self.code = code
    self.message = message
  }
}

public struct DiagnosticsReport: Codable, Sendable, Equatable {
  public var coordinator: CoordinatorInfo
  public var host: HostInfo
  public var runtimes: [RuntimeDiagnostic]
  public var recentErrors: [RecentError]

  public init(
    coordinator: CoordinatorInfo, host: HostInfo, runtimes: [RuntimeDiagnostic], recentErrors: [RecentError]
  ) {
    self.coordinator = coordinator
    self.host = host
    self.runtimes = runtimes
    self.recentErrors = recentErrors
  }
}

/// ISO 8601 timestamps with fractional seconds; strings on the wire, never Date.
public enum Timestamp {
  private static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  public static func now() -> String { string(from: Date()) }
  public static func string(from date: Date) -> String { date.formatted(style) }
  public static func date(from string: String) -> Date? { try? style.parse(string) }
}
