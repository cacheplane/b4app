import Foundation

/// Serializes host background wakes, including a new wake arriving during reconciliation or parking.
/// A late arrival requires another full operation; sharing an older result would miss its changes.
/// All callers share the first wake's overall deadline rather than extending iOS's execution budget.
@MainActor public final class MirrorRefreshCoordinator {
  var generation = 0
  private var active: Task<Bool, Never>?
  private let now: @Sendable () -> ContinuousClock.Instant

  public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
    self.now = now
  }

  /// `operation` must respect its remaining budget and finish all cleanup before returning. A new
  /// wake during that cleanup repeats the operation if time remains, or reports failure to all callers.
  public func perform(
    waitingAtMost limit: Duration,
    operation: @escaping @MainActor @Sendable (Duration) async -> Bool
  ) async -> Bool {
    guard limit > .zero else { return false }
    generation += 1
    if let active { return await active.value }
    let deadline = now() + limit
    let task = Task {
      // Clear inside the task, atomically with the final generation check: a later caller must not
      // join an already-completed task while its first caller has not yet resumed from the await.
      defer { active = nil }
      while true {
        let through = generation
        let remaining = now().duration(to: deadline)
        guard remaining > .zero else { return false }
        let result = await operation(remaining)
        if generation == through { return result }
      }
    }
    active = task
    return await task.value
  }
}
