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
}
