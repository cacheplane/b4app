/// The top-level block the parser has open: the lines it holds so far and what ends it.
struct BlockState: Equatable, Sendable {
  private enum Open: Equatable, Sendable {
    case none
    case paragraph([ParagraphLine])
    case fence(LineScanner.FenceOpening, [String])
  }

  private struct ParagraphLine: Equatable, Sendable {
    /// The line without whitespace at either end.
    let text: String
    /// The text with a hard break's marker removed, when the line ends in one.
    let hardText: String?
  }

  private var open = Open.none

  var isOpen: Bool { open != .none }

  /// Takes one complete line. Returns the blocks the line finished, in order.
  mutating func accept(_ line: Substring) -> [MarkdownBlock.Kind] {
    if case .fence(let opening, var lines) = open {
      if LineScanner.closesFence(line, opening) {
        open = .none
        return [.code(language: opening.language, text: lines.joined(separator: "\n"), closed: true)]
      }
      lines.append(String(line))
      open = .fence(opening, lines)
      return []
    }
    if LineScanner.isBlank(line) { return close() }
    if LineScanner.thematicBreak(line) { return close() + [.thematicBreak] }
    if let heading = LineScanner.heading(line) {
      return close() + [.heading(level: heading.level, text: heading.text)]
    }
    if let opening = LineScanner.fenceOpening(line) {
      let finished = close()
      open = .fence(opening, [])
      return finished
    }
    var lines: [ParagraphLine] = []
    if case .paragraph(let held) = open { lines = held }
    lines.append(Self.paragraphLine(line))
    open = .paragraph(lines)
    return []
  }

  /// Ends the open block, if any.
  mutating func close() -> [MarkdownBlock.Kind] {
    defer { open = .none }
    return current().map { [$0] } ?? []
  }

  /// The open block as it reads now, for a document read while the text is still arriving.
  func current() -> MarkdownBlock.Kind? {
    switch open {
    case .none:
      return nil
    case .paragraph(let lines):
      var text = ""
      for (index, line) in lines.enumerated() {
        if index == lines.count - 1 {
          text += line.text
        } else if let hard = line.hardText {
          text += hard + "\n"
        } else {
          text += line.text + " "
        }
      }
      return .paragraph(text)
    case .fence(let opening, let lines):
      return .code(language: opening.language, text: lines.joined(separator: "\n"), closed: false)
    }
  }

  private static func paragraphLine(_ line: Substring) -> ParagraphLine {
    let text = LineScanner.trimmed(line)
    let spaces = line.reversed().prefix { $0 == " " }.count
    if spaces >= 2 {
      return ParagraphLine(text: String(text), hardText: String(text))
    }
    if text.last == "\\" {
      return ParagraphLine(text: String(text), hardText: String(LineScanner.trimmed(text.dropLast())))
    }
    return ParagraphLine(text: String(text), hardText: nil)
  }
}
