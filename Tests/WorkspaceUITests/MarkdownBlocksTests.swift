import Testing

@testable import WorkspaceUI

/// A reply's text cut into prose and fenced code (F02): what is drawn as a block, and what Copy takes.
@Suite struct MarkdownBlocksTests {
  private typealias Block = MarkdownBlocks.Block
  private let fence = "```"

  @Test func textWithoutAFenceIsOneProseBlockAsWritten() {
    let text = "First line.\n\n- a list item\n  indented `code`"
    #expect(MarkdownBlocks.split(text) == [.prose(text)])
    #expect(MarkdownBlocks.split("") == [])
    #expect(MarkdownBlocks.split("\n\n") == [])
  }

  @Test func aFenceIsACodeBlockWithItsLanguageAndExactText() {
    let text = "Run it:\n\n\(fence)bash\nswift test --filter SyncTests\n\(fence)\n\nThat is all."
    #expect(
      MarkdownBlocks.split(text) == [
        .prose("Run it:"),
        .code(language: "bash", text: "swift test --filter SyncTests", closed: true),
        .prose("That is all."),
      ])
  }

  /// What Copy takes is the lines between the fences: indentation, blank lines, long paths, emoji and
  /// combining marks as written, and no language word or fence.
  @Test func theCodeIsExactlyTheLinesBetweenTheFences() {
    let code =
      "func a() {\n\n    let p = \"/Users/dev/a very/long path/файл.swift\"  \n\tprint(\"👩🏽‍💻 e\u{301}\")\n}"
    let text = "\(fence)swift title=\"a.swift\"\n\(code)\n\(fence)"
    #expect(MarkdownBlocks.split(text) == [.code(language: "swift", text: code, closed: true)])
  }

  @Test func aFenceWithNoLanguageHasNone() {
    #expect(
      MarkdownBlocks.split("\(fence)\nls\n\(fence)") == [.code(language: nil, text: "ls", closed: true)])
    #expect(MarkdownBlocks.split("~~~\nls\n~~~") == [.code(language: nil, text: "ls", closed: true)])
  }

  /// A reply still streaming: the fence has opened and not closed.
  @Test func anOpenFenceIsAnUnclosedCodeBlock() {
    #expect(
      MarkdownBlocks.split("Here:\n\(fence)swift\nlet a = 1\nlet b")
        == [.prose("Here:"), .code(language: "swift", text: "let a = 1\nlet b", closed: false)])
    #expect(MarkdownBlocks.split("\(fence)sw") == [.code(language: "sw", text: "", closed: false)])
  }

  /// A longer fence holds shorter ones; a fence closes only on its own character.
  @Test func aFenceClosesOnlyOnAtLeastAsManyOfItsOwnCharacter() {
    let text = "````markdown\n\(fence)bash\nls\n\(fence)\n~~~\n````"
    #expect(
      MarkdownBlocks.split(text)
        == [.code(language: "markdown", text: "\(fence)bash\nls\n\(fence)\n~~~", closed: true)])
  }

  @Test func inlineBackticksAndDeepIndentsAreNotFences() {
    let inline = "Use \(fence)code\(fence) inline.\n\(fence)also\(fence) this"
    #expect(MarkdownBlocks.split(inline) == [.prose(inline)])
    let indented = "    \(fence)\n    not a fence\n    \(fence)"
    #expect(MarkdownBlocks.split(indented) == [.prose(indented)])
  }

  @Test func windowsLineEndingsSplitAsLines() {
    #expect(
      MarkdownBlocks.split("A\r\n\(fence)\r\nls\r\n\(fence)\r\nB")
        == [.prose("A"), .code(language: nil, text: "ls", closed: true), .prose("B")])
  }

  /// As a reply arrives a character at a time, a block that has closed never changes again, and the
  /// last cut equals the cut of the whole text.
  @Test func blocksThatHaveClosedStayAsTheyAreWhileTheReplyStreams() {
    let text =
      "Two steps.\n\n\(fence)bash\nswift build\n\(fence)\n\nThen:\n\n~~~swift\nlet 👩🏽‍💻 = \"e\u{301}\"\n~~~\n\nDone."
    var settled: [Block] = []
    var prefix = ""
    for character in text {
      prefix.append(character)
      let blocks = MarkdownBlocks.split(prefix)
      // Everything before the last block is settled; it must extend what was settled before.
      let before = Array(blocks.dropLast())
      #expect(Array(before.prefix(settled.count)) == settled, "after \(prefix.debugDescription)")
      if before.count > settled.count { settled = before }
    }
    #expect(MarkdownBlocks.split(prefix) == MarkdownBlocks.split(text))
    #expect(
      MarkdownBlocks.split(text) == [
        .prose("Two steps."), .code(language: "bash", text: "swift build", closed: true), .prose("Then:"),
        .code(language: "swift", text: "let 👩🏽‍💻 = \"e\u{301}\"", closed: true), .prose("Done."),
      ])
  }
}
