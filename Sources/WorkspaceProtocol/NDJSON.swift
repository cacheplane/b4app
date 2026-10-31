import Foundation

/// Newline-delimited framing shared by the coordinator socket and the Codex app-server bridge.
/// Byte-based on purpose: Swift treats "\r\n" as one Character, so string search would miss it.
public struct LineDecoder: Sendable {
  private var buffer: [UInt8] = []

  public init() {}

  /// Push a chunk; returns every complete line received so far, without newlines and without blank lines.
  public mutating func push(_ chunk: String) -> [String] {
    push(Array(chunk.utf8))
  }

  public mutating func push(_ chunk: Data) -> [String] {
    push([UInt8](chunk))
  }

  public mutating func push(_ bytes: [UInt8]) -> [String] {
    buffer.append(contentsOf: bytes)
    var lines: [String] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = Array(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      if line.last == 0x0D { line.removeLast() }
      if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
    }
    return lines
  }

  /// Flush a trailing partial line, if any.
  public mutating func flush() -> String? {
    var rest = buffer
    buffer = []
    if rest.last == 0x0D { rest.removeLast() }
    return rest.isEmpty ? nil : String(decoding: rest, as: UTF8.self)
  }
}

public enum NDJSON {
  /// Encode one value as a single JSON line.
  public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONCoding.encoder.encode(value)
    data.append(0x0A)
    return data
  }
}
