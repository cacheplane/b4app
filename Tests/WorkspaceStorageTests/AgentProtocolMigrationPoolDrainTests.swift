import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

private enum MigrationPoolWorkFailure: Error { case missingResult }

/// The caller may block observing a lease/drain boundary, so the original blocking operation runs
/// on its own retained Thread (RemoteApplyTests documents the three-core cooperative-pool cycle).
/// This is only a test work/result handle: it never cancels or abandons the actual operation.
private final class MigrationPoolWork<Value: Sendable> {
  private final class State: Sendable {
    let result = Mutex<Result<Value, any Error>?>(nil)
    let completed = DispatchSemaphore(value: 0)
  }
  private let state: State
  private let thread: Thread

  init(_ operation: @escaping @Sendable () throws -> Value) {
    let state = State()
    self.state = state
    thread = Thread {
      let result = Result { try operation() }
      state.result.withLock { $0 = result }
      state.completed.signal()
    }
    thread.start()
  }

  func join() -> Result<Value, any Error> {
    state.completed.wait()
    return state.result.withLock { $0 } ?? .failure(MigrationPoolWorkFailure.missingResult)
  }

  func value() throws -> Value { try join().get() }
}

private final class MigrationPoolObservation: Sendable {
  let borrowerEntered = Mutex(false)
  let borrowerHeld = Mutex(false)
  let waiterEntered = Mutex(false)
  let waiterTimedOut = Mutex(false)
  let drainStarted = Mutex(false)
  let drainFinished = Mutex(false)
  let succeededWhileBorrowerHeld = Mutex(false)
  let bodyCalls = Mutex(0)
}

@Suite(.serialized) struct AgentProtocolMigrationPoolDrainTests {
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let inspector: PostgresConnection
    let pool: ConnectionPool
    let applicationName: String
    let backupDirectory: String
  }

  private enum FixtureFailure: Error, Equatable { case barrierTimeout, expectedBodyFailure }

  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static func fixture(pending: Bool = false) throws -> Fixture {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir =
      try AgentProtocolResourceFixture.physicalExistingDirectory(
        (endpoint.logPath as NSString).deletingLastPathComponent) + "/data"
    let inspector = try connection(endpoint)
    if pending {
      try Migrator.ensureLedger(inspector, table: Migrator.table)
      for file in try Migrator.files() where file.name <= "0008_thread_delete" {
        try inspector.execute(file.sql)
        try inspector.execute(
          #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#, [file.name])
      }
      try inspector.execute(
        """
        INSERT INTO "connections" ("id", "kind", "label", "target", "authReference", "nativeScope",
          "capabilities", "status", "authStatus", "createdAt", "updatedAt") VALUES
          ('old-b4', 'b4', 'Retained', 'https://example.invalid/base', 'secret:old-ref', 'old-scope',
          '{}', 'ready', 'authenticated', 'created', 'updated');
        INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "nativeScope", "readTurnId",
          "createdAt", "updatedAt") VALUES
          ('old-thread', 'old-b4', 'native-old', 'old-scope', 'old-turn', 'created', 'updated');
        INSERT INTO "turns" ("id", "threadId", "operationId", "status", "submission", "outcome",
          "createdAt", "updatedAt") VALUES
          ('old-turn', 'old-thread', 'old-operation', 'reconciling', 'unknown', NULL, 'created', 'updated');
        INSERT INTO "runtimeRequests" ("id", "nativeRequestId", "threadId", "turnId", "adapterGeneration",
          "kind", "state", "payload", "createdAt", "updatedAt") VALUES
          ('old-request', '1', 'old-thread', 'old-turn', 1, 'command_approval', 'pending',
          '{"opaque":[true,null]}', 'created', 'updated');
        """)
    }
    let application = "b4a3_pool_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let pool = try ConnectionPool(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database) application_name=\(application)",
      size: 1)
    let backup = (endpoint.dataDir! as NSString).deletingLastPathComponent + "/backups/" + endpoint.database
    return Fixture(
      endpoint: endpoint, inspector: inspector, pool: pool, applicationName: application,
      backupDirectory: backup)
  }

  private static func observed(
    within budget: Duration = .seconds(2), _ signal: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + budget
    while !signal(), ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
    }
    return signal()
  }

  private static func namedBackendAbsent(_ fixture: Fixture) -> Bool {
    (try? fixture.inspector.execute(
      "SELECT 1 FROM pg_stat_activity WHERE datname = $1 AND application_name = $2",
      [fixture.endpoint.database, fixture.applicationName]
    ).rows.isEmpty) == true
  }

  private static func snapshot(_ c: PostgresConnection) throws -> [String] {
    var facts: [String] = []
    for table in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY 1"
    ).rows.compactMap({ $0.text("tablename") }) {
      facts += try c.execute(
        "SELECT 'row:' || $1 || ':' || to_jsonb(t)::text AS fact FROM \(Rows.quote(table)) t",
        [table]
      ).rows.compactMap { $0.text("fact") }
    }
    facts += try c.execute(
      """
      SELECT 'column:' || table_name || ':' || column_name || ':' || data_type || ':' || is_nullable
        || ':' || coalesce(column_default, '') AS fact FROM information_schema.columns
        WHERE table_schema = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    facts += try c.execute(
      """
      SELECT 'constraint:' || r.relname || ':' || c.conname || ':' || pg_get_constraintdef(c.oid) AS fact
        FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    return facts.sorted()
  }

  private static func isClosedRefusal<T>(_ result: Result<T, any Error>) -> Bool {
    if case .failure(let error as WorkspaceError) = result { return error.code == .endpointUnavailable }
    return false
  }

  @Test func migrationDrainWaitsForActiveLeaseAndRefusesLaterWork() async throws {
    let fixture = try Self.fixture()
    defer { fixture.pool.close() }
    let observation = MigrationPoolObservation()
    let releaseBorrower = DispatchSemaphore(value: 0)
    let releaseWaiter = DispatchSemaphore(value: 0)
    let borrower = MigrationPoolWork {
      try fixture.pool.withConnection { _ in
        observation.borrowerHeld.withLock { $0 = true }
        observation.borrowerEntered.withLock { $0 = true }
        defer { observation.borrowerHeld.withLock { $0 = false } }
        guard releaseBorrower.wait(timeout: .now() + .seconds(8)) == .success else {
          throw FixtureFailure.barrierTimeout
        }
      }
    }
    let borrowerReady = await Self.observed { observation.borrowerEntered.withLock { $0 } }
    let waiter = MigrationPoolWork {
      Result {
        try fixture.pool.withConnection(
          beforeWaiting: {
            observation.waiterEntered.withLock { $0 = true }
            if releaseWaiter.wait(timeout: .now() + .seconds(8)) != .success {
              observation.waiterTimedOut.withLock { $0 = true }
            }
          }
        ) { _ in observation.bodyCalls.withLock { $0 += 1 } }
      }
    }
    let waiterReady = await Self.observed { observation.waiterEntered.withLock { $0 } }
    // Admission is now deterministically closed before probing new work or starting the drain.
    // Draining an already-closed pool is needed after an account scope's ordinary pool close.
    fixture.pool.close()
    let newAttempt = Result {
      try fixture.pool.withConnection { _ in observation.bodyCalls.withLock { $0 += 1 } }
    }
    let drainer = MigrationPoolWork {
      observation.drainStarted.withLock { $0 = true }
      let drained = fixture.pool.closeForMigration(timeout: .seconds(2))
      observation.succeededWhileBorrowerHeld.withLock {
        $0 = drained && observation.borrowerHeld.withLock { $0 }
      }
      observation.drainFinished.withLock { $0 = true }
      return drained
    }
    let drainStarted = await Self.observed { observation.drainStarted.withLock { $0 } }
    // This is a bounded absence observation after explicit entry barriers, not an assumed ordering
    // based on a sleep. A successful drain cannot finish while the admitted borrower remains held.
    let finishedBeforeRelease = await Self.observed(within: .milliseconds(75)) {
      observation.drainFinished.withLock { $0 }
    }
    releaseBorrower.signal()
    releaseWaiter.signal()
    let borrowed = borrower.join()
    let queued = try waiter.value()
    let drained = try drainer.value()
    _ = try borrowed.get()
    #expect(borrowerReady && waiterReady && drainStarted)
    #expect(!finishedBeforeRelease)
    #expect(!observation.succeededWhileBorrowerHeld.withLock { $0 })
    #expect(drained)
    #expect(Self.isClosedRefusal(newAttempt))
    #expect(Self.isClosedRefusal(queued))
    #expect(observation.bodyCalls.withLock { $0 } == 0)
    #expect(!observation.waiterTimedOut.withLock { $0 })
    let absent = await Self.observed { Self.namedBackendAbsent(fixture) }
    #expect(absent)
  }

  @Test func migrationDrainTimeoutPreventsCaptureAndDDL() async throws {
    let fixture = try Self.fixture(pending: true)
    defer {
      fixture.pool.close()
      try? FileManager.default.removeItem(atPath: fixture.backupDirectory)
    }
    let before = try Self.snapshot(fixture.inspector)
    let observation = MigrationPoolObservation()
    let release = DispatchSemaphore(value: 0)
    let stageCalls = Mutex(0)
    let borrower = MigrationPoolWork {
      try fixture.pool.withConnection { _ in
        observation.borrowerEntered.withLock { $0 = true }
        guard release.wait(timeout: .now() + .seconds(8)) == .success else {
          throw FixtureFailure.barrierTimeout
        }
      }
    }
    let entered = await Self.observed { observation.borrowerEntered.withLock { $0 } }
    let guardCaller = MigrationPoolWork {
      let start = ContinuousClock.now
      let drained = fixture.pool.closeForMigration(timeout: .milliseconds(100))
      let elapsed = start.duration(to: .now)
      // Test-owned caller exercises the real storage bridge only if the bounded drain succeeds.
      if drained {
        let c = try Self.connection(fixture.endpoint)
        try WorkspaceDatabase.migrateWithBackup(
          c, endpoint: fixture.endpoint, backupDirectory: fixture.backupDirectory
        ) { _ in stageCalls.withLock { $0 += 1 } }
      }
      return (drained, elapsed)
    }
    let guarded = guardCaller.join()
    let after = Result { try Self.snapshot(fixture.inspector) }
    let backupExists = FileManager.default.fileExists(atPath: fixture.backupDirectory)
    release.signal()
    let borrowed = borrower.join()
    _ = try borrowed.get()
    let (drained, elapsed) = try guarded.get()
    #expect(entered)
    #expect(!drained)
    #expect(elapsed < .seconds(1))
    #expect(stageCalls.withLock { $0 } == 0)
    #expect(!backupExists)
    #expect(try after.get() == before)
    let absent = await Self.observed { Self.namedBackendAbsent(fixture) }
    #expect(absent)
  }

  @Test func preAdmissionWaiterDoesNotRunOrLeakMigrationLease() async throws {
    let fixture = try Self.fixture()
    defer { fixture.pool.close() }
    let observation = MigrationPoolObservation()
    let release = DispatchSemaphore(value: 0)
    let waiter = MigrationPoolWork {
      Result {
        try fixture.pool.withConnection(
          beforeWaiting: {
            observation.waiterEntered.withLock { $0 = true }
            if release.wait(timeout: .now() + .seconds(8)) != .success {
              observation.waiterTimedOut.withLock { $0 = true }
            }
          }
        ) { _ in observation.bodyCalls.withLock { $0 += 1 } }
      }
    }
    let ready = await Self.observed { observation.waiterEntered.withLock { $0 } }
    let drainer = MigrationPoolWork { fixture.pool.closeForMigration(timeout: .milliseconds(100)) }
    let drained = try drainer.value()
    release.signal()
    let attempted = try waiter.value()
    #expect(ready)
    #expect(drained)
    #expect(Self.isClosedRefusal(attempted))
    #expect(observation.bodyCalls.withLock { $0 } == 0)
    #expect(!observation.waiterTimedOut.withLock { $0 })
    #expect(fixture.pool.closeForMigration(timeout: .zero))
    let absent = await Self.observed { Self.namedBackendAbsent(fixture) }
    #expect(absent)
  }

  @Test func ordinaryPoolCloseRemainsNonwaitingWithActiveLease() async throws {
    let fixture = try Self.fixture()
    defer { fixture.pool.close() }
    let observation = MigrationPoolObservation()
    let release = DispatchSemaphore(value: 0)
    let borrower = MigrationPoolWork {
      try fixture.pool.withConnection { _ in
        observation.borrowerHeld.withLock { $0 = true }
        observation.borrowerEntered.withLock { $0 = true }
        defer { observation.borrowerHeld.withLock { $0 = false } }
        guard release.wait(timeout: .now() + .seconds(8)) == .success else {
          throw FixtureFailure.barrierTimeout
        }
      }
    }
    let entered = await Self.observed { observation.borrowerEntered.withLock { $0 } }
    let closer = MigrationPoolWork {
      fixture.pool.close()
      observation.drainFinished.withLock { $0 = true }
    }
    let finished = await Self.observed { observation.drainFinished.withLock { $0 } }
    let finishedWhileHeld = finished && observation.borrowerHeld.withLock { $0 }
    var refused = false
    if finished {
      refused = Self.isClosedRefusal(
        Result {
          try fixture.pool.withConnection { _ in observation.bodyCalls.withLock { $0 += 1 } }
        })
    }
    release.signal()
    let result = borrower.join()
    try closer.value()
    _ = try result.get()
    #expect(entered)
    #expect(finishedWhileHeld)
    #expect(refused)
    #expect(observation.bodyCalls.withLock { $0 } == 0)
    let absent = await Self.observed { Self.namedBackendAbsent(fixture) }
    #expect(absent)
  }

  @Test func throwingBodyAndLazyConnectionFailureDoNotLeakMigrationAdmission() async throws {
    let fixture = try Self.fixture()
    defer { fixture.pool.close() }
    let bodyResult: Result<Void, any Error> = Result {
      try fixture.pool.withConnection { _ -> Void in throw FixtureFailure.expectedBodyFailure }
    }
    if case .failure(let error as FixtureFailure) = bodyResult {
      #expect(error == .expectedBodyFailure)
    } else {
      Issue.record("The fixture body did not throw its expected error.")
    }
    #expect(fixture.pool.closeForMigration(timeout: .zero))
    let initialAbsent = await Self.observed { Self.namedBackendAbsent(fixture) }
    #expect(initialAbsent)

    // The role exists ONLY on this source-registered private test cluster. A nonsuperuser's one
    // allowed connection is held by the first lease, forcing lazy creation for slot2 to fail.
    let role = "b4a3_role_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try fixture.inspector.execute("CREATE ROLE \(Rows.quote(role)) LOGIN NOSUPERUSER CONNECTION LIMIT 1")
    var roleRemoved = false
    defer {
      if !roleRemoved { _ = try? fixture.inspector.execute("DROP ROLE \(Rows.quote(role))") }
    }
    let roleFacts = try #require(
      try fixture.inspector.execute(
        "SELECT rolconnlimit, rolsuper FROM pg_roles WHERE rolname = $1", [role]
      ).rows.first)
    #expect(roleFacts.int("rolconnlimit") == 1)
    #expect(roleFacts.text("rolsuper") == "f")
    let application = fixture.applicationName + "_limited"
    let limited = try ConnectionPool(
      lib: LibPQ.load(binDir: fixture.endpoint.binDir!),
      connectionString:
        "host=\(fixture.endpoint.socketDir) port=\(fixture.endpoint.port) user=\(role) dbname=\(fixture.endpoint.database) application_name=\(application)",
      size: 2)
    defer { limited.close() }
    let release = DispatchSemaphore(value: 0)
    let observation = MigrationPoolObservation()
    let borrower = MigrationPoolWork {
      try limited.withConnection { _ in
        observation.borrowerEntered.withLock { $0 = true }
        guard release.wait(timeout: .now() + .seconds(8)) == .success else {
          throw FixtureFailure.barrierTimeout
        }
      }
    }
    let entered = await Self.observed { observation.borrowerEntered.withLock { $0 } }
    let creator = MigrationPoolWork {
      Result {
        try limited.withConnection { _ in observation.bodyCalls.withLock { $0 += 1 } }
      }
    }
    let creation = try creator.value()
    release.signal()
    let borrowed = borrower.join()
    _ = try borrowed.get()
    #expect(entered)
    #expect(Self.isClosedRefusal(creation))
    if case .failure(let error as WorkspaceError) = creation {
      #expect(error.message.contains("too many connections for role"))
    }
    #expect(observation.bodyCalls.withLock { $0 } == 0)
    #expect(limited.closeForMigration(timeout: .milliseconds(250)))
    let limitedAbsent = await Self.observed {
      (try? fixture.inspector.execute(
        "SELECT 1 FROM pg_stat_activity WHERE datname = $1 AND application_name = $2",
        [fixture.endpoint.database, application]
      ).rows.isEmpty) == true
    }
    #expect(limitedAbsent)
    // Prove role cleanup rather than relying on the cluster's eventual removal.
    limited.close()
    try fixture.inspector.execute("DROP ROLE \(Rows.quote(role))")
    roleRemoved = true
    #expect(try fixture.inspector.execute("SELECT 1 FROM pg_roles WHERE rolname = $1", [role]).rows.isEmpty)
  }
}
