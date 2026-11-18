import StreamingMarkdown

/// Pushes `prefix`, then `count` pieces one push at a time, reading `document` after each push
/// when `reading`. Returns the fastest of three runs, to keep scheduling noise out, and the last
/// run's parser.
func streamed(
  _ prefix: String, lines count: Int, reading: Bool = true, line: (Int) -> String
) -> (time: Duration, parser: MarkdownParser) {
  let clock = ContinuousClock()
  var best = Duration.seconds(1000)
  var parser = MarkdownParser()
  for _ in 0..<3 {
    parser = MarkdownParser()
    parser.push(prefix)
    let elapsed = clock.measure {
      for index in 0..<count {
        parser.push(line(index))
        if reading { _ = parser.document }
      }
    }
    best = min(best, elapsed)
  }
  return (best, parser)
}

/// Whether streaming four times the lines took well under sixteen times as long: linear work gives
/// about 4, and work that re-reads the open block on every line gives about 16.
func staysLinear(
  _ prefix: String, lines count: Int, reading: Bool = true, line: (Int) -> String
) -> (
  linear: Bool, parser: MarkdownParser
) {
  let short = streamed(prefix, lines: count, reading: reading, line: line)
  let long = streamed(prefix, lines: count * 4, reading: reading, line: line)
  return (long.time < short.time * 8, long.parser)
}
