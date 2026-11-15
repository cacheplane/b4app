/// A reply's text cut into prose and fenced code, so code is drawn as a block and copied exactly. No
/// SwiftUI. Everything else in the text stays prose, as it was.
enum MarkdownBlocks {
  enum Block: Equatable, Sendable {
    /// Lines outside any fence, joined by "\n", without the blank lines at either end.
    case prose(String)
    /// The lines between a fence's opening and closing lines, joined by "\n", exactly as written.
    /// `language` is the first word after the opening fence. `closed` is false while the closing
    /// fence has not arrived: a reply still streaming, or one that never closed it.
    case code(language: String?, text: String, closed: Bool)
  }

  /// A fence opens on a line of three or more backticks or tildes (indented at most three spaces) and
  /// closes on a line of at least as many of the same character and nothing else. A backtick fence
  /// whose opening line holds another backtick is inline code, not a fence.
  static func split(_ text: String) -> [Block] {
    var blocks: [Block] = []
    var prose: [Substring] = []
    var code: [Substring] = []
    var fence: (mark: Character, count: Int, language: String?)?

    func flushProse() {
      let lines = prose.drop { isBlank($0) }
      let kept = lines.prefix(lines.count - lines.reversed().prefix { isBlank($0) }.count)
      if !kept.isEmpty { blocks.append(.prose(kept.joined(separator: "\n"))) }
      prose = []
    }

    for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      if let open = fence {
        if closes(line, open.mark, open.count) {
          blocks.append(.code(language: open.language, text: code.joined(separator: "\n"), closed: true))
          code = []
          fence = nil
        } else {
          code.append(line)
        }
      } else if let opened = opening(line) {
        flushProse()
        fence = opened
      } else {
        prose.append(line)
      }
    }
    if let open = fence {
      blocks.append(.code(language: open.language, text: code.joined(separator: "\n"), closed: false))
    } else {
      flushProse()
    }
    return blocks
  }

  private static func isBlank(_ line: Substring) -> Bool { line.allSatisfy(\.isWhitespace) }

  /// The line without up to three leading spaces, or nil when it is indented further.
  private static func unindented(_ line: Substring) -> Substring? {
    let body = line.drop { $0 == " " }
    return line.count - body.count <= 3 ? body : nil
  }

  private static func opening(_ line: Substring) -> (mark: Character, count: Int, language: String?)? {
    guard let body = unindented(line), let mark = body.first, mark == "`" || mark == "~" else { return nil }
    let run = body.prefix { $0 == mark }
    guard run.count >= 3 else { return nil }
    let info = body.dropFirst(run.count)
    if mark == "`", info.contains("`") { return nil }
    let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
    return (mark, run.count, language)
  }

  private static func closes(_ line: Substring, _ mark: Character, _ count: Int) -> Bool {
    guard let body = unindented(line) else { return false }
    let run = body.prefix { $0 == mark }
    return run.count >= count && body.dropFirst(run.count).allSatisfy(\.isWhitespace)
  }
}
