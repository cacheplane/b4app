/// The top-level block the parser has open: the lines it holds so far and what ends it.
///
/// The open block's storage is plain stored properties that `accept` mutates in place. Never pull
/// the storage out of an enum payload into a local `var` to append to it: the enum still holds the
/// array, so the append copies the whole array on every line. Container states should do the same.
struct BlockState: Equatable, Sendable {
  private enum Open: Equatable, Sendable {
    case none, paragraph, fence
  }

  private struct ParagraphLine: Equatable, Sendable {
    /// The line without whitespace at either end.
    let text: String
    /// The text with a hard break's marker removed, when the line ends in one.
    let hardText: String?
  }

  private var open = Open.none
  private var paragraphLines: [ParagraphLine] = []
  private var fence: LineScanner.FenceOpening?
  /// The open fence's code, kept joined as lines arrive so a read does not join them again.
  private var fenceText = ""
  private var fenceHasLines = false

  /// Takes one complete line. Returns the blocks the line finished, in order.
  mutating func accept(_ line: Substring) -> [MarkdownBlock.Kind] {
    if open == .fence, let fence {
      if LineScanner.closesFence(line, fence) {
        let kind = MarkdownBlock.Kind.code(language: fence.language, text: fenceText, closed: true)
        reset()
        return [kind]
      }
      if fenceHasLines { fenceText += "\n" }
      fenceText += line
      fenceHasLines = true
      return []
    }
    if LineScanner.isBlank(line) { return close() }
    if LineScanner.thematicBreak(line) { return close() + [.thematicBreak] }
    if let heading = LineScanner.heading(line) {
      return close() + [.heading(level: heading.level, text: heading.text)]
    }
    if let opening = LineScanner.fenceOpening(line) {
      let finished = close()
      open = .fence
      fence = opening
      return finished
    }
    open = .paragraph
    paragraphLines.append(Self.paragraphLine(line))
    return []
  }

  /// Ends the open block, if any.
  mutating func close() -> [MarkdownBlock.Kind] {
    defer { reset() }
    return current().map { [$0] } ?? []
  }

  /// The open block as it reads now, for a document read while the text is still arriving.
  func current() -> MarkdownBlock.Kind? {
    switch open {
    case .none:
      return nil
    case .paragraph:
      // Rebuilt on every read: a paragraph is short, so this stays cheap.
      var text = ""
      for (index, line) in paragraphLines.enumerated() {
        if index == paragraphLines.count - 1 {
          text += line.text
        } else if let hard = line.hardText {
          text += hard + "\n"
        } else {
          text += line.text + " "
        }
      }
      return .paragraph(text)
    case .fence:
      return .code(language: fence?.language, text: fenceText, closed: false)
    }
  }

  private mutating func reset() {
    open = .none
    paragraphLines = []
    fence = nil
    fenceText = ""
    fenceHasLines = false
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
