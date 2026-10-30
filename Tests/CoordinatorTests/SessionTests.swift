import Foundation
import NIOTransport
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

/// The fake app-server shipped with the Codex adapter tests.
private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

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
