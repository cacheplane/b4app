import Foundation
import WorkspaceProtocol

/// Codex app-server speaks JSON-RPC 2.0 over newline-delimited JSON with the "jsonrpc" field
/// omitted on the wire. Requests carry id + method; responses echo id with result or error;
/// notifications carry method without id. Server-initiated requests must be answered by id.
public enum RpcId: Sendable, Equatable, Hashable {
  case number(Int)
  case string(String)

  var json: JSONValue {
    switch self {
    case .number(let value): return .number(Double(value))
    case .string(let value): return .string(value)
    }
  }

  init?(_ value: JSONValue?) {
    switch value {
    case .some(.number(let n)): self = .number(Int(n))
    case .some(.string(let s)): self = .string(s)
    default: return nil
    }
  }
}

public struct RpcError: Sendable, Equatable {
  public var code: Int
  public var message: String
  public var data: JSONValue?
}

public enum RpcMessage: Sendable, Equatable {
  case response(id: RpcId, result: JSONValue)
  case error(id: RpcId, error: RpcError)
  case request(id: RpcId, method: String, params: JSONValue)
  case notification(method: String, params: JSONValue)
}

public enum JSONRPC {
  public static func classify(_ value: JSONValue) -> RpcMessage? {
    guard case .object(let record) = value else { return nil }
    let method = record["method"]?.stringValue
    let id = RpcId(record["id"])
    if let method, let id {
      return .request(id: id, method: method, params: record["params"] ?? .null)
    }
    if let method {
      return .notification(method: method, params: record["params"] ?? .null)
    }
    if let id, case .some(.object(let errorRecord)) = record["error"] {
      return .error(
        id: id,
        error: RpcError(
          code: Int(errorRecord["code"]?.numberValue ?? -1),
          message: errorRecord["message"]?.stringValue ?? "Unknown error",
          data: errorRecord["data"]))
    }
    if let id, record.keys.contains("result") {
      return .response(id: id, result: record["result"] ?? .null)
    }
    return nil
  }

  public static func encodeRequest(id: RpcId, method: String, params: JSONValue) throws -> Data {
    try NDJSON.encodeLine(JSONValue.object(["id": id.json, "method": .string(method), "params": params]))
  }

  public static func encodeNotification(method: String, params: JSONValue) throws -> Data {
    try NDJSON.encodeLine(JSONValue.object(["method": .string(method), "params": params]))
  }

  public static func encodeResponse(id: RpcId, result: JSONValue) throws -> Data {
    try NDJSON.encodeLine(JSONValue.object(["id": id.json, "result": result]))
  }

  public static func encodeError(id: RpcId, error: RpcError) throws -> Data {
    var body: [String: JSONValue] = ["code": .number(Double(error.code)), "message": .string(error.message)]
    if let data = error.data { body["data"] = data }
    return try NDJSON.encodeLine(JSONValue.object(["id": id.json, "error": .object(body)]))
  }
}

/// Incremental decoder: bytes in, classified messages out. Invalid lines are reported, never thrown.
public struct RpcDecoder: Sendable {
  private var lines = LineDecoder()
  public private(set) var invalidLines: [String] = []

  public init() {}

  public mutating func push(_ chunk: String) -> [RpcMessage] {
    push(Array(chunk.utf8))
  }

  public mutating func push(_ bytes: [UInt8]) -> [RpcMessage] {
    var messages: [RpcMessage] = []
    for line in lines.push(bytes) {
      guard let value = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(line.utf8)),
        let message = JSONRPC.classify(value)
      else {
        invalidLines.append(line)
        continue
      }
      messages.append(message)
    }
    return messages
  }
}
