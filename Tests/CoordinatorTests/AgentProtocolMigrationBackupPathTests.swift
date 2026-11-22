import Foundation
import Testing
import WorkspacePlatform

@testable import Coordinator
@testable import WorkspaceStorage

struct AgentProtocolMigrationBackupPathTests {
  @Test func accountOpenBacksUpPublishedSchemaInItsFlavorDirectory() throws {
    let endpoint = try EphemeralPostgres.endpoint()
    let binDir = try #require(endpoint.binDir)
    let host = "host=\(endpoint.socketDir) port=\(endpoint.port)"
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: binDir),
      connectionString: "\(host) user=\(NSUserName()) dbname=\(endpoint.database)")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    let published = try Migrator.files().prefix { $0.name < "0017_agent_protocol" }
    for file in published {
      try raw.execute(file.sql)
      try raw.execute(
        #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,'published')"#, [file.name])
    }
    try raw.execute(#"INSERT INTO settings(key,value) VALUES ('retained','true')"#)
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      UUID().uuidString)
    try PrivateFiles.ensurePrivateDirectory(root.path)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = PlatformPaths(runtimeDir: root.appendingPathComponent("rt").path, dataDir: root.path)
    let row = AccountRow(
      id: "account", hubURL: "https://example.invalid", hubUserId: "user", deviceId: "device",
      database: endpoint.database, displayName: "Fixture", orgName: "Fixture")
    let database = try AccountScope.openDatabase(
      row: row, cluster: StoreCluster(endpoint: endpoint, binDir: binDir), paths: paths,
      createIfMissing: false)
    defer { try? database.close() }
    #expect(try database.settings(key: "retained") == .bool(true))
    #expect(try database.appliedMigrations().contains("0017_agent_protocol"))
    let directory = root.appendingPathComponent("backups").appendingPathComponent(endpoint.database)
    let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(archives.map(\.pathExtension) == ["jsonl"])
  }
}
