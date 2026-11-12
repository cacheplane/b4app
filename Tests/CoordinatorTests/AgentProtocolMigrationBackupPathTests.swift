import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

@Suite(.serialized) struct AgentProtocolMigrationBackupPathTests {
  private static let fakeCredential = "A3_FAKE_ENDPOINT_VALUE_MUST_NOT_ENTER_ARCHIVE"

  private struct Snapshot: Sendable {
    var rows: [String: [String]]
    var jsonColumns: [String: Set<String>]
    var migrations: [String]
    var archiveFacts: AgentProtocolFoundationFixture.ArchiveFacts
  }

  private struct Fixture: Sendable {
    let paths: PlatformPaths
    let raw: PostgresConnection
    let before: Snapshot
    let root: String
    let backupDirectory: String
    let secrets: MemorySecretStore
    let authRef: SecretRef
  }

  private static func fixture() async throws -> Fixture {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    #expect(endpoint.dataDir == nil)
    let lib = try LibPQ.load(binDir: endpoint.binDir!)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName())"
    let admin = try PostgresConnection(lib: lib, connectionString: base + " dbname=postgres")
    // A dot is valid in this private database name but must be encoded in its backup component.
    let database = "a3.path_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try admin.execute("ALTER DATABASE \(Rows.quote(endpoint.database)) RENAME TO \(Rows.quote(database))")
    endpoint.database = database
    let raw = try PostgresConnection(lib: lib, connectionString: base + " dbname=\(database)")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    for file in try Migrator.files() where file.name <= "0008_thread_delete" {
      try raw.execute(file.sql)
      try raw.execute(
        #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#, [file.name])
    }
    try raw.execute(
      """
      INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt")
        VALUES ('old-project', 'Retained project', true, 'created', 'updated');
      INSERT INTO "projectFolders" ("id", "projectId", "path", "createdAt")
        VALUES ('old-folder', 'old-project', '/fixture/project', 'created');
      INSERT INTO "connections" ("id", "kind", "label", "target", "routeKey", "b4Mode", "nativeScope",
        "projectId", "capabilities", "status", "authStatus", "createdAt", "updatedAt") VALUES
        ('old-b4', 'b4', 'Retained', 'https://example.invalid/base', '/old#agent', 'remote', 'old-scope',
        'old-project', '{}', 'ready', 'authenticated', 'created', 'updated');
      INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "nativeScope", "projectId",
        "readTurnId", "createdAt", "updatedAt") VALUES
        ('old-thread', 'old-b4', 'native-old', 'old-scope', 'old-project', 'old-turn', 'created', 'updated');
      INSERT INTO "turns" ("id", "threadId", "operationId", "status", "submission", "outcome",
        "createdAt", "updatedAt") VALUES
        ('old-turn', 'old-thread', 'old-operation', 'reconciling', 'unknown', NULL, 'created', 'updated');
      INSERT INTO "runtimeRequests" ("id", "nativeRequestId", "threadId", "turnId", "adapterGeneration",
        "kind", "state", "payload", "createdAt", "updatedAt") VALUES
        ('old-request', '1', 'old-thread', 'old-turn', 1, 'command_approval', 'pending',
        '{"opaque":[true,null,{"text":"🌱"}]}', 'created', 'updated');
      INSERT INTO "displayItems" ("id", "threadId", "turnId", "role", "type", "payload", "sequence",
        "provenance", "createdAt") VALUES
        ('old-item', 'old-thread', 'old-turn', 'assistant', 'agentMessage',
        '{"text":"Partial","opaque":{"unknown":true}}', 0, 'cache', 'created');
      INSERT INTO "drafts" ("threadId", "text", "updatedAt")
        VALUES ('old-thread', 'Retained unsent draft', 'updated');
      """)
    let secrets = MemorySecretStore()
    let authRef = SecretRef.make()
    try await secrets.put(authRef, value: fakeCredential)
    try raw.execute(
      #"UPDATE "connections" SET "authReference" = $1 WHERE "id" = 'old-b4'"#, [authRef.rawValue])
    let root = AgentProtocolResourceFixture.temporaryDirectory + "a3-flavor-path-\(UUID())"
    var complete = false
    defer { if !complete { try? FileManager.default.removeItem(atPath: root) } }
    var paths = PlatformPaths(runtimeDir: root + "/rt", dataDir: root + "/flavor-beta")
    paths.postgres = endpoint  // EXTERNAL: nil dataDir, explicit owned socket/bin/database.
    try FileManager.default.createDirectory(
      atPath: paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let encoded = try #require(
      database.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))))
    #expect(encoded.contains("%2E"))
    let directory = URL(fileURLWithPath: paths.dataDir).appendingPathComponent("backups")
      .appendingPathComponent(encoded).path
    let before = try snapshot(raw)
    complete = true
    return Fixture(
      paths: paths, raw: raw, before: before, root: root, backupDirectory: directory,
      secrets: secrets, authRef: authRef)
  }

  private static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    var rows: [String: [String]] = [:]
    for table in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY 1"
    ).rows.compactMap({ $0.text("tablename") }) {
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
        .rows.compactMap { $0.text("row") }
    }
    var json: [String: Set<String>] = [:]
    for row in try c.execute(
      """
      SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND data_type IN ('json', 'jsonb')
      """
    ).rows {
      json[try #require(row.text("table_name")), default: []]
        .insert(try #require(row.text("column_name")))
    }
    return Snapshot(
      rows: rows, jsonColumns: json, migrations: try Migrator.recorded(c),
      archiveFacts: try AgentProtocolFoundationFixture.archiveFacts(c))
  }

  private static func normalized(_ row: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
  }

  private static func assertBackupAndCurrentStore(_ fixture: Fixture, database: WorkspaceDatabase) throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: fixture.backupDirectory), includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    let archive = try #require(files.first { $0.pathExtension == "jsonl" })
    let text = try String(contentsOf: archive, encoding: .utf8)
    #expect(!text.contains(fakeCredential))
    let document = try AgentProtocolFoundationFixture.readV4(
      text, expectedRows: fixture.before.rows, expectedMigrations: fixture.before.migrations,
      facts: fixture.before.archiveFacts)
    try AgentProtocolFoundationFixture.assertArchiveRows(
      document, oldRows: fixture.before.rows, facts: fixture.before.archiveFacts)
    let fileMode = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions]
    let directoryMode = try FileManager.default.attributesOfItem(atPath: fixture.backupDirectory)[
      .posixPermissions]
    let rootMode = try FileManager.default.attributesOfItem(atPath: fixture.paths.dataDir)[.posixPermissions]
    #expect((fileMode as? NSNumber)?.intValue == 0o600)
    #expect((directoryMode as? NSNumber)?.intValue == 0o700)
    #expect((rootMode as? NSNumber)?.intValue == 0o700)
    #expect(try database.appliedMigrations() == AgentProtocolFoundationFixture.migrations)
    #expect(
      try WorkspaceDatabase.preflightMigration(
        endpoint: fixture.paths.postgres, binDir: fixture.paths.postgres.binDir!) == .current)
    try AgentProtocolFoundationFixture.assertCurrentPreservesOld(fixture.raw, oldRows: fixture.before.rows)
    #expect(try database.connection(id: "old-b4")?.authReference == fixture.authRef.rawValue)
    #expect(try database.turn(id: "old-turn")?.outcome == nil)
    #expect(try database.runtimeRequest(id: "old-request")?.state == .pending)
  }

  @Test func storeBootExternalPendingUsesFlavorPrivateBackupRoot() async throws {
    let fixture = try await Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }
    #expect(fixture.paths.postgres.dataDir == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.paths.databasePath))
    let boot = try await StoreBoot.open(paths: fixture.paths, environment: [:])
    var failure: (any Error)?
    do {
      #expect(boot.ownedServer == nil)
      #expect(boot.imported == nil)
      try Self.assertBackupAndCurrentStore(fixture, database: boot.database)
    } catch { failure = error }
    try? boot.database.close()
    #expect(boot.database.closeForMigration(timeout: .milliseconds(500)))
    if let server = boot.ownedServer {
      let stopped = await Bounded.run(within: .seconds(5)) {
        _ = try? await server.stop(timeout: .seconds(3))
      }
      #expect(stopped, "Unexpected owned server did not stop within the private fixture budget.")
    }
    #expect(try await fixture.secrets.read(fixture.authRef) == Self.fakeCredential)
    if let failure { throw failure }
  }

  @Test func accountScopeExternalPendingUsesFlavorPrivateBackupRoot() async throws {
    let fixture = try await Self.fixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }
    let adapterCalls = Mutex(0), hubCalls = Mutex(0)
    let events = EventLog()
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: fixture.paths, startedAt: "fixture", environment: [:], secretStore: fixture.secrets,
        eventLog: events))
    let link = FakeHubLinkConnection()
    let power = FakePowerAssertions()
    var context = AccountScope.Context(
      paths: fixture.paths, environment: [:], secretStore: fixture.secrets, eventLog: events,
      diagnostics: diagnostics,
      adapterFactory: { _, _, _, _ in
        adapterCalls.withLock { $0 += 1 }
        throw WorkspaceError(.internalError, "A historical path fixture reached a runtime factory.")
      },
      hubAPIFactory: { _, _ in
        hubCalls.withLock { $0 += 1 }
        return FakeHubAPI()
      }, hubLinkConnection: link, powerAssertions: power, checkRetryDelays: [], threadDeleteSweep: .zero)
    context.flavor = .beta
    let row = AccountRow(
      id: UUID().uuidString.lowercased(), hubURL: "https://example.invalid", hubUserId: "fixture-user",
      deviceId: "fixture-device", database: fixture.paths.postgres.database,
      displayName: "Fixture", orgName: "Fixture")
    let scope = try await AccountScope.open(
      row: row,
      cluster: StoreCluster(endpoint: fixture.paths.postgres, binDir: fixture.paths.postgres.binDir!),
      context: context)
    var failure: (any Error)?
    do {
      #expect(try scope.database.hubLink() == nil)
      #expect(try scope.database.listLocalServers().isEmpty)
      try Self.assertBackupAndCurrentStore(fixture, database: scope.database)
    } catch { failure = error }
    let closed = await Bounded.run(within: .seconds(5)) {
      await scope.close(stoppingServers: false, drainTimeout: .zero)
    }
    #expect(closed, "A3 path fixture scope close exceeded its bound.")
    #expect(scope.database.closeForMigration(timeout: .milliseconds(500)))
    #expect(adapterCalls.withLock { $0 } == 0)
    #expect(hubCalls.withLock { $0 } == 0)
    #expect(link.openCount == 0)
    #expect(power.takes == 0)
    #expect(try await fixture.secrets.read(fixture.authRef) == Self.fakeCredential)
    if let failure { throw failure }
  }
}
