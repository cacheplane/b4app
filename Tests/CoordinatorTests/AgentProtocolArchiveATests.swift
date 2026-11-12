import Darwin
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceStorage

/// Existing storage admission/capture APIs only. No service, runtime, listener, hub or owner data.
@Suite(.serialized) struct AgentProtocolArchiveATests {
  private static let dataTables = [
    "localServers", "environments", "environmentFolders", "connections", "threads", "turns", "displayItems",
    "runtimeRequests", "drafts", "devices", "changes", "columnClocks", "settings", "usageReadings",
    "tokenUsage", "connectionUsage", "threadDeletes", "protocolSubscriptions", "protocolRunSegments",
    "protocolOperations", "protocolGrantSecrets", "protocolGrants", "protocolPromptAnswers",
    "protocolHistoryAnchors",
  ]
  private static let historicalDataTables = dataTables.map {
    $0 == "environments" ? "projects" : ($0 == "environmentFolders" ? "projectFolders" : $0)
  }
  private static func sourceDataTables(_ present: Set<String>) -> [String] {
    (present.contains("projects") ? historicalDataTables : dataTables).filter(present.contains)
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
    case unexpectedSchema, invalidRecord, unhandledPrivateFailure, boundaryFault, unsafeLog, oversizedLog
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
    let database: WorkspaceDatabase?
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
    current: Bool = true, _ body: @Sendable (Fixture) async throws -> Void
  ) async throws {
    // Strict intent/live helper+PG identity/ACK precedes fixture schema/row/material SQL.
    // Existing EphemeralPostgres infrastructure CREATE DATABASE precedes that ACK.
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let root = AgentProtocolResourceFixture.temporaryDirectory + "a3-archive-private-\(UUID())"
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
        endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/setup", wall: { 4096 })
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
      for suffix in ["a", "b"] {
        try seedPrivate(database, suffix: suffix, material: material + " owner-" + suffix)
      }
      // Setup writes have returned. The current pool stays open for direct export/restore tests;
      // there is no service/account/network lifecycle in this fixture.
    }
    let expectedTables = Set(
      ((current ? dataTables : historicalDataTables) + contextTables).filter {
        current || !$0.hasPrefix("protocol")
      })
    let actualTables = Set(
      try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
        .rows.compactMap { $0.text("tablename") })
    guard actualTables == expectedTables else { throw FixtureFailure.unexpectedSchema }
    let before = try snapshot(raw)
    guard before.rows.values.allSatisfy({ !$0.isEmpty }) else { throw FixtureFailure.unexpectedSchema }
    let fixture = Fixture(
      database: database, endpoint: endpoint, raw: raw, root: root,
      backup: root + "/backups/" + endpoint.database,
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
    try database?.close()
    if let failure { throw failure }
  }
  private static func seedOldTables(
    _ c: PostgresConnection, endpointReference: SecretRef, protocolProfiles: Bool
  ) throws {
    let environmentTable = protocolProfiles ? "environments" : "projects"
    let folderTable = protocolProfiles ? "environmentFolders" : "projectFolders"
    let association = protocolProfiles ? "environmentId" : "projectId"
    try c.execute(
      """
      INSERT INTO "localServers" ("id","name","projectPath","nodePath","cliPath","launchMode","health","routes","createdAt","updatedAt")
        VALUES ('server','Fixture server','/fixture/project','/fixture/node','/fixture/cli','source','offline','[]','created','updated');
      INSERT INTO "\(environmentTable)" ("id","name","manual","createdAt","updatedAt") VALUES ('project','Retained project',true,'created','updated');
      INSERT INTO "\(folderTable)" ("id","\(association)","path","createdAt") VALUES ('folder','project','/fixture/project','created');
      """)
    for suffix in ["a", "b", "legacy", "codex", "claude"] {
      let kind = suffix == "codex" || suffix == "claude" ? suffix : "b4"
      if protocolProfiles && (suffix == "a" || suffix == "b") {
        try c.execute(
          #"INSERT INTO "connections" ("id","kind","label","target","localServerId","authReference","nativeScope","\#(association)","capabilities","status","authStatus","peerProfile","agentId","authMode","createdAt","updatedAt") VALUES ($1,'agentProtocol',$2,'https://example.invalid/prefix','server',$3,$4,'project','{}','ready','authenticated','agentProtocol','fixture-agent','bearer','created','updated')"#,
          ["connection-" + suffix, "Fresh " + suffix, endpointReference.rawValue, "fixture-scope-" + suffix])
      } else {
        try c.execute(
          #"INSERT INTO "connections" ("id","kind","label","target","localServerId","authReference","nativeScope","\#(association)","capabilities","status","authStatus","createdAt","updatedAt") VALUES ($1,$2,$3,'https://example.invalid/prefix','server',$4,$5,'project','{}','ready','authenticated','created','updated')"#,
          [
            "connection-" + suffix, kind, "Retained " + suffix, endpointReference.rawValue,
            "fixture-scope-" + suffix,
          ])
      }
    }
    for suffix in ["a", "b"] {
      try c.execute(
        #"INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","title","\#(association)","readTurnId","pinned","archived","userDeletedAt","createdAt","updatedAt") VALUES ($1,$2,$3,$4,'Cached history','project',$5,true,true,'deleted','created','updated')"#,
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
        #"INSERT INTO "protocolRunSegments" ("connectionId","threadId","namespace","nativeRunId","rootRunId","localTurnId","facts","updatedAt") VALUES ($1,$2,'[]',$3,$3,$4,'{"opaque":[1,true,null]}',$5)"#,
        [owner.connectionId, owner.threadId, native, "turn-" + suffix, stamp])
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
  private struct OwnedLog: Sendable {
    let path: String
    let device: dev_t
    let inode: ino_t
    init(_ path: String) throws {
      let temporary = URL(fileURLWithPath: AgentProtocolResourceFixture.temporaryDirectory)
        .resolvingSymlinksInPath().standardizedFileURL.path
      let expected = temporary + "/b4pg-shared-\(ProcessInfo.processInfo.processIdentifier)/postgres.log"
      var info = stat()
      guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected,
        lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
      else { throw FixtureFailure.unsafeLog }
      self.path = path; device = info.st_dev; inode = info.st_ino
    }
    func opened() throws -> FileHandle {
      let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
      guard fd >= 0 else { throw FixtureFailure.unsafeLog }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode,
        info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
      else { Darwin.close(fd); throw FixtureFailure.unsafeLog }
      return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func offset() throws -> UInt64 {
      let h = try opened(); defer { try? h.close() }; return try h.seekToEnd()
    }
    func tail(_ start: UInt64) throws -> String {
      let h = try opened(); defer { try? h.close() }
      let end = try h.seekToEnd()
      guard end >= start, end - start <= 4 << 20 else { throw FixtureFailure.oversizedLog }
      try h.seek(toOffset: start)
      let length = Int(end - start)
      var data = Data()
      while data.count < length {
        guard let chunk = try h.read(upToCount: length - data.count), !chunk.isEmpty
        else { throw FixtureFailure.unsafeLog }
        data.append(chunk)
      }
      return String(decoding: data, as: UTF8.self)
    }
    func observed(_ marker: String, after start: UInt64) async throws -> Bool {
      let end = ContinuousClock.now + .seconds(2)
      repeat {
        if try tail(start).contains(marker) { return true }
        try await Task.sleep(for: .milliseconds(10))
      } while ContinuousClock.now < end
      return false
    }
  }
  private struct Target: Sendable {
    let database: WorkspaceDatabase
    let raw: PostgresConnection
    let before: Snapshot
  }
  // TEST ONLY: immutable after capture into Sendable test callbacks; Any is Foundation JSON.
  // Mutations are local before encoding, never shared concurrently with the paused export worker.
  private struct Document: @unchecked Sendable {
    var header: [String: Any]
    var records: [[String: Any]]
    var footer: [String: Any]
    func bytes() throws -> Data {
      var data = Data()
      for record in [header] + records + [footer] {
        data += try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .fragmentsAllowed])
        data += Data("\n".utf8)
      }
      return data
    }
    mutating func recount() {
      let declared =
        (header["requiredTables"] as? [String] ?? []) + (header["sourceContextTables"] as? [String] ?? [])
      var counts: [String: Int] = [:]
      for table in declared { counts[table] = 0 }
      for record in records { if let table = record["table"] as? String { counts[table, default: 0] += 1 } }
      footer = ["format": "b4app-export-end", "version": 4, "rows": records.count, "tableRows": counts]
    }
  }
  private static func document(_ raw: PostgresConnection, purpose: String = "onDemand") throws -> Document {
    let present = Set(
      try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap {
        $0.text("tablename")
      })
    let data = sourceDataTables(present),
      context = contextTables.filter { present.contains($0) }
    var records: [[String: Any]] = []
    for table in data + context {
      for row in try raw.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows {
        var object: [String: Any] = [:]
        for (key, cell) in row.cells { object[key] = try WorkspaceDatabase.jsonObject(cell) }
        records.append(["table": table, "row": object])
      }
    }
    var result = Document(
      header: [
        "format": "b4app-export", "version": 4, "at": stamp, "purpose": purpose,
        "migrations": try Migrator.recorded(raw), "requiredTables": data, "sourceContextTables": context,
      ], records: records, footer: [:])
    result.recount()
    return result
  }
  private static func decoded(_ path: String) throws -> Document {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.last == 0x0a else { throw FixtureFailure.invalidRecord }
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    var objects = try lines.map { line -> [String: Any] in
      guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { throw FixtureFailure.invalidRecord }
      return object
    }
    guard objects.count >= 2 else { throw FixtureFailure.invalidRecord }
    let header = objects.removeFirst(), footer = objects.removeLast()
    return Document(header: header, records: objects, footer: footer)
  }
  private static func containsPrivate(_ text: String) -> Bool {
    text.contains("A3_GRANT_PRIVATE_") || text.contains("A3_ENDPOINT_PRIVATE_")
  }
  private static func withTarget(
    _ f: Fixture, populated: Bool = false,
    _ body: @Sendable (Target) async throws -> Void
  ) async throws {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let db = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!,
      backupDirectory: f.root + "/target-setup/" + endpoint.database, wall: { 1024 })
    let raw = try connection(endpoint)
    defer { try? db.close() }
    try raw.execute(#"UPDATE "schemaMigrations" SET "appliedAt"='target-authoritative-' || "name""#)
    if populated {
      try seedOldTables(
        raw, endpointReference: SecretRef(rawValue: "secret:target-only")!, protocolProfiles: true)
      for suffix in ["a", "b"] {
        try seedPrivate(db, suffix: suffix, material: "A3_GRANT_PRIVATE_TARGET_" + suffix)
      }
      try raw.execute(
        #"DELETE FROM "hubLink"; UPDATE "environments" SET "name"='Target retained on failure'"#)
    }
    var failure: (any Error)?
    do { try await body(Target(database: db, raw: raw, before: snapshot(raw))) } catch {
      if containsPrivate(String(reflecting: error)) {
        Issue.record("An unsafe archive error was refused without printing its value.");
        failure = FixtureFailure.unhandledPrivateFailure
      } else {
        failure = error
      }
    }
    try db.close()
    let noBackends = try raw.execute(
      "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'", [endpoint.database]
    ).rows.isEmpty
    #expect(noBackends)
    if let failure { throw failure }
  }
  private static func assertRestored(_ source: Snapshot, target: Target) throws {
    let after = try snapshot(target.raw)
    for table in dataTables {
      var expected = source.rows[table] ?? []
      if table == "changes" {
        expected = try expected.map { text in
          guard var row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
          else { throw FixtureFailure.invalidRecord }
          row["synced"] = false
          return try canonical(row)
        }.sorted()
      }
      let equal = after.rows[table] == expected
      #expect(equal, "Exact restored values differ for \(table)")
      let representationEqual = after.encodedJsonCells[table] == source.encodedJsonCells[table]
      #expect(representationEqual, "SQL NULL/JSON text representation differs for \(table)")
    }
    let targetLedger = after.rows[Migrator.table] == target.before.rows[Migrator.table]
    let noSourceLink = after.rows["hubLink"] == target.before.rows["hubLink"] && after.rows["hubLink"] == []
    let catalogUnchanged = after.catalog == target.before.catalog
    #expect(targetLedger); #expect(noSourceLink); #expect(catalogUnchanged)
  }
  private static func assertFraming(_ document: Document, expected: Snapshot) throws {
    let headerValid =
      document.header["format"] as? String == "b4app-export" && document.header["version"] as? Int == 4
    let manifestsValid =
      Set(document.header["requiredTables"] as? [String] ?? [])
      == Set(sourceDataTables(Set(expected.rows.keys)))
      && Set(document.header["sourceContextTables"] as? [String] ?? [])
        == Set(contextTables.filter { expected.rows[$0] != nil })
    let sourceNames = try (expected.rows[Migrator.table] ?? []).map { text -> String in
      guard let row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let name = row["name"] as? String
      else { throw FixtureFailure.invalidRecord }
      return name
    }.sorted()
    let migrationNamesMatch = document.header["migrations"] as? [String] == sourceNames
    let dataNames = document.header["requiredTables"] as? [String] ?? []
    let contextNames = document.header["sourceContextTables"] as? [String] ?? []
    let uniqueDisjoint =
      dataNames.count == Set(dataNames).count && contextNames.count == Set(contextNames).count
      && Set(dataNames).isDisjoint(with: Set(contextNames))
    #expect(headerValid); #expect(manifestsValid); #expect(migrationNamesMatch); #expect(uniqueDisjoint)
    var actual: [String: [String]] = [:], jsonCells: [String: [String]] = [:]
    var counts = Dictionary(uniqueKeysWithValues: expected.rows.keys.map { ($0, 0) })
    for record in document.records {
      guard let table = record["table"] as? String, var row = record["row"] as? [String: Any]
      else { throw FixtureFailure.invalidRecord }
      var encoded: [String: Any] = [:]
      for column in expected.jsonColumns[table] ?? [] {
        encoded[column] = row[column] ?? NSNull()
        if let text = row[column] as? String {
          row[column] = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        }
      }
      if expected.jsonColumns[table] != nil { jsonCells[table, default: []].append(try canonical(encoded)) }
      actual[table, default: []].append(try canonical(row)); counts[table, default: 0] += 1
    }
    for (table, expectedRows) in expected.rows {
      let equal = (actual[table] ?? []).sorted() == expectedRows
      let encodedEqual = (jsonCells[table] ?? []).sorted() == (expected.encodedJsonCells[table] ?? [])
      #expect(equal, "Complete archived values differ for \(table)"); #expect(encodedEqual)
    }
    let footerValid =
      document.footer["format"] as? String == "b4app-export-end"
      && document.footer["version"] as? Int == 4 && document.footer["rows"] as? Int == document.records.count
      && document.footer["tableRows"] as? [String: Int] == counts
    #expect(footerValid)
  }
  private static func failure(_ body: () throws -> Void) -> (any Error)? {
    do { try body(); return nil } catch { return error }
  }
  private static func safeBoundary(_ error: any Error, f: Fixture, writing: Bool = false) async throws {
    let noCause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
    let reflectedSafe = !containsPrivate(String(reflecting: error))
    let error = WorkspaceError.from(error)
    #expect(noCause); #expect(reflectedSafe)
    let code =
      error.code == .internalError || error.code == .protocolInvalid || error.code == .incompatibleVersion
    let detailsAbsent = error.details == nil
    let messageSafe = !containsPrivate(error.message)
    #expect(code); #expect(detailsAbsent); #expect(messageSafe)
    let response = ResponseEnvelope.failure("archive-private", error: error)
    let wire = try JSONCoding.encoder.encode(response), line = try NDJSON.encodeLine(response)
    let env = ["PATH": f.root + "/empty-bin", "HOME": f.root, ExecutableLocator.fallbackOverrideVariable: ""]
    let events = EventLog()
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: PlatformPaths(runtimeDir: f.root + "/rt", dataDir: f.root + "/data"),
        startedAt: stamp, environment: env, secretStore: MemorySecretStore(), eventLog: events))
    await diagnostics.recordError(
      scope: writing ? "archive-write" : "archive-restore", code: error.code.rawValue, message: error.message)
    let report = try await diagnostics.read()
    let reportBytes = try JSONCoding.encoder.encode(report)
    let safe =
      !containsPrivate(String(decoding: wire, as: UTF8.self))
      && !containsPrivate(String(decoding: line, as: UTF8.self))
      && !containsPrivate(String(decoding: reportBytes, as: UTF8.self))
    #expect(safe); #expect(await events.sequence == 0)
  }
  private static func assertRefused(
    _ error: (any Error)?, target: Target, before: Snapshot, f: Fixture
  ) async throws {
    let refused = error != nil
    #expect(refused)
    if let error {
      let reflectedSafe = !containsPrivate(String(reflecting: error))
      let noCause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
      #expect(reflectedSafe); #expect(noCause)
      try await safeBoundary(error, f: f)
    }
    let unchanged = try snapshot(target.raw) == before
    #expect(unchanged)
  }
  private static func capture(_ f: Fixture) throws -> String {
    try f.raw.execute("SELECT pg_advisory_lock($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
    defer {
      try? f.raw.execute(
        "SELECT pg_advisory_unlock($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
    }
    try WorkspaceDatabase.backupBeforeMigration(f.raw, endpoint: f.endpoint, directory: f.backup)
    let files = try FileManager.default.contentsOfDirectory(atPath: f.backup).filter {
      $0.hasSuffix(".jsonl")
    }
    guard files.count == 1, let name = files.first else { throw FixtureFailure.invalidRecord }
    return f.backup + "/" + name
  }
  private static func editRow(_ document: inout Document, table: String, key: String, value: Any?) throws {
    guard let index = document.records.firstIndex(where: { $0["table"] as? String == table }),
      var row = document.records[index]["row"] as? [String: Any]
    else { throw FixtureFailure.invalidRecord }
    row[key] = value; document.records[index]["row"] = row
  }

  @Test func archiveA1BothWritersRoundTripPrivateAuthorityWithoutEndpointValues() async throws {
    try await Self.withFixture { f in
      let db = try #require(f.database)
      let publicPath = f.root + "/on-demand.jsonl"
      let summary = try db.export(to: publicPath)
      let backupPath = try Self.capture(f)
      for path in [publicPath, backupPath] {
        let artifact = try Self.decoded(path)
        try Self.assertFraming(artifact, expected: f.before)
        let purpose =
          artifact.header["purpose"] as? String == (path == publicPath ? "onDemand" : "preMigration")
        #expect(purpose)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let excludesEndpoint = !String(decoding: bytes, as: UTF8.self).contains(f.endpointValue)
        #expect(excludesEndpoint)
        #expect(
          (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
            == 0o600)
        try await Self.withTarget(f) { target in
          let result = try target.database.restore(from: path)
          try Self.assertRestored(f.before, target: target)
          let dataRows = Self.dataTables.reduce(0) { $0 + (f.before.rows[$1]?.count ?? 0) }
          #expect(result.rows == dataRows)
          if path == publicPath { #expect(summary.rows == dataRows) }
          let emptySecrets = MemorySecretStore()
          let noEndpoint = try await emptySecrets.read(f.endpointReference) == nil
          #expect(noEndpoint)
          for suffix in ["a", "b"] {
            let owner = ProtocolGrantSecretStore.Owner(
              connectionId: "connection-" + suffix, threadId: "thread-" + suffix)
            let referenceText = try #require(
              try target.raw.execute(
                #"SELECT "grantReference" FROM "protocolGrants" WHERE "threadId"=$1"#, [owner.threadId]
              ).rows.first?.text("grantReference"))
            let reference = try #require(SecretRef(rawValue: referenceText))
            let material = try ProtocolGrantSecretStore.transaction(database: target.database, owner: owner) {
              _, store in try store.read(reference)
            }
            let bytesEqual = material.map { Array($0.utf8) } == Array((f.material + " owner-" + suffix).utf8)
            #expect(bytesEqual)
            let profile = try #require(try target.database.connection(id: owner.connectionId))
            let unavailable = Self.failure {
              _ = try SessionService.defaultAdapterFactory(profile, [:], "fixture", emptySecrets)
            }
            #expect((unavailable as? WorkspaceError)?.code == .unsupportedCapability)
          }
          try Self.assertRestored(f.before, target: target)
        }
      }
      let sourceUnchanged = try Self.snapshot(f.raw) == f.before
      #expect(sourceUnchanged)
      // Required declarations/counts retain a known empty protocol table as well as nonempty ones.
      try f.raw.execute(#"DELETE FROM "protocolHistoryAnchors""#)
      let zeroExpected = try Self.snapshot(f.raw), zeroPath = f.root + "/zero-declared-table.jsonl"
      try db.export(to: zeroPath)
      try Self.assertFraming(Self.decoded(zeroPath), expected: zeroExpected)
      let zeroSourceUnchanged = try Self.snapshot(f.raw) == zeroExpected
      #expect(zeroSourceUnchanged)
    }
  }

  @Test func archiveA2ReplacePreservesInt64SequencesAndOrdersNextRealLocalClock() async throws {
    try await Self.withFixture { f in
      // Both persisted clock sources exceed the pinned target wall (1024). Imported facts are exact.
      let sourceClock = HLC(millis: 8192, counter: 7, deviceId: "source-mac").rawValue
      let laterColumnClock = HLC(millis: 8193, counter: 9, deviceId: "source-mac").rawValue
      try f.raw.execute(#"UPDATE "changes" SET "hlc"=$1,"synced"=true"#, [sourceClock])
      try f.raw.execute(#"UPDATE "columnClocks" SET "hlc"=$1"#, [laterColumnClock])
      let originalIds = try f.raw.execute(#"SELECT "seq"::text AS seq FROM "changes" ORDER BY "seq" LIMIT 3"#)
        .rows.compactMap { $0.text("seq") }
      guard originalIds.count == 3 else { throw FixtureFailure.invalidRecord }
      let exactIds: [Int64] = [Int64.min, 9_007_199_254_740_993, Int64.max - 1]
      for (old, seq) in zip(originalIds, exactIds) {
        try f.raw.execute(
          #"UPDATE "changes" SET "seq"=$1::bigint WHERE "seq"=$2::bigint"#, [String(seq), old])
      }
      let expected = try Self.snapshot(f.raw)
      let doc = try Self.document(f.raw)
      let path = f.root + "/exact-int64.jsonl"
      try doc.bytes().write(to: URL(fileURLWithPath: path))
      try await Self.withTarget(f, populated: true) { target in
        try target.database.restore(from: path, replace: true)
        try Self.assertRestored(expected, target: target)
        let values = try target.raw.execute(#"SELECT "seq"::text AS seq FROM "changes" ORDER BY "seq""#).rows
          .compactMap { $0.text("seq") }
        let allExact = exactIds.allSatisfy { values.contains(String($0)) }
        #expect(allExact)
        let noSourceLink = try target.database.hubLink() == nil
        let ledger = try Self.snapshot(target.raw).rows[Migrator.table] == target.before.rows[Migrator.table]
        #expect(noSourceLink); #expect(ledger)
        let beforeWrite = try Self.snapshot(target.raw)
        try target.database.write { c in
          try c.execute(#"UPDATE "threads" SET "title"='Actual edit after import' WHERE "id"='thread-a'"#)
        }
        let newest = try #require(
          try target.raw.execute(
            #"SELECT "seq"::text AS seq,"hlc" FROM "changes" ORDER BY "seq" DESC LIMIT 1"#
          ).rows.first)
        #expect(newest.text("seq") == String(Int64.max))
        let stamp = try #require(newest.text("hlc"))
        let newestAfterBothSources = stamp > sourceClock && stamp > laterColumnClock
        #expect(newestAfterBothSources)
        // One normal title update emits exactly one change, with its clock installed on that column.
        let titleClock = try target.raw.execute(
          #"SELECT "hlc" FROM "columnClocks" WHERE "table"='threads' AND "rowId"='thread-a' AND "column"='title'"#
        ).rows.first?.text("hlc")
        #expect(titleClock == stamp)
        let allChangesUnsynced = try target.raw.execute(#"SELECT 1 FROM "changes" WHERE "synced""#).rows
          .isEmpty
        #expect(allChangesUnsynced)
        let privateUnchanged = try Self.dataTables.filter { $0.hasPrefix("protocol") }.allSatisfy { table in
          try Self.snapshot(target.raw).rows[table] == beforeWrite.rows[table]
        }
        #expect(privateUnchanged)
        // Empty changes is valid: retain explicit zero declaration and restart at1 transactionally.
        var empty = doc
        empty.records.removeAll { $0["table"] as? String == "changes" }; empty.recount()
        let emptyPath = f.root + "/empty-changes.jsonl"
        try empty.bytes().write(to: URL(fileURLWithPath: emptyPath))
        try target.database.restore(from: emptyPath, replace: true)
        let noChanges = try target.raw.execute(#"SELECT 1 FROM "changes""#).rows.isEmpty
        #expect(noChanges)
        try target.database.write { c in
          try c.execute(
            #"UPDATE "threads" SET "title"='Actual edit after empty import' WHERE "id"='thread-a'"#)
        }
        let emptyNext = try target.raw.execute(#"SELECT "seq"::text AS seq,"hlc" FROM "changes""#).rows
        #expect(emptyNext.count == 1); #expect(emptyNext.first?.text("seq") == "1")
        let emptyHlcNewer = (emptyNext.first?.text("hlc") ?? "") > laterColumnClock
        #expect(emptyHlcNewer)
      }
    }
  }

  @Test func archiveA3MalformedFutureAndJoinedTargetsRefuseBeforeMutation() async throws {
    try await Self.withFixture { f in
      let original = try Self.document(f.raw)
      try await Self.withTarget(f, populated: true) { target in
        for variant in 0..<17 {
          var doc = original
          switch variant {
          case 3: doc.header["requiredTables"] = Self.dataTables + ["unsupportedRequiredTable"]; doc.recount()
          case 4: doc.records[0]["table"] = "undeclaredTable"; doc.recount()
          case 5:
            try Self.editRow(
              &doc, table: "protocolGrantSecrets", key: "unknownRequiredColumn", value: "opaque")
          case 6:
            doc.header["requiredTables"] = Self.dataTables.filter { $0 != "protocolHistoryAnchors" }
            doc.records.removeAll { $0["table"] as? String == "protocolHistoryAnchors" }; doc.recount()
          case 7: doc.header["version"] = 999
          case 8:
            doc.header["migrations"] =
              Self.canonicalNine + [
                "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_agent_protocol",
                "9999_future",
              ]
            doc.records.append([
              "table": Migrator.table, "row": ["name": "9999_future", "appliedAt": "future"],
            ]); doc.recount()
          case 9, 10, 11:
            let key = variant == 9 ? "reference" : (variant == 10 ? "threadId" : "material")
            guard let record = doc.records.first(where: { $0["table"] as? String == "protocolGrantSecrets" }),
              let row = record["row"] as? [String: Any], let prefix = row[key] as? String
            else { throw FixtureFailure.invalidRecord }
            // The prefix is the ACTUAL valid owner/reference/material. libpq truncation would
            // otherwise target a valid prefix and could falsely pass via an unrelated FK refusal.
            try Self.editRow(&doc, table: "protocolGrantSecrets", key: key, value: prefix + "\0suffix")
          case 15: doc.header["migrations"] = Self.canonicalNine  // Context ledger still claims0013.
          case 16: doc.header["requiredTables"] = Self.dataTables + ["connections"]; doc.recount()
          default: break
          }
          var bytes = try doc.bytes()
          if variant == 0 {
            // Contains valid private rows before malformed syntax; no parser/SQL cause may echo them.
            let footer =
              try JSONSerialization.data(withJSONObject: doc.footer, options: [.sortedKeys]) + Data("\n".utf8)
            bytes.removeLast(footer.count); bytes += Data("{invalid JSON\n".utf8); bytes += footer
          }
          if variant == 1 {
            let footer =
              try JSONSerialization.data(withJSONObject: doc.footer, options: [.sortedKeys]) + Data("\n".utf8)
            bytes.removeLast(footer.count)
          }
          if variant == 2 {
            doc.records.removeLast(); bytes = try doc.bytes()  // Original footer is intentionally retained.
          }
          if variant == 12 { bytes.removeLast() }
          if variant == 13 {
            bytes +=
              try JSONSerialization.data(withJSONObject: doc.footer, options: [.sortedKeys]) + Data("\n".utf8)
          }
          if variant == 14 {
            bytes +=
              try JSONSerialization.data(withJSONObject: doc.records[0], options: [.sortedKeys])
              + Data("\n".utf8)
          }
          let path = f.root + "/malformed-\(variant).jsonl"
          try bytes.write(to: URL(fileURLWithPath: path))
          let before = try Self.snapshot(target.raw)
          let error = Self.failure { try target.database.restore(from: path, replace: true) }
          try await Self.assertRefused(error, target: target, before: before, f: f)
        }
      }
      // Use accepted legacy3 framing to reach today's storage write, independently of missing v4 support.
      let legacy = f.root + "/joined-legacy3.jsonl"
      try Self.legacyBytes(original, version: 3, jsonColumns: f.before.jsonColumns).write(
        to: URL(fileURLWithPath: legacy))
      try await Self.withTarget(f) { target in
        // A real accepted restore is a SETUP PRECONDITION, not a targeted guard feature assertion.
        try Self.acceptLegacy(path: legacy, source: f.before, target: target)
        try target.database.write { c in
          try c.execute("SET LOCAL b4app.replaying='on'")
          for table in Self.dataTables.reversed() { try c.execute("DELETE FROM \(Rows.quote(table))") }
        }
        try target.raw.execute(
          #"INSERT INTO "hubLink" ("id","url","deviceId","deviceName","tokenRef","orgSlug","username","joinedAt") VALUES (1,'https://target.invalid','target-device','target','secret:target-hub','target','target','joined')"#
        )
        let before = try Self.snapshot(target.raw)
        for replace in [false, true] {
          let error = Self.failure { try target.database.restore(from: legacy, replace: replace) }
          try await Self.assertRefused(error, target: target, before: before, f: f)
        }
      }
      // Emptiness covers auxiliary facts even with zero connections; no unrelated data is overwritten.
      try await Self.withTarget(f) { target in
        try target.raw.execute(#"INSERT INTO "settings" ("key","value") VALUES ('target-only','true')"#)
        let before = try Self.snapshot(target.raw)
        let error = Self.failure { try target.database.restore(from: legacy) }
        try await Self.assertRefused(error, target: target, before: before, f: f)
      }
      // Protocol material hidden under a legacy header is rejected, never silently skipped.
      for version in [1, 2, 3] {
        try await Self.withTarget(f) { target in
          let path = f.root + "/private-under-v\(version).jsonl"
          var bytes = try Self.legacyBytes(original, version: version, jsonColumns: f.before.jsonColumns)
          let record = try #require(
            original.records.first { $0["table"] as? String == "protocolHistoryAnchors" })
          bytes +=
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8)
          try bytes.write(to: URL(fileURLWithPath: path))
          let error = Self.failure { try target.database.restore(from: path) }
          try await Self.assertRefused(error, target: target, before: target.before, f: f)
        }
      }
    }
  }

  private static let protocolConnectionFields = [
    "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt", "protocolRetiredReason",
  ]
  /// TEST FIXTURE ONLY: a copy of the produced0009 connection shape. IDs, nativeScope, references,
  /// timestamps and every other property stay exact. Never mutates the canonical v4 document or DB.
  private static func legacyConnection(_ input: [String: Any]) -> [String: Any] {
    var row = input
    if row["kind"] as? String == "agentProtocol" { row["kind"] = "b4" }
    for key in protocolConnectionFields { row.removeValue(forKey: key) }
    return row
  }
  private static func historicalRow(table: String, row input: [String: Any]) throws -> [String: Any] {
    var row = input
    let references = ["connections", "threads", "environmentFolders", "projectFolders"]
    if references.contains(table), let value = row.removeValue(forKey: "environmentId") {
      guard row["projectId"] == nil else { throw FixtureFailure.invalidRecord }
      row["projectId"] = value
    }
    if table == "changes" || table == "columnClocks", let stored = row["table"] as? String {
      row["table"] =
        stored == "environments" ? "projects" : (stored == "environmentFolders" ? "projectFolders" : stored)
      if references.contains(stored), row["column"] as? String == "environmentId" {
        row["column"] = "projectId"
      }
      if table == "changes", row["op"] as? String == "insert", references.contains(stored),
        let text = row["value"] as? String,
        var image = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let value = image.removeValue(forKey: "environmentId")
      {
        guard image["projectId"] == nil else { throw FixtureFailure.invalidRecord }
        image["projectId"] = value; row["value"] = try canonical(image)
      }
    }
    return row
  }
  private static func legacyBytes(
    _ document: Document, version: Int, jsonColumns: [String: Set<String>]
  ) throws -> Data {
    guard [1, 2, 3].contains(version) else { throw FixtureFailure.invalidRecord }
    let order = [
      "localServers", "connections", "projects", "projectFolders", "threads", "turns", "displayItems",
      "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
    ]
    var data =
      try JSONSerialization.data(
        withJSONObject: ["format": "b4app-export", "version": version], options: [.sortedKeys])
      + Data("\n".utf8)
    for table in order {
      let current =
        table == "projects" ? "environments" : (table == "projectFolders" ? "environmentFolders" : table)
      for var record in document.records where record["table"] as? String == current {
        guard let provided = record["row"] as? [String: Any] else { throw FixtureFailure.invalidRecord }
        var row = try historicalRow(table: current, row: provided)
        record["table"] = table
        if table == "connections" { row = legacyConnection(row) }
        if table == "changes", row["table"] as? String == "connections", row["op"] as? String == "insert" {
          guard let text = row["value"] as? String,
            let image = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
          else { throw FixtureFailure.invalidRecord }
          row["value"] = try canonical(legacyConnection(image))
        }
        if version == 1 {
          for key in jsonColumns[current] ?? [] {
            if let text = row[key] as? String {
              row[key] = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            }
          }
        }
        record["row"] = row
        data += try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8)
      }
    }
    return data
  }
  /// Actual full old12 row/ledger/link/sequence capture proves the normalized input is known valid.
  /// Any mismatch is a SETUP failure; never let an early legacy rejection count as a guard RED/GREEN.
  private static func acceptLegacy(path: String, source: Snapshot, target: Target) throws {
    let before = try snapshot(target.raw)
    do { try target.database.restore(from: path, replace: true) } catch {
      throw FixtureFailure.unexpectedSchema
    }
    let after = try snapshot(target.raw)
    for table in [
      "localServers", "connections", "environments", "environmentFolders", "threads", "turns", "displayItems",
      "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
    ] {
      let expected = try (source.rows[table] ?? []).map { text -> String in
        guard var row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw FixtureFailure.invalidRecord }
        if table == "connections" {
          row = legacyConnection(row)
          for key in protocolConnectionFields { row[key] = NSNull() }  // target's nullable0013 defaults
        }
        if table == "changes" {
          row["synced"] = false
          if row["table"] as? String == "connections", row["op"] as? String == "insert",
            let image = row["value"] as? [String: Any]
          {
            row["value"] = legacyConnection(image)
          }
        }
        return try canonical(row)
      }.sorted()
      guard after.rows[table] == expected else { throw FixtureFailure.unexpectedSchema }
    }
    guard after.rows[Migrator.table] == before.rows[Migrator.table],
      after.rows["hubLink"] == before.rows["hubLink"],
      after.catalog == before.catalog,
      let maxText = try target.raw.execute(#"SELECT coalesce(max("seq"),0)::text AS n FROM "changes""#).rows
        .first?.text("n"),
      let max = Int64(maxText), max < Int64.max,
      after.sequences.contains("changes_seq_seq:\(max + 1):false")
    else { throw FixtureFailure.unexpectedSchema }
  }
  private static func observed(_ body: @Sendable () -> Bool, seconds: Int = 15) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !body(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    return body()
  }

  @Test func archiveA4HeaderBarrierSnapshotIsConsistentWhileSharedWriterCommits() async throws {
    try await Self.withFixture { f in
      let db = try #require(f.database)
      let header = Mutex(false), writerDone = Mutex(false)
      let release = DispatchSemaphore(value: 0)
      let path = f.root + "/concurrent.jsonl"
      let exporter = Task.detached {
        try db.export(to: path) { stage in
          if stage == .headerWritten {
            header.withLock { $0 = true }
            guard release.wait(timeout: .now() + 25) == .success else { throw FixtureFailure.boundaryFault }
          }
        }
      }
      var writer: Task<Void, any Error>?
      var caught: (any Error)?
      do {
        let atHeader = try await Self.observed { header.withLock { $0 } }
        #expect(atHeader)
        guard atHeader else { throw FixtureFailure.boundaryFault }
        writer = Task.detached {
          defer { writerDone.withLock { $0 = true } }
          try ProtocolGrantSecretStore.transaction(
            database: db, owner: .init(connectionId: "connection-a", threadId: "thread-a")
          ) { c, store in
            try store.put("A3_GRANT_PRIVATE_CONCURRENT_" + UUID().uuidString, reference: .make())
            try c.execute(#"UPDATE "threads" SET "title"='Committed after header' WHERE "id"='thread-a'"#)
            try c.execute(
              #"UPDATE "protocolSubscriptions" SET "appliedSeq"=18,"appliedEventId"='after-header' WHERE "threadId"='thread-a'"#
            )
          }
        }
        let committedWhilePaused = try await Self.observed { writerDone.withLock { $0 } }
        #expect(committedWhilePaused)
        guard committedWhilePaused else { throw FixtureFailure.boundaryFault }
      } catch { caught = error }
      // ALWAYS release before actual joins, including observed/setup/oracle failure. No Bounded-as-join.
      release.signal()
      if let writer { do { try await writer.value } catch { if caught == nil { caught = error } } }
      do { _ = try await exporter.value } catch { if caught == nil { caught = error } }
      if let caught { throw caught }
      try Self.assertFraming(Self.decoded(path), expected: f.before)
      let changed = try Self.snapshot(f.raw).rows != f.before.rows
      #expect(changed)
    }
  }

  private static func inode(_ path: String) throws -> String {
    var value = stat()
    guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid()
    else { throw FixtureFailure.unsafeLog }
    return String(value.st_dev) + ":" + String(value.st_ino)
  }
  @Test func archiveA5AtomicOverwriteKeepsOldFileOnlyBeforePublicationAndRefusesLinks() async throws {
    try await Self.withFixture { f in
      let db = try #require(f.database)
      let fm = FileManager.default, old = Data("Owner previous backup; retain until publication\n".utf8)
      let blocked = f.root + "/blocked-parent"
      try old.write(to: URL(fileURLWithPath: blocked))
      let blockerError = Self.failure { try db.export(to: blocked + "/archive.jsonl") }
      #expect(blockerError != nil)
      let blockerUnchanged = try Data(contentsOf: URL(fileURLWithPath: blocked)) == old
      #expect(blockerUnchanged)
      let realParent = f.root + "/real-parent", linkParent = f.root + "/link-parent"
      try fm.createDirectory(
        atPath: realParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try fm.createSymbolicLink(atPath: linkParent, withDestinationPath: realParent)
      let parentError = Self.failure { try db.export(to: linkParent + "/archive.jsonl") }
      #expect(parentError != nil)
      #expect(!fm.fileExists(atPath: realParent + "/archive.jsonl"))
      let canary = f.root + "/canary", link = f.root + "/destination-link"
      try old.write(to: URL(fileURLWithPath: canary))
      let originalCanaryInode = try Self.inode(canary)
      try fm.createSymbolicLink(atPath: link, withDestinationPath: canary)
      let destinationError = Self.failure { try db.export(to: link) }
      #expect(destinationError != nil)
      let canaryUnchanged =
        try Data(contentsOf: URL(fileURLWithPath: canary)) == old && Self.inode(canary) == originalCanaryInode
      #expect(canaryUnchanged)
      // Preserve the current overwrite contract; success replaces atomically with a COMPLETE new file.
      let path = f.root + "/overwrite.jsonl"
      try old.write(to: URL(fileURLWithPath: path))
      let oldInode = try Self.inode(path)
      try db.export(to: path)
      let replacedInode = try Self.inode(path) != oldInode
      #expect(replacedInode)
      try Self.assertFraming(Self.decoded(path), expected: f.before)
      // This event is deliberately NOT emitted by the unchanged baseline. If absent, the fault
      // branch is unexecuted and reached=false is a meaningful missing-durability assertion.
      try old.write(to: URL(fileURLWithPath: path))
      let beforeFaultInode = try Self.inode(path), reached = Mutex(false)
      let error = Self.failure {
        try db.export(to: path) { stage in
          if stage == .fileSynchronized {
            reached.withLock { $0 = true }
            throw AuthorityFault(privateValue: f.material)
          }
        }
      }
      #expect(reached.withLock { $0 }); #expect(error != nil)
      if let error { try await Self.safeBoundary(error, f: f, writing: true) }
      let oldPreserved =
        try Data(contentsOf: URL(fileURLWithPath: path)) == old && Self.inode(path) == beforeFaultInode
      #expect(oldPreserved)
      let partials = try fm.contentsOfDirectory(atPath: f.root).filter { $0.hasSuffix(".partial") }
      #expect(partials.isEmpty)
      let sourceUnchanged = try Self.snapshot(f.raw) == f.before
      #expect(sourceUnchanged)
      // After publication, a directory-fsync error may leave the complete NEW file published.
      // This test makes no impossible post-rename old-file rollback guarantee.
    }
  }

  private static func settings(_ c: PostgresConnection) throws -> [String] {
    let row = try #require(
      try c.execute(
        "SELECT current_setting('log_error_verbosity') AS a,current_setting('log_parameter_max_length') AS b,current_setting('log_parameter_max_length_on_error') AS c,current_setting('debug_print_parse') AS d,current_setting('debug_print_rewritten') AS e,current_setting('debug_print_plan') AS f"
      ).rows.first)
    return ["a", "b", "c", "d", "e", "f"].map { row.text($0) ?? "NULL" }
  }
  private static func transactionSettings(_ db: WorkspaceDatabase, pid: Int) throws -> [String] {
    try db.read { c in
      let sameBackend = try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid") == pid
      #expect(sameBackend)
      return try settings(c)
    }
  }
  @Test func archiveA6CommitFailureRollsBackApplicationSequenceAndMasksPrivateDiagnostics() async throws {
    try await Self.withFixture { f in
      let document = try Self.document(f.raw), log = try OwnedLog(f.endpoint.logPath)
      try await Self.withTarget(f, populated: true) { target in
        let path = f.root + "/restore-fault.jsonl"
        try document.bytes().write(to: URL(fileURLWithPath: path))
        let backend = try target.database.read { c -> Int in
          try c.execute(
            "SET log_error_verbosity=default; SET log_parameter_max_length=-1; SET log_parameter_max_length_on_error=-1"
          )
          return try #require(try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"))
        }
        let originalSettings = try Self.transactionSettings(target.database, pid: backend)
        // The test-only progress sequence is intentionally outside application sequence inventory.
        // Its nontransactional increments prove which real trigger bodies ran; it never stores data.
        try target.raw.execute("CREATE SEQUENCE a3_archive_test_progress")
        defer { try? target.raw.execute("DROP SEQUENCE IF EXISTS a3_archive_test_progress") }
        for deferred in [false, true] {
          try target.raw.execute(
            """
            CREATE FUNCTION a3_archive_fault() RETURNS trigger LANGUAGE plpgsql AS $$
            DECLARE progress bigint;
            BEGIN
              progress := nextval('a3_archive_test_progress');
              IF \(deferred ? "progress % 2 = 0" : "true") THEN
                RAISE EXCEPTION 'Fixture archive refusal' USING ERRCODE='23514',DETAIL=NEW."material";
              END IF;
              RETURN NEW;
            END $$;
            CREATE \(deferred ? "CONSTRAINT " : "")TRIGGER a3_archive_fault AFTER INSERT ON "protocolGrantSecrets"
              \(deferred ? "DEFERRABLE INITIALLY DEFERRED" : "") FOR EACH ROW EXECUTE FUNCTION a3_archive_fault();
            """)
          defer {
            try? target.raw.execute(
              "DROP TRIGGER IF EXISTS a3_archive_fault ON \"protocolGrantSecrets\"; DROP FUNCTION IF EXISTS a3_archive_fault()"
            )
          }
          try target.raw.execute("ALTER SEQUENCE a3_archive_test_progress RESTART WITH 1")
          // Actual raw DETAIL positive control, isolated under the same three privacy GUCs. Never print it.
          var rawCode: String?, rawDetail = false
          do {
            try target.raw.execute("BEGIN")
            try ProtocolGrantProtection.establish(target.raw)
            let row = try #require(
              try target.raw.execute(
                #"SELECT "reference","connectionId","threadId","material","createdAt" FROM "protocolGrantSecrets" ORDER BY "reference" LIMIT 1"#
              ).rows.first)
            for n in 1...(deferred ? 2 : 1) {
              try target.raw.execute(
                #"INSERT INTO "protocolGrantSecrets" ("reference","connectionId","threadId","material","createdAt") VALUES ($1,$2,$3,$4,$5)"#,
                [
                  "secret:raw-archive-control-\(n)", row.text("connectionId"), row.text("threadId"),
                  row.text("material"), row.text("createdAt"),
                ])
            }
            if deferred { try target.raw.execute("SET CONSTRAINTS a3_archive_fault IMMEDIATE") }
          } catch let error as PostgresError {
            rawCode = error.sqlState; rawDetail = Self.containsPrivate(error.description)
          }
          try target.raw.execute("ROLLBACK")
          guard rawCode == "23514", rawDetail else { throw FixtureFailure.unexpectedSchema }
          try target.raw.execute("ALTER SEQUENCE a3_archive_test_progress RESTART WITH 1")
          let before = try Self.snapshot(target.raw)
          let offset = try log.offset()
          let error = Self.failure { try target.database.restore(from: path, replace: true) }
          let reached = try target.raw.execute(
            "SELECT last_value::text AS n,is_called FROM a3_archive_test_progress"
          ).rows.first
          #expect(reached?.text("n") == (deferred ? "2" : "1"))
          #expect(reached?.text("is_called") == "t")
          // Exclude ONLY the exact test progress sequence, whose intentional nontransactional change
          // is instrumentation; every application sequence state/rows/ledger/catalog must match.
          let after = try Self.snapshot(target.raw)
          let appBefore = before.sequences.filter { !$0.hasPrefix("a3_archive_test_progress:") }
          let appAfter = after.sequences.filter { !$0.hasPrefix("a3_archive_test_progress:") }
          let unchanged =
            before.rows == after.rows && before.catalog == after.catalog && appBefore == appAfter
          #expect(unchanged)
          if let error {
            let noCause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
            let publicError = WorkspaceError.from(error)
            let safe =
              publicError.code == .internalError
              && publicError.message == "The protected workspace archive could not be restored."
              && publicError.details == nil && !Self.containsPrivate(String(reflecting: error))
            #expect(noCause); #expect(safe)
            try await Self.safeBoundary(error, f: f)
          } else {
            Issue.record("The real restore failure was not refused.")
          }
          let restoredSettings =
            try Self.transactionSettings(target.database, pid: backend) == originalSettings
          #expect(restoredSettings)
          let marker = "a3-archive-diagnostic-" + UUID().uuidString
          try target.raw.execute("DO $$ BEGIN RAISE LOG '%', $m$\(marker)$m$; END $$")
          guard try await log.observed(marker, after: offset) else { throw FixtureFailure.unsafeLog }
          let tail = try log.tail(offset)
          let expectedFaultPresent = tail.contains("Fixture archive refusal")
          let sentinelAbsent = !Self.containsPrivate(tail)
          #expect(expectedFaultPresent); #expect(sentinelAbsent)
          try target.raw.execute(
            "DROP TRIGGER a3_archive_fault ON \"protocolGrantSecrets\"; DROP FUNCTION a3_archive_fault()")
        }
        // Remove ONLY fixture protocol obligations before the legacy-sequence probes. Otherwise
        // legacy's old reverse DELETE order could fail a RESTRICT FK before ever reaching changes,
        // falsely passing the missing-seq/default-nextval oracle.
        try target.database.write { c in
          try c.execute("SET LOCAL b4app.replaying='on'")
          for table in Self.dataTables.reversed() where table.hasPrefix("protocol") {
            try c.execute("DELETE FROM \(Rows.quote(table))")
          }
        }
        // Fresh real successful1/2/3 restores prove each normalized control valid BEFORE fault
        // instrumentation. Full row/catalog/ledger/link/app-sequence captures are checked each time.
        // Their failure is setup; the malformed sequence matrix is then UNEXECUTED.
        for version in [1, 2, 3] {
          let path = f.root + "/accepted-seq-base-v\(version).jsonl"
          try Self.legacyBytes(document, version: version, jsonColumns: f.before.jsonColumns).write(
            to: URL(fileURLWithPath: path))
          try Self.acceptLegacy(path: path, source: f.before, target: target)
        }
        // Sequence parsing is independently reached under ALL supported legacy headers as well as4.
        // A legacy malformed sequence must not invoke its default nextval even if later replay fails.
        try target.raw.execute(
          """
          CREATE FUNCTION a3_archive_seq_fault() RETURNS trigger LANGUAGE plpgsql AS $$
          BEGIN PERFORM nextval('a3_archive_test_progress'); RAISE EXCEPTION 'Sequence replay unexpectedly reached' USING ERRCODE='23514'; END $$;
          CREATE TRIGGER a3_archive_seq_fault AFTER INSERT ON "changes" FOR EACH ROW EXECUTE FUNCTION a3_archive_seq_fault();
          """)
        defer {
          try? target.raw.execute(
            "DROP TRIGGER IF EXISTS a3_archive_seq_fault ON \"changes\"; DROP FUNCTION IF EXISTS a3_archive_seq_fault()"
          )
        }
        // Raw JSON number lexemes avoid Double rounding in the TEST builder as well as the reader.
        let lexemes: [String?] = [
          nil, "null", "true", "1.5", "1.00000000000000000000001",
          "9223372036854775808", "-9223372036854775809", "9223372036854775807", "\"17\"",
        ]
        for version in [1, 2, 3, 4] {
          for (index, lexeme) in lexemes.enumerated() {
            var changed = document
            try Self.editRow(
              &changed, table: "changes", key: "seq", value: lexeme == nil ? nil : "__A3_RAW_SEQUENCE__")
            let bytes =
              version == 4
              ? try changed.bytes()
              : try Self.legacyBytes(changed, version: version, jsonColumns: f.before.jsonColumns)
            let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(
              of: "\"__A3_RAW_SEQUENCE__\"", with: lexeme ?? "null")
            try Data(text.utf8).write(to: URL(fileURLWithPath: f.root + "/seq-\(version)-\(index).jsonl"))
            try target.raw.execute("ALTER SEQUENCE a3_archive_test_progress RESTART WITH 1")
            let before = try Self.snapshot(target.raw)
            let error = Self.failure {
              try target.database.restore(from: f.root + "/seq-\(version)-\(index).jsonl", replace: true)
            }
            try await Self.assertRefused(error, target: target, before: before, f: f)
            let replayNotReached =
              try target.raw.execute("SELECT is_called FROM a3_archive_test_progress").rows.first?.text(
                "is_called") == "f"
            #expect(replayNotReached)
          }
        }
      }
    }
  }

  @Test func archiveA7BothWritersRefuseMalformed0010ButGenuineOldNineRemainsCapturable() async throws {
    try await Self.withFixture { f in
      let db = try #require(f.database)
      // Leaf-only test corruption: ledger0013 is kept; no CASCADE and no authority rows are dropped.
      try f.raw.execute(#"DROP TABLE "protocolHistoryAnchors""#)
      let before = try Self.snapshot(f.raw)
      let path = f.root + "/malformed-source.jsonl"
      let error = Self.failure { try db.export(to: path) }
      #expect(error != nil)
      if let error { try await Self.safeBoundary(error, f: f, writing: true) }
      #expect(!FileManager.default.fileExists(atPath: path))
      let beforeCapture = try Self.snapshot(f.raw) == before
      #expect(beforeCapture)
      let captureError = Self.failure { _ = try Self.capture(f) }
      #expect(captureError != nil)
      let afterCapture = try Self.snapshot(f.raw) == before
      #expect(afterCapture)
      let files = (try? FileManager.default.contentsOfDirectory(atPath: f.backup)) ?? []
      #expect(files.isEmpty)
    }
    // This positive is the real raw0001–0009 catalog, not a production skip-migration constructor.
    // Only preMigration has a callable old-schema connection path; ordinary open upgrades it first.
    try await Self.withFixture(current: false) { f in
      let path = try Self.capture(f)
      try Self.assertFraming(Self.decoded(path), expected: f.before)
      let unchanged = try Self.snapshot(f.raw) == f.before
      #expect(unchanged)
    }
  }
}
