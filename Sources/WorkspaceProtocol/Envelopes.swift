import Foundation

public let protocolVersion = 1

public struct CommandEnvelope: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var kind: String
  public var requestId: String
  public var operationId: String?
  public var method: String
  public var params: JSONValue?

  public init(requestId: String, method: String, params: JSONValue?, operationId: String? = nil) {
    self.protocolVersion = WorkspaceProtocol.protocolVersion
    self.kind = "command"
    self.requestId = requestId
    self.operationId = operationId
    self.method = method
    self.params = params
  }
}

public struct ResponseEnvelope: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var kind: String
  public var requestId: String
  public var ok: Bool
  public var result: JSONValue?
  public var error: WorkspaceError?

  public static func success(_ requestId: String, result: JSONValue) -> ResponseEnvelope {
    ResponseEnvelope(
      protocolVersion: WorkspaceProtocol.protocolVersion, kind: "response", requestId: requestId, ok: true,
      result: result, error: nil)
  }

  public static func failure(_ requestId: String, error: WorkspaceError) -> ResponseEnvelope {
    ResponseEnvelope(
      protocolVersion: WorkspaceProtocol.protocolVersion, kind: "response", requestId: requestId, ok: false,
      result: nil, error: error)
  }
}

public struct EventEnvelope: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var kind: String
  public var epoch: String
  public var sequence: Int
  public var event: AdapterEvent

  public init(epoch: String, sequence: Int, event: AdapterEvent) {
    self.protocolVersion = WorkspaceProtocol.protocolVersion
    self.kind = "event"
    self.epoch = epoch
    self.sequence = sequence
    self.event = event
  }
}

public struct CoordinatorIdentity: Codable, Sendable, Equatable {
  public var version: String
  public var pid: Int32

  public init(version: String, pid: Int32) {
    self.version = version
    self.pid = pid
  }
}

/// Sent by the coordinator right after a client connects.
public struct HelloEnvelope: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var kind: String
  public var epoch: String
  public var sequence: Int
  public var coordinator: CoordinatorIdentity

  public init(epoch: String, sequence: Int, coordinator: CoordinatorIdentity) {
    self.protocolVersion = WorkspaceProtocol.protocolVersion
    self.kind = "hello"
    self.epoch = epoch
    self.sequence = sequence
    self.coordinator = coordinator
  }
}

/// Everything a client may receive from the coordinator.
public enum ServerEnvelope: Sendable, Equatable {
  case hello(HelloEnvelope)
  case response(ResponseEnvelope)
  case event(EventEnvelope)

  private struct Peek: Decodable {
    var kind: String
    var protocolVersion: Int
  }

  /// Decode one line. Returns nil for unknown kinds or versions so a client never crashes on new frames.
  public static func decode(_ data: Data) -> ServerEnvelope? {
    guard let peek = try? JSONCoding.decoder.decode(Peek.self, from: data),
      peek.protocolVersion == WorkspaceProtocol.protocolVersion
    else { return nil }
    switch peek.kind {
    case "hello":
      return (try? JSONCoding.decoder.decode(HelloEnvelope.self, from: data)).map(ServerEnvelope.hello)
    case "response":
      return (try? JSONCoding.decoder.decode(ResponseEnvelope.self, from: data)).map(ServerEnvelope.response)
    case "event":
      return (try? JSONCoding.decoder.decode(EventEnvelope.self, from: data)).map(ServerEnvelope.event)
    default: return nil
    }
  }

  public func encoded() throws -> Data {
    switch self {
    case .hello(let value): return try JSONCoding.encoder.encode(value)
    case .response(let value): return try JSONCoding.encoder.encode(value)
    case .event(let value): return try JSONCoding.encoder.encode(value)
    }
  }
}
