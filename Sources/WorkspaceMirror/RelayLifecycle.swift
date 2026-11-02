import Foundation
import WorkspaceProtocol

/// When the phone holds its hub link, and what a `b4app://pair` link may do (M8c). The decisions only:
/// `MirrorHost` turns them into `MirrorRelay.start()` and `stop()` and into what the Connect screen shows.
///
/// - The link is held while this device is enrolled and the app was last active. Background closes it
///   (the relay keeps its watched set and sends it again on the next start); inactive (the app switcher,
///   a system sheet) leaves it as it is.
/// - A pairing link is only ever offered for confirmation, and only while not enrolled; enrolled, it is
///   answered "already paired" whatever it holds. No decision here enrolls or sends a request.
public struct RelayLifecycle: Sendable, Equatable {
  /// The scene's phase, without SwiftUI.
  public enum Phase: Sendable, Equatable {
    case active, inactive, background
  }

  public enum Action: Sendable, Equatable {
    case start, stop
  }

  public enum PairLinkDecision: Sendable, Equatable {
    /// Fill the Connect screen and ask "Pair this iPhone with the hub at <host>?".
    case confirm(PairLink)
    /// "This iPhone is already paired"; nothing else happens.
    case alreadyPaired
    /// A pairing link this phone refuses (no code, a bad code, an insecure remote hub, …).
    case invalid
    /// Not a pairing link.
    case ignored
  }

  public private(set) var enrolled: Bool
  /// Whether the last phase change asked for the link (active) or against it (background).
  public private(set) var wantsLink = false
  /// Whether the relay was last told to start.
  public private(set) var running = false

  public init(enrolled: Bool) {
    self.enrolled = enrolled
  }

  /// The scene moved to `phase`; the action to take, if any.
  public mutating func enter(_ phase: Phase) -> Action? {
    switch phase {
    case .active: wantsLink = true
    case .background: wantsLink = false
    case .inactive: break
    }
    return settle()
  }

  /// This device enrolled (paired) or left (logged out); the action to take, if any.
  public mutating func setEnrolled(_ enrolled: Bool) -> Action? {
    self.enrolled = enrolled
    return settle()
  }

  /// What a `b4app://` link opened on this phone may do.
  public func pairLink(_ url: URL) -> PairLinkDecision {
    guard PairLink.isPairLink(url) else { return .ignored }
    if enrolled { return .alreadyPaired }
    return PairLink.parse(url).map(PairLinkDecision.confirm) ?? .invalid
  }

  private mutating func settle() -> Action? {
    let wanted = enrolled && wantsLink
    guard wanted != running else { return nil }
    running = wanted
    return wanted ? .start : .stop
  }
}
