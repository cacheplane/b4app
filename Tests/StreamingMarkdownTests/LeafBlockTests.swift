import StreamingMarkdown
import Testing

@Suite struct LeafBlockTests {
  private func parsed(_ text: String) -> String { outline(MarkdownParser.parse(text)) }
  private let fence = "```"

  @Test func paragraphsAreSplitByBlankLinesAndSoftBreaksAreSpaces() {
    #expect(parsed("one\ntwo\n\nthree") == "p \"one two\"\np \"three\"")
  }
  @Test func aHardBreakKeepsTheLineBreak() {
    #expect(parsed("one  \ntwo\\\nthree") == "p \"one\\ntwo\\nthree\"")
  }
  @Test func headingsTakeTheirLevelAndDropClosingHashes() {
    #expect(parsed("# A\n###### B ##\n####### C\n#D") == "h1 \"A\"\nh6 \"B\"\np \"####### C #D\"")
  }
  @Test func threeOrMoreMarksAloneAreAThematicBreak() {
    #expect(parsed("a\n\n---\n***\n_ _ _\n--") == "p \"a\"\nhr\nhr\nhr\np \"--\"")
  }
  @Test func aTitleThenDashesIsAParagraphAndABreakNotASetextHeading() {
    #expect(parsed("Title\n---") == "p \"Title\"\nhr")
  }
  @Test func aFenceIsCodeWithItsLanguageAndExactText() {
    #expect(
      parsed("Run:\n\(fence)bash\n  ls -la\n\n# not a heading\n\(fence)\nDone.")
        == "p \"Run:\"\ncode bash closed \"  ls -la\\n\\n# not a heading\"\np \"Done.\"")
  }
  @Test func tildeFencesAndLongerFencesHoldShorterOnes() {
    #expect(parsed("~~~\n\(fence)\n~~~") == "code - closed \"\(fence)\"")
    #expect(parsed("````\n\(fence)\n````") == "code - closed \"\(fence)\"")
  }
  @Test func aBacktickOpenerHoldingABacktickIsNotAFence() {
    #expect(parsed("\(fence)a`b") == "p \"\(fence)a`b\"")
  }
  @Test func anUnclosedFenceStaysCodeMarkedOpenAfterFinish() {
    #expect(parsed("\(fence)swift\nlet a") == "code swift open \"let a\"")
  }
  @Test func indentedTextIsAParagraphNotCode() {
    #expect(parsed("    let v = 1") == "p \"let v = 1\"")
  }
  @Test func blankEdgesAndEmptyTextGiveNoBlocks() {
    #expect(MarkdownParser.parse("") == .empty)
    #expect(MarkdownParser.parse(" \n\n\t\n") == .empty)
    #expect(MarkdownParser.parse("\n\nhi  \n\n") == MarkdownParser.parse("hi"))
  }
  @Test func crlfLineEndingsParseAsLf() {
    let text = "# A\r\n\r\n\(fence)\r\nx\r\n\(fence)\r\n"
    #expect(
      MarkdownParser.parse(text) == MarkdownParser.parse(text.replacingOccurrences(of: "\r\n", with: "\n")))
    var split = MarkdownParser()
    split.push("a\r")
    split.push("\nb")
    split.finish()
    #expect(outline(split.document) == "p \"a b\"")
  }
  @Test func theLastLineIsNotDroppedWithoutATrailingNewline() {
    #expect(parsed("a\n\nb") == "p \"a\"\np \"b\"")
  }
  @Test func idsArePositionsAndCommittedBlocksKeepTheirValue() {
    var parser = MarkdownParser()
    parser.push("a\n\nb\n\n")
    let first = parser.document.blocks[0]
    parser.push("c\n\n")
    #expect(parser.document.blocks.map(\.id) == ["0", "1", "2"])
    #expect(parser.document.blocks[0] == first)
  }
}
