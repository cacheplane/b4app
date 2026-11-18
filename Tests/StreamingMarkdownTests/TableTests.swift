import StreamingMarkdown
import Testing

@Suite struct TableTests {
  private func parsed(_ text: String) -> String { outline(MarkdownParser.parse(text)) }

  @Test func aHeaderAndDelimiterRowMakeATable() {
    #expect(
      parsed("| a | b |\n|---|:-:|\n| 1 | 2 |") == "table - c\n  head \"a\" | \"b\"\n  row \"1\" | \"2\"")
  }
  @Test func alignmentsComeFromTheDelimiterRow() {
    #expect(parsed("a|b|c\n:--|--:|:-:").hasPrefix("table l r c"))
  }
  @Test func rowsArePaddedOrCutToTheHeader() {
    #expect(
      parsed("|a|b|\n|-|-|\n|1|\n|1|2|3|")
        == "table - -\n  head \"a\" | \"b\"\n  row \"1\" | \"\"\n  row \"1\" | \"2\"")
  }
  @Test func aHeaderWithNoDelimiterRowIsAParagraph() {
    #expect(parsed("| a | b |\nplain") == "p \"| a | b | plain\"")
  }
  @Test func aMismatchedDelimiterRowIsNotATable() {
    #expect(parsed("| a | b |\n|---|").hasPrefix("p "))
    #expect(parsed("| a | b |\n|---|") == "p \"| a | b | |---|\"")
  }
  @Test func escapedPipesAndPipesInCodeDoNotSplit() {
    #expect(
      parsed("|a|b|\n|-|-|\n|x \\| y|`p|q`|")
        == "table - -\n  head \"a\" | \"b\"\n  row \"x | y\" | \"`p|q`\"")
  }
  @Test func aBlankLineEndsTheTable() {
    #expect(parsed("|a|\n|-|\n|1|\n\nafter").hasSuffix("p \"after\""))
  }
  @Test func aTableInsideAQuoteAndAnItem() {
    #expect(parsed("> |a|\n> |-|\n> |1|").hasPrefix("quote\n  table -"))
    #expect(parsed("- x\n\n  |a|\n  |-|\n  |1|").contains("    table -"))
  }
  @Test func aLongTablePushedRowByRowStaysFast() {
    var (linear, parser) = staysLinear("|a|b|\n|-|-|\n", lines: 2000) {
      "|row \($0)|\(String(repeating: "x", count: 100))|\n"
    }
    #expect(linear)
    parser.finish()
    guard case .table(let table) = parser.document.blocks[0].kind else {
      Issue.record("not a table")
      return
    }
    #expect(table.rows.count == 8000)
  }
  @Test func onlyAParagraphsFirstLineCanBeAHeader() {
    #expect(parsed("a\n|b|c|\n|-|-|") == "p \"a |b|c| |-|-|\"")
  }
  @Test func aLazyDelimiterLineInAQuoteDoesNotMakeATable() {
    #expect(parsed("> |a|b|\n|-|-|") == "quote\n  p \"|a|b| |-|-|\"")
  }
  @Test func aHeadingAFenceAndAQuoteEndATable() {
    #expect(parsed("|a|\n|-|\n|1|\n# h") == "table -\n  head \"a\"\n  row \"1\"\nh1 \"h\"")
    #expect(
      parsed("|a|\n|-|\n|1|\n```\nx") == "table -\n  head \"a\"\n  row \"1\"\ncode - open \"x\"")
    #expect(
      parsed("|a|\n|-|\n|1|\n> q")
        == "table -\n  head \"a\"\n  row \"1\"\nquote\n  p \"q\"")
  }
  @Test func anEscapedBackslashBeforeAPipeStillSplits() {
    #expect(parsed("|a\\\\|b|\n|-|-|") == "table - -\n  head \"a\\\\\" | \"b\"")
  }
  @Test func aLongLineOfBacktickRunsStaysLinear() {
    // Runs of increasing length with pipes between: none has a matching closer.
    func line(_ size: Int) -> Substring {
      var text = ""
      var length = 1
      while text.count < size {
        text += String(repeating: "`", count: length) + "|"
        length += 1
      }
      return Substring(text)
    }
    let clock = ContinuousClock()
    func time(_ size: Int) -> Duration {
      var best = Duration.seconds(1000)
      for _ in 0..<3 {
        best = min(best, clock.measure { _ = MarkdownParser.parse(String(line(size))) })
      }
      return best
    }
    #expect(time(400_000) < time(100_000) * 8)
    #expect(time(400_000) < .seconds(5))
  }
}
