import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Task-local test helpers shared by the two test targets through identical thin delegates.
/// EphemeralPostgres owns the opt-in resource registration and acknowledgment.
enum AgentProtocolResourceFixture {
  static var temporaryDirectory: String {
    let env = ProcessInfo.processInfo.environment
    if env["B4APP_A3_NONCE"] != nil, let root = env["B4APP_A3_PRIVATE_ROOT"] {
      return (root as NSString).appendingPathComponent("tmp") + "/"
    }
    // Ordinary CI may spell TMPDIR through /var; create fixtures under its physical base.
    // Adversarial paths supplied by individual tests are deliberately not normalized here.
    return URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/"
  }

  /// Select only a trusted existing fixture base before adding any generated leaf. Never pass
  /// an adversarial publication target here: those raw paths must reach the no-follow publisher.
  static func physicalExistingDirectory(_ base: String) throws -> String {
    guard base.hasPrefix("/"), !base.utf8.contains(0),
      let buffer = base.withCString({ realpath($0, nil) })
    else { throw FixturePathFailure.unavailable }
    defer { free(buffer) }
    guard let resolved = String(validatingCString: buffer) else { throw FixturePathFailure.unavailable }
    var info = stat()
    guard lstat(resolved, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw FixturePathFailure.unavailable
    }
    return resolved
  }

  static func physicalTemporaryDirectory() throws -> String {
    let base = try physicalExistingDirectory(temporaryDirectory)
    return base + (base.hasSuffix("/") ? "" : "/")
  }

  private enum FixturePathFailure: Error { case unavailable }

  // The shared ephemeral test utility owns the same opt-in guard/registration/ACK for all callers.
  static func endpoint() throws -> PostgresEndpoint { try EphemeralPostgres.endpoint() }

  static func currentSchemaEndpoint() throws -> PostgresEndpoint {
    let environment = ProcessInfo.processInfo.environment
    if environment["B4APP_PROTOCOL_FULL_MATRIX"] == "1" || environment["B4APP_A3_NONCE"] != nil {
      return try endpoint()
    }
    return try EphemeralPostgres.endpoint(migrated: true)
  }

  static func database() throws -> WorkspaceDatabase {
    let endpoint = try endpoint()
    return try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
  }
}

/// Closed primitive observation of this preference queue only, not a thread or operation identity.
enum NativeDBCaseQueueWait: Equatable, Sendable {
  case none, overflow
  case value(Int64)

  static func classify(_ elapsed: Duration?) -> Self {
    guard let elapsed else { return .none }
    let components = elapsed.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return .none }
    let (whole, multiplyOverflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000)
    guard !multiplyOverflow else { return .overflow }
    let fraction = components.attoseconds / 1_000_000_000_000
    let (microseconds, addOverflow) = whole.addingReportingOverflow(fraction)
    guard !addOverflow else { return .overflow }
    return .value(microseconds)
  }

  static func maximum(_ lhs: Self, _ rhs: Self) -> Self {
    switch (lhs, rhs) {
    case (.overflow, _), (_, .overflow): return .overflow
    case (.value(let a), .value(let b)): return .value(max(a, b))
    case (.none, _): return rhs
    case (_, .none): return lhs
    }
  }

  var fieldValue: String {
    switch self {
    case .none: return "none"
    case .overflow: return "overflow"
    case .value(let microseconds): return String(microseconds)
    }
  }
}

struct NativeDBCaseQueueSnapshot: Sendable {
  enum Availability: String, Sendable { case unavailable, available }
  let availability: Availability
  let enqueueCount: UInt32
  let enqueueOverflow: Bool
  let firstWait: NativeDBCaseQueueWait
  let maxWait: NativeDBCaseQueueWait

  static let unavailable = Self(
    availability: .unavailable, enqueueCount: 0, enqueueOverflow: false,
    firstWait: .none, maxWait: .none)

  var enqueueCountField: String {
    availability == .available ? String(enqueueCount) : "none"
  }

  var enqueueOverflowField: String {
    availability == .available ? String(enqueueOverflow) : "none"
  }
}

enum NativeDBCaseExecutorScope {
  @TaskLocal static var current: NativeDBCaseExecutor? = nil
}

/// A concurrent queue for a native test scope; actor isolation and runner ownership remain intact.
/// This is an executor preference, not a deadline or a join of unstructured descendants.
final class NativeDBCaseExecutor: TaskExecutor {
  private struct QueueState: Sendable {
    var enqueueCount: UInt32 = 0
    var enqueueOverflow = false
    var observedEntry = false
    var firstWait: NativeDBCaseQueueWait = .none
    var maxWait: NativeDBCaseQueueWait = .none
  }

  private let stats = Mutex(QueueState())
  private let queue = DispatchQueue(
    label: "b4app.tests.native-db-case", attributes: .concurrent)

  func snapshot() -> NativeDBCaseQueueSnapshot {
    stats.withLock {
      NativeDBCaseQueueSnapshot(
        availability: .available, enqueueCount: $0.enqueueCount,
        enqueueOverflow: $0.enqueueOverflow, firstWait: $0.firstWait, maxWait: $0.maxWait)
    }
  }

  func enqueue(_ job: consuming ExecutorJob) {
    stats.withLock {
      if $0.enqueueCount == UInt32.max {
        $0.enqueueOverflow = true
      } else {
        $0.enqueueCount += 1
      }
    }
    let job = UnownedJob(job)
    let enqueuedAt = ContinuousClock.now
    queue.async { [self] in
      let wait = NativeDBCaseQueueWait.classify(enqueuedAt.duration(to: ContinuousClock.now))
      stats.withLock {
        if !$0.observedEntry {
          $0.observedEntry = true
          $0.firstWait = wait
        }
        $0.maxWait = NativeDBCaseQueueWait.maximum($0.maxWait, wait)
      }
      // The statistics lock is released before the original job runs; no native work is enclosed.
      job.runSynchronously(on: asUnownedTaskExecutor())
    }
  }
}

/// The two large storage suites each run one everyday case at a time. Their blocking database
/// calls share a suite executor, while concurrent work within each case can still make progress.
struct OrdinaryProtocolStorageSuite: SuiteTrait, TestScoping {
  static var scheduling: any SuiteTrait {
    if ProcessInfo.processInfo.environment["B4APP_PROTOCOL_FULL_MATRIX"] == "1" {
      return ConditionTrait.enabled(if: true)
    }
    return ParallelizationTrait.serialized
  }

  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    guard test.isSuite, testCase == nil,
      ProcessInfo.processInfo.environment["B4APP_PROTOCOL_FULL_MATRIX"] != "1"
    else { return nil }
    return self
  }

  func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    let executor = NativeDBCaseExecutor()
    try await withTaskExecutorPreference(executor) { try await function() }
  }
}

struct NativeDBResources: TestTrait, SuiteTrait, TestScoping {
  var runBlockingCaseInOrdinarySuite = false
  var isRecursive: Bool { true }

  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    guard testCase != nil else { return nil }
    let fullMatrix = ProcessInfo.processInfo.environment["B4APP_PROTOCOL_FULL_MATRIX"] == "1"
    return runBlockingCaseInOrdinarySuite || fullMatrix ? self : nil
  }

  func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    let executor = NativeDBCaseExecutor()
    defer { withExtendedLifetime(executor) {} }
    try await withTaskExecutorPreference(executor) {
      try await NativeDBCaseExecutorScope.$current.withValue(executor) {
        try await function()
      }
    }
  }
}

/// Primitive-only observation of the application backend rows after the original close defers.
/// A three-second acceptance window permits short server-side retention; it does not bound PQexec
/// return time or prove ARC, PQfinish, or native thread/process exit.
struct ApplicationBackendObservation: Sendable {
  enum Outcome: String { case emptyBeforeDeadline, nonemptyAtDeadline, lateEmpty, sampleLimit, queryError }
  enum ErrorCategory: String { case none, postgresError, otherError }
  enum SQLState: String {
    case none, unlisted
    case code08003 = "08003"
    case code08006 = "08006"
    case code22023 = "22023"
    case code22P02 = "22P02"
    case code23502 = "23502"
    case code23503 = "23503"
    case code23505 = "23505"
    case code23514 = "23514"
    case code25P02 = "25P02"
    case code40001 = "40001"
    case code40P01 = "40P01"
    case code53100 = "53100"
    case code53200 = "53200"
    case code53300 = "53300"
    case code53400 = "53400"
    case code55P03 = "55P03"
    case code57014 = "57014"
    case code57P01 = "57P01"
    case code58030 = "58030"
    case code58P01 = "58P01"
    case codeP0001 = "P0001"

    static func classify(_ code: String) -> Self {
      guard let state = Self(rawValue: code), state != .none else { return .unlisted }
      return state
    }
  }

  var firstRowCount: Int?
  var firstCompletionElapsed: Duration?
  var lastRowCount: Int?
  var samples = 0
  var outcome: Outcome = .sampleLimit
  var totalElapsed: Duration = .zero
  var errorCategory: ErrorCategory = .none
  var sqlState: SQLState = .none

  var accepted: Bool { outcome == .emptyBeforeDeadline }

  var diagnostic: String {
    let first = firstRowCount.map(String.init) ?? "none"
    let last = lastRowCount.map(String.init) ?? "none"
    let firstElapsed = firstCompletionElapsed.map { String(describing: $0) } ?? "none"
    return """
      firstRowCount=\(first) firstCompletionElapsed=\(firstElapsed) lastRowCount=\(last) \
      samples=\(samples) outcome=\(outcome.rawValue) totalElapsed=\(totalElapsed) \
      category=\(errorCategory.rawValue) sqlstate=\(sqlState.rawValue) boundedObservationSeconds=3
      """
  }

  /// Query errors fail immediately. Even the first empty sample must COMPLETE before the deadline.
  static func observe(_ query: () throws -> Int) -> Self {
    var observation = Self()
    let clock = ContinuousClock()
    let started = clock.now
    let deadline = started + .seconds(3)
    while observation.samples < 301 {
      observation.samples += 1
      do {
        let count = try query()
        let completed = clock.now
        let elapsed = started.duration(to: completed)
        if observation.samples == 1 {
          observation.firstRowCount = count
          observation.firstCompletionElapsed = elapsed
        }
        observation.lastRowCount = count
        if completed >= deadline {
          observation.outcome = count == 0 ? .lateEmpty : .nonemptyAtDeadline
          break
        }
        if count == 0 {
          observation.outcome = .emptyBeforeDeadline
          break
        }
      } catch {
        // P3: an error is still a completed first observation; it has no row count.
        if observation.samples == 1 {
          observation.firstCompletionElapsed = started.duration(to: clock.now)
        }
        observation.errorCategory = error is PostgresError ? .postgresError : .otherError
        if let error = error as? PostgresError {
          observation.sqlState = SQLState.classify(error.sqlState)
        }
        observation.outcome = .queryError
        break
      }
      if observation.samples == 301 { break }
      Thread.sleep(forTimeInterval: 0.01)
      if clock.now >= deadline {
        observation.outcome = .nonemptyAtDeadline
        break
      }
    }
    observation.totalElapsed = started.duration(to: clock.now)
    return observation
  }
}
