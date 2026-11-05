import Foundation

/// The title a thread gets from the message that starts it.
public enum ThreadTitle {
  /// The longest title, in characters, before the "…".
  static let limit = 60

  /// The first non-empty line, trimmed; a longer one is cut at the last word boundary within `limit`
  /// characters (at `limit` itself when the line has no space before it) and ends in "…".
  public static func fromFirstMessage(_ text: String) -> String {
    let line =
      text.split(whereSeparator: \.isNewline)
      .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    guard line.count > limit else { return line }
    let head = line.prefix(limit)
    let next = line[head.endIndex]
    var cut = Substring(head)
    if !next.isWhitespace, let space = head.lastIndex(where: \.isWhitespace) {
      cut = head[..<space]
    }
    return cut.trimmingCharacters(in: .whitespaces) + "…"
  }
}
