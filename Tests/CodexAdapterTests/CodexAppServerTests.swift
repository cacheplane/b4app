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

  /// Suspended `waitFor` calls, resumed by the next event (or a deadline).
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private func append(_ event: AdapterEvent) {
    events.append(event)
    wake()
  }

  private func wake() {
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }

  /// The first event matching `predicate`, checked now and again as each event arrives. The timeout
  /// only ends a test that would otherwise hang.
  @discardableResult
  func waitFor(
    timeout: Duration = .seconds(60), _ predicate: @Sendable (AdapterEvent) -> Bool
  ) async throws -> AdapterEvent {
    let deadline = ContinuousClock.now + timeout
    let alarm = Task { [weak self] in
      guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
      await self?.wake()
    }
    defer { alarm.cancel() }
    while true {
      if let match = events.first(where: predicate) { return match }
      guard ContinuousClock.now < deadline else {
        throw WorkspaceError(
          .internalError, "timed out waiting for event; saw \(events.map(\.kind.rawValue))")
      }
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  func kinds() -> [EventKind] { events.map(\.kind) }
}

private func makeAdapter(_ environment: [String: String]? = nil) -> CodexAdapter {
  guard let environment else {
    return CodexAdapter(connectionId: "c1", executablePath: fakeCodexPath(), clientVersion: "test")
  }
  return CodexAdapter(
    connectionId: "c1", executablePath: fakeCodexPath(),
    environment: ProcessInfo.processInfo.environment.merging(environment) { $1 }, clientVersion: "test")
}

/// The requests the fake received for one method, as `FAKE_CODEX_PARAMS` recorded them.
private func recordedParams(_ method: String, in file: URL) throws -> [JSONValue] {
  try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
    let entry = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    return entry["method"]?.stringValue == method ? entry["params"] : nil
  }
}

private func paramsFile() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "fake-codex-params-\(UUID().uuidString).jsonl")
}

@Suite(.serialized) struct CodexAppServerTests {
  /// A dispose is final: the coordinator disposes adapters as an account signs out, and a call still
  /// on its way must not start an app server that nobody stops.
  @Test func aDisposedAdapterStartsNoAppServerAgain() async throws {
    let adapter = makeAdapter()
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    await adapter.dispose()
    let created = await #expect(throws: WorkspaceError.self) {
      _ = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    }
    #expect(created?.code == .endpointUnavailable)
    await #expect(throws: WorkspaceError.self) {
      _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "hello"))
    }
    await #expect(throws: WorkspaceError.self) { _ = try await adapter.reconcile(ref, turn: nil) }
    await #expect(throws: WorkspaceError.self) { _ = try await adapter.startLogin() }
  }

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

  @Test func inspectionListsModels() async throws {
    let adapter = makeAdapter()
    let inspection = try await adapter.inspectConnection()
    #expect(inspection.models == [RuntimeModel(id: "gpt-fake", label: "GPT Fake")])
    await adapter.dispose()
  }

  @Test func aRuntimeWithoutAModelListStillInspectsReady() async throws {
    let adapter = makeAdapter(["FAKE_CODEX_NO_MODEL_LIST": "1"])
    let inspection = try await adapter.inspectConnection()
    #expect(inspection.status == .ready)
    #expect(inspection.authStatus == .authenticated)
    #expect(inspection.models == nil)
    await adapter.dispose()
  }

  @Test func turnCarriesModelAndAutoWithWritableRoots() async throws {
    let file = paramsFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let adapter = makeAdapter(["FAKE_CODEX_PARAMS": file.path])
    let ref = try await adapter.createSession(
      NewSessionInput(workingDirectory: "/tmp/work", model: "gpt-fake"))
    _ = try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: "op1", text: "hello", workingDirectory: "/tmp/work", model: "gpt-fake",
        permission: "auto",
        additionalDirectories: ["/x"]))
    await adapter.dispose()
    let thread = try #require(try recordedParams("thread/start", in: file).first)
    #expect(thread["model"]?.stringValue == "gpt-fake")
    let turn = try #require(try recordedParams("turn/start", in: file).first)
    #expect(turn["model"]?.stringValue == "gpt-fake")
    #expect(turn["approvalPolicy"]?.stringValue == "on-request")
    #expect(turn["sandboxPolicy"] == ["type": "workspaceWrite", "writableRoots": ["/x"]])
  }

  @Test func asConfiguredSendsNoPolicy() async throws {
    let file = paramsFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let adapter = makeAdapter(["FAKE_CODEX_PARAMS": file.path])
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "hello"))
    // A permission id Codex does not define (a phone-synced value) is treated as none.
    _ = try await adapter.sendTurn(
      ref, input: TurnInput(operationId: "op2", text: "hello", permission: "bypassPermissions"))
    await adapter.dispose()
    let thread = try #require(try recordedParams("thread/start", in: file).first)
    #expect(thread["model"] == nil)
    let turns = try recordedParams("turn/start", in: file)
    #expect(turns.count == 2)
    for turn in turns {
      #expect(turn["model"] == nil)
      #expect(turn["approvalPolicy"] == nil)
      #expect(turn["sandboxPolicy"] == nil)
    }
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
    let turnKinds = kinds.filter { ![.connectionChanged, .turnStateChanged, .usageChanged].contains($0) }
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

  @Test func archivedResumeRetainsRecoveryAndDoesNotSubmit() async throws {
    let file = paramsFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let adapter = makeAdapter(["FAKE_CODEX_PARAMS": file.path])
    let ref = NativeSessionRef(nativeSessionId: "thr_archived", nativeScope: "owner@example.com")
    let failure = await #expect(throws: WorkspaceError.self) {
      _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "preserve my draft"))
    }
    #expect(failure?.code == .protocolInvalid)
    #expect(failure?.details?["reason"]?.stringValue == "native_session_archived")
    #expect(failure?.message.contains("codex unarchive thr_archived") == true)
    #expect(failure?.details?["rpcCode"]?.numberValue == -32600)
    #expect(failure?.details?["nativeMessage"]?.stringValue?.contains("is archived") == true)
    #expect(try recordedParams("turn/start", in: file).isEmpty)
    await adapter.dispose()
  }

  @Test(arguments: ["thr_config_missing", "thr_resume_fault"])
  func unrelatedResumeErrorsDoNotClaimTheSessionIsMissing(_ threadId: String) async throws {
    let file = paramsFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let adapter = makeAdapter(["FAKE_CODEX_PARAMS": file.path])
    let ref = NativeSessionRef(nativeSessionId: threadId, nativeScope: "owner@example.com")
    let failure = await #expect(throws: WorkspaceError.self) {
      _ = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "hi"))
    }
    #expect(failure?.code == .internalError)
    #expect(
      failure?.message
        == (threadId == "thr_config_missing"
          ? "configuration file not found" : "failed to read session: permission denied"))
    #expect(try recordedParams("turn/start", in: file).isEmpty)
    await adapter.dispose()
  }

  @Test func interruptEndsAHangingTurnAsCancelled() async throws {
    let adapter = makeAdapter()
    let collector = EventCollector(adapter.events())
    let ref = try await adapter.createSession(NewSessionInput(workingDirectory: "/tmp/work"))
    let receipt = try await adapter.sendTurn(ref, input: TurnInput(operationId: "op1", text: "hang around"))
    try await collector.waitFor { $0.kind == .turnAcknowledged }
    let reconcile = try await adapter.reconcile(ref, turn: ActiveTurnRef(nativeTurnId: receipt.nativeTurnId!))
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
