import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Real storage-only admission tests. No account lifecycle, production migration bypass, server,
/// listener or runtime is introduced to reach the old schema.
@Suite(.serialized) struct AgentProtocolMigrationAdmissionTests {
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
  }

  private enum FixtureFailure: Error { case barrierTimeout }

  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static func fixture(pending: Bool = true) throws -> Fixture {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir =
      try AgentProtocolResourceFixture.physicalExistingDirectory(
        (endpoint.logPath as NSString).deletingLastPathComponent) + "/data"
    let raw = try connection(endpoint)
    if pending {
      try Migrator.ensureLedger(raw, table: Migrator.table)
      for file in try Migrator.files() where file.name <= "0008_thread_delete" {
        try raw.execute(file.sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#, [file.name])
      }
      try raw.execute(
        """
        INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt")
          VALUES ('old-project', 'Retained', true, 'created', 'updated');
        INSERT INTO "connections" ("id", "kind", "label", "target", "authReference", "nativeScope",
          "projectId", "capabilities", "status", "authStatus", "createdAt", "updatedAt") VALUES
          ('old-b4', 'b4', 'Retained', 'https://example.invalid/base', 'secret:old-ref', 'old-scope',
          'old-project', '{}', 'ready', 'authenticated', 'created', 'updated');
        INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "nativeScope", "projectId",
          "readTurnId", "createdAt", "updatedAt") VALUES
          ('old-thread', 'old-b4', 'native-old', 'old-scope', 'old-project', 'old-turn', 'created', 'updated');
        INSERT INTO "turns" ("id", "threadId", "operationId", "status", "submission", "outcome",
          "createdAt", "updatedAt") VALUES
          ('old-turn', 'old-thread', 'old-operation', 'reconciling', 'unknown', NULL, 'created', 'updated');
        INSERT INTO "runtimeRequests" ("id", "nativeRequestId", "threadId", "turnId", "adapterGeneration",
          "kind", "state", "payload", "createdAt", "updatedAt") VALUES
          ('old-request', '1', 'old-thread', 'old-turn', 1, 'command_approval', 'pending',
          '{"opaque":[true,null,{"text":"🌱"}]}', 'created', 'updated');
        INSERT INTO "displayItems" ("id", "threadId", "turnId", "role", "type", "payload", "sequence",
          "provenance", "createdAt") VALUES
          ('old-item', 'old-thread', 'old-turn', 'assistant', 'agentMessage',
          '{"text":"Partial","opaque":{"unknown":true}}', 0, 'cache', 'created');
        INSERT INTO "drafts" ("threadId", "text", "updatedAt")
          VALUES ('old-thread', 'Retained unsent draft', 'updated');
        """)
    }
    return Fixture(endpoint: endpoint, raw: raw)
  }

  private static func snapshot(_ c: PostgresConnection) throws -> [String] {
    var facts = try c.execute("SELECT 'database:' || datname AS fact FROM pg_database").rows
      .compactMap { $0.text("fact") }
    for table in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY 1"
    ).rows.compactMap({ $0.text("tablename") }) {
      facts.append("table:\(table)")
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
    facts += try c.execute(
      "SELECT 'index:' || indexname || ':' || indexdef AS fact FROM pg_indexes WHERE schemaname = 'public'"
    ).rows.compactMap { $0.text("fact") }
    return facts.sorted()
  }

  private static func backupFiles(_ endpoint: PostgresEndpoint) -> [String] {
    let root = (endpoint.dataDir! as NSString).deletingLastPathComponent + "/backups"
    guard FileManager.default.fileExists(atPath: root) else { return [] }
    return [root]
      + ((FileManager.default.enumerator(
        at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).map(
        \.path
      ).sorted()
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

  private static func databasePoolAbsent(_ fixture: Fixture) -> Bool {
    (try? fixture.raw.execute(
      "SELECT 1 FROM pg_stat_activity WHERE datname = $1 AND application_name = 'b4app'",
      [fixture.endpoint.database]
    ).rows.isEmpty) == true
  }

  @Test func pendingPreflightReadsOldSchemaWithoutMutation() throws {
    let fixture = try Self.fixture()
    let before = try Self.snapshot(fixture.raw)
    let files = Self.backupFiles(fixture.endpoint)
    let result = Result {
      try WorkspaceDatabase.preflightMigration(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
    }
    // Full no-mutation assertions run even with the unsupported semantic baseline.
    #expect(try Self.snapshot(fixture.raw) == before)
    #expect(Self.backupFiles(fixture.endpoint) == files)
    #expect(try result.get() == .pending)
  }

  @Test func preflightDistinguishesCurrentEmptyAndMissingWithoutCreation() throws {
    let current = try Self.fixture(pending: false)
    let database = try WorkspaceDatabase(endpoint: current.endpoint, binDir: current.endpoint.binDir!)
    try database.close()
    let empty = try Self.fixture(pending: false)
    var missing = empty.endpoint
    missing.database = "a3_missing_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let cases: [(PostgresEndpoint, PostgresConnection, WorkspaceDatabase.MigrationState)] = [
      (current.endpoint, current.raw, .current), (empty.endpoint, empty.raw, .pending),
      (missing, empty.raw, .missing),
    ]
    for (endpoint, inspector, expected) in cases {
      let before = try Self.snapshot(inspector)
      let files = Self.backupFiles(endpoint)
      let result = Result {
        try WorkspaceDatabase.preflightMigration(endpoint: endpoint, binDir: endpoint.binDir!)
      }
      #expect(try Self.snapshot(inspector) == before)
      #expect(Self.backupFiles(endpoint) == files)
      switch result {
      case .success(let state): #expect(state == expected)
      case .failure(let error):
        Issue.record("Expected \(expected) preflight, received \(WorkspaceError.from(error).code.rawValue).")
      }
    }
    #expect(
      try empty.raw.execute(
        "SELECT 1 FROM pg_database WHERE datname = $1", [missing.database]
      ).rows.isEmpty)
    #expect(
      try empty.raw.execute(#"SELECT to_regclass('"schemaMigrations"')::text AS name"#)
        .rows.first?.text("name") == nil)
  }

  @Test func futurePreflightRefusesBeforeMutationOrBackup() throws {
    let fixture = try Self.fixture()
    try fixture.raw.execute(
      #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ('9999_future', 'fixture')"#)
    let before = try Self.snapshot(fixture.raw)
    let files = Self.backupFiles(fixture.endpoint)
    var code: ErrorCode?
    do {
      _ = try WorkspaceDatabase.preflightMigration(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
    } catch { code = WorkspaceError.from(error).code }
    #expect(code == .incompatibleVersion)
    #expect(try Self.snapshot(fixture.raw) == before)
    #expect(Self.backupFiles(fixture.endpoint) == files)
  }

  @Test func databaseMigrationCloseDrainsLeaseAndBoundsTimeout() async throws {
    // Successful drain after ordinary close, with one already admitted lease.
    do {
      let fixture = try Self.fixture(pending: false)
      let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
      defer { try? db.close() }
      let before = try Self.snapshot(fixture.raw)
      let files = Self.backupFiles(fixture.endpoint)
      let entered = Mutex(false), drainStarted = Mutex(false), finished = Mutex(false)
      let release = DispatchSemaphore(value: 0)
      let borrower = Task.detached {
        try db.read { _ in
          entered.withLock { $0 = true }
          guard release.wait(timeout: .now() + .seconds(8)) == .success else {
            throw FixtureFailure.barrierTimeout
          }
        }
      }
      let ready = await Self.observed { entered.withLock { $0 } }
      // Save a close failure, rather than throwing before release/join.
      let closed = Result { try db.close() }
      let drainer = Task.detached {
        drainStarted.withLock { $0 = true }
        let result = db.closeForMigration(timeout: .seconds(2))
        finished.withLock { $0 = true }
        return result
      }
      let started = await Self.observed { drainStarted.withLock { $0 } }
      let finishedWhileHeld = await Self.observed(within: .milliseconds(75)) { finished.withLock { $0 } }
      release.signal()
      let borrowed = await borrower.result
      let drained = await drainer.value
      _ = try closed.get()
      _ = try borrowed.get()
      #expect(ready && started)
      #expect(!finishedWhileHeld)
      #expect(drained)
      var refused = false
      do { _ = try db.listConnections() } catch {
        refused = WorkspaceError.from(error).code == .endpointUnavailable
      }
      #expect(refused)
      #expect(try Self.snapshot(fixture.raw) == before)
      #expect(Self.backupFiles(fixture.endpoint) == files)
      let absent = await Self.observed { Self.databasePoolAbsent(fixture) }
      #expect(absent)
    }
    // Timeout keeps admission closed. This guarded caller is test-owned, not account wiring.
    do {
      let fixture = try Self.fixture(pending: false)
      let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
      defer { try? db.close() }
      let before = try Self.snapshot(fixture.raw)
      let files = Self.backupFiles(fixture.endpoint)
      let entered = Mutex(false), stageCalls = Mutex(0)
      let release = DispatchSemaphore(value: 0)
      let borrower = Task.detached {
        try db.read { _ in
          entered.withLock { $0 = true }
          guard release.wait(timeout: .now() + .seconds(8)) == .success else {
            throw FixtureFailure.barrierTimeout
          }
        }
      }
      let ready = await Self.observed { entered.withLock { $0 } }
      let guardCaller = Task.detached {
        let start = ContinuousClock.now
        let drained = db.closeForMigration(timeout: .milliseconds(100))
        let elapsed = start.duration(to: .now)
        if drained {
          let c = try Self.connection(fixture.endpoint)
          try WorkspaceDatabase.migrateWithBackup(c, endpoint: fixture.endpoint, backupDirectory: nil) {
            _ in stageCalls.withLock { $0 += 1 }
          }
        }
        return (drained, elapsed)
      }
      let guarded = await guardCaller.result
      let after = Result { try Self.snapshot(fixture.raw) }
      let afterFiles = Self.backupFiles(fixture.endpoint)
      release.signal()
      let borrowed = await borrower.result
      _ = try borrowed.get()
      let (drained, elapsed) = try guarded.get()
      #expect(ready)
      #expect(!drained)
      #expect(elapsed < .seconds(1))
      #expect(stageCalls.withLock { $0 } == 0)
      #expect(try after.get() == before)
      #expect(afterFiles == files)
      var refused = false
      do { _ = try db.listConnections() } catch {
        refused = WorkspaceError.from(error).code == .endpointUnavailable
      }
      #expect(refused)
      let absent = await Self.observed { Self.databasePoolAbsent(fixture) }
      #expect(absent)
    }
  }
}
