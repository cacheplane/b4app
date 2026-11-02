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

  static func start(extraEnvironment: [String: String] = [:]) async throws -> RelayHarness {
    let base = NSTemporaryDirectory() + "b4r-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["ANTHROPIC_API_KEY"] = nil
    for (key, value) in extraEnvironment { env[key] = value }
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    let executor = RelayExecutor(
      sessions: coordinator.sessions, projects: coordinator.projects, database: coordinator.database)
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

  func project(_ name: String, _ folders: [String]) async throws -> Project {
    try await coordinator.projects.create(ProjectCreate.Params(name: name, folders: folders)).project
  }

  func waitForFinish(_ turn: Turn) async throws {
    try await events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }
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
    let project = try await h.project("App", [app])
    let threadId = UUID().uuidString.lowercased()
    let id = UUID().uuidString.lowercased()
    let reply = try await run(
      h.executor, id: id, .threadStart,
      ThreadStart.Params(
        threadId: threadId, projectId: project.id, connectionId: connection.id, folder: app, text: "hi"))
    let started = try result(reply, as: ThreadStart.Result.self)
    #expect(started.thread.id == threadId)
    #expect(started.thread.connectionId == connection.id)
    #expect(started.thread.projectId == project.id)
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
    let projectId = try #require(connection.projectId)
    let executor = RelayExecutor(
      sessions: h.coordinator.sessions, projects: h.coordinator.projects, database: h.coordinator.database)

    // A folder is not part of a B4 thread.
    let withFolder = try await run(
      executor, .threadStart,
      ThreadStart.Params(
        threadId: UUID().uuidString.lowercased(), projectId: projectId, connectionId: connection.id,
        folder: h.base + "/agent", text: "hi"))
    #expect(failure(withFolder)?.code == ErrorCode.protocolInvalid.rawValue)

    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      executor, .threadStart,
      ThreadStart.Params(threadId: threadId, projectId: projectId, connectionId: connection.id, text: "hello")
    )
    let started = try result(reply, as: ThreadStart.Result.self)
    #expect(started.thread.id == threadId)
    #expect(started.thread.context == connection.routeKey)
    #expect(started.thread.context == "/chat#agent")
    #expect(started.thread.projectId == projectId)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == started.turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
  }

  @Test func threadStartRefusesAFolderOutsideTheProject() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let project = try await h.project("App", [try h.folder("app")])
    let threadId = UUID().uuidString.lowercased()
    for folder in [try h.folder("elsewhere"), nil] {
      let reply = try await run(
        h.executor, .threadStart,
        ThreadStart.Params(
          threadId: threadId, projectId: project.id, connectionId: connection.id, folder: folder, text: "hi"))
      #expect(failure(reply)?.code == ErrorCode.protocolInvalid.rawValue, "\(folder ?? "no folder")")
    }
    // An unknown project is refused the same way.
    let unknown = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, projectId: "p-missing", connectionId: connection.id, folder: try h.folder("app"),
        text: "hi"))
    #expect(failure(unknown)?.code == ErrorCode.protocolInvalid.rawValue)
    #expect(try h.db.thread(id: threadId) == nil)
  }

  @Test func threadStartRefusesAB4ServerOfAnotherProject() async throws {
    let h = try await ServerHarness.start()
    defer { Task { await h.close() } }
    let server = try await h.add(try h.project("agent"))
    let connection = try await h.client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, route: "/chat#agent", serverId: server.id),
      options: h.mutation()
    ).connection
    let own = try #require(connection.projectId)
    let otherFolder = h.base + "/other"
    try FileManager.default.createDirectory(atPath: otherFolder, withIntermediateDirectories: true)
    let other = try await h.coordinator.projects.create(
      ProjectCreate.Params(name: "Other", folders: [otherFolder])
    ).project
    #expect(other.id != own)
    let executor = RelayExecutor(
      sessions: h.coordinator.sessions, projects: h.coordinator.projects, database: h.coordinator.database)
    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      executor, .threadStart,
      ThreadStart.Params(threadId: threadId, projectId: other.id, connectionId: connection.id, text: "hi"))
    #expect(failure(reply)?.code == ErrorCode.protocolInvalid.rawValue)
    #expect(try h.coordinator.database.thread(id: threadId) == nil)
  }

  @Test func threadStartRefusesRemoteB4() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let project = try await h.project("App", [try h.folder("app")])
    let remote = try h.db.insertConnection(
      Connection(
        id: "c-remote", kind: .b4, label: "Remote", target: "https://b4.example.com", routeKey: "/chat#agent",
        b4Mode: .remote, projectId: project.id, status: .ready))
    let threadId = UUID().uuidString.lowercased()
    let reply = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(threadId: threadId, projectId: project.id, connectionId: remote.id, text: "hi"))
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
    let project = try await h.project("App", [app, docs])
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
          threadId: threadId, projectId: project.id, connectionId: connection.id, folder: app, text: "hi")),
      as: ThreadStart.Result.self)
    #expect(first.thread.id == threadId)
    #expect(first.thread.nativeThreadId == made.nativeThreadId)
    try await h.waitForFinish(first.turn)
    // The same thread id with another folder, under a new command id, is not the same thread.
    let reply = try await run(
      h.executor, .threadStart,
      ThreadStart.Params(
        threadId: threadId, projectId: project.id, connectionId: connection.id, folder: docs, text: "again"))
    let error = try #require(failure(reply))
    #expect(error.code == ErrorCode.protocolInvalid.rawValue)
    #expect(error.details?["reason"]?.stringValue == "thread_mismatch")
    #expect(error.details?["turnId"] == nil)
    #expect(try h.db.turns(threadId: threadId).map(\.id) == [first.turn.id])
    #expect(try h.db.listThreads(ThreadFilter(includeArchived: true)).map(\.id) == [threadId])
  }

  /// R4: the relay-only methods are refused over the local socket, and a local `thread.create` cannot
  /// choose its thread's id.
  @Test func localSocketRefusesRelayOnlyMethods() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let project = try await h.project("App", [app])
    let options = RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30))
    do {
      _ = try await h.client.request(
        ThreadStart.self,
        ThreadStart.Params(
          threadId: "t-local", projectId: project.id, connectionId: connection.id, folder: app, text: "hi"),
        options: options)
      Issue.record("thread.start must be refused locally")
    } catch let error as WorkspaceError {
      #expect(error.code == .unsupportedCapability)
      #expect(error.message == "Only relayed from the hub.")
    }
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
    #expect(try h.db.thread(id: "t-local") == nil)
  }

  @Test func threadStartRetryReusesThreadAndTurn() async throws {
    let h = try await RelayHarness.start()
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let app = try h.folder("app")
    let project = try await h.project("App", [app])
    let id = UUID().uuidString.lowercased()
    let params = ThreadStart.Params(
      threadId: UUID().uuidString.lowercased(), projectId: project.id, connectionId: connection.id,
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

  // MARK: - turn.lookup

  @Test func turnLookupReportsInFlightFoundAndNone() async throws {
    let h = try await RelayHarness.start(extraEnvironment: ["B4APP_CODEX_REQUEST_TIMEOUT": "2"])
    defer { Task { await h.close() } }
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection, in: try h.folder("work"))
    let id = UUID().uuidString.lowercased()
    func lookup(_ operationId: String) async throws -> TurnLookup.Result {
      try result(
        try await run(
          h.executor, .turnLookup, TurnLookup.Params(operationId: operationId, threadId: thread.id)),
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
