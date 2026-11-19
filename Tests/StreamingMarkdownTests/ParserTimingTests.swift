import Foundation
import StreamingMarkdown
import Testing

/// The parser's cost grows linearly with what is streamed. Each test streams a workload of size n and
/// of size 16n, five rounds interleaved, and compares the fastest of each: linear work gives a ratio
/// of about 16 and quadratic work about 256, so `long < short * 64` holds with room for noise and fails
/// on quadratic work. Time is the calling thread's CPU time, so time the thread spends descheduled on a
/// busy machine is not counted. No absolute bound is asserted.
///
/// Run only when `B4APP_TIMING` is set, alone in a process (CI's Test step does). The ordinary run
/// skips the suite, so it holds no timing assertion. `B4APP_TIMING_DIR=<dir>` also writes each
/// test's numbers to `<dir>/parser-timing-<test>.json`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_TIMING"] != nil))
struct ParserTimingTests {
  // MARK: Fences, lists and tables streamed line by line

  @Test func aLongFencePushedLineByLineIsLinear() throws {
    let filler = String(repeating: "x", count: 300)
    try expectLinear("fence-lines", n: 500) { lines in
      stream("```\n", pieces: lines) { "line \($0) \(filler)\n" }
    }
  }

  @Test func aLongFenceInsideAListItemIsLinear() throws {
    let filler = String(repeating: "x", count: 300)
    try expectLinear("fence-in-list", n: 500) { lines in
      stream("- Run:\n\n  ```\n", pieces: lines) { "  line \($0) \(filler)\n" }
    }
  }

  @Test func aLongTablePushedRowByRowIsLinear() throws {
    let cell = String(repeating: "x", count: 100)
    try expectLinear("table-rows", n: 500) { rows in
      stream("|a|b|\n|-|-|\n", pieces: rows) { "|row \($0)|\(cell)|\n" }
    }
  }

  /// Many pushes per line and no reads, so most pushes leave an unfinished line in the fence.
  @Test func aLongFencePushedInPiecesWithoutReadsIsLinear() throws {
    let token = String(repeating: "x", count: 400)
    try expectLinear("fence-pieces", n: 400) { pieces in
      stream("```\n", pieces: pieces, reading: false) { $0 % 8 == 7 ? "\(token)\n" : "\(token) " }
    }
  }

  // MARK: One long line

  /// One line streamed in 64-character pieces with a read after each. Each piece ends in whitespace,
  /// so the open line always does: trimming it must not walk the line.
  enum LongLinePiece: String, CaseIterable {
    case prose = "abcd efg abcd efg abcd efg abcd efg abcd efg abcd efg abcd efg a "
    case markup = "see **bold** and `code` [l](u) _it_ ~~x~~ a * b * c prose here  "
  }

  @Test(arguments: LongLinePiece.allCases)
  func oneLongLineStreamedWithReadsIsLinear(piece: LongLinePiece) throws {
    // 1,600 pieces of 64 characters, about 100,000 characters, in the long run.
    try expectLinear("long-line-\(piece)", n: 100) { pieces in
      stream("", pieces: pieces) { _ in piece.rawValue }
    }
  }

  /// One line with no newline, like a JSON reply, cut into 64-character pieces with a read after each.
  @Test func oneLongJSONLineStreamedWithReadsIsLinear() throws {
    let unit = "{\"k\":\"v **x** `y` [z](u)\","
    var whole = ""
    while whole.count < 16 * 6_400 { whole += unit }
    let characters = Array(whole)
    try expectLinear("long-line-json", n: 100) { pieces in
      stream("", pieces: pieces) { String(characters[($0 * 64)..<($0 * 64 + 64)]) }
    }
  }

  /// Backtick runs of increasing length with pipes between, none with a matching closer.
  @Test func aLongLineOfBacktickRunsIsLinear() throws {
    try expectLinear("backtick-runs", n: 25_000) { size in
      var text = ""
      var count = 0
      var length = 1
      while count < size {
        text += String(repeating: "`", count: length) + "|"
        count += length + 1
        length += 1
      }
      return (MarkdownParser.parse(text), text)
    }
  }

  // MARK: A reply one character at a time

  /// A mixed reply (paragraphs, lists, code, a table) pushed one character at a time, read every 16.
  @Test func aReplyPushedOneCharacterAtATimeIsLinear() throws {
    let unit = try corpusText("mixed-reply.md")
    try #require(!unit.isEmpty)
    var whole = ""
    while whole.count < 16 * 6_250 { whole += unit }
    let characters = Array(whole)
    try expectLinear("characters", n: 6_250) { size in
      var parser = MarkdownParser()
      for index in 0..<size {
        parser.push(String(characters[index]))
        if index % 16 == 0 { _ = parser.document }
      }
      parser.finish()
      return (parser.document, String(characters[0..<size]))
    }
  }
}

// MARK: - Measuring

/// The calling thread's CPU time in nanoseconds.
private func threadTime() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

/// Runs `work` at `n` and at `16 * n`, five rounds interleaved, and expects the fastest long run to
/// take less than 64 times the fastest short one. `work(size)` streams a workload of that size and
/// returns the finished document and the text it streamed; the long run's document must equal a
/// fresh parse of that text.
private func expectLinear(
  _ name: String, n: Int, sourceLocation: SourceLocation = #_sourceLocation,
  _ work: (Int) -> (document: MarkdownDocument, text: String)
) throws {
  var short = UInt64.max
  var long = UInt64.max
  var last: (document: MarkdownDocument, text: String)?
  for _ in 0..<5 {
    for size in [n, 16 * n] {
      let start = threadTime()
      let result = work(size)
      let elapsed = threadTime() - start
      if size == n {
        short = min(short, elapsed)
      } else {
        long = min(long, elapsed)
        last = result
      }
    }
  }
  let ratio = Double(long) / Double(max(short, 1))
  #expect(
    long < short * 64, "\(name): 16n took \(ratio)x n (n \(short) ns, 16n \(long) ns)",
    sourceLocation: sourceLocation)
  let final = try #require(last, sourceLocation: sourceLocation)
  #expect(
    final.document == MarkdownParser.parse(final.text), "\(name): the streamed document",
    sourceLocation: sourceLocation)
  if let directory = ProcessInfo.processInfo.environment["B4APP_TIMING_DIR"] {
    let numbers: [String: Double] = [
      "n": Double(n), "shortMs": Double(short) / 1e6, "longMs": Double(long) / 1e6, "ratio": ratio,
    ]
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: numbers, options: [.sortedKeys, .prettyPrinted])
      .write(to: URL(fileURLWithPath: "\(directory)/parser-timing-\(name).json"))
  }
}

/// Pushes `prefix`, then `count` pieces, reading `document` after each push when `reading`, then
/// finishes. Returns the document and the whole text pushed.
private func stream(
  _ prefix: String, pieces count: Int, reading: Bool = true, piece: (Int) -> String
) -> (document: MarkdownDocument, text: String) {
  var parser = MarkdownParser()
  var text = prefix
  parser.push(prefix)
  for index in 0..<count {
    let next = piece(index)
    parser.push(next)
    text += next
    if reading { _ = parser.document }
  }
  parser.finish()
  return (parser.document, text)
}
