import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

@Suite(.serialized) struct AgentProtocolMainSchemaAdmissionIntegrationTests {
  private typealias F = MainSchemaAdmissionFixture

  @Test func rawMainTenPendingOpenBacksUpOwnedContextBeforeProtocolMigration() throws {
    let fixture = try F.rawMainTen()
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }
    let before = try F.snapshot(fixture.raw)
    #expect(
      try WorkspaceDatabase.preflightMigration(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!) == .pending)
    let db: WorkspaceDatabase
    do {
      // This public open, not the fixture builder, must admit a deployed main10 source.
      db = try WorkspaceDatabase(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!,
        createIfMissing: false, backupDirectory: fixture.backup)
    } catch {
      #expect(try F.snapshot(fixture.raw) == before)
      #expect(try F.archives(fixture.backup).isEmpty)
      throw error  // Preserve the actual required-backup admission failure as the initial RED.
    }
    defer { try? db.close() }
    #expect(try db.appliedMigrations() == F.thirteen)
    try F.assertMainTenRowsRetained(before, after: F.snapshot(fixture.raw))
    try F.assertArchive(
      F.onlyArchive(fixture.backup), source: before, migrations: F.ten,
      dataTables: F.oldTables, purpose: "preMigration")
  }

  @Test func rawMainTenDurabilityWitnessPrecedesProtocolDDL() throws {
    let fixture = try F.rawMainTen()
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }
    let inspector = try F.connection(fixture.endpoint)
    let before = try F.snapshot(inspector)
    let stages = Mutex<[MigrationBackupStage]>([])
    try WorkspaceDatabase.migrateWithBackup(
      fixture.raw, endpoint: fixture.endpoint, backupDirectory: fixture.backup
    ) { stage in
      stages.withLock { $0.append(stage) }
      // Independent connection proves no ledger, row, sequence or catalog mutation before DDL.
      #expect(try F.snapshot(inspector) == before)
      if stage == .directorySynchronized || stage == .willMigrate {
        try F.assertArchive(
          F.onlyArchive(fixture.backup), source: before, migrations: F.ten,
          dataTables: F.oldTables, purpose: "preMigration")
      }
    }
    #expect(
      stages.withLock { $0 } == [
        .locked, .contentsWritten, .fileSynchronized, .renamed, .directorySynchronized, .willMigrate,
      ])
    #expect(try Migrator.recorded(fixture.raw) == F.thirteen)
    try F.assertMainTenRowsRetained(before, after: F.snapshot(inspector))
  }

  @Test func successorPrivateArchiveRoundTripsWithoutInstallingSourceOwnedContext() async throws {
    let root = try F.directory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let source = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    defer { try? source.close() }
    let secrets = MemorySecretStore()
    let endpointReference = SecretRef.make()
    let endpointValue = "MAIN4723_SYNTHETIC_ENDPOINT_VALUE_NOT_IN_ARCHIVE"
    try await secrets.put(endpointReference, value: endpointValue)
    try source.write { try F.seed($0, protocolProfile: true, endpointReference: endpointReference.rawValue) }
    try F.seedPrivate(source)
    let before = try source.read { try F.snapshot($0) }
    for table in F.protocolTables { #expect(before.rows[table]?.count == 1) }
    let path = root + "/current.jsonl"
    // Fresh empty initialization is valid even before the codec integration fix. Export is the RED.
    try source.export(to: path)
    try F.assertArchive(
      path, source: before, migrations: F.thirteen, dataTables: F.allTables, purpose: "onDemand")
    let archiveText = try F.text(path)
    let endpointExcluded = !archiveText.contains(endpointValue)
    let grantRetained = archiveText.contains("MAIN4723_SYNTHETIC_GRANT_MATERIAL")
    let endpointBeforeRestoreUnchanged = try await secrets.read(endpointReference) == endpointValue
    #expect(endpointExcluded)
    #expect(grantRetained)
    #expect(endpointBeforeRestoreUnchanged)

    let targetEndpoint = try AgentProtocolResourceFixture.endpoint()
    let target = try WorkspaceDatabase(endpoint: targetEndpoint, binDir: targetEndpoint.binDir!)
    defer { try? target.close() }
    let targetBefore = try target.read { try F.snapshot($0) }
    #expect(targetBefore.rows["hubLink"]?.isEmpty == true)
    try target.restore(from: path)
    let after = try target.read { try F.snapshot($0) }
    for table in F.allTables {
      let retained = after.rows[table] == before.rows[table]
      #expect(retained, "Restored data differs for table \(table).")
    }
    // Source ledger timestamps, hub account, token reference and ownedAs are context, never replay.
    #expect(after.rows["hubLink"] == targetBefore.rows["hubLink"])
    #expect(after.rows["schemaMigrations"] == targetBefore.rows["schemaMigrations"])
    #expect(after.columns == targetBefore.columns)
    #expect(after.constraints == targetBefore.constraints)
    #expect(after.indexes == targetBefore.indexes)
    #expect(after.triggers == targetBefore.triggers)
    #expect(after.functions == targetBefore.functions)
    #expect(try target.appliedMigrations() == F.thirteen)
    let endpointAfterRestoreUnchanged = try await secrets.read(endpointReference) == endpointValue
    #expect(endpointAfterRestoreUnchanged)
  }
}

/// Independent canonical SQL setup and raw PG/archive oracle; never calls the AP foundation fixture.
private enum MainSchemaAdmissionFixture {
  enum Failure: Error { case missingCanonicalMigration, canonicalMainSchema, archive }
  static let nine = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
  ]
  static let ten = nine + ["0010_owned_rows"]
  static let thirteen = ten + ["0011_environments", "0012_app_folders", "0013_agent_protocol"]
  static let oldTables = [
    "localServers", "projects", "projectFolders", "connections", "threads", "turns", "displayItems",
    "runtimeRequests", "drafts", "devices", "changes", "columnClocks", "settings", "usageReadings",
    "tokenUsage", "connectionUsage", "threadDeletes",
  ]
  static let protocolTables = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]
  static let allTables =
    oldTables.flatMap { table in
      table == "threads"
        ? ["threads", "appFolders"] : [AgentProtocolFoundationFixture.currentTable(old: table)]
    } + protocolTables
  static let apFields = [
    "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt", "protocolRetiredReason",
  ]
  struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let root: String
    var backup: String { root + "/backups" }
  }
  struct Snapshot: Sendable, Equatable {
    var rows: [String: [String]]
    var columns: [String]
    var columnNames: [String: Set<String>]
    var constraints: [String]
    var indexes: [String]
    var triggers: [String]
    var functions: [String]
    var sequences: [String]
  }
  static func directory() throws -> String {
    let path = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "main4723-" + UUID().uuidString
    try PrivateFiles.ensurePrivateDirectory(path)
    return path
  }
  static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }
  static func rawMainTen() throws -> Fixture {
    let root = try directory()
    do {
      let endpoint = try AgentProtocolResourceFixture.endpoint()
      let raw = try connection(endpoint)
      // Names are independently fixed; the unpublished AP0010 is deliberately never applied here.
      let bundled = Dictionary(uniqueKeysWithValues: try Migrator.files().map { ($0.name, $0.sql) })
      try Migrator.ensureLedger(raw, table: "schemaMigrations")
      for name in ten {
        guard let sql = bundled[name] else { throw Failure.missingCanonicalMigration }
        try raw.execute(sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,'main10-fixed')"#, [name])
      }
      try seed(raw, protocolProfile: false, endpointReference: "secret:retained-endpoint-reference")
      guard try Migrator.recorded(raw) == ten,
        Set(
          try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap {
            $0.text("tablename")
          })
          == Set(oldTables + ["schemaMigrations", "hubLink"]),
        try raw.execute(#"SELECT "ownedAs" FROM "hubLink""#).rows.first?.text("ownedAs") == "source-owner"
      else { throw Failure.canonicalMainSchema }
      return Fixture(endpoint: endpoint, raw: raw, root: root)
    } catch {
      try? FileManager.default.removeItem(atPath: root)
      throw error
    }
  }
  static func seed(_ c: PostgresConnection, protocolProfile: Bool, endpointReference: String) throws {
    try c.execute(
      #"INSERT INTO "projects" ("id","name","manual","createdAt","updatedAt") VALUES ('project','Retained',true,'created','updated'); INSERT INTO "projectFolders" ("id","projectId","path","createdAt") VALUES ('folder','project','/fixture/project','created')"#
    )
    if protocolProfile {
      try c.execute(
        #"INSERT INTO "connections" ("id","kind","label","target","authReference","nativeScope","capabilities","status","authStatus","peerProfile","agentId","authMode","createdAt","updatedAt") VALUES ('connection','agentProtocol','Profile','https://example.invalid/source',$1,'native-scope','{}','ready','authenticated','b4','fixture-agent','bearer','created','updated')"#,
        [endpointReference])
    } else {
      try c.execute(
        #"INSERT INTO "connections" ("id","kind","label","target","authReference","nativeScope","capabilities","status","authStatus","createdAt","updatedAt") VALUES ('connection','b4','Historical','https://example.invalid/source',$1,'native-scope','{}','ready','authenticated','created','updated')"#,
        [endpointReference])
    }
    try c.execute(
      """
      INSERT INTO "connections" ("id","kind","label","target","nativeScope","capabilities","status","authStatus","createdAt","updatedAt") VALUES
        ('codex','codex','Codex','/fixture/codex','codex-scope','{}','ready','authenticated','created','updated'),
        ('claude','claude','Claude','/fixture/claude','claude-scope','{}','ready','authenticated','created','updated');
      INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","projectId","readTurnId","createdAt","updatedAt")
        VALUES ('thread','connection','native-thread','native-scope','project','turn','created','updated');
      INSERT INTO "turns" ("id","threadId","operationId","nativeTurnId","status","submission","outcome","createdAt","updatedAt")
        VALUES ('turn','thread','operation','native-turn','reconciling','unknown',NULL,'created','updated');
      INSERT INTO "displayItems" ("id","threadId","turnId","nativeItemId","role","type","payload","sequence","provenance","createdAt")
        VALUES ('item','thread','turn','native-item','assistant','agentMessage','{"text":"retained 🌱","opaque":[true,null,9007199254740993]}',0,'cache','created');
      INSERT INTO "runtimeRequests" ("id","nativeRequestId","threadId","turnId","adapterGeneration","kind","state","payload","createdAt","updatedAt")
        VALUES ('request','7','thread','turn',1,'command_approval','pending','{"opaque":true}','created','updated');
      INSERT INTO "drafts" ("threadId","text","updatedAt") VALUES ('thread','Unsent retained draft','updated');
      INSERT INTO "hubLink" ("id","url","deviceId","deviceName","tokenRef","orgSlug","username","cursor","joinedAt","ownedAs")
        VALUES (1,'https://hub.example.invalid','source-device','Source device','secret:source-hub-reference','fixture','fixture-user',19,'joined','source-owner');
      """)
  }
  static func seedPrivate(_ db: WorkspaceDatabase) throws {
    let owner = ProtocolGrantSecretStore.Owner(connectionId: "connection", threadId: "thread")
    let reference = try #require(SecretRef(rawValue: "secret:main4723-grant"))
    try ProtocolGrantSecretStore.transaction(database: db, owner: owner) { c, store in
      try store.put("MAIN4723_SYNTHETIC_GRANT_MATERIAL", reference: reference)
      try c.execute(
        #"INSERT INTO "protocolSubscriptions" ("threadId","connectionId","nativeThreadId","generation","channels","namespaces","appliedEventId","appliedSeq","coverage","updatedAt") VALUES ('thread','connection','native-thread','generation','["messages"]','[[]]','event',17,'{"opaque":true}','updated')"#
      )
      try c.execute(
        #"INSERT INTO "protocolRunSegments" ("connectionId","threadId","identityEpochKind","identityEpochId","namespace","nativeRunId","rootRunId","localTurnId","facts","updatedAt") VALUES ('connection','thread','b4','generation','[]','run','run','turn','{"opaque":[true,null]}','updated')"#
      )
      try c.execute(
        #"INSERT INTO "protocolOperations" ("operationId","connectionId","threadId","kind","operationThreadId","payload","grantReferences","expectations","fingerprint","status","createdAt","updatedAt") VALUES ('private-operation','connection','thread','fixture','native-thread','{"opaque":true}','["secret:main4723-grant"]','{"opaque":true}','fingerprint','prepared','created','updated')"#
      )
      try c.execute(
        #"INSERT INTO "protocolGrants" ("threadId","pausedGeneration","namespace","interruptId","proposalHash","connectionId","grantReference","disposition","updatedAt") VALUES ('thread','generation','[]','interrupt','proposal','connection','secret:main4723-grant','allow','updated')"#
      )
      try c.execute(
        #"INSERT INTO "protocolPromptAnswers" ("threadId","pausedGeneration","namespace","interruptId","proposalHash","connectionId","answer","status","updatedAt") VALUES ('thread','generation','[]','interrupt','proposal','connection','null','answered','updated')"#
      )
      try c.execute(
        #"INSERT INTO "protocolHistoryAnchors" ("threadId","generation","anchor","connectionId","coverage","revision","nextBefore","updatedAt") VALUES ('thread','generation','anchor','connection','{"opaque":true}','revision',NULL,'updated')"#
      )
    }
  }
  static func canonical(_ object: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }
  static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    let tables = try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
      .rows.compactMap { $0.text("tablename") }
    let columnRows = try c.execute(
      "SELECT table_name,column_name,data_type,is_nullable,coalesce(column_default,'') AS def FROM information_schema.columns WHERE table_schema='public' ORDER BY table_name,column_name"
    ).rows
    var names: [String: Set<String>] = [:], json: [String: [String]] = [:]
    for row in columnRows {
      let table = try #require(row.text("table_name")), column = try #require(row.text("column_name"))
      names[table, default: []].insert(column)
      if ["json", "jsonb"].contains(row.text("data_type") ?? "") { json[table, default: []].append(column) }
    }
    var rows: [String: [String]] = [:]
    for table in tables {
      var expression = "to_jsonb(t)"
      // Match the documented archive representation independently: json/jsonb cells are SQL text.
      for column in json[table] ?? [] {
        expression += " || jsonb_build_object('\(column)',to_jsonb(t.\(Rows.quote(column))::text))"
      }
      rows[table] = try c.execute(
        "SELECT (\(expression))::text AS row FROM \(Rows.quote(table)) t ORDER BY 1"
      ).rows.map {
        try canonical(JSONSerialization.jsonObject(with: Data(try #require($0.text("row")).utf8)))
      }.sorted()
    }
    func facts(_ sql: String) throws -> [String] { try c.execute(sql).rows.compactMap { $0.text("fact") } }
    let columns = try columnRows.map { row in
      try ["table_name", "column_name", "data_type", "is_nullable", "def"].map { try #require(row.text($0)) }
        .joined(separator: ":")
    }
    var sequences: [String] = []
    for name in try c.execute(
      "SELECT sequencename FROM pg_sequences WHERE schemaname='public' ORDER BY sequencename"
    ).rows.compactMap({ $0.text("sequencename") }) {
      let row = try #require(
        try c.execute("SELECT last_value::text AS value,is_called::text AS called FROM \(Rows.quote(name))")
          .rows.first)
      sequences.append(name + ":" + (row.text("value") ?? "NULL") + ":" + (row.text("called") ?? "NULL"))
    }
    return Snapshot(
      rows: rows, columns: columns, columnNames: names,
      constraints: try facts(
        "SELECT t.relname||':'||c.conname||':'||pg_get_constraintdef(c.oid) AS fact FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname='public' ORDER BY 1"
      ),
      indexes: try facts(
        "SELECT tablename||':'||indexname||':'||indexdef AS fact FROM pg_indexes WHERE schemaname='public' ORDER BY 1"
      ),
      triggers: try facts(
        "SELECT t.relname||':'||g.tgname||':'||pg_get_triggerdef(g.oid) AS fact FROM pg_trigger g JOIN pg_class t ON t.oid=g.tgrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname='public' AND NOT g.tgisinternal ORDER BY 1"
      ),
      functions: try facts(
        "SELECT p.proname||':'||pg_get_functiondef(p.oid) AS fact FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' ORDER BY 1"
      ), sequences: sequences)
  }
  static func assertMainTenRowsRetained(_ before: Snapshot, after: Snapshot) throws {
    #expect(Set(after.rows.keys) == Set(allTables + ["schemaMigrations", "hubLink"]))
    for table in oldTables + ["hubLink"] {
      let currentTable = AgentProtocolFoundationFixture.currentTable(old: table)
      let rows = try #require(after.rows[currentTable]).map { text -> String in
        var row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if table == "connections" {
          for field in apFields { #expect(row[field] is NSNull); row.removeValue(forKey: field) }
        }
        // Normalize only the spelling of SQL-text JSON. Current schema names must already be exact.
        if table == "changes", row["op"] as? String == "insert",
          ["connections", "threads", "environmentFolders"].contains(row["table"] as? String ?? ""),
          let value = row["value"] as? String,
          let image = try JSONSerialization.jsonObject(
            with: Data(value.utf8), options: [.fragmentsAllowed]) as? [String: Any]
        {
          row["value"] = try canonical(image)
        }
        return try canonical(row)
      }.sorted()
      let expected = try #require(before.rows[table]).map { text -> String in
        let row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try canonical(
          AgentProtocolFoundationFixture.currentRow(table: table, row: row, jsonColumnsAsText: true))
      }.sorted()
      #expect(rows == expected)
    }
    let oldLedger = try #require(before.rows["schemaMigrations"])
    let newLedger = try #require(after.rows["schemaMigrations"])
    #expect(Set(oldLedger).isSubset(of: Set(newLedger)))
    #expect(newLedger.count == oldLedger.count + 3)
    let addedNames = try Set(newLedger).subtracting(oldLedger).map { text in
      let row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
      return try #require(row["name"] as? String)
    }
    #expect(Set(addedNames) == Set(["0011_environments", "0012_app_folders", "0013_agent_protocol"]))
    #expect(after.sequences == before.sequences)
    for table in protocolTables { #expect(after.rows[table]?.isEmpty == true) }
    #expect(after.rows["appFolders"]?.isEmpty == true)
  }
  static func archives(_ directory: String) throws -> [String] {
    guard FileManager.default.fileExists(atPath: directory) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".jsonl") }
      .map { directory + "/" + $0 }.sorted()
  }
  static func onlyArchive(_ directory: String) throws -> String {
    let paths = try archives(directory)
    #expect(paths.count == 1)
    return try #require(paths.first)
  }
  static func text(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
  static func assertArchive(
    _ path: String, source: Snapshot, migrations: [String], dataTables: [String], purpose: String
  ) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.last == 0x0a else { throw Failure.archive }
    let pieces = data.split(separator: 0x0a, omittingEmptySubsequences: false)
    guard pieces.count >= 3, pieces.last?.isEmpty == true,
      pieces.dropLast().allSatisfy({ !$0.isEmpty })
    else { throw Failure.archive }
    var lines = pieces.dropLast().map { Data($0) }
    func object(_ bytes: Data) throws -> [String: Any] {
      guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
        throw Failure.archive
      }
      return value
    }
    let header = try object(lines.removeFirst()), footer = try object(lines.removeLast())
    var headerFields: Set<String> = [
      "format", "version", "at", "purpose", "migrations", "requiredTables", "sourceContextTables",
    ]
    if migrations.count == 13 {
      headerFields.insert("protocolSchema")
      #expect(header["protocolSchema"] as? String == "generation_epochs_v1")
    }
    #expect(Set(header.keys) == headerFields)
    #expect(Set(footer.keys) == Set(["format", "version", "rows", "tableRows"]))
    #expect(header["format"] as? String == "b4app-export")
    #expect(header["version"] as? Int == 4)
    #expect(header["purpose"] as? String == purpose)
    #expect(header["migrations"] as? [String] == migrations)
    #expect(header["requiredTables"] as? [String] == dataTables)
    #expect(header["sourceContextTables"] as? [String] == ["schemaMigrations", "hubLink"])
    #expect(footer["format"] as? String == "b4app-export-end")
    #expect(footer["version"] as? Int == 4)
    #expect(footer["rows"] as? Int == lines.count)
    var actual = Dictionary(uniqueKeysWithValues: source.rows.keys.map { ($0, [String]()) })
    for bytes in lines {
      let line = try object(bytes)
      let table = try #require(line["table"] as? String), row = try #require(line["row"] as? [String: Any])
      #expect(Set(row.keys) == source.columnNames[table])
      actual[table, default: []].append(try canonical(row))
    }
    for table in actual.keys { actual[table]?.sort() }
    let completeRowsMatch = actual == source.rows
    #expect(completeRowsMatch, "Archive data and source context must match the independent raw snapshot.")
    #expect(footer["tableRows"] as? [String: Int] == source.rows.mapValues { $0.count })
    let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }
}
