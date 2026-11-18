import Foundation

/// The clock of a paced reveal: while started it calls `onTick` once per frame. Injected so a test
/// drives the reveal by hand.
@MainActor protocol RevealTicker: AnyObject {
  var onTick: (@MainActor () -> Void)? { get set }
  /// Idempotent.
  func start()
  /// Idempotent.
  func stop()
}

/// Sixty ticks a second on the main actor while started. The loop holds the ticker weakly, so a
/// ticker nothing else holds ends its loop, and `stop()` ends it at once.
@MainActor final class DisplayTicker: RevealTicker {
  var onTick: (@MainActor () -> Void)?
  private var task: Task<Void, Never>?
  /// Names the live loop: a loop that is not the current generation ends without ticking.
  private var generation = 0

  func start() {
    guard task == nil else { return }
    generation += 1
    let mine = generation
    task = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1.0 / 60.0)) } catch { return }
        guard !Task.isCancelled, let self, self.generation == mine, self.task != nil else { return }
        self.onTick?()
      }
    }
  }

  func stop() {
    task?.cancel()
    task = nil
  }
}

/// A ticker a test fires by hand.
@MainActor final class ManualTicker: RevealTicker {
  var onTick: (@MainActor () -> Void)?
  private(set) var running = false

  func start() { running = true }
  func stop() { running = false }

  /// Calls `onTick` `count` times, or until the ticker stops.
  func fire(_ count: Int = 1) {
    for _ in 0..<count {
      guard running else { return }
      onTick?()
    }
  }
}
