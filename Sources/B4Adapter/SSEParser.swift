import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
  public var event: String?
  public var data: String
  public var id: String?
  public var retry: Int?

  public init(event: String?, data: String, id: String? = nil, retry: Int? = nil) {
    self.event = event
    self.data = data
    self.id = id
    self.retry = retry
  }
}

/// Incremental WHATWG event-stream parser. Byte based: handles chunk boundaries anywhere, CR, LF and
/// CRLF line endings, comments, multi-line data, id and retry. `URLSession.bytes.lines` cannot be used
/// because it drops the blank lines that delimit events.
public struct SSEParser: Sendable {
  private var buffer: [UInt8] = []
  private var skipLF = false
  private var firstLine = true
  private var event: String?
  private var dataLines: [String] = []
  private var id: String?
  private var retry: Int?

  public init() {}

  public mutating func push(_ chunk: String) -> [SSEEvent] { push(Array(chunk.utf8)) }
  public mutating func push(_ chunk: Data) -> [SSEEvent] { push([UInt8](chunk)) }

  public mutating func push(_ bytes: [UInt8]) -> [SSEEvent] {
    var events: [SSEEvent] = []
    for byte in bytes {
      if skipLF {
        skipLF = false
        if byte == 0x0A { continue }
      }
      if byte == 0x0D || byte == 0x0A {
        var line = buffer
        buffer.removeAll(keepingCapacity: true)
        if firstLine {
          firstLine = false
          if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if let dispatched = handle(line: line) { events.append(dispatched) }
        skipLF = byte == 0x0D
      } else {
        buffer.append(byte)
      }
    }
    return events
  }

  /// EOF never dispatches incomplete data (WHATWG HTML §9.2.6). CR is processed immediately by push.
  public mutating func flush() -> SSEEvent? {
    buffer = []
    event = nil
    dataLines = []
    return nil
  }

  private mutating func handle(line: [UInt8]) -> SSEEvent? {
    if line.isEmpty { return dispatch() }
    if line.first == 0x3A { return nil }  // comment
    let text = String(decoding: line, as: UTF8.self)
    let field: Substring
    var value: Substring
    if let colon = text.firstIndex(of: ":") {
      field = text[text.startIndex..<colon]
      value = text[text.index(after: colon)...]
      if value.first == " " { value = value.dropFirst() }
    } else {
      field = text[...]
      value = ""
    }
    switch field {
    case "event":
      event = String(value)
    case "data":
      dataLines.append(String(value))
    case "id":
      if !value.contains("\u{0}") { id = String(value) }
    case "retry":
      if !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let parsed = Int(value) {
        retry = parsed
      }
    default:
      break
    }
    return nil
  }

  private mutating func dispatch() -> SSEEvent? {
    defer {
      event = nil
      dataLines = []
    }
    guard !dataLines.isEmpty else { return nil }
    let out = SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id, retry: retry)
    return out
  }
}
