import Foundation
import IOKit.pwr_mgt

/// The system's idle-sleep assertion, behind a seam so tests never touch the real power state.
public protocol PowerAssertions: Sendable {
  /// Takes the assertion that stops the Mac from sleeping when idle, named `name`. False when the system
  /// refused. Never called while one is already held.
  func take(name: String) -> Bool
  /// Gives the assertion back. A no-op when none is held.
  func drop()
}

/// `IOPMAssertionCreateWithName` with `kIOPMAssertPreventUserIdleSystemSleep`: the Mac stays awake, the
/// display can still sleep. The system also drops it when the process exits.
public final class IOKitPowerAssertions: PowerAssertions, @unchecked Sendable {
  private let lock = NSLock()
  private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

  public init() {}

  public func take(name: String) -> Bool {
    lock.withLock {
      guard assertionID == IOPMAssertionID(kIOPMNullAssertionID) else { return true }
      var id = IOPMAssertionID(kIOPMNullAssertionID)
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
        name as CFString, &id)
      guard result == kIOReturnSuccess else { return false }
      assertionID = id
      return true
    }
  }

  public func drop() {
    lock.withLock {
      guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else { return }
      IOPMAssertionRelease(assertionID)
      assertionID = IOPMAssertionID(kIOPMNullAssertionID)
    }
  }
}

/// A `PowerAssertions` that only counts, for tests.
public final class FakePowerAssertions: PowerAssertions, @unchecked Sendable {
  private let lock = NSLock()
  private var state = (held: false, refuse: false, takes: 0, drops: 0, names: [String]())

  public init() {}

  /// While set, every `take` fails, as when the system refuses.
  public var refuse: Bool {
    get { lock.withLock { state.refuse } }
    set { lock.withLock { state.refuse = newValue } }
  }
  public var isHeld: Bool { lock.withLock { state.held } }
  /// How many assertions were taken, and how many given back.
  public var takes: Int { lock.withLock { state.takes } }
  public var drops: Int { lock.withLock { state.drops } }
  /// The name of each assertion taken.
  public var names: [String] { lock.withLock { state.names } }

  public func take(name: String) -> Bool {
    lock.withLock {
      guard !state.refuse else { return false }
      state.held = true
      state.takes += 1
      state.names.append(name)
      return true
    }
  }

  public func drop() {
    lock.withLock {
      guard state.held else { return }
      state.held = false
      state.drops += 1
    }
  }
}

/// "Keep the Mac awake" (M8c): the assertion is held exactly while the preference is on and this Mac is
/// joined to a hub, so the phone can reach it. The preference itself lives in the `settings` table; this
/// type only acts on it, and is told the facts by `HubSync`.
public final class KeepAwake: @unchecked Sendable {
  /// What the system's power tools (`pmset -g assertions`) show for this assertion.
  public static let reason = "Agent Workspace keeps this Mac reachable from your phone"

  private let assertions: any PowerAssertions
  private let lock = NSLock()
  private var held = false

  public init(assertions: any PowerAssertions) {
    self.assertions = assertions
  }

  public var isHeld: Bool { lock.withLock { held } }

  /// Brings the assertion in line: held when `enabled` and `joined`, otherwise released. Applying the
  /// state it is already in does nothing; a refused assertion is tried again by the next apply.
  public func apply(enabled: Bool, joined: Bool) {
    lock.withLock {
      if enabled && joined {
        if !held { held = assertions.take(name: Self.reason) }
      } else if held {
        assertions.drop()
        held = false
      }
    }
  }

  /// Gives the assertion back, whatever the preference says (the coordinator is exiting).
  public func release() {
    lock.withLock {
      guard held else { return }
      assertions.drop()
      held = false
    }
  }
}
