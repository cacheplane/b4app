#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import WorkspaceUI

  /// A reply with fenced code, measured on a hosted view at a narrow column (F02, F15).
  @Suite(.serialized) @MainActor struct CodeFenceViewTests {
    private func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
      let host = NSHostingView(rootView: view.frame(width: width))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize
    }

    /// A line wider than the column scrolls inside its block; the reply keeps the column's width.
    @Test func aWideLineOfCodeDoesNotWidenTheReply() {
      let wide = String(repeating: "swift test --filter Sync ", count: 40)
      let reply = MarkdownText(text: "Run:\n\n```bash\n\(wide)\n```\n\nDone.")
      let measured = size(reply, width: 420)
      #expect(measured.width <= 420.5, "the reply is \(measured.width) pt wide")
      // One line of code, not wrapped into many: the block is as tall as a short one.
      let short = size(MarkdownText(text: "Run:\n\n```bash\nls\n```\n\nDone."), width: 420)
      #expect(abs(measured.height - short.height) <= 0.5)
    }

    /// A reply with no fence is the one text it always was.
    @Test func aReplyWithNoFenceIsDrawnAsBefore() {
      let text = "A plain reply with `inline code`.\n\nAnd a second paragraph."
      #expect(size(MarkdownText(text: text), width: 420) == size(MarkdownProse(text: text), width: 420))
    }

    /// A block that is still open draws without Copy while the reply streams, and with it once the
    /// reply has ended unclosed.
    @Test func anOpenBlockOffersCopyOnlyOnceTheReplyHasEnded() {
      #expect(
        MarkdownBlocks.split("```swift\nlet a") == [.code(language: "swift", text: "let a", closed: false)])
      #expect(!CodeFence(language: "swift", code: "let a", copyable: false).copyable)
      let streaming = size(MarkdownText(text: "```swift\nlet a", streaming: true), width: 420)
      let ended = size(MarkdownText(text: "```swift\nlet a", streaming: false), width: 420)
      #expect(streaming.height == ended.height, "Copy arriving must not move the code")
    }
  }
#endif
