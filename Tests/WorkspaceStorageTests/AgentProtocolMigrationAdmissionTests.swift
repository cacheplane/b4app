import Darwin
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Real storage-only admission tests. No account lifecycle, production migration bypass, application server,
/// listener or runtime is introduced to reach the old schema; each method owns its PostgreSQL cluster.
@Suite(.serialized) struct AgentProtocolMigrationAdmissionTests {
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
  }

  private enum FixtureFailure: Error { case barrierTimeout }

  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static func fixture(_ cluster: AdmissionOwnedCluster, pending: Bool = true) throws -> Fixture {
    let endpoint = try cluster.endpoint(dataDir: true)
    let raw = try connection(endpoint)
    if pending {
      try Migrator.ensureLedger(raw, table: Migrator.table)
      for file in try Migrator.files() where file.name <= "0008_thread_delete" {
        try raw.execute(file.sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ($1, 'fixture')"#, [file.name])
      }
      try raw.execute(
        """
        INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt")
          VALUES ('old-project', 'Retained', true, 'created', 'updated');
        INSERT INTO "connections" ("id", "kind", "label", "target", "authReference", "nativeScope",
          "projectId", "capabilities", "status", "authStatus", "createdAt", "updatedAt") VALUES
          ('old-b4', 'b4', 'Retained', 'https://example.invalid/base', 'secret:old-ref', 'old-scope',
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
    }
    return Fixture(endpoint: endpoint, raw: raw)
  }

  private static func snapshot(_ c: PostgresConnection) throws -> [String] {
    var facts = try c.execute("SELECT 'database:' || datname AS fact FROM pg_database").rows
      .compactMap { $0.text("fact") }
    for table in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY 1"
    ).rows.compactMap({ $0.text("tablename") }) {
      facts.append("table:\(table)")
      facts += try c.execute(
        "SELECT 'row:' || $1 || ':' || to_jsonb(t)::text AS fact FROM \(Rows.quote(table)) t",
        [table]
      ).rows.compactMap { $0.text("fact") }
    }
    facts += try c.execute(
      """
      SELECT 'column:' || table_name || ':' || column_name || ':' || data_type || ':' || is_nullable
        || ':' || coalesce(column_default, '') AS fact FROM information_schema.columns
        WHERE table_schema = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    facts += try c.execute(
      """
      SELECT 'constraint:' || r.relname || ':' || c.conname || ':' || pg_get_constraintdef(c.oid) AS fact
        FROM pg_constraint c JOIN pg_class r ON r.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = r.relnamespace WHERE n.nspname = 'public'
      """
    ).rows.compactMap { $0.text("fact") }
    facts += try c.execute(
      "SELECT 'index:' || indexname || ':' || indexdef AS fact FROM pg_indexes WHERE schemaname = 'public'"
    ).rows.compactMap { $0.text("fact") }
    return facts.sorted()
  }

  private static func assertSnapshot(before: [String], after: [String]) {
    let beforeDatabases = before.filter { $0.hasPrefix("database:") }
    let afterDatabases = after.filter { $0.hasPrefix("database:") }
    #expect(afterDatabases == beforeDatabases)
    #expect(after == before)
  }

  private static func backupFiles(_ endpoint: PostgresEndpoint) -> [String] {
    let root = (endpoint.dataDir! as NSString).deletingLastPathComponent + "/backups"
    guard FileManager.default.fileExists(atPath: root) else { return [] }
    return [root]
      + ((FileManager.default.enumerator(
        at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []).map(
        \.path
      ).sorted()
  }

  // Dedicated test work suspends its retained Task instead of blocking a cooperative worker.
  // The nonthrowing overload keeps the drainer's original Task<Bool, Never> result contract.
  private static func onDedicatedMigrationThread<T: Sendable>(
    _ operation: @escaping @Sendable () -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      Thread { continuation.resume(returning: operation()) }.start()
    }
  }

  private static func onDedicatedMigrationThread<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await onDedicatedMigrationThread { Result<T, any Error> { try operation() } }.get()
  }

  private static func observed(
    within budget: Duration = .seconds(2), _ signal: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + budget
    while !signal(), ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
    }
    return signal()
  }

  private static func databasePoolAbsent(_ fixture: Fixture) -> Bool {
    (try? fixture.raw.execute(
      "SELECT 1 FROM pg_stat_activity WHERE datname = $1 AND application_name = 'b4app'",
      [fixture.endpoint.database]
    ).rows.isEmpty) == true
  }

  @Test func pendingPreflightReadsOldSchemaWithoutMutation() async throws {
    try await AdmissionOwnedCluster.withCluster(observation: .pendingPreflight) { cluster in
      let fixture = try Self.fixture(cluster)
      let before = try Self.snapshot(fixture.raw)
      let files = Self.backupFiles(fixture.endpoint)
      let result = Result {
        try WorkspaceDatabase.preflightMigration(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
      }
      // Full no-mutation assertions run even with the unsupported semantic baseline.
      Self.assertSnapshot(before: before, after: try Self.snapshot(fixture.raw))
      #expect(Self.backupFiles(fixture.endpoint) == files)
      #expect(try result.get() == .pending)
    }
  }

  @Test func preflightDistinguishesCurrentEmptyAndMissingWithoutCreation() async throws {
    try await AdmissionOwnedCluster.withCluster { cluster in
      let current = try Self.fixture(cluster, pending: false)
      let database = try WorkspaceDatabase(endpoint: current.endpoint, binDir: current.endpoint.binDir!)
      try database.close()
      let empty = try Self.fixture(cluster, pending: false)
      var missing = empty.endpoint
      missing.database = "a3_missing_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let cases: [(PostgresEndpoint, PostgresConnection, WorkspaceDatabase.MigrationState)] = [
        (current.endpoint, current.raw, .current), (empty.endpoint, empty.raw, .pending),
        (missing, empty.raw, .missing),
      ]
      for (endpoint, inspector, expected) in cases {
        let before = try Self.snapshot(inspector)
        let files = Self.backupFiles(endpoint)
        let result = Result {
          try WorkspaceDatabase.preflightMigration(endpoint: endpoint, binDir: endpoint.binDir!)
        }
        Self.assertSnapshot(before: before, after: try Self.snapshot(inspector))
        #expect(Self.backupFiles(endpoint) == files)
        switch result {
        case .success(let state): #expect(state == expected)
        case .failure(let error):
          Issue.record(
            "Expected \(expected) preflight, received \(WorkspaceError.from(error).code.rawValue).")
        }
      }
      #expect(
        try empty.raw.execute(
          "SELECT 1 FROM pg_database WHERE datname = $1", [missing.database]
        ).rows.isEmpty)
      #expect(
        try empty.raw.execute(#"SELECT to_regclass('"schemaMigrations"')::text AS name"#)
          .rows.first?.text("name") == nil)
    }
  }

  @Test func futurePreflightRefusesBeforeMutationOrBackup() async throws {
    try await AdmissionOwnedCluster.withCluster { cluster in
      let fixture = try Self.fixture(cluster)
      try fixture.raw.execute(
        #"INSERT INTO "schemaMigrations" ("name", "appliedAt") VALUES ('9999_future', 'fixture')"#)
      let before = try Self.snapshot(fixture.raw)
      let files = Self.backupFiles(fixture.endpoint)
      var code: ErrorCode?
      do {
        _ = try WorkspaceDatabase.preflightMigration(
          endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
      } catch { code = WorkspaceError.from(error).code }
      #expect(code == .incompatibleVersion)
      Self.assertSnapshot(before: before, after: try Self.snapshot(fixture.raw))
      #expect(Self.backupFiles(fixture.endpoint) == files)
    }
  }

  @Test func databaseMigrationCloseDrainsLeaseAndBoundsTimeout() async throws {
    try await AdmissionOwnedCluster.withCluster { cluster in
      // Successful drain after ordinary close, with one already admitted lease.
      do {
        let fixture = try Self.fixture(cluster, pending: false)
        let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
        defer { try? db.close() }
        let before = try Self.snapshot(fixture.raw)
        let files = Self.backupFiles(fixture.endpoint)
        let entered = Mutex(false), drainStarted = Mutex(false), finished = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let borrower = Task.detached {
          try await Self.onDedicatedMigrationThread {
            try db.read { _ in
              entered.withLock { $0 = true }
              guard release.wait(timeout: .now() + .seconds(8)) == .success else {
                throw FixtureFailure.barrierTimeout
              }
            }
          }
        }
        let ready = await Self.observed { entered.withLock { $0 } }
        // Save a close failure, rather than throwing before release/join.
        let closed = Result { try db.close() }
        let drainer = Task.detached {
          await Self.onDedicatedMigrationThread {
            drainStarted.withLock { $0 = true }
            let result = db.closeForMigration(timeout: .seconds(2))
            finished.withLock { $0 = true }
            return result
          }
        }
        let started = await Self.observed { drainStarted.withLock { $0 } }
        let finishedWhileHeld = await Self.observed(within: .milliseconds(75)) { finished.withLock { $0 } }
        release.signal()
        let borrowed = await borrower.result
        let drained = await drainer.value
        _ = try closed.get()
        _ = try borrowed.get()
        #expect(ready && started)
        #expect(!finishedWhileHeld)
        #expect(drained)
        var refused = false
        do { _ = try db.listConnections() } catch {
          refused = WorkspaceError.from(error).code == .endpointUnavailable
        }
        #expect(refused)
        Self.assertSnapshot(before: before, after: try Self.snapshot(fixture.raw))
        #expect(Self.backupFiles(fixture.endpoint) == files)
        let absent = await Self.observed { Self.databasePoolAbsent(fixture) }
        #expect(absent)
      }
      // Timeout keeps admission closed. This guarded caller is test-owned, not account wiring.
      do {
        let fixture = try Self.fixture(cluster, pending: false)
        let db = try WorkspaceDatabase(endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!)
        defer { try? db.close() }
        let before = try Self.snapshot(fixture.raw)
        let files = Self.backupFiles(fixture.endpoint)
        let entered = Mutex(false), stageCalls = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        let borrower = Task.detached {
          try await Self.onDedicatedMigrationThread {
            try db.read { _ in
              entered.withLock { $0 = true }
              guard release.wait(timeout: .now() + .seconds(8)) == .success else {
                throw FixtureFailure.barrierTimeout
              }
            }
          }
        }
        let ready = await Self.observed { entered.withLock { $0 } }
        let guardCaller = Task.detached {
          try await Self.onDedicatedMigrationThread {
            let start = ContinuousClock.now
            let drained = db.closeForMigration(timeout: .milliseconds(100))
            let elapsed = start.duration(to: .now)
            if drained {
              let c = try Self.connection(fixture.endpoint)
              try WorkspaceDatabase.migrateWithBackup(c, endpoint: fixture.endpoint, backupDirectory: nil) {
                _ in stageCalls.withLock { $0 += 1 }
              }
            }
            return (drained, elapsed)
          }
        }
        let guarded = await guardCaller.result
        let after = Result { try Self.snapshot(fixture.raw) }
        let afterFiles = Self.backupFiles(fixture.endpoint)
        release.signal()
        let borrowed = await borrower.result
        _ = try borrowed.get()
        let (drained, elapsed) = try guarded.get()
        #expect(ready)
        #expect(!drained)
        #expect(elapsed < .seconds(1))
        #expect(stageCalls.withLock { $0 } == 0)
        Self.assertSnapshot(before: before, after: try after.get())
        #expect(afterFiles == files)
        var refused = false
        do { _ = try db.listConnections() } catch {
          refused = WorkspaceError.from(error).code == .endpointUnavailable
        }
        #expect(refused)
        let absent = await Self.observed { Self.databasePoolAbsent(fixture) }
        #expect(absent)
      }
    }
  }
}

private struct AdmissionObservation {
  enum Case: String { case pendingPreflight }
  enum Stage: String {
    case initializer, initialStatus, serverStart, startedStatus, startedIdentity, body, finishCall
    case startAttemptRequired, initialPaths, finishInitialStatus, currentIdentity, retainedIdentityCheck
    case clientDrain, finishBeforeStopStatus, beforeStopIdentity, serverStop, finishAfterStopStatus
    case afterStopAlive, stoppedBranch, uninitializedBranch, savedClientDrainError
    case startedIdentityRequired, finalPaths, removeSocket, removeRoot
  }
  enum Outcome: String { case notAttempted, returned, threw }
  enum Primary: String { case none, original, cleanup, initializer }
  private let testCase: Case
  var lastBoundary: Stage = .initializer
  var initializerOutcome: Outcome = .notAttempted
  var primaryStage: Stage?
  var primaryOutcome: Outcome = .notAttempted
  var finishStage: Stage?
  var finishOutcome: Outcome = .notAttempted
  var savedClientDrainOrigin: Stage?
  var bodyEntered = false
  var selectedPrimary: Primary = .none
  var cleanupRecordedAndRethrown = false

  init(_ testCase: Case) { self.testCase = testCase }

  static func observe<T>(
    _ stage: Stage, observation: inout AdmissionObservation?, _ operation: () throws -> T
  ) rethrows -> T {
    observation?.lastBoundary = stage
    return try operation()
  }

  static func observeAsync<T>(
    _ stage: Stage, observation: inout AdmissionObservation?, _ operation: () async throws -> T
  ) async rethrows -> T {
    observation?.lastBoundary = stage
    return try await operation()
  }

  func emitAfterCleanupDecisions() {
    // Stages are test call boundaries. An outer throw can also be a failed guard AFTER a call
    // returned; neither this cursor nor bodyEntered proves a native operand or assertion ran.
    print(
      "A3_NATIVE_OBSERVATION case=\(testCase.rawValue) initializerOutcome=\(initializerOutcome.rawValue) primaryStage=\(primaryStage?.rawValue ?? "none") primaryOuterOutcome=\(primaryOutcome.rawValue) bodyEntered=\(bodyEntered) finishStage=\(finishStage?.rawValue ?? "none") finishOuterOutcome=\(finishOutcome.rawValue) savedClientDrainOrigin=\(savedClientDrainOrigin?.rawValue ?? "none") selectedPrimary=\(selectedPrimary.rawValue) cleanupRecordedAndRethrown=\(cleanupRecordedAndRethrown)"
    )
  }
}

/// This method owns an isolated catalog, so complete pg_database equality is meaningful.
/// Deliberately not compatible with the old shared-cluster private intent/ACK profile.
private struct AdmissionOwnedCluster: Sendable {
  private enum Failure: Error {
    case privateProfile, pathOwnership, processOwnership, clientsRemain, partialStart, shutdown
  }
  let server: PostgresServer
  let root: String
  private let rootDevice: dev_t, rootInode: ino_t
  private let socketDevice: dev_t, socketInode: ino_t

  private init() throws {
    guard ProcessInfo.processInfo.environment["B4APP_A3_NONCE"] == nil else {
      throw Failure.privateProfile
    }
    guard let bin = PostgresLocator.binDir(anchors: [StorageResources.bundle.bundleURL]) else {
      throw WorkspaceError(.missingExecutable, "No selected PostgreSQL fixture binaries.")
    }
    let base = try AgentProtocolResourceFixture.physicalTemporaryDirectory()
    // Foundation's physical temporary base can exceed sockaddr_un's limit on macOS.
    let socketBase = try AgentProtocolResourceFixture.physicalExistingDirectory("/tmp")
    let name = "b4pg-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(12))"
    let rootPath = base + name
    let socket = socketBase + "/" + name + "s"
    guard mkdir(rootPath, 0o700) == 0 else { throw Failure.pathOwnership }
    guard mkdir(socket, 0o700) == 0 else {
      // Only the exclusively created, still empty root can be removed here.
      guard rmdir(rootPath) == 0 else { throw Failure.pathOwnership }
      throw Failure.pathOwnership
    }
    var r = stat(), s = stat()
    guard lstat(rootPath, &r) == 0, lstat(socket, &s) == 0,
      r.st_mode & S_IFMT == S_IFDIR, s.st_mode & S_IFMT == S_IFDIR,
      r.st_uid == getuid(), s.st_uid == getuid(),
      r.st_mode & 0o7777 == 0o700, s.st_mode & 0o7777 == 0o700
    else { throw Failure.pathOwnership }
    root = rootPath
    rootDevice = r.st_dev; rootInode = r.st_ino
    socketDevice = s.st_dev; socketInode = s.st_ino
    server = PostgresServer(
      cluster: PostgresCluster(
        binDir: bin, dataDir: rootPath + "/data", socketDir: socket, logPath: rootPath + "/postgres.log"))
  }

  static func withCluster(
    observation testCase: AdmissionObservation.Case? = nil, _ body: (Self) async throws -> Void
  ) async throws {
    var observation = testCase.map(AdmissionObservation.init)
    defer { observation?.emitAfterCleanupDecisions() }
    let owner: Self
    do {
      owner = try Self()
      observation?.initializerOutcome = .returned
    } catch {
      observation?.initializerOutcome = .threw
      observation?.primaryStage = .initializer
      observation?.primaryOutcome = .threw
      observation?.selectedPrimary = .initializer
      throw error
    }
    var primary: (any Error)?
    var started: ProcessIdentity?
    var startAttempted = false
    do {
      guard
        try await AdmissionObservation.observeAsync(
          .initialStatus, observation: &observation,
          {
            try await owner.server.status()
          }) == .uninitialized
      else { throw Failure.processOwnership }
      startAttempted = true
      let pid = try await AdmissionObservation.observeAsync(.serverStart, observation: &observation) {
        try await owner.server.start()
      }
      guard
        try await AdmissionObservation.observeAsync(
          .startedStatus, observation: &observation,
          {
            try await owner.server.status()
          }) == .running(pid: pid)
      else { throw Failure.processOwnership }
      started = try AdmissionObservation.observe(.startedIdentity, observation: &observation) {
        try owner.identity(pid)
      }
      observation?.bodyEntered = true
      try await AdmissionObservation.observeAsync(.body, observation: &observation) {
        try await body(owner)
      }
      observation?.primaryStage = .body
      observation?.primaryOutcome = .returned
    } catch {
      let primaryBoundary = observation?.lastBoundary
      observation?.primaryStage = primaryBoundary
      observation?.primaryOutcome = .threw
      observation?.selectedPrimary = .original
      primary = error
    }
    // body returns only after its release/join/close scope and all raw handles have ended.
    // Pass the cursor directly: an outer forwarding borrow would overlap finish's inout borrow.
    observation?.lastBoundary = .finishCall
    do {
      try await owner.finish(started: started, startAttempted: startAttempted, observation: &observation)
      let finishBoundary = observation?.lastBoundary
      observation?.finishStage = finishBoundary
      observation?.finishOutcome = .returned
    } catch {
      let finishBoundary = observation?.lastBoundary
      observation?.finishStage = finishBoundary
      observation?.finishOutcome = .threw
      Issue.record(error)
      if primary == nil {
        primary = error
        observation?.selectedPrimary = .cleanup
        observation?.cleanupRecordedAndRethrown = true
      }
    }
    if let primary { throw primary }
  }

  private func identity(_ pid: Int32) throws -> ProcessIdentity {
    let cluster = server.cluster
    guard pid > 0, let before = ProcessInspector.identity(pid: pid),
      let executable = ProcessInspector.executablePath(pid: pid),
      URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        == URL(fileURLWithPath: cluster.binDir + "/postgres").resolvingSymlinksInPath().path,
      let d = before.arguments.firstIndex(of: "-D"), before.arguments.indices.contains(d + 1),
      before.arguments[d + 1] == cluster.dataDir,
      ProcessInspector.identity(pid: pid) == before
    else { throw Failure.processOwnership }
    return before
  }

  private func maintenance() throws -> PostgresConnection {
    let c = server.cluster
    return try PostgresConnection(
      lib: LibPQ.load(binDir: c.binDir),
      connectionString: "host=\(c.socketDir) port=\(c.port) user=\(c.user) dbname=postgres")
  }

  func endpoint(dataDir: Bool) throws -> PostgresEndpoint {
    let name = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let admin = try maintenance()
    try admin.execute("CREATE DATABASE \(Rows.quote(name))")
    let c = server.cluster
    return PostgresEndpoint(
      socketDir: c.socketDir, port: c.port, database: name, dataDir: dataDir ? c.dataDir : nil,
      logPath: c.logPath, binDir: c.binDir)
  }

  private func noOtherClients() async throws {
    let observer = try maintenance()
    let deadline = ContinuousClock.now + .seconds(3)
    while true {
      if try observer.execute(
        "SELECT 1 FROM pg_stat_activity WHERE backend_type='client backend' AND pid<>pg_backend_pid()"
      ).rows.isEmpty {
        return
      }
      guard ContinuousClock.now < deadline else { throw Failure.clientsRemain }
      try await Task.sleep(for: .milliseconds(10))
    }
    // The observer's lexical ownership ends before finish invokes stop.
  }

  private func pathsUnchanged() throws {
    var r = stat(), s = stat()
    guard lstat(root, &r) == 0, lstat(server.cluster.socketDir, &s) == 0,
      r.st_mode & S_IFMT == S_IFDIR, s.st_mode & S_IFMT == S_IFDIR,
      r.st_dev == rootDevice, r.st_ino == rootInode,
      s.st_dev == socketDevice, s.st_ino == socketInode,
      r.st_uid == getuid(), s.st_uid == getuid(),
      r.st_mode & 0o7777 == 0o700, s.st_mode & 0o7777 == 0o700
    else { throw Failure.pathOwnership }
  }

  private func finish(
    started: ProcessIdentity?, startAttempted: Bool, observation: inout AdmissionObservation?
  ) async throws {
    // A refused initial status cannot authorize SQL or stop against a discovered process.
    observation?.lastBoundary = .startAttemptRequired
    guard startAttempted else { throw Failure.processOwnership }
    try AdmissionObservation.observe(.initialPaths, observation: &observation) { try pathsUnchanged() }
    var cleanupFailure: (any Error)?
    switch try await AdmissionObservation.observeAsync(
      .finishInitialStatus, observation: &observation,
      {
        try await server.status()
      })
    {
    case .running(let pid):
      let current = try AdmissionObservation.observe(.currentIdentity, observation: &observation) {
        try identity(pid)
      }  // PID0 or unknown/changed executable never reaches stop.
      if let started {
        observation?.lastBoundary = .retainedIdentityCheck
        guard current.pid == started.pid, current.startedAt == started.startedAt else {
          throw Failure.processOwnership
        }
      }
      do {
        try await AdmissionObservation.observeAsync(.clientDrain, observation: &observation) {
          try await noOtherClients()
        }
      } catch {
        observation?.savedClientDrainOrigin = .clientDrain
        cleanupFailure = error
      }
      // Even failed client-drain proof stays failed after this owned FAST stop.
      guard
        try await AdmissionObservation.observeAsync(
          .finishBeforeStopStatus, observation: &observation,
          {
            try await server.status()
          }) == .running(pid: pid),
        try AdmissionObservation.observe(
          .beforeStopIdentity, observation: &observation,
          {
            try identity(pid)
          }) == current
      else { throw Failure.processOwnership }
      try await AdmissionObservation.observeAsync(.serverStop, observation: &observation) {
        try await server.stop()
      }
      guard
        try await AdmissionObservation.observeAsync(
          .finishAfterStopStatus, observation: &observation,
          {
            try await server.status()
          }) == .stopped,
        AdmissionObservation.observe(
          .afterStopAlive, observation: &observation,
          {
            !ProcessInspector.isAlive(pid: pid)
          })
      else { throw Failure.shutdown }
    case .stopped:
      // Bodies never stop this actor. Do not skip the required client/awaited-stop proof.
      observation?.lastBoundary = .stoppedBranch
      throw Failure.shutdown
    case .uninitialized:
      observation?.lastBoundary = .uninitializedBranch
      throw Failure.partialStart  // Preserve uncertain/partial startup evidence.
    }
    if let cleanupFailure {
      observation?.lastBoundary = .savedClientDrainError
      throw cleanupFailure
    }  // Retain evidence; never normalize a drain failure.
    observation?.lastBoundary = .startedIdentityRequired
    guard started != nil else { throw Failure.partialStart }  // Keep failed-start logs even after owned stop.
    try AdmissionObservation.observe(.finalPaths, observation: &observation) { try pathsUnchanged() }
    try AdmissionObservation.observe(.removeSocket, observation: &observation) {
      try FileManager.default.removeItem(atPath: server.cluster.socketDir)
    }
    try AdmissionObservation.observe(.removeRoot, observation: &observation) {
      try FileManager.default.removeItem(atPath: root)
    }
  }
}

private final class AdmissionObservationSentinel: Error {}

@Suite private struct AgentProtocolAdmissionObservationMechanicalTests {
  @Test func forwardingPreservesGuardShortCircuitAndReferenceIdentity() async throws {
    let sentinel = AdmissionObservationSentinel()
    var observation: AdmissionObservation? = AdmissionObservation(.pendingPreflight)
    var firstCalls = 0
    var secondCalls = 0
    var accepted = false
    if AdmissionObservation.observe(
      .finishBeforeStopStatus, observation: &observation,
      {
        firstCalls += 1
        return false
      }),
      AdmissionObservation.observe(
        .beforeStopIdentity, observation: &observation,
        {
          secondCalls += 1
          return true
        })
    {
      accepted = true
    }
    #expect(!accepted)
    #expect(firstCalls == 1)
    #expect(secondCalls == 0)
    #expect(observation?.lastBoundary == .finishBeforeStopStatus)
    do {
      if try AdmissionObservation.observe(
        .finishBeforeStopStatus, observation: &observation,
        { () throws -> Bool in
          firstCalls += 1
          throw sentinel
        }),
        AdmissionObservation.observe(
          .beforeStopIdentity, observation: &observation,
          {
            secondCalls += 1
            return true
          })
      {
        accepted = true
      }
      Issue.record("Expected the identical first-operand sentinel.")
    } catch {
      #expect((error as? AdmissionObservationSentinel) === sentinel)
    }
    #expect(!accepted)
    #expect(firstCalls == 2)
    #expect(secondCalls == 0)
    #expect(observation?.lastBoundary == .finishBeforeStopStatus)

    if await AdmissionObservation.observeAsync(
      .finishAfterStopStatus, observation: &observation,
      {
        firstCalls += 1
        return false
      }),
      AdmissionObservation.observe(
        .afterStopAlive, observation: &observation,
        {
          secondCalls += 1
          return true
        })
    {
      accepted = true
    }
    #expect(!accepted)
    #expect(firstCalls == 3)
    #expect(secondCalls == 0)
    #expect(observation?.lastBoundary == .finishAfterStopStatus)
    do {
      if try await AdmissionObservation.observeAsync(
        .finishAfterStopStatus, observation: &observation,
        { () async throws -> Bool in
          firstCalls += 1
          throw sentinel
        }),
        AdmissionObservation.observe(
          .afterStopAlive, observation: &observation,
          {
            secondCalls += 1
            return true
          })
      {
        accepted = true
      }
      Issue.record("Expected the identical async first-operand sentinel.")
    } catch {
      #expect((error as? AdmissionObservationSentinel) === sentinel)
    }
    #expect(!accepted)
    #expect(firstCalls == 4)
    #expect(secondCalls == 0)
    #expect(observation?.lastBoundary == .finishAfterStopStatus)

    let forwarded = AdmissionObservation.observe(.currentIdentity, observation: &observation) { sentinel }
    #expect(forwarded === sentinel)
    let asyncForwarded = await AdmissionObservation.observeAsync(.startedIdentity, observation: &observation)
    {
      sentinel
    }
    #expect(asyncForwarded === sentinel)
    #expect(observation?.lastBoundary == .startedIdentity)
    // Nil is the default path: forwarding still invokes exactly once without creating observation state.
    var absent: AdmissionObservation?
    let withoutObservation = AdmissionObservation.observe(.currentIdentity, observation: &absent) {
      firstCalls += 1
      return sentinel
    }
    #expect(withoutObservation === sentinel)
    #expect(firstCalls == 5)
    #expect(absent == nil)
    // lastBoundary is a call boundary, not proof that a native operand threw. The original
    // withCluster/finish error-selection algorithm remains literal and is audited as source.
  }
}
