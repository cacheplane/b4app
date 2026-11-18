/// What one line is, outside the block that is open. Static functions over a line without its
/// line ending; each returns nil when the line is not that thing.
enum LineScanner {
  struct FenceOpening: Equatable {
    let mark: Character
    let count: Int
    let language: String?
  }

  static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

  /// The line without up to three leading spaces, or nil when it is indented further.
  static func unindented(_ line: Substring) -> Substring? {
    let body = line.drop { $0 == " " }
    return line.count - body.count <= 3 ? body : nil
  }

  /// Three or more of one of `-`, `*`, `_`, with spaces and tabs between, and nothing else.
  static func thematicBreak(_ line: Substring) -> Bool {
    guard let body = unindented(line), let mark = body.first, "-*_".contains(mark) else { return false }
    var count = 0
    for character in body {
      if character == mark {
        count += 1
      } else if character != " " && character != "\t" {
        return false
      }
    }
    return count >= 3
  }

  /// One to six `#`, then a space, a tab or the line's end; the closing `#`s are dropped.
  static func heading(_ line: Substring) -> (level: Int, text: String)? {
    guard let body = unindented(line) else { return nil }
    let marks = body.prefix { $0 == "#" }
    guard (1...6).contains(marks.count) else { return nil }
    let rest = body.dropFirst(marks.count)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    var text = trimmed(rest)
    let closing = text.reversed().prefix { $0 == "#" }.count
    if closing > 0 {
      let before = text.dropLast(closing)
      if before.isEmpty || before.last == " " || before.last == "\t" { text = trimmed(before) }
    }
    return (marks.count, String(text))
  }

  /// Three or more backticks or tildes, indented at most three spaces. A backtick opener holding
  /// another backtick is inline code, not a fence.
  static func fenceOpening(_ line: Substring) -> FenceOpening? {
    guard let body = unindented(line), let mark = body.first, mark == "`" || mark == "~" else { return nil }
    let run = body.prefix { $0 == mark }
    guard run.count >= 3 else { return nil }
    let info = body.dropFirst(run.count)
    if mark == "`", info.contains("`") { return nil }
    let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return FenceOpening(mark: mark, count: run.count, language: language)
  }

  /// At least as many of the same mark as the opener and nothing else.
  static func closesFence(_ line: Substring, _ opening: FenceOpening) -> Bool {
    guard let body = unindented(line) else { return false }
    let run = body.prefix { $0 == opening.mark }
    return run.count >= opening.count && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
  }

  /// The text without whitespace at either end.
  static func trimmed(_ text: Substring) -> Substring {
    var result = text.drop { $0.isWhitespace }
    while let last = result.last, last.isWhitespace { result = result.dropLast() }
    return result
  }
}
