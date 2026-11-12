import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// First native RED uses only today's public export/restore surface; it cannot activate a protocol.
@Suite struct ProtocolActivationRestoreTests {
  private static let controlKey = "__b4app_agent_protocol_activation_v1"
  private static let migrations = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
    "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
    "0014_agent_protocol",
  ]
  // Independent literal inventory includes empty tables and every private obligation table.
  private static let tables = [
    "localServers", "environments", "environmentFolders", "connections", "threads", "appFolders",
    "turns", "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
    "settings", "usageReadings", "tokenUsage", "connectionUsage", "threadDeletes", "viewSettings",
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  private static func snapshot(_ db: WorkspaceDatabase) throws -> [String: [Data]] {
    try db.read { c in
      var result: [String: [Data]] = [:]
      for table in tables {
        // Only the new local control row may differ after GREEN. Never omit unrelated settings,
        // private rows, empty tables, view values, changes or clocks from this equality oracle.
        let condition = table == "settings" ? #" WHERE t."key" IS DISTINCT FROM $1"# : ""
        let parameters: [String?] = table == "settings" ? [controlKey] : []
        result[table] = try c.execute(
          "SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t\(condition)", parameters
        ).rows.map { row in
          Data(try #require(row.text("row")).utf8)
        }.sorted { $0.lexicographicallyPrecedes($1) }
      }
      return result
    }
  }

  private static func controlCount(_ db: WorkspaceDatabase) throws -> Int {
    try db.read { c in
      try #require(
        try c.execute(#"SELECT count(*) AS n FROM "settings" WHERE "key" = $1"#, [controlKey])
          .rows.first?.int("n"))
    }
  }

  private static func ledger(_ db: WorkspaceDatabase) throws -> [Data] {
    try db.read { c in
      try c.execute(#"SELECT to_jsonb(t)::text AS row FROM "schemaMigrations" t ORDER BY "name""#)
        .rows.map { row in Data(try #require(row.text("row")).utf8) }
    }
  }

  private static func nextSequence(_ db: WorkspaceDatabase) throws -> String {
    try db.read { c in
      try #require(
        try c.execute(
          #"SELECT (CASE WHEN is_called THEN last_value + 1 ELSE last_value END)::text AS next_value FROM "changes_seq_seq""#
        ).rows.first?.text("next_value"))
    }
  }

  private static func publicTables(_ db: WorkspaceDatabase) throws -> Set<String> {
    try db.read { c in
      Set(
        try c.execute("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'")
          .rows.compactMap { $0.text("tablename") })
    }
  }

  @Test func restoreWithoutSourceControlCreatesInactiveLocalFacts() throws {
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "activation-red-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/workspace.jsonl"
    let source = try AgentProtocolResourceFixture.database()
    defer { try? source.close() }
    let destination = try AgentProtocolResourceFixture.database()
    defer { try? destination.close() }
    let outcome = Result<Int, any Error> { () throws -> Int in
      try #require(source.endpoint.database != destination.endpoint.database)
      try #require(try source.appliedMigrations() == Self.migrations)
      try #require(try destination.appliedMigrations() == Self.migrations)
      let allTables = Set(Self.tables + ["schemaMigrations", "hubLink"])
      try #require(try Self.publicTables(source) == allTables)
      try #require(try Self.publicTables(destination) == allTables)
      try #require(WorkspaceDatabase.archiveTables == Self.tables)
      try #require(try Self.controlCount(source) == 0)
      try #require(try Self.controlCount(destination) == 0)
      try source.write { c in
        // Fixed native fixtures: no joined account, private auth, runtime or network activity.
        try c.execute(
          """
          SET LOCAL b4app.replaying='on';
          INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
            VALUES ('activation-c','codex','Stored','/fixture/codex','{}','ready','authenticated','then','then');
          INSERT INTO threads (id,"connectionId","nativeThreadId",context,"createdAt","updatedAt")
            VALUES ('activation-t','activation-c','native-t','/fixture/app','then','then');
          INSERT INTO "appFolders" (path,"threadId","createdAt")
            VALUES ('/fixture/app','activation-t','then');
          INSERT INTO turns (id,"threadId","operationId",status,submission,outcome,"createdAt","updatedAt")
            VALUES ('activation-u','activation-t','operation-u','terminal','acknowledged','completed','then','then');
          INSERT INTO "displayItems" (id,"threadId","turnId",role,type,payload,sequence,provenance,"createdAt")
            VALUES ('activation-i','activation-t','activation-u','assistant','agentMessage',
              '{"projectId":"external","environmentId":"keep","n":1e400}',0,'cache','then');
          INSERT INTO drafts ("threadId",text,"updatedAt") VALUES ('activation-t','Retained draft','then');
          INSERT INTO settings (key,value)
            VALUES ('activation-unrelated','{"n":9007199254740993,"opaque":[true,null,"keep"]}');
          INSERT INTO "viewSettings" (id,arrangement,"quietThreads","showArchived","updatedAt")
            VALUES ('view','future-arrangement',NULL,true,NULL);
          INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
            VALUES ('fixture',1,'displayItems','activation-i','update','payload',
              '{"projectId":"external","n":1e-400}','000000001000-0000-fixture');
          INSERT INTO "columnClocks" ("table","rowId","column",hlc)
            VALUES ('viewSettings','view','arrangement','000000001000-0000-fixture');
          """)
      }
      let before = try Self.snapshot(source)
      try #require(before.count == Self.tables.count)
      try #require(before["viewSettings"]?.count == 1 && before["settings"]?.count == 1)
      let sourceLedger = try Self.ledger(source)
      let destinationLedger = try Self.ledger(destination)
      let next = try Self.nextSequence(source)
      let exported = try source.export(to: path)
      #expect(exported.rows == before.values.reduce(0) { $0 + $1.count })
      #expect(try Self.snapshot(source) == before)
      #expect(try Self.ledger(source) == sourceLedger)
      #expect(try Self.controlCount(source) == 0)
      let restored = try destination.restore(from: path)
      // All existing import, native JSONB/text, unknown view, empty/private-table and ledger
      // invariants precede the one intended RED assertion. No UI-default normalization is used.
      #expect(restored.rows == exported.rows)
      #expect(try Self.snapshot(destination) == before)
      #expect(try Self.publicTables(destination) == allTables)
      #expect(try destination.appliedMigrations() == Self.migrations)
      #expect(try Self.ledger(destination) == destinationLedger)
      #expect(try Self.nextSequence(destination) == next)
      #expect(try Self.snapshot(source) == before)
      #expect(try Self.ledger(source) == sourceLedger)
      #expect(try Self.controlCount(source) == 0)
      #expect(try destination.hubLink() == nil)
      #expect(try source.hubLink() == nil)
      return try Self.controlCount(destination)
    }
    // Close both real pools before propagating setup/import errors or the intended count issue.
    let destinationClosed = Result { try destination.close() }
    let sourceClosed = Result { try source.close() }
    let restoredControlRows = try outcome.get()
    try destinationClosed.get()
    try sourceClosed.get()
    // Baseline restore creates no row (actual0). Only this missing local-state assertion is RED;
    // later GREEN tests must also validate fresh incarnations, no binding and no observation.
    #expect(restoredControlRows == 1)
  }
}
