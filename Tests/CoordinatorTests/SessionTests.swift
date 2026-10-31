import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

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
}

private func temporaryPaths() throws -> PlatformPaths {
  let base = NSTemporaryDirectory() + "b4s-\(UUID().uuidString.prefix(8))"
  try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
  return PlatformPaths(runtimeDir: base + "/rt", dataDir: base + "/data")
}

private struct Harness {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let workDir: String
  let events: EventCollector

  static func start() async throws -> Harness {
    let paths = try temporaryPaths()
    // The fixture is a Python script, so the child needs the real PATH; Node lookups stay isolated.
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["FAKE_CLAUDE_PROJECTS"] = (paths.dataDir as NSString).deletingLastPathComponent + "/claude-projects"
    env["ANTHROPIC_API_KEY"] = nil
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
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

actor EventCollector {
  private(set) var events: [EventEnvelope] = []
  init(_ stream: AsyncStream<EventEnvelope>) {
    Task { for await event in stream { await self.append(event) } }
  }
  private func append(_ event: EventEnvelope) { events.append(event) }

  @discardableResult
  func waitFor(
    timeout: Duration = .seconds(15), _ predicate: @Sendable (AdapterEvent) -> Bool
  ) async throws -> AdapterEvent {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let match = events.map(\.event).first(where: predicate) { return match }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw WorkspaceError(.internalError, "timed out; saw \(events.map(\.event.kind.rawValue))")
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
    let claudeThread = try await h.newThread(claude)
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
