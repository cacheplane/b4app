import SwiftUI
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// The iOS companion reads the workspace the Mac syncs to the hub (M8a): until this device has
/// joined it shows the Connect screen, then the shared shell over the local mirror. Writing from the
/// phone arrives in M8b and sending turns through the hub in M8c; the mirror refuses both.
@main
struct B4AppiOS: App {
  @State private var host = MirrorHost.shared
  @State private var model = WorkspaceModel(transportProvider: MirrorHost.transportProvider)

  var body: some Scene {
    WindowGroup {
      if host.isLinked {
        // The shared shell's footer speaks for the mirror, which is always reachable; whether the
        // mirror is keeping up with the hub is said here, above everything, while it is not.
        WorkspaceRootView(model: model)
          .safeAreaInset(edge: .top, spacing: 0) { SyncBanner(status: host.syncStatus) }
      } else {
        HubConnectView(host: host)
      }
    }
  }
}

/// One line while the last pull failed: when the mirror last caught up and why it cannot now. Hidden
/// once a pull succeeds. It cannot tell a sleeping Mac from an idle one (presence arrives in M8c).
struct SyncBanner: View {
  let status: MirrorSyncStatus

  var body: some View {
    if let error = status.lastError {
      HStack(spacing: LLA.Space.s) {
        Circle()
          .fill(LLA.Color.danger)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
        Text(Self.message(error: error, lastSyncAt: status.lastSyncAt))
          .font(LLAFont.small)
          .foregroundStyle(LLA.Color.ink)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, LLA.Space.l)
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
