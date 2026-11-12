import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Existing storage admission/capture APIs only. No service, runtime, listener, hub or owner data.
@Suite(.serialized) struct AgentProtocolPrivateBackupTests {
  private static let legacyDataTables = [
    "localServers", "projects", "projectFolders", "connections", "threads", "turns", "displayItems",
    "runtimeRequests", "drafts", "devices", "changes", "columnClocks", "settings", "usageReadings",
    "tokenUsage", "connectionUsage", "threadDeletes", "protocolSubscriptions", "protocolRunSegments",
    "protocolOperations", "protocolGrantSecrets", "protocolGrants", "protocolPromptAnswers",
    "protocolHistoryAnchors",
  ]
  private static let dataTables =
    ["viewSettings"]
    + legacyDataTables.flatMap { table in
      table == "threads"
        ? ["threads", "appFolders"] : [AgentProtocolFoundationFixture.currentTable(old: table)]
    }
  private static let contextTables = [Migrator.table, "hubLink"]
  private static let canonicalNine = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay", "0006_usage",
    "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
  ]
  private static let stamp = "2026-11-09T00:00:00.000Z"
  private static let generation = "22222222-2222-4222-8222-222222222222"
  private static let native = "11111111-1111-4111-8111-111111111111"
  private static let interrupt = "33333333-3333-4333-8333-333333333333"
  private static let backupMessage =
    "The required pre-migration backup could not be saved. The existing database was not migrated."
  private enum FixtureFailure: Error {
    case unexpectedSchema, invalidRecord, unhandledPrivateFailure, boundaryFault
  }
  private struct AuthorityFault: Error, CustomStringConvertible {
    let privateValue: String
    var description: String { privateValue }
  }
  private struct Snapshot: Sendable, Equatable {
    let rows: [String: [String]]
    let catalog: [String]
    let sequences: [String]
    let jsonColumns: [String: Set<String>]
    let encodedJsonCells: [String: [String]]
  }
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let root: String
    let backup: String
    let material: String
    let endpointReference: SecretRef
    let endpointValue: String
    let endpointSecrets: MemorySecretStore
    let before: Snapshot
  }
  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }
  private static func withFixture(
    current: Bool, _ body: @Sendable (Fixture) async throws -> Void
  ) async throws {
    // Strict source intent/live helper+postmaster identity/independent ACK happens before fixture SQL.
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-private-backup-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root);
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let raw = try connection(endpoint)
    defer {
      let noBackends =
        (try? raw.execute(
          "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'", [endpoint.database]
        ).rows.isEmpty) == true
      #expect(noBackends)
    }
    let supported = try raw.execute(
      "SELECT current_setting('server_version_num') AS version,current_setting('is_superuser') AS privileged"
    ).rows.first
    guard supported?.text("version") == "170011", supported?.text("privileged") == "on"
    else { throw FixtureFailure.unexpectedSchema }
    let secrets = MemorySecretStore(), reference = SecretRef.make()
    let endpointValue = "A3_ENDPOINT_PRIVATE_\(UUID())"
    try await secrets.put(reference, value: endpointValue)
    let material = "A3_GRANT_PRIVATE_\(UUID()) opaque 🌱 e\u{301}\r\nquoted \"text\" \\ tail\t "
    var database: WorkspaceDatabase?
    defer { try? database?.close() }
    if current {
      database = try WorkspaceDatabase(
        endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/setup")
    } else {
      let files = try Migrator.files().filter { $0.name <= "0009_thread_runtime_choice" }
      guard files.map(\.name) == canonicalNine else { throw FixtureFailure.unexpectedSchema }
      try Migrator.ensureLedger(raw, table: Migrator.table)
      for file in files {
        try raw.execute(file.sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,$2)"#,
          [file.name, "source-applied-" + file.name])
      }
    }
    try seedOldTables(raw, endpointReference: reference, protocolProfiles: current)
    if let database {
      try raw.execute(
        #"SET b4app.replaying='on'; INSERT INTO "viewSettings" ("id","arrangement","quietThreads","showArchived","updatedAt") VALUES ('view','future-arrangement','future-quiet',true,'source-view'); RESET b4app.replaying"#
      )
      for suffix in ["a", "b"] {
        try seedPrivate(database, suffix: suffix, material: material + " owner-" + suffix)
      }
      // Every setup write is synchronous and complete. Close pool admission/idle connections before
      // raw snapshot capture; no account/service/network quiescence is claimed by this fixture.
      try database.close()
    }
    let expectedTables = Set(
      ((current ? dataTables : legacyDataTables) + contextTables).filter {
        current || !$0.hasPrefix("protocol")
      })
    let actualTables = Set(
      try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
        .rows.compactMap { $0.text("tablename") })
    guard actualTables == expectedTables else { throw FixtureFailure.unexpectedSchema }
    let before = try snapshot(raw)
    guard before.rows.values.allSatisfy({ !$0.isEmpty }) else { throw FixtureFailure.unexpectedSchema }
    let fixture = Fixture(
      endpoint: endpoint, raw: raw, root: root, backup: root + "/backups/" + endpoint.database,
      material: material, endpointReference: reference, endpointValue: endpointValue,
      endpointSecrets: secrets, before: before)
    var failure: (any Error)?
    do { try await body(fixture) } catch {
      let text = String(describing: error)
      if containsPrivate(text) {
        Issue.record("An unhandled private error was refused without printing its value.");
        failure = FixtureFailure.unhandledPrivateFailure
      } else {
        failure = error
      }
    }
    let endpointUnchanged = try await secrets.read(reference) == endpointValue
    #expect(endpointUnchanged)
    if let failure { throw failure }
  }
  private static func seedOldTables(
    _ c: PostgresConnection, endpointReference: SecretRef, protocolProfiles: Bool
  ) throws {
    // The raw-nine branch still seeds the historical project schema.
    let environmentTable = protocolProfiles ? "environments" : "projects"
    let foldersTable = protocolProfiles ? "environmentFolders" : "projectFolders"
    let referenceColumn = protocolProfiles ? "environmentId" : "projectId"
    try c.execute(
      """
      INSERT INTO "localServers" ("id","name","projectPath","nodePath","cliPath","launchMode","health","routes","createdAt","updatedAt")
        VALUES ('server','Fixture server','/fixture/project','/fixture/node','/fixture/cli','source','offline','[]','created','updated');
      INSERT INTO "\(environmentTable)" ("id","name","manual","createdAt","updatedAt") VALUES ('project','Retained project',true,'created','updated');
      INSERT INTO "\(foldersTable)" ("id","\(referenceColumn)","path","createdAt") VALUES ('folder','project','/fixture/project','created');
      """)
    for suffix in ["a", "b", "legacy", "codex", "claude"] {
      let kind = suffix == "codex" || suffix == "claude" ? suffix : "b4"
      if protocolProfiles && (suffix == "a" || suffix == "b") {
        try c.execute(
          #"INSERT INTO "connections" ("id","kind","label","target","localServerId","authReference","nativeScope","\#(referenceColumn)","capabilities","status","authStatus","peerProfile","agentId","authMode","createdAt","updatedAt") VALUES ($1,'agentProtocol',$2,'https://example.invalid/prefix','server',$3,$4,'project','{}','ready','authenticated','agentProtocol','fixture-agent','bearer','created','updated')"#,
          ["connection-" + suffix, "Fresh " + suffix, endpointReference.rawValue, "fixture-scope-" + suffix])
      } else {
        try c.execute(
          #"INSERT INTO "connections" ("id","kind","label","target","localServerId","authReference","nativeScope","\#(referenceColumn)","capabilities","status","authStatus","createdAt","updatedAt") VALUES ($1,$2,$3,'https://example.invalid/prefix','server',$4,$5,'project','{}','ready','authenticated','created','updated')"#,
          [
            "connection-" + suffix, kind, "Retained " + suffix, endpointReference.rawValue,
            "fixture-scope-" + suffix,
          ])
      }
    }
    for suffix in ["a", "b"] {
      try c.execute(
        #"INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","title","\#(referenceColumn)","readTurnId","pinned","archived","userDeletedAt","createdAt","updatedAt") VALUES ($1,$2,$3,$4,'Cached history','project',$5,true,true,'deleted','created','updated')"#,
        ["thread-" + suffix, "connection-" + suffix, native, "fixture-scope-" + suffix, "turn-" + suffix])
      try c.execute(
        #"INSERT INTO "turns" ("id","threadId","operationId","nativeTurnId","status","submission","outcome","createdAt","updatedAt") VALUES ($1,$2,$3,'1','reconciling','unknown',NULL,'created','updated')"#,
        ["turn-" + suffix, "thread-" + suffix, "operation-" + suffix])
      try c.execute(
        #"INSERT INTO "displayItems" ("id","threadId","turnId","nativeItemId","role","type","payload","sequence","provenance","createdAt") VALUES ($1,$2,$3,'item','assistant','agentMessage','{"text":"partial 🌱","opaque":[true,null,3.25]}',0,'cache','created')"#,
        ["item-" + suffix, "thread-" + suffix, "turn-" + suffix])
      try c.execute(
        #"INSERT INTO "runtimeRequests" ("id","nativeRequestId","threadId","turnId","adapterGeneration","kind","state","payload","createdAt","updatedAt") VALUES ($1,'7',$2,$3,1,'command_approval','pending','{"command":"fixture"}','created','updated')"#,
        ["request-" + suffix, "thread-" + suffix, "turn-" + suffix])
      try c.execute(
        #"INSERT INTO "drafts" ("threadId","text","updatedAt") VALUES ($1,'Unsent draft','updated')"#,
        ["thread-" + suffix])
    }
    try c.execute(
      """
      INSERT INTO "devices" ("id","name","createdAt") VALUES ('device','Retained device','created');
      INSERT INTO "hubLink" ("id","url","deviceId","deviceName","tokenRef","orgSlug","username","cursor","joinedAt")
        VALUES (1,'https://hub.example.invalid','device','Retained device','secret:source-hub','fixture','fixture-user',19,'joined');
      INSERT INTO "settings" ("key","value") VALUES ('fixture','{"opaque":[null,true,"choice"]}');
      INSERT INTO "usageReadings" ("connectionId","reading","observedAt") VALUES ('connection-a','opaque-plan-reading','observed');
      INSERT INTO "tokenUsage" ("turnId","connectionId","recordedAt","totalTokens") VALUES ('turn-a','connection-a','recorded',9);
      INSERT INTO "connectionUsage" ("connectionId","reading","tokens","updatedAt") VALUES ('connection-a','null','{"opaque":true}','updated');
      INSERT INTO "threadDeletes" ("threadId","state","attempts","nextAttemptAt","lastError","updatedAt")
        VALUES ('thread-a','waiting',3,'later','Historical unknown','updated');
      """)
    if protocolProfiles {
      // A D203 app-folder thread has no environment. Keep every current table populated without
      // changing the genuine pre13 source rows or assigning the folder to an environment thread.
      try c.execute(
        """
        INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","title","context",
          "environmentId","createdAt","updatedAt") VALUES
          ('app-folder-thread','connection-codex','app-folder-native','fixture-app-folder','App folder',
           '/fixture/private-app-folder',NULL,'created','updated');
        INSERT INTO "appFolders" ("path","threadId","createdAt") VALUES
          ('/fixture/private-app-folder','app-folder-thread','created');
        """)
    }
  }
  private static func seedPrivate(_ db: WorkspaceDatabase, suffix: String, material: String) throws {
    let owner = ProtocolGrantSecretStore.Owner(
      connectionId: "connection-" + suffix, threadId: "thread-" + suffix)
    let reference = SecretRef.make()
    try ProtocolGrantSecretStore.transaction(database: db, owner: owner) { c, store in
      try store.put(material, reference: reference)
      try c.execute(
        #"INSERT INTO "protocolSubscriptions" ("threadId","connectionId","nativeThreadId","generation","channels","namespaces","appliedEventId","appliedSeq","coverage","updatedAt") VALUES ($1,$2,$3,$4,'["messages"]','[[],["branch"]]','event',17,'{"opaque":true}',$5)"#,
        [owner.threadId, owner.connectionId, native, generation, stamp])
      try c.execute(
        #"INSERT INTO "protocolRunSegments" ("connectionId","threadId","identityEpochKind","identityEpochId","namespace","nativeRunId","rootRunId","localTurnId","facts","updatedAt") VALUES ($1,$2,'b4',$6,'[]',$3,$3,$4,'{"opaque":[1,true,null]}',$5)"#,
        [owner.connectionId, owner.threadId, native, "turn-" + suffix, stamp, generation])
      try c.execute(
        #"INSERT INTO "protocolOperations" ("operationId","connectionId","threadId","kind","operationThreadId","payload","grantReferences","expectations","fingerprint","status","createdAt","updatedAt") VALUES ($1,$2,$3,'fixture-kind',$4,'{"opaque":[true,null,"text"]}',$5::jsonb,'{"opaque":true}','fixture-fingerprint','fixture-status',$6,$6)"#,
        [
          "protocol-operation-" + suffix, owner.connectionId, owner.threadId, native,
          String(decoding: try JSONCoding.encoder.encode([reference.rawValue]), as: UTF8.self), stamp,
        ])
      try c.execute(
        #"INSERT INTO "protocolGrants" ("threadId","pausedGeneration","namespace","interruptId","proposalHash","connectionId","grantReference","disposition","updatedAt") VALUES ($1,$2,'[]',$3,'fixture-proposal',$4,$5,'fixture-disposition',$6)"#,
        [owner.threadId, generation, interrupt, owner.connectionId, reference.rawValue, stamp])
      try c.execute(
        #"INSERT INTO "protocolPromptAnswers" ("threadId","pausedGeneration","namespace","interruptId","proposalHash","connectionId","answer","status","updatedAt") VALUES ($1,$2,'[]',$3,'fixture-proposal',$4,'null','fixture-status',$5)"#,
        [owner.threadId, generation, interrupt, owner.connectionId, stamp])
      try c.execute(
        #"INSERT INTO "protocolHistoryAnchors" ("threadId","generation","anchor","connectionId","coverage","revision","nextBefore","updatedAt") VALUES ($1,$2,'opaque-anchor',$3,'{"opaque":[]}','opaque-revision',NULL,$4)"#,
        [owner.threadId, generation, owner.connectionId, stamp])
    }
  }
  private static func canonical(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
  }
  private static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    // TEST-ONLY expected-state capture includes raw private rows. These strings never enter Testing
    // macros, logs or public JSON; every equality below is computed into a Boolean first.
    var rows: [String: [String]] = [:], json: [String: Set<String>] = [:]
    for row in try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
      .rows
    {
      guard let table = row.text("tablename") else { throw FixtureFailure.invalidRecord }
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
        .rows.map {
          guard let text = $0.text("row") else { throw FixtureFailure.invalidRecord }
          return try canonical(JSONSerialization.jsonObject(with: Data(text.utf8)))
        }.sorted()
    }
    var catalog: [String] = []
    for sql in [
      "SELECT 'column:'||table_name||':'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'') AS fact FROM information_schema.columns WHERE table_schema='public'",
      "SELECT 'constraint:'||r.relname||':'||c.conname||':'||pg_get_constraintdef(c.oid) AS fact FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public'",
      "SELECT 'index:'||tablename||':'||indexname||':'||indexdef AS fact FROM pg_indexes WHERE schemaname='public'",
      "SELECT 'function:'||p.proname||':'||pg_get_functiondef(p.oid) AS fact FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f'",
      "SELECT 'trigger:'||r.relname||':'||t.tgname||':'||pg_get_triggerdef(t.oid) AS fact FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal",
    ] { catalog += try c.execute(sql).rows.compactMap { $0.text("fact") } }
    var sequences: [String] = []
    for row in try c.execute("SELECT sequencename FROM pg_sequences WHERE schemaname='public'").rows {
      guard let name = row.text("sequencename"),
        let state = try c.execute(
          "SELECT last_value::text AS value,is_called::text AS called FROM \(Rows.quote(name))"
        ).rows.first
      else { throw FixtureFailure.invalidRecord }
      sequences.append(name + ":" + (state.text("value") ?? "NULL") + ":" + (state.text("called") ?? "NULL"))
    }
    for row in try c.execute(
      "SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public' AND data_type IN ('json','jsonb')"
    ).rows {
      guard let table = row.text("table_name"), let column = row.text("column_name") else {
        throw FixtureFailure.invalidRecord
      }
      json[table, default: []].insert(column)
    }
    var encodedJsonCells: [String: [String]] = [:]
    for (table, columns) in json {
      encodedJsonCells[table] = try c.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows.map {
        row in
        var cells: [String: Any] = [:]
        for column in columns {
          // SQL NULL is NSNull; a JSON null is the non-nil PostgreSQL text "null". This extra
          // representation oracle is independent of to_jsonb(row), which conflates the two.
          cells[column] = row.text(column).map { $0 as Any } ?? NSNull()
        }
        return try canonical(cells)
      }.sorted()
    }
    return Snapshot(
      rows: rows, catalog: catalog.sorted(), sequences: sequences.sorted(), jsonColumns: json,
      encodedJsonCells: encodedJsonCells)
  }
  private static func archives(_ directory: String) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "jsonl" }
  }
  private static func containsPrivate(_ text: String) -> Bool {
    text.contains("A3_GRANT_PRIVATE_") || text.contains("A3_ENDPOINT_PRIVATE_")
  }
  private static func assertArchive(_ f: Fixture) throws {
    let files = try archives(f.backup)
    #expect(files.count == 1)
    guard let file = files.first else { return }
    let bytes = try Data(contentsOf: file)
    let text = String(decoding: bytes, as: UTF8.self)
    let endpointExcluded = !text.contains(f.endpointValue)
    #expect(endpointExcluded)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first,
      let header = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
    else { throw FixtureFailure.invalidRecord }
    let version4 = header["version"] as? Int == 4
    #expect(version4)
    let purpose = header["purpose"] as? String == "preMigration"
    #expect(purpose)
    let migrations = try Migrator.recorded(f.raw)
    if migrations.count == 14 {
      #expect(header["protocolSchema"] as? String == "generation_epochs_v1")
    } else {
      #expect(header["protocolSchema"] == nil)
    }
    let sourceNamesMatch = header["migrations"] as? [String] == migrations
    #expect(sourceNamesMatch)
    let sourceDataTables = migrations.count >= 11 ? dataTables : legacyDataTables
    let wantedData = Set(sourceDataTables.filter { f.before.rows[$0] != nil })
    let wantedContext = Set(contextTables.filter { f.before.rows[$0] != nil })
    let dataManifest = Set(header["requiredTables"] as? [String] ?? []) == wantedData
    let contextManifest = Set(header["sourceContextTables"] as? [String] ?? []) == wantedContext
    #expect(dataManifest); #expect(contextManifest)
    var decoded: [String: [String]] = [:], actualCounts: [String: Int] = [:]
    var encodedJsonCells: [String: [String]] = [:]
    var footer: [String: Any]?, footerIndex: Int?
    for (index, line) in lines.dropFirst().enumerated() where !line.isEmpty {
      guard let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { throw FixtureFailure.invalidRecord }
      if record["format"] as? String == "b4app-export-end" {
        let onlyFooter = footer == nil
        #expect(onlyFooter)
        footer = record; footerIndex = index + 1; continue
      }
      guard let table = record["table"] as? String, var row = record["row"] as? [String: Any]
      else { throw FixtureFailure.invalidRecord }
      let declared = wantedData.union(wantedContext).contains(table)
      #expect(declared)
      if let columns = f.before.jsonColumns[table] {
        var cells: [String: Any] = [:]
        for column in columns { cells[column] = row[column] ?? NSNull() }
        encodedJsonCells[table, default: []].append(try canonical(cells))
      }
      for column in f.before.jsonColumns[table] ?? [] {
        guard let value = row[column], !(value is NSNull) else { continue }
        guard let json = value as? String else { throw FixtureFailure.invalidRecord }
        row[column] = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
      }
      decoded[table, default: []].append(try canonical(row)); actualCounts[table, default: 0] += 1
    }
    let allRowsCount = decoded.values.reduce(0) { $0 + $1.count }
    let countMatches = allRowsCount == f.before.rows.values.reduce(0) { $0 + $1.count }
    #expect(countMatches)
    for (table, expected) in f.before.rows {
      let valuesMatch = (decoded[table] ?? []).sorted() == expected
      #expect(valuesMatch, "Exact archived values differ for \(table)")
    }
    for (table, expected) in f.before.encodedJsonCells {
      let nullAndJsonRepresentationsMatch = (encodedJsonCells[table] ?? []).sorted() == expected
      #expect(nullAndJsonRepresentationsMatch, "SQL NULL/JSON text representation differs for \(table)")
    }
    let footerPresent = footer != nil
    #expect(footerPresent)
    if let footer {
      let total = footer["rows"] as? Int == allRowsCount
      let tableCounts = footer["tableRows"] as? [String: Int] == actualCounts
      let footerVersion = footer["version"] as? Int == 4
      let finalNewline = bytes.last == 0x0a && footerIndex == lines.count - 2
      #expect(total); #expect(tableCounts); #expect(footerVersion); #expect(finalNewline)
    }
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: f.backup)[.posixPermissions] as? NSNumber
    #expect(fileMode?.intValue == 0o600); #expect(directoryMode?.intValue == 0o700)
  }
  private static func capture(_ f: Fixture) throws {
    try f.raw.execute("SELECT pg_advisory_lock($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
    defer {
      try? f.raw.execute(
        "SELECT pg_advisory_unlock($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
    }
    try WorkspaceDatabase.backupBeforeMigration(f.raw, endpoint: f.endpoint, directory: f.backup)
  }
  private static func assertSafe(_ error: any Error) throws {
    let normalized = WorkspaceError.from(error)
    let code = normalized.code == .internalError
    let message = normalized.message == backupMessage
    let details = normalized.details == nil
    let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
    let bytes = try JSONCoding.encoder.encode(ResponseEnvelope.failure("private-backup", error: normalized))
    let noPrivate =
      !containsPrivate(String(decoding: bytes, as: UTF8.self))
      && !containsPrivate(String(reflecting: error))
      && !containsPrivate(String(describing: (error as NSError).userInfo))
    #expect(code); #expect(message); #expect(details); #expect(cause); #expect(noPrivate)
  }

  @Test func preMigrationCaptureRetainsAllPrivateAuthorityAndSourceLedger() async throws {
    try await Self.withFixture(current: true) { f in
      try Self.capture(f)
      try Self.assertArchive(f)
      let sourceUnchanged = try Self.snapshot(f.raw) == f.before
      #expect(sourceUnchanged)
    }
  }

  @Test func genuineOldNineBackupIsCompleteBeforeDdlAndBoundaryFaultsRefuse() async throws {
    for fault in [MigrationBackupStage.contentsWritten, .fileSynchronized, .renamed] {
      try await Self.withFixture(current: false) { f in
        let stages = Mutex<[MigrationBackupStage]>([])
        var error: (any Error)?
        do {
          try WorkspaceDatabase.migrateWithBackup(f.raw, endpoint: f.endpoint, backupDirectory: f.backup) {
            stage in
            stages.withLock { $0.append(stage) }
            if stage == fault { throw AuthorityFault(privateValue: f.material) }
          }
        } catch let caught { error = caught }
        let refused = error != nil
        #expect(refused)
        if let error { try Self.assertSafe(error) }
        let unchanged = try Self.snapshot(f.raw) == f.before
        let noDdl = !stages.withLock { $0.contains(.willMigrate) }
        #expect(unchanged); #expect(noDdl)
        let partials = (try? FileManager.default.contentsOfDirectory(atPath: f.backup)) ?? []
        #expect(!partials.contains { $0.hasSuffix(".partial") })
        if fault == .renamed {
          try Self.assertArchive(f)
        } else {
          #expect(try Self.archives(f.backup).isEmpty)
        }
      }
    }
    try await Self.withFixture(current: false) { f in
      let stages = Mutex<[MigrationBackupStage]>([]), reachedDdl = Mutex(false)
      try WorkspaceDatabase.migrateWithBackup(f.raw, endpoint: f.endpoint, backupDirectory: f.backup) {
        stage in
        stages.withLock { $0.append(stage) }
        if stage == .willMigrate {
          let durableBeforeDdl = stages.withLock { $0.contains(.directorySynchronized) }
          let unchangedBeforeDdl = try Self.snapshot(f.raw) == f.before
          #expect(durableBeforeDdl); #expect(unchangedBeforeDdl)
          try Self.assertArchive(f)
          reachedDdl.withLock { $0 = true }
        }
      }
      #expect(reachedDdl.withLock { $0 })
      let recorded = try Migrator.recorded(f.raw)
      #expect(
        recorded == Self.canonicalNine + [
          "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
          "0014_agent_protocol",
        ])
      let after = try Self.snapshot(f.raw)
      for (table, expected) in f.before.rows {
        let currentTable = AgentProtocolFoundationFixture.currentTable(old: table)
        let expectedRows = try expected.map { text -> String in
          let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          return try Self.canonical(AgentProtocolFoundationFixture.currentRow(table: table, row: object))
        }.sorted()
        let rows = try (after.rows[currentTable] ?? []).map { text -> String in
          guard var object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
          else { throw FixtureFailure.invalidRecord }
          if table == "connections" {
            for name in [
              "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt",
              "protocolRetiredReason",
            ] {
              object.removeValue(forKey: name)
            }
          }
          if table == "hubLink" {
            #expect(object["ownedAs"] is NSNull)
            object.removeValue(forKey: "ownedAs")
          }
          return try Self.canonical(object)
        }.sorted()
        let valuesRetained =
          table == Migrator.table
          ? Set(expected).isSubset(of: Set(rows)) && rows.count == expected.count + 5 : rows == expectedRows
        if table == Migrator.table {
          let addedNames = try Set(rows).subtracting(expected).map { text in
            let row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return try #require(row["name"] as? String)
          }
          #expect(
            Set(addedNames)
              == Set([
                "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
                "0014_agent_protocol",
              ]))
        }
        #expect(valuesRetained, "Original values changed for \(table)")
      }
      let sequenceRetained = after.sequences == f.before.sequences
      #expect(sequenceRetained)
    }
  }

  @Test func privateCapturePrivilegeAndFutureSchemaRefuseWithoutMutation() async throws {
    try await Self.withFixture(current: true) { f in
      let role =
        "a3_backup_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
      try f.raw.execute("CREATE ROLE \(Rows.quote(role)) NOINHERIT LOGIN NOSUPERUSER")
      defer {
        try? f.raw.execute("RESET ROLE")
        try? f.raw.execute("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM \(Rows.quote(role))")
        try? f.raw.execute("REVOKE ALL ON SCHEMA public FROM \(Rows.quote(role))")
        try? f.raw.execute("DROP ROLE \(Rows.quote(role))")
        let roleAbsent =
          (try? f.raw.execute("SELECT 1 FROM pg_roles WHERE rolname=$1", [role]).rows.isEmpty) == true
        #expect(roleAbsent)
      }
      try f.raw.execute("GRANT USAGE ON SCHEMA public TO \(Rows.quote(role))")
      try f.raw.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO \(Rows.quote(role))")
      let settings = try f.raw.execute(
        "SELECT current_setting('log_error_verbosity') AS verbosity,current_setting('log_parameter_max_length') AS parameters,current_setting('log_parameter_max_length_on_error') AS error_parameters"
      ).rows.first
      try f.raw.execute("SET ROLE \(Rows.quote(role))")
      var denied: String?
      do { try f.raw.execute("SET log_error_verbosity=terse") } catch let error as PostgresError {
        denied = error.sqlState
      }
      guard denied == "42501" else { throw FixtureFailure.unexpectedSchema }
      var error: (any Error)?
      do { try Self.capture(f) } catch let caught { error = caught }
      try f.raw.execute("RESET ROLE")
      let refused = error != nil
      #expect(refused)
      if let error { try Self.assertSafe(error) }
      let afterSettings = try f.raw.execute(
        "SELECT current_setting('log_error_verbosity') AS verbosity,current_setting('log_parameter_max_length') AS parameters,current_setting('log_parameter_max_length_on_error') AS error_parameters"
      ).rows.first
      let restored = ["verbosity", "parameters", "error_parameters"].allSatisfy {
        settings?.text($0) == afterSettings?.text($0)
      }
      let unchanged = try Self.snapshot(f.raw) == f.before
      #expect(restored); #expect(unchanged)
      #expect(try Self.archives(f.backup).isEmpty)
    }
    try await Self.withFixture(current: true) { f in
      try f.raw.execute(
        #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ('9999_future','source-future')"#)
      let before = try Self.snapshot(f.raw)
      var error: (any Error)?
      do {
        let database = try WorkspaceDatabase(
          endpoint: f.endpoint, binDir: f.endpoint.binDir!, backupDirectory: f.backup)
        try database.close()
      } catch let caught { error = caught }
      let refused = (error as? WorkspaceError)?.code == .incompatibleVersion
      let unchanged = try Self.snapshot(f.raw) == before
      #expect(refused); #expect(unchanged)
      #expect(try Self.archives(f.backup).isEmpty)
    }
  }
}
