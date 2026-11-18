import StreamingMarkdown
import SwiftUI

/// A table: a header row in the body's semibold weight, a hairline under it and between the rows, and
/// each cell aligned as its column's delimiter says. At its natural width, scrolling sideways inside the
/// block when wider than the column, as code does.
struct MarkdownTableView: View, Equatable {
  let table: MarkdownTable

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.header.enumerated()), id: \.offset) { column, source in
            cell(source)
              .font(LLAFont.bodyStrong)
              .gridColumnAlignment(alignment(of: column))
          }
        }
        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
          rule
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { _, source in
              cell(source).font(LLAFont.body)
            }
          }
        }
      }
      .fixedSize(horizontal: true, vertical: true)
    }
    .accessibilityElement(children: .contain)
  }

  private var rule: some View {
    Rectangle().fill(LLA.Color.rule).frame(height: 1)
      .gridCellUnsizedAxes(.horizontal)
      .accessibilityHidden(true)
  }

  private func cell(_ source: String) -> some View {
    InlineText(source: source)
      .textSelection(.enabled)
      .padding(.horizontal, LLA.Space.m)
      .padding(.vertical, LLA.Space.s)
  }

  private func alignment(of column: Int) -> HorizontalAlignment {
    switch column < table.alignments.count ? table.alignments[column] : nil {
    case .center: .center
    case .trailing: .trailing
    case .leading, nil: .leading
    }
  }
}
