import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// The published app-folder schema is a real source prefix, not an alias for an AP development DB.
@Suite(.serialized) struct AgentProtocolAppFolderArchiveIntegrationTests {
  private static let twelve = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
    "0010_owned_rows", "0011_environments", "0012_app_folders",
  ]
  private static let thirteen = twelve + ["0013_agent_protocol"]
  private static let publishedTables = [
    "localServers", "environments", "environmentFolders", "connections", "threads", "appFolders",
    "turns", "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
    "settings", "usageReadings", "tokenUsage", "connectionUsage", "threadDeletes",
  ]
  private static let protocolTables = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  @Test func publishedTwelveAndProtocolThirteenHaveDistinctClosedManifests() throws {
    let published = try WorkspaceArchive.schema(Self.twelve)
    let successor = try WorkspaceArchive.schema(Self.thirteen)
    #expect(published.data == Self.publishedTables)
    #expect(successor.data == Self.publishedTables + Self.protocolTables)
    #expect(successor.data.count == 25)
    #expect(published.context == ["schemaMigrations", "hubLink"])
    #expect(try WorkspaceArchive.columns("appFolders", at: 11).isEmpty)
    #expect(try WorkspaceArchive.columns("appFolders", at: 12) == Set(["path", "threadId", "createdAt"]))
    for table in Self.protocolTables {
      #expect(try WorkspaceArchive.columns(table, at: 12).isEmpty)
      #expect(try !WorkspaceArchive.columns(table, at: 13).isEmpty)
    }
    #expect(try !WorkspaceArchive.columns("connections", at: 12).contains("authMode"))
    #expect(try WorkspaceArchive.columns("connections", at: 13).contains("authMode"))
    for (prefixCount, draft) in [(10, "0011_agent_protocol"), (11, "0012_agent_protocol")] {
      let names = Array(Self.twelve.prefix(prefixCount)) + [draft]
      #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.schema(names) }
    }
  }

  @Test func publishedV3AppFoldersKeepOpaqueJSONAndRejectUnknownFolderColumns() throws {
    let opaque = #"{"projectId":"external","environmentId":"keep","n":1e400}"#
    let folder: [String: Any] = ["path": "/fixture/app", "threadId": "t", "createdAt": "then"]
    func document(_ row: [String: Any]) throws -> Data {
      try Self.lines([
        ["format": "b4app-export", "version": 3, "migrations": Self.twelve],
        ["table": "appFolders", "row": row],
        [
          "table": "changes",
          "row": ["seq": 1, "table": "displayItems", "op": "update", "column": "payload", "value": opaque],
        ],
      ])
    }
    let input = try WorkspaceArchive.read(document(folder))
    #expect(input.records["appFolders"]?.first?.row["path"] as? String == "/fixture/app")
    #expect(input.records["changes"]?.first?.row["value"] as? String == opaque)
    var unknown = folder; unknown["grantMaterial"] = "must-refuse"
    #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(document(unknown)) }
    let mixed = try Self.lines([
      ["format": "b4app-export", "version": 3],
      ["table": "appFolders", "row": folder],
      ["table": "projects", "row": ["id": "old", "name": "mixed"]],
    ])
    #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(mixed) }
  }

  @Test func genuineTwelveFoldersAndArchivesSurviveThirteenAndReopen() throws {
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "ap-app-folders-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let backups = root + "/backups"
    let v3 = root + "/published-v3.jsonl", v4 = root + "/published-v4.jsonl"
    let before: [String: [String]]
    do {
      let raw = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      try Migrator.ensureLedger(raw, table: Migrator.table)
      for file in try Migrator.files() where file.name < "0013" {
        try raw.execute(file.sql)
        try raw.execute(
          "INSERT INTO \"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'published12')", [file.name])
      }
      try #require(try Migrator.recorded(raw) == Self.twelve)
      try raw.execute(
        """
        SET b4app.replaying='on';
        INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
          VALUES ('c','codex','Native','/fixture/codex','{}','ready','authenticated','then','then');
        INSERT INTO threads (id,"connectionId","nativeThreadId",context,"createdAt","updatedAt")
          VALUES ('t','c','native-12','/fixture/app','then','then');
        INSERT INTO "appFolders" (path,"threadId","createdAt") VALUES ('/fixture/app','t','then');
        INSERT INTO turns (id,"threadId","operationId",status,submission,outcome,"createdAt","updatedAt")
          VALUES ('u','t','op','terminal','acknowledged','completed','then','then');
        INSERT INTO "displayItems" (id,"threadId","turnId",role,type,payload,sequence,provenance,"createdAt")
          VALUES ('i','t','u','assistant','agentMessage','{"projectId":"external","environmentId":"keep","n":1e400}',0,'cache','then');
        INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
          VALUES ('fixture',1,'displayItems','i','update','payload','{"projectId":"external","n":1e-400}','000000001000-0000-fixture');
        RESET b4app.replaying;
        """)
      before = try Self.snapshot(raw)
      // This is the fixed published v3 writer order, independent of the current v4 manifest.
      let legacyTables = [
        "localServers", "connections", "environments", "environmentFolders", "threads", "appFolders", "turns",
        "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
      ]
      var records: [[String: Any]] = [["format": "b4app-export", "version": 3, "migrations": Self.twelve]]
      for table in legacyTables {
        for row in try raw.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows {
          var values: [String: Any] = [:]
          for (key, cell) in row.cells { values[key] = try WorkspaceDatabase.jsonObject(cell) }
          records.append(["table": table, "row": values])
        }
      }
      let legacyBytes = try Self.lines(records)
      try #require(
        FileManager.default.createFile(
          atPath: v3, contents: legacyBytes, attributes: [.posixPermissions: 0o600]))
      try raw.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
      do {
        try ProtocolGrantProtection.establish(raw)
        let present = Set(
          try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap {
            $0.text("tablename")
          })
        let schema = try WorkspaceArchive.captureSchema(raw, present: present)
        try #require(schema.migrations == Self.twelve)
        try ArchivePublication.write(to: v4) { handle in
          _ = try WorkspaceArchive.write(raw, schema: schema, purpose: "preMigration", handle: handle)
        }
        try raw.execute("COMMIT")
      } catch { try? raw.execute("ROLLBACK"); throw error }
    }
    for path in [v3, v4] {
      let target = try AgentProtocolResourceFixture.database()
      let outcome = Result<Void, any Error> { () throws -> Void in
        try target.restore(from: path)
        #expect(try target.read { try Self.snapshot($0) } == before)
        #expect(try target.appliedMigrations() == Self.thirteen)
        try target.read { try AgentProtocolFoundationFixture.assertAdditionsNullAndPrivateEmpty($0) }
        #expect(
          try target.read {
            try $0.execute("SELECT 1 FROM \"schemaMigrations\" WHERE \"appliedAt\"='published12'").rows
              .isEmpty
          })
      }
      try target.close()
      try outcome.get()
    }
    let source = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backups)
    let outcome = Result<Void, any Error> { () throws -> Void in
      #expect(try source.appliedMigrations() == Self.thirteen)
      try source.read { try AgentProtocolFoundationFixture.assertAdditionsNullAndPrivateEmpty($0) }
      #expect(try source.read { try Self.snapshot($0) } == before)
      #expect(try source.appFolder(threadId: "t")?.path == "/fixture/app")
      #expect(try source.thread(id: "t")?.environmentId == nil)
      let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups)
      try #require(backupNames.count == 1 && backupNames[0].hasSuffix(".jsonl"))
      let backup = try WorkspaceArchive.read(
        Data(contentsOf: URL(fileURLWithPath: backups + "/" + backupNames[0])))
      #expect(backup.records["schemaMigrations"]?.compactMap { $0.row["name"] as? String } == Self.twelve)
      #expect(backup.records["appFolders"]?.first?.row["threadId"] as? String == "t")
      let nativePayload = try source.read {
        try $0.execute(#"SELECT payload::text AS payload FROM "displayItems" WHERE id='i'"#).rows.first?.text(
          "payload")
      }
      #expect(backup.records["displayItems"]?.first?.row["payload"] as? String == nativePayload)
      try source.export(to: root + "/current13.jsonl")
      let exported = try WorkspaceArchive.read(
        Data(contentsOf: URL(fileURLWithPath: root + "/current13.jsonl")))
      #expect(exported.records["appFolders"]?.first?.row["threadId"] as? String == "t")
    }
    try source.close()
    try outcome.get()
    let published = try FileManager.default.contentsOfDirectory(atPath: backups).sorted()
    let reopened = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backups)
    let reopenedOutcome = Result<Void, any Error> { () throws -> Void in
      #expect(try reopened.read { try Self.snapshot($0) } == before)
      #expect(try reopened.appliedMigrations() == Self.thirteen)
      #expect(try FileManager.default.contentsOfDirectory(atPath: backups).sorted() == published)
    }
    try reopened.close()
    try reopenedOutcome.get()
  }

  private static func snapshot(_ raw: PostgresConnection) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    for table in publishedTables {
      let projection =
        table == "connections"
        ? "to_jsonb(t) - ARRAY['peerProfile','agentId','authMode','authHeaderName','protocolRetiredAt','protocolRetiredReason']"
        : "to_jsonb(t)"
      result[table] = try raw.execute(
        "SELECT (\(projection))::text AS row FROM \(Rows.quote(table)) t ORDER BY 1"
      ).rows.compactMap { $0.text("row") }
    }
    return result
  }

  private static func lines(_ values: [[String: Any]]) throws -> Data {
    try values.reduce(into: Data()) { data, value in
      data += try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data("\n".utf8)
    }
  }
}
