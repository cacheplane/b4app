import Darwin
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceStorage

/// No route or adapter: real private storage plus existing public normalization/diagnostics only.
@Suite(.serialized) struct AgentProtocolGrantCredentialTests {
  private typealias Store = ProtocolGrantSecretStore
  private static let owner = Store.Owner(connectionId: "connection-a", threadId: "thread-a")
  private static let message = "The private protocol credential transaction could not be completed."
  private static let stamp = "2026-11-09T00:00:00.000Z"
  private static let native = "11111111-1111-4111-8111-111111111111"
  private static let generation = "22222222-2222-4222-8222-222222222222"
  private static let interrupt = "33333333-3333-4333-8333-333333333333"
  private static let privateTables: Set<String> = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]
  private enum FixtureFailure: Error {
    case unsafeLog, oversizedLog, missingLogControl, unexpectedPositiveControl, unhandledPrivateFailure,
      deliberateRollback, backendObservation
  }
  private struct State: Equatable, Sendable {
    let credentials: Int
    let metadata: [String]
    let cursors: [String]
  }
  private struct OwnedLog: Sendable {
    let path: String
    let device: dev_t
    let inode: ino_t
    init(_ path: String) throws {
      let temporary = URL(fileURLWithPath: AgentProtocolResourceFixture.temporaryDirectory)
        .resolvingSymlinksInPath().standardizedFileURL.path
      let expected = temporary + "/b4pg-shared-\(ProcessInfo.processInfo.processIdentifier)/postgres.log"
      var info = stat()
      guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected,
        lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
      else { throw FixtureFailure.unsafeLog }
      self.path = path; device = info.st_dev; inode = info.st_ino
    }
    func opened() throws -> FileHandle {
      let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
      guard fd >= 0 else { throw FixtureFailure.unsafeLog }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_dev == device, info.st_ino == inode,
        info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid()
      else { Darwin.close(fd); throw FixtureFailure.unsafeLog }
      return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func offset() throws -> UInt64 {
      let h = try opened(); defer { try? h.close() }; return try h.seekToEnd()
    }
    func tail(_ start: UInt64) throws -> String {
      let h = try opened(); defer { try? h.close() }
      let end = try h.seekToEnd()
      guard end >= start, end - start <= 4 << 20 else { throw FixtureFailure.oversizedLog }
      try h.seek(toOffset: start)
      let length = Int(end - start)
      var data = Data()
      while data.count < length {
        guard let chunk = try h.read(upToCount: length - data.count), !chunk.isEmpty
        else { throw FixtureFailure.unsafeLog }
        data.append(chunk)
      }
      return String(decoding: data, as: UTF8.self)
    }
    func observed(_ marker: String, after start: UInt64) async throws -> Bool {
      let end = ContinuousClock.now + .seconds(2)
      repeat {
        if try tail(start).contains(marker) { return true }
        try await Task.sleep(for: .milliseconds(10))
      } while ContinuousClock.now < end
      return false
    }
  }
  private struct Fixture: Sendable {
    let database: WorkspaceDatabase
    let raw: PostgresConnection
    let endpoint: PostgresEndpoint
    let root: String
    let secrets: MemorySecretStore
    let endpointReference: SecretRef
    let endpointValue: String
    let material: String
    let log: OwnedLog
  }
  private static func withFixture(_ body: @Sendable (Fixture) async throws -> Void) async throws {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-grant-private-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root);
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    var ownedDatabase: WorkspaceDatabase?
    defer { try? ownedDatabase?.close() }  // Idempotent fallback; explicit close below owns the proof.
    var primary: (any Error)?
    do {
      let supported = try raw.execute(
        "SELECT current_setting('server_version_num')::int AS version,current_setting('is_superuser') AS privileged"
      ).rows.first
      try #require(supported?.int("version") == 170011 && supported?.text("privileged") == "on")
      let log = try OwnedLog(endpoint.logPath)
      let database = try WorkspaceDatabase(
        endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backups")
      ownedDatabase = database
      let secrets = MemorySecretStore(), endpointReference = SecretRef.make()
      let endpointValue = "A3_ENDPOINT_PRIVATE_\(UUID())"
      try await secrets.put(endpointReference, value: endpointValue)
      for suffix in ["a", "b"] {
        _ = try database.insertConnection(
          Connection(
            id: "connection-" + suffix, kind: .agentProtocol, label: "Fixture " + suffix,
            target: "https://example.invalid/" + suffix, authReference: endpointReference.rawValue,
            nativeScope: #"["agent-protocol-v1","agentProtocol","https://example.invalid/\#(suffix)"]"#,
            peerProfile: .agentProtocol, agentId: "fixture-agent", authMode: .bearer, createdAt: stamp,
            updatedAt: stamp))
        try raw.execute(
          #"INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","createdAt","updatedAt") VALUES ($1,$2,$3,'fixture-scope',$4,$4)"#,
          ["thread-" + suffix, "connection-" + suffix, native, stamp])
      }
      try raw.execute(
        #"INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","createdAt","updatedAt") VALUES ('thread-a-other','connection-a','44444444-4444-4444-8444-444444444444','fixture-scope',$1,$1)"#,
        [stamp])
      try raw.execute(
        #"INSERT INTO "protocolSubscriptions" ("threadId","connectionId","nativeThreadId","generation","channels","namespaces","appliedEventId","appliedSeq","coverage","updatedAt") VALUES ('thread-a','connection-a',$1,$2,'[]','[[]]','before',1,'{}',$3)"#,
        [native, generation, stamp])
      let material = "A3_GRANT_PRIVATE_\(UUID()) opaque 🌱 e\u{301}\r\nline \"quoted\" \\ tail\t "
      let fixture = Fixture(
        database: database, raw: raw, endpoint: endpoint, root: root, secrets: secrets,
        endpointReference: endpointReference, endpointValue: endpointValue, material: material, log: log)
      let before = try publicFacts(raw)
      let bodyResult: Result<Void, any Error>
      do {
        try await body(fixture)
        bodyResult = .success(())
      } catch { bodyResult = .failure(Self.fixtureError(error)) }
      if case .failure(let error) = bodyResult { primary = error }
      // Run all public/material checks even when the saved body failed; never replace its error.
      do { try await noPublicExposure(fixture, before: before) } catch {
        let safe = Self.fixtureError(error)
        if primary == nil {
          primary = safe
        } else {
          Issue.record("The private fixture public-exposure check also failed.")
        }
      }
    } catch { if primary == nil { primary = Self.fixtureError(error) } }

    var closeSucceeded = true
    do { try ownedDatabase?.close() } catch {
      closeSucceeded = false
      Issue.record("The private fixture pool close failed.")
      if primary == nil { primary = FixtureFailure.backendObservation }
    }
    let noAppBackends = await Self.observedNoAppBackends(
      raw, database: endpoint.database, hadThrownFailure: primary != nil, closeSucceeded: closeSucceeded)
    #expect(noAppBackends)
    if !noAppBackends, primary == nil { primary = FixtureFailure.backendObservation }
    if let primary { throw primary }
  }

  private static func fixtureError(_ error: any Error) -> any Error {
    let text = String(describing: error)
    if text.contains("A3_GRANT_PRIVATE_") || text.contains("A3_ENDPOINT_PRIVATE_") {
      Issue.record("A private sentinel reached an unhandled error; refused to print its value.")
      return FixtureFailure.unhandledPrivateFailure
    }
    return error
  }

  private struct NativeCloseObservation: Sendable {
    var readFailed = false, nonzeroObserved = false, lateCompletion = false, cancelled = false
    var zero = false, firstEmpty = false
    var sampleCount: UInt32 = 0
    var firstSampleMilliseconds: Int64?
    var lastSampleMilliseconds: Int64?
    let workerStartedMilliseconds: Int64
  }

  private static func nativeCloseMilliseconds(
    since began: ContinuousClock.Instant, at completed: ContinuousClock.Instant
  ) -> Int64 {
    let elapsed = began.duration(to: completed).components
    return elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
  }

  private static func observedNoAppBackends(
    _ raw: PostgresConnection, database: String, hadThrownFailure: Bool, closeSucceeded: Bool
  ) async -> Bool {
    // Dispatch and worker startup consume the ORIGINAL observation window; no readiness reset.
    let began = ContinuousClock.now
    let deadline = began + .seconds(1)
    let retained = Mutex<Thread?>(nil)
    let cancellation = Mutex(Task.isCancelled)
    let observation: NativeCloseObservation = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        retained.withLock { thread in
          thread = Thread {
            var facts = NativeCloseObservation(
              workerStartedMilliseconds: Self.nativeCloseMilliseconds(since: began, at: .now))
            while ContinuousClock.now < deadline {
              if cancellation.withLock({ $0 }) { facts.cancelled = true; break }
              do {
                // EXACT original predicate: every b4app backend for this database, not a selected PID.
                let empty = try raw.execute(
                  "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'", [database]
                ).rows.isEmpty
                let completed = ContinuousClock.now
                // Saturation bounds telemetry only; it never controls polling or acceptance.
                if facts.sampleCount < UInt32.max { facts.sampleCount += 1 }
                let milliseconds = Self.nativeCloseMilliseconds(since: began, at: completed)
                if facts.firstSampleMilliseconds == nil {
                  facts.firstSampleMilliseconds = milliseconds
                  facts.firstEmpty = empty
                }
                facts.lastSampleMilliseconds = milliseconds
                facts.nonzeroObserved = facts.nonzeroObserved || !empty
                if completed > deadline { facts.lateCompletion = true; break }
                if cancellation.withLock({ $0 }) { facts.cancelled = true; break }
                if empty { facts.zero = true; break }
              } catch { facts.readFailed = true; break }
              guard ContinuousClock.now < deadline else { break }
              Thread.sleep(forTimeInterval: 0.010)
            }
            facts.cancelled = facts.cancelled || cancellation.withLock({ $0 })
            // All inspector accesses have ended. This joins the native operation, not kernel Thread exit.
            continuation.resume(returning: facts)
          }
          thread?.start()
        }
      }
    } onCancel: {
      // Carry parent cancellation into the worker; never abandon or force-interrupt a native query.
      cancellation.withLock { $0 = true }
    }
    retained.withLock { $0 = nil }
    let cancelled = observation.cancelled || cancellation.withLock({ $0 }) || Task.isCancelled
    let elapsedMilliseconds = Self.nativeCloseMilliseconds(since: began, at: .now)
    // Fixed booleans/count/times only; emit on the original Test Task after native-operation completion.
    print(
      "A3_GRANT_NATIVE_CLOSE_WITNESS hadThrownFailure=\(hadThrownFailure) closeSucceeded=\(closeSucceeded) "
        + "readFailed=\(observation.readFailed) nonzeroObserved=\(observation.nonzeroObserved) lateCompletion=\(observation.lateCompletion) "
        + "cancelled=\(cancelled) zero=\(observation.zero) firstEmpty=\(observation.firstEmpty) "
        + "sampleCompleted=\(observation.firstSampleMilliseconds != nil) firstSampleMilliseconds=\(observation.firstSampleMilliseconds ?? 0) "
        + "lastSampleMilliseconds=\(observation.lastSampleMilliseconds ?? 0) sampleCount=\(observation.sampleCount) "
        + "workerStartedMilliseconds=\(observation.workerStartedMilliseconds) elapsedMilliseconds=\(elapsedMilliseconds)"
    )
    return closeSucceeded && observation.zero && !observation.readFailed && !observation.lateCompletion
      && !cancelled
  }
  private static func rows(_ c: PostgresConnection, _ table: String) throws -> [String] {
    try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
      .rows.compactMap { $0.text("row") }
  }
  private static func state(_ c: PostgresConnection) throws -> State {
    // Never turn credential-value rows into Codable/row JSON or assertion diagnostics.
    State(
      credentials: try c.execute(#"SELECT count(*) AS n FROM "protocolGrantSecrets""#).rows.first?.int("n")
        ?? 0,
      metadata: try rows(c, "protocolGrants"), cursors: try rows(c, "protocolSubscriptions"))
  }
  private static func publicFacts(_ c: PostgresConnection) throws -> [String: [String]] {
    var result: [String: [String]] = [:]
    for row in try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows {
      let table = try #require(row.text("tablename"))
      if !privateTables.contains(table) { result[table] = try rows(c, table) }
    }
    return result
  }
  private static func metadata(_ c: PostgresConnection, reference: SecretRef, sequence: Int = 2) throws {
    try c.execute(
      #"INSERT INTO "protocolGrants" ("threadId","pausedGeneration","namespace","interruptId","proposalHash","connectionId","grantReference","disposition","updatedAt") VALUES ('thread-a',$1,'[]',$2,'fixture-proposal','connection-a',$3,'fixture-disposition',$4) ON CONFLICT ("threadId","pausedGeneration","namespace","interruptId","proposalHash") DO UPDATE SET "grantReference"=EXCLUDED."grantReference","updatedAt"=EXCLUDED."updatedAt""#,
      [generation, interrupt, reference.rawValue, stamp])
    try c.execute(
      #"UPDATE "protocolSubscriptions" SET "appliedEventId"=$1,"appliedSeq"=$2,"coverage"='{"opaque":true}',"updatedAt"=$3 WHERE "threadId"='thread-a'"#,
      ["after-\(sequence)", String(sequence), stamp])
  }
  private static func stored(_ f: Fixture, reference: SecretRef, equals value: String?) throws -> Bool {
    try Store.transaction(database: f.database, owner: owner) { _, store in
      switch (try store.read(reference), value) {
      case (nil, nil): return true
      case (.some(let actual), .some(let expected)): return actual.utf8.elementsEqual(expected.utf8)
      default: return false
      }
    }
  }
  private static func credentialInsert(_ c: PostgresConnection, reference: SecretRef, material: String) throws
  {
    // TEST-ONLY failed-row diagnostic control; normal material writes go only through the component.
    try c.execute(
      #"INSERT INTO "protocolGrantSecrets" ("reference","connectionId","threadId","material","createdAt") VALUES ($1,'connection-a','thread-a',$2,$3)"#,
      [reference.rawValue, material, stamp])
  }
  private static func noPublicExposure(_ f: Fixture, before: [String: [String]]) async throws {
    let unchanged = try publicFacts(f.raw) == before
    #expect(unchanged)
    let endpointUnchanged = try await f.secrets.read(f.endpointReference) == f.endpointValue
    #expect(endpointUnchanged)
    let text = try String(
      decoding: JSONCoding.encoder.encode(f.database.listConnections(includeDisabled: true)), as: UTF8.self)
    let leaked = text.contains("A3_GRANT_PRIVATE_") || text.contains("A3_ENDPOINT_PRIVATE_")
    #expect(!leaked)
  }
  private static func failure(_ body: () throws -> Void) -> (any Error)? {
    do { try body(); return nil } catch { return error }
  }
  private static func safePublicBoundary(_ error: any Error, fixture: Fixture) async throws {
    let publicError = WorkspaceError.from(error)
    #expect(publicError.code == .internalError)
    let constantMessage = publicError.message == message
    let noDetails = publicError.details == nil
    let noCause = (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
    #expect(constantMessage); #expect(noDetails); #expect(noCause)
    let response = ResponseEnvelope.failure("fixture-private-error", error: publicError)
    let bytes = try JSONCoding.encoder.encode(response)
    let line = try NDJSON.encodeLine(response)
    let wireRoundTrip = try JSONCoding.decoder.decode(ResponseEnvelope.self, from: bytes).error == publicError
    #expect(wireRoundTrip)
    let paths = PlatformPaths(runtimeDir: fixture.root + "/rt", dataDir: fixture.root + "/data")
    let env = [
      "PATH": fixture.root + "/empty-bin", "HOME": fixture.root,
      ExecutableLocator.fallbackOverrideVariable: "",
    ]
    for name in ["node", "codex", "claude"] { #expect(ExecutableLocator.find(name, environment: env) == nil) }
    let events = EventLog()
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: paths, startedAt: stamp, environment: env, secretStore: fixture.secrets, eventLog: events))
    await diagnostics.recordError(
      scope: "private-credential", code: publicError.code.rawValue, message: publicError.message)
    let report = try await diagnostics.read()
    let constantDiagnostic = report.recentErrors.last?.message == message
    #expect(constantDiagnostic)
    #expect(report.runtimes.allSatisfy { $0.executablePath == nil })
    #expect(await events.sequence == 0)
    let surfaces = [
      String(decoding: bytes, as: UTF8.self), String(decoding: line, as: UTF8.self),
      String(reflecting: error), String(describing: (error as NSError).userInfo),
      String(decoding: try JSONCoding.encoder.encode(report), as: UTF8.self),
    ]
    let leaked = surfaces.contains { $0.contains("A3_GRANT_PRIVATE_") || $0.contains("A3_ENDPOINT_PRIVATE_") }
    #expect(!leaked)
    await events.finish()
  }
  private static let privacy = [
    "log_error_verbosity", "log_parameter_max_length", "log_parameter_max_length_on_error",
  ]
  private static let modes: [[String: String]] = [
    [
      "log_statement": "all", "log_min_duration_statement": "-1", "log_min_duration_sample": "-1",
      "log_transaction_sample_rate": "0",
    ],
    [
      "log_statement": "none", "log_min_duration_statement": "0", "log_min_duration_sample": "-1",
      "log_transaction_sample_rate": "0",
    ],
    [
      "log_statement": "none", "log_min_duration_statement": "-1", "log_min_duration_sample": "0",
      "log_statement_sample_rate": "1", "log_transaction_sample_rate": "1",
    ],
  ]
  private static let settingNames =
    privacy + [
      "log_statement", "log_min_duration_statement", "log_min_duration_sample",
      "log_statement_sample_rate", "log_transaction_sample_rate", "debug_print_parse",
      "debug_print_rewritten", "debug_print_plan",
    ]
  private static func settings(_ c: PostgresConnection) throws -> [String: String] {
    var result: [String: String] = [:]
    for name in settingNames {
      result[name] = try #require(
        try c.execute("SELECT current_setting($1) AS value", [name]).rows.first?.text("value"))
    }
    return result
  }
  private static func configure(_ c: PostgresConnection, _ values: [String: String]) throws {
    for (name, value) in values.sorted(by: { $0.key < $1.key }) {
      try c.execute("SELECT set_config($1,$2,false)", [name, value])
    }
  }
  private static func pid(_ c: PostgresConnection) throws -> Int {
    try #require(try c.execute("SELECT pg_backend_pid() AS pid").rows.first?.int("pid"))
  }
  private static func rawDetailControl(_ f: Fixture, deferred: Bool) throws {
    let value = "A3_RAW_DETAIL_CONTROL_\(UUID())"
    try f.raw.execute("BEGIN")
    var sqlState: String?, containsValue = false
    do {
      try credentialInsert(f.raw, reference: .make(), material: value)
      if deferred { try f.raw.execute("SET CONSTRAINTS a3_commit_refusal IMMEDIATE") }
    } catch let error as PostgresError {
      sqlState = error.sqlState; containsValue = error.message.contains(value)
    } catch { try? f.raw.execute("ROLLBACK"); throw FixtureFailure.unexpectedPositiveControl }
    // The diagnostic row never commits. The component case separately reaches actual COMMIT.
    try f.raw.execute("ROLLBACK")
    guard sqlState == "23514", containsValue else { throw FixtureFailure.unexpectedPositiveControl }
  }

  @Test func grantMaterialMetadataAndCursorCommitInOneTransaction() async throws {
    try await Self.withFixture { f in
      let before = try Self.state(f.raw), publicBefore = try Self.publicFacts(f.raw)
      let reference = try #require(SecretRef(rawValue: "secret:fixture-opaque"))
      var reached = false
      var expected: State?
      try Store.transaction(database: f.database, owner: Self.owner) { c, store in
        let backend = try Self.pid(c)
        try store.put(f.material, reference: reference)
        let internalMatch = try store.read(reference).map { $0.utf8.elementsEqual(f.material.utf8) } == true
        #expect(internalMatch)
        try Self.metadata(c, reference: reference)
        expected = try Self.state(c)
        #expect(try Self.pid(c) == backend)
        #expect(try Self.state(f.raw) == before)  // Separate inspector cannot see any partial commit.
        reached = true
      }
      #expect(reached)
      let materialMatches = try Self.stored(f, reference: reference, equals: f.material)
      #expect(materialMatches)
      let after = try Self.state(f.raw)
      let expectedState = try #require(expected)
      #expect(after == expectedState)
      #expect(after.credentials == 1 && after.metadata.count == 1)
      #expect(after.metadata.contains { $0.contains(reference.rawValue) })
      #expect(after.cursors.contains { $0.contains("after-2") })
      try await Self.noPublicExposure(f, before: publicBefore)
    }
  }

  @Test func failedGrantBatchRollsBackNewReplacementAndNulMaterial() async throws {
    for replacing in [false, true] {
      try await Self.withFixture { f in
        let original = SecretRef.make()
        if replacing {
          try Store.transaction(database: f.database, owner: Self.owner) { c, store in
            try store.put(f.material, reference: original); try Self.metadata(c, reference: original)
          }
        }
        let before = try Self.state(f.raw), publicBefore = try Self.publicFacts(f.raw),
          replacement = SecretRef.make()
        var afterAllWrites = false
        let error = Self.failure {
          try Store.transaction(database: f.database, owner: Self.owner) { c, store in
            try store.put(f.material + " replacement", reference: replacement)
            try Self.metadata(c, reference: replacement, sequence: 3)
            afterAllWrites = true
            throw FixtureFailure.deliberateRollback
          }
        }
        #expect(afterAllWrites)
        let caught = try #require(error)
        try await Self.safePublicBoundary(caught, fixture: f)
        #expect(try Self.state(f.raw) == before)
        let replacementAbsent = try Self.stored(f, reference: replacement, equals: nil)
        #expect(replacementAbsent)
        if replacing {
          let originalMatches = try Self.stored(f, reference: original, equals: f.material)
          #expect(originalMatches)
        }
        var reachedNul = false
        let nulError = Self.failure {
          try Store.transaction(database: f.database, owner: Self.owner) { c, store in
            try c.execute(#"UPDATE "protocolSubscriptions" SET "appliedSeq"=99 WHERE "threadId"='thread-a'"#)
            reachedNul = true
            try store.put(f.material + "\0truncated", reference: .make())
          }
        }
        #expect(reachedNul)
        try await Self.safePublicBoundary(try #require(nulError), fixture: f)
        #expect(try Self.state(f.raw) == before)
        try await Self.noPublicExposure(f, before: publicBefore)
      }
    }
  }

  @Test func ownerAndRepresentabilityGuardsCannotResolveValidPrefixes() async throws {
    try await Self.withFixture { f in
      let reference = SecretRef.make(), publicBefore = try Self.publicFacts(f.raw)
      try Store.transaction(database: f.database, owner: Self.owner) { _, store in
        try store.put(f.material, reference: reference)
      }
      let materialMatches = try Self.stored(f, reference: reference, equals: f.material)
      #expect(materialMatches)
      let missingAbsent = try Self.stored(f, reference: .make(), equals: nil)
      #expect(missingAbsent)
      for other in [
        Store.Owner(connectionId: "connection-b", threadId: "thread-b"),
        Store.Owner(connectionId: "connection-a", threadId: "thread-a-other"),
      ] {
        let hidden = try Store.transaction(database: f.database, owner: other) { _, store in
          try store.read(reference) == nil
        }
        #expect(hidden)
      }
      let before = try Self.state(f.raw)
      let collision = Self.failure {
        try Store.transaction(
          database: f.database, owner: .init(connectionId: "connection-b", threadId: "thread-b")
        ) { _, store in
          try store.put(f.material + " moved", reference: reference)
        }
      }
      try await Self.safePublicBoundary(try #require(collision), fixture: f)
      for invalid in [
        Store.Owner(connectionId: "connection-a\0suffix", threadId: "thread-a"),
        Store.Owner(connectionId: "connection-a", threadId: "thread-a\0suffix"),
        Store.Owner(connectionId: "", threadId: "thread-a"),
        Store.Owner(connectionId: "connection-a", threadId: ""),
      ] {
        var invoked = false
        let error = Self.failure {
          try Store.transaction(database: f.database, owner: invalid) { _, store in
            invoked = true; _ = try store.read(reference)
          }
        }
        #expect(!invoked)
        try await Self.safePublicBoundary(try #require(error), fixture: f)
      }
      let nulReference = try #require(SecretRef(rawValue: reference.rawValue + "\0suffix"))
      for write in [false, true] {
        let error = Self.failure {
          try Store.transaction(database: f.database, owner: Self.owner) { _, store in
            if write {
              try store.put(f.material + " overwritten", reference: nulReference)
            } else {
              _ = try store.read(nulReference)
            }
          }
        }
        try await Self.safePublicBoundary(try #require(error), fixture: f)
      }
      let empty = Self.failure {
        try Store.transaction(database: f.database, owner: Self.owner) { _, store in
          try store.put("", reference: .make())
        }
      }
      try await Self.safePublicBoundary(try #require(empty), fixture: f)
      #expect(try Self.state(f.raw) == before)
      let originalStillMatches = try Self.stored(f, reference: reference, equals: f.material)
      #expect(originalStillMatches)
      try await Self.noPublicExposure(f, before: publicBefore)
    }
  }

  @Test func sqlDetailAndCommitFailuresNormalizeAtExistingPublicBoundaries() async throws {
    for deferred in [false, true] {
      try await Self.withFixture { f in
        if deferred {
          try f.raw.execute(
            #"CREATE FUNCTION a3_commit_refusal() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'Fixture commit refusal' USING ERRCODE='23514',DETAIL=NEW."material"; END; $$"#
          )
          try f.raw.execute(
            #"CREATE CONSTRAINT TRIGGER a3_commit_refusal AFTER INSERT ON "protocolGrantSecrets" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION a3_commit_refusal()"#
          )
        } else {
          try f.raw.execute(
            #"ALTER TABLE "protocolGrantSecrets" ADD CONSTRAINT a3_test_refusal CHECK ("material" NOT LIKE 'A3_%')"#
          )
        }
        try Self.rawDetailControl(f, deferred: deferred)
        let before = try Self.state(f.raw), publicBefore = try Self.publicFacts(f.raw)
        var bodyCompleted = false, callbackEntered = false
        let beforePID = try f.database.read { try Self.pid($0) }, logStart = try f.log.offset()
        let error = Self.failure {
          try Store.transaction(database: f.database, owner: Self.owner) { c, store in
            callbackEntered = true
            try store.put(f.material, reference: .make())
            bodyCompleted = true
            if deferred { #expect(try Self.state(f.raw) == before) }
          }
        }
        #expect(callbackEntered)
        #expect(bodyCompleted == deferred)
        #expect(try f.database.read { try Self.pid($0) } == beforePID)
        let endMarker = "A3_SAFE_ERROR_END_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try f.database.read { try $0.execute("DO $$ BEGIN RAISE LOG '\(endMarker)'; END; $$") }
        guard try await f.log.observed(endMarker, after: logStart) else {
          throw FixtureFailure.missingLogControl
        }
        let errorTail = try f.log.tail(logStart)
        let expectedFault = deferred ? "Fixture commit refusal" : "a3_test_refusal"
        let expectedFaultLogged = errorTail.contains(expectedFault)
        #expect(expectedFaultLogged)
        let serverLeak = errorTail.contains("A3_GRANT_PRIVATE_")
        #expect(!serverLeak)
        try await Self.safePublicBoundary(try #require(error), fixture: f)
        #expect(try Self.state(f.raw) == before)
        try await Self.noPublicExposure(f, before: publicBefore)
      }
    }
  }

  @Test func serverLogsHideMaterialAndRestoreSamePooledConnectionSettings() async throws {
    try await Self.withFixture { f in
      let initial = try f.database.read { try Self.settings($0) }
      defer { try? f.database.read { try Self.configure($0, initial) } }
      for (index, mode) in Self.modes.enumerated() {
        var verbose = mode
        verbose["log_error_verbosity"] = "verbose"
        verbose["log_parameter_max_length"] = "-1"
        verbose["log_parameter_max_length_on_error"] = "-1"
        let beforePID = try f.database.read { c -> Int in
          try Self.configure(c, verbose); return try Self.pid(c)
        }
        let beforeSettings = try f.database.read { try Self.settings($0) }
        let rawMarker = "A3_RAW_BIND_CONTROL_\(UUID())", rawStart = try f.log.offset()
        try f.database.read { try $0.execute("SELECT $1::text AS value", [rawMarker]) }
        guard try await f.log.observed(rawMarker, after: rawStart) else {
          throw FixtureFailure.missingLogControl
        }
        for failing in [false, true] {
          let start = try f.log.offset(), reference = SecretRef.make()
          var invoked = false
          let error = Self.failure {
            try Store.transaction(database: f.database, owner: Self.owner) { c, store in
              invoked = true
              #expect(try Self.pid(c) == beforePID)
              let protected = try Self.settings(c)
              #expect(protected["log_error_verbosity"] == "terse")
              #expect(protected["log_parameter_max_length"] == "0")
              #expect(protected["log_parameter_max_length_on_error"] == "0")
              for (name, value) in mode { #expect(protected[name] == value) }
              try store.put(f.material, reference: reference)
              if failing {
                try c.execute(
                  #"UPDATE "protocolGrantSecrets" SET "createdAt"='' WHERE "reference"=$1"#,
                  [reference.rawValue])
              }
            }
          }
          #expect(invoked)
          if failing {
            try await Self.safePublicBoundary(try #require(error), fixture: f)
          } else {
            let succeeded = error == nil; #expect(succeeded)
          }
          #expect(try f.database.read { try Self.pid($0) } == beforePID)
          #expect(try f.database.read { try Self.settings($0) } == beforeSettings)
          let endMarker =
            "A3_SAFE_LOG_END_\(index)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
          try f.database.read { try $0.execute("SELECT 1 /* \(endMarker) */") }
          guard try await f.log.observed(endMarker, after: start) else {
            throw FixtureFailure.missingLogControl
          }
          let tail = try f.log.tail(start)
          let leaked = tail.contains("A3_GRANT_PRIVATE_") || tail.contains("A3_ENDPOINT_PRIVATE_")
          #expect(!leaked)
          let safeQueryLogged = tail.contains("SELECT 1")
          #expect(safeQueryLogged)  // Safe query/timing diagnostics still exist.
          let storedMatches = try Self.stored(f, reference: reference, equals: failing ? nil : f.material)
          #expect(storedMatches)
        }
        let restoredMarker = "A3_RAW_RESTORE_CONTROL_\(UUID())", restoredStart = try f.log.offset()
        try f.database.read { try $0.execute("SELECT $1::text", [restoredMarker]) }
        guard try await f.log.observed(restoredMarker, after: restoredStart) else {
          throw FixtureFailure.missingLogControl
        }
      }
    }
  }

  @Test func privacyFailureAndExpiredBorrowRefuseBeforeMaterialAccess() async throws {
    try await Self.withFixture { f in
      let role =
        "a3_grant_\(ProcessInfo.processInfo.processIdentifier)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
      try f.raw.execute("CREATE ROLE \(Rows.quote(role)) NOINHERIT LOGIN NOSUPERUSER")
      defer {
        try? f.database.read { try $0.execute("RESET ROLE") }
        try? f.raw.execute("REVOKE ALL ON \"protocolGrantSecrets\" FROM \(Rows.quote(role))")
        try? f.raw.execute("DROP ROLE \(Rows.quote(role))")
        #expect((try? f.raw.execute("SELECT 1 FROM pg_roles WHERE rolname=$1", [role]).rows.isEmpty) == true)
      }
      try f.raw.execute("GRANT SELECT,INSERT,UPDATE ON \"protocolGrantSecrets\" TO \(Rows.quote(role))")
      let original = try f.database.read { try Self.settings($0) }
      let backend = try f.database.read { c -> Int in
        try c.execute("SET ROLE \(Rows.quote(role))"); return try Self.pid(c)
      }
      let denied = try f.database.read { c -> Bool in
        var code: String?
        do { try c.execute("SET log_error_verbosity=terse") } catch let error as PostgresError {
          code = error.sqlState
        }
        return code == "42501"
      }
      try #require(denied)
      var invoked = false
      let error = Self.failure {
        try Store.transaction(database: f.database, owner: Self.owner) { _, store in
          invoked = true; try store.put(f.material, reference: .make())
        }
      }
      #expect(!invoked)
      try await Self.safePublicBoundary(try #require(error), fixture: f)
      #expect(try f.database.read { try Self.pid($0) } == backend)
      #expect(try f.database.read { try Self.settings($0) } == original)
      try f.database.read { try $0.execute("RESET ROLE") }
      #expect(try Self.state(f.raw).credentials == 0)
      try f.database.read { try Self.configure($0, ["debug_print_plan": "on"]) }
      defer { try? f.database.read { try Self.configure($0, original) } }
      var debugInvoked = false
      let debugError = Self.failure {
        try Store.transaction(database: f.database, owner: Self.owner) { _, store in
          debugInvoked = true; try store.put(f.material, reference: .make())
        }
      }
      #expect(!debugInvoked)
      try await Self.safePublicBoundary(try #require(debugError), fixture: f)
      #expect(try f.database.read { try Self.settings($0)["debug_print_plan"] } == "on")
      try f.database.read { try Self.configure($0, original) }
      var escaped: Store?
      let reference = SecretRef.make()
      try Store.transaction(database: f.database, owner: Self.owner) { _, store in
        try store.put(f.material, reference: reference); escaped = store
      }
      let store = try #require(escaped), before = try Self.state(f.raw)
      let readError = Self.failure { _ = try store.read(reference) }
      let writeError = Self.failure { try store.put(f.material + " escaped", reference: .make()) }
      try await Self.safePublicBoundary(try #require(readError), fixture: f)
      try await Self.safePublicBoundary(try #require(writeError), fixture: f)
      #expect(try Self.state(f.raw) == before)
    }
  }
}
