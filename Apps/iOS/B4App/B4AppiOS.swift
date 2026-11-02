import SwiftUI
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceUI

/// The iOS companion reads the workspace the Mac syncs to the hub (M8a): the shared shell over the
/// local mirror. Organising threads and projects from the phone (M8b) writes to the mirror and uploads
/// through the hub; chatting (M8c) goes through the hub's relay to the Mac, whose link is held while the
/// app is active.
///
/// The root is `WorkspaceRootView`'s (sign-in plan, Task 14): the sign-in screen while signed out,
/// onboarding while the new account has no name, and the workspace otherwise. The phone signs in at its
/// flavour's hub itself, through its host's account. Under the sign-in screen, "Use an enrollment code"
/// opens the sheet for a hub that gives out codes; a `b4app://pair` link (the Mac's QR code, opened from
/// anywhere) opens it too and asks before enrolling. On a phone that is signed in it says so and does
/// nothing else. A stray `b4app*://auth` callback is dropped.
@main
struct B4AppiOS: App {
  @State private var host = MirrorHost.shared
  @State private var model = MirrorHost.shared.makeModel()
  /// A pairing link waiting for the enrollment sheet to take it (it holds the code: view state only).
  @State private var pairArrival: PairArrival?
  @State private var enrolling = false
  @State private var alreadyPaired = false
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WorkspaceRootView(model: model)
        // The shared shell's footer speaks for the mirror, which is always reachable; whether the
        // mirror is keeping up with the hub is said here, above everything, while it is not.
        .safeAreaInset(edge: .top, spacing: 0) {
          if model.rootScreen == .workspace {
            SyncBanner(status: host.syncStatus, relayRefused: host.relayRefused)
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if model.rootScreen == .signIn {
            Button(EnrollView.title) { enrolling = true }
              .font(LLAFont.small)
              .foregroundStyle(LLA.Color.accent)
              .padding(.bottom, LLA.Space.l)
              .accessibilityIdentifier("signIn.enroll")
          }
        }
        .sheet(isPresented: $enrolling) {
          EnrollView(host: host, incoming: $pairArrival)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in host.enter(RelayLifecycle.Phase(phase)) }
        .onChange(of: model.rootScreen) { _, screen in
          // Signed in by any route: nothing is left to enroll.
          if screen != .signIn { enrolling = false }
        }
        .onOpenURL { url in open(url) }
        .alert(PairLink.alreadyPaired, isPresented: $alreadyPaired) {
          Button("OK", role: .cancel) {}
        }
    }
  }

  private func open(_ url: URL) {
    // A sign-in callback opened from outside a ceremony belongs to none: dropped, never redeemed.
    if model.openURL(url) { return }
    switch host.pairLink(url) {
    case .confirm(let link):
      pairArrival = .offer(link)
      enrolling = true
    case .invalid:
      pairArrival = .invalid(PairArrival.invalidLink)
      enrolling = true
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
