import Foundation

/// An append-only markdown block parser: text arrives in pieces through `push`, and `document` is
/// the blocks so far. A block that a later line cannot change is committed and keeps its value.
public struct MarkdownParser: Sendable {
  private var buffer = ""
  private var committed: [MarkdownBlock] = []
  private var state = BlockState()
  /// The inline scan of the open leaf's text as of the last push, so a read scans only the
  /// characters that are new since. A cache: a read whose text does not extend it scans afresh.
  private var inline = InlineProjection.Scan()

  public init() {}

  public mutating func push(_ text: String) {
    // A piece with no newline completes no line: it only grows the unfinished one.
    if !text.utf8.contains(UInt8(ascii: "\n")) {
      buffer += text
      advanceInlineScan()
      return
    }
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
    advanceInlineScan()
  }

  /// Hands the unfinished line over as a last line and closes everything.
  public mutating func finish() {
    if !buffer.isEmpty {
      let line = Substring(buffer)
      buffer = ""
      consume(line.hasSuffix("\r") ? line.dropLast() : line)
    }
    commit(state.close())
    inline = InlineProjection.Scan()
  }

  /// The committed blocks and the open one. Before `finish()` the unfinished line after the last
  /// newline is projected into it: markers the next character decides are held and unfinished
  /// syntax is guessed (`OpenLineProjection.swift`, `InlineProjection`). The guesses are made on a
  /// copy of the open state on every read and never stored, so a wrong one reverts by itself.
  public var document: MarkdownDocument {
    let projection = state.projection(of: openLine, inline: inline)
    var blocks = committed
    for kind in projection.finished + [projection.open].compactMap({ $0 }) {
      blocks.append(MarkdownBlock(id: String(blocks.count), kind: kind))
    }
    return MarkdownDocument(blocks: blocks)
  }

  public static func parse(_ text: String) -> MarkdownDocument {
    var parser = MarkdownParser()
    parser.push(text)
    parser.finish()
    return parser.document
  }

  /// The unfinished line, without the "\r" of a "\r\n" split across pushes.
  private var openLine: Substring {
    buffer.hasSuffix("\r") ? Substring(buffer).dropLast() : Substring(buffer)
  }

  /// Brings the kept inline scan up to the open leaf's text, so the next read starts from it.
  private mutating func advanceInlineScan() {
    inline = state.projection(of: openLine, inline: inline).inline
  }

  private mutating func consume(_ line: Substring) {
    commit(state.accept(line))
  }

  private mutating func commit(_ kinds: [MarkdownBlock.Kind]) {
    for kind in kinds { committed.append(MarkdownBlock(id: String(committed.count), kind: kind)) }
  }
}
