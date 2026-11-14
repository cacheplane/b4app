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

  private func currentRows(_ raw: PostgresConnection) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    for table in try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
      .rows.compactMap({ $0.text("tablename") })
    {
      result[table] = try raw.execute(
        "SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1"
      ).rows.compactMap { $0.text("row") }
    }
    return result
  }
  /// Match archive images from native cells without decoding any opaque JSONB value.
  private func archiveImages(
    _ raw: PostgresConnection, facts: AgentProtocolFoundationFixture.ArchiveFacts
  ) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    for table in try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
      .rows.compactMap({ $0.text("tablename") })
    {
      let fields = (facts.jsonColumns[table] ?? []).sorted().flatMap {
        ["'" + $0 + "'", "t." + Rows.quote($0) + "::text"]
      }
      let image =
        fields.isEmpty
        ? "to_jsonb(t)" : "to_jsonb(t)||jsonb_build_object(" + fields.joined(separator: ",") + ")"
      result[table] = try raw.execute(
        "SELECT (" + image + ")::text AS row FROM " + Rows.quote(table) + " t"
      ).rows.map { row in
        guard let text = row.text("row") else { throw AgentProtocolFoundationFixture.Failure.row }
        // Every native JSON/JSONB cell is now opaque text, including1e400 and jsonb null.
        return try AgentProtocolFoundationFixture.canonical(
          JSONSerialization.jsonObject(with: Data(text.utf8)))
      }.sorted()
    }
    return result
  }
  private func requireArchiveImages(
    _ document: AgentProtocolFoundationFixture.Document, expected: [String: [String]]
  ) throws {
    for (table, original) in expected {
      let actual = try (document.rows[table] ?? []).map { try AgentProtocolFoundationFixture.canonical($0) }
        .sorted()
      guard actual.map({ Data($0.utf8) }) == original.map({ Data($0.utf8) }) else {
        throw AgentProtocolFoundationFixture.Failure.row
      }
    }
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
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0014_connection_commands')
          OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='connections' AND column_name='commands')
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0015_density')
          OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
            WHERE t.tgrelid='public."viewSettings"'::regclass AND t.tgname='viewSettingsChanges'
              AND NOT t.tgisinternal AND t.tgtype=29 AND t.tgenabled='O' AND t.tgnargs=1
              AND encode(t.tgargs,'hex')='696400' AND t.tgfoid='public.b4app_record_change()'::regprocedure
              AND p.prosrc LIKE '%''density''%')
          OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='viewSettings' AND column_name='density' AND data_type='text' AND is_nullable='YES' AND column_default IS NULL)
          OR to_regclass('public."viewSettings"') IS NULL
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name=NEW.name AND "appliedAt"=NEW."appliedAt")
          OR NOT EXISTS (SELECT 1 FROM public.changes WHERE "rowId"='opaque'
            AND value='{"projectId":"external","environmentId":"keep","nested":{"projectId":"inside"}}'::jsonb)
        THEN RAISE EXCEPTION 'Fourteen COMMIT stage was not reached'; END IF;
        PERFORM nextval('history_integration.probe');
        RAISE EXCEPTION 'Deliberate fourteen COMMIT refusal';
      END $$;
      CREATE CONSTRAINT TRIGGER history_integration_fourteen AFTER INSERT ON public."schemaMigrations"
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.name='0016_agent_protocol')
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
    #expect(try Migrator.recorded(f.raw) == Array(AgentProtocolFoundationFixture.migrations.prefix(15)))
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
    #expect(
      try f.raw.execute(
        "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='connections' AND column_name='commands'"
      ).rows.count == 1)
    #expect(try f.raw.execute("SELECT 1 FROM connections WHERE commands IS NOT NULL").rows.isEmpty)
    try assertBackup(f)
    let oldFile = try #require(try archives(f).first)
    let oldBytes = try Data(contentsOf: oldFile)
    let priorLedger = try #require(
      try f.raw.execute(
        "SELECT jsonb_agg(to_jsonb(m) ORDER BY name)::text AS value FROM public.\"schemaMigrations\" m"
      ).rows.first?.text("value"))
    let committedRows = try currentRows(f.raw)
    let committedFacts = try AgentProtocolFoundationFixture.archiveFacts(f.raw)
    _ = try AgentProtocolFoundationFixture.preservationPrefix(f.raw, expectedCount: 15)
    try f.raw.execute("DROP TRIGGER history_integration_fourteen ON public.\"schemaMigrations\"")
    let db = try WorkspaceDatabase(
      endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    try db.close()
    #expect(try Migrator.recorded(f.raw) == Migrator.files().map(\.name))
    #expect(
      try f.raw.execute(
        "SELECT jsonb_agg(to_jsonb(m) ORDER BY name)::text AS value FROM public.\"schemaMigrations\" m WHERE name<'0016'"
      ).rows.first?.text("value") == priorLedger)
    #expect(try Data(contentsOf: oldFile) == oldBytes)
    #expect(try archives(f).count == 2)
    for archive in try archives(f) {
      let mode =
        try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
      #expect(mode?.intValue == 0o600)
    }
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: f.backup)[.posixPermissions] as? NSNumber
    #expect(directoryMode?.intValue == 0o700)

    let retryBackup = try #require(try archives(f).first { $0 != oldFile })
    let retryDocument = try AgentProtocolFoundationFixture.readV4(
      String(contentsOf: retryBackup, encoding: .utf8), expectedRows: committedRows,
      expectedMigrations: Array(AgentProtocolFoundationFixture.migrations.prefix(15)),
      facts: committedFacts, canonicalPrefixCount: 15)
    try AgentProtocolFoundationFixture.assertArchiveRows(
      retryDocument, oldRows: committedRows, facts: committedFacts)
    #expect(retryDocument.header["protocolSchema"] == nil)

    #expect(
      try f.raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
        .rows.first?.text("value") == f.opaqueFeed)
    #expect(
      try f.raw.execute("SELECT count(*)::text AS n FROM public.\"protocolSubscriptions\"").rows.first?.text(
        "n") == "0")
  }

  @Test func publishedFourteenCommandsSurviveDeferredFifteenCommitFaultAndRetry() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(atPath: (f.backup as NSString).deletingLastPathComponent) }
    // Build a genuine published14 source before installing the16 fault; the command value is never
    // seeded in the doomed16 transaction. The existing prefix10 case above remains independent.
    try Migrator.withMigrationLock(f.raw) {
      for file in try Migrator.files() where file.name >= "0011" && file.name < "0015" {
        if file.name == "0011_environments" {
          try EnvironmentHistoryMigrationGuard.apply(
            f.raw,
            file: StoreMigrationResource(name: file.name, bytes: Data(file.sql.utf8)))
        } else {
          try f.raw.execute("BEGIN")
          do {
            try f.raw.execute(file.sql)
            try f.raw.execute(
              #"INSERT INTO "schemaMigrations" (name,"appliedAt") VALUES ($1,'published14-source')"#,
              [file.name])
            try f.raw.execute("COMMIT")
          } catch { try? f.raw.execute("ROLLBACK"); throw error }
        }
      }
    }
    _ = try AgentProtocolFoundationFixture.preservationPrefix(f.raw, expectedCount: 14)
    try f.raw.execute(
      """
      SET b4app.replaying='on';
      INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt",commands)
        VALUES ('retained-commands','codex','Retained','/fixture/codex','{}','ready','authenticated','then','then',
          '[{"name":"retained","unknown":{"n":1e400}}]');
      UPDATE connections SET models='[{"id":"retained-model","n":1e400}]' WHERE id='retained-commands';
      INSERT INTO threads (id,"connectionId","nativeThreadId",model,permission,"createdAt","updatedAt")
        VALUES ('retained-thread','retained-commands','raw-thread','{"id":"picked","n":1e400}',
          '{"mode":"future","unknown":true}','then','then');
      INSERT INTO "viewSettings" (id,arrangement,"quietThreads","showArchived","updatedAt")
        VALUES ('view','byEnvironment','tiny',true,'then');
      RESET b4app.replaying;
      """)
    func rows() throws -> [String: [String]] {
      var result: [String: [String]] = [:]
      for table in try f.raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows
        .compactMap({ $0.text("tablename") })
      {
        result[table] = try f.raw.execute(
          "SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1"
        ).rows.compactMap { $0.text("row") }
      }
      return result
    }
    let before = try rows(), facts = try AgentProtocolFoundationFixture.archiveFacts(f.raw)
    let beforeImages = try archiveImages(f.raw, facts: facts)
    let sourcePrefix = try AgentProtocolFoundationFixture.preservationPrefix(f.raw, expectedCount: 14)
    let density = try AgentProtocolFoundationFixture.densityFacts(f.raw, source: sourcePrefix)
    let sequence = try f.raw.execute(
      #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
    ).rows.first?.text("value")

    let names = Array(AgentProtocolFoundationFixture.migrations.prefix(14))
    let command = try #require(
      try f.raw.execute("SELECT commands::text AS value FROM connections WHERE id='retained-commands'").rows
        .first?.text("value"))
    try f.raw.execute(
      """
      CREATE SCHEMA history_commands_fault;
      CREATE SEQUENCE history_commands_fault.probe;
      CREATE FUNCTION history_commands_fault.refuse_fifteen() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM public.connections WHERE id='retained-commands' AND commands='[{"name":"retained","unknown":{"n":1e400}}]'::jsonb)
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0014_connection_commands' AND "appliedAt"='published14-source')
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0015_density')
          OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
            WHERE t.tgrelid='public."viewSettings"'::regclass AND t.tgname='viewSettingsChanges'
              AND NOT t.tgisinternal AND t.tgtype=29 AND t.tgenabled='O' AND t.tgnargs=1
              AND encode(t.tgargs,'hex')='696400' AND t.tgfoid='public.b4app_record_change()'::regprocedure
              AND p.prosrc LIKE '%''density''%')
          OR NOT EXISTS (SELECT 1 FROM public."viewSettings" WHERE id='view' AND "quietThreads"='shown' AND density='dense')
          OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='viewSettings' AND column_name='density' AND data_type='text' AND is_nullable='YES' AND column_default IS NULL)
          OR to_regclass('public."protocolSubscriptions"') IS NULL
        THEN RAISE EXCEPTION 'Published14 command source and committed15 were not reached'; END IF;
        PERFORM nextval('history_commands_fault.probe');
        RAISE EXCEPTION 'Deliberate16 COMMIT refusal';
      END $$;
      CREATE CONSTRAINT TRIGGER history_commands_fifteen AFTER INSERT ON public."schemaMigrations"
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.name='0016_agent_protocol')
        EXECUTE FUNCTION history_commands_fault.refuse_fifteen();
      """)
    let failed = Result {
      try WorkspaceDatabase(
        endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    }
    if case .success(let db) = failed { try db.close(); Issue.record("Actual16 COMMIT must fail") }
    #expect(throws: WorkspaceError.self) { try failed.get() }
    #expect(
      try f.raw.execute("SELECT last_value::text AS n FROM history_commands_fault.probe WHERE is_called").rows
        .first?.text("n") == "1")
    let committedNames = names + ["0015_density"]
    #expect(try Migrator.recorded(f.raw) == committedNames)
    try AgentProtocolFoundationFixture.requireDensity(
      f.raw, original: density, path: .nativeMigration, targetCount: 15)
    let committedRows = try rows()
    #expect(Set(committedRows.keys) == Set(before.keys))
    for (table, original) in before where table != "schemaMigrations" && table != "viewSettings" {
      #expect(committedRows[table]?.map { Data($0.utf8) } == original.map { Data($0.utf8) })
    }
    let expectedView = try (before["viewSettings"] ?? []).map { text -> String in
      guard var row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let id = row["id"] as? String, let cells = density.rows[id]
      else { throw AgentProtocolFoundationFixture.Failure.row }
      let expected = try AgentProtocolFoundationFixture.expectedDensityCells(
        cells, source: sourcePrefix, path: .nativeMigration)
      for column in ["quietThreads", "density"] {
        guard let cell = expected[column] else { throw AgentProtocolFoundationFixture.Failure.row }
        row[column] = cell.bytes.map { String(decoding: $0, as: UTF8.self) as Any } ?? NSNull()
      }
      return try AgentProtocolFoundationFixture.canonical(row)
    }.sorted()
    let actualView = try (committedRows["viewSettings"] ?? []).map {
      try AgentProtocolFoundationFixture.canonical(JSONSerialization.jsonObject(with: Data($0.utf8)))
    }.sorted()
    #expect(actualView.map { Data($0.utf8) } == expectedView.map { Data($0.utf8) })
    let oldLedger = before["schemaMigrations"] ?? []
    let committedLedger = committedRows["schemaMigrations"] ?? []
    #expect(Set(oldLedger).isSubset(of: Set(committedLedger)) && committedLedger.count == oldLedger.count + 1)
    for table in AgentProtocolFoundationFixture.protocolTables {
      #expect(
        try f.raw.execute("SELECT to_regclass($1)::text AS name", ["public." + Rows.quote(table)])
          .rows.first?.text("name") == nil)
    }
    #expect(
      try f.raw.execute(
        "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='connections' AND column_name='peerProfile'"
      ).rows.isEmpty)
    #expect(
      try f.raw.execute(
        #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
      ).rows.first?.text("value") == sequence)
    let committedFacts = try AgentProtocolFoundationFixture.archiveFacts(f.raw)
    let committedImages = try archiveImages(f.raw, facts: committedFacts)
    let committedDensity = try AgentProtocolFoundationFixture.densityFacts(
      f.raw,
      source: AgentProtocolFoundationFixture.preservationPrefix(f.raw, expectedCount: 15))
    try AgentProtocolFoundationFixture.requireNativeJSONRetained(
      facts,
      after: AgentProtocolFoundationFixture.archiveFacts(f.raw), tables: Array(before.keys))
    let saved = try #require(try archives(f).first)
    let bytes = try Data(contentsOf: saved)
    let document = try AgentProtocolFoundationFixture.readV4(
      String(decoding: bytes, as: UTF8.self),
      expectedRows: before, expectedMigrations: names, facts: facts, canonicalPrefixCount: 14)
    try requireArchiveImages(document, expected: beforeImages)
    #expect(document.rows["connections"]?.first?["commands"] as? String == command)
    #expect(document.header["protocolSchema"] == nil)
    #expect(document.rows["viewSettings"]?.first?["quietThreads"] as? String == "tiny")
    #expect(document.rows["viewSettings"]?.first?["density"] == nil)
    try f.raw.execute("DROP TRIGGER history_commands_fifteen ON public.\"schemaMigrations\"")
    let db = try WorkspaceDatabase(
      endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false, backupDirectory: f.backup)
    try db.close()
    #expect(try Migrator.recorded(f.raw) == AgentProtocolFoundationFixture.migrations)
    let retainedLedger = try f.raw.execute(
      #"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m WHERE name<'0016' ORDER BY name"#
    ).rows.compactMap { $0.text("row") }
    #expect(retainedLedger == committedRows["schemaMigrations"])
    try AgentProtocolFoundationFixture.requireDensity(
      f.raw, original: committedDensity, path: .nativeMigration)
    try AgentProtocolFoundationFixture.requireNativeJSONRetained(
      committedFacts, after: AgentProtocolFoundationFixture.archiveFacts(f.raw),
      tables: Array(committedRows.keys))
    for (table, original) in committedRows where table != "schemaMigrations" {
      let source = try AgentProtocolFoundationFixture.preservationPrefix(committedNames, expectedCount: 15)
      let retained = try AgentProtocolFoundationFixture.projectedRows(
        f.raw, table: table, source: source, originalRows: original)
      #expect(retained.map { Data($0.utf8) } == original.map { Data($0.utf8) })
    }
    #expect(
      try f.raw.execute(
        #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
      ).rows.first?.text("value") == sequence)
    #expect(
      try f.raw.execute("SELECT commands::text AS value FROM connections WHERE id='retained-commands'").rows
        .first?.text("value") == command)
    #expect(try Data(contentsOf: saved) == bytes)
    #expect(try archives(f).count == 2)
    for archive in try archives(f) {
      let mode =
        try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
      #expect(mode?.intValue == 0o600)
    }
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: f.backup)[.posixPermissions] as? NSNumber
    #expect(directoryMode?.intValue == 0o700)

    let retry = try #require(try archives(f).first { $0 != saved })
    let retryDocument = try AgentProtocolFoundationFixture.readV4(
      String(contentsOf: retry, encoding: .utf8), expectedRows: committedRows,
      expectedMigrations: committedNames, facts: committedFacts, canonicalPrefixCount: 15)
    try requireArchiveImages(retryDocument, expected: committedImages)
    #expect(retryDocument.header["protocolSchema"] == nil)
    #expect(retryDocument.rows["viewSettings"]?.first?["quietThreads"] as? String == "shown")
    #expect(retryDocument.rows["viewSettings"]?.first?["density"] as? String == "dense")
    #expect(
      try f.raw.execute("SELECT to_jsonb(c)::text AS value FROM public.changes c WHERE \"rowId\"='opaque'")
        .rows.first?.text("value") == f.opaqueFeed)
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

  @Test(arguments: [
    "0012_agent_protocol", "0013_agent_protocol", "0014_agent_protocol", "0015_agent_protocol",
    "0000_unknown",
  ])
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
