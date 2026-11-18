import StreamingMarkdown
import Testing

@Suite struct OpenDocumentTests {
  private func midStream(_ text: String) -> String {
    var parser = MarkdownParser()
    parser.push(text)
    return outline(parser.document)
  }

  @Test func anOpenParagraphShowsItsCompletedLines() {
    #expect(midStream("one\ntwo\n") == "p \"one two\"")
  }
  @Test func anOpenFenceShowsAsOpen() {
    #expect(midStream("```swift\nlet a\n") == "code swift open \"let a\"")
  }
  @Test func theUnfinishedLastLineIsIgnoredForNow() {
    #expect(midStream("one\ntw") == "p \"one\"")
    #expect(midStream("```\nlet a\nlet") == "code - open \"let a\"")
    #expect(midStream("# hea") == "")
  }
  @Test func aLongFencePushedLineByLineStaysFast() {
    var parser = MarkdownParser()
    parser.push("```\n")
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      for index in 0..<5000 {
        parser.push("line \(index)\n")
        _ = parser.document
      }
    }
    #expect(elapsed < .seconds(2))
    parser.finish()
    guard case .code(_, let text, let closed) = parser.document.blocks[0].kind else {
      Issue.record("not code")
      return
    }
    #expect(!closed)
    #expect(text.split(separator: "\n").count == 5000)
  }
}
