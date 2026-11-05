import SwiftUI
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// A concise sync status, hidden after a successful pull. Technical errors remain in Diagnostics.
/// A refused relay requires sign-in; an unreadable mirror is paused rather than retrying.
struct SyncBanner: View {
  static let signInRequiredMessage = "Log out, then sign in to reconnect."

  let status: MirrorSyncStatus
  var relayRefused: String?
  var syncPaused = false

  var body: some View {
    if let message = syncPaused
      ? "Sync paused. Check Diagnostics."
      : relayRefused
        ?? status.lastError.map({ _ in Self.message(lastSyncAt: status.lastSyncAt) })
    {
      HStack(spacing: LLA.Space.s) {
        Circle()
          .fill(LLA.Color.danger)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text(message)
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.ink)
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

  static func message(lastSyncAt: String?) -> String {
    guard let lastSyncAt, let date = Timestamp.date(from: lastSyncAt) else {
      return "Not synced yet. Retrying…"
    }
    let time = date.formatted(
      date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    return "Last synced \(time). Retrying…"
  }
}
