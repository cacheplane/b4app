import SwiftUI

/// The dense composer's one muted line, where the picker row is at normal density (the Mac only): the
/// place, then the runtime and model, then the permission when it is not the default. It is text, not a
/// control; the palette and `/` in the field change the choices it names.
///
/// One line. The place gives way first, cut in the middle so both ends of its name stay; the runtime and
/// the permission keep their full width, and are cut at the tail only when they alone do not fit.
struct ComposerSummaryLine: View {
  let summary: ComposerSummary
  /// Told the width the runtime and permission are drawn at (the line's tests).
  var restWidth: ((CGFloat) -> Void)? = nil

  init(summary: ComposerSummary) {
    self.summary = summary
  }

  /// The runtime and the permission, led by " · " when the place comes before them.
  static func rest(_ summary: ComposerSummary) -> String {
    let words = [summary.runtime ?? ComposerSummary.noRuntime, summary.permission].compactMap { $0 }
      .joined(separator: " · ")
    return summary.place == nil ? words : " · " + words
  }

  var body: some View {
    HStack(spacing: 0) {
      if let place = summary.place {
        Text(place).lineLimit(1).truncationMode(.middle)
      }
      Text(Self.rest(summary))
        .lineLimit(1)
        .layoutPriority(1)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { restWidth?($0) }
    }
    .font(LLAFont.caption)
    .foregroundStyle(LLA.Color.muted)
    // Its words start under the field's text.
    .padding(.horizontal, ComposerField<EmptyView>.textLeading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary.spoken)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("composer-summary")
  }
}
