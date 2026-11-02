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
/// onboarding while the new account has no name, and the workspace otherwise; while the account has no
/// Mac, "Connect your Mac" takes the thread list's place (Task 15). The phone signs in at its flavour's
/// hub itself, through its host's account. Under the sign-in screen, "Use an enrollment code" opens the
/// sheet for a hub that gives out codes.
///
/// Pairing (D-066): the Mac's QR code is `https://<site>/pair#c=<code>`. The system Camera opens it as
/// a universal link (`onContinueUserActivity`), the in-app scanner reads it, and any other route
/// arrives through `onOpenURL`; all three take one path, `MirrorHost.pairLinkDecision`, then the
/// enrollment sheet's one confirmation. A stray `b4app*://auth` callback is dropped.
@main
struct B4AppiOS: App {
  @State private var host = MirrorHost.shared
  @State private var model = MirrorHost.shared.makeModel()
  /// A pairing link waiting for the enrollment sheet to take it (it holds the code: view state only).
  @State private var pairArrival: PairArrival?
  @State private var enrolling = false
  /// "Scan the code" on Connect your Mac: the scanner, then the enrollment sheet with what it read.
  @State private var scanning = false
  /// A pairing link refused on a signed-in phone, said in an alert rather than the sign-in sheet.
  @State private var refusedLink: String?
  /// An arrival waiting for the sheet or alert in front of the root to go, so it is never lost to a
  /// presentation SwiftUI would not make.
  @State private var pending: PairArrival?
  /// The last link opened, and when: a universal link can reach the app by two routes at once.
  @State private var lastOpened: (url: URL, at: Date)?
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
        .environment(\.connectMacContent) {
          AnyView(ConnectMacView(siteDomain: MirrorHost.flavor.siteDomain) { scanning = true })
        }
        .sheet(isPresented: $enrolling, onDismiss: presentPending) {
          EnrollView(host: host, incoming: $pairArrival)
        }
        .sheet(isPresented: $scanning, onDismiss: presentPending) {
          // What it reads waits for the scanner to go, then takes the way every link takes.
          QRScannerView { text in
            pending = PairArrival(scanned: text, decide: host.pairLinkDecision)
          }
        }
        // The workspace's own sheets, or the alert below: an arrival waits for them to close.
        .onChange(of: workspaceSheetUp || refusedLink != nil) { _, blocked in
          if !blocked { presentPending() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in host.enter(RelayLifecycle.Phase(phase)) }
        .onChange(of: model.rootScreen) { old, screen in
          // Signed in from the sign-in screen by another route: nothing is left to enroll. A sheet
          // opened on a signed-in phone (pairing, a switch) closes itself.
          if old == .signIn, screen != .signIn { enrolling = false }
        }
        .onOpenURL { url in open(url) }
        // The system Camera and a tapped `https://<site>/pair` link arrive as a universal link.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
          if let url = activity.webpageURL { open(url) }
        }
        .alert(
          refusedLink ?? "",
          isPresented: Binding(get: { refusedLink != nil }, set: { if !$0 { refusedLink = nil } })
        ) {
          Button("OK", role: .cancel) {}
        }
    }
  }

  private func open(_ url: URL) {
    // A sign-in callback opened from outside a ceremony belongs to none: dropped, never redeemed.
    if model.openURL(url) { return }
    // The same link again within moments is the same arrival (`onContinueUserActivity` and
    // `onOpenURL` can both deliver one universal link).
    if let last = lastOpened, last.url == url, Date().timeIntervalSince(last.at) < 10 { return }
    lastOpened = (url, Date())
    switch host.pairLinkDecision(url) {
    case .confirm(let link): deliver(.offer(link))
    case .invalid: deliver(.invalid(PairArrival.invalidLink))
    case .ignored: break
    }
  }

  /// A sheet of the workspace's own is up (Settings, New thread, Search).
  private var workspaceSheetUp: Bool {
    model.showSettingsSheet || model.showNewThread || model.showSearch
  }

  /// Into the enrollment sheet if it is up; otherwise now, or once whatever is in front has gone.
  private func deliver(_ arrival: PairArrival) {
    if enrolling {
      pairArrival = arrival
    } else if scanning || workspaceSheetUp || refusedLink != nil {
      pending = arrival
    } else {
      present(arrival)
    }
  }

  private func presentPending() {
    guard let arrival = pending, !enrolling, !scanning, !workspaceSheetUp, refusedLink == nil else { return }
    pending = nil
    present(arrival)
  }

  /// A refused link on a signed-in phone is an alert (the sheet's typed entry is for signing in); the
  /// rest open the enrollment sheet, which confirms.
  private func present(_ arrival: PairArrival) {
    if case .invalid(let message) = arrival, model.rootScreen != .signIn {
      refusedLink = message
    } else {
      pairArrival = arrival
      enrolling = true
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
