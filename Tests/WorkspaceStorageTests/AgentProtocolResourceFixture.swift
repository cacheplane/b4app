import Darwin
import Dispatch
import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

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

  static func database() throws -> WorkspaceDatabase {
    let endpoint = try endpoint()
    return try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
  }
}

/// One concurrent resource per executing test case; actor isolation and runner ownership remain intact.
/// This is an executor preference, not a deadline or a join of unstructured descendants.
final class NativeDBCaseExecutor: TaskExecutor {
  private let queue = DispatchQueue(
    label: "b4app.tests.native-db-case", attributes: .concurrent)

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { [self] in
      job.runSynchronously(on: asUnownedTaskExecutor())
    }
  }
}

struct NativeDBResources: TestTrait, SuiteTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    let executor = NativeDBCaseExecutor()
    defer { withExtendedLifetime(executor) {} }
    try await withTaskExecutorPreference(executor) {
      try await function()
    }
  }
}
