import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Real prefix10 admission controls. Ordinary witness data stays outside the closed public schema;
/// the archive oracle is the independent shared test reader, not the production decoder.
@Suite(.serialized)
struct AgentProtocolEnvironmentHistoryIntegrationTests {
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let backup: String
    let rows: [String: [String]]
    let facts: AgentProtocolFoundationFixture.ArchiveFacts
    let migrations: [String]
    let opaqueFeed: String
  }

  private enum Fault: Error { case durability }

  private func fixture() throws -> Fixture {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(endpoint.database) user=\(NSUserName())")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    let prefix = try Migrator.files().filter { $0.name < "0011" }
    for file in prefix {
      try raw.execute(file.sql)
      try raw.execute(
        "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'prefix10')", [file.name])
    }
    try raw.execute(
      """
      SET b4app.replaying='on';
      INSERT INTO public.projects (id,name,"createdAt","updatedAt") VALUES ('retained','old','then','then');
      INSERT INTO public.changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
        VALUES ('fixture',1,'displayItems','opaque','update','payload',
          '{"projectId":"external","environmentId":"keep","nested":{"projectId":"inside"}}','clock');
      RESET b4app.replaying;
      """
    )
    let tables = try raw.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows.compactMap { $0.text("tablename") }
    var rows: [String: [String]] = [:]
    for table in tables {
      rows[table] = try raw.execute(
        "SELECT to_jsonb(r)::text AS row FROM public.\(Rows.quote(table)) r ORDER BY 1"
      ).rows.compactMap { $0.text("row") }
    }
    let backup =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-history-" + UUID().uuidString
      + "/backups"
    return Fixture(
      endpoint: endpoint, raw: raw, backup: backup, rows: rows,
      facts: try AgentProtocolFoundationFixture.archiveFacts(raw), migrations: prefix.map(\.name),
      opaqueFeed: try #require(
        try raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
          .rows.first?.text("value")))
  }

  private func archives(_ fixture: Fixture) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: fixture.backup) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: fixture.backup), includingPropertiesForKeys: nil)
  }

  private func assertBackup(_ fixture: Fixture) throws {
    let files = try archives(fixture)
    #expect(files.count == 1)
    let file = try #require(files.first)
    #expect(file.pathExtension == "jsonl")
    let document = try AgentProtocolFoundationFixture.readV4(
      String(contentsOf: file, encoding: .utf8),
      expectedRows: fixture.rows, expectedMigrations: fixture.migrations, facts: fixture.facts,
      canonicalPrefixCount: 10)
    try AgentProtocolFoundationFixture.assertArchiveRows(
      document, oldRows: fixture.rows, facts: fixture.facts)
  }

  @Test(arguments: ["read committed", "repeatable read"])
  func publicPrefixTenBackupAndHistorySurviveThroughFourteen(isolation: String) throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    try f.raw.execute(
      "ALTER DATABASE \(Rows.quote(f.endpoint.database)) SET default_transaction_isolation='\(isolation)'")
    let db = try WorkspaceDatabase(
      endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    let outcome = Result<Void, any Error> { () throws -> Void in
      try assertBackup(f)
      #expect(try db.appliedMigrations() == Migrator.files().map(\.name))
      #expect(
        try f.raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
          .rows.first?.text("value") == f.opaqueFeed)
      #expect(
        try f.raw.execute("SELECT name FROM public.environments WHERE id='retained'").rows.first?.text("name")
          == "old")
      #expect(
        try f.raw.execute("SELECT to_regclass('public.\"appFolders\"') IS NOT NULL AS present").rows.first?
          .text("present") == "t")
      #expect(
        try f.raw.execute("SELECT to_regclass('public.\"protocolSubscriptions\"') IS NOT NULL AS present")
          .rows.first?.text("present") == "t")
    }
    try db.close()
    try outcome.get()
  }

  @Test(arguments: [
    MigrationBackupStage.contentsWritten, .fileSynchronized, .renamed, .directorySynchronized,
  ])
  func genuinePrefixTenDurabilityFaultPrecedesAnyMigration(failing: MigrationBackupStage) throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    let reached = Mutex(false)
    let outcome = Result {
      try WorkspaceDatabase.migrateWithBackup(f.raw, endpoint: f.endpoint, backupDirectory: f.backup) {
        stage in
        if stage == failing { reached.withLock { $0 = true }; throw Fault.durability }
      }
    }
    #expect(throws: WorkspaceError.self) { try outcome.get() }
    #expect(reached.withLock { $0 })
    #expect(try Migrator.recorded(f.raw) == f.migrations)
    #expect(
      try f.raw.execute("SELECT to_regclass('public.projects') IS NOT NULL AS present").rows.first?.text(
        "present") == "t")
    #expect(
      try f.raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
        .rows.first?.text("value") == f.opaqueFeed)
    let files = try archives(f)
    #expect(!files.contains { $0.pathExtension == "partial" })
    if failing == .renamed || failing == .directorySynchronized {
      try assertBackup(f)
    } else {
      #expect(files.isEmpty)
    }
  }

  @Test func missingLedgerNonemptyStoreRefusesBeforeSnapshotFileStages() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    try f.raw.execute("DROP TABLE public.\"schemaMigrations\"")
    let stages = Mutex<[MigrationBackupStage]>([])
    let outcome = Result {
      try WorkspaceDatabase.migrateWithBackup(f.raw, endpoint: f.endpoint, backupDirectory: f.backup) {
        stage in
        stages.withLock { $0.append(stage) }
      }
    }
    #expect(throws: WorkspaceError.self) { try outcome.get() }
    #expect(stages.withLock { $0 } == [.locked])
    #expect(
      try f.raw.execute("SELECT to_regclass('public.\"schemaMigrations\"')::text AS name").rows.first?.text(
        "name") == nil)
    #expect(
      try f.raw.execute("SELECT to_regclass('public.projects') IS NOT NULL AS present").rows.first?.text(
        "present") == "t")
    #expect(try archives(f).isEmpty)
  }

  @Test func laterFourteenCommitFaultKeepsElevenTwelveThirteenAndTheirBackup() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    try f.raw.execute(
      """
      CREATE SCHEMA history_integration;
      CREATE SEQUENCE history_integration.probe;
      CREATE FUNCTION history_integration.refuse_fourteen() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        IF to_regclass('public."appFolders"') IS NULL OR to_regclass('public."protocolSubscriptions"') IS NULL
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0011_environments')
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0012_app_folders')
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0013_view_settings')
          OR to_regclass('public."viewSettings"') IS NULL
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name=NEW.name AND "appliedAt"=NEW."appliedAt")
          OR NOT EXISTS (SELECT 1 FROM public.changes WHERE "rowId"='opaque'
            AND value='{"projectId":"external","environmentId":"keep","nested":{"projectId":"inside"}}'::jsonb)
        THEN RAISE EXCEPTION 'Fourteen COMMIT stage was not reached'; END IF;
        PERFORM nextval('history_integration.probe');
        RAISE EXCEPTION 'Deliberate fourteen COMMIT refusal';
      END $$;
      CREATE CONSTRAINT TRIGGER history_integration_fourteen AFTER INSERT ON public."schemaMigrations"
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.name='0014_agent_protocol')
        EXECUTE FUNCTION history_integration.refuse_fourteen();
      """
    )
    let failed = Result {
      try WorkspaceDatabase(
        endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    }
    if case .success(let db) = failed { try db.close(); Issue.record("Actual fourteen COMMIT must fail") }
    #expect(throws: WorkspaceError.self) { try failed.get() }
    #expect(
      try f.raw.execute("SELECT last_value::text AS n FROM history_integration.probe WHERE is_called").rows
        .first?.text("n") == "1")
    #expect(try Migrator.recorded(f.raw) == Array(Migrator.files().map(\.name).prefix(13)))
    #expect(
      try f.raw.execute("SELECT to_regclass('public.\"protocolSubscriptions\"')::text AS name").rows.first?
        .text("name") == nil)
    #expect(
      try f.raw.execute("SELECT to_regclass('public.\"appFolders\"') IS NOT NULL AS present").rows.first?
        .text("present") == "t")
    #expect(
      try f.raw.execute(
        "SELECT count(*)::text AS n FROM information_schema.columns WHERE table_schema='public' AND table_name='connections' AND column_name='peerProfile'"
      ).rows.first?.text("n") == "0")
    #expect(
      try f.raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
        .rows.first?.text("value") == f.opaqueFeed)
    try assertBackup(f)
    let oldFile = try #require(try archives(f).first)
    let oldBytes = try Data(contentsOf: oldFile)
    let priorLedger = try #require(
      try f.raw.execute(
        "SELECT jsonb_agg(to_jsonb(m) ORDER BY name)::text AS value FROM public.\"schemaMigrations\" m"
      ).rows.first?.text("value"))
    try f.raw.execute("DROP TRIGGER history_integration_fourteen ON public.\"schemaMigrations\"")
    let db = try WorkspaceDatabase(
      endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    try db.close()
    #expect(try Migrator.recorded(f.raw) == Migrator.files().map(\.name))
    #expect(
      try f.raw.execute(
        "SELECT jsonb_agg(to_jsonb(m) ORDER BY name)::text AS value FROM public.\"schemaMigrations\" m WHERE name<'0014'"
      ).rows.first?.text("value") == priorLedger)
    #expect(try Data(contentsOf: oldFile) == oldBytes)
    #expect(try archives(f).count == 2)
    #expect(
      try f.raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
        .rows.first?.text("value") == f.opaqueFeed)
    #expect(
      try f.raw.execute("SELECT count(*)::text AS n FROM public.\"protocolSubscriptions\"").rows.first?.text(
        "n") == "0")
  }

  @Test func directMigrationCannotOvertakeDurableBackup() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    func connection() throws -> PostgresConnection {
      try PostgresConnection(
        lib: LibPQ.load(binDir: f.endpoint.binDir!),
        connectionString:
          "host=\(f.endpoint.socketDir) port=\(f.endpoint.port) dbname=\(f.endpoint.database) user=\(NSUserName())"
      )
    }
    let observer = try connection()
    let secondConnection = try connection()
    let holderPID = try #require(
      try f.raw.execute("SELECT pg_backend_pid()::text AS pid").rows.first?.text("pid"))
    let waiterPID = try #require(
      try secondConnection.execute("SELECT pg_backend_pid()::text AS pid").rows.first?.text("pid"))
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let firstDone = DispatchSemaphore(value: 0)
    let secondDone = DispatchSemaphore(value: 0)
    let held = Mutex(false)
    let firstResult = Mutex<Result<Void, any Error>?>(nil)
    let secondResult = Mutex<Result<[String], any Error>?>(nil)
    let first = Thread {
      let result = Result {
        try WorkspaceDatabase.migrateWithBackup(f.raw, endpoint: f.endpoint, backupDirectory: f.backup) {
          stage in
          if stage == .directorySynchronized {
            held.withLock { $0 = true }
            reached.signal()
            release.wait()
          }
        }
      }
      firstResult.withLock { $0 = result }
      reached.signal()  // A pre-barrier failure also wakes the controller; it is never a fake success.
      firstDone.signal()
    }
    first.start()
    reached.wait()
    var second: Thread?
    let observation = Result<Void, any Error> { () throws -> Void in
      try #require(held.withLock { $0 })
      try assertBackup(f)
      #expect(try Migrator.recorded(observer) == f.migrations)
      second = Thread {
        let result = Result { try Migrator.migrate(secondConnection) }
        secondResult.withLock { $0 = result }
        secondDone.signal()
      }
      second?.start()
      let deadline = ContinuousClock.now + .seconds(10)
      var blocked = false
      repeat {
        blocked = try !observer.execute(
          """
          SELECT 1 FROM pg_catalog.pg_locks l
          WHERE l.pid=$1::int AND l.locktype='advisory' AND NOT l.granted AND l.objsubid=1
            AND l.classid=$2::oid AND l.objid=$3::oid AND $4::int=ANY(pg_catalog.pg_blocking_pids(l.pid))
          """,
          [
            waiterPID, String(UInt64(Migrator.migrationLockKey) >> 32),
            String(UInt64(Migrator.migrationLockKey) & 0xffff_ffff), holderPID,
          ]
        ).rows.isEmpty
        if !blocked { Thread.sleep(forTimeInterval: 0.01) }
      } while !blocked && ContinuousClock.now < deadline
      try #require(blocked)
    }
    // Always release the original backup operation before joining either actual call.
    release.signal()
    firstDone.wait()
    if second != nil { secondDone.wait() }
    try observation.get()
    try #require(firstResult.withLock { $0 }).get()
    #expect(try #require(secondResult.withLock { $0 }).get().isEmpty)
    #expect(try Migrator.recorded(observer) == Migrator.files().map(\.name))
  }

  @Test(arguments: ["0012_agent_protocol", "0013_agent_protocol", "0000_unknown"])
  func currentStoreWithUnknownLedgerRefusesWithoutBackupOrMutation(extra: String) throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    let initial = try WorkspaceDatabase(
      endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    try initial.close()
    try #require(try Migrator.recorded(f.raw) == Migrator.files().map(\.name))
    try f.raw.execute(
      "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'unpublished')", [extra])
    func snapshot() throws -> [String] {
      let tables = try f.raw.execute(
        "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename"
      ).rows.compactMap { $0.text("tablename") }
      var rows: [String] = []
      for table in tables {
        rows += try f.raw.execute(
          "SELECT $1 || ':' || to_jsonb(r)::text AS fact FROM public.\(Rows.quote(table)) r ORDER BY 1",
          [table]
        ).rows.compactMap { $0.text("fact") }
      }
      rows += try f.raw.execute(
        """
        SELECT 'column:' || c.oid::text || ':' || c.relname || ':' || a.attname || ':' || a.atttypid::text || ':' || a.attnotnull::text AS fact
        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid
        WHERE c.relnamespace='public'::regnamespace AND a.attnum>0 AND NOT a.attisdropped ORDER BY 1
        """
      ).rows.compactMap { $0.text("fact") }
      rows += try f.raw.execute(
        """
        SELECT 'constraint:' || k.oid::text || ':' || pg_get_constraintdef(k.oid) AS fact
        FROM pg_catalog.pg_constraint k JOIN pg_catalog.pg_class c ON c.oid=k.conrelid
        WHERE c.relnamespace='public'::regnamespace ORDER BY 1
        """
      ).rows.compactMap { $0.text("fact") }
      rows += try f.raw.execute(
        "SELECT 'sequence:' || last_value::text || ':' || log_cnt::text || ':' || is_called::text AS fact FROM public.changes_seq_seq"
      ).rows.compactMap { $0.text("fact") }
      return rows.sorted()
    }
    let before = try snapshot()
    let backupFiles = try archives(f).sorted { $0.path < $1.path }
    let backupBytes = try backupFiles.map { try Data(contentsOf: $0) }
    let outcome = Result {
      try WorkspaceDatabase(
        endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    }
    if case .success(let db) = outcome {
      try db.close(); Issue.record("A noncanonical current ledger must refuse")
    }
    #expect(throws: WorkspaceError.self) { try outcome.get() }
    if case .failure(let error) = outcome {
      let safe = try #require(error as? WorkspaceError)
      #expect(safe.code == .internalError)
      #expect(safe.message == "Store environment history preservation failed.")
      #expect(safe.details == nil)
    }
    #expect(try snapshot() == before)
    let afterFiles = try archives(f).sorted { $0.path < $1.path }
    #expect(afterFiles == backupFiles)
    #expect(try afterFiles.map { try Data(contentsOf: $0) } == backupBytes)
  }

}
