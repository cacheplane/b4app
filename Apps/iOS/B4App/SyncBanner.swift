import SwiftUI
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// One line while the last pull failed: when the mirror last caught up and why it cannot now. Hidden
/// once a pull succeeds. While the hub refuses the relay's link (a revoked device), that comes first:
/// it lasts until the phone logs out and pairs again.
struct SyncBanner: View {
  let status: MirrorSyncStatus
  var relayRefused: String?

  var body: some View {
    if let message = relayRefused
      ?? status.lastError.map({
        Self.message(error: $0, lastSyncAt: status.lastSyncAt)
      })
    {
      HStack(spacing: LLA.Space.s) {
        Circle()
          .fill(LLA.Color.danger)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text(message)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.ink)
          .lineLimit(relayRefused == nil ? 1 : 2)
          .truncationMode(.tail)
      }
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Space.s)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(LLA.Color.surfaceRaised)
      .overlay(alignment: .bottom) {
        Rectangle().fill(LLA.Color.rule).frame(height: 1)
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("sync.banner")
    }
  }

  static func message(error: String, lastSyncAt: String?) -> String {
    guard let lastSyncAt, let date = Timestamp.date(from: lastSyncAt) else {
      return "Not synced yet: \(error)"
    }
    let time = date.formatted(
      date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    return "Not synced since \(time): \(error)"
  }
}
