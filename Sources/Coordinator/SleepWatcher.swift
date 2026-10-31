import Foundation
import WorkspacePlatform

/// Detects a Mac sleep from inside the coordinator (D-034): `ContinuousClock` keeps counting while
/// the machine sleeps and `SuspendingClock` does not, so after a wake the two have drifted apart by
/// the time asleep. A gap past the threshold fires `onGap` once, which reconciles every unresolved
/// turn. The app also listens for `NSWorkspace.didWakeNotification`; this covers a CLI-spawned
/// coordinator with no app running.
public actor SleepWatcher {
  private let threshold: Duration
  private let interval: Duration
  private let onGap: @Sendable (Duration) async -> Void
  private var task: Task<Void, Never>?
  private var lastContinuous = ContinuousClock.now
  private var lastSuspending = SuspendingClock.now
  private let logger = Log.logger("sleep")

  public init(
    threshold: Duration = .seconds(20), interval: Duration = .seconds(5),
    onGap: @escaping @Sendable (Duration) async -> Void
  ) {
    self.threshold = threshold
    self.interval = interval
    self.onGap = onGap
  }

  public func start() {
    guard task == nil else { return }
    lastContinuous = .now
    lastSuspending = .now
    task = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: self?.interval ?? .seconds(5), clock: .suspending)
        guard let self, !Task.isCancelled else { return }
        await self.tick(continuous: .now, suspending: .now)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  /// One observation. Returns the detected gap when it exceeded the threshold, nil otherwise.
  @discardableResult
  func tick(continuous: ContinuousClock.Instant, suspending: SuspendingClock.Instant) async -> Duration? {
    let gap = Self.gap(
      continuousElapsed: continuous - lastContinuous, suspendingElapsed: suspending - lastSuspending,
      threshold: threshold)
    lastContinuous = continuous
    lastSuspending = suspending
    if let gap {
      logger.info("wake detected after \(gap.components.seconds, privacy: .public) s; reconciling")
      await onGap(gap)
    }
    return gap
  }

  /// The time the machine spent asleep between two observations, when it is worth reacting to.
  static func gap(continuousElapsed: Duration, suspendingElapsed: Duration, threshold: Duration) -> Duration?
  {
    let asleep = continuousElapsed - suspendingElapsed
    return asleep >= threshold ? asleep : nil
  }
}
