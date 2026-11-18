import StreamingMarkdown
import Testing

@Suite struct ProjectionTests {
  private func open(_ text: String) -> String {
    var parser = MarkdownParser()
    parser.push(text)
    return outline(parser.document)
  }

  @Test func aHeadingAppearsAtItsMarker() {
    #expect(open("#") == "h1 \"\"")
    #expect(open("## Ti") == "h2 \"Ti\"")
  }
  @Test func aBareMarkerIsHeldAndAMarkerWithASpaceIsAnItem() {
    #expect(open("-") == "")
    #expect(open("1.") == "")
    #expect(open("- ") == "list ul\n  item")
    #expect(open("a\n\n1") == "p \"a\"")
    #expect(open("- [x] d") == "list ul\n  item [x]\n    p \"d\"")
  }
  @Test func twoDashesAreHeldAndThreeAreABreak() {
    #expect(open("a\n\n--") == "p \"a\"")
    #expect(open("a\n\n---") == "p \"a\"\nhr")
  }
  @Test func aQuoteAppearsAtItsMarker() {
    #expect(open("> q") == "quote\n  p \"q\"")
    #expect(open("> -") == "quote")
  }
  @Test func anOpenFenceIsCodeAndItsClosingRunNeverFlashes() {
    #expect(open("```sw") == "code - open \"\"")  // language is taken when the line completes
    #expect(open("```swift\nlet a") == "code swift open \"let a\"")
    #expect(open("```swift\nlet a\n``") == "code swift open \"let a\"")
    #expect(open("```swift\nlet a\n```") == "code swift closed \"let a\"")
  }
  @Test func aTableAppearsAtItsFirstClosedHeaderCell() {
    #expect(open("| Na") == "p \"| Na\"")
    #expect(open("| Name |") == "table -\n  head \"Name\"")
    #expect(open("| Name | Ag") == "table - -\n  head \"Name\" | \"Ag\"")
  }
  @Test func thePendingHeaderStaysATableWhileTheDelimiterRowArrives() {
    #expect(open("| a | b |\n|--") == "table - -\n  head \"a\" | \"b\"")
    #expect(open("| a | b |\n|---|---|\n") == "table - -\n  head \"a\" | \"b\"")
  }
  @Test func aHalfTypedBodyRowIsARowPaddedToTheHeader() {
    #expect(open("| a | b |\n|---|---|\n| 1") == "table - -\n  head \"a\" | \"b\"\n  row \"1\" | \"\"")
  }
  @Test func aHeaderWhoseNextLineIsNotADelimiterRevertsToAParagraph() {
    #expect(open("| a | b |\nplain\n\n") == "p \"| a | b | plain\"")
  }
  @Test func unfinishedInlineMarkupIsClosedInTheOpenLeafOnly() {
    #expect(open("done **b\n\nnow **bo") == "p \"done **b\"\np \"now **bo**\"")
  }
  @Test func finishRemovesEveryGuess() {
    var parser = MarkdownParser()
    parser.push("**bold")
    parser.finish()
    #expect(outline(parser.document) == "p \"**bold\"")
    parser = MarkdownParser()
    parser.push("-")
    parser.finish()
    // A lone `-` is an empty item once the text is finished, as in CommonMark (a ruling on the plan).
    #expect(outline(parser.document) == "list ul\n  item")
  }
  @Test func streamingCharacterByCharacterReadsAsTheSameTextPushedAtOnce() {
    let text =
      "Run **this** `ls -la` and\n> see [the docs](https://e.com/x) for *more\n- a ` b ``c`` d ` e\n| a | b |\n|---|---|\n| **1 | 2"
    var streamed = MarkdownParser()
    var sent = ""
    for character in text {
      streamed.push(String(character))
      sent.append(character)
      var whole = MarkdownParser()
      whole.push(sent)
      #expect(streamed.document == whole.document, "after \(sent.debugDescription)")
    }
  }
  @Test func piecesWithoutANewlineGrowTheUnfinishedLine() {
    var pieces = MarkdownParser()
    for piece in ["one t", "wo **th", "ree", "** four\nfi", "ve"] { pieces.push(piece) }
    var whole = MarkdownParser()
    whole.push("one two **three** four\nfive")
    #expect(pieces.document == whole.document)
    #expect(outline(pieces.document) == "p \"one two **three** four five\"")
    pieces.finish()
    whole.finish()
    #expect(pieces.document == whole.document)
  }
  @Test func aLongFencePushedInPiecesWithoutReadsStaysFast() {
    // Many pushes per line, so most leave an unfinished line in the fence.
    let token = String(repeating: "x", count: 400)
    var (linear, parser) = staysLinear("```\n", lines: 1500, reading: false) {
      $0 % 8 == 7 ? "\(token)\n" : "\(token) "
    }
    #expect(linear)
    parser.finish()
    guard case .code(_, let text, _) = parser.document.blocks[0].kind else {
      Issue.record("not code")
      return
    }
    #expect(text.split(separator: "\n").count == 750)
  }
  @Test func oneLongLineStreamedWithReadsStaysFast() {
    let plain = String(repeating: "abcd efg", count: 8)
    let markup = "see **bold** and `code` [l](u) _it_ ~~x~~ a*b " + String(repeating: "z", count: 19)
    for piece in [plain, markup] {
      // 390 pieces of 64 characters is about 25,000 characters; the long run is about 100,000.
      let (linear, parser) = staysLinear("", lines: 390) { _ in piece }
      #expect(linear, "for \(piece.debugDescription)")
      #expect(parser.document.blocks.count == 1)
    }
  }
  @Test func readingTheDocumentDoesNotChangeTheParser() {
    var a = MarkdownParser()
    var b = MarkdownParser()
    a.push("| a |")
    _ = a.document
    a.push("\nplain\n")
    a.finish()
    b.push("| a |\nplain\n")
    b.finish()
    #expect(a.document == b.document)
  }
}
