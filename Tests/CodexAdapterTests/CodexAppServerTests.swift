import Foundation
import Testing
import WorkspaceProtocol

@testable import CodexAdapter

/// Path of the fake app-server script shipped with the tests.
func fakeCodexPath() -> String {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-codex.py")
    .path
}

/// Drains an adapter's event stream so tests can wait for specific events with a timeout.
actor EventCollector {
  private(set) var events: [AdapterEvent] = []

  init(_ stream: AsyncStream<AdapterEvent>) {
    Task { for await event in stream { await self.append(event) } }
  }

  private func append(_ event: AdapterEvent) { events.append(event) }

  @discardableResult
  func waitFor(
    timeout: Duration = .seconds(10), _ predicate: @Sendable (AdapterEvent) -> Bool
  ) async throws -> AdapterEvent {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let match = events.first(where: predicate) { return match }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw WorkspaceError(.internalError, "timed out waiting for event; saw \(events.map(\.kind.rawValue))")
  }

  func kinds() -> [EventKind] { events.map(\.kind) }
}

private func makeAdapter() -> CodexAdapter {
  CodexAdapter(connectionId: "c1", executablePath: fakeCodexPath(), clientVersion: "test")
}

@Suite(.serialized) struct CodexAppServerTests {
  @Test func inspectsThroughTheHandshakeAndAccountRead() async throws {
    let adapter = makeAdapter()
    let inspection = try await adapter.inspectConnection()
    #expect(inspection.status == .ready)
    #expect(inspection.authStatus == .authenticated)
    #expect(inspection.nativeScope == "owner@example.com")
    #expect(inspection.version == "0.166.0")
    #expect(inspection.capabilities[.streaming] == .supported)
    let login = try await adapter.startLogin()
    #expect(login.authUrl.hasPrefix("https://auth.example/login"))
    await adapter.dispose()
  }

  @Test func createsAThreadAndStreamsATurn() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    #expect(ref.nativeSessionId == "thr_1")
    #expect(ref.nativeScope == "owner@example.com")
    let receipt = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "hello"))
    #expect(receipt.acknowledged)
    #expect(receipt.nativeTurnId == "turn_1")
    let finished = try await collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.nativeIds["threadId"] == "thr_1")
    let kinds = await collector.kinds()
    #expect(kinds.contains(.connectionChanged))
    let turnKinds = kinds.filter { $0 != .connectionChanged && $0 != .turnStateChanged }
    #expect(
      turnKinds == [
        .turnAcknowledged, .messageStarted, .messageDelta, .messageDelta, .messageCompleted, .turnFinished,
      ]
    )
    let completed = await collector.events.first { $0.kind == .messageCompleted }
    #expect(completed?.payload["item"]?["text"]?.stringValue == "Hello from fake Codex.")
    await adapter.dispose()
  }

  @Test func answersACommandApprovalWithTheUsersDecision() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "please approve this"))
    let opened = try await collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(opened.payload["kind"]?.stringValue == "command_approval")
    #expect(opened.payload["request"]?["command"]?.stringValue == "ls -la")
    #expect(opened.payload["request"]?["environmentId"] == nil)
    let requestRef = RuntimeRequestRef(
      nativeRequestId: opened.nativeIds["requestId"]!, kind: .commandApproval,
      adapterGeneration: opened.adapterGeneration)
    try await adapter.respond(requestRef, response: .decision(.allowOnce))
    let tool = try await collector.waitFor { $0.kind == .toolCompleted }
    #expect(tool.payload["item"]?["status"]?.stringValue == "completed")
    let finished = try await collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(await collector.events.contains { $0.kind == .runtimeRequestResolved })
    do {
      try await adapter.respond(requestRef, response: .decision(.deny))
      Issue.record("second answer must be stale")
    } catch let error as WorkspaceError {
      #expect(error.code == .staleRuntimeRequest)
    }
    await adapter.dispose()
  }

  @Test func declinesUnsupportedRequestsExplicitly() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "needs permissions"))
    let opened = try await collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(opened.payload["kind"]?.stringValue == "tool_permission")
    #expect(opened.payload["answerable"]?.boolValue == false)
    let resolved = try await collector.waitFor { $0.kind == .runtimeRequestResolved }
    #expect(resolved.payload["autoDeclined"]?.boolValue == true)
    let message = try await collector.waitFor { $0.kind == .messageCompleted }
    #expect(message.payload["item"]?["text"]?.stringValue?.contains("\"permissions\": {}") == true)
    try await collector.waitFor { $0.kind == .turnFinished }
    await adapter.dispose()
  }

  @Test func passesUserQuestionAnswersThrough() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "ask a question"))
    let opened = try await collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(opened.payload["kind"]?.stringValue == "user_question")
    #expect(opened.payload["request"]?["questions"]?.arrayValue?.first?["id"]?.stringValue == "color")
    try await adapter.respond(
      RuntimeRequestRef(
        nativeRequestId: opened.nativeIds["requestId"]!, kind: .userQuestion,
        adapterGeneration: opened.adapterGeneration),
      response: .answers(["color": ["blue"]]))
    let message = try await collector.waitFor { $0.kind == .messageCompleted }
    #expect(message.payload["item"]?["text"]?.stringValue == "You chose blue.")
    await adapter.dispose()
  }

  @Test func resumesBeforeSendingAndReportsMissingThreads() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let known = NativeSessionRef(nativeSessionId: "thr_old", nativeScope: "owner@example.com")
    let receipt = try await adapter.sendTurn(
      known, input: TurnInput(operationId: "op1", text: "hi", workingDirectory: "/tmp/w"))
    #expect(receipt.acknowledged)
    try await collector.waitFor { $0.kind == .turnFinished }
    let missing = NativeSessionRef(nativeSessionId: "thr_missing", nativeScope: "owner@example.com")
    do {
      _ = try await adapter.sendTurn(missing, input: TurnInput(operationId: "op2", text: "hi"))
      Issue.record("expected native_session_missing")
    } catch let error as WorkspaceError {
      #expect(error.code == .nativeSessionMissing)
    }
    let snapshot = try await adapter.loadSession(known)
    #expect(snapshot.title == "Resumed thread")
    #expect(snapshot.items.map(\.nativeItemId) == ["u_h1", "a_h1"])
    #expect(snapshot.activeTurn == nil)
    await adapter.dispose()
  }

  @Test func interruptEndsAHangingTurnAsCancelled() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    let receipt = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "hang around"))
    try await collector.waitFor { $0.kind == .turnAcknowledged }
    let reconcile = try await adapter.reconcile(ref)
    #expect(reconcile.activeTurnOutcome == .unknown)
    let stop = try await adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: receipt.nativeTurnId!))
    #expect(stop.confirmed)
    let finished = try await collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "cancelled")
    await adapter.dispose()
  }

  @Test func processExitMidTurnIsReportedAndTheNextSendRestarts() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "crash now"))
    let changed = try await collector.waitFor {
      $0.kind == .connectionChanged && $0.payload["transport"]?.stringValue == "disconnected"
    }
    #expect(changed.payload["status"]?.stringValue == "offline")
    #expect(changed.adapterGeneration == 1)
    let receipt = try await adapter.sendTurn(
      ref, input: TurnInput(operationId: "op2", text: "hello again", workingDirectory: "/tmp/work"))
    #expect(receipt.acknowledged)
    let finished = try await collector.waitFor { $0.kind == .turnFinished && $0.adapterGeneration == 2 }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    await adapter.dispose()
  }

  @Test func failedTurnsCarryTheMappedErrorCode() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "fail please"))
    let finished = try await collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "failed")
    #expect(finished.payload["errorCode"]?.stringValue == "allowance_exceeded")
    await adapter.dispose()
  }
}
