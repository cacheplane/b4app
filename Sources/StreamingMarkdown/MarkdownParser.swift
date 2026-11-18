import Foundation

/// An append-only markdown block parser: text arrives in pieces through `push`, and `document` is
/// the blocks so far. A block that a later line cannot change is committed and keeps its value.
public struct MarkdownParser: Sendable {
  private var buffer = ""
  private var committed: [MarkdownBlock] = []
  private var state = BlockState()

  public init() {}

  public mutating func push(_ text: String) {
    // "\r\n" is one Character in Swift, so line endings are made "\n" before lines are cut. A "\r" at
    // the end of the buffer stays in it, so a "\r\n" split across two pushes is still one ending.
    let all = (buffer + text).replacingOccurrences(of: "\r\n", with: "\n")
    // Walk an index over the text; only the last, partial line is copied, once, after the loop.
    var start = all.startIndex
    while let newline = all[start...].firstIndex(of: "\n") {
      consume(all[start..<newline])
      start = all.index(after: newline)
    }
    buffer = String(all[start...])
  }

  /// Hands the unfinished line over as a last line and closes everything.
  public mutating func finish() {
    if !buffer.isEmpty {
      let line = Substring(buffer)
      buffer = ""
      consume(line.hasSuffix("\r") ? line.dropLast() : line)
    }
    commit(state.close())
  }

  /// The committed blocks and the open one, read from the completed lines. The text after the last
  /// newline is not in it yet.
  public var document: MarkdownDocument {
    var blocks = committed
    if let kind = state.current() { blocks.append(MarkdownBlock(id: String(blocks.count), kind: kind)) }
    return MarkdownDocument(blocks: blocks)
  }

  public static func parse(_ text: String) -> MarkdownDocument {
    var parser = MarkdownParser()
    parser.push(text)
    parser.finish()
    return parser.document
  }

  private mutating func consume(_ line: Substring) {
    commit(state.accept(line))
  }

  private mutating func commit(_ kinds: [MarkdownBlock.Kind]) {
    for kind in kinds { committed.append(MarkdownBlock(id: String(committed.count), kind: kind)) }
  }
}
