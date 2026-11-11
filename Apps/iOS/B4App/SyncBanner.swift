import SwiftUI
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// A concise sync status, hidden after a successful pull. Technical errors remain in Diagnostics.
/// A refused relay requires sign-in; an unreadable mirror is paused rather than retrying.
struct SyncBanner: View {
  static let signInRequiredMessage = SyncBannerContent.signInRequiredMessage

  let status: MirrorSyncStatus
  var relayRefused: String?
  var syncPaused = false

  var body: some View {
    if let message = SyncBannerContent(
      lastError: status.lastError, lastSyncAt: status.lastSyncAt,
      relayRefused: relayRefused, syncPaused: syncPaused
    ).text {
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

}
