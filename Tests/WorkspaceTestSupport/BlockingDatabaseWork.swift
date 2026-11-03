import Dispatch
import Testing

/// The synchronous libpq API can block in socket reads. Let those tests block dispatch workers,
/// rather than occupying Swift's cooperative workers needed by socket shutdown and logout timers.
/// Existing parallel/serialized traits remain in force; there is no case-count limit. Actor
/// isolation still takes precedence over this execution preference.
public struct BlockingDatabaseWork: SuiteTrait, TestTrait, TestScoping {
  public init() {}

  public var isRecursive: Bool { true }

  @concurrent
  public func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    try await withTaskExecutorPreference(DatabaseTestExecutor.shared) {
      try await executeDatabaseTest(function)
    }
  }
}

private final class DatabaseTestExecutor: TaskExecutor {
  static let shared = DatabaseTestExecutor()
  let queue = DispatchQueue(label: "b4app.tests.blocking-database", attributes: .concurrent)

  func enqueue(_ job: UnownedJob) {
    queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
  }
}

@concurrent
private func executeDatabaseTest(_ function: @concurrent @Sendable () async throws -> Void) async throws {
  // Fail rather than silently losing the execution boundary after a toolchain change.
  dispatchPrecondition(condition: .onQueue(DatabaseTestExecutor.shared.queue))
  try await function()
}
