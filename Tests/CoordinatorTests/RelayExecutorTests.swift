import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

/// A coordinator over a scratch store with the fake Codex runtime, its `RelayExecutor`, and scratch
/// folders to work in. Commands go straight to the executor, as `HubLink` will hand them over.
private struct RelayHarness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let events: EventCollector
  let executor: RelayExecutor
  let base: String
  var db: WorkspaceDatabase { coordinator.database }

  static func start(
    extraEnvironment: [String: String] = [:], adapterFactory: SessionService.AdapterFactory? = nil
  ) async throws -> RelayHarness {
    let base = NSTemporaryDirectory() + "b4r-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["ANTHROPIC_API_KEY"] = nil
    for (key, value) in extraEnvironment { env[key] = value }
    let outcome = try await Coordinator.startSignedIn(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: MemorySecretStore(), adapterFactory: adapterFactory))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    let executor = RelayExecutor(
      sessions: coordinator.sessions, environments: coordinator.environments, database: coordinator.database,
      diagnostics: coordinator.diagnostics)
    return RelayHarness(
      coordinator: coordinator, client: client, events: EventCollector(await client.events()),
      executor: executor, base: base)
  }

  /// A scratch folder, as written (not canonical: temp dirs live behind a symlink).
  func folder(_ name: String) throws -> String {
    let path = base + "/" + name
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  func addCodex() async throws -> Connection {
    try await coordinator.sessions.connectionAdd(
      ConnectionAdd.Params(kind: .codex, label: "Fake Codex", executablePath: fakeCodex)
    ).connection
  }

  func newThread(_ connection: Connection, in directory: String) async throws -> ConversationThread {
    try await coordinator.sessions.threadCreate(
      ThreadCreate.Params(connectionId: connection.id, workingDirectory: directory)
    ).thread
  }

  func environment(_ name: String, _ folders: [String]) async throws -> WorkEnvironment {
    try await coordinator.environments.create(EnvironmentCreate.Params(name: name, folders: folders))
      .environment
  }

  func waitForFinish(_ turn: Turn) async throws {
    try await events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }
}

/// What `SeamAdapter` does differently from the runtime it wraps, set by the test as it goes.
private actor Seams {
  /// Native sessions the runtime was asked to create.
  private(set) var created = 0
  /// Held before each `createSession`, so a second create arrives while the first is under way.
  var createDelay: Duration?
  /// Thrown by `sendTurn` in place of the runtime's answer (after the turn is inserted).
  var sendFailure: (any Error & Sendable)?
  func recordCreate() -> Duration? {
    created += 1
    return createDelay
  }
  func set(createDelay: Duration? = nil, sendFailure: (any Error & Sendable)? = nil) {
    self.createDelay = createDelay
    self.sendFailure = sendFailure
  }
}

/// A foreign error whose description carries a path and SQL, as `String(describing:)` of a real one can.
private struct LeakyFailure: Error, CustomStringConvertible {
  var description: String { "open /Users/someone/Library/secret.db failed near SELECT * FROM turns" }
}

/// A real adapter (the fake Codex runtime) with the test's `Seams`: a counted, optionally slow
/// `createSession`, and an optionally failing `sendTurn`.
private struct SeamAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let seams: Seams
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    if let delay = await seams.recordCreate() { try await Task.sleep(for: delay) }
    return try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    if let failure = await seams.sendFailure { throw failure }
    return try await inner.sendTurn(ref, input: input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    try await inner.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    try await inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await inner.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { inner.events() }
  func dispose() async { await inner.dispose() }
}

/// A harness whose adapters all go through `SeamAdapter` with `seams`.
private func seamHarness(_ seams: Seams) async throws -> RelayHarness {
  try await RelayHarness.start(adapterFactory: { connection, environment, version, secrets in
    SeamAdapter(
      inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets), seams: seams
    )
  })
}

/// The native request ids that reached the runtime's `respond`, in order.
private actor AnswerLog {
  private(set) var answered: [String] = []
  func record(_ nativeRequestId: String) { answered.append(nativeRequestId) }
}

/// A real adapter (the fake Codex runtime) that records each answer on its way to the runtime.
private struct CountingAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let log: AnswerLog
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    try await inner.sendTurn(ref, input: input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    try await inner.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    await log.record(ref.nativeRequestId)
    try await inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await inner.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { inner.events() }
  func dispose() async { await inner.dispose() }
}

/// A harness whose adapters record each answer in `log`.
private func countingHarness(_ log: AnswerLog) async throws -> RelayHarness {
  try await RelayHarness.start(adapterFactory: { connection, environment, version, secrets in
    CountingAdapter(
      inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets), log: log)
  })
}

/// One relayed command as `HubLink` passes it: a deadline 8 s after the hub's now, by default.
private func run(
  _ executor: RelayExecutor, id: String = UUID().uuidString.lowercased(), _ method: RelayMethod,
  _ params: some Encodable, hubNow: Date = Date(), deadline: Date? = nil
) async throws -> RelayMessage {
  await executor.execute(
    id: id, method: method, params: try JSONValue(encoding: params),
    deadline: deadline ?? hubNow.addingTimeInterval(8), hubNow: hubNow)
}

/// The reply's result decoded as `T`; fails the test on an error reply.
private func result<T: Decodable>(
  _ reply: RelayMessage, as type: T.Type, sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
  guard case .reply(_, let result, let error) = reply else {
    Issue.record("not a reply: \(reply)", sourceLocation: sourceLocation)
    throw WorkspaceError(.internalError, "not a reply")
  }
  if let error {
    Issue.record("error reply: \(error.code) \(error.message)", sourceLocation: sourceLocation)
    throw error.workspaceError
  }
  return try #require(result, sourceLocation: sourceLocation).decode(type)
}

/// The reply's error; nil (and a recorded issue) for a result.
private func failure(
  _ reply: RelayMessage, sourceLocation: SourceLocation = #_sourceLocation
) -> RelayWireError? {
  guard case .reply(_, let result, let error) = reply, let error else {
    Issue.record("expected an error reply, got \(reply)", sourceLocation: sourceLocation)
    return nil
  }
  #expect(result == nil, sourceLocation: sourceLocation)
  return error
}

@Suite(.serialized) struct RelayExecutorTests {
  // MARK: - turn.send

  @Test func relayedSendRunsATurn() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    let reply = try await run(h.executor, id: id, .turnSend, TurnSend.Params(threadId: thread.id, text: "hi"))
    guard case .reply(let replyId, _, _) = reply else { throw WorkspaceError(.internalError, "no reply") }
    #expect(replyId == id)
    let turn = try result(reply, as: TurnSend.Result.self).turn
    #expect(turn.operationId == id)
    #expect(turn.threadId == thread.id)
    try await h.waitForFinish(turn)
    let read = try await h.coordinator.sessions.threadRead(ThreadRead.Params(threadId: thread.id))
    #expect(read.turns.map(\.outcome) == [.completed])
    #expect(read.items.map(\.role) == [.user, .assistant])
  }

  @Test func resendAfterCompletionReturnsTheSameTurn() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    let params = TurnSend.Params(threadId: thread.id, text: "hello")
    let first = try result(try await run(h.executor, id: id, .turnSend, params), as: TurnSend.Result.self)
      .turn
    try await h.waitForFinish(first)
    // The hub restarted and the phone resent the same id: the Mac answers with the turn it made.
    let again = try result(try await run(h.executor, id: id, .turnSend, params), as: TurnSend.Result.self)
      .turn
    #expect(again.id == first.id)
    #expect(again.status == .terminal)
    #expect(try h.db.turns(threadId: thread.id).count == 1)
  }

  @Test func overlappingResendAwaitsTheFirst() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    let params = TurnSend.Params(threadId: thread.id, text: "hang around")
    async let first = run(h.executor, id: id, .turnSend, params)
    async let second = run(h.executor, id: id, .turnSend, params)
    let (a, b) = try await (first, second)
    #expect(a == b)
    let turn = try result(a, as: TurnSend.Result.self).turn
    #expect(try h.db.turns(threadId: thread.id).map(\.id) == [turn.id])
    _ = try await h.coordinator.sessions.turnInterrupt(TurnInterrupt.Params(threadId: thread.id))
    try await h.waitForFinish(turn)
  }

  @Test func expiredCommandRunsNothing() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    let now = Date()
    let reply = try await run(
      h.executor, id: id, .turnSend, TurnSend.Params(threadId: thread.id, text: "hi"), hubNow: now,
      deadline: now.addingTimeInterval(-1))
    #expect(failure(reply)?.code == ErrorCode.commandExpired.rawValue)
    #expect(try h.db.turn(operationId: id) == nil)
    #expect(try h.db.turns(threadId: thread.id).isEmpty)
  }

  /// Review Focus 1: the deadline is judged on the hub's clock, whatever the Mac's says.
  @Test func deadlineUsesTheHubClockNotTheMacs() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))

    // The Mac's clock is 2 minutes ahead of the hub's: by `Date()` the deadline passed long ago, but the
    // hub says 8 s are left, so it runs.
    let behindHub = Date().addingTimeInterval(-120)
    let ran = try await run(
      h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "hi"), hubNow: behindHub,
      deadline: behindHub.addingTimeInterval(8))
    let turn = try result(ran, as: TurnSend.Result.self).turn
    try await h.waitForFinish(turn)

    // The Mac's clock is 2 minutes behind: by `Date()` the deadline is far off, but the hub's now is 1 s
    // past it, so it is dropped.
    let aheadHub = Date().addingTimeInterval(120)
    let id = UUID().uuidString.lowercased()
    let dropped = try await run(
      h.executor, id: id, .turnSend, TurnSend.Params(threadId: thread.id, text: "again"), hubNow: aheadHub,
      deadline: aheadHub.addingTimeInterval(-1))
    #expect(failure(dropped)?.code == ErrorCode.commandExpired.rawValue)
    #expect(try h.db.turn(operationId: id) == nil)
    #expect(try h.db.turns(threadId: thread.id).map(\.id) == [turn.id])
  }

  @Test func failureAfterInsertCarriesTheTurnId() async throws {
    let h = try await RelayHarness.start(extraEnvironment: ["B4APP_CODEX_REQUEST_TIMEOUT": "1"])
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    // The fixture swallows the submission: the turn and the user's message exist, the outcome is unknown.
    let reply = try await run(
      h.executor, id: id, .turnSend, TurnSend.Params(threadId: thread.id, text: "please swallow this"))
    let error = try #require(failure(reply))
    #expect(error.code == ErrorCode.submissionUnknown.rawValue)
    let turnId = try #require(error.details?["turnId"]?.stringValue)
    let stored = try #require(try h.db.turn(id: turnId))
    #expect(stored.operationId == id)
    #expect(stored.status == .reconciling)
  }

  // MARK: - thread.start

  @Test func threadStartCreatesInTheFolderAndSends() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])
    let threadId = UUID().uuidString.lowercased()
    let id = UUID().uuidString.lowercased()
    let reply = try await run(
      h.executor, id: id, .threadStart,
      ThreadStart.Params(
        threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: app,
        text: "hi"))
    let started = try result(reply, as: ThreadStart.Result.self)
    #expect(started.thread.id == threadId)
    #expect(started.thread.connectionId == connection.id)
    #expect(started.thread.environmentId == environment.id)
    #expect(
      SessionService.canonicalDirectory(started.thread.context ?? "")
        == SessionService.canonicalDirectory(app))
    #expect(started.turn.threadId == threadId)
    #expect(started.turn.operationId == id)
    try await h.waitForFinish(started.turn)
    let read = try await h.coordinator.sessions.threadRead(ThreadRead.Params(threadId: threadId))
    #expect(read.turns.map(\.outcome) == [.completed])
    #expect(read.items.first?.payload["text"]?.stringValue == "hi")
    // The Mac's own viewers hear of the new thread, as for one started here.
    try await h.events.waitFor { $0.kind == .threadUpdated && $0.threadId == threadId }
  }

  @Test func threadStartOnLocalB4IsRouteBound() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.start(try await h.add(try h.project("agent")))
    let connection = try await h.client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, route: "/chat#agent", serverId: server.id),
      options: h.mutation()
    ).connection
    #expect(connection.status == .ready)
    let environmentId = try #require(connection.environmentId)
    let executor = RelayExecutor(
      sessions: h.coordinator.sessions, environments: h.coordinator.environments,
      database: h.coordinator.database,
      diagnostics: h.coordinator.diagnostics)

    // A folder is not part of a B4 thread.
    let withFolder = try await run(
      executor, .threadStart,
      ThreadStart.Params(
        threadId: UUID().uuidString.lowercased(), environmentId: environmentId, connectionId: connection.id,
        folder: h.base + "/agent", text: "hi"))
    #expect(failure(withFolder)?.code == ErrorCode.protocolInvalid.rawValue)

    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, environmentId: environmentId, connectionId: connection.id, text: "hello")
    )
    let started = try result(reply, as: ThreadStart.Result.self)
    #expect(started.thread.id == threadId)
    #expect(started.thread.context == connection.routeKey)
    #expect(started.thread.context == "/chat#agent")
    #expect(started.thread.environmentId == environmentId)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == started.turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
  }

  @Test func threadStartRefusesAFolderOutsideTheEnvironment() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let environment = try await h.environment("App", [try h.folder("app")])
    let threadId = UUID().uuidString.lowercased()
    let elsewhere = try h.folder("elsewhere")
    // Folders compare in canonical form: `..` and symlinks that lead out of the environment are outside it.
    let fm = FileManager.default
    try fm.createSymbolicLink(atPath: h.base + "/app/escape", withDestinationPath: elsewhere)
    try fm.createSymbolicLink(atPath: h.base + "/looks-like-app", withDestinationPath: elsewhere)
    let outside: [String?] = [
      elsewhere, h.base + "/app/../elsewhere", h.base + "/app/escape", h.base + "/looks-like-app",
      h.base + "/app/..", nil,
    ]
    for folder in outside {
      let reply = try await run(
        h.executor, .threadStart,
        ThreadStart.Params(
          threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: folder,
          text: "hi"))
      #expect(failure(reply)?.code == ErrorCode.protocolInvalid.rawValue, "\(folder ?? "no folder")")
    }
    // An unknown environment is refused the same way.
    let unknown = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, environmentId: "p-missing", connectionId: connection.id,
        folder: try h.folder("app"),
        text: "hi"))
    #expect(failure(unknown)?.code == ErrorCode.protocolInvalid.rawValue)
    #expect(try h.db.thread(id: threadId) == nil)
  }

  @Test func threadStartRefusesAB4ServerOfAnotherEnvironment() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.add(try h.project("agent"))
    let connection = try await h.client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, route: "/chat#agent", serverId: server.id),
      options: h.mutation()
    ).connection
    let own = try #require(connection.environmentId)
    let otherFolder = h.base + "/other"
    try FileManager.default.createDirectory(atPath: otherFolder, withIntermediateDirectories: true)
    let other = try await h.coordinator.environments.create(
      EnvironmentCreate.Params(name: "Other", folders: [otherFolder])
    ).environment
    #expect(other.id != own)
    let executor = RelayExecutor(
      sessions: h.coordinator.sessions, environments: h.coordinator.environments,
      database: h.coordinator.database,
      diagnostics: h.coordinator.diagnostics)
    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      executor, .threadStart,
      ThreadStart.Params(threadId: threadId, environmentId: other.id, connectionId: connection.id, text: "hi")
    )
    #expect(failure(reply)?.code == ErrorCode.protocolInvalid.rawValue)
    #expect(try h.coordinator.database.thread(id: threadId) == nil)
  }

  @Test func threadStartRefusesRemoteB4() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let environment = try await h.environment("App", [try h.folder("app")])
    let remote = try h.db.insertConnection(
      Connection(
        id: "c-remote", kind: .b4, label: "Remote", target: "https://b4.example.com", routeKey: "/chat#agent",
        b4Mode: .remote, environmentId: environment.id, status: .ready))
    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, environmentId: environment.id, connectionId: remote.id, text: "hi"))
    let error = try #require(failure(reply))
    #expect(error.code == ErrorCode.protocolInvalid.rawValue)
    #expect(error.details?["reason"]?.stringValue == "remote_b4")
    #expect(try h.db.thread(id: threadId) == nil)
  }

  @Test func threadStartRefusesAReusedIdWithAnotherFolder() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let docs = try h.folder("docs")
    let environment = try await h.environment("App", [app, docs])
    // A start whose thread was made but whose turn never was (the send was refused after the create)
    // left the thread behind; a start naming it with the same connection and folder reuses it.
    let threadId = UUID().uuidString.lowercased()
    let made = try await h.coordinator.sessions.threadCreate(
      ThreadCreate.Params(connectionId: connection.id, workingDirectory: app, threadId: threadId)
    ).thread
    #expect(made.id == threadId)
    let first = try result(
      try await run(
        h.executor, .threadStart,
        ThreadStart.Params(
          threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: app,
          text: "hi")),
      as: ThreadStart.Result.self)
    #expect(first.thread.id == threadId)
    #expect(first.thread.nativeThreadId == made.nativeThreadId)
    try await h.waitForFinish(first.turn)
    // The same thread id with another folder, under a new command id, is not the same thread.
    let reply = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: docs,
        text: "again"))
    let error = try #require(failure(reply))
    #expect(error.code == ErrorCode.protocolInvalid.rawValue)
    #expect(error.details?["reason"]?.stringValue == "thread_mismatch")
    #expect(error.details?["turnId"] == nil)
    #expect(try h.db.turns(threadId: threadId).map(\.id) == [first.turn.id])
    #expect(try h.db.listThreads(ThreadFilter(includeArchived: true)).map(\.id) == [threadId])
  }

  /// A relayed start with a folder must name its environment: without one it is refused before anything is
  /// made.
  @Test func relayedStartStillRequiresAEnvironment() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, connectionId: connection.id, folder: try h.folder("app"), text: "hi"))
    let error = try #require(failure(reply))
    #expect(error.code == ErrorCode.protocolInvalid.rawValue)
    #expect(error.details?["reason"]?.stringValue == "environment_missing")
    #expect(try h.db.thread(id: threadId) == nil)
  }

  /// R4: `turn.lookup` is refused over the local socket (`thread.start` is local too now), and a local
  /// `thread.create` cannot choose its thread's id.
  @Test func localSocketRefusesTurnLookupAndAChosenThreadId() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    do {
      _ = try await h.client.request(TurnLookup.self, TurnLookup.Params(operationId: "op", threadId: "t"))
      Issue.record("turn.lookup must be refused locally")
    } catch let error as WorkspaceError {
      #expect(error.code == .unsupportedCapability)
    }
    let created = try await h.client.request(
      ThreadCreate.self,
      ThreadCreate.Params(connectionId: connection.id, workingDirectory: app, threadId: "t-chosen"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(created.thread.id != "t-chosen")
  }

  @Test func threadStartRetryReusesThreadAndTurn() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])
    let id = UUID().uuidString.lowercased()
    let params = ThreadStart.Params(
      threadId: UUID().uuidString.lowercased(), environmentId: environment.id, connectionId: connection.id,
      folder: app, text: "hi")
    let first = try result(
      try await run(h.executor, id: id, .threadStart, params), as: ThreadStart.Result.self)
    try await h.waitForFinish(first.turn)
    let again = try result(
      try await run(h.executor, id: id, .threadStart, params), as: ThreadStart.Result.self)
    #expect(again.thread.id == first.thread.id)
    #expect(again.turn.id == first.turn.id)
    #expect(try h.db.listThreads(ThreadFilter(includeArchived: true)).map(\.id) == [first.thread.id])
    #expect(try h.db.turns(threadId: first.thread.id).count == 1)
  }

  /// Two starts of one new thread under different command ids: the second waits for the first, so the
  /// thread (and its native session) is created once and no store error reaches the reply.
  @Test func concurrentStartsOfOneNewThreadCreateItOnce() async throws {
    let seams = Seams()
    await seams.set(createDelay: .milliseconds(300))
    let h = try await seamHarness(seams)
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])
    let threadId = UUID().uuidString.lowercased()
    let params = ThreadStart.Params(
      threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: app, text: "hi")
    async let first = run(h.executor, .threadStart, params)
    async let second = run(h.executor, .threadStart, params)
    let replies = try await [first, second]
    let successes = replies.compactMap { reply -> ThreadStart.Result? in
      guard case .reply(_, let result?, nil) = reply else { return nil }
      return try? result.decode(ThreadStart.Result.self)
    }
    let started = try #require(successes.first)
    #expect(started.thread.id == threadId)
    for reply in replies {
      guard case .reply(_, _, let error?) = reply else { continue }
      // The second may find the first turn still running; it is never a store failure.
      #expect(error.code == ErrorCode.protocolInvalid.rawValue)
      #expect(error.message != RelayExecutor.couldNotRun)
    }
    #expect(try h.db.listThreads(ThreadFilter(includeArchived: true)).map(\.id) == [threadId])
    #expect(await seams.created == 1)
    try await h.waitForFinish(started.turn)
  }

  // MARK: - Errors that stay on the Mac

  /// A store failure, a process launch failure, and an internal error reach the hub only as their code
  /// (and `turnId`); the text, which can carry SQL, row values, and paths, goes to the log and
  /// Diagnostics on this Mac.
  @Test func storeLaunchAndInternalFailuresKeepTheirTextOnTheMac() async throws {
    let seams = Seams()
    let h = try await seamHarness(seams)
    defer { Task { await h.close() } }
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])

    // A runtime that exists but cannot be executed: "Could not start <path>: …".
    let broken = h.base + "/bin/codex"
    try FileManager.default.createDirectory(atPath: h.base + "/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: broken, contents: Data("not a program".utf8), attributes: [.posixPermissions: 0o755])
    let unrunnable = try h.db.insertConnection(
      Connection(id: "c-broken", kind: .codex, label: "Broken", target: broken, status: .ready))
    let launch = try #require(
      failure(
        try await run(
          h.executor, .threadStart,
          ThreadStart.Params(
            threadId: UUID().uuidString.lowercased(), environmentId: environment.id,
            connectionId: unrunnable.id,
            folder: app, text: "hi"))))
    #expect(launch.code == ErrorCode.missingExecutable.rawValue)

    // A store failure: a local create of the same thread id commits first, so the relayed start's insert
    // hits the primary key ("PostgreSQL: [23505] … DETAIL: Key (id)=(…)", protocol_invalid).
    let connection = try await h.addCodex()
    await seams.set(createDelay: .milliseconds(300))
    let threadId = UUID().uuidString.lowercased()
    let sessions = h.coordinator.sessions
    let local = Task {
      try await sessions.threadCreate(
        ThreadCreate.Params(connectionId: connection.id, workingDirectory: app, threadId: threadId))
    }
    try await Task.sleep(for: .milliseconds(100))
    let store = try #require(
      failure(
        try await run(
          h.executor, .threadStart,
          ThreadStart.Params(
            threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: app,
            text: "hi")))
    )
    _ = try await local.value
    #expect(store.code == ErrorCode.protocolInvalid.rawValue)

    // An internal error after the turn exists: a foreign error from the runtime. The code and `turnId`
    // survive; its other details go.
    await seams.set(sendFailure: LeakyFailure())
    let id = UUID().uuidString.lowercased()
    let internalError = try #require(
      failure(
        try await run(h.executor, id: id, .turnSend, TurnSend.Params(threadId: threadId, text: "hello"))))
    #expect(internalError.code == ErrorCode.internalError.rawValue)
    let turnId = try #require(internalError.details?["turnId"]?.stringValue)
    #expect(internalError.details == .object(["turnId": .string(turnId)]))
    #expect(try h.db.turn(id: turnId)?.operationId == id)

    for error in [launch, store, internalError] {
      #expect(error.message == RelayExecutor.couldNotRun)
      let encoded = String(decoding: try JSONCoding.encoder.encode(error), as: UTF8.self)
      for leak in [
        "PostgreSQL", "/bin/codex", "/Users/someone", "SELECT", "DETAIL", h.base,
        SessionService.canonicalDirectory(h.base),
      ] {
        #expect(!encoded.contains(leak), "\(error.code) leaks \(leak)")
      }
    }
    // The text is kept on this Mac, in Diagnostics.
    let recorded = try await h.coordinator.diagnostics.read().recentErrors
    #expect(
      recorded.contains {
        $0.scope == "relay:thread.start" && $0.code == "missing_executable"
          && $0.message.hasPrefix("Could not start ")
      })
    #expect(
      recorded.contains {
        $0.scope == "relay:thread.start" && $0.code == "protocol_invalid"
          && $0.message.hasPrefix("PostgreSQL:")
      })
    #expect(
      recorded.contains {
        $0.scope == "relay:turn.send" && $0.code == ErrorCode.internalError.rawValue
          && $0.message.contains("/Users/someone")
      })
  }

  /// A refusal made before this send's turn exists names the turn in the way as `blockingTurnId`, never
  /// `turnId`, which the phone reads as "accepted".
  @Test func refusalsBeforeTheTurnExistsNameTheBlockingTurnApart() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let work = try h.folder("work")
    let thread = try await h.newThread(connection, in: work)
    let active = try result(
      try await run(h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "hang around")),
      as: TurnSend.Result.self
    ).turn

    let busy = try #require(
      failure(try await run(h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "next"))))
    #expect(busy.details?["reason"]?.stringValue == "turn_active")
    #expect(busy.details?["turnId"] == nil)
    #expect(busy.details?["blockingTurnId"]?.stringValue == active.id)

    // The local socket still gets `turnId`, unchanged.
    do {
      _ = try await h.client.request(
        TurnSend.self, TurnSend.Params(threadId: thread.id, text: "local"),
        options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
      Issue.record("a second turn must be refused")
    } catch let error as WorkspaceError {
      #expect(error.details?["turnId"]?.stringValue == active.id)
    }
    _ = try await h.coordinator.sessions.turnInterrupt(TurnInterrupt.Params(threadId: thread.id))
    try await h.waitForFinish(active)
  }

  /// A NUL cannot be stored; a relayed text with one is refused before any `SessionService` call.
  @Test func textWithANulIsRefusedBeforeAnything() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let threadId = UUID().uuidString.lowercased()
    let replies = [
      try await run(h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "a \u{0} b")),
      try await run(
        h.executor, .threadStart,
        ThreadStart.Params(
          threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: app,
          text: "\u{0}")),
    ]
    for reply in replies {
      let error = try #require(failure(reply))
      #expect(error.code == ErrorCode.protocolInvalid.rawValue)
      #expect(error.details?["reason"]?.stringValue == "invalid_text")
    }
    #expect(try h.db.turns(threadId: thread.id).isEmpty)
    #expect(try h.db.thread(id: threadId) == nil)
    // The thread is not left blocked: an ordinary send runs.
    let turn = try result(
      try await run(h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "fine")),
      as: TurnSend.Result.self
    ).turn
    try await h.waitForFinish(turn)
  }

  /// No folder lock: a start beside another thread's running turn in the same folder makes its thread
  /// and its turn.
  @Test func threadStartBesideARunningThreadInTheSameFolderStarts() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let work = try h.folder("work")
    let environment = try await h.environment("Work", [work])
    let other = try await h.newThread(connection, in: work)
    let active = try result(
      try await run(h.executor, .turnSend, TurnSend.Params(threadId: other.id, text: "hang around")),
      as: TurnSend.Result.self
    ).turn
    let threadId = UUID().uuidString.lowercased()
    let start = ThreadStart.Params(
      threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: work,
      text: "beside")
    let started = try result(try await run(h.executor, .threadStart, start), as: ThreadStart.Result.self)
    #expect(started.thread.id == threadId)
    #expect(started.turn.threadId == threadId)
    #expect(try h.db.thread(id: threadId) != nil)
    try await h.waitForFinish(started.turn)
    _ = try await h.coordinator.sessions.turnInterrupt(TurnInterrupt.Params(threadId: other.id))
    try await h.waitForFinish(active)
  }

  /// The phone mints the thread id; anything but a lowercase UUID is refused before anything is made.
  @Test func threadStartRefusesAThreadIdThatIsNotALowercaseUUID() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])
    for threadId in ["thread-1", UUID().uuidString.uppercased(), "", UUID().uuidString.lowercased() + " "] {
      let error = try #require(
        failure(
          try await run(
            h.executor, .threadStart,
            ThreadStart.Params(
              threadId: threadId, environmentId: environment.id, connectionId: connection.id, folder: app,
              text: "hi")
          )))
      #expect(error.code == ErrorCode.protocolInvalid.rawValue)
      #expect(error.details?["reason"]?.stringValue == "invalid_thread_id")
    }
    #expect(try h.db.listThreads(ThreadFilter(includeArchived: true)).isEmpty)
  }

  /// The boundary rule itself: code kept, `turnId` kept, the text replaced only where it may carry
  /// store, process, or foreign-error text.
  // MARK: - Environment edits

  @Test func environmentCreateValidatesFoldersOnThisMacAndRunsOnce() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    // A thread in `app` gives it an automatic environment, which the new environment takes over.
    let thread = try await h.newThread(connection, in: app)
    let automatic = try #require(try h.db.thread(id: thread.id)?.environmentId)
    let environmentId = UUID().uuidString.lowercased()

    // A folder that is not on this Mac refuses the whole create, naming it; nothing changes.
    let missing = h.base + "/not-here"
    let refused = try await run(
      h.executor, .environmentCreate,
      EnvironmentCreate.Params(
        name: "Work", folders: [app, missing], environmentId: environmentId, deviceId: "mac"))
    let error = try #require(failure(refused))
    #expect(error.code == ErrorCode.protocolInvalid.rawValue)
    #expect(error.message == "Folder \(missing) does not exist.")
    #expect(error.details?["folder"] == .string(missing))
    #expect(try h.db.environment(id: environmentId) == nil)
    #expect(try h.db.thread(id: thread.id)?.environmentId == automatic)

    let params = EnvironmentCreate.Params(
      name: "Work", folders: [app], environmentId: environmentId, deviceId: "mac")
    let created = try result(
      try await run(h.executor, .environmentCreate, params), as: EnvironmentCreate.Result.self
    ).environment
    #expect(created.id == environmentId && created.manual && created.name == "Work")
    #expect(created.folders.map(\.path) == [SessionService.canonicalDirectory(app)])
    #expect(try h.db.thread(id: thread.id)?.environmentId == environmentId)
    #expect(try h.db.environment(id: automatic) == nil)

    // The phone trying again after a lost reply (a new command id) gets the same environment.
    let again = try result(
      try await run(h.executor, .environmentCreate, params), as: EnvironmentCreate.Result.self
    ).environment
    #expect(again.id == environmentId)
    #expect(try h.db.listEnvironments().filter(\.manual).count == 1)

    // An id the phone did not mint as a lowercase UUID is refused before anything.
    let badId = try await run(
      h.executor, .environmentCreate,
      EnvironmentCreate.Params(name: "Odd", folders: [try h.folder("odd")], environmentId: "Not-A-UUID"))
    #expect(failure(badId)?.details?["reason"] == "invalid_environment_id")
  }

  @Test func environmentUpdateAndDeleteRunOnTheMac() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let docs = try h.folder("docs")
    let thread = try await h.newThread(connection, in: app)
    let environment = try await h.environment("Work", [app])

    let updated = try result(
      try await run(
        h.executor, .environmentUpdate,
        EnvironmentUpdate.Params(
          environmentId: environment.id, name: "Docs", addFolders: [docs], removeFolders: [app])),
      as: EnvironmentUpdate.Result.self
    ).environment
    #expect(updated.name == "Docs")
    #expect(updated.folders.map(\.path) == [SessionService.canonicalDirectory(docs)])
    // The thread's folder left the environment, so it is back in an automatic one.
    let moved = try #require(try h.db.thread(id: thread.id)?.environmentId)
    #expect(moved != environment.id)
    #expect(try h.db.environment(id: moved)?.manual == false)

    // A folder that is not on this Mac is refused, and the environment is left as it was.
    let refused = try await run(
      h.executor, .environmentUpdate,
      EnvironmentUpdate.Params(environmentId: environment.id, addFolders: [h.base + "/not-here"]))
    #expect(failure(refused)?.code == ErrorCode.protocolInvalid.rawValue)
    #expect(try h.db.environment(id: environment.id)?.folders.count == 1)

    let deleted = try result(
      try await run(h.executor, .environmentDelete, EnvironmentDelete.Params(environmentId: environment.id)),
      as: EnvironmentDelete.Result.self)
    #expect(deleted.environmentId == environment.id)
    #expect(try h.db.environment(id: environment.id) == nil)
    let gone = try await run(
      h.executor, .environmentDelete, EnvironmentDelete.Params(environmentId: environment.id))
    #expect(failure(gone)?.code == ErrorCode.notFound.rawValue)
    // An automatic environment is the Mac's own: it cannot be deleted from anywhere.
    let automatic = try await run(
      h.executor, .environmentDelete, EnvironmentDelete.Params(environmentId: moved))
    #expect(failure(automatic)?.code == ErrorCode.protocolInvalid.rawValue)
  }

  @Test func wireErrorKeepsTheCodeAndTurnIdAndReplacesUnsafeText() {
    let row = "PostgreSQL: [23505] duplicate key value DETAIL: Key (id)=(t-1) already exists."
    let internalWithTurn = RelayExecutor.wireError(
      WorkspaceError(.internalError, row, details: ["turnId": "turn-1", "cause": ["sql": "SELECT 1"]]))
    #expect(internalWithTurn.replaced)
    #expect(internalWithTurn.error.code == ErrorCode.internalError.rawValue)
    #expect(internalWithTurn.error.message == RelayExecutor.couldNotRun)
    #expect(internalWithTurn.error.details == ["turnId": "turn-1"])

    let foreign = RelayExecutor.wireError(WorkspaceError(.internalError, "Error Domain=NSPOSIXErrorDomain"))
    #expect(foreign.error.message == RelayExecutor.couldNotRun)
    #expect(foreign.error.details == nil)

    let constraint = RelayExecutor.wireError(
      WorkspaceError(
        .protocolInvalid, "PostgreSQL: [23502] Failing row contains (/Users/me/app, secret text).",
        details: ["reason": "x", "turnId": "turn-2"]))
    #expect(constraint.error.code == "protocol_invalid")
    #expect(constraint.error.message == RelayExecutor.couldNotRun)
    #expect(constraint.error.details == ["reason": "x", "turnId": "turn-2"])

    let launch = RelayExecutor.wireError(
      WorkspaceError(.missingExecutable, "Could not start /opt/tools/codex: Exec format error"))
    #expect(launch.error.code == "missing_executable")
    #expect(launch.error.message == RelayExecutor.couldNotRun)

    let ordinary = RelayExecutor.wireError(
      WorkspaceError(
        .submissionUnknown, "The runtime did not acknowledge the turn.", details: ["turnId": "t"]))
    #expect(!ordinary.replaced)
    #expect(ordinary.error.message == "The runtime did not acknowledge the turn.")
    #expect(ordinary.error.details == ["turnId": "t"])
  }

  // MARK: - turn.interrupt and request.respond

  @Test func relayedInterruptStopsARunningTurn() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    // The fixture keeps a "hang" turn running until it is interrupted.
    let started = try result(
      try await run(h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "hang around")),
      as: TurnSend.Result.self
    ).turn
    #expect(started.status != .terminal)
    let reply = try await run(h.executor, .turnInterrupt, TurnInterrupt.Params(threadId: thread.id))
    let stopped = try result(reply, as: TurnInterrupt.Result.self).turn
    #expect(stopped.id == started.id)
    #expect([.stopping, .terminal].contains(stopped.status))
    try await h.waitForFinish(started)
    let ended = try #require(try h.db.turn(id: started.id))
    #expect(ended.status == .terminal)
    #expect(ended.outcome == .cancelled)
    // Nothing is active any more: a second interrupt is the local `not_found`, as a reply.
    let again = try #require(
      failure(try await run(h.executor, .turnInterrupt, TurnInterrupt.Params(threadId: thread.id))))
    #expect(again.code == ErrorCode.notFound.rawValue)
  }

  /// Opens a pending approval on a new thread and returns it with the turn that is waiting on it.
  private func openApproval(_ h: RelayHarness) async throws -> (turn: Turn, request: RuntimeRequest) {
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let turn = try result(
      try await run(h.executor, .turnSend, TurnSend.Params(threadId: thread.id, text: "please approve this")),
      as: TurnSend.Result.self
    ).turn
    let opened = try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let request = try #require(try opened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    return (turn, request)
  }

  @Test func relayedAnswerResolvesAPendingRequest() async throws {
    let log = AnswerLog()
    let h = try await countingHarness(log)
    defer { Task { await h.close() } }
    let (turn, request) = try await openApproval(h)
    #expect(try h.db.runtimeRequest(id: request.id)?.state == .pending)
    let reply = try await run(
      h.executor, .requestRespond, RequestRespond.Params(requestId: request.id, decision: .allowOnce))
    let resolved = try result(reply, as: RequestRespond.Result.self).request
    #expect(resolved.id == request.id)
    #expect(resolved.state == .resolved)
    #expect(await log.answered == [request.nativeRequestId])
    #expect(try h.db.runtimeRequest(id: request.id)?.state == .resolved)
    try await h.waitForFinish(turn)
    #expect(try h.db.turn(id: turn.id)?.outcome == .completed)
    #expect(await log.answered.count == 1)
  }

  @Test func relayedAnswerToAnAnsweredRequestIsStale() async throws {
    let log = AnswerLog()
    let h = try await countingHarness(log)
    defer { Task { await h.close() } }
    let (turn, request) = try await openApproval(h)
    // The Mac answers first, locally.
    _ = try await h.coordinator.sessions.requestRespond(
      RequestRespond.Params(requestId: request.id, decision: .allowOnce))
    let late = try #require(
      failure(
        try await run(
          h.executor, .requestRespond, RequestRespond.Params(requestId: request.id, decision: .deny))))
    #expect(late.code == ErrorCode.staleRuntimeRequest.rawValue)
    #expect(await log.answered == [request.nativeRequestId])
    #expect(try h.db.runtimeRequest(id: request.id)?.state == .resolved)
    try await h.waitForFinish(turn)
  }

  // MARK: - turn.lookup

  @Test func turnLookupReportsInFlightFoundAndNone() async throws {
    let h = try await RelayHarness.start(extraEnvironment: ["B4APP_CODEX_REQUEST_TIMEOUT": "2"])
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    func lookup(_ operationId: String, on threadId: String? = nil) async throws -> TurnLookup.Result {
      try result(
        try await run(
          h.executor, .turnLookup,
          TurnLookup.Params(operationId: operationId, threadId: threadId ?? thread.id)),
        as: TurnLookup.Result.self)
    }

    // The fixture swallows the submission, so the send stays in flight until the request times out.
    let executor = h.executor
    let send = Task {
      try await run(executor, id: id, .turnSend, TurnSend.Params(threadId: thread.id, text: "please swallow"))
    }
    var seen: TurnLookup.State?
    for _ in 0..<200 {
      seen = try await lookup(id).state
      if seen == .inFlight { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(seen == .inFlight)
    #expect(try await lookup(id).turn == nil)
    // In flight on this thread only: asked about another thread, the answer is `none`.
    #expect(try await lookup(id, on: "t-other").state == .none)
    // The same id as another method, while the send runs, is refused rather than handed its reply.
    let app = try h.folder("app")
    let environment = try await h.environment("App", [app])
    let reused = try await run(
      h.executor, id: id, .threadStart,
      ThreadStart.Params(
        threadId: UUID().uuidString.lowercased(), environmentId: environment.id, connectionId: connection.id,
        folder: app, text: "hi"))
    let refusal = try #require(failure(reused))
    #expect(refusal.code == ErrorCode.protocolInvalid.rawValue)
    #expect(refusal.details?["reason"]?.stringValue == "operation_reused")

    // Ended with an error, but the turn exists: `found`.
    _ = try await send.value
    let found = try await lookup(id)
    #expect(found.state == .found)
    #expect(found.turn?.operationId == id)
    #expect(found.turn?.threadId == thread.id)

    let none = try await lookup(UUID().uuidString.lowercased())
    #expect(none.state == .none)
    #expect(none.turn == nil)
  }
}
