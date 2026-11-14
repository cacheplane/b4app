import Darwin
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceStorage

/// Review-only test fixture: one private current store, no account/session/runtime/network service.
enum AgentProtocolIdentityManagedFixture {
  struct Snapshot: Sendable, Equatable {
    var rows: [String: [String]]
    var catalog: [String]
    var sequences: [String]
  }
  struct Store: Sendable {
    let database: WorkspaceDatabase
    let raw: PostgresConnection
    let endpoint: PostgresEndpoint
    let root: String
  }
  enum SetupFailure: Error { case catalog, processPresent, backendObservation }
  static let historyTables = [
    "environments", "environmentFolders", "threads", "turns", "displayItems",
    "runtimeRequests", "drafts", "protocolSubscriptions", "protocolRunSegments", "protocolOperations",
    "protocolGrantSecrets", "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  static func raw(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }
  private struct Backend: Encodable {
    var pid: Int
    var started: String
    var database: String
    var application: String?
    var state: String?
    var transactionStarted: String?
    var waitType: String?
    var wait: String?
    var inspector: Bool
  }
  private struct BackendClose: Encodable {
    var database: String
    var branch: String
    var before: [Backend]?
    var firstAfter: [Backend]?
    var lastAfter: [Backend]?
    var samples = 0
    var zero = false
    var failure: String?
    var sqlState: String?
    var elapsedMillis: Int64 = 0
  }
  private static func backends(_ c: PostgresConnection, database: String) throws -> [Backend] {
    let rows = try c.execute(
      """
      SELECT pid,backend_start::text AS started,datname,application_name,state,
        xact_start::text AS transaction_started,wait_event_type,wait_event,pid=pg_backend_pid() AS inspector
      FROM pg_stat_activity WHERE datname=$1 AND (application_name='b4app' OR pid=pg_backend_pid())
      ORDER BY pid
      """, [database]
    ).rows
    let values = try rows.map { row in
      guard let pid = row.int("pid"), let started = row.text("started"), let name = row.text("datname")
      else { throw SetupFailure.backendObservation }
      return Backend(
        pid: pid, started: started, database: name, application: row.text("application_name"),
        state: row.text("state"), transactionStarted: row.text("transaction_started"),
        waitType: row.text("wait_event_type"), wait: row.text("wait_event"),
        inspector: row.text("inspector") == "t")
    }
    // Identify the inspector's actual database/backend without excluding a named app session.
    guard values.filter({ $0.inspector && $0.database == database }).count == 1
    else { throw SetupFailure.backendObservation }
    return values
  }
  private static func emitBackendClose(_ stage: String, _ value: BackendClose) throws {
    var line = Data(("A3_BACKEND_CLOSE_" + stage + " ").utf8)
    line.append(try JSONEncoder().encode(value))
    line.append(10)
    try FileHandle.standardOutput.write(contentsOf: line)
  }
  static func withStore(
    branch: String = "identity-managed", _ body: @Sendable (Store) async throws -> Void
  ) async throws {
    // Infrastructure CREATE DATABASE precedes ACK; helper+PG LIVE ACK precedes fixture SQL.
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-identity-managed-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root);
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let inspector = try raw(endpoint)
    let database = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backup", wall: { 4096 })
    defer { try? database.close() }
    let knownMigrations = [
      "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
      "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
      "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
      "0014_connection_commands", "0015_density", "0016_agent_protocol",
    ]
    var failure: (any Error)?
    do {
      guard try database.appliedMigrations() == knownMigrations else { throw SetupFailure.catalog }
      try seed(database)
      try await body(Store(database: database, raw: inspector, endpoint: endpoint, root: root))
    } catch { failure = error }
    var close = BackendClose(database: endpoint.database, branch: branch)
    // Capture observer errors distinctly; the old try? conflated them with remaining backends.
    func recordObservationError(_ error: any Error) {
      close.failure = error is PostgresError ? "sql" : "observation"
      if let pg = error as? PostgresError,
        pg.sqlState.utf8.count == 5,
        pg.sqlState.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) })
      {
        close.sqlState = pg.sqlState
      }
      if failure == nil { failure = SetupFailure.backendObservation }
    }
    do {
      close.before = try Self.backends(inspector, database: endpoint.database)
      try Self.emitBackendClose("BEFORE", close)
    } catch { recordObservationError(error) }
    // Ordinary close remains nonwaiting. Never substitute the migration drain or signal a backend.
    do { try database.close() } catch { if failure == nil { failure = error } }
    let began = ContinuousClock.now
    let deadline = began + .seconds(1)
    if close.failure == nil {
      do {
        repeat {
          let current = try Self.backends(inspector, database: endpoint.database)
          close.samples += 1
          if close.firstAfter == nil { close.firstAfter = current }
          close.lastAfter = current
          // Exact original predicate: ALL b4app sessions for this database must really be absent.
          close.zero = !current.contains { $0.application == "b4app" }
          if close.samples == 1 { try Self.emitBackendClose("FIRST_AFTER", close) }
          if close.zero || ContinuousClock.now >= deadline { break }
          try await Task.sleep(for: .milliseconds(10))
        } while true
      } catch { recordObservationError(error) }
    }
    let elapsed = began.duration(to: ContinuousClock.now).components
    close.elapsedMillis = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
    do {
      // Metadata only: no query text, row values, auth/secret refs, material or raw error messages.
      try Self.emitBackendClose("AFTER", close)
    } catch {
      if failure == nil { failure = SetupFailure.backendObservation }
    }
    let noAppBackends = close.zero && close.failure == nil
    #expect(noAppBackends)
    if !noAppBackends, failure == nil { failure = SetupFailure.backendObservation }
    if let failure { throw failure }
  }
  static func seed(_ db: WorkspaceDatabase) throws {
    try db.write { c in
      try c.execute(
        """
        INSERT INTO "environments" ("id","name","manual","createdAt","updatedAt") VALUES ('project','Retained',true,'created','updated');
        INSERT INTO "environmentFolders" ("id","environmentId","path","createdAt") VALUES ('folder','project','/fixture/project','created');
        """)
    }
    for (index, id, kind) in [
      (0, "legacy", ConnectionKind.b4), (1, "profile", .agentProtocol), (2, "codex", .codex),
      (3, "claude", .claude),
    ] {
      _ = try db.insertConnection(
        Connection(
          id: id, kind: kind, label: "Retained " + id,
          target: kind == .codex || kind == .claude ? "/fixture/" + id : "https://example.invalid/base",
          routeKey: kind == .b4 ? "/chat#agent" : nil, b4Mode: kind == .b4 ? .remote : nil,
          authReference: "secret:fixture-" + id, nativeScope: "scope-" + id, environmentId: "project",
          peerProfile: kind == .agentProtocol ? .agentProtocol : nil,
          agentId: kind == .agentProtocol ? "agent:opaque" : nil,
          authMode: kind == .agentProtocol ? ConnectionAuthMode.none : nil,
          status: .ready, authStatus: .authenticated, createdAt: "created-\(index)", updatedAt: "updated"))
      try db.write { c in
        try c.execute(
          #"INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","title","environmentId","readTurnId","createdAt","updatedAt") VALUES ($1,$2,'same-native','scope-'||$2,'Retained','project',$3,'created','updated')"#,
          ["thread-" + id, id, "turn-" + id])
        try c.execute(
          #"INSERT INTO "turns" ("id","threadId","operationId","nativeTurnId","status","submission","outcome","createdAt","updatedAt") VALUES ($1,$2,$3,'native-turn','reconciling','unknown',NULL,'created','updated')"#,
          ["turn-" + id, "thread-" + id, "operation-" + id])
        try c.execute(
          #"INSERT INTO "displayItems" ("id","threadId","turnId","role","type","payload","sequence","provenance","createdAt") VALUES ($1,$2,$3,'assistant','agentMessage','{"text":"Partial 🌱","opaque":[null,true]}',0,'cache','created')"#,
          ["item-" + id, "thread-" + id, "turn-" + id])
        try c.execute(
          #"INSERT INTO "runtimeRequests" ("id","nativeRequestId","threadId","turnId","adapterGeneration","kind","state","payload","createdAt","updatedAt") VALUES ($1,'7',$2,$3,1,'command_approval','pending','{"opaque":[true,null]}','created','updated')"#,
          ["request-" + id, "thread-" + id, "turn-" + id])
        try c.execute(
          #"INSERT INTO "drafts" ("threadId","text","updatedAt") VALUES ($1,'Deliberately unsent','updated')"#,
          ["thread-" + id])
      }
    }
    // Metadata obligations only: no credential-value material or endpoint SecretStore access.
    try db.write { c in
      try c.execute(
        """
        INSERT INTO "protocolSubscriptions" VALUES ('thread-profile','profile','same-native','generation',NULL,'["messages"]','[[]]','event',7,'{"opaque":true}','updated');
        INSERT INTO "protocolRunSegments" ("connectionId","threadId","identityEpochKind","identityEpochId","namespace","nativeRunId","localTurnId","facts","updatedAt") VALUES ('profile','thread-profile','b4','generation','[]','run','turn-profile','{"unknown":true}','updated');
        INSERT INTO "protocolOperations" ("operationId","connectionId","threadId","kind","operationThreadId","payload","grantReferences","expectations","fingerprint","status","createdAt","updatedAt") VALUES ('protocol-op','profile','thread-profile','opaque-kind','same-native','{"opaque":[true,null]}','[]','{}','opaque-fingerprint','opaque-status','created','updated');
        INSERT INTO "protocolGrants" ("threadId","pausedGeneration","namespace","interruptId","proposalHash","connectionId","grantReference","disposition","updatedAt") VALUES ('thread-profile','generation','[]','interrupt','proposal','profile',NULL,'opaque-disposition','updated');
        INSERT INTO "protocolPromptAnswers" VALUES ('thread-profile','generation','[]','interrupt','proposal','profile','null','opaque-status','updated');
        INSERT INTO "protocolHistoryAnchors" VALUES ('thread-profile','generation','anchor','profile','{}','revision',NULL,'updated');
        """)
    }
  }
  static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    var rows: [String: [String]] = [:]
    for table in try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY 1").rows
      .compactMap({ $0.text("tablename") })
    {
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
        .rows.compactMap { $0.text("row") }
    }
    var catalog: [String] = []
    for sql in [
      "SELECT 'column:'||table_name||':'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'') AS fact FROM information_schema.columns WHERE table_schema='public'",
      "SELECT 'constraint:'||r.relname||':'||c.conname||':'||pg_get_constraintdef(c.oid) AS fact FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public'",
      "SELECT 'index:'||indexname||':'||indexdef AS fact FROM pg_indexes WHERE schemaname='public'",
      "SELECT 'function:'||p.proname||':'||pg_get_functiondef(p.oid) AS fact FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f'",
      "SELECT 'trigger:'||r.relname||':'||t.tgname||':'||pg_get_triggerdef(t.oid) AS fact FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal",
    ] { catalog += try c.execute(sql).rows.compactMap { $0.text("fact") } }
    var sequences: [String] = []
    for name in try c.execute("SELECT sequencename FROM pg_sequences WHERE schemaname='public'").rows
      .compactMap({ $0.text("sequencename") })
    {
      let state = try #require(
        try c.execute("SELECT last_value::text AS value,is_called::text AS called FROM \(Rows.quote(name))")
          .rows.first)
      sequences.append(name + ":" + (state.text("value") ?? "NULL") + ":" + (state.text("called") ?? "NULL"))
    }
    return Snapshot(rows: rows, catalog: catalog.sorted(), sequences: sequences.sorted())
  }
  static func history(_ snapshot: Snapshot) -> [String: [String]] {
    snapshot.rows.filter { historyTables.contains($0.key) }
  }

  /// Direct LocalServerService harness, deliberately NOT the listener/process-based ServerHarness.
  final class LocalServerHarness: Sendable {
    let store: Store
    let service: LocalServerService
    let events: EventLog
    let rememberedPID: Int32 = Int32.max
    private final class CollectedEvents: Sendable {
      struct State: Sendable {
        var events: [AdapterEvent] = []
        var firstConnectionAppendCompleted: [String: ContinuousClock.Instant] = [:]
      }
      let value = Mutex(State())
    }
    private let collected: CollectedEvents
    private let reader: Task<Void, Never>
    init(store: Store) throws {
      self.store = store
      errno = 0
      guard Darwin.kill(Int32.max, 0) == -1, errno == ESRCH,
        ProcessInspector.identity(pid: Int32.max) == nil, !ProcessInspector.isAlive(pid: Int32.max)
      else { throw SetupFailure.processPresent }
      let log = EventLog(epoch: "a3-managed-fixture")
      events = log
      let paths = PlatformPaths(runtimeDir: store.root + "/rt", dataDir: store.root + "/data")
      let instance = LocalServerService(
        context: .init(
          database: store.database, eventLog: log,
          environment: ["PATH": "/nonexistent"], paths: paths))
      service = instance
      let stream = instance.events(), values = CollectedEvents()
      collected = values
      reader = Task {
        for await event in stream {
          values.value.withLock { state in
            state.events.append(event)
            if event.kind == .connectionChanged,
              state.firstConnectionAppendCompleted[event.connectionId] == nil
            {
              // Timestamp completion, not enqueue/stream yield, and publish it atomically with
              // the event to observers. Unknown/missing timestamps can never satisfy the barrier.
              state.firstConnectionAppendCompleted[event.connectionId] = ContinuousClock.now
            }
          }
        }
      }
    }
    func rememberedServer(references: [String], disabled: Bool = false) throws -> LocalServer {
      let server = try store.database.insertLocalServer(
        LocalServer(
          id: "server", name: "fixture-server",
          projectPath: store.root + "/project", nodePath: store.root + "/absent-node",
          cliPath: store.root + "/absent-cli",
          launchMode: .source, requestedPort: 61433, actualPort: 61433, generation: 3, pid: rememberedPID,
          processStartedAt: 1, ownershipVerified: false, health: .ready,
          statusMessage: "Remembered historical row",
          logPath: store.root + "/server.log", createdAt: "created", updatedAt: "updated"))
      for id in references {
        _ = try store.database.updateConnection(id: id) {
          $0.localServerId = server.id; $0.enabled = !disabled
        }
      }
      return server
    }
    func observedCurrentEvent(_ id: String) async -> Bool {
      let began = ContinuousClock.now
      let deadline = began + .seconds(15)
      var foundInLoop = false
      var lastCheck = began
      while ContinuousClock.now < deadline {
        let completed = collected.value.withLock { $0.firstConnectionAppendCompleted[id] }
        lastCheck = ContinuousClock.now
        if let completed, completed <= deadline { foundInLoop = true; break }
        guard ContinuousClock.now < deadline else { break }
        try? await Task.sleep(for: .milliseconds(5))
      }
      // A late observer wake may find a timely append. A late/unknown APPEND stays failure;
      // the final read adds no wait and cannot turn post-deadline delivery into on-time success.
      let final = collected.value.withLock { $0.firstConnectionAppendCompleted[id] }
      let onTime = final.map { $0 <= deadline } ?? false
      let returned = ContinuousClock.now
      func milliseconds(_ instant: ContinuousClock.Instant) -> Int64 {
        let elapsed = began.duration(to: instant).components
        return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
      }
      print(
        "A3_CURRENT_EVENT_OBSERVATION foundInLoop=\(foundInLoop) appendKnown=\(final != nil) onTime=\(onTime) "
          + "observerReturnedLate=\(returned > deadline) lastCheckMilliseconds=\(milliseconds(lastCheck)) "
          + "appendMilliseconds=\(final.map { milliseconds($0) } ?? 0) "
          + "returnedMilliseconds=\(milliseconds(returned))"
      )
      return onTime
    }
    func adapterEvents() -> [AdapterEvent] { collected.value.withLock { $0.events } }
    func finish() async {
      // No live owned/adopted PID exists in these cases: no launch, monitor, health or inFlight task.
      await service.shutdown()
      reader.cancel()
      await reader.value  // actual join, including error paths; never Bounded-as-join.
      await events.finish()
    }
  }
  static func withServer(_ body: @Sendable (LocalServerHarness) async throws -> Void) async throws {
    try await withStore { store in
      let harness = try LocalServerHarness(store: store)
      var failure: (any Error)?
      do { try await body(harness) } catch { failure = error }
      await harness.finish()
      if let failure { throw failure }
    }
  }
}
