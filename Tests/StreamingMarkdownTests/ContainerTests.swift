import StreamingMarkdown
import Testing

@Suite struct ContainerTests {
  private func parsed(_ text: String) -> String { outline(MarkdownParser.parse(text)) }

  @Test func aBulletListHoldsItsItems() {
    #expect(parsed("- a\n- b") == "list ul\n  item\n    p \"a\"\n  item\n    p \"b\"")
  }
  @Test func anOrderedListKeepsItsStart() {
    #expect(parsed("3. a\n4. b") == "list ol 3\n  item\n    p \"a\"\n  item\n    p \"b\"")
  }
  @Test func aBlankLineBetweenItemsDoesNotSplitTheList() {
    #expect(parsed("- a\n\n- b") == parsed("- a\n- b"))
  }
  @Test func anItemHoldsFencedCodeAndASecondParagraph() {
    #expect(
      parsed("1. Run:\n\n   ```sh\n   ls\n   ```\n\n   Then stop.\n2. Next")
        == "list ol 1\n  item\n    p \"Run:\"\n    code sh closed \"ls\"\n    p \"Then stop.\"\n  item\n    p \"Next\""
    )
  }
  @Test func listsNestByIndent() {
    #expect(
      parsed("- a\n  - b\n    - c\n- d")
        == "list ul\n  item\n    p \"a\"\n    list ul\n      item\n        p \"b\"\n        list ul\n          item\n            p \"c\"\n  item\n    p \"d\""
    )
  }
  @Test func taskItemsCarryTheirState() {
    #expect(
      parsed("- [ ] a\n- [x] b\n- c")
        == "list ul\n  item [ ]\n    p \"a\"\n  item [x]\n    p \"b\"\n  item\n    p \"c\"")
  }
  @Test func aDifferentMarkerStartsANewList() {
    #expect(parsed("- a\n1. b") == "list ul\n  item\n    p \"a\"\nlist ol 1\n  item\n    p \"b\"")
  }
  @Test func anUnindentedParagraphAfterABlankLineEndsTheList() {
    #expect(parsed("- a\n\nb") == "list ul\n  item\n    p \"a\"\np \"b\"")
  }
  @Test func aQuoteHoldsBlocksIncludingListsAndQuotes() {
    #expect(
      parsed("> # T\n> - a\n> > deep")
        == "quote\n  h1 \"T\"\n  list ul\n    item\n      p \"a\"\n  quote\n    p \"deep\"")
  }
  @Test func aLazyLineContinuesTheParagraphInAQuoteOrItem() {
    #expect(parsed("> a\nb") == "quote\n  p \"a b\"")
    #expect(parsed("- a\nb") == "list ul\n  item\n    p \"a b\"")
  }
  @Test func aParagraphThenAQuoteAreSiblings() {  // cacheplane's `a\n> q` bug
    #expect(parsed("a\n> q") == "p \"a\"\nquote\n  p \"q\"")
  }
  @Test func aQuoteInsideAnItem() {
    #expect(parsed("- a\n  > q") == "list ul\n  item\n    p \"a\"\n    quote\n      p \"q\"")
  }
  @Test func twoSpacesTimesThreeAndATabIndentTheSame() {
    #expect(parsed("- a\n\t- b") == parsed("- a\n    - b"))
  }
  @Test func nestingStopsAtSixteenLevelsWithoutCrashing() {
    let deep = String(repeating: "> ", count: 40) + "x"
    let doc = MarkdownParser.parse(deep)
    #expect(outline(doc).split(separator: "\n").count == 17)  // 16 quotes and one paragraph
    #expect(outline(doc).hasSuffix("p \"" + String(repeating: "> ", count: 24) + "x\""))
    _ = MarkdownParser.parse(
      (0..<20).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n"))
  }
  @Test func nestedIdsArePaths() {
    let doc = MarkdownParser.parse("a\n\n- x\n- y\n  > q")
    guard case .list(let list) = doc.blocks[1].kind else {
      Issue.record("not a list")
      return
    }
    #expect(list.items.map(\.id) == ["1.0", "1.1"])
    #expect(list.items[1].blocks.map(\.id) == ["1.1.0", "1.1.1"])
  }

  @Test func aNestedIdDoesNotChangeAsLaterSiblingsArrive() {
    var parser = MarkdownParser()
    parser.push("p\n\n> a\n> - x\n")
    let before = parser.document
    parser.push(">   y\n> - z\n> b\n")
    guard case .quote(let early) = before.blocks[1].kind,
      case .quote(let late) = parser.document.blocks[1].kind,
      case .list(let earlyList) = early[1].kind, case .list(let lateList) = late[1].kind
    else {
      Issue.record("not a quote holding a list")
      return
    }
    #expect(early.map(\.id) == ["1.0", "1.1"])
    #expect(late.map(\.id) == ["1.0", "1.1"])
    #expect(earlyList.items[0].id == lateList.items[0].id)
    #expect(lateList.items.map(\.id) == ["1.1.0", "1.1.1"])
    #expect(lateList.items[0].blocks.map(\.id) == ["1.1.0.0"])
    #expect(outline(parser.document).hasSuffix("item\n      p \"z b\""))
  }
  @Test func anOpenListShowsItsCompletedLines() {
    var parser = MarkdownParser()
    parser.push("- a\n  - b\n")
    #expect(
      outline(parser.document) == "list ul\n  item\n    p \"a\"\n    list ul\n      item\n        p \"b\"")
  }
  @Test func aLongFenceInsideAListItemStaysFast() {
    var parser = MarkdownParser()
    parser.push("- Run:\n\n  ```\n")
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for index in 0..<5000 {
        parser.push("  line \(index)\n")
        _ = parser.document
      }
    }
    #expect(elapsed < .seconds(2))
    parser.finish()
    guard case .list(let list) = parser.document.blocks[0].kind,
      case .code(_, let text, let closed) = list.items[0].blocks[1].kind
    else {
      Issue.record("not code in a list item")
      return
    }
    #expect(!closed)
    #expect(text.split(separator: "\n").count == 5000)
    #expect(text.hasPrefix("line 0\n"))
  }
}
