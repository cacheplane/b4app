import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

/// The fake runtimes shipped with the adapter tests.
private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path
private let fakeClaude =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("ClaudeAdapterTests/Fixtures/fake-claude.py").path
private let fakeB4 =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("B4AdapterTests/Fixtures/fake-b4.py").path

/// The B4 fixture server as a child process (a copy of the adapter tests' launcher; test targets
/// cannot share code). It outlives a coordinator restart, like a real server would.
private final class FakeB4: Sendable {
  let process: StreamingProcess
  let port: Int
  var baseURL: String { "http://127.0.0.1:\(port)" }

  private init(process: StreamingProcess, port: Int) {
    self.process = process
    self.port = port
  }

  static func start(environment extra: [String: String] = [:]) async throws -> FakeB4 {
    var env = ProcessInfo.processInfo.environment
    for (key, value) in extra { env[key] = value }
    let process = try StreamingProcess.start(
      executable: fakeB4, arguments: ["--port", "0"], environment: env)
    var buffer = ""
    for await chunk in process.stdout {
      buffer += String(decoding: chunk, as: UTF8.self)
      if let range = buffer.range(of: "listening on http://127.0.0.1:"),
        let newline = buffer[range.upperBound...].firstIndex(of: "\n"),
        let port = Int(buffer[range.upperBound..<newline])
      {
        return FakeB4(process: process, port: port)
      }
    }
    throw WorkspaceError(.internalError, "fake-b4 did not start: \(process.recentStderr())")
  }

  func stop() async {
    process.terminate()
    _ = await process.waitForExit()
  }

  /// Returns once the thread's run has finished on the server: a reattach (`GET /runs/stream`) streams
  /// the live run until its `done` frame, which the fixture sends after recording the outcome, and
  /// answers `done` at once when no run is live.
  func waitForRunToEnd(nativeThreadId: String) async throws {
    let url = try #require(URL(string: "\(baseURL)/threads/\(nativeThreadId)/runs/stream"))
    let (bytes, _) = try await URLSession.shared.bytes(from: url)
    for try await line in bytes.lines where line == "event: done" { return }
    throw WorkspaceError(.internalError, "the run stream ended without done")
  }
}

private func temporaryPaths() throws -> PlatformPaths {
  let base = NSTemporaryDirectory() + "b4s-\(UUID().uuidString.prefix(8))"
  try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
  return try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
}

private struct Harness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let workDir: String
  let events: EventCollector

  static func start(
    paths: PlatformPaths? = nil, extraEnvironment: [String: String] = [:],
    adapterFactory: SessionService.AdapterFactory? = nil
  ) async throws -> Harness {
    let paths = try paths ?? temporaryPaths()
    // The fixture is a Python script, so the child needs the real PATH; Node lookups stay isolated.
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["FAKE_CLAUDE_PROJECTS"] = (paths.dataDir as NSString).deletingLastPathComponent + "/claude-projects"
    env["ANTHROPIC_API_KEY"] = nil
    for (key, value) in extraEnvironment { env[key] = value }
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: MemorySecretStore(), adapterFactory: adapterFactory))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    let events = EventCollector(await client.events())
    let workDir = (paths.runtimeDir as NSString).deletingLastPathComponent + "/work"
    return Harness(coordinator: coordinator, client: client, workDir: workDir, events: events)
  }

  func addCodex() async throws -> Connection {
    let result = try await client.request(
      ConnectionAdd.self, ConnectionAdd.Params(kind: .codex, label: "Fake Codex", executablePath: fakeCodex),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    return result.connection
  }

  func addClaude() async throws -> Connection {
    let result = try await client.request(
      ConnectionAdd.self,
      ConnectionAdd.Params(kind: .claude, label: "Fake Claude", executablePath: fakeClaude),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    return result.connection
  }

  func addB4(
    _ server: FakeB4, route: String = "/chat#agent", authReference: String? = nil, label: String? = "Fake B4"
  ) async throws -> ConnectionAdd.Result {
    try await client.request(
      ConnectionAdd.self,
      ConnectionAdd.Params(
        kind: .b4, label: label, url: server.baseURL, route: route, authReference: authReference),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
  }

  func newB4Thread(_ connection: Connection, title: String? = nil) async throws -> ConversationThread {
    try await client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: connection.id, title: title),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30))
    ).thread
  }

  func newThread(_ connection: Connection) async throws -> ConversationThread {
    try await client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: connection.id, workingDirectory: workDir),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30))
    ).thread
  }

  func send(
    _ thread: ConversationThread, _ text: String, operationId: String = UUID().uuidString
  ) async throws -> Turn {
    try await client.request(
      TurnSend.self, TurnSend.Params(threadId: thread.id, text: text),
      options: RequestOptions(operationId: operationId, timeout: .seconds(30))
    ).turn
  }

  func read(_ thread: ConversationThread) async throws -> ThreadRead.Result {
    try await client.request(
      ThreadRead.self, ThreadRead.Params(threadId: thread.id), options: RequestOptions(timeout: .seconds(30)))
  }

  func stop() async {
    await client.close()
    await coordinator.close()
  }
}

/// Counts the answers that reach a runtime, and holds each one long enough for a second answer to the
/// same request to arrive while the first is still with the runtime.
private actor RespondRecorder {
  private(set) var responses: [String] = []
  func record(_ nativeRequestId: String) { responses.append(nativeRequestId) }
}

/// A real adapter (here the fake Codex runtime) with a slow `respond` that records each call.
private struct SlowRespondAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let recorder: RespondRecorder
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
    await recorder.record(ref.nativeRequestId)
    try await Task.sleep(for: .milliseconds(500))
    try await inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await inner.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { inner.events() }
  func dispose() async { await inner.dispose() }
}

actor EventCollector {
  private(set) var events: [EventEnvelope] = []
  /// Suspended `until` calls, resumed by the next event (or a deadline).
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(_ stream: AsyncStream<EventEnvelope>) {
    Task { for await event in stream { await self.append(event) } }
  }

  private func append(_ event: EventEnvelope) {
    events.append(event)
    wake()
  }

  private func wake() {
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }

  /// The events so far once `condition` holds of them, checked now and after each event that arrives,
  /// or nil at the timeout. The timeout is only a guard so a failing test ends.
  func until(
    timeout: Duration = .seconds(60), _ condition: @Sendable ([AdapterEvent]) -> Bool
  ) async -> [AdapterEvent]? {
    let deadline = ContinuousClock.now + timeout
    let alarm = Task { [weak self] in
      guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
      await self?.wake()
    }
    defer { alarm.cancel() }
    while true {
      let seen = events.map(\.event)
      if condition(seen) { return seen }
      if ContinuousClock.now >= deadline { return nil }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  /// The first event matching `predicate`, as soon as it has arrived.
  @discardableResult
  func waitFor(
    timeout: Duration = .seconds(60), _ predicate: @Sendable (AdapterEvent) -> Bool
  ) async throws -> AdapterEvent {
    guard let seen = await until(timeout: timeout, { $0.contains(where: predicate) }),
      let match = seen.first(where: predicate)
    else {
      throw WorkspaceError(.internalError, "timed out; saw \(events.map(\.event.kind.rawValue))")
    }
    return match
  }
}

@Suite(.serialized) struct SessionServiceTests {
  @Test func runsAWholeConversationOverTheSocket() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    #expect(connection.status == .ready)
    #expect(connection.authStatus == .authenticated)
    #expect(connection.capabilities[.streaming] == .supported)
    let thread = try await h.newThread(connection)
    #expect(thread.nativeThreadId == "thr_1")
    #expect(thread.nativeScope == "owner@example.com")
    #expect(thread.title == "work")
    try await h.events.waitFor { $0.kind == .threadUpdated && $0.threadId == thread.id }

    let turn = try await h.send(thread, "hello there")
    #expect(turn.status == .running || turn.status == .terminal)
    #expect(turn.submission == .acknowledged)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.threadId == thread.id)
    let deltas = await h.events.events.map(\.event).filter {
      $0.kind == .messageDelta && $0.threadId == thread.id
    }
    #expect(deltas.map { $0.payload["delta"]?.stringValue ?? "" }.joined() == "Hello from fake Codex.")

    let read = try await h.read(thread)
    #expect(read.turns.count == 1)
    #expect(read.turns[0].status == .terminal)
    #expect(read.turns[0].outcome == .completed)
    #expect(read.turns[0].nativeTurnId == "turn_1")
    #expect(read.items.map(\.role) == [.user, .assistant])
    #expect(read.items[0].payload["text"]?.stringValue == "hello there")
    #expect(read.items[1].payload["text"]?.stringValue == "Hello from fake Codex.")
    #expect(read.items[1].turnId == turn.id)
    #expect(read.requests.isEmpty)
    let listed = try await h.client.request(ThreadList.self, ThreadList.Params())
    #expect(listed.threads.map(\.id) == [thread.id])
    await h.stop()
  }

  @Test func refusesASecondTurnWhileOneIsActiveAndDeduplicatesRetries() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let first = try await h.send(thread, "hang around", operationId: "op-hang")
    do {
      _ = try await h.send(thread, "another")
      Issue.record("second turn must be refused")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
      #expect(error.details?["reason"]?.stringValue == "turn_active")
    }
    let retried = try await h.send(thread, "hang around", operationId: "op-hang")
    #expect(retried.id == first.id)
    let stopped = try await h.client.request(
      TurnInterrupt.self, TurnInterrupt.Params(threadId: thread.id),
      options: RequestOptions(operationId: UUID().uuidString))
    #expect(stopped.turn.status == .stopping || stopped.turn.status == .terminal)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == first.id }
    #expect(finished.payload["outcome"]?.stringValue == "cancelled")
    let read = try await h.read(thread)
    #expect(read.turns.count == 1)
    #expect(read.turns[0].outcome == .cancelled)
    let next = try await h.send(thread, "hello again")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == next.id }
    await h.stop()
  }

  @Test func answersAnApprovalExactlyOnce() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "please approve this")
    let opened = try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let request = try #require(try opened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    #expect(request.kind == .commandApproval)
    #expect(request.turnId == turn.id)
    let midway = try await h.read(thread)
    #expect(midway.requests.map(\.id) == [request.id])
    #expect(midway.turns[0].status == .waitingForUser)
    let answered = try await h.client.request(
      RequestRespond.self, RequestRespond.Params(requestId: request.id, decision: .allowOnce),
      options: RequestOptions(operationId: UUID().uuidString))
    #expect(answered.request.state == .resolved)
    do {
      _ = try await h.client.request(
        RequestRespond.self, RequestRespond.Params(requestId: request.id, decision: .deny),
        options: RequestOptions(operationId: UUID().uuidString))
      Issue.record("second answer must be stale")
    } catch let error as WorkspaceError {
      #expect(error.code == .staleRuntimeRequest)
    }
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let read = try await h.read(thread)
    #expect(read.requests.isEmpty)
    let tool = read.items.first { $0.role == .tool }
    #expect(tool?.payload["status"]?.stringValue == "completed")
    #expect(read.items.last?.payload["text"]?.stringValue == "Command completed.")
    await h.stop()
  }

  /// First answer wins at the runtime, not only in the database: an answer that arrives while another
  /// is still with the runtime is refused before it reaches the adapter.
  @Test func simultaneousAnswersReachTheRuntimeOnce() async throws {
    let recorder = RespondRecorder()
    let h = try await Harness.start(adapterFactory: { connection, environment, version, secrets in
      SlowRespondAdapter(
        inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
        recorder: recorder)
    })
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "please approve this")
    let opened = try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let request = try #require(try opened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    let sessions = h.coordinator.sessions
    func answer(_ decision: RuntimeDecision) async -> Result<RuntimeRequest, WorkspaceError> {
      do {
        return .success(
          try await sessions.requestRespond(RequestRespond.Params(requestId: request.id, decision: decision))
            .request)
      } catch { return .failure(WorkspaceError.from(error)) }
    }
    async let mac = answer(.allowOnce)
    async let phone = answer(.deny)
    let outcomes = await [mac, phone]
    let resolved = outcomes.compactMap { try? $0.get() }
    let refused = outcomes.compactMap { outcome -> WorkspaceError? in
      if case .failure(let error) = outcome { return error }
      return nil
    }
    #expect(resolved.map(\.state) == [.resolved])
    #expect(refused.map(\.code) == [.staleRuntimeRequest])
    #expect(await recorder.responses == [request.nativeRequestId])
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    // Once the first answer is done, a late one is stale as before (and never reaches the runtime).
    if case .failure(let late) = await answer(.deny) {
      #expect(late.code == .staleRuntimeRequest)
    } else {
      Issue.record("a late answer must be stale")
    }
    #expect(await recorder.responses.count == 1)
    await h.stop()
  }

  @Test func runtimeExitLeavesTheTurnUnresolvedAndBlocksDispatch() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "crash now")
    let changed = try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id
        && $0.payload["reason"]?.stringValue == "runtime_exited"
    }
    #expect(changed.payload["status"]?.stringValue == "reconciling")
    let offline = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(offline.connections[0].status == .offline)
    // Reading the thread reconciles, which restarts the runtime; the fixture cannot vouch for the
    // crashed turn, so it stays unresolved while the connection is usable again.
    let read = try await h.read(thread)
    #expect(read.turns[0].status == .reconciling)
    #expect(read.turns[0].submission == .unknown)
    #expect(read.turns[0].outcome == nil)
    do {
      _ = try await h.send(thread, "hello again")
      Issue.record("dispatch must wait for reconciliation")
    } catch let error as WorkspaceError {
      #expect(error.details?["reason"]?.stringValue == "turn_active")
      #expect(error.details?["status"]?.stringValue == "reconciling")
    }
    let connections = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(connections.connections[0].status == .ready)
    await h.stop()
  }

  @Test func failedDispatchKeepsTheUserMessageAndMarksTheTurnFailed() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "fail please")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "failed")
    #expect(finished.payload["errorCode"]?.stringValue == "allowance_exceeded")
    let read = try await h.read(thread)
    #expect(read.turns[0].outcome == .failed)
    #expect(read.items.map(\.role) == [.user])
    await h.stop()
  }

  @Test func pendingRequestsExpireAndTurnsReconcileAcrossCoordinatorRestart() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "please approve this")
    try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let paths = h.coordinator.paths
    await h.stop()
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    guard
      case .running(let restarted) = try await Coordinator.start(
        options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    else { throw WorkspaceError(.internalError, "expected running") }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let read = try await client.request(
      ThreadRead.self, ThreadRead.Params(threadId: thread.id), options: RequestOptions(timeout: .seconds(30)))
    #expect(read.requests.isEmpty)
    #expect(read.turns.first { $0.id == turn.id }?.status == .reconciling)
    await client.close()
    await restarted.close()
  }
}

@Suite(.serialized) struct ClaudeSessionServiceTests {
  @Test func runsAClaudeConversationBesideACodexThread() async throws {
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let claude = try await h.addClaude()
    #expect(claude.kind == .claude)
    #expect(claude.status == .ready)
    #expect(claude.authStatus == .authenticated)
    let codexThread = try await h.newThread(codex)
    let claudeThread = try await h.newThread(claude)
    #expect(claudeThread.nativeScope == "owner@example.com")
    #expect(claudeThread.nativeThreadId != codexThread.nativeThreadId)

    let turn = try await h.send(claudeThread, "hello claude")
    #expect(turn.submission == .acknowledged)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.threadId == claudeThread.id)
    let read = try await h.read(claudeThread)
    #expect(read.items.map(\.role) == [.user, .assistant])
    #expect(read.items[1].payload["text"]?.stringValue == "Hello from fake Claude.")
    #expect(read.turns[0].nativeTurnId != nil)

    let listed = try await h.client.request(ThreadList.self, ThreadList.Params())
    #expect(Set(listed.threads.map(\.connectionId)) == [codex.id, claude.id])
    await h.stop()
  }

  @Test func answersAClaudeToolPermissionThroughTheCoordinator() async throws {
    let h = try await Harness.start()
    let claude = try await h.addClaude()
    let thread = try await h.newThread(claude)
    let turn = try await h.send(thread, "use a tool")
    let opened = try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let request = try #require(try opened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    #expect(request.kind == .toolPermission)
    #expect(request.payload["request"]?["toolName"]?.stringValue == "Bash")
    let answered = try await h.client.request(
      RequestRespond.self, RequestRespond.Params(requestId: request.id, decision: .allowOnce),
      options: RequestOptions(operationId: UUID().uuidString))
    #expect(answered.request.state == .resolved)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let read = try await h.read(thread)
    let tool = try #require(read.items.first { $0.role == .tool })
    #expect(tool.type == "toolUse")
    #expect(tool.payload["status"]?.stringValue == "completed")
    #expect(read.items.last?.payload["text"]?.stringValue == "The directory is empty.")
    await h.stop()
  }

  @Test func claudeCrashIsScopedToItsThread() async throws {
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let claude = try await h.addClaude()
    let codexThread = try await h.newThread(codex)
    // A second directory: the directory lock (spec 10.1.5) would otherwise serialize the two turns.
    let claudeDir = (h.workDir as NSString).deletingLastPathComponent + "/claude-work"
    try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    let claudeThread = try await h.client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: claude.id, workingDirectory: claudeDir),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30))
    ).thread
    let pending = try await h.send(codexThread, "please approve this")
    try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == codexThread.id }
    let crashed = try await h.send(claudeThread, "crash now")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == crashed.id }
    #expect(finished.payload["outcome"]?.stringValue == "failed")
    let connections = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(connections.connections.first { $0.id == codex.id }?.status == .ready)
    #expect(connections.connections.first { $0.id == claude.id }?.status == .ready)
    let codexRead = try await h.read(codexThread)
    #expect(codexRead.requests.count == 1)
    #expect(codexRead.turns.first { $0.id == pending.id }?.status == .waitingForUser)
    let claudeRead = try await h.read(claudeThread)
    #expect(claudeRead.turns[0].status == .terminal)
    #expect(claudeRead.turns[0].outcome == .failed)
    let again = try await h.send(claudeThread, "hello again")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == again.id }
    await h.stop()
  }
}

@Suite(.serialized) struct B4SessionServiceTests {
  @Test func runsAB4ConversationBesideCodex() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let added = try await h.addB4(server)
    let b4 = added.connection
    #expect(b4.kind == .b4)
    #expect(b4.status == .ready)
    #expect(b4.authStatus == .notRequired)
    #expect(b4.b4Mode == .attachedLocal)
    #expect(b4.routeKey == "/chat#agent")
    #expect(b4.target == server.baseURL)
    #expect(b4.capabilities[.permissionDecisions] == .supported)
    #expect(added.inspection.message?.contains("not verified") == true)
    let codexThread = try await h.newThread(codex)
    let thread = try await h.newB4Thread(b4)
    #expect(thread.title == "chat")
    #expect(thread.context == "/chat#agent")
    #expect(thread.nativeScope == server.baseURL)
    #expect(thread.nativeThreadId == "thr_1")
    #expect(
      thread.nativeThreadId != codexThread.nativeThreadId || thread.nativeScope != codexThread.nativeScope)

    let turn = try await h.send(thread, "hello b4")
    #expect(turn.submission == .acknowledged)
    #expect(turn.nativeTurnId == "turn-1")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.threadId == thread.id)
    let deltas = await h.events.events.map(\.event).filter {
      $0.kind == .messageDelta && $0.threadId == thread.id
    }
    #expect(deltas.map { $0.payload["delta"]?.stringValue ?? "" }.joined() == "Hello from fake B4.")
    let read = try await h.read(thread)
    #expect(read.turns.count == 1)
    #expect(read.turns[0].outcome == .completed)
    #expect(read.items.map(\.role) == [.user, .assistant])
    #expect(read.items[1].payload["text"]?.stringValue == "Hello from fake B4.")
    let listed = try await h.client.request(ThreadList.self, ThreadList.Params())
    #expect(Set(listed.threads.map(\.id)) == [thread.id, codexThread.id])
    let again = try await h.addB4(server)
    #expect(again.connection.id == b4.id)
    await h.stop()
    await server.stop()
  }

  @Test func answersAB4PermissionThroughTheCoordinator() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "please approve")
    let opened = try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let request = try #require(try opened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    #expect(request.kind == .commandApproval)
    #expect(request.payload["request"]?["command"]?.stringValue == "rm -rf tmp")
    try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id
        && $0.payload["status"]?.stringValue == "waiting_for_user"
    }
    let midway = try await h.read(thread)
    #expect(midway.turns[0].status == .waitingForUser)
    #expect(midway.requests.map(\.id) == [request.id])
    let answered = try await h.client.request(
      RequestRespond.self, RequestRespond.Params(requestId: request.id, decision: .allowAlways),
      options: RequestOptions(operationId: UUID().uuidString))
    #expect(answered.request.state == .resolved)
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let read = try await h.read(thread)
    #expect(read.requests.isEmpty)
    #expect(read.items.last?.payload["text"]?.stringValue?.contains("Approved (always)") == true)
    do {
      _ = try await h.client.request(
        RequestRespond.self, RequestRespond.Params(requestId: request.id, decision: .deny),
        options: RequestOptions(operationId: UUID().uuidString))
      Issue.record("second answer must be stale")
    } catch let error as WorkspaceError {
      #expect(error.code == .staleRuntimeRequest)
    }
    await h.stop()
    await server.stop()
  }

  @Test func credentialAddProducesAReferenceTheEndpointAccepts() async throws {
    let server = try await FakeB4.start(environment: ["FAKE_B4_TOKEN": "s3cret"])
    let h = try await Harness.start()
    let stored = try await h.client.request(
      CredentialAdd.self, CredentialAdd.Params(label: "fake endpoint", value: "s3cret"),
      options: RequestOptions(operationId: UUID().uuidString))
    #expect(stored.reference.hasPrefix("secret:"))
    #expect(stored.label == "fake endpoint")
    do {
      _ = try await h.addB4(server, authReference: "secret:missing")
      Issue.record("an unknown reference must be refused")
    } catch let error as WorkspaceError {
      #expect(error.code == .notFound)
    }
    let anonymous = try await h.addB4(server, label: "No auth").connection
    #expect(anonymous.status == .ready)
    let anonymousThread = try await h.newB4Thread(anonymous)
    do {
      _ = try await h.send(anonymousThread, "hello")
      Issue.record("the middleware must reject the turn")
    } catch let error as WorkspaceError {
      #expect(error.code == .authRequired)
    }
    try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.payload["authStatus"]?.stringValue == "error"
    }
    let authorized = try await h.addB4(
      server, route: "/chat#agent", authReference: stored.reference, label: "With auth")
    #expect(authorized.connection.id != anonymous.id)
    #expect(authorized.connection.authReference == stored.reference)
    #expect(authorized.connection.authStatus == .unknown)
    let thread = try await h.newB4Thread(authorized.connection)
    let turn = try await h.send(thread, "hello")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let connections = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(connections.connections.allSatisfy { $0.authReference != "s3cret" })
    await h.stop()
    await server.stop()
  }

  @Test func routeAndUrlProblemsAreReportedNotSilentlyDegraded() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let workflow = try await h.addB4(server, route: "/dispatch#workflow", label: "Workflow")
    #expect(workflow.connection.status == .incompatible)
    #expect(workflow.inspection.error?.code == .unsupportedCapability)
    do {
      _ = try await h.newB4Thread(workflow.connection)
      Issue.record("a workflow route must not start a thread")
    } catch let error as WorkspaceError {
      #expect(error.code == .unsupportedCapability)
    }
    for (url, route) in [
      (server.baseURL, "chat"), ("http://agent.example.com", "/chat#agent"), ("", "/chat#agent"),
    ] {
      do {
        _ = try await h.client.request(
          ConnectionAdd.self, ConnectionAdd.Params(kind: .b4, url: url, route: route),
          options: RequestOptions(operationId: UUID().uuidString))
        Issue.record("\(url) \(route) must be rejected")
      } catch let error as WorkspaceError {
        #expect(error.code == .protocolInvalid)
      }
    }
    let codex = try await h.addCodex()
    do {
      _ = try await h.client.request(
        ThreadCreate.self, ThreadCreate.Params(connectionId: codex.id),
        options: RequestOptions(operationId: UUID().uuidString))
      Issue.record("a harness thread still needs a directory")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid)
    }
    await h.stop()
    await server.stop()
  }

  @Test func aParkedB4TurnIsAnswerableAfterACoordinatorRestart() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "please approve")
    try await h.events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let paths = h.coordinator.paths
    await h.stop()

    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    guard
      case .running(let restarted) = try await Coordinator.start(
        options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    else { throw WorkspaceError(.internalError, "expected running") }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    await client.resetCursor(epoch: snapshot.epoch, sequence: snapshot.sequence)
    let events = EventCollector(await client.events())
    let first = try await client.request(
      ThreadRead.self, ThreadRead.Params(threadId: thread.id), options: RequestOptions(timeout: .seconds(30)))
    #expect(first.turns.first { $0.id == turn.id }?.status == .waitingForUser)
    let reopened = try await events.waitFor { $0.kind == .runtimeRequestOpened && $0.threadId == thread.id }
    let request = try #require(try reopened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    #expect(request.adapterGeneration == 2)
    let read = try await client.request(
      ThreadRead.self, ThreadRead.Params(threadId: thread.id), options: RequestOptions(timeout: .seconds(30)))
    #expect(read.requests.map(\.id) == [request.id])
    let answered = try await client.request(
      RequestRespond.self, RequestRespond.Params(requestId: request.id, decision: .allowOnce),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(answered.request.state == .resolved)
    let finished = try await events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    await client.close()
    await restarted.close()
    await server.stop()
  }
}

// MARK: - M5

@Suite(.serialized) struct ThreadOrganizationTests {
  /// Spec A05: rename, pin, archive/unarchive, title search, and draft state survive a restart.
  @Test func organizationAndDraftsSurviveACoordinatorRestart() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let first = try await h.newThread(connection)
    let second = try await h.newThread(connection)
    let mutation = { RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)) }
    _ = try await h.client.request(
      ThreadUpdate.self, ThreadUpdate.Params(threadId: first.id, title: "Release notes", pinned: true),
      options: mutation())
    _ = try await h.client.request(
      ThreadUpdate.self, ThreadUpdate.Params(threadId: second.id, archived: true), options: mutation())
    _ = try await h.client.request(
      DraftSave.self, DraftSave.Params(threadId: first.id, text: "unsent words"), options: mutation())
    try await h.events.waitFor {
      $0.kind == .threadUpdated && $0.threadId == second.id
        && ((try? $0.payload["thread"]?.decode(ConversationThread.self))?.archived ?? false)
    }
    let paths = h.coordinator.paths
    await h.stop()

    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    guard
      case .running(let restarted) = try await Coordinator.start(
        options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    else { throw WorkspaceError(.internalError, "expected running") }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    let visible = try await client.request(ThreadList.self, ThreadList.Params())
    #expect(visible.threads.map(\.id) == [first.id])
    #expect(visible.threads[0].title == "Release notes")
    #expect(visible.threads[0].pinned)
    let all = try await client.request(ThreadList.self, ThreadList.Params(includeArchived: true))
    #expect(Set(all.threads.map(\.id)) == [first.id, second.id])
    let searched = try await client.request(
      ThreadList.self, ThreadList.Params(includeArchived: true, query: "release"))
    #expect(searched.threads.map(\.id) == [first.id])
    let draft = try await client.request(DraftRead.self, DraftRead.Params(threadId: first.id)).draft
    #expect(draft?.text == "unsent words")
    let unarchived = try await client.request(
      ThreadUpdate.self, ThreadUpdate.Params(threadId: second.id, archived: false), options: mutation())
    #expect(!unarchived.thread.archived)
    let again = try await client.request(ThreadList.self, ThreadList.Params())
    #expect(Set(again.threads.map(\.id)) == [first.id, second.id])
    await client.close()
    await restarted.close()
  }

  /// The snapshot carries non-terminal turns so a fresh viewer can show per-thread state (spec 3.1).
  @Test func snapshotListsActiveTurns() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "hang around")
    let snapshot = try await h.client.request(EventsSnapshot.self, EmptyParams())
    #expect(snapshot.activeTurns.map(\.id) == [turn.id])
    #expect(snapshot.activeTurns.first?.threadId == thread.id)
    _ = try await h.client.request(
      TurnInterrupt.self, TurnInterrupt.Params(threadId: thread.id),
      options: RequestOptions(operationId: UUID().uuidString))
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    let after = try await h.client.request(EventsSnapshot.self, EmptyParams())
    #expect(after.activeTurns.isEmpty)
    await h.stop()
  }
}

@Suite(.serialized) struct ContinuityTests {
  private let mutation = { RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)) }

  /// A13 and A11: after a restart with the display cache gone, reconciliation rebuilds history from
  /// the runtime; with a partial cache it merges without duplicating the live rows.
  @Test func reconcileMergesNativeHistoryWithoutDuplicates() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "hello there")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    let cached = try await h.read(thread).items
    #expect(cached.map(\.role) == [.user, .assistant])

    // Partial cache: the fixture's history (one earlier turn) goes before the live rows, nothing twice.
    let merged = try await h.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id), options: mutation())
    #expect(merged.thread.continuity == .available)
    #expect(merged.items.map(\.nativeItemId) == ["u_h1", "a_h1", nil, cached[1].nativeItemId])
    #expect(merged.items.map(\.id)[2...] == cached.map(\.id)[...])
    #expect(merged.items.map(\.sequence) == [0, 1, 2, 3])
    #expect(merged.items.filter { $0.payload["text"]?.stringValue == "hello there" }.count == 1)
    let snapshotEvent = try await h.events.waitFor {
      $0.kind == .reconciliationSnapshot && $0.threadId == thread.id
    }
    #expect(snapshotEvent.payload["inserted"]?.numberValue == 2)

    // Lost cache: a restart with the items wiped rebuilds history on a plain read, and a repeated
    // reconcile changes nothing.
    let paths = h.coordinator.paths
    await h.stop()
    let restarted = try await Harness.start(paths: paths)
    _ = try restarted.coordinator.database.deleteDisplayItems(threadId: thread.id)
    let rebuilt = try await restarted.read(thread)
    #expect(rebuilt.items.map(\.nativeItemId) == ["u_h1", "a_h1"])
    #expect(rebuilt.items.allSatisfy { $0.provenance == .snapshot })
    let again = try await restarted.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id), options: mutation())
    #expect(again.items.map(\.id) == rebuilt.items.map(\.id))
    await restarted.stop()
  }

  /// Spec 3.3: a missing native session keeps the cache, refuses continuation, and never claims a resume.
  @Test func missingNativeSessionIsReportedAndRefusesNewTurns() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try h.coordinator.database.insertThread(
      ConversationThread(
        id: "ghost", connectionId: connection.id, nativeThreadId: "thr_missing",
        nativeScope: "owner@example.com",
        title: "ghost", context: h.workDir))
    _ = try h.coordinator.database.insertTurn(
      Turn(
        id: "ghost-turn", threadId: thread.id, operationId: "ghost-op", nativeTurnId: "turn_0",
        status: .terminal,
        submission: .acknowledged, outcome: .completed))
    _ = try h.coordinator.database.upsertDisplayItem(
      threadId: thread.id, turnId: "ghost-turn", nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": "from before"], provenance: .live)

    let read = try await h.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id), options: mutation())
    #expect(read.thread.continuity == .missing)
    #expect(read.items.map { $0.payload["text"]?.stringValue } == ["from before"])
    try await h.events.waitFor {
      $0.kind == .threadUpdated && $0.threadId == thread.id
        && (try? $0.payload["thread"]?.decode(ConversationThread.self))?.continuity == .missing
    }
    do {
      _ = try await h.send(thread, "are you there")
      Issue.record("a missing native session must refuse new turns")
    } catch let error as WorkspaceError {
      #expect(error.code == .nativeSessionMissing)
      #expect(error.details?["reason"]?.stringValue == "missing")
    }
    #expect(try h.coordinator.database.turns(threadId: thread.id).count == 1)
    let plain = try await h.read(thread)
    #expect(plain.thread.continuity == .missing)
    await h.stop()
  }

  /// Spec 5.1: a connection that now presents another account keeps old threads readable but never
  /// retargets them; the original identity coming back restores continuity.
  @Test func identityChangeBlocksOldThreadsUntilTheIdentityReturns() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    #expect(thread.nativeScope == "owner@example.com")
    let turn = try await h.send(thread, "hello there")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    let listed = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(listed.connections[0].nativeScope == "owner@example.com")
    let paths = h.coordinator.paths
    await h.stop()

    let other = try await Harness.start(
      paths: paths, extraEnvironment: ["FAKE_CODEX_EMAIL": "other@example.com", "FAKE_CODEX_ID_PREFIX": "o"])
    let inspected = try await other.client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: connection.id), options: mutation())
    #expect(inspected.connection.nativeScope == "other@example.com")
    let read = try await other.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id), options: mutation())
    #expect(read.thread.continuity == .identityChanged)
    #expect(read.items.count == 2)
    do {
      _ = try await other.send(thread, "still me?")
      Issue.record("an identity change must refuse new turns on old threads")
    } catch let error as WorkspaceError {
      #expect(error.code == .identityChanged)
      #expect(error.details?["connectionScope"]?.stringValue == "other@example.com")
    }
    // A new thread on the same connection belongs to the new identity.
    let fresh = try await other.newThread(connection)
    #expect(fresh.nativeScope == "other@example.com")
    await other.stop()

    let back = try await Harness.start(paths: paths, extraEnvironment: ["FAKE_CODEX_ID_PREFIX": "b"])
    _ = try await back.client.request(
      ConnectionInspect.self, ConnectionInspect.Params(connectionId: connection.id), options: mutation())
    let restored = try await back.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id), options: mutation())
    #expect(restored.thread.continuity == .available)
    let next = try await back.send(thread, "welcome back")
    try await back.events.waitFor { $0.kind == .turnFinished && $0.turnId == next.id }
    await back.stop()
  }
}

@Suite(.serialized) struct RecoveryTests {
  private let mutation = { RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)) }

  private func expectRefusal(
    _ body: () async throws -> Turn, code: ErrorCode, reason: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async -> WorkspaceError? {
    do {
      _ = try await body()
      Issue.record("expected \(code.rawValue) / \(reason)", sourceLocation: sourceLocation)
      return nil
    } catch let error as WorkspaceError {
      #expect(error.code == code, sourceLocation: sourceLocation)
      #expect(error.details?["reason"]?.stringValue == reason, sourceLocation: sourceLocation)
      return error
    } catch {
      Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
      return nil
    }
  }

  /// A18 and spec 10.1.5: one writable harness turn per canonical directory through this app, across
  /// connections, held through an unknown outcome and released by a deliberate abandon.
  @Test func directoryLockSerializesHarnessTurnsAcrossConnections() async throws {
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let claude = try await h.addClaude()
    let first = try await h.newThread(codex)
    let second = try await h.newThread(codex)
    let viaLink = try await h.client.request(
      ThreadCreate.self,
      ThreadCreate.Params(connectionId: claude.id, workingDirectory: h.workDir + "/../work/"),
      options: mutation()
    ).thread
    let elsewhere = (h.workDir as NSString).deletingLastPathComponent + "/other"
    try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
    let other = try await h.client.request(
      ThreadCreate.self, ThreadCreate.Params(connectionId: codex.id, workingDirectory: elsewhere),
      options: mutation()
    ).thread

    let running = try await h.send(first, "hang around")
    let refused = await expectRefusal(
      { try await h.send(second, "me too") }, code: .protocolInvalid, reason: "directory_locked")
    #expect(refused?.details?["threadId"]?.stringValue == first.id)
    #expect(refused?.details?["turnId"]?.stringValue == running.id)
    _ = await expectRefusal(
      { try await h.send(viaLink, "claude in the same place") }, code: .protocolInvalid,
      reason: "directory_locked")
    let free = try await h.send(other, "different directory")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == free.id }
    #expect(try h.coordinator.database.turns(threadId: second.id).isEmpty)

    // The lock survives the runtime crashing under the first turn (outcome unknown).
    _ = try await h.client.request(
      TurnInterrupt.self, TurnInterrupt.Params(threadId: first.id), options: mutation())
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == running.id }
    let crashed = try await h.send(first, "crash now")
    try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == crashed.id
        && $0.payload["status"]?.stringValue == "reconciling"
    }
    _ = await expectRefusal(
      { try await h.send(second, "still locked?") }, code: .protocolInvalid, reason: "directory_locked")
    do {
      _ = try await h.client.request(
        TurnAbandon.self, TurnInterrupt.Params(threadId: second.id), options: mutation())
      Issue.record("abandon needs a reconciling turn")
    } catch let error as WorkspaceError {
      #expect(error.code == .notFound)
    }
    let abandoned = try await h.client.request(
      TurnAbandon.self, TurnInterrupt.Params(threadId: first.id), options: mutation())
    #expect(abandoned.turn.status == .terminal)
    #expect(abandoned.turn.outcome == .failed)
    let read = try await h.read(first)
    #expect(read.items.last?.role == .system)
    #expect(read.items.last?.type == "turnAbandoned")
    let unlocked = try await h.send(second, "finally")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == unlocked.id }
    await h.stop()
  }

  /// A12: a lost acknowledgement becomes an unknown submission; reconciliation is attempted and
  /// nothing is re-sent until the user abandons the turn. A lost response with a live stream still
  /// completes exactly once.
  @Test func lostAcknowledgementsAreNeverRetried() async throws {
    let h = try await Harness.start(extraEnvironment: ["B4APP_CODEX_REQUEST_TIMEOUT": "1"])
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)

    var swallowed: Turn?
    do {
      _ = try await h.send(thread, "please swallow this")
      Issue.record("a swallowed request must not look acknowledged")
    } catch let error as WorkspaceError {
      #expect(error.code == .submissionUnknown)
      swallowed = try h.coordinator.database.turn(id: error.details?["turnId"]?.stringValue ?? "")
    }
    let unknown = try #require(swallowed)
    #expect(unknown.status == .reconciling)
    #expect(unknown.submission == .unknown)
    let reconciled = try await h.client.request(
      ThreadReconcile.self, ThreadReconcile.Params(threadId: thread.id), options: mutation())
    #expect(reconciled.turns.first { $0.id == unknown.id }?.status == .reconciling)
    _ = await expectRefusal(
      { try await h.send(thread, "again?") }, code: .protocolInvalid, reason: "turn_active")
    do {
      _ = try await h.client.request(
        TurnAbandon.self, TurnInterrupt.Params(threadId: thread.id), options: mutation())
    }
    let late = try await h.send(thread, "late ack please")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == late.id }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    let read = try await h.read(thread)
    #expect(read.turns.map(\.outcome) == [.failed, .completed])
    #expect(read.turns[1].submission == .acknowledged)
    #expect(read.turns[1].nativeTurnId == "turn_1")
    // The reconcile above merged the fixture's canned history (snapshot rows); the live turn produced
    // exactly one reply and its user message is cached once.
    #expect(read.items.filter { $0.role == .assistant && $0.provenance == .live }.count == 1)
    #expect(read.items.filter { $0.payload["text"]?.stringValue == "late ack please" }.count == 1)
    await h.stop()
  }
}

@Suite(.serialized) struct FailureTests {
  /// A15: an expired login during a turn is actionable: the turn fails with `auth_required`, the
  /// connection reports `required`, viewers get `connection.changed`, and nothing is re-sent.
  @Test func expiredLoginFlipsTheConnectionToAuthRequired() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    #expect(connection.authStatus == .authenticated)
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "signout now")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    #expect(finished.payload["errorCode"]?.stringValue == "auth_required")
    let changed = try await h.events.waitFor {
      $0.kind == .connectionChanged && $0.connectionId == connection.id
        && $0.payload["authStatus"]?.stringValue == "required"
    }
    #expect(changed.payload["status"]?.stringValue == "ready")
    let listed = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(listed.connections[0].authStatus == .required)
    #expect(listed.connections[0].status == .ready)
    let doctor = try await h.client.request(
      DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
    #expect(doctor.recentErrors.contains { $0.code == "auth_required" && $0.scope.contains("Fake Codex") })
    #expect(try h.coordinator.database.turns(threadId: thread.id).count == 1)
    // A later successful turn restores the auth state through the normal path.
    let again = try await h.send(thread, "hello again")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == again.id }
    await h.stop()
  }

  /// A15: an allowance failure is recorded with the connection's label and never retried.
  @Test func allowanceFailuresAreRecordedNotRetried() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "fail please")
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    let doctor = try await h.client.request(
      DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
    #expect(
      doctor.recentErrors.contains { $0.code == "allowance_exceeded" && $0.scope.contains("Fake Codex") })
    let listed = try await h.client.request(ConnectionList.self, ConnectionList.Params())
    #expect(listed.connections[0].authStatus == .authenticated)
    #expect(try h.coordinator.database.turns(threadId: thread.id).count == 1)
    await h.stop()
  }
}

@Suite(.serialized) struct LifecycleTests {
  private let mutation = { RequestOptions(operationId: UUID().uuidString, timeout: .seconds(120)) }

  /// Spec 10.3 Quit: local work is named and can be stopped; attached and remote runs are detached,
  /// never cancelled by the app.
  @Test func activeWorkNamesLocalAndRemoteTurnsAndStopLocalWorkDetachesRemote() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let b4 = try await h.addB4(server).connection
    let codexThread = try await h.newThread(codex)
    let b4Thread = try await h.newB4Thread(b4)
    let localTurn = try await h.send(codexThread, "hang around")
    let remoteTurn = try await h.send(b4Thread, "hang around")

    let work = try await h.client.request(WorkspaceActiveWork.self, EmptyParams())
    #expect(Set(work.turns.map(\.turnId)) == [localTurn.id, remoteTurn.id])
    #expect(work.localTurns.map(\.turnId) == [localTurn.id])
    #expect(work.remoteTurns.map(\.turnId) == [remoteTurn.id])
    #expect(work.remoteTurns.first?.b4Mode == .attachedLocal)
    #expect(work.servers.isEmpty)

    let stopped = try await h.client.request(WorkspaceStopLocalWork.self, EmptyParams(), options: mutation())
    #expect(stopped.stopped.map(\.turnId) == [localTurn.id])
    #expect(stopped.stopped.first?.status == .terminal)
    #expect(stopped.detached.map(\.turnId) == [remoteTurn.id])
    #expect(stopped.unconfirmed.isEmpty)
    #expect(try h.coordinator.database.turn(id: localTurn.id)?.outcome == .cancelled)
    // The attached B4 run is still in flight on its server until the test stops it itself.
    #expect(try h.coordinator.database.turn(id: remoteTurn.id)?.status == .running)
    let after = try await h.client.request(WorkspaceActiveWork.self, EmptyParams())
    #expect(after.turns.map(\.turnId) == [remoteTurn.id])
    _ = try await h.client.request(
      TurnInterrupt.self, TurnInterrupt.Params(threadId: b4Thread.id), options: mutation())
    try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == remoteTurn.id }
    await h.stop()
    await server.stop()
  }

  /// Spec 10.3 wake: a turn that finished on its server while the coordinator was down is settled by
  /// `workspace.reconcile`, with no re-send.
  @Test func reconcileSettlesATurnThatFinishedWhileTheCoordinatorWasDown() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "slow please")
    #expect(turn.status == .running)
    let paths = h.coordinator.paths
    await h.stop()
    try await server.waitForRunToEnd(nativeThreadId: thread.nativeThreadId)

    let back = try await Harness.start(paths: paths)
    let before = try back.coordinator.database.turn(id: turn.id)
    #expect(before?.status == .reconciling)
    let result = try await back.client.request(
      WorkspaceReconcile.self, WorkspaceReconcile.Params(reason: "test-wake"), options: mutation())
    #expect(result.reconciled == 1)
    #expect(result.stillUnknown == 0)
    let read = try await back.read(thread)
    #expect(read.turns.map(\.outcome) == [.completed])
    // Exactly one server-side turn: reconciliation never re-sent the prompt (A12).
    let (data, _) = try await URLSession.shared.data(
      from: URL(string: "\(server.baseURL)/threads/\(thread.nativeThreadId)/turns")!)
    let body = try JSONCoding.decoder.decode(JSONValue.self, from: data)
    #expect((body["turns"]?["turns"]?.arrayValue ?? body["turns"]?.arrayValue)?.count == 1)
    await back.stop()
    await server.stop()
  }
}

@Suite(.serialized) struct RedactionTests {
  /// A16 and spec 12: runtime error text with credential shapes is masked before it reaches an event,
  /// a thread read, or `doctor`.
  @Test func runtimeErrorsAreRedactedBeforeTheyLeaveTheCoordinator() async throws {
    let h = try await Harness.start()
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let turn = try await h.send(thread, "leak the secrets")
    let finished = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
    let message = finished.payload["error"]?["message"]?.stringValue ?? ""
    #expect(message.contains("[redacted]"))
    for secret in ["abc.def.ghi", "sk-proj-ABCDEFGHIJKLMNOP", "SECRETCODE", "tok123"] {
      #expect(!message.contains(secret), "event leaked \(secret)")
    }
    let doctor = try await h.client.request(
      DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
    let recorded = try #require(doctor.recentErrors.last { $0.code == "allowance_exceeded" })
    #expect(recorded.message.contains("[redacted]"))
    for secret in ["abc.def.ghi", "sk-proj-ABCDEFGHIJKLMNOP", "SECRETCODE", "tok123"] {
      #expect(!recorded.message.contains(secret), "doctor leaked \(secret)")
    }
    // The whole event log of this session carries none of the values either.
    let everything = await h.events.events.map { String(describing: $0.event.payload) }.joined()
    #expect(!everything.contains("sk-proj-ABCDEFGHIJKLMNOP"))
    #expect(!everything.contains("SECRETCODE"))
    await h.stop()
  }
}
