import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// The old store is built only from the frozen pre-cutover migrations. It never opens an owner's
/// database, and no new-profile identity is written into its historical rows.
@Suite(.serialized) struct AgentProtocolMigrationTests {
  private func backupDirectory(_ endpoint: PostgresEndpoint) -> String {
    AgentProtocolResourceFixture.temporaryDirectory + "a3-history-backups-" + endpoint.database
  }

  private func oldFixture() throws -> (PostgresEndpoint, [String: [String]]) {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let c = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    try Migrator.ensureLedger(c, table: Migrator.table)
    for file in try Migrator.files() where file.name <= "0009_thread_runtime_choice" {
      try c.execute(file.sql)
      try c.execute(
        #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#, [file.name])
    }
    try c.execute(
      """
      INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt")
        VALUES ('project-old', 'Preserve project', true, 'created', 'updated');
      INSERT INTO "projectFolders" ("id", "projectId", "path", "createdAt")
        VALUES ('folder-old', 'project-old', '/fixture/project', 'created');
      INSERT INTO "connections" ("id", "kind", "label", "target", "routeKey", "b4Mode",
        "authReference", "nativeScope", "projectId", "capabilities", "status", "authStatus",
        "createdAt", "updatedAt") VALUES
        ('legacy-b4', 'b4', 'Old endpoint', 'https://example.invalid/prefix', '/chat#agent', 'remote',
         'secret:legacy-reference', 'https://example.invalid', 'project-old', '{}', 'ready',
         'authenticated', 'created', 'updated'),
        ('codex-old', 'codex', 'Codex', '/fixture/codex', NULL, NULL, NULL, 'account:codex', NULL,
         '{}', 'ready', 'authenticated', 'created', 'updated'),
        ('claude-old', 'claude', 'Claude', '/fixture/claude', NULL, NULL, NULL, 'account:claude', NULL,
         '{}', 'ready', 'authenticated', 'created', 'updated');
      INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "nativeScope", "title",
        "context", "pinned", "archived", "projectId", "readTurnId", "createdAt", "updatedAt")
        VALUES ('thread-old', 'legacy-b4', 'reused-native-id', 'https://example.invalid', 'History',
        '/chat#agent', true, true, 'project-old', 'turn-old', 'created', 'updated');
      INSERT INTO "turns" ("id", "threadId", "operationId", "nativeTurnId", "status", "submission",
        "outcome", "createdAt", "updatedAt") VALUES
        ('turn-old', 'thread-old', 'operation-old', '1', 'reconciling', 'unknown', NULL,
         'created', 'updated');
      INSERT INTO "displayItems" ("id", "threadId", "turnId", "nativeItemId", "role", "type",
        "payload", "sequence", "provenance", "createdAt") VALUES
        ('item-old', 'thread-old', 'turn-old', 'item-native-old', 'assistant', 'agentMessage',
         '{"text":"Partial output 🌱","opaque":{"unknown":true}}', 0, 'cache', 'created');
      INSERT INTO "runtimeRequests" ("id", "nativeRequestId", "threadId", "turnId",
        "adapterGeneration", "kind", "state", "payload", "createdAt", "updatedAt") VALUES
        ('request-old', '7', 'thread-old', 'turn-old', 3, 'command_approval', 'pending',
         '{"command":"fixture-only"}', 'created', 'updated');
      INSERT INTO "drafts" ("threadId", "text", "updatedAt")
        VALUES ('thread-old', 'Deliberately unsent draft', 'updated');
      """)
    return (endpoint, try snapshot(c))
  }

  private func snapshot(_ c: PostgresConnection) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    let present = Set(
      try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap {
        $0.text("tablename")
      })
    for oldTable in [
      "connections", "projects", "projectFolders", "threads", "turns", "displayItems",
      "runtimeRequests", "drafts", "changes", "columnClocks",
    ] {
      let table =
        present.contains(oldTable) ? oldTable : AgentProtocolFoundationFixture.currentTable(old: oldTable)
      let rows = try c.execute(
        """
        SELECT (to_jsonb(t) - ARRAY['peerProfile','agentId','authMode','authHeaderName',
          'protocolRetiredAt','protocolRetiredReason'])::text AS row
        FROM \(Rows.quote(table)) t ORDER BY 1
        """
      ).rows.compactMap { $0.text("row") }
      let destination = AgentProtocolFoundationFixture.currentTable(old: oldTable)
      if present.contains("projects") {
        result[destination] = try rows.map { text in
          let row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          let current = try AgentProtocolFoundationFixture.currentRow(table: table, row: row)
          let encoded = String(
            decoding: try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]),
            as: UTF8.self)
          // PostgreSQL supplies the same JSONB spelling as the untouched current-side SQL facts.
          return try #require(
            try c.execute("SELECT $1::jsonb::text AS row", [encoded]).rows.first?.text("row"))
        }.sorted()
      } else {
        // Current actual values never pass through either the rename oracle or Foundation's
        // numeric conversion. Stale aliases and exact opaque JSONB number changes remain visible.
        result[destination] = rows.sorted()
      }
    }
    return result
  }

  @Test func additiveMigrationRetainsEveryLegacyFieldAndDoesNotEmitRetirementChanges() throws {
    let (endpoint, before) = try oldFixture()
    defer { try? FileManager.default.removeItem(atPath: backupDirectory(endpoint)) }
    let db = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backupDirectory(endpoint))
    defer { try? db.close() }
    #expect(try db.appliedMigrations().last == "0013_agent_protocol")
    #expect(try db.read { try snapshot($0) } == before)
    let legacy = try #require(try db.connection(id: "legacy-b4"))
    #expect(legacy.kind == .b4)
    #expect(legacy.nativeScope == "https://example.invalid")
    #expect(legacy.authReference == "secret:legacy-reference")
    #expect(try db.turn(id: "turn-old")?.outcome == nil)
    #expect(try db.turn(id: "turn-old")?.submission == .unknown)
  }

  @Test func oldArchiveRestoresItsHistoryAndCredentialReferencesExactly() throws {
    let (endpoint, _) = try oldFixture()
    defer { try? FileManager.default.removeItem(atPath: backupDirectory(endpoint)) }
    let source = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backupDirectory(endpoint))
    defer { try? source.close() }
    let path = AgentProtocolResourceFixture.temporaryDirectory + "a3-history-\(UUID()).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try source.export(to: path)
    let target = try AgentProtocolResourceFixture.database()
    defer { try? target.close() }
    try target.restore(from: path)
    #expect(try target.read { try snapshot($0) } == source.read { try snapshot($0) })
    #expect(try target.draft(threadId: "thread-old")?.text == "Deliberately unsent draft")
    #expect(try target.thread(id: "thread-old")?.readTurnId == "turn-old")
    #expect(try target.pendingRuntimeRequests(threadId: "thread-old").map(\.id) == ["request-old"])
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  /// Reconstruct the historical file order independently of the current exporter. Changing the
  /// export order cannot repair an archive already on disk or make these compatibility cases pass.
  private func historicalArchive(_ source: WorkspaceDatabase, version: Int, path: String) throws {
    _ = try HistoricalWorkspaceArchiveFixture.write(source, version: version, path: path)
    let records = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst().map {
      try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    let connection = try #require(records.firstIndex { $0["table"] as? String == "connections" })
    let project = try #require(records.firstIndex { $0["table"] as? String == "projects" })
    #expect(connection < project)
  }

  private func assertHistoricalArchiveRestores(version: Int, environmentNames: Bool = false) throws {
    let (endpoint, _) = try oldFixture()
    defer { try? FileManager.default.removeItem(atPath: backupDirectory(endpoint)) }
    let source = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backupDirectory(endpoint))
    defer { try? source.close() }
    try source.write { c in
      // Exercise object, array, scalar string/boolean and JSON null cells, including the version1
      // parsed-value representation. These are historical data, never new runtime authority.
      try c.execute(
        #"UPDATE "displayItems" SET "payload" = '{"text":"Partial output 🌱","opaque":[true,null,3.25,{"quote":"a\\b\"c"}]}' WHERE "id" = 'item-old'"#
      )
      try c.execute(
        #"UPDATE "connections" SET "label" = 'A quoted "historical" label' WHERE "id" = 'legacy-b4'"#)
      try c.execute(#"UPDATE "threads" SET "pinned" = false WHERE "id" = 'thread-old'"#)
      try c.execute(#"UPDATE "changes" SET "synced" = true"#)
    }
    var expected = try source.read { try snapshot($0) }
    expected["changes"] = try source.read { c in
      try c.execute(
        #"SELECT (to_jsonb(t) || '{"synced":false}'::jsonb)::text AS row FROM "changes" t ORDER BY 1"#
      ).rows.compactMap { $0.text("row") }
    }
    let expectedChangeCount = try #require(expected["changes"]?.count)
    #expect(expectedChangeCount > 0)
    #expect(try source.unsyncedChangeCount() == 0)
    let path = AgentProtocolResourceFixture.temporaryDirectory + "a3-archive-v\(version)-\(UUID()).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    if environmentNames {
      _ = try HistoricalWorkspaceArchiveFixture.write(
        source, version: version, path: path, environmentNames: true)
    } else {
      try historicalArchive(source, version: version, path: path)
    }
    let target = try AgentProtocolResourceFixture.database()
    defer { try? target.close() }
    try target.restore(from: path)
    #expect(try target.read { try snapshot($0) } == expected)
    #expect(try target.connection(id: "legacy-b4")?.environmentId == "project-old")
    #expect(try target.connection(id: "legacy-b4")?.authReference == "secret:legacy-reference")
    #expect(try target.connection(id: "legacy-b4")?.nativeScope == "https://example.invalid")
    #expect(try target.thread(id: "thread-old")?.environmentId == "project-old")
    #expect(try target.thread(id: "thread-old")?.readTurnId == "turn-old")
    #expect(try target.turn(id: "turn-old")?.submission == .unknown)
    #expect(try target.turn(id: "turn-old")?.outcome == nil)
    #expect(try target.runtimeRequest(id: "request-old")?.state == .pending)
    #expect(try target.draft(threadId: "thread-old")?.text == "Deliberately unsent draft")
    #expect(try target.unsyncedChangeCount() == expectedChangeCount)
  }

  @Test func archiveV1RestoresHistoricalDependencyOrderExactly() throws {
    try assertHistoricalArchiveRestores(version: 1)
  }

  @Test func archiveV2RestoresHistoricalDependencyOrderExactly() throws {
    try assertHistoricalArchiveRestores(version: 2)
  }

  @Test func archiveV3RestoresHistoricalDependencyOrderExactly() throws {
    try assertHistoricalArchiveRestores(version: 3)
  }

  @Test func archiveV3RestoresMainElevenEnvironmentAssociations() throws {
    try assertHistoricalArchiveRestores(version: 3, environmentNames: true)
  }

  @Test func archiveMalformedAndFutureInputPreservePopulatedTargetAtomically() throws {
    let (endpoint, _) = try oldFixture()
    defer { try? FileManager.default.removeItem(atPath: backupDirectory(endpoint)) }
    let target = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backupDirectory(endpoint))
    defer { try? target.close() }
    let before = try target.read { try snapshot($0) }
    let path = AgentProtocolResourceFixture.temporaryDirectory + "a3-archive-invalid-\(UUID()).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    for version in [3, 999] {
      let header = try JSONSerialization.data(withJSONObject: [
        "format": "b4app-export", "version": version,
      ])
      let replacement = Data(
        #"{"table":"projects","row":{"id":"replacement-only","name":"Must roll back","manual":true,"createdAt":"x","updatedAt":"x"}}"#
          .utf8)
      // Supported input contains a valid replacement row before malformed JSON. Refusal must leave
      // existing rows and trigger facts intact, whether parsing happens before or inside the write.
      try (header + Data("\n".utf8) + replacement + Data("\n{invalid JSON\n".utf8))
        .write(to: URL(fileURLWithPath: path))
      var refused = false
      do { try target.restore(from: path, replace: true) } catch { refused = true }
      #expect(refused)
      #expect(try target.read { try snapshot($0) } == before)
      #expect(try target.environment(id: "replacement-only") == nil)
    }
  }

  private func protocolConnectionJSON() throws -> Data {
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: JSONCoding.encoder.encode(
          Connection(id: "profile-new", kind: .b4, label: "New", target: "https://example.invalid/prefix")))
        as? [String: Any])
    object["kind"] = "agentProtocol"
    object["peerProfile"] = "agentProtocol"
    object["agentId"] = "canonical-agent"
    object["authMode"] = "header"
    object["authHeaderName"] = "x-api-key"
    object["authReference"] = "secret:new-reference"
    object["nativeScope"] = #"["agent-protocol-v1","agentProtocol","https://example.invalid/prefix"]"#
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  @Test func freshProtocolProfileRoundTripsWithoutReusingTheHistoricalIdentity() throws {
    let (endpoint, _) = try oldFixture()
    defer { try? FileManager.default.removeItem(atPath: backupDirectory(endpoint)) }
    let db = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backupDirectory(endpoint))
    defer { try? db.close() }
    let data = try protocolConnectionJSON()
    let profile = try JSONCoding.decoder.decode(Connection.self, from: data)
    _ = try db.insertConnection(profile)
    let stored = try #require(try db.connection(id: "profile-new"))
    let expected = try JSONSerialization.jsonObject(with: data) as? NSDictionary
    let actual = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(stored)) as? NSDictionary
    #expect(actual == expected)
    #expect(try db.connection(id: "legacy-b4")?.nativeScope == "https://example.invalid")
    #expect(try db.thread(id: "thread-old")?.connectionId == "legacy-b4")
    #expect(try db.listConnections(includeDisabled: true).count == 4)
  }

  @Test func connectionAddRetainsExplicitProtocolSelectionAndAuthFields() throws {
    let data = Data(
      #"{"kind":"b4","peerProfile":"agentProtocol","agentId":"canonical-agent","authMode":"header","authHeaderName":"x-api-key","authReference":"secret:reference","url":"https://example.invalid/prefix"}"#
        .utf8)
    let params = try JSONCoding.decoder.decode(ConnectionAdd.Params.self, from: data)
    let encoded = try #require(
      try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(params)) as? [String: String])
    #expect(encoded["peerProfile"] == "agentProtocol")
    #expect(encoded["agentId"] == "canonical-agent")
    #expect(encoded["authMode"] == "header")
    #expect(encoded["authHeaderName"] == "x-api-key")
    #expect(encoded["authReference"] == "secret:reference")
  }
}
