import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

struct AgentProtocolAppFolderArchiveIntegrationTests {
  @Test(arguments: [15, 16])
  func publishedTurnFieldsSurviveArchiveRestoreAndUpgrade(prefix: Int) throws {
    let files = Array(try Migrator.files().prefix(prefix))
    let names = files.map(\.name)
    try #require(names.last == (prefix == 16 ? "0016_turn_open_work" : "0015_density"))
    let endpoint = try EphemeralPostgres.endpoint()
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    for file in files {
      try raw.execute(file.sql)
      try raw.execute(
        #"INSERT INTO "schemaMigrations" (name,"appliedAt") VALUES ($1,'published')"#, [file.name])
    }
    try raw.execute(
      """
      SET b4app.replaying='on';
      INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
        VALUES ('c','codex','Native','/fixture/codex','{}','ready','authenticated','then','then');
      INSERT INTO threads (id,"connectionId","nativeThreadId",context,"createdAt","updatedAt")
        VALUES ('t','c','native','/fixture/app','then','then');
      INSERT INTO turns (id,"threadId","operationId",status,submission,outcome,"createdAt","updatedAt")
        VALUES ('u','t','op','terminal','acknowledged','completed','then','then');
      """)
    if prefix == 16 {
      try raw.execute(#"UPDATE turns SET "openWork"=3, origin='runtime-fixture' WHERE id='u'"#)
    }
    try raw.execute("RESET b4app.replaying")

    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/published-v3.jsonl"
    let tables = [
      "localServers", "connections", "environments", "environmentFolders", "threads", "appFolders", "turns",
      "displayItems", "runtimeRequests", "drafts", "viewSettings", "devices", "changes", "columnClocks",
    ]
    var records: [[String: Any]] = [
      ["format": "b4app-export", "version": 3, "at": "2026-11-19T00:00:00Z", "migrations": names]
    ]
    for table in tables {
      for row in try raw.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows {
        var values: [String: Any] = [:]
        for (key, cell) in row.cells { values[key] = try WorkspaceDatabase.jsonObject(cell) }
        records.append(["table": table, "row": values])
      }
    }
    var bytes = Data()
    for record in records {
      bytes.append(try JSONSerialization.data(withJSONObject: record))
      bytes.append(0x0a)
    }
    try bytes.write(to: URL(fileURLWithPath: path))
    let destination = try AgentProtocolResourceFixture.database()
    defer { try? destination.close() }
    _ = try destination.restore(from: path)
    let upgraded = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backups")
    defer { try? upgraded.close() }
    for db in [upgraded, destination] {
      #expect(try db.appliedMigrations().last == "0017_agent_protocol")
      try db.read { c in
        let row = try #require(
          try c.execute(#"SELECT "openWork", origin FROM turns WHERE id='u'"#).rows.first)
        #expect(row.int("openWork") == (prefix == 16 ? 3 : 0))
        #expect(row.text("origin") == (prefix == 16 ? "runtime-fixture" : nil))
      }
    }
  }
}
