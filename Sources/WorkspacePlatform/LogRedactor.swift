import Darwin
import Foundation

/// Reads bounded, redacted tails of a server log the child writes directly (D-029). Redaction masks
/// the credential shapes we know; it is not proof that arbitrary project output holds no secret.
public enum LogRedactor {
  public struct Tail: Sendable, Equatable {
    public var lines: [String]
    /// Byte offset just past the last line returned; pass it back as `afterOffset`.
    public var offset: Int
    /// True when the file holds lines before the first one returned.
    public var truncated: Bool
  }

  private static let patterns: [(NSRegularExpression, String)] = [
    (try! NSRegularExpression(pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#), "Bearer [redacted]"),
    (try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{8,}"#), "[redacted]"),
    (
      try! NSRegularExpression(
        pattern:
          #"(?i)\b([A-Z0-9_]*(?:api[_-]?key|token|secret|password|authorization)[A-Z0-9_]*)(\s*[=:]\s*)(?!\[redacted\]|Bearer\b)\S+"#
      ), "$1$2[redacted]"
    ),
  ]

  public static func redact(_ line: String) -> String {
    var text = line
    for (regex, template) in patterns {
      text = regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    return text
  }

  /// The last `lines` lines (or everything after `afterOffset`), each redacted. A missing file is an
  /// empty tail at offset 0.
  public static func tail(path: String, lines: Int, afterOffset: Int?) throws -> Tail {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      return Tail(lines: [], offset: 0, truncated: false)
    }
    defer { try? handle.close() }
    let size = Int(try handle.seekToEnd())
    var start = 0
    var truncated = false
    if let afterOffset, afterOffset <= size {
      start = afterOffset
    } else if afterOffset != nil {
      start = 0
      truncated = true
    }
    try handle.seek(toOffset: UInt64(start))
    let data = try handle.readToEnd() ?? Data()
    var all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    // A trailing newline yields an empty last element; a partial last line is kept.
    if all.last == "" { all.removeLast() }
    if afterOffset == nil, all.count > lines {
      truncated = true
      all = Array(all.suffix(lines))
    }
    return Tail(lines: all.map(redact), offset: size, truncated: truncated)
  }

  /// Keep the file under `limit` bytes by copying the last `keep` bytes to the front and truncating.
  /// Appending writers (`O_APPEND`) continue correctly after the truncation.
  public static func bound(path: String, limit: Int = 4 << 20, keep: Int = 1 << 20) throws {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = attributes[.size] as? Int, size > limit
    else { return }
    let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(size - keep))
    var kept = try handle.readToEnd() ?? Data()
    if let newline = kept.firstIndex(of: UInt8(ascii: "\n")) { kept = kept[kept.index(after: newline)...] }
    try handle.truncate(atOffset: 0)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: kept)
  }
}
