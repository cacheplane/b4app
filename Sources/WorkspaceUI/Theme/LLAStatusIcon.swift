import SwiftUI

/// A connection's or a B4 project's state as one 16 pt icon: an ink check (connected), a cobalt spinner
/// (checking), a danger "!" (needs you), or a ghost ring (not checked). The words are the accessibility
/// label and the hover help, never visible text (settings connections design).
struct LLAStatusIcon: View {
  let status: LLAStatus
  /// The hover help when it says more than the label (a failure's reason).
  var detail: String?
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16

  var body: some View {
    glyph
      .frame(width: size, height: size)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(status.label)
      .accessibilityValue(detail ?? "")
      .help(detail.map { "\(status.label): \($0)" } ?? status.label)
  }

  @ViewBuilder private var glyph: some View {
    switch status {
    case .ok:
      Image(systemName: "checkmark.circle.fill")
        .resizable()
        .symbolRenderingMode(.palette)
        .foregroundStyle(LLA.Color.bg, LLA.Color.ink)
    case .attention:
      Image(systemName: "exclamationmark.circle.fill")
        .resizable()
        .symbolRenderingMode(.palette)
        .foregroundStyle(LLA.Color.bg, LLA.Color.danger)
    case .idle:
      Circle().strokeBorder(LLA.Color.ghost, lineWidth: size / 10)
    case .busy:
      LLASpinner(lineWidth: size / 9)
    }
  }
}

/// An indeterminate ring in the accent: a raised track and a quarter arc turning once a second. Drawn
/// rather than `ProgressView`, whose size and tint differ by platform.
struct LLASpinner: View {
  var lineWidth: CGFloat = 2
  @State private var turning = false

  var body: some View {
    ZStack {
      Circle().stroke(LLA.Color.surfaceRaised, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: 0.25)
        .stroke(LLA.Color.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(turning ? 360 : 0))
        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
    }
    .padding(lineWidth / 2)
    .onAppear { turning = true }
  }
}
