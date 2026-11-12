import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

actor L1Secrets: SecretStore {
  struct Operations: Sendable, Equatable {
    var puts: [SecretRef] = []
    var removes: [SecretRef] = []
  }
  private let memory = MemorySecretStore()
  private var recorded = Operations()
  nonisolated var backend: String { "memory-l1-fixture" }
  func put(_ ref: SecretRef, value: String) async throws {
    recorded.puts.append(ref)
    try await memory.put(ref, value: value)
  }
  func read(_ ref: SecretRef) async throws -> String? { try await memory.read(ref) }
  func remove(_ ref: SecretRef) async throws -> Bool {
    recorded.removes.append(ref)
    return try await memory.remove(ref)
  }
  func operations() -> Operations { recorded }
}

final class L1Release: Sendable {
  private let released = Mutex(false)
  private let action: @Sendable () -> Void
  init(_ action: @escaping @Sendable () -> Void) { self.action = action }
  func run() {
    let first = released.withLock { value in
      defer { value = true }
      return !value
    }
    if first { action() }
  }
}

/// Owns only this fixture's blockers/tasks. Releases BEFORE joins, including setup/oracle failures.
final class L1Cleanup: Sendable {
  private struct State {
    var releases: [L1Release] = []
    var joins: [@Sendable () async -> Void] = []
    var managers: [AccountManager] = []
    var scopes: [AccountScope] = []
    var databases: [WorkspaceDatabase] = []
    var registries: [AccountRegistry] = []
    var roots: [String] = []
    var backendAudits: [(endpoint: PostgresEndpoint, inspector: PostgresConnection)] = []
  }
  private let state = Mutex(State())
  @discardableResult func release(_ action: @escaping @Sendable () -> Void) -> L1Release {
    let once = L1Release(action)
    state.withLock { $0.releases.append(once) }
    return once
  }
  func join(_ action: @escaping @Sendable () async -> Void) { state.withLock { $0.joins.append(action) } }
  func own(_ manager: AccountManager) { state.withLock { $0.managers.append(manager) } }
  func own(_ scope: AccountScope) { state.withLock { $0.scopes.append(scope) } }
  func own(_ database: WorkspaceDatabase) { state.withLock { $0.databases.append(database) } }
  func own(_ registry: AccountRegistry) { state.withLock { $0.registries.append(registry) } }
  func own(root: String) { state.withLock { $0.roots.append(root) } }
  func auditBackend(_ endpoint: PostgresEndpoint, inspector: PostgresConnection) {
    state.withLock { $0.backendAudits.append((endpoint, inspector)) }
  }
  func finish() async {
    let owned = state.withLock { value in
      defer { value = State() }
      return value
    }
    for release in owned.releases.reversed() { release.run() }
    for join in owned.joins { await join() }
    // Await actual owner calls; Bounded.run's cancellation is not treated as a join.
    for manager in owned.managers { await manager.shutdown() }
    for scope in owned.scopes {
      await scope.close(stoppingServers: false, drainTimeout: .zero)
      #expect(scope.database.closeForMigration(timeout: .seconds(2)))
    }
    for database in owned.databases {
      try? database.close()
      #expect(database.closeForMigration(timeout: .seconds(2)))
    }
    for registry in owned.registries { registry.close() }
    for audit in owned.backendAudits {
      #expect(
        await AgentProtocolAccountMigrationTests.observed {
          (try? audit.inspector.execute(
            "SELECT 1 FROM pg_stat_activity WHERE application_name='b4app' AND datname=$1",
            [audit.endpoint.database]
          ).rows.isEmpty) == true
        })
    }
    for root in owned.roots {
      try? FileManager.default.removeItem(atPath: root)
      #expect(!FileManager.default.fileExists(atPath: root))
    }
  }
}

// Fixed primitive-only events; neither task entry nor call issuance claims actor entry.
private final class L1PhaseTrace: Sendable {
  enum Case: String, Sendable { case quiescence, gateTimeout }
  enum Stage: String, Sendable {
    case taskEntered, signInCallIssued, signInReturned, finished
    case lockObservationEntered, nativeObservationCompleted, lockObservationReturned
    case completionObservationEntered, completionObservationReturned
    case bodyScopeClosing, bodyRunFinished, cleanupJoined
  }
  private struct Event: Sendable {
    let stage: Stage
    let milliseconds: Int64
    let flag: Bool?
  }
  private struct State: Sendable {
    var events: [Event] = []
    var overflow = false
  }
  private let started = ContinuousClock.now
  private let state = Mutex(State())
  private let testCase: Case
  init(_ testCase: Case) { self.testCase = testCase }

  func record(_ stage: Stage, flag: Bool? = nil) {
    let elapsed = started.duration(to: .now).components
    let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    state.withLock { value in
      guard value.events.count < 32 else { value.overflow = true; return }
      value.events.append(Event(stage: stage, milliseconds: milliseconds, flag: flag))
    }
  }

  // Called only after withFixture returned, including its releases and actual retained Task joins.
  func emitAfterCleanup() {
    record(.cleanupJoined)
    let snapshot = state.withLock { $0 }
    let fields = snapshot.events.map { event in
      let flag = event.flag.map { $0 ? "true" : "false" } ?? "none"
      return "\(event.stage.rawValue):\(event.milliseconds):\(flag)"
    }.joined(separator: ";")
    print("A3_ACCOUNT_PHASE case=\(testCase.rawValue) overflow=\(snapshot.overflow) events=\(fields)")
  }
}

final class L1RunState: Sendable { let finished = Mutex(false) }

final class L1FactoryCalls: Sendable {
  private let count = Mutex(0)
  func record() { count.withLock { $0 += 1 } }
  var value: Int { count.withLock { $0 } }
}

@Suite(.serialized) struct AgentProtocolAccountMigrationTests {
  static let hubURL = "https://fixture.invalid"
  static let accountValue = "L1_FAKE_OLD_ACCOUNT_VALUE"
  static let endpointValue = "L1_FAKE_ENDPOINT_VALUE"
  enum SetupFailure: Error {
    case unexpectedMigrationSet, missingScope, malformedLedger, missingFunction
    case canonicalMismatch, setupGateTimeout, observationTimeout, leaseGuardTimeout
  }
  struct Snapshot: Sendable, Equatable {
    var rows: [String: [String]]
    var catalog: [String]
    var jsonColumns: [String: Set<String>]
    var migrations: [String]
    var archiveFacts: AgentProtocolFoundationFixture.ArchiveFacts
    var additiveSQLNull: [String: Bool]
  }
  struct Fixture: Sendable {
    let manager: AccountManager
    let hubURL: String
    let diagnostics: DiagnosticsService
    let registry: AccountRegistry
    let registryRaw: PostgresConnection
    let scope: AccountScope
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let paths: PlatformPaths
    let secrets: L1Secrets
    let accountRef: SecretRef
    let endpointRef: SecretRef
    let before: Snapshot
    let registryBefore: Snapshot
    let secretBefore: L1Secrets.Operations
    let adapterCalls: L1FactoryCalls
  }
  struct Run: Sendable {
    let task: Task<Result<AccountStatus.Result, any Error>, Never>
    let state: L1RunState
  }

  /// Held synchronous leases must not occupy Swift's cooperative executor while their
  /// async controller arranges release. The existing Task handle still awaits the result.
  static func onDedicatedLeaseThread<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      Thread {
        do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
      }.start()
    }
  }

  static func session(other: Bool = false) -> AuthSession {
    AuthSession(
      deviceId: other ? "dev-l1-b" : "dev-l1-a", token: other ? "L1_FAKE_NEW_B" : "L1_FAKE_NEW_A",
      org: OrgInfo(slug: "fixture-org", name: "Fixture Org"),
      user: UserInfo(username: other ? "fixture-b" : "fixture-a", displayName: "Fixture"),
      needsOnboarding: false,
      userId: other ? "0197bbbb-0000-7000-8000-00000000b002" : "0197aaaa-0000-7000-8000-00000000a001")
  }

  static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database) application_name=a3_l1_fixture"
    )
  }

  static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    var rows: [String: [String]] = [:]
    var catalog: [String] = []
    for table in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY 1"
    ).rows.compactMap({ $0.text("tablename") }) {
      catalog.append("table:\(table)")
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
        .rows.compactMap { $0.text("row") }
    }
    catalog += try c.execute(
      """
      SELECT 'column:' || table_name || ':' || column_name || ':' || ordinal_position::text || ':' ||
        data_type || ':' || udt_name || ':' || is_nullable || ':' || coalesce(column_default, '') AS fact
        FROM information_schema.columns WHERE table_schema = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    catalog += try c.execute(
      """
      SELECT 'constraint:' || r.relname || ':' || c.conname || ':' || pg_get_constraintdef(c.oid) AS fact
        FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    catalog += try c.execute(
      "SELECT 'index:' || indexname || ':' || indexdef AS fact FROM pg_indexes WHERE schemaname = 'public'"
    ).rows.compactMap { $0.text("fact") }
    catalog += try c.execute(
      """
      SELECT 'trigger:' || r.relname || ':' || pg_get_triggerdef(t.oid) AS fact
        FROM pg_trigger t JOIN pg_class r ON r.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = 'public' AND NOT t.tgisinternal
      """
    ).rows.compactMap { $0.text("fact") }
    catalog += try c.execute(
      """
      SELECT 'function:' || pg_get_functiondef(p.oid) AS fact FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    catalog += try c.execute(
      """
      SELECT 'sequence-structure:' || sequencename || ':' || sequenceowner || ':' || data_type::text || ':' ||
        start_value::text || ':' || min_value::text || ':' || max_value::text || ':' || increment_by::text || ':' ||
        cycle::text || ':' || cache_size::text AS fact FROM pg_sequences WHERE schemaname='public'
      """
    ).rows.compactMap { $0.text("fact") }
    for sequence in try c.execute(
      "SELECT sequencename FROM pg_sequences WHERE schemaname='public' ORDER BY 1"
    ).rows.compactMap({ $0.text("sequencename") }) {
      let value = try #require(
        c.execute("SELECT last_value::text AS value,is_called::text AS called FROM \(Rows.quote(sequence))")
          .rows.first)
      catalog.append(
        "sequence:\(sequence):\(try #require(value.text("value"))):\(try #require(value.text("called")))")
    }
    var json: [String: Set<String>] = [:]
    for row in try c.execute(
      "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND data_type IN ('json','jsonb')"
    ).rows {
      guard let table = row.text("table_name"), let column = row.text("column_name") else {
        throw SetupFailure.canonicalMismatch
      }
      json[table, default: []].insert(column)
    }
    return Snapshot(
      rows: rows, catalog: catalog.sorted(), jsonColumns: json, migrations: try Migrator.recorded(c),
      archiveFacts: try AgentProtocolFoundationFixture.archiveFacts(c),
      additiveSQLNull: try AgentProtocolFoundationFixture.additiveSQLNullFacts(c))
  }

  static func observed(within budget: Duration = .seconds(3), _ value: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + budget
    while !value(), ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
    }
    return value()
  }

  static func canonicalOldStore(
    applied: [String: String], files: [(name: String, sql: String)], through: String = "0008_thread_delete"
  ) throws -> PostgresConnection {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let c = try connection(endpoint)
    try Migrator.ensureLedger(c, table: Migrator.table)
    for file in files where file.name <= through {
      guard let at = applied[file.name] else { throw SetupFailure.malformedLedger }
      try c.execute(file.sql)
      try c.execute(
        #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, $2)"#, [file.name, at])
    }
    return c
  }

  static func reconstructOldStore(_ c: PostgresConnection, files: [(name: String, sql: String)]) throws {
    guard files.map(\.name) == AgentProtocolFoundationFixture.migrations,
      try Migrator.recorded(c) == AgentProtocolFoundationFixture.migrations
    else { throw SetupFailure.unexpectedMigrationSet }
    // This test-only reversal is allowed ONLY on the empty, quiesced initial scope. It cannot erase
    // owner obligations or profile metadata to make an otherwise invalid historical fixture pass.
    guard try c.execute(#"SELECT 1 FROM "hubLink""#).rows.isEmpty
    else { throw SetupFailure.canonicalMismatch }
    for table in AgentProtocolFoundationFixture.protocolTables {
      guard try c.execute("SELECT 1 FROM \(Rows.quote(table)) LIMIT 1").rows.isEmpty
      else { throw SetupFailure.canonicalMismatch }
    }
    let profileFields = [
      "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt", "protocolRetiredReason",
    ]
    let present = profileFields.map { Rows.quote($0) + " IS NOT NULL" }.joined(separator: " OR ")
    guard
      try c.execute("SELECT 1 FROM \"connections\" WHERE \(present) OR \"kind\"='agentProtocol'").rows.isEmpty
    else { throw SetupFailure.canonicalMismatch }
    var allApplied: [String: String] = [:]
    for row in try c.execute(#"SELECT "name", "appliedAt" FROM "schemaMigrations" ORDER BY "name""#).rows {
      guard let name = row.text("name"), let at = row.text("appliedAt"), allApplied[name] == nil
      else { throw SetupFailure.malformedLedger }
      allApplied[name] = at
    }
    guard allApplied.keys.sorted() == AgentProtocolFoundationFixture.migrations else {
      throw SetupFailure.malformedLedger
    }
    for table in [
      "environments", "environmentFolders", "connections", "threads", "appFolders", "viewSettings",
    ] {
      guard try c.execute("SELECT 1 FROM \(Rows.quote(table)) LIMIT 1").rows.isEmpty
      else { throw SetupFailure.canonicalMismatch }
    }
    guard
      try c.execute(
        #"SELECT 1 FROM "changes" WHERE "table" IN ('environments','environmentFolders') OR "column"='environmentId' OR (jsonb_typeof("value")='object' AND "value" ? 'environmentId') LIMIT 1"#
      ).rows.isEmpty,
      try c.execute(
        #"SELECT 1 FROM "columnClocks" WHERE "table" IN ('environments','environmentFolders') OR "column"='environmentId' LIMIT 1"#
      ).rows.isEmpty,
      let ninthSQL = files.first(where: { $0.name == "0009_thread_runtime_choice" })?.sql,
      let ninthStart = ninthSQL.range(of: "CREATE OR REPLACE FUNCTION b4app_record_change()"),
      let ninthEnd = ninthSQL[ninthStart.lowerBound...].range(of: "\n$$;")
    else { throw SetupFailure.canonicalMismatch }
    let ninthFunction = String(ninthSQL[ninthStart.lowerBound..<ninthEnd.upperBound])
    try c.execute("BEGIN")
    do {
      // Explicit dependency order, no CASCADE, no public table row mutation.
      for table in [
        "protocolPromptAnswers", "protocolHistoryAnchors", "protocolOperations", "protocolRunSegments",
        "protocolGrants", "protocolSubscriptions", "protocolGrantSecrets",
      ] {
        try c.execute("DROP TABLE \(Rows.quote(table))")
      }
      try c.execute(#"ALTER TABLE "turns" DROP CONSTRAINT "turns_protocol_owner_key""#)
      try c.execute(#"ALTER TABLE "threads" DROP CONSTRAINT "threads_protocol_owner_key""#)
      for function in [
        "b4app_protocol_secret_references(jsonb)", "b4app_protocol_namespace_array(jsonb)",
        "b4app_protocol_secret_reference(text)", "b4app_protocol_string_array(jsonb)",
      ] {
        try c.execute("DROP FUNCTION " + function)
      }
      try c.execute(
        #"ALTER TABLE "connections" DROP CONSTRAINT "connections_protocol_profile_check", DROP CONSTRAINT "connections_protocol_retirement_check", DROP CONSTRAINT "connections_kind_check""#
      )
      for field in profileFields {
        try c.execute("ALTER TABLE \"connections\" DROP COLUMN \(Rows.quote(field))")
      }
      try c.execute(
        #"ALTER TABLE "connections" ADD CONSTRAINT "connections_kind_check" CHECK ("kind" IN ('codex', 'claude', 'b4'))"#
      )
      guard try c.execute(#"DELETE FROM "schemaMigrations" WHERE "name"='0014_agent_protocol'"#).affected == 1
      else { throw SetupFailure.malformedLedger }
      try c.execute(#"DROP TABLE "viewSettings""#)
      guard try c.execute(#"DELETE FROM "schemaMigrations" WHERE "name"='0013_view_settings'"#).affected == 1
      else { throw SetupFailure.malformedLedger }
      try c.execute(#"DROP TABLE "appFolders""#)
      guard try c.execute(#"DELETE FROM "schemaMigrations" WHERE "name"='0012_app_folders'"#).affected == 1
      else { throw SetupFailure.malformedLedger }
      try c.execute(
        """
        ALTER TABLE "environments" RENAME TO "projects";
        ALTER TABLE "environmentFolders" RENAME TO "projectFolders";
        ALTER TABLE "projectFolders" RENAME COLUMN "environmentId" TO "projectId";
        ALTER TABLE "threads" RENAME COLUMN "environmentId" TO "projectId";
        ALTER TABLE "connections" RENAME COLUMN "environmentId" TO "projectId";
        ALTER INDEX "environmentFoldersByEnvironment" RENAME TO "projectFoldersByProject";
        ALTER INDEX "threadsByEnvironment" RENAME TO "threadsByProject";
        ALTER INDEX "connectionsByEnvironment" RENAME TO "connectionsByProject";
        ALTER TRIGGER "environmentsChanges" ON "projects" RENAME TO "projectsChanges";
        ALTER TRIGGER "environmentFoldersChanges" ON "projectFolders" RENAME TO "projectFoldersChanges";
        """)
      try c.execute(ninthFunction)
      guard try c.execute(#"DELETE FROM "schemaMigrations" WHERE "name"='0011_environments'"#).affected == 1
      else { throw SetupFailure.malformedLedger }
      try c.execute(#"ALTER TABLE "hubLink" DROP COLUMN "ownedAs""#)
      guard try c.execute(#"DELETE FROM "schemaMigrations" WHERE "name"='0010_owned_rows'"#).affected == 1
      else { throw SetupFailure.malformedLedger }
      try c.execute("COMMIT")
    } catch { _ = try? c.execute("ROLLBACK"); throw error }
    // Independent raw canonical0001–0009 catalog, initialization rows, sequence facts and original
    // ledger timestamps. Never copy a reconstructed catalog/row into this reference.
    let reference9 = try canonicalOldStore(
      applied: allApplied, files: files, through: "0009_thread_runtime_choice")
    guard try snapshot(c) == snapshot(reference9) else { throw SetupFailure.canonicalMismatch }
    guard try c.execute(#"SELECT 1 FROM "connections" WHERE "models" IS NOT NULL"#).rows.isEmpty,
      try c.execute(#"SELECT 1 FROM "threads" WHERE "model" IS NOT NULL OR "permission" IS NOT NULL"#).rows
        .isEmpty,
      let sql = files.first(where: { $0.name == "0008_thread_delete" })?.sql,
      let start = sql.range(of: "CREATE OR REPLACE FUNCTION b4app_record_change()"),
      let end = sql[start.lowerBound...].range(of: "\n$$;")
    else { throw SetupFailure.missingFunction }
    let function = String(sql[start.lowerBound..<end.upperBound])
    try c.execute("BEGIN")
    do {
      try c.execute(#"ALTER TABLE "threads" DROP COLUMN "model", DROP COLUMN "permission""#)
      try c.execute(#"ALTER TABLE "connections" DROP COLUMN "models""#)
      try c.execute(function)
      guard
        try c.execute(#"DELETE FROM "schemaMigrations" WHERE "name"='0009_thread_runtime_choice'"#).affected
          == 1
      else { throw SetupFailure.malformedLedger }
      try c.execute("COMMIT")
    } catch { _ = try? c.execute("ROLLBACK"); throw error }
    let applied8 = allApplied.filter { $0.key <= "0008_thread_delete" }
    let reference8 = try canonicalOldStore(applied: applied8, files: files)
    guard try snapshot(c) == snapshot(reference8) else { throw SetupFailure.canonicalMismatch }
  }

  static func seedHistory(
    _ c: PostgresConnection, accountRef: SecretRef, endpointRef: SecretRef,
    hubURL: String = AgentProtocolAccountMigrationTests.hubURL, currentSchema: Bool = false
  ) throws {
    let environmentTable = currentSchema ? "environments" : "projects"
    let foldersTable = currentSchema ? "environmentFolders" : "projectFolders"
    let referenceColumn = currentSchema ? "environmentId" : "projectId"
    try c.execute(
      """
      INSERT INTO "\(environmentTable)" ("id","name","manual","createdAt","updatedAt")
        VALUES ('old-project','Retained',true,'created','updated');
      INSERT INTO "\(foldersTable)" ("id","\(referenceColumn)","path","createdAt")
        VALUES ('old-folder','old-project','/fixture/project','created');
      INSERT INTO "connections" ("id","kind","label","target","routeKey","b4Mode","nativeScope",
        "\(referenceColumn)","capabilities","status","authStatus","createdAt","updatedAt") VALUES
        ('old-b4','b4','Retained','https://example.invalid/base','/old#agent','remote','old-scope',
        'old-project','{}','ready','authenticated','created','updated');
      INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","\(referenceColumn)","readTurnId",
        "createdAt","updatedAt") VALUES ('old-thread','old-b4','native-old','old-scope','old-project',
        'old-turn','created','updated');
      INSERT INTO "turns" ("id","threadId","operationId","status","submission","outcome","createdAt","updatedAt")
        VALUES ('old-turn','old-thread','old-operation','reconciling','unknown',NULL,'created','updated');
      INSERT INTO "runtimeRequests" ("id","nativeRequestId","threadId","turnId","adapterGeneration","kind",
        "state","payload","createdAt","updatedAt") VALUES ('old-request','1','old-thread','old-turn',1,
        'command_approval','pending','{"opaque":[true,null,{"text":"🌱"}]}','created','updated');
      INSERT INTO "displayItems" ("id","threadId","turnId","role","type","payload","sequence","provenance","createdAt")
        VALUES ('old-item','old-thread','old-turn','assistant','agentMessage','{"text":"Partial","opaque":{"unknown":true}}',
        0,'cache','created');
      INSERT INTO "drafts" ("threadId","text","updatedAt") VALUES ('old-thread','Retained unsent draft','updated');
      INSERT INTO "hubLink" ("id","url","deviceId","deviceName","tokenRef","orgSlug","username","cursor","joinedAt")
        VALUES (1,'https://fixture.invalid','dev-l1-a','Fixture Mac','secret:placeholder','fixture-org','fixture-a',0,'joined');
      """)
    try c.execute(
      #"UPDATE "connections" SET "authReference" = $1 WHERE "id" = 'old-b4'"#, [endpointRef.rawValue])
    try c.execute(
      #"UPDATE "hubLink" SET "tokenRef" = $1, "url" = $2 WHERE "id" = 1"#, [accountRef.rawValue, hubURL])
  }

  static func fixture(
    _ cleanup: L1Cleanup, pending: Bool = true, hubURL: String = AgentProtocolAccountMigrationTests.hubURL,
    apiFactory: HubSync.APIFactory? = nil, isolatedDiagnostics: Bool = false,
    adapterFactory: SessionService.AdapterFactory? = nil
  ) async throws -> Fixture {
    let files = try AgentProtocolFoundationFixture.knownFiles()
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-l1-\(UUID())"
    cleanup.own(root: root)
    var paths = PlatformPaths(runtimeDir: root + "/rt", dataDir: root + "/flavor-local")
    paths.postgres = endpoint
    try FileManager.default.createDirectory(
      atPath: paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let initial = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    cleanup.own(initial)
    try initial.close()
    let registryName = AccountManager.registryDatabaseName(for: endpoint)
    let registry = try AccountRegistry(
      endpoint: endpoint, binDir: endpoint.binDir!, databaseName: registryName)
    cleanup.own(registry)
    var registryEndpoint = endpoint
    registryEndpoint.database = registryName
    let registryRaw = try connection(registryEndpoint)
    let secrets = L1Secrets()
    let accountRef = SecretRef.make(), endpointRef = SecretRef.make()
    try await secrets.put(accountRef, value: accountValue)
    try await secrets.put(endpointRef, value: endpointValue)
    let ann = session()
    let row = AccountRow(
      id: UUID().uuidString.lowercased(), hubURL: hubURL, hubUserId: ann.userId!, deviceId: ann.deviceId,
      database: endpoint.database, displayName: ann.user.displayName, orgName: ann.org.name)
    try registry.insert(row)
    try registry.activate(id: row.id, tokenRef: accountRef.rawValue)
    let fake = FakeHubAPI()
    await fake.setSession(ann)
    _ = try await fake.passkeyFinish(
      PasskeyFinishRequest(
        ceremonyId: "fixture", assertion: nil, attestation: nil,
        device: DeviceSpec(deviceName: "Fixture Mac", platform: "macos", deviceId: ann.deviceId)))
    let events = EventLog()
    let adapterCalls = L1FactoryCalls()
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: paths, startedAt: "fixture",
        environment: isolatedDiagnostics
          ? ["PATH": "/nonexistent", "HOME": root, ExecutableLocator.fallbackOverrideVariable: ""] : [:],
        secretStore: secrets, eventLog: events))
    let scopeContext = AccountScope.Context(
      paths: paths, environment: ["PATH": "/nonexistent", "HOME": root], secretStore: secrets,
      eventLog: events, diagnostics: diagnostics,
      adapterFactory: { connection, environment, version, store in
        adapterCalls.record()
        if let adapterFactory { return try adapterFactory(connection, environment, version, store) }
        throw WorkspaceError(.internalError, "L1 fixture reached a native runtime factory.")
      }, hubAPIFactory: apiFactory ?? { _, _ in fake }, hubLinkConnection: FakeHubLinkConnection(),
      powerAssertions: FakePowerAssertions(), checkRetryDelays: [], threadDeleteSweep: .zero)
    let manager = AccountManager(
      context: .init(
        cluster: StoreCluster(endpoint: endpoint, binDir: endpoint.binDir!), registry: registry,
        scope: scopeContext, flavor: .local))
    cleanup.own(manager)
    await manager.start()
    guard let scope = manager.current else { throw SetupFailure.missingScope }
    cleanup.own(scope)
    let raw = try connection(endpoint)
    guard try raw.execute(#"SELECT 1 FROM "hubLink""#).rows.isEmpty else {
      throw SetupFailure.canonicalMismatch
    }
    scope.refuseNewWork()
    let reopenSetupGate = cleanup.release { scope.admitWorkAgain() }
    guard await scope.drain(timeout: .seconds(2)) else { throw SetupFailure.setupGateTimeout }
    if pending { try reconstructOldStore(raw, files: files) }
    try seedHistory(
      raw, accountRef: accountRef, endpointRef: endpointRef, hubURL: hubURL, currentSchema: !pending)
    reopenSetupGate.run()
    let expected: WorkspaceDatabase.MigrationState = pending ? .pending : .current
    guard try WorkspaceDatabase.preflightMigration(endpoint: endpoint, binDir: endpoint.binDir!) == expected
    else {
      throw SetupFailure.canonicalMismatch
    }
    return Fixture(
      manager: manager, hubURL: hubURL, diagnostics: diagnostics, registry: registry,
      registryRaw: registryRaw, scope: scope, endpoint: endpoint,
      raw: raw, paths: paths, secrets: secrets, accountRef: accountRef, endpointRef: endpointRef,
      before: try snapshot(raw), registryBefore: try snapshot(registryRaw),
      secretBefore: await secrets.operations(), adapterCalls: adapterCalls)
  }

  static func withFixture(
    pending: Bool = true, hubURL: String = AgentProtocolAccountMigrationTests.hubURL,
    apiFactory: HubSync.APIFactory? = nil,
    isolatedDiagnostics: Bool = false, adapterFactory: SessionService.AdapterFactory? = nil,
    expectedAdapterFactoryCalls: Int = 0,
    _ body: @Sendable (Fixture, L1Cleanup) async throws -> Void
  ) async throws {
    let cleanup = L1Cleanup()
    var failure: (any Error)?
    var created: Fixture?
    do {
      let fixture = try await fixture(
        cleanup, pending: pending, hubURL: hubURL, apiFactory: apiFactory,
        isolatedDiagnostics: isolatedDiagnostics, adapterFactory: adapterFactory)
      created = fixture
      try await body(fixture, cleanup)
    } catch { failure = error }
    if let current = created?.manager.current { cleanup.own(current) }
    await cleanup.finish()
    if let fixture = created {
      #expect(fixture.adapterCalls.value == expectedAdapterFactoryCalls)
      let absent = await observed {
        (try? fixture.raw.execute(
          "SELECT 1 FROM pg_stat_activity WHERE application_name = 'b4app' AND datname IN ($1,$2)",
          [fixture.endpoint.database, AccountManager.registryDatabaseName(for: fixture.endpoint)]
        ).rows.isEmpty) == true
      }
      #expect(absent, "L1 fixture retained an application database backend after owner shutdown.")
    }
    if let failure { throw failure }
  }

  static func begin(_ fixture: Fixture, _ cleanup: L1Cleanup, session: AuthSession? = nil) -> Run {
    begin(fixture, cleanup, session: session, trace: nil)
  }

  private static func begin(
    _ fixture: Fixture, _ cleanup: L1Cleanup, session: AuthSession? = nil, trace: L1PhaseTrace?
  ) -> Run {
    let state = L1RunState()
    let answer = session ?? Self.session()
    let task = Task {
      trace?.record(.taskEntered)
      defer {
        state.finished.withLock { $0 = true }
        trace?.record(.finished)
      }
      do {
        trace?.record(.signInCallIssued)
        let value = try await fixture.manager.signIn(session: answer, hubURL: fixture.hubURL)
        trace?.record(.signInReturned, flag: true)
        return Result<AccountStatus.Result, any Error>.success(value)
      } catch {
        trace?.record(.signInReturned, flag: false)
        return .failure(error)
      }
    }
    cleanup.join { _ = await task.value }
    return Run(task: task, state: state)
  }

  static func completed(_ run: Run) async throws -> Result<AccountStatus.Result, any Error> {
    try await completed(run, trace: nil)
  }

  // This moves only the fixed native query observer, never the actor-isolated signIn SQL.
  // The deadline is fixed by its caller BEFORE dispatch; late Thread startup gets no new window.
  private static func observedNativeQuery(
    until deadline: ContinuousClock.Instant, trace: L1PhaseTrace,
    _ body: @escaping @Sendable () -> Bool
  ) async -> Bool {
    let retained = Mutex<Thread?>(nil)
    let observed: Bool = await withCheckedContinuation { continuation in
      let observer = Thread {
        var onTime = false
        while ContinuousClock.now < deadline {
          let matched = body()
          let completed = ContinuousClock.now
          if matched, completed <= deadline { onTime = true; break }
          guard completed < deadline else { break }
          Thread.sleep(forTimeInterval: 0.010)
        }
        trace.record(.nativeObservationCompleted, flag: onTime)
        continuation.resume(returning: onTime)
      }
      retained.withLock { $0 = observer }
      observer.start()
    }
    // Actual observer operation completed; this does not assert kernel-thread exit.
    retained.withLock { $0 = nil }
    return observed
  }

  private static func completed(
    _ run: Run, trace: L1PhaseTrace?
  ) async throws -> Result<AccountStatus.Result, any Error> {
    trace?.record(.completionObservationEntered)
    let finished = await observed(within: .seconds(15), { run.state.finished.withLock { $0 } })
    trace?.record(.completionObservationReturned, flag: finished)
    guard finished else { throw SetupFailure.observationTimeout }
    return await run.task.value
  }

  static func directory(_ fixture: Fixture) -> String {
    let component = fixture.endpoint.database.addingPercentEncoding(
      withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-")))!
    return fixture.paths.dataDir + "/backups/" + component
  }

  static func refused<T>(_ result: Result<T, any Error>, code: ErrorCode? = nil) -> Bool {
    if case .failure(let error) = result { return code == nil || WorkspaceError.from(error).code == code }
    return false
  }

  static func unchanged(_ fixture: Fixture) async throws {
    #expect(try snapshot(fixture.raw) == fixture.before)
    #expect(try snapshot(fixture.registryRaw) == fixture.registryBefore)
    #expect(await fixture.secrets.operations() == fixture.secretBefore)
    #expect(try await fixture.secrets.read(fixture.accountRef) == accountValue)
    #expect(try await fixture.secrets.read(fixture.endpointRef) == endpointValue)
    #expect(!FileManager.default.fileExists(atPath: directory(fixture)))
  }

  static func assertHistory(_ before: Snapshot, after: Snapshot) throws {
    #expect(after.migrations == AgentProtocolFoundationFixture.migrations)
    try AgentProtocolFoundationFixture.assertCurrentLedgerAndInventory(after.rows, oldRows: before.rows)
    for (table, columns) in AgentProtocolFoundationFixture.addedColumns {
      for column in columns { #expect(after.additiveSQLNull["\(table).\(column)"] == true) }
    }
    for table in [
      "connections", "projects", "projectFolders", "threads", "turns", "displayItems", "runtimeRequests",
      "drafts", "columnClocks",
    ] {
      let beforeTable =
        before.rows[table] == nil ? AgentProtocolFoundationFixture.currentTable(old: table) : table
      let currentTable = AgentProtocolFoundationFixture.currentTable(old: beforeTable)
      func normalize(_ values: [String], table: String, renameLegacy: Bool) throws -> [String] {
        try values.map { text in
          var row = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          for column in AgentProtocolFoundationFixture.addedColumns[table] ?? [] {
            if let value = row[column] { #expect(value is NSNull) }
            row.removeValue(forKey: column)
          }
          if renameLegacy {
            row = try AgentProtocolFoundationFixture.currentRow(table: table, row: row)
          }
          return try AgentProtocolFoundationFixture.canonical(row)
        }.sorted()
      }
      #expect(
        try normalize(before.rows[beforeTable] ?? [], table: beforeTable, renameLegacy: true)
          == normalize(after.rows[currentTable] ?? [], table: currentTable, renameLegacy: false))
    }
  }

  static func assertArchive(_ fixture: Fixture, expected: Snapshot) throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: directory(fixture)).filter {
      $0.hasSuffix(".jsonl")
    }
    #expect(files.count == 1)
    let path = (directory(fixture) as NSString).appendingPathComponent(try #require(files.first))
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(!text.contains(accountValue) && !text.contains(endpointValue))
    let document = try AgentProtocolFoundationFixture.readV4(
      text, expectedRows: expected.rows, expectedMigrations: expected.migrations, facts: expected.archiveFacts
    )
    try AgentProtocolFoundationFixture.assertArchiveRows(
      document, oldRows: expected.rows, facts: expected.archiveFacts)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        == 0o600)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: directory(fixture))[.posixPermissions] as? NSNumber)?
        .intValue == 0o700)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: fixture.paths.dataDir)[.posixPermissions] as? NSNumber)?
        .intValue == 0o700)
  }

  @Test func sameAccountPendingQuiescesBeforeCapture() async throws {
    let trace = L1PhaseTrace(.quiescence)
    defer { trace.emitAfterCleanup() }
    try await Self.withFixture { fixture, cleanup in
      let writer = try Self.connection(fixture.endpoint)
      let writerPID = try #require(writer.execute("SELECT pg_backend_pid() AS pid").rows.first?.text("pid"))
      try writer.execute("BEGIN")
      let active = Mutex(true)
      let release = cleanup.release {
        if active.withLock({ value in
          defer { value = false }; return value
        }) {
          _ = try? writer.execute("ROLLBACK")
        }
      }
      try writer.execute(
        "SELECT pg_advisory_xact_lock_shared($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
      try writer.execute(
        #"UPDATE "connections" SET "label" = 'Committed before migration' WHERE "id" = 'old-b4'"#)
      let expected = try Self.snapshot(writer)
      let run = Self.begin(fixture, cleanup, trace: trace)
      defer {
        trace.record(.bodyScopeClosing, flag: fixture.scope.isClosing)
        let finished = run.state.finished.withLock { $0 }
        trace.record(.bodyRunFinished, flag: finished)
      }
      trace.record(.lockObservationEntered)
      let nativeDeadline = ContinuousClock.now + .seconds(3)
      let waiting = await Self.observedNativeQuery(until: nativeDeadline, trace: trace) {
        (try? fixture.raw.execute(
          """
          SELECT a.pid FROM pg_stat_activity a JOIN pg_locks l ON l.pid = a.pid
            WHERE a.datname = $1 AND a.application_name = 'b4app' AND l.locktype = 'advisory'
            AND l.mode = 'ExclusiveLock' AND NOT l.granted
            AND $2::int = ANY(pg_blocking_pids(a.pid))
          """, [fixture.endpoint.database, writerPID]
        ).rows.count == 1) == true
      }
      trace.record(.lockObservationReturned, flag: waiting)
      // A missed native prerequisite remains failed; a closing gate alone is not a closed pool.
      try #require(waiting)
      #expect(fixture.scope.isClosing)
      let read = Result {
        try fixture.scope.database.read { try $0.execute(#"SELECT "id" FROM "connections""#) }
      }
      #expect(Self.refused(read, code: .endpointUnavailable))
      // The admitted writer has already allocated its change counter while its rows remain
      // uncommitted. Require its catalog to differ ONLY at this one exact counter value fact.
      let counterPrefix = "sequence:changes_seq_seq:"
      let baselineCounter = fixture.before.catalog.filter { $0.hasPrefix(counterPrefix) }
      let writerCounter = expected.catalog.filter { $0.hasPrefix(counterPrefix) }
      let baselineOtherCatalog = fixture.before.catalog.filter { !$0.hasPrefix(counterPrefix) }
      let writerOtherCatalog = expected.catalog.filter { !$0.hasPrefix(counterPrefix) }
      guard baselineCounter.count == 1, writerCounter.count == 1,
        writerOtherCatalog == baselineOtherCatalog
      else { throw SetupFailure.canonicalMismatch }
      var expectedBeforeCommit = fixture.before
      expectedBeforeCommit.catalog = fixture.before.catalog.map { fact in
        fact.hasPrefix(counterPrefix) ? writerCounter[0] : fact
      }
      #expect(try Self.snapshot(fixture.raw) == expectedBeforeCommit)
      #expect(!FileManager.default.fileExists(atPath: Self.directory(fixture)))
      let commit = Result { try writer.execute("COMMIT") }
      if case .success = commit { active.withLock { $0 = false } }
      release.run()
      _ = try commit.get()
      let result = try await Self.completed(run, trace: trace)
      _ = try result.get()
      try Self.assertArchive(fixture, expected: expected)
      try Self.assertHistory(expected, after: Self.snapshot(fixture.raw))
      #expect(
        try WorkspaceDatabase.preflightMigration(
          endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!) == .current)
      #expect(fixture.manager.current?.instance != fixture.scope.instance)
    }
  }

  @Test func pendingGateTimeoutRestoresSameLiveScopeWithoutMutation() async throws {
    let trace = L1PhaseTrace(.gateTimeout)
    defer { trace.emitAfterCleanup() }
    try await Self.withFixture { fixture, cleanup in
      try fixture.scope.enter()
      let release = cleanup.release { fixture.scope.leave() }
      let run = Self.begin(fixture, cleanup, trace: trace)
      defer {
        trace.record(.bodyScopeClosing, flag: fixture.scope.isClosing)
        let finished = run.state.finished.withLock { $0 }
        trace.record(.bodyRunFinished, flag: finished)
      }
      let result = try await Self.completed(run, trace: trace)
      #expect(Self.refused(result))
      #expect(fixture.manager.current?.instance == fixture.scope.instance)
      #expect(!fixture.scope.isClosing)
      var admitted = false
      do {
        try fixture.scope.enter()
        defer { fixture.scope.leave() }
        _ = try fixture.scope.database.read { try $0.execute(#"SELECT "id" FROM "connections""#) }
        admitted = true
      } catch {}
      #expect(admitted)
      try await Self.unchanged(fixture)
      release.run()
    }
  }

  @Test func pendingPoolTimeoutLeavesUnavailableWithoutDDLOrCredentialReset() async throws {
    try await Self.withFixture { fixture, cleanup in
      let releaseSemaphore = DispatchSemaphore(value: 0)
      let release = cleanup.release { releaseSemaphore.signal() }
      let entered = Mutex(false)
      let borrower = Task.detached {
        try await Self.onDedicatedLeaseThread {
          try fixture.scope.database.read { _ in
            entered.withLock { $0 = true }
            guard releaseSemaphore.wait(timeout: .now() + .seconds(25)) == .success else {
              throw SetupFailure.leaseGuardTimeout
            }
          }
        }
      }
      cleanup.join { _ = await borrower.result }
      guard await Self.observed({ entered.withLock { $0 } }) else { throw SetupFailure.observationTimeout }
      let run = Self.begin(fixture, cleanup)
      let result = try await Self.completed(run)
      #expect(Self.refused(result))
      var admitted = false
      if let current = fixture.manager.current, (try? current.enter()) != nil {
        admitted = true
        current.leave()
      }
      #expect(!admitted)
      let read = Result { try fixture.scope.database.read { try $0.execute("SELECT 1") } }
      #expect(Self.refused(read, code: .endpointUnavailable))
      try await Self.unchanged(fixture)
      release.run()
      _ = try await borrower.value
    }
  }

  @Test func currentAndDifferentAccountOpenPreserveFallbackControls() async throws {
    try await Self.withFixture(pending: false) { fixture, cleanup in
      let semaphore = DispatchSemaphore(value: 0)
      let release = cleanup.release { semaphore.signal() }
      let entered = Mutex(false)
      let borrower = Task.detached {
        try await Self.onDedicatedLeaseThread {
          try fixture.scope.database.read { _ in
            entered.withLock { $0 = true }
            guard semaphore.wait(timeout: .now() + .seconds(25)) == .success else {
              throw SetupFailure.leaseGuardTimeout
            }
          }
        }
      }
      cleanup.join { _ = await borrower.result }
      guard await Self.observed({ entered.withLock { $0 } }) else { throw SetupFailure.observationTimeout }
      let result = try await Self.completed(Self.begin(fixture, cleanup))
      _ = try result.get()
      #expect(!FileManager.default.fileExists(atPath: Self.directory(fixture)))
      try Self.assertHistory(fixture.before, after: Self.snapshot(fixture.raw))
      #expect(try await fixture.secrets.read(fixture.endpointRef) == Self.endpointValue)
      release.run()
      _ = try await borrower.value
    }
    try await Self.withFixture(pending: false) { fixture, cleanup in
      let endpoint = try AgentProtocolResourceFixture.endpoint()
      let future = try Self.connection(endpoint)
      try Migrator.ensureLedger(future, table: Migrator.table)
      for file in try Migrator.files() where file.name <= "0008_thread_delete" {
        try future.execute(file.sql)
        try future.execute(
          #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,'fixture')"#, [file.name])
      }
      try future.execute(
        #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ('9999_future','fixture')"#)
      let bob = Self.session(other: true)
      try fixture.registry.insert(
        AccountRow(
          id: UUID().uuidString.lowercased(), hubURL: Self.hubURL, hubUserId: bob.userId!,
          deviceId: bob.deviceId,
          database: endpoint.database, displayName: bob.user.displayName, orgName: bob.org.name))
      let before = try Self.snapshot(fixture.raw), registryBefore = try Self.snapshot(fixture.registryRaw)
      let futureBefore = try Self.snapshot(future)
      let secretsBefore = await fixture.secrets.operations()
      let result = try await Self.completed(Self.begin(fixture, cleanup, session: bob))
      #expect(Self.refused(result, code: .incompatibleVersion))
      #expect(fixture.manager.current?.instance == fixture.scope.instance)
      #expect(!fixture.scope.isClosing)
      try fixture.scope.enter()
      do {
        defer { fixture.scope.leave() }
        _ = try fixture.scope.database.read { try $0.execute("SELECT 1") }
      }
      #expect(try Self.snapshot(fixture.raw) == before)
      #expect(try Self.snapshot(fixture.registryRaw) == registryBefore)
      #expect(try Self.snapshot(future) == futureBefore)
      #expect(await fixture.secrets.operations() == secretsBefore)
      #expect(try await fixture.secrets.read(fixture.accountRef) == Self.accountValue)
      #expect(try await fixture.secrets.read(fixture.endpointRef) == Self.endpointValue)
      #expect(!FileManager.default.fileExists(atPath: Self.directory(fixture)))
      let futureComponent = try #require(
        endpoint.database.addingPercentEncoding(
          withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))))
      let futureDirectory = fixture.paths.dataDir + "/backups/" + futureComponent
      #expect(!FileManager.default.fileExists(atPath: futureDirectory))
    }
  }
}
