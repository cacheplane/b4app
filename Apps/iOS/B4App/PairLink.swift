import SwiftUI
import WorkspaceMirror
import WorkspaceProtocol

/// A pairing link that reached the app, from the system Camera or a universal link, `.onOpenURL`, or
/// the in-app scanner. It holds the code, so it lives in view state only and is dropped once the
/// enrollment request returns.
enum PairArrival: Equatable {
  /// A link this phone may pair with, once Brian confirms.
  case offer(PairLink)
  /// A pairing link (or a scanned code) this phone refuses; nothing is filled in and nothing is sent.
  case invalid(String)

  static let invalidLink = "This pairing link is not valid. Show a new code on your Mac and try again."
  static let notAPairingCode = "That QR code is not a pairing code from your Mac."
  static let ignoredWhileOffering =
    "Another pairing link arrived and was ignored. Cancel, then open it again to use it."

  /// What a scanned QR code offers.
  init(scanned text: String, decide: (URL) -> PairLinkDecision) {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      self = .invalid(Self.notAPairingCode)
      return
    }
    switch decide(url) {
    case .confirm(let link): self = .offer(link)
    case .invalid: self = .invalid(Self.invalidLink)
    case .ignored: self = .invalid(Self.notAPairingCode)
    }
  }
}

extension PairLink {
  /// The one confirmation every pairing asks for.
  var prompt: String { "Pair this iPhone with the hub at \(host)?" }
}

extension RelayLifecycle.Phase {
  init(_ phase: ScenePhase) {
    switch phase {
    case .active: self = .active
    case .background: self = .background
    case .inactive: self = .inactive
    @unknown default: self = .inactive
    }
  }
}
