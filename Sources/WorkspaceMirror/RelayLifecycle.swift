import Foundation
import WorkspaceProtocol

/// When the phone holds its hub link (M8c). The decisions only: `MirrorHost` turns them into
/// `MirrorRelay.start()` and `stop()`. What a pairing link may do is `PhoneFlavor.pairLinkDecision`'s
/// and `MirrorAccount.pair`'s (sign-in plan, Task 15).
///
/// - The link is held while this device is enrolled, a relay exists, and the app was last active.
///   Background closes it (the relay keeps its watched set and sends it again on the next start);
///   inactive (the app switcher, a system sheet) leaves it as it is.
/// - A link the hub refused (`unauthorized`, `revoked`) is not opened again until the device logs out
///   and pairs again: every later attempt would be refused too.
public struct RelayLifecycle: Sendable, Equatable {
  /// The scene's phase, without SwiftUI.
  public enum Phase: Sendable, Equatable {
    case active, inactive, background
  }

  public enum Action: Sendable, Equatable {
    case start, stop
  }

  /// The relay stop reasons that mean this device's token is no good.
  public static let refusals: Set<String> = ["unauthorized", "revoked"]

  public private(set) var enrolled: Bool
  /// A relay was built (none for an unreadable mirror).
  public private(set) var hasRelay: Bool
  /// The hub refused this device's link; cleared when enrollment changes.
  public private(set) var refused = false
  /// Whether the last phase change asked for the link (active) or against it (background).
  public private(set) var wantsLink = false
  /// Whether the relay was last told to start.
  public private(set) var running = false

  public init(enrolled: Bool, hasRelay: Bool = true) {
    self.enrolled = enrolled
    self.hasRelay = hasRelay
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

  /// This device enrolled (paired) or left (logged out), with or without a relay; the action to take,
  /// if any. A change of enrollment forgets a refusal.
  public mutating func setEnrolled(_ enrolled: Bool, hasRelay: Bool = true) -> Action? {
    if enrolled != self.enrolled { refused = false }
    self.enrolled = enrolled
    self.hasRelay = hasRelay
    return settle()
  }

  /// The relay stopped on its own with `reason`. It is already stopped, so there is never an action; a
  /// refusal keeps it stopped until the device pairs again, and any other reason but our own `stopped`
  /// lets the next active open it again. `stopped` is ignored: it may be a late report of a stop that a
  /// later start has already overtaken.
  public mutating func linkStopped(reason: String) -> Action? {
    guard reason != "stopped" else { return nil }
    running = false
    if Self.refusals.contains(reason) { refused = true }
    return nil
  }

  private mutating func settle() -> Action? {
    let wanted = enrolled && hasRelay && wantsLink && !refused
    guard wanted != running else { return nil }
    running = wanted
    return wanted ? .start : .stop
  }
}
