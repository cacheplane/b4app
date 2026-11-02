import SwiftUI
import WorkspaceProtocol

/// One plan window: the label and percent, a 4 pt bar, and the time to reset under it, 4 pt apart.
/// Ink on the raised surface, danger from 90% (settings connections design).
struct UsageMeter: View {
  let title: String
  let window: UsageWindow
  let now: Date

  var body: some View {
    let hot = UsageFormat.isHot(window.usedPercent)
    let percent = UsageFormat.percent(window.usedPercent)
    let resets = UsageFormat.resets(window.resetsAt, now: now)
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      HStack(spacing: LLA.Space.s) {
        Text(title).foregroundStyle(LLA.Color.ink)
        Spacer(minLength: 0)
        Text(percent).monospacedDigit().foregroundStyle(hot ? LLA.Color.danger : LLA.Color.ink)
      }
      .font(LLAFont.caption)
      .lineLimit(1)
      Capsule()
        .fill(LLA.Color.surfaceRaised)
        .frame(height: 4)
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Capsule()
              .fill(hot ? LLA.Color.danger : LLA.Color.ink)
              .frame(width: proxy.size.width * UsageFormat.fill(window.usedPercent))
          }
        }
      if let resets {
        Text(resets).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(1)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue([percent + " used", resets].compactMap { $0 }.joined(separator: ", "))
  }
}
