import Testing

@testable import StreamingMarkdown

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
    #expect(parsed("| a | b |\nplain") == "p \"| a | b |\\nplain\"")
  }
  @Test func aMismatchedDelimiterRowIsNotATable() {
    #expect(parsed("| a | b |\n|---|").hasPrefix("p "))
    #expect(parsed("| a | b |\n|---|") == "p \"| a | b |\\n|---|\"")
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
  @Test func aLongTablePushedRowByRowKeepsEveryRow() {
    let parser = streamedAndFinished("|a|b|\n|-|-|\n", pieces: 2000) {
      "|row \($0)|\(String(repeating: "x", count: 100))|\n"
    }
    guard case .table(let table) = parser.document.blocks[0].kind else {
      Issue.record("not a table")
      return
    }
    #expect(table.rows.count == 2000)
  }
  @Test func onlyAParagraphsFirstLineCanBeAHeader() {
    #expect(parsed("a\n|b|c|\n|-|-|") == "p \"a\\n|b|c|\\n|-|-|\"")
  }
  @Test func aLazyDelimiterLineInAQuoteDoesNotMakeATable() {
    #expect(parsed("> |a|b|\n|-|-|") == "quote\n  p \"|a|b|\\n|-|-|\"")
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
  @Test func aRowReportsHowManyCellsAPipeClosed() {
    #expect(LineScanner.tableRow("|a|b").cells == ["a", "b"])
    #expect(LineScanner.tableRow("|a|b").closedCount == 1)
    #expect(LineScanner.tableRow("|a|b|").closedCount == 2)
    #expect(LineScanner.tableRow("a|b").closedCount == 1)
    #expect(LineScanner.tableRow("a|b|").closedCount == 2)
    #expect(LineScanner.tableRow("|a").closedCount == 0)
    let plain = LineScanner.tableRow("plain")
    #expect(plain.cells == ["plain"] && plain.closedCount == 0 && !plain.splits)
  }
  @Test func fitPadsAndCuts() {
    #expect(LineScanner.fit(["1"], to: 3) == ["1", "", ""])
    #expect(LineScanner.fit(["1", "2", "3"], to: 2) == ["1", "2"])
    #expect(LineScanner.fit(["1", "2"], to: 2) == ["1", "2"])
  }
}
