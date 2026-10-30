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
  private var event: String?
  private var dataLines: [String] = []
  private var id: String?
  private var retry: Int?
  private var hasFields = false

  public init() {}

  public mutating func push(_ chunk: String) -> [SSEEvent] { push(Array(chunk.utf8)) }
  public mutating func push(_ chunk: Data) -> [SSEEvent] { push([UInt8](chunk)) }

  public mutating func push(_ bytes: [UInt8]) -> [SSEEvent] {
    buffer.append(contentsOf: bytes)
    var events: [SSEEvent] = []
    while true {
      guard let (end, skip) = nextLineBreak() else { break }
      let line = Array(buffer[buffer.startIndex..<end])
      buffer.removeSubrange(buffer.startIndex..<(end + skip))
      if let dispatched = handle(line: line) { events.append(dispatched) }
    }
    return events
  }

  /// Dispatch a trailing event that was not terminated by a blank line.
  public mutating func flush() -> SSEEvent? {
    if !buffer.isEmpty {
      var line = buffer
      buffer = []
      if line.last == 0x0D { line.removeLast() }
      _ = handle(line: line)
    }
    return dispatch()
  }

  /// Index of the next line terminator and how many bytes it spans. A trailing lone CR waits for
  /// the next chunk, since it may be the first half of CRLF.
  private func nextLineBreak() -> (Int, Int)? {
    var index = buffer.startIndex
    while index < buffer.endIndex {
      let byte = buffer[index]
      if byte == 0x0A { return (index, 1) }
      if byte == 0x0D {
        if index == buffer.endIndex - 1 { return nil }
        return (index, buffer[index + 1] == 0x0A ? 2 : 1)
      }
      index += 1
    }
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
      hasFields = true
    case "data":
      dataLines.append(String(value))
      hasFields = true
    case "id":
      if !value.contains("\u{0}") { id = String(value) }
      hasFields = true
    case "retry":
      if let parsed = Int(value) { retry = parsed }
    default:
      break
    }
    return nil
  }

  private mutating func dispatch() -> SSEEvent? {
    guard hasFields else { return nil }
    let out = SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id, retry: retry)
    event = nil
    dataLines = []
    id = nil
    retry = nil
    hasFields = false
    return out
  }
}
