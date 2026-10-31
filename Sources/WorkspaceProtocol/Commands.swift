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
  case turnSend = "turn.send"
  case turnInterrupt = "turn.interrupt"
  case requestRespond = "request.respond"
  case credentialAdd = "credential.add"

  public var isMutation: Bool {
    switch self {
    case .draftSave, .connectionAdd, .connectionInspect, .connectionLogin, .threadCreate, .threadUpdate,
      .turnSend, .turnInterrupt, .requestRespond, .credentialAdd:
      return true
    case .systemPing, .diagnosticsRead, .connectionList, .threadList, .draftRead, .eventsSnapshot,
      .eventsReplay, .threadRead:
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

public enum EventsSnapshot: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var epoch: String
    public var sequence: Int
    public var connections: [Connection]
    public var threads: [ConversationThread]
    public init(epoch: String, sequence: Int, connections: [Connection], threads: [ConversationThread]) {
      self.epoch = epoch
      self.sequence = sequence
      self.connections = connections
      self.threads = threads
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
    public init(
      kind: ConnectionKind, label: String? = nil, executablePath: String? = nil, url: String? = nil,
      route: String? = nil, authReference: String? = nil
    ) {
      self.kind = kind
      self.label = label
      self.executablePath = executablePath
      self.url = url
      self.route = route
      self.authReference = authReference
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
    public init(connectionId: String, workingDirectory: String? = nil, title: String? = nil) {
      self.connectionId = connectionId
      self.workingDirectory = workingDirectory
      self.title = title
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
