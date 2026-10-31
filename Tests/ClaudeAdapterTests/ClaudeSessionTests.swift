import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

func fakeClaudePath() -> String {
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
    "Fixtures/fake-claude.py"
  ).path
}

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
}

private struct Rig {
  let adapter: ClaudeAdapter
  let collector: EventCollector
  let workDir: String
  let projects: String

  init() throws {
    let base = NSTemporaryDirectory() + "b4claude-\(UUID().uuidString.prefix(8))"
    workDir = base + "/work"
    projects = base + "/projects"
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
    var env = ProcessInfo.processInfo.environment
    env["FAKE_CLAUDE_PROJECTS"] = projects
    env["ANTHROPIC_API_KEY"] = nil
    adapter = ClaudeAdapter(
      connectionId: "c1", executablePath: fakeClaudePath(), environment: env, clientVersion: "test")
    collector = EventCollector(adapter.events())
  }

  func turn(_ ref: NativeSessionRef, _ text: String) async throws -> SubmissionReceipt {
    try await adapter.sendTurn(
      ref, input: TurnInput(operationId: UUID().uuidString, text: text, workingDirectory: workDir))
  }
}

@Suite(.serialized) struct ClaudeSessionTests {
  @Test func inspectsThroughTheFixture() async throws {
    let rig = try Rig()
    let inspection = try await rig.adapter.inspectConnection()
    #expect(inspection.status == .ready)
    #expect(inspection.authStatus == .authenticated)
    #expect(inspection.nativeScope == "owner@example.com")
    #expect(inspection.version == "2.1.282")
    #expect(inspection.capabilities[.permissionDecisions] == .supported)
    let login = try await rig.adapter.startLogin()
    #expect(login.authUrl.hasPrefix("https://claude.ai/oauth/authorize"))
    try await rig.collector.waitFor {
      $0.kind == .connectionChanged && $0.payload["authStatus"]?.stringValue == "authenticated"
    }
    await rig.adapter.dispose()
  }

  @Test func createsASessionAndStreamsATurn() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    #expect(ref.nativeScope == "owner@example.com")
    #expect(UUID(uuidString: ref.nativeSessionId) != nil)
    let receipt = try await rig.turn(ref, "hello")
    #expect(receipt.acknowledged)
    let finished = try await rig.collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.nativeIds["threadId"] == ref.nativeSessionId)
    #expect(finished.nativeIds["turnId"] == receipt.nativeTurnId)
    let kinds = await rig.collector.events.map(\.kind).filter { $0 != .turnStateChanged }
    #expect(kinds == [.messageStarted, .messageDelta, .messageDelta, .messageCompleted, .turnFinished])
    let completed = await rig.collector.events.first { $0.kind == .messageCompleted }
    #expect(completed?.payload["item"]?["text"]?.stringValue == "Hello from fake Claude.")
    await rig.adapter.dispose()
  }

  @Test func answersAToolPermissionOnceAndPairsTheResult() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.turn(ref, "use a tool")
    let opened = try await rig.collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(opened.payload["kind"]?.stringValue == "tool_permission")
    #expect(opened.payload["request"]?["command"]?.stringValue == "ls -la")
    let requestRef = RuntimeRequestRef(
      nativeRequestId: opened.nativeIds["requestId"]!, kind: .toolPermission,
      adapterGeneration: opened.adapterGeneration)
    try await rig.adapter.respond(requestRef, response: .decision(.allowOnce))
    let tool = try await rig.collector.waitFor { $0.kind == .toolCompleted }
    #expect(tool.payload["item"]?["status"]?.stringValue == "completed")
    #expect(tool.payload["item"]?["output"]?.stringValue == "total 0\n")
    let finished = try await rig.collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    do {
      try await rig.adapter.respond(requestRef, response: .decision(.deny))
      Issue.record("second answer must be stale")
    } catch let error as WorkspaceError {
      #expect(error.code == .staleRuntimeRequest)
    }
    await rig.adapter.dispose()
  }

  @Test func deniedToolShowsAFailedResultAndTheTurnStillCompletes() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.turn(ref, "use a tool")
    let opened = try await rig.collector.waitFor { $0.kind == .runtimeRequestOpened }
    try await rig.adapter.respond(
      RuntimeRequestRef(
        nativeRequestId: opened.nativeIds["requestId"]!, kind: .toolPermission,
        adapterGeneration: opened.adapterGeneration),
      response: .decision(.deny))
    let tool = try await rig.collector.waitFor { $0.kind == .toolCompleted }
    #expect(tool.payload["item"]?["status"]?.stringValue == "failed")
    let message = try await rig.collector.waitFor { $0.kind == .messageCompleted }
    #expect(message.payload["item"]?["text"]?.stringValue == "I could not run the command.")
    await rig.adapter.dispose()
  }

  @Test func passesQuestionAnswersThroughAndDeclinesElicitation() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.turn(ref, "ask a question")
    let opened = try await rig.collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(opened.payload["kind"]?.stringValue == "user_question")
    try await rig.adapter.respond(
      RuntimeRequestRef(
        nativeRequestId: opened.nativeIds["requestId"]!, kind: .userQuestion,
        adapterGeneration: opened.adapterGeneration),
      response: .answers(["q0": ["blue"]]))
    let message = try await rig.collector.waitFor { $0.kind == .messageCompleted }
    #expect(message.payload["item"]?["text"]?.stringValue == "You chose blue.")
    try await rig.collector.waitFor { $0.kind == .turnFinished }
    _ = try await rig.turn(ref, "trigger elicitation")
    let elicitation = try await rig.collector.waitFor {
      $0.kind == .runtimeRequestOpened && $0.payload["kind"]?.stringValue == "elicitation"
    }
    #expect(elicitation.payload["answerable"]?.boolValue == false)
    let resolved = try await rig.collector.waitFor {
      $0.kind == .runtimeRequestResolved && $0.payload["autoDeclined"]?.boolValue == true
    }
    #expect(resolved.nativeIds["requestId"] == elicitation.nativeIds["requestId"])
    let reply = try await rig.collector.waitFor {
      $0.kind == .messageCompleted
        && $0.payload["item"]?["text"]?.stringValue?.contains("Elicitation") == true
    }
    #expect(reply.payload["item"]?["text"]?.stringValue?.contains("\"action\": \"decline\"") == true)
    await rig.adapter.dispose()
  }

  @Test func interruptEndsAHangingTurnAsCancelled() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    let receipt = try await rig.turn(ref, "hang around")
    try await rig.collector.waitFor { $0.kind == .messageDelta }
    let reconcile = try await rig.adapter.reconcile(
      ref, turn: ActiveTurnRef(nativeTurnId: receipt.nativeTurnId!))
    #expect(reconcile.activeTurnOutcome == .unknown)
    let stop = try await rig.adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: receipt.nativeTurnId!))
    #expect(stop.confirmed)
    let finished = try await rig.collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "cancelled")
    await rig.adapter.dispose()
  }

  @Test func crashEndsTheTurnAsFailedAndTheNextSendResumes() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.turn(ref, "crash now")
    let finished = try await rig.collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "failed")
    let changed = try await rig.collector.waitFor {
      $0.kind == .connectionChanged && $0.payload["transport"]?.stringValue == "disconnected"
    }
    #expect(changed.nativeIds["threadId"] == ref.nativeSessionId)
    let after = try await rig.adapter.reconcile(ref, turn: ActiveTurnRef(nativeTurnId: "x"))
    #expect(after.activeTurnOutcome == .known(.failed))
    let receipt = try await rig.turn(ref, "hello again")
    #expect(receipt.acknowledged)
    let again = try await rig.collector.waitFor {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == receipt.nativeTurnId
    }
    #expect(again.payload["outcome"]?.stringValue == "completed")
    #expect(again.adapterGeneration == 2)
    await rig.adapter.dispose()
  }

  @Test func failedResultCarriesTheErrorCode() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.turn(ref, "fail please")
    let finished = try await rig.collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "failed")
    #expect(finished.payload["errorCode"]?.stringValue == "auth_required")
    await rig.adapter.dispose()
  }

  @Test func resumesKnownSessionsAndReportsMissingOnes() async throws {
    let rig = try Rig()
    let known = NativeSessionRef(
      nativeSessionId: "22222222-2222-4222-8222-222222222222", nativeScope: "owner@example.com")
    let receipt = try await rig.turn(known, "hi")
    #expect(receipt.acknowledged)
    try await rig.collector.waitFor { $0.kind == .turnFinished }
    let snapshot = try await rig.adapter.loadSession(known)
    #expect(snapshot.items.map(\.type) == ["userMessage", "agentMessage"])
    #expect(snapshot.items[1].payload["text"]?.stringValue == "Hello from fake Claude.")
    do {
      _ = try await rig.turn(
        NativeSessionRef(nativeSessionId: "missing", nativeScope: "owner@example.com"), "hi")
      Issue.record("expected native_session_missing")
    } catch let error as WorkspaceError {
      #expect(error.code == .nativeSessionMissing)
    }
    await rig.adapter.dispose()
  }
}
