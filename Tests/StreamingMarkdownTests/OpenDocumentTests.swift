import StreamingMarkdown
import Testing

@Suite struct OpenDocumentTests {
  private func midStream(_ text: String) -> String {
    var parser = MarkdownParser()
    parser.push(text)
    return outline(parser.document)
  }

  @Test func anOpenParagraphShowsItsCompletedLines() {
    #expect(midStream("one\ntwo\n") == "p \"one\\ntwo\"")
  }
  @Test func anOpenFenceShowsAsOpen() {
    #expect(midStream("```swift\nlet a\n") == "code swift open \"let a\"")
  }
  @Test func theUnfinishedLastLineIsProjected() {
    #expect(midStream("one\ntw") == "p \"one\\ntw\"")
    #expect(midStream("```\nlet a\nlet") == "code - open \"let a\\nlet\"")
    #expect(midStream("# hea") == "h1 \"hea\"")
  }
  @Test func aLongFencePushedLineByLineStaysOpenCode() {
    let filler = String(repeating: "x", count: 300)
    let parser = streamedAndFinished("```\n", pieces: 2000) { "line \($0) \(filler)\n" }
    guard case .code(_, let text, let closed) = parser.document.blocks[0].kind else {
      Issue.record("not code")
      return
    }
    #expect(!closed)
    #expect(text.split(separator: "\n").count == 2000)
  }
}
