import Foundation

/// Allowlisted command methods. `method` is a discriminator with its own params and result types;
/// mutations require an operationId so retries can be deduplicated locally (spec section 6.2).
public enum Method: String, Codable, Sendable, CaseIterable {
  case systemPing = "system.ping"
  case diagnosticsRead = "diagnostics.read"
  case connectionList = "connection.list"
  case threadList = "thread.list"
  case draftRead = "draft.read"
  case draftSave = "draft.save"
  case eventsSnapshot = "events.snapshot"
  case eventsReplay = "events.replay"
  case connectionAdd = "connection.add"
  case connectionInspect = "connection.inspect"
  case connectionLogin = "connection.login"
  case threadCreate = "thread.create"
  case threadRead = "thread.read"
  case threadUpdate = "thread.update"
  case threadReconcile = "thread.reconcile"
  case turnSend = "turn.send"
  case turnInterrupt = "turn.interrupt"
  case turnAbandon = "turn.abandon"
  case requestRespond = "request.respond"
  case credentialAdd = "credential.add"
  case serverAdd = "server.add"
  case serverList = "server.list"
  case serverStart = "server.start"
  case serverStatus = "server.status"
  case serverLogs = "server.logs"
  case serverRestart = "server.restart"
  case serverStop = "server.stop"
  case serverInspect = "server.inspect"
  case workspaceActiveWork = "workspace.activeWork"
  case workspaceStopLocalWork = "workspace.stopLocalWork"
  case workspaceReconcile = "workspace.reconcile"
  case databaseStatus = "database.status"
  case databaseBackup = "database.backup"
  case databaseRestore = "database.restore"
  case databaseImportSQLite = "database.importSqlite"
  case hubJoin = "hub.join"
  case hubStatus = "hub.status"
  case hubLeave = "hub.leave"
  case hubPair = "hub.pair"
  case hubPairStatus = "hub.pairStatus"
  case settingsRead = "settings.read"
  case settingsUpdate = "settings.update"
  case projectList = "project.list"
  case projectCreate = "project.create"
  case projectUpdate = "project.update"
  case projectRename = "project.rename"
  case projectDelete = "project.delete"
  case threadMarkRead = "thread.markRead"
  /// Relayed from the hub only (`RelayExecutor`); `Router` refuses both over the local socket. Listed so
  /// `MirrorTransport` can serve `thread.start` through the relay.
  case threadStart = "thread.start"
  case turnLookup = "turn.lookup"

  public var isMutation: Bool {
    switch self {
    case .draftSave, .connectionAdd, .connectionInspect, .connectionLogin, .threadCreate, .threadUpdate,
      .threadReconcile, .turnSend, .turnInterrupt, .turnAbandon, .requestRespond, .credentialAdd, .serverAdd,
      .serverStart,
      .serverRestart,
      .serverStop, .serverInspect, .workspaceStopLocalWork, .workspaceReconcile, .databaseBackup,
      .databaseRestore,
      .databaseImportSQLite, .hubJoin, .hubLeave, .projectCreate, .projectUpdate, .projectRename,
      .projectDelete, .threadMarkRead, .threadStart, .settingsUpdate:
      return true
    case .systemPing, .diagnosticsRead, .connectionList, .threadList, .draftRead, .eventsSnapshot,
      .eventsReplay, .threadRead, .serverList, .serverStatus, .serverLogs, .workspaceActiveWork,
      .databaseStatus, .hubStatus, .projectList, .turnLookup, .hubPair, .hubPairStatus, .settingsRead:
      return false
    }
  }
}

/// A typed command: params in, result out, bound to one method.
public protocol WorkspaceCommand: Sendable {
  associatedtype Params: Codable & Sendable
  associatedtype Result: Codable & Sendable
  static var method: Method { get }
}

public struct EmptyParams: Codable, Sendable, Equatable {
  public init() {}
}

public enum SystemPing: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var pong: Bool
    public var epoch: String
    public var sequence: Int
    public var coordinator: CoordinatorIdentity
    public var startedAt: String
    public init(
      pong: Bool = true, epoch: String, sequence: Int, coordinator: CoordinatorIdentity, startedAt: String
    ) {
      self.pong = pong
      self.epoch = epoch
      self.sequence = sequence
      self.coordinator = coordinator
      self.startedAt = startedAt
    }
  }
  public static let method = Method.systemPing
}

public enum DiagnosticsRead: WorkspaceCommand {
  public typealias Params = EmptyParams
  public typealias Result = DiagnosticsReport
  public static let method = Method.diagnosticsRead
}

public enum ConnectionList: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var includeDisabled: Bool?
    public init(includeDisabled: Bool? = nil) { self.includeDisabled = includeDisabled }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var connections: [Connection]
    public init(connections: [Connection]) { self.connections = connections }
  }
  public static let method = Method.connectionList
}

public enum ThreadList: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var connectionId: String?
    public var includeArchived: Bool?
    public var query: String?
    public init(connectionId: String? = nil, includeArchived: Bool? = nil, query: String? = nil) {
      self.connectionId = connectionId
      self.includeArchived = includeArchived
      self.query = query
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var threads: [ConversationThread]
    public init(threads: [ConversationThread]) { self.threads = threads }
  }
  public static let method = Method.threadList
}

public enum DraftRead: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public init(threadId: String) { self.threadId = threadId }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var draft: Draft?
    public init(draft: Draft?) { self.draft = draft }
  }
  public static let method = Method.draftRead
}

public enum DraftSave: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public var text: String
    public init(threadId: String, text: String) {
      self.threadId = threadId
      self.text = text
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var draft: Draft
    public init(draft: Draft) { self.draft = draft }
  }
  public static let method = Method.draftSave
}

/// Everything a viewer needs to start: connections, every thread (archived included), and every
/// non-terminal turn so the sidebar can show per-thread state before any event arrives (spec 3.1).
public enum EventsSnapshot: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var epoch: String
    public var sequence: Int
    public var connections: [Connection]
    public var threads: [ConversationThread]
    public var activeTurns: [Turn]
    public init(
      epoch: String, sequence: Int, connections: [Connection], threads: [ConversationThread],
      activeTurns: [Turn] = []
    ) {
      self.epoch = epoch
      self.sequence = sequence
      self.connections = connections
      self.threads = threads
      self.activeTurns = activeTurns
    }

    private enum CodingKeys: String, CodingKey { case epoch, sequence, connections, threads, activeTurns }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      epoch = try container.decode(String.self, forKey: .epoch)
      sequence = try container.decode(Int.self, forKey: .sequence)
      connections = try container.decode([Connection].self, forKey: .connections)
      threads = try container.decode([ConversationThread].self, forKey: .threads)
      activeTurns = try container.decodeIfPresent([Turn].self, forKey: .activeTurns) ?? []
    }
  }
  public static let method = Method.eventsSnapshot
}

/// Bounded replay. Fails with `snapshot_required` on an epoch change or an expired buffer.
public enum EventsReplay: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var epoch: String
    public var afterSequence: Int
    public init(epoch: String, afterSequence: Int) {
      self.epoch = epoch
      self.afterSequence = afterSequence
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var events: [EventEnvelope]
    public init(events: [EventEnvelope]) { self.events = events }
  }
  public static let method = Method.eventsReplay
}

// MARK: - M1 conversation methods

/// Register a connection. For Codex and Claude the executable is located on PATH unless
/// `executablePath` is given. For B4, `url` is the endpoint base URL (HTTPS, or HTTP on loopback),
/// `route` the exact route key such as `/chat#agent`, and `authReference` an optional `secret:` id
/// from `credential.add`. The connection is inspected before it is returned.
public enum ConnectionAdd: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var kind: ConnectionKind
    public var label: String?
    public var executablePath: String?
    public var url: String?
    public var route: String?
    public var authReference: String?
    /// A managed server id: the connection targets that server's loopback origin (M4).
    public var serverId: String?
    public init(
      kind: ConnectionKind, label: String? = nil, executablePath: String? = nil, url: String? = nil,
      route: String? = nil, authReference: String? = nil, serverId: String? = nil
    ) {
      self.kind = kind
      self.label = label
      self.executablePath = executablePath
      self.url = url
      self.route = route
      self.authReference = authReference
      self.serverId = serverId
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var connection: Connection
    public var inspection: ConnectionInspection
    public init(connection: Connection, inspection: ConnectionInspection) {
      self.connection = connection
      self.inspection = inspection
    }
  }
  public static let method = Method.connectionAdd
}

/// Re-inspect a connection (executable, version, account) and store the result.
public enum ConnectionInspect: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var connectionId: String
    public init(connectionId: String) { self.connectionId = connectionId }
  }
  public typealias Result = ConnectionAdd.Result
  public static let method = Method.connectionInspect
}

/// Start the runtime's official sign-in. The caller opens `authUrl`; completion arrives as an event.
public enum ConnectionLogin: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var connectionId: String
    public init(connectionId: String) { self.connectionId = connectionId }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var authUrl: String
    public var loginId: String
    public init(authUrl: String, loginId: String) {
      self.authUrl = authUrl
      self.loginId = loginId
    }
  }
  public static let method = Method.connectionLogin
}

/// Create a native thread. Harness threads need a `workingDirectory`; B4 threads ignore it and bind
/// to the connection's route instead.
public enum ThreadCreate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var connectionId: String
    public var workingDirectory: String?
    public var title: String?
    /// The new thread's id, minted by the phone for `thread.start`; nil mints one here. Only the relay
    /// sets it (`Router` drops it from a local `thread.create`).
    public var threadId: String?
    public init(
      connectionId: String, workingDirectory: String? = nil, title: String? = nil, threadId: String? = nil
    ) {
      self.connectionId = connectionId
      self.workingDirectory = workingDirectory
      self.title = title
      self.threadId = threadId
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var thread: ConversationThread
    public init(thread: ConversationThread) { self.thread = thread }
  }
  public static let method = Method.threadCreate
}

/// Everything a viewer needs to render one thread from the local cache. No network.
public enum ThreadRead: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public init(threadId: String) { self.threadId = threadId }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var thread: ConversationThread
    public var turns: [Turn]
    public var items: [DisplayItem]
    public var requests: [RuntimeRequest]
    public init(thread: ConversationThread, turns: [Turn], items: [DisplayItem], requests: [RuntimeRequest]) {
      self.thread = thread
      self.turns = turns
      self.items = items
      self.requests = requests
    }
  }
  public static let method = Method.threadRead
}

/// Local title, pin, and archive changes. Never rewrites native provider history.
public enum ThreadUpdate: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public var title: String?
    public var pinned: Bool?
    public var archived: Bool?
    public init(threadId: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) {
      self.threadId = threadId
      self.title = title
      self.pinned = pinned
      self.archived = archived
    }
  }
  public typealias Result = ThreadCreate.Result
  public static let method = Method.threadUpdate
}

/// Ask the runtime about a thread: settle an unresolved turn, load native history and merge it into
/// the cache without duplicates (D-031), and record whether the native session can still be
/// continued (missing history, changed identity). Never re-sends anything.
public enum ThreadReconcile: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public init(threadId: String) { self.threadId = threadId }
  }
  public typealias Result = ThreadRead.Result
  public static let method = Method.threadReconcile
}

/// Dispatch one user turn. The envelope's operationId is the turn's operation id, so a retried
/// command returns the original turn instead of dispatching again.
public enum TurnSend: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public var text: String
    public init(threadId: String, text: String) {
      self.threadId = threadId
      self.text = text
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var turn: Turn
    public init(turn: Turn) { self.turn = turn }
  }
  public static let method = Method.turnSend
}

public enum TurnInterrupt: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public init(threadId: String) { self.threadId = threadId }
  }
  public typealias Result = TurnSend.Result
  public static let method = Method.turnInterrupt
}

/// Deliberate recovery for a turn whose outcome the runtime never established (spec 10.1.4): only a
/// `reconciling` turn can be abandoned. It ends `failed` with a visible note; nothing is re-sent and
/// the runtime is not told anything.
public enum TurnAbandon: WorkspaceCommand {
  public typealias Params = TurnInterrupt.Params
  public typealias Result = TurnSend.Result
  public static let method = Method.turnAbandon
}

/// Answer a pending runtime request exactly once. `decision` answers approvals; `answers` answers
/// user questions; neither (or `decline: true`) sends an explicit decline.
public enum RequestRespond: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var requestId: String
    public var decision: RuntimeDecision?
    public var answers: [String: [String]]?
    public var decline: Bool?
    public init(
      requestId: String, decision: RuntimeDecision? = nil, answers: [String: [String]]? = nil,
      decline: Bool? = nil
    ) {
      self.requestId = requestId
      self.decision = decision
      self.answers = answers
      self.decline = decline
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var request: RuntimeRequest
    public init(request: RuntimeRequest) { self.request = request }
  }
  public static let method = Method.requestRespond
}

/// Store an endpoint secret in the coordinator's credential store and return its reference. The
/// value travels only over the local socket; it is never echoed in the result, an event, or a log.
public enum CredentialAdd: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var label: String
    public var value: String
    public init(label: String, value: String) {
      self.label = label
      self.value = value
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var reference: String
    public var label: String
    public init(reference: String, label: String) {
      self.reference = reference
      self.label = label
    }
  }
  public static let method = Method.credentialAdd
}

// MARK: - M4 managed server methods

/// Register a local B4 project. Inspection (`b4 routes --json`) runs the project's config and route
/// modules, so registration is the trust decision. `port` is allocated once when omitted.
public enum ServerAdd: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var projectPath: String
    public var name: String?
    public var launchMode: LocalServerLaunchMode?
    public var envFilePath: String?
    public var port: Int?
    public init(
      projectPath: String, name: String? = nil, launchMode: LocalServerLaunchMode? = nil,
      envFilePath: String? = nil, port: Int? = nil
    ) {
      self.projectPath = projectPath
      self.name = name
      self.launchMode = launchMode
      self.envFilePath = envFilePath
      self.port = port
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var server: LocalServer
    public init(server: LocalServer) { self.server = server }
  }
  public static let method = Method.serverAdd
}

public enum ServerList: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var servers: [LocalServer]
    public init(servers: [LocalServer]) { self.servers = servers }
  }
  public static let method = Method.serverList
}

public struct ServerRef: Codable, Sendable, Equatable {
  public var serverId: String
  public init(serverId: String) { self.serverId = serverId }
}

/// Start an owned server and wait for `/healthz`; idempotent for a ready server.
public enum ServerStart: WorkspaceCommand {
  public typealias Params = ServerRef
  public typealias Result = ServerAdd.Result
  public static let method = Method.serverStart
}

public enum ServerStatus: WorkspaceCommand {
  public typealias Params = ServerRef
  public typealias Result = ServerAdd.Result
  public static let method = Method.serverStatus
}

/// Re-run route discovery for a registered project.
public enum ServerInspect: WorkspaceCommand {
  public typealias Params = ServerRef
  public typealias Result = ServerAdd.Result
  public static let method = Method.serverInspect
}

/// Stop or restart. Refused with `owned_process_conflict` (`reason: turn_active`) while a route
/// connection has a running turn unless `force` is set (D-030).
public struct ServerLifecycleParams: Codable, Sendable, Equatable {
  public var serverId: String
  public var force: Bool?
  public init(serverId: String, force: Bool? = nil) {
    self.serverId = serverId
    self.force = force
  }
}

public enum ServerStop: WorkspaceCommand {
  public typealias Params = ServerLifecycleParams
  public typealias Result = ServerAdd.Result
  public static let method = Method.serverStop
}

public enum ServerRestart: WorkspaceCommand {
  public typealias Params = ServerLifecycleParams
  public typealias Result = ServerAdd.Result
  public static let method = Method.serverRestart
}

/// A redacted tail of the server's log file. Pass the returned `offset` back as `afterOffset` to
/// read only what was appended since.
public enum ServerLogs: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var serverId: String
    public var lines: Int?
    public var afterOffset: Int?
    public init(serverId: String, lines: Int? = nil, afterOffset: Int? = nil) {
      self.serverId = serverId
      self.lines = lines
      self.afterOffset = afterOffset
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var lines: [String]
    public var offset: Int
    public var truncated: Bool
    public var logPath: String
    public init(lines: [String], offset: Int, truncated: Bool, logPath: String) {
      self.lines = lines
      self.offset = offset
      self.truncated = truncated
      self.logPath = logPath
    }
  }
  public static let method = Method.serverLogs
}

// MARK: - M5 lifecycle methods

/// One non-terminal turn as the Quit dialog and wake handling see it. `local` is true for work this
/// coordinator's process tree owns (Codex, Claude, managed B4); attached and remote B4 runs continue
/// on their server when the app quits, so the app detaches from them rather than cancelling.
public struct ActiveTurnSummary: Codable, Sendable, Equatable, Identifiable {
  public var id: String { turnId }
  public var threadId: String
  public var threadTitle: String
  public var turnId: String
  public var status: TurnStatus
  public var connectionId: String
  public var connectionLabel: String
  public var kind: ConnectionKind
  public var b4Mode: B4Mode?
  public var local: Bool

  public init(
    threadId: String, threadTitle: String, turnId: String, status: TurnStatus, connectionId: String,
    connectionLabel: String, kind: ConnectionKind, b4Mode: B4Mode?, local: Bool
  ) {
    self.threadId = threadId
    self.threadTitle = threadTitle
    self.turnId = turnId
    self.status = status
    self.connectionId = connectionId
    self.connectionLabel = connectionLabel
    self.kind = kind
    self.b4Mode = b4Mode
    self.local = local
  }
}

/// What is running right now: every non-terminal turn and every owned server that is up.
public enum WorkspaceActiveWork: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var turns: [ActiveTurnSummary]
    public var servers: [LocalServer]
    public init(turns: [ActiveTurnSummary], servers: [LocalServer]) {
      self.turns = turns
      self.servers = servers
    }
    public var localTurns: [ActiveTurnSummary] { turns.filter(\.local) }
    public var remoteTurns: [ActiveTurnSummary] { turns.filter { !$0.local } }
  }
  public static let method = Method.workspaceActiveWork
}

/// Spec 10.3 "stop owned local work and quit": interrupt every local turn, wait briefly for the
/// runtime to confirm, force-stop owned servers. Remote and attached runs are left alone (detached).
public enum WorkspaceStopLocalWork: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    /// Local turns the runtime confirmed as finished (cancelled, completed, or failed).
    public var stopped: [ActiveTurnSummary]
    /// Local turns whose end the runtime did not confirm in time; they reconcile on the next launch.
    public var unconfirmed: [ActiveTurnSummary]
    /// Remote and attached runs left running on their server.
    public var detached: [ActiveTurnSummary]
    public var serversStopped: [String]
    public var serverErrors: [String]
    public init(
      stopped: [ActiveTurnSummary] = [], unconfirmed: [ActiveTurnSummary] = [],
      detached: [ActiveTurnSummary] = [], serversStopped: [String] = [], serverErrors: [String] = []
    ) {
      self.stopped = stopped
      self.unconfirmed = unconfirmed
      self.detached = detached
      self.serversStopped = serversStopped
      self.serverErrors = serverErrors
    }
  }
  public static let method = Method.workspaceStopLocalWork
}

/// Spec 10.3 wake and reconnect: ask every runtime about every unresolved turn and re-check
/// offline connections. Never re-sends; what stays unknown stays visibly unknown.
public enum WorkspaceReconcile: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var reason: String?
    public init(reason: String? = nil) { self.reason = reason }
  }
  public struct Result: Codable, Sendable, Equatable {
    /// Turns whose state changed (finished, parked, or back to running).
    public var reconciled: Int
    public var stillUnknown: Int
    public var connectionsRechecked: Int
    public init(reconciled: Int, stillUnknown: Int, connectionsRechecked: Int) {
      self.reconciled = reconciled
      self.stillUnknown = stillUnknown
      self.connectionsRechecked = connectionsRechecked
    }
  }
  public static let method = Method.workspaceReconcile
}

// MARK: - Store (M7, D-041)

/// Where the store is, what schema it has, how big it is, and how much of its change log is unsynced.
public enum DatabaseStatus: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var endpoint: String
    public var dataDir: String?
    public var migrations: [String]
    public var rows: [String: Int]
    public var unsyncedChanges: Int
    public var backupsDir: String
    public init(
      endpoint: String, dataDir: String?, migrations: [String], rows: [String: Int], unsyncedChanges: Int,
      backupsDir: String
    ) {
      self.endpoint = endpoint
      self.dataDir = dataDir
      self.migrations = migrations
      self.rows = rows
      self.unsyncedChanges = unsyncedChanges
      self.backupsDir = backupsDir
    }
  }
  public static let method = Method.databaseStatus
}

/// Write every table to a JSON-lines archive (default: `<data dir>/backups/<timestamp>.jsonl`).
public enum DatabaseBackup: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var path: String?
    public init(path: String? = nil) { self.path = path }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var path: String
    public var rows: Int
    public init(path: String, rows: Int) {
      self.path = path
      self.rows = rows
    }
  }
  public static let method = Method.databaseBackup
}

/// Load an archive into an empty store, or over the current one with `replace`.
public enum DatabaseRestore: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var path: String
    public var replace: Bool
    public init(path: String, replace: Bool = false) {
      self.path = path
      self.replace = replace
    }
  }
  public typealias Result = DatabaseBackup.Result
  public static let method = Method.databaseRestore
}

/// Import a pre-0.2 `workspace.sqlite` into an empty store.
public enum DatabaseImportSQLite: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var path: String
    public init(path: String) { self.path = path }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var rows: [String: Int]
    public init(rows: [String: Int]) { self.rows = rows }
  }
  public static let method = Method.databaseImportSQLite
}

// MARK: - Hub (M8a)

/// Join a hub with a one-time enrollment code. The code travels only over the local socket, as
/// `credential.add` carries values; it is never echoed in the result, an event, or a log.
public enum HubJoin: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var url: String
    public var code: String
    /// Defaults to the Mac's name.
    public var deviceName: String?
    public init(url: String, code: String, deviceName: String? = nil) {
      self.url = url
      self.code = code
      self.deviceName = deviceName
    }
  }
  public typealias Result = HubStatus.Result
  public static let method = Method.hubJoin
}

/// Whether this Mac has joined a hub, as whom, and how much of its change log is still unpushed.
public enum HubStatus: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var joined: Bool
    public var url: String?
    public var deviceId: String?
    public var deviceName: String?
    public var orgSlug: String?
    public var username: String?
    /// The hub user's display name, when the coordinator has it (absent from a pre-0.2 coordinator).
    public var displayName: String?
    public var unsyncedChanges: Int
    public var lastPushAt: String?
    public var lastError: String?
    /// The relay link to the hub (M8c), while joined; absent from an older coordinator.
    public var link: HubLinkStatus?
    /// Whether the "keep the Mac awake" power assertion is held right now (M8c); absent from an older
    /// coordinator.
    public var keepAwakeHeld: Bool?
    public init(
      joined: Bool, url: String? = nil, deviceId: String? = nil, deviceName: String? = nil,
      orgSlug: String? = nil, username: String? = nil, displayName: String? = nil, unsyncedChanges: Int,
      lastPushAt: String? = nil, lastError: String? = nil, link: HubLinkStatus? = nil,
      keepAwakeHeld: Bool? = nil
    ) {
      self.joined = joined
      self.url = url
      self.deviceId = deviceId
      self.deviceName = deviceName
      self.orgSlug = orgSlug
      self.username = username
      self.displayName = displayName
      self.unsyncedChanges = unsyncedChanges
      self.lastPushAt = lastPushAt
      self.lastError = lastError
      self.link = link
      self.keepAwakeHeld = keepAwakeHeld
    }
  }
  public static let method = Method.hubStatus
}

/// Where this Mac's relay link to the hub is (M8c). `since` is when it entered `state` (`Timestamp`
/// form); `lastError` says why it is not connected, and never carries a token.
public struct HubLinkStatus: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable {
    case connected, connecting, offline

    /// A state this build does not know (a newer coordinator's) reads as `offline`.
    public init(from decoder: Decoder) throws {
      self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .offline
    }
  }

  public var state: State
  public var since: String?
  public var lastError: String?

  public init(state: State, since: String? = nil, lastError: String? = nil) {
    self.state = state
    self.since = since
    self.lastError = lastError
  }
}

/// Revoke this device at the hub (best effort), forget its token, and stop pushing. What was already
/// uploaded stays on the hub.
public enum HubLeave: WorkspaceCommand {
  public typealias Params = EmptyParams
  public typealias Result = HubStatus.Result
  public static let method = Method.hubLeave
}

public struct ParsedCommand: Sendable, Equatable {
  public var envelope: CommandEnvelope
  public var method: Method
  public var params: JSONValue

  /// Decode the params for a typed command. Throws `protocol_invalid` on shape mismatch.
  public func params<C: WorkspaceCommand>(for command: C.Type) throws -> C.Params {
    do {
      return try params.decode(C.Params.self)
    } catch {
      throw WorkspaceError(
        .protocolInvalid, "Invalid params for \"\(method.rawValue)\".",
        details: ["method": .string(method.rawValue), "reason": .string(String(describing: error))])
    }
  }
}

/// Validate a raw inbound line as a command. Throws `protocol_invalid` or `method_unknown`;
/// never returns a partially validated command.
public func parseCommand(_ data: Data) throws -> ParsedCommand {
  let envelope: CommandEnvelope
  do {
    envelope = try JSONCoding.decoder.decode(CommandEnvelope.self, from: data)
  } catch {
    throw WorkspaceError(
      .protocolInvalid, "Malformed command envelope.", details: ["reason": .string(String(describing: error))]
    )
  }
  guard envelope.protocolVersion == protocolVersion else {
    throw WorkspaceError(
      .protocolInvalid, "Unsupported protocol version \(envelope.protocolVersion).",
      details: ["protocolVersion": .number(Double(envelope.protocolVersion))])
  }
  guard envelope.kind == "command" else {
    throw WorkspaceError(.protocolInvalid, "Expected kind \"command\", got \"\(envelope.kind)\".")
  }
  guard !envelope.requestId.isEmpty else {
    throw WorkspaceError(.protocolInvalid, "requestId must not be empty.")
  }
  guard let method = Method(rawValue: envelope.method) else {
    throw WorkspaceError(
      .methodUnknown, "Unknown method \"\(envelope.method)\".", details: ["method": .string(envelope.method)])
  }
  if method.isMutation, (envelope.operationId ?? "").isEmpty {
    throw WorkspaceError(
      .protocolInvalid, "Method \"\(method.rawValue)\" is a mutation and requires an operationId.",
      details: ["method": .string(method.rawValue)])
  }
  let params: JSONValue
  switch envelope.params {
  case .none, .some(.null): params = .object([:])
  case .some(.object(let members)): params = .object(members)
  case .some:
    throw WorkspaceError(
      .protocolInvalid, "params must be an object.", details: ["method": .string(method.rawValue)])
  }
  return ParsedCommand(envelope: envelope, method: method, params: params)
}
