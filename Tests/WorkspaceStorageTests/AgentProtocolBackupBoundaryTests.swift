import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Real PostgreSQL controls for the shared migration admission core. Faults are injected at observed
/// durability boundaries, not reported as actual kernel syscall failures. No account/runtime starts.
@Suite(.serialized) struct AgentProtocolBackupBoundaryTests {
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let backupDirectory: String
  }

  private struct Snapshot: Equatable, Sendable {
    var rows: [String: [String]]
    var columns: [String]
    var constraints: [String]
    var jsonColumns: [String: Set<String>]
    var archiveFacts: AgentProtocolFoundationFixture.ArchiveFacts
  }

  private enum FixtureFailure: Error { case barrierTimeout }

  private struct SentinelFailure: Error, CustomStringConvertible {
    var description: String { "A3_FAKE_PRIVATE_FAILURE_SENTINEL" }
  }

  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static func fixture() throws -> Fixture {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir =
      URL(fileURLWithPath: endpoint.logPath).deletingLastPathComponent()
      .appendingPathComponent("data").path
    let raw = try connection(endpoint)
    try Migrator.ensureLedger(raw, table: Migrator.table)
    for file in try Migrator.files() where file.name <= "0008_thread_delete" {
      try raw.execute(file.sql)
      try raw.execute(
        #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#, [file.name])
    }
    try raw.execute(
      """
      INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt")
        VALUES ('old-project', 'Retained project', true, 'created', 'updated');
      INSERT INTO "connections" ("id", "kind", "label", "target", "routeKey", "nativeScope",
        "authReference", "projectId", "capabilities", "status", "authStatus", "createdAt", "updatedAt")
        VALUES ('old-b4', 'b4', 'Before upgrade', 'https://example.invalid/base', '/old#agent',
        'old-native-scope', 'secret:retained-ref', 'old-project', '{}', 'ready', 'authenticated',
        'created', 'updated');
      INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "nativeScope", "projectId",
        "readTurnId", "createdAt", "updatedAt") VALUES
        ('old-thread', 'old-b4', 'reused-native', 'old-native-scope', 'old-project', 'old-turn',
        'created', 'updated');
      INSERT INTO "turns" ("id", "threadId", "operationId", "status", "submission", "outcome",
        "createdAt", "updatedAt") VALUES
        ('old-turn', 'old-thread', 'old-operation', 'reconciling', 'unknown', NULL, 'created', 'updated');
      INSERT INTO "runtimeRequests" ("id", "nativeRequestId", "threadId", "turnId", "adapterGeneration",
        "kind", "state", "payload", "createdAt", "updatedAt") VALUES
        ('old-request', '1', 'old-thread', 'old-turn', 1, 'command_approval', 'pending',
        '{"opaque":[true,null,{"text":"retained 🌱"}]}', 'created', 'updated');
      INSERT INTO "displayItems" ("id", "threadId", "turnId", "role", "type", "payload", "sequence",
        "provenance", "createdAt") VALUES
        ('old-item', 'old-thread', 'old-turn', 'assistant', 'agentMessage',
        '{"text":"Partial","opaque":{"unknown":true}}', 0, 'cache', 'created');
      INSERT INTO "drafts" ("threadId", "text", "updatedAt")
        VALUES ('old-thread', 'Unsent retained draft', 'updated');
      """)
    let backup = URL(fileURLWithPath: endpoint.dataDir!).deletingLastPathComponent()
      .appendingPathComponent("backups").appendingPathComponent(endpoint.database).path
    return Fixture(endpoint: endpoint, raw: raw, backupDirectory: backup)
  }

  private static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    let tables = try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename"
    ).rows.compactMap { $0.text("tablename") }
    var rows: [String: [String]] = [:]
    for table in tables {
      rows[table] = try c.execute(
        "SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1"
      ).rows.compactMap { $0.text("row") }
    }
    let columns = try c.execute(
      """
      SELECT table_name || ':' || column_name || ':' || data_type || ':' || is_nullable || ':' ||
        coalesce(column_default, '') AS fact FROM information_schema.columns
        WHERE table_schema = 'public' ORDER BY 1
      """
    ).rows.compactMap { $0.text("fact") }
    let constraints = try c.execute(
      """
      SELECT r.relname || ':' || c.conname || ':' || pg_get_constraintdef(c.oid) AS fact
        FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = 'public' ORDER BY 1
      """
    ).rows.compactMap { $0.text("fact") }
    var jsonColumns: [String: Set<String>] = [:]
    for row in try c.execute(
      """
      SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND data_type IN ('json', 'jsonb')
      """
    ).rows {
      let table = try #require(row.text("table_name"))
      jsonColumns[table, default: []].insert(try #require(row.text("column_name")))
    }
    return Snapshot(
      rows: rows, columns: columns, constraints: constraints, jsonColumns: jsonColumns,
      archiveFacts: try AgentProtocolFoundationFixture.archiveFacts(c))
  }

  private static func files(_ directory: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
  }

  private static func assertRetainedRows(_ before: Snapshot, _ after: Snapshot) throws {
    for (table, original) in before.rows {
      let currentTable = AgentProtocolFoundationFixture.currentTable(old: table)
      let restored = try #require(after.rows[currentTable])
      if table == Migrator.table {
        #expect(Set(original).isSubset(of: Set(restored)))  // Preserve each original appliedAt exactly.
        #expect(restored.count == original.count + 4)
        let addedNames = try Set(restored).subtracting(original).map { text in
          let row = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          return try #require(row["name"] as? String)
        }
        #expect(
          Set(addedNames)
            == Set([
              "0009_thread_runtime_choice", "0010_owned_rows", "0011_environments", "0012_app_folders",
              "0013_agent_protocol",
            ]))
        continue
      }
      func normalized(_ rows: [String], table: String, renameLegacy: Bool) throws -> [String] {
        try rows.map { text in
          var object = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          for column in AgentProtocolFoundationFixture.addedColumns[table] ?? [] {
            if let value = object[column] { #expect(value is NSNull) }
            object.removeValue(forKey: column)
          }
          if renameLegacy {
            object = try AgentProtocolFoundationFixture.currentRow(table: table, row: object)
          }
          return try AgentProtocolFoundationFixture.canonical(object)
        }.sorted()
      }
      #expect(
        try normalized(original, table: table, renameLegacy: true)
          == normalized(restored, table: currentTable, renameLegacy: false))
    }
  }

  private static func assertOldArchive(
    _ fixture: Fixture, label: String = "Before upgrade", expected: Snapshot? = nil
  ) throws {
    let archives = try files(fixture.backupDirectory).filter { $0.pathExtension == "jsonl" }
    #expect(archives.count == 1)
    let archive = try #require(archives.first)
    let text = try String(contentsOf: archive, encoding: .utf8)
    let expected = try #require(expected)
    let document = try AgentProtocolFoundationFixture.readV4(
      text, expectedRows: expected.rows,
      expectedMigrations: Array(AgentProtocolFoundationFixture.migrations.prefix(8)),
      facts: expected.archiveFacts)
    try AgentProtocolFoundationFixture.assertArchiveRows(
      document, oldRows: expected.rows, facts: expected.archiveFacts)
    let rows = document.rows
    let oldConnection = try #require(rows["connections"]?.first { $0["id"] as? String == "old-b4" })
    #expect(oldConnection["label"] as? String == label)
    #expect(oldConnection["projectId"] as? String == "old-project")
    #expect(oldConnection["nativeScope"] as? String == "old-native-scope")
    #expect(oldConnection["authReference"] as? String == "secret:retained-ref")
    #expect(oldConnection["models"] == nil)
    #expect(rows["threads"]?.first?["readTurnId"] as? String == "old-turn")
    #expect(rows["turns"]?.first?["submission"] as? String == "unknown")
    #expect(rows["turns"]?.first?["outcome"] is NSNull)
    #expect(rows["runtimeRequests"]?.first?["state"] as? String == "pending")
    #expect(rows["drafts"]?.first?["text"] as? String == "Unsent retained draft")
    let fileMode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions]
    let directoryMode = try FileManager.default.attributesOfItem(atPath: fixture.backupDirectory)[
      .posixPermissions]
    #expect((fileMode as? NSNumber)?.intValue == 0o600)
    #expect((directoryMode as? NSNumber)?.intValue == 0o700)
  }

  private static func observed(_ body: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !body(), ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return body()
  }

  private static func waitingOnAdvisory(_ c: PostgresConnection, pid: Int) -> Bool {
    (try? c.execute(
      "SELECT 1 FROM pg_stat_activity WHERE pid = $1::integer AND wait_event_type = 'Lock' AND wait_event = 'advisory'",
      [String(pid)]
    ).rows.isEmpty == false) == true
  }

  @Test func backupDurabilityBoundaryFailuresLeaveOldStoreUntouched() throws {
    for failingStage in [MigrationBackupStage.contentsWritten, .fileSynchronized, .renamed] {
      let fixture = try Self.fixture()
      defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
      let before = try Self.snapshot(fixture.raw)
      let reached = Mutex(false)
      var refused: WorkspaceError?
      do {
        try WorkspaceDatabase.migrateWithBackup(
          fixture.raw, endpoint: fixture.endpoint, backupDirectory: fixture.backupDirectory
        ) { stage in
          if stage == failingStage {
            reached.withLock { $0 = true }
            throw SentinelFailure()
          }
        }
      } catch { refused = WorkspaceError.from(error) }
      #expect(reached.withLock { $0 })
      let error = try #require(refused)
      let encoded = String(decoding: try JSONCoding.encoder.encode(error), as: UTF8.self)
      #expect(!encoded.contains(SentinelFailure().description))
      #expect(!error.description.contains(SentinelFailure().description))
      #expect(error.details == nil)
      #expect(try Self.snapshot(fixture.raw) == before)
      let remaining = try Self.files(fixture.backupDirectory)
      #expect(!remaining.contains { $0.pathExtension == "partial" })
      if failingStage == .renamed {
        try Self.assertOldArchive(fixture, expected: before)
      } else {
        #expect(remaining.isEmpty)
      }
    }
  }

  @Test func migrationCannotRunBeforeDurableArchive() throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
    let before = try Self.snapshot(fixture.raw)
    let inspector = try Self.connection(fixture.endpoint)
    let stages = Mutex<[MigrationBackupStage]>([])
    try WorkspaceDatabase.migrateWithBackup(
      fixture.raw, endpoint: fixture.endpoint, backupDirectory: fixture.backupDirectory
    ) { stage in
      stages.withLock { $0.append(stage) }
      #expect(try Self.snapshot(inspector) == before)
      if stage == .directorySynchronized || stage == .willMigrate {
        try Self.assertOldArchive(fixture, expected: before)
      }
    }
    #expect(
      stages.withLock { $0 } == [
        .locked, .contentsWritten, .fileSynchronized, .renamed, .directorySynchronized, .willMigrate,
      ])
    #expect(try Migrator.recorded(fixture.raw) == AgentProtocolFoundationFixture.migrations)
    #expect(try Self.snapshot(fixture.raw) != before)
    try Self.assertRetainedRows(before, Self.snapshot(fixture.raw))
    try AgentProtocolFoundationFixture.assertCurrentPreservesOld(fixture.raw, oldRows: before.rows)
  }

  @Test func concurrentOpensSerializeCaptureAndApplyOnce() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
    let before = try Self.snapshot(fixture.raw)
    let release = DispatchSemaphore(value: 0)
    let firstPaused = Mutex(false)
    let secondPID = Mutex(0)
    let secondLocked = Mutex(false)
    let first = Task.detached {
      let c = try Self.connection(fixture.endpoint)
      try WorkspaceDatabase.migrateWithBackup(
        c, endpoint: fixture.endpoint, backupDirectory: fixture.backupDirectory
      ) { stage in
        if stage == .contentsWritten {
          firstPaused.withLock { $0 = true }
          guard release.wait(timeout: .now() + .seconds(8)) == .success else {
            throw FixtureFailure.barrierTimeout
          }
        }
      }
    }
    let paused = await Self.observed { firstPaused.withLock { $0 } }
    let second = Task.detached {
      let c = try Self.connection(fixture.endpoint)
      let pid = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid") ?? 0
      secondPID.withLock { $0 = pid }
      try WorkspaceDatabase.migrateWithBackup(
        c, endpoint: fixture.endpoint, backupDirectory: fixture.backupDirectory
      ) { stage in if stage == .locked { secondLocked.withLock { $0 = true } } }
    }
    let waiting = await Self.observed {
      Self.waitingOnAdvisory(fixture.raw, pid: secondPID.withLock { $0 })
    }
    let lockedBeforeRelease = secondLocked.withLock { $0 }
    let whileHeld = Result { try Self.snapshot(fixture.raw) }
    // No throwing assertion or exit may skip releasing/joining either worker.
    release.signal()
    let firstResult = await first.result
    let secondResult = await second.result
    try firstResult.get()
    try secondResult.get()
    #expect(paused)
    #expect(waiting)
    #expect(!lockedBeforeRelease)
    #expect(try whileHeld.get() == before)
    #expect(secondLocked.withLock { $0 })
    try Self.assertOldArchive(fixture, expected: before)
    #expect(try Migrator.recorded(fixture.raw).filter { $0 == "0009_thread_runtime_choice" }.count == 1)
    #expect(try Migrator.recorded(fixture.raw) == AgentProtocolFoundationFixture.migrations)
    try Self.assertRetainedRows(before, Self.snapshot(fixture.raw))
    try AgentProtocolFoundationFixture.assertCurrentPreservesOld(fixture.raw, oldRows: before.rows)
  }

  @Test func sharedWriterFinishesBeforeMigrationSnapshot() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
    let inspector = try Self.connection(fixture.endpoint)
    let migrationPID = Mutex(0)
    let captureStarted = Mutex(false)
    try fixture.raw.execute("BEGIN")
    do {
      try fixture.raw.execute(
        "SELECT pg_advisory_xact_lock_shared($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
      try fixture.raw.execute(
        #"UPDATE "connections" SET "label" = 'Committed before migration' WHERE "id" = 'old-b4'"#)
    } catch {
      _ = try? fixture.raw.execute("ROLLBACK")
      throw error
    }
    let migration = Task.detached {
      let c = try Self.connection(fixture.endpoint)
      let pid = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid") ?? 0
      migrationPID.withLock { $0 = pid }
      try WorkspaceDatabase.migrateWithBackup(
        c, endpoint: fixture.endpoint, backupDirectory: fixture.backupDirectory
      ) { stage in if stage == .contentsWritten { captureStarted.withLock { $0 = true } } }
    }
    let waiting = await Self.observed {
      Self.waitingOnAdvisory(inspector, pid: migrationPID.withLock { $0 })
    }
    let capturedBeforeCommit = captureStarted.withLock { $0 }
    let committedOld = Result { try Self.snapshot(fixture.raw) }
    let committed = Result { try fixture.raw.execute("COMMIT") }
    if case .failure = committed { _ = try? fixture.raw.execute("ROLLBACK") }
    let result = await migration.result
    _ = try committed.get()
    try result.get()
    #expect(waiting)
    #expect(!capturedBeforeCommit)
    #expect(captureStarted.withLock { $0 })
    let expected = try committedOld.get()
    try Self.assertOldArchive(fixture, label: "Committed before migration", expected: expected)
    #expect(try Migrator.recorded(fixture.raw) == AgentProtocolFoundationFixture.migrations)
    try Self.assertRetainedRows(expected, Self.snapshot(fixture.raw))
    try AgentProtocolFoundationFixture.assertCurrentPreservesOld(fixture.raw, oldRows: expected.rows)
  }
}
