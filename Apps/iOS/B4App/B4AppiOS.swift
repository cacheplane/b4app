import SwiftUI
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// The iOS companion reads the workspace the Mac syncs to the hub (M8a): until this device has
/// joined it shows the Connect screen, then the shared shell over the local mirror. Organising threads
/// and projects from the phone (M8b) writes to the mirror and uploads through the hub; chatting (M8c)
/// goes through the hub's relay to the Mac, whose link is held while the app is active.
///
/// A `b4app://pair` link (the Mac's QR code, opened from anywhere) fills the Connect screen and asks
/// before enrolling; on a phone that is already paired it says so and does nothing else.
@main
struct B4AppiOS: App {
  @State private var host = MirrorHost.shared
  @State private var model = WorkspaceModel(transportProvider: MirrorHost.transportProvider)
  /// A pairing link waiting for the Connect screen to take it (it holds the code: view state only).
  @State private var pairArrival: PairArrival?
  @State private var alreadyPaired = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      Group {
        if host.isLinked {
          // The shared shell's footer speaks for the mirror, which is always reachable; whether the
          // mirror is keeping up with the hub is said here, above everything, while it is not.
          WorkspaceRootView(model: model)
            .safeAreaInset(edge: .top, spacing: 0) {
              SyncBanner(status: host.syncStatus, relayRefused: host.relayRefused)
            }
            .task { host.wire(model) }
        } else {
          HubConnectView(host: host, incoming: $pairArrival)
        }
      }
      .onChange(of: scenePhase, initial: true) { _, phase in host.enter(RelayLifecycle.Phase(phase)) }
      .onOpenURL { url in open(url) }
      .alert(PairLink.alreadyPaired, isPresented: $alreadyPaired) {
        Button("OK", role: .cancel) {}
      }
    }
  }

  private func open(_ url: URL) {
    switch host.pairLink(url) {
    case .confirm(let link): pairArrival = .offer(link)
    case .invalid: pairArrival = .invalid(PairArrival.invalidLink)
    case .alreadyPaired: alreadyPaired = true
    case .ignored: break
    }
  }
}

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
