import Foundation
import StreamingMarkdown
import SwiftUI

/// A reply drawn as block markdown: one view per block, keyed by the block's id and `Equatable` on its
/// value, so a block that did not change is skipped as the reply's last block grows. Agent output is
/// drawn as text, never executed: no HTML, no scripts, no images, and only web and mail links open
/// (`LinkPolicy`). An empty document draws nothing.
struct MarkdownText: View, Equatable {
  let document: MarkdownDocument
  /// The reply is still arriving: an open fence may yet close, so it offers no Copy.
  var streaming = false

  init(document: MarkdownDocument, streaming: Bool = false) {
    self.document = document
    self.streaming = streaming
  }

  /// For a caller with settled text: the text parsed whole.
  init(text: String, streaming: Bool = false) {
    self.init(document: MarkdownParser.parse(text), streaming: streaming)
  }

  var body: some View {
    if !document.blocks.isEmpty {
      MarkdownBlocksView(blocks: document.blocks, streaming: streaming)
        .foregroundStyle(LLA.Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Blocks one under another, as a reply, a quote or a list item holds them.
private struct MarkdownBlocksView: View {
  let blocks: [MarkdownBlock]
  let streaming: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.m) {
      ForEach(blocks) { block in
        MarkdownBlockView(block: block, streaming: streaming).equatable()
      }
    }
  }
}

/// One block. Text takes its colour from the environment, so a quote's blocks draw muted.
struct MarkdownBlockView: View, Equatable {
  let block: MarkdownBlock
  let streaming: Bool

  var body: some View {
    switch block.kind {
    case .paragraph(let source):
      InlineText(source: source)
        .font(LLAFont.body)
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .heading(let level, let source):
      InlineText(source: source)
        .font(Self.headingFont(level))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    case .thematicBreak:
      Rectangle().fill(LLA.Color.rule).frame(height: 1)
        .accessibilityHidden(true)
    case .code(let language, let text, let closed):
      CodeFence(language: language, code: text, copyable: closed || !streaming)
    case .quote(let blocks):
      HStack(alignment: .top, spacing: LLA.Space.m) {
        Rectangle().fill(LLA.Color.rule).frame(width: 2)
          .accessibilityHidden(true)
        MarkdownBlocksView(blocks: blocks, streaming: streaming)
          .foregroundStyle(LLA.Color.muted)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .list(let list):
      MarkdownListView(list: list, streaming: streaming)
    case .table(let table):
      MarkdownTableView(table: table)
    }
  }

  /// Three sizes from the type scale: level 1, level 2, and levels 3 to 6.
  static func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: LLAFont.display
    case 2: LLAFont.title
    default: LLAFont.bodyStrong
    }
  }
}

/// A list: a marker column (a bullet, the item's number, or a task's box) and the item's blocks beside
/// it. A nested list sits in its item's content column, so it is indented by the marker column.
private struct MarkdownListView: View {
  let list: MarkdownList
  let streaming: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: LLA.Space.s) {
      ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: LLA.Space.s) {
          marker(index: index, task: item.task)
            .font(LLAFont.body)
            .monospacedDigit()
            .frame(minWidth: LLA.Space.xl, alignment: .trailing)
          MarkdownBlocksView(blocks: item.blocks, streaming: streaming)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  @ViewBuilder private func marker(index: Int, task: Bool?) -> some View {
    if let done = task {
      Image(systemName: done ? "checkmark.square" : "square")
        .foregroundStyle(LLA.Color.muted)
        .accessibilityLabel(done ? "Done" : "Not done")
    } else if list.ordered {
      Text(verbatim: "\(list.start + index).")
    } else {
      Text(verbatim: "•").accessibilityHidden(true)
    }
  }
}

/// A block's inline source (a paragraph, a heading, a table cell) through Foundation's inline parser,
/// whitespace kept, links filtered by `LinkPolicy`. It caches nothing: its `Equatable` conformance keeps
/// a block that did not change from being parsed again. Source Foundation rejects draws as written.
struct InlineText: View, Equatable {
  let source: String

  var body: some View {
    if let parsed = try? AttributedString(
      markdown: source,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    {
      Text(LinkPolicy.filtered(parsed))
    } else {
      Text(source)
    }
  }
}
