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

  public var isMutation: Bool {
    switch self {
    case .draftSave: return true
    default: return false
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
