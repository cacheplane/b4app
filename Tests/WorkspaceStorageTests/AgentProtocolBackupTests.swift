import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Uses the existing database initializer and a real frozen pending migration to reproduce missing
/// pre-DDL backup behavior. No new product backup/drain API is implemented to make these tests run.
@Suite(.serialized) struct AgentProtocolBackupTests {
  private struct Fixture {
    var endpoint: PostgresEndpoint
    var raw: PostgresConnection
    var backupDirectory: String
  }

  private func fixture() throws -> Fixture {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    // Describe this actual owned cluster, rather than inventing a data directory. Direct database
    // opening does not start/adopt a server. Production account backup paths are database-bound.
    endpoint.dataDir =
      try AgentProtocolResourceFixture.physicalExistingDirectory(
        (endpoint.logPath as NSString).deletingLastPathComponent) + "/data"
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    for migration in try Migrator.files() where migration.name <= "0008_thread_delete" {
      try raw.execute(migration.sql)
      try raw.execute(
        #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#,
        [migration.name])
    }
    try raw.execute(
      """
      INSERT INTO "connections" ("id", "kind", "label", "target", "capabilities", "status",
        "authStatus", "createdAt", "updatedAt")
      VALUES ('preserve', 'codex', 'Before upgrade', '/fixture/codex', '{}', 'ready',
        'authenticated', 'created', 'updated')
      """)
    let backupDirectory =
      (endpoint.dataDir! as NSString).deletingLastPathComponent + "/backups/" + endpoint.database
    return Fixture(endpoint: endpoint, raw: raw, backupDirectory: backupDirectory)
  }

  private func snapshot(_ raw: PostgresConnection) throws -> [String] {
    try raw.execute(
      """
      SELECT 'migration:' || "name" AS fact FROM "schemaMigrations"
      UNION ALL SELECT 'column:' || column_name FROM information_schema.columns
        WHERE table_schema='public' AND table_name='connections'
      UNION ALL SELECT 'row:' || to_jsonb(c)::text FROM "connections" c ORDER BY 1
      """
    ).rows.compactMap { $0.text("fact") }
  }

  private func archives(_ directory: String) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "jsonl" }
  }

  @Test func pendingSchemaGetsAnOldConsistentBackupBeforeDDL() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
    let before = try snapshot(fixture.raw)
    let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
    defer { try? db.close() }
    let files = archives(fixture.backupDirectory)
    #expect(files.count == 1)
    guard let archive = files.first else { return }
    let lines = try String(contentsOf: archive, encoding: .utf8).split(separator: "\n")
    let header = try #require(
      try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
    #expect((header["migrations"] as? [String])?.last == "0008_thread_delete")
    let connectionLine = try #require(lines.first { $0.contains("Before upgrade") })
    #expect(!connectionLine.contains("models"))
    #expect(try snapshot(fixture.raw) != before)
    #expect(try db.connection(id: "preserve")?.label == "Before upgrade")
    let mode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
  }

  @Test func failedBackupLeavesCatalogLedgerAndRowsUntouched() throws {
    let fixture = try fixture()
    let parent = (fixture.backupDirectory as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    try Data("directory blocker".utf8).write(to: URL(fileURLWithPath: fixture.backupDirectory))
    defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
    let before = try snapshot(fixture.raw)
    var refused = false
    do {
      let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
      try db.close()
    } catch { refused = true }
    #expect(refused)
    #expect(try snapshot(fixture.raw) == before)
  }

  @Test func noOpReopenDoesNotWriteAnotherBackup() throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.backupDirectory) }
    let first = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
    try first.close()
    let afterFirst = archives(fixture.backupDirectory)
    #expect(afterFirst.count == 1)
    let again = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
    defer { try? again.close() }
    #expect(archives(fixture.backupDirectory) == afterFirst)
  }

  @Test func futureSchemaRefusesWithoutCreatingABackupOrChangingRows() throws {
    let fixture = try fixture()
    try fixture.raw.execute(
      #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ('9999_future', 'fixture')"#)
    let before = try snapshot(fixture.raw)
    var refused = false
    do {
      let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
      try db.close()
    } catch let error as WorkspaceError { refused = error.code == .incompatibleVersion }
    #expect(refused)
    #expect(try snapshot(fixture.raw) == before)
    #expect(archives(fixture.backupDirectory).isEmpty)
  }
}
