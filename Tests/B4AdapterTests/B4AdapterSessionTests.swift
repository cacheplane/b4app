import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import B4Adapter

/// A fixture server plus one adapter bound to it.
private struct Rig {
  let server: FakeB4Server
  let adapter: B4Adapter
  let collector: EventCollector

  static func start(
    route: String = "/chat#agent", authorization: String? = nil, port: Int = 0,
    serverEnvironment: [String: String] = [:]
  ) async throws -> Rig {
    let server = try await FakeB4Server.start(port: port, environment: serverEnvironment)
    return attach(server, route: route, authorization: authorization)
  }

  static func attach(
    _ server: FakeB4Server, route: String = "/chat#agent", authorization: String? = nil
  ) -> Rig {
    let adapter = B4Adapter(
      connectionId: "b4-1", baseURL: server.baseURL, routeKey: route,
      authorization: { authorization.map(B4HTTPClient.authorizationHeader(secret:)) },
      authConfigured: authorization != nil, clientVersion: "test")
    return Rig(server: server, adapter: adapter, collector: EventCollector(adapter.events()))
  }

  func turn(_ ref: NativeSessionRef, _ text: String) async throws -> SubmissionReceipt {
    try await adapter.sendTurn(ref, input: TurnInput(operationId: UUID().uuidString, text: text))
  }

  func finished(_ receipt: SubmissionReceipt, timeout: Duration = .seconds(10)) async throws -> AdapterEvent {
    try await collector.waitFor(timeout: timeout) {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == receipt.nativeTurnId
    }
  }

  func stop() async {
    await adapter.dispose()
    await server.stop()
  }
}

@Suite(.serialized) struct B4AdapterSessionTests {
  @Test func inspectsCreatesAndStreamsATurn() async throws {
    let rig = try await Rig.start()
    let inspection = try await rig.adapter.inspectConnection()
    #expect(inspection.status == .ready)
    #expect(inspection.authStatus == .notRequired)
    #expect(inspection.nativeScope == rig.server.baseURL)
    #expect(inspection.capabilities[.streaming] == .supported)
    #expect(inspection.capabilities[.userQuestions] == .unsupported)
    #expect(inspection.message?.contains("not verified") == true)

    let ref = try await rig.adapter.createSession(NewSessionInput(routeKey: "/chat#agent"))
    #expect(ref.nativeSessionId == "thr_1")
    #expect(ref.nativeScope == rig.server.baseURL)
    let receipt = try await rig.turn(ref, "hello")
    #expect(receipt.acknowledged)
    #expect(receipt.nativeTurnId == "turn-1")
    let finished = try await rig.finished(receipt)
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.payload["usage"]?["model"]?.stringValue == "fake-1")
    #expect(await rig.collector.deltas(turnId: "turn-1") == "Hello from fake B4.")
    let kinds = await rig.collector.events.map(\.kind)
    #expect(kinds.first == .messageStarted)
    #expect(kinds.contains(.messageCompleted))
    #expect(!kinds.contains(.toolCompleted), "usage must not become a transcript item")
    let second = try await rig.turn(ref, "hello again")
    #expect(second.nativeTurnId == "turn-2")
    try await rig.finished(second)
    await rig.stop()
  }

  @Test func toolTurnsAndHistory() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    let receipt = try await rig.turn(ref, "use a tool")
    try await rig.finished(receipt)
    let tool = try await rig.collector.waitFor { $0.kind == .toolCompleted }
    #expect(tool.nativeIds["itemId"] == "call_1")
    #expect(tool.payload["item"]?["name"]?.stringValue == "search")
    #expect(tool.payload["item"]?["output"]?.stringValue == "{\"hits\":2}")
    #expect(tool.payload["item"]?["label"]?.stringValue == "Searched b4")
    #expect(tool.payload["item"]?["input"] == ["q": "b4"])
    let toolEvents = await rig.collector.events.filter { $0.nativeIds["itemId"] == "call_1" }.map(\.kind)
    #expect(
      toolEvents == [.toolStarted, .toolStarted, .toolCompleted], "args, call, step, result → one card")
    let finishedTool = try await rig.collector.waitFor {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == "turn-1"
    }
    #expect(finishedTool.payload["usage"]?["usage_metadata"]?["total_tokens"]?.numberValue == 15)
    #expect(await rig.collector.events.contains { $0.payload["type"]?.stringValue == "step" } == false)
    let snapshot = try await rig.adapter.loadSession(ref)
    #expect(snapshot.items.map(\.type) == ["userMessage", "agentMessage", "toolCall", "agentMessage"])
    #expect(snapshot.items[0].payload["text"]?.stringValue == "use a tool")
    #expect(snapshot.items[2].payload["output"]?.stringValue == "{\"hits\":2}")
    #expect(snapshot.items[3].payload["text"]?.stringValue == "Found 2 hits.")
    #expect(snapshot.pendingRequests.isEmpty)
    let empty = try await rig.adapter.createSession(NewSessionInput())
    #expect(try await rig.adapter.loadSession(empty).items.isEmpty)
    await rig.stop()
  }

  @Test func parksOnAPermissionAndResumesOnce() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    let receipt = try await rig.turn(ref, "please approve")
    let opened = try await rig.collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(opened.payload["kind"]?.stringValue == "command_approval")
    #expect(opened.payload["request"]?["command"]?.stringValue == "rm -rf tmp")
    #expect(opened.nativeIds["turnId"] == "turn-1")
    try await rig.collector.waitFor {
      $0.kind == .turnStateChanged && $0.payload["status"]?.stringValue == "waiting_for_user"
    }
    #expect(await rig.collector.events.contains { $0.kind == .turnFinished } == false)
    do {
      _ = try await rig.turn(ref, "another")
      Issue.record("a parked thread must refuse a new turn")
    } catch let error as WorkspaceError {
      #expect(error.details?["reason"]?.stringValue == "turn_active")
    }
    let request = RuntimeRequestRef(
      nativeRequestId: opened.nativeIds["requestId"]!, kind: .commandApproval,
      adapterGeneration: opened.adapterGeneration)
    try await rig.adapter.respond(request, response: .decision(.allowOnce))
    let finished = try await rig.finished(receipt)
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(await rig.collector.deltas(turnId: "turn-1").contains("Approved (once)"))
    do {
      try await rig.adapter.respond(request, response: .decision(.deny))
      Issue.record("a second answer must be stale")
    } catch let error as WorkspaceError {
      #expect(error.code == .staleRuntimeRequest)
    }
    let turns = try await rig.server.get("/threads/\(ref.nativeSessionId)/turns")
    #expect(B4Protocol.turnList(turns)?.count == 1)
    #expect(turns?["status"]?.stringValue == "idle")
    await rig.stop()
  }

  @Test func alwaysDenyAndDeclineAllReachTheServer() async throws {
    let rig = try await Rig.start()
    for (response, expected) in [
      (RuntimeResponse.decision(.allowAlways), "Approved (always)"),
      (RuntimeResponse.decision(.deny), "Denied"),
      (RuntimeResponse.decline(reason: "no"), "Cancelled by the user."),
    ] {
      let ref = try await rig.adapter.createSession(NewSessionInput())
      let receipt = try await rig.turn(ref, "please approve")
      let opened = try await rig.collector.waitFor {
        $0.kind == .runtimeRequestOpened && $0.nativeIds["threadId"] == ref.nativeSessionId
      }
      try await rig.adapter.respond(
        RuntimeRequestRef(
          nativeRequestId: opened.nativeIds["requestId"]!, kind: .commandApproval,
          adapterGeneration: opened.adapterGeneration), response: response)
      let finished = try await rig.collector.waitFor {
        $0.kind == .turnFinished && $0.nativeIds["threadId"] == ref.nativeSessionId
      }
      #expect(finished.payload["outcome"]?.stringValue == "completed")
      _ = receipt
      let text = await rig.collector.events.filter {
        $0.kind == .messageDelta && $0.nativeIds["threadId"] == ref.nativeSessionId
      }.compactMap { $0.payload["delta"]?.stringValue }.joined()
      #expect(text.contains(expected), "\(expected) in \(text)")
    }
    await rig.stop()
  }

  @Test func stopOnAParkedTurnDeclinesThePrompt() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    let receipt = try await rig.turn(ref, "please approve")
    try await rig.collector.waitFor { $0.kind == .runtimeRequestOpened }
    let stop = try await rig.adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(stop.confirmed)
    #expect(stop.outcome == nil)
    let finished = try await rig.finished(receipt)
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(await rig.collector.deltas(turnId: "turn-1").contains("Cancelled by the user."))
    await rig.stop()
  }

  @Test func cancelsAHangingRun() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    let receipt = try await rig.turn(ref, "hang around")
    try await rig.collector.waitFor { $0.kind == .messageDelta }
    let stop = try await rig.adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(stop.confirmed)
    let finished = try await rig.finished(receipt)
    #expect(finished.payload["outcome"]?.stringValue == "cancelled")
    let thread = try await rig.server.get("/threads/\(ref.nativeSessionId)")
    #expect(thread?["status"]?.stringValue == "interrupted")
    #expect(
      try await rig.server.get("/threads/\(ref.nativeSessionId)/pending_interrupts")?["interrupts"]?
        .arrayValue?.isEmpty == true)
    // A second stop after the fact is confirmed with the known outcome, not reported as a failure.
    let again = try await rig.adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(again.confirmed)
    #expect(again.outcome == .cancelled)
    await rig.stop()
  }

  @Test func reportsAFailedRun() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    let receipt = try await rig.turn(ref, "fail please")
    let finished = try await rig.finished(receipt)
    #expect(finished.payload["outcome"]?.stringValue == "failed")
    #expect(finished.payload["error"]?["message"]?.stringValue == "boom")
    let stop = try await rig.adapter.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(stop.outcome == .failed)
    await rig.stop()
  }

  @Test func aDroppedStreamReattachesWithoutResubmitting() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    let receipt = try await rig.turn(ref, "drop it")
    let finished = try await rig.finished(receipt, timeout: .seconds(15))
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(await rig.collector.deltas(turnId: "turn-1") == "Part one. Part two.")
    let turns = try await rig.server.get("/threads/\(ref.nativeSessionId)/turns")
    #expect(B4Protocol.turnList(turns)?.count == 1)
    #expect(rig.server.process.recentStderr().contains("GET /threads/\(ref.nativeSessionId)/runs/stream"))
    await rig.stop()
  }

  @Test func aParkedPromptSurvivesAServerRestart() async throws {
    let state = NSTemporaryDirectory() + "b4state-\(UUID().uuidString.prefix(8)).json"
    let first = try await Rig.start(serverEnvironment: ["FAKE_B4_STATE": state])
    let ref = try await first.adapter.createSession(NewSessionInput())
    _ = try await first.turn(ref, "please approve")
    try await first.collector.waitFor { $0.kind == .runtimeRequestOpened }
    let port = first.server.port
    await first.stop()

    let server = try await FakeB4Server.start(port: port, environment: ["FAKE_B4_STATE": state])
    let second = Rig.attach(server)
    let result = try await second.adapter.reconcile(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(result.activeTurnOutcome == .parked)
    let reopened = try await second.collector.waitFor { $0.kind == .runtimeRequestOpened }
    #expect(reopened.payload["request"]?["command"]?.stringValue == "rm -rf tmp")
    #expect(reopened.adapterGeneration == 2)
    let snapshot = try await second.adapter.loadSession(ref)
    #expect(snapshot.pendingRequests.map(\.nativeRequestId) == [reopened.nativeIds["requestId"]!])
    try await second.adapter.respond(
      RuntimeRequestRef(
        nativeRequestId: reopened.nativeIds["requestId"]!, kind: .commandApproval, adapterGeneration: 2),
      response: .decision(.allowOnce))
    let finished = try await second.collector.waitFor { $0.kind == .turnFinished }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
    #expect(finished.nativeIds["turnId"] == "turn-1")
    await second.stop()
  }

  @Test func aServerRestartMidRunFailsTheTurnHonestly() async throws {
    let state = NSTemporaryDirectory() + "b4state-\(UUID().uuidString.prefix(8)).json"
    let first = try await Rig.start(serverEnvironment: ["FAKE_B4_STATE": state])
    let ref = try await first.adapter.createSession(NewSessionInput())
    _ = try await first.turn(ref, "slow please")
    try await first.collector.waitFor { $0.kind == .messageDelta }
    let port = first.server.port
    await first.stop()

    let server = try await FakeB4Server.start(port: port, environment: ["FAKE_B4_STATE": state])
    let second = Rig.attach(server)
    #expect(try await server.get("/threads/\(ref.nativeSessionId)")?["status"]?.stringValue == "busy")
    let result = try await second.adapter.reconcile(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(result.activeTurnOutcome == .known(.failed))
    let next = try await second.turn(ref, "hello")
    #expect(next.nativeTurnId == "turn-2")
    try await second.finished(next)
    await second.stop()
  }

  @Test func reconcileDistinguishesRecordedFromUnrecordedTurns() async throws {
    let rig = try await Rig.start()
    let ref = try await rig.adapter.createSession(NewSessionInput())
    try await rig.finished(try await rig.turn(ref, "hello"))
    let recorded = try await rig.adapter.reconcile(ref, turn: ActiveTurnRef(nativeTurnId: "turn-1"))
    #expect(recorded.activeTurnOutcome == .known(.completed))
    // turn-1's stream may still be ending; while it is, a turn-3 reconcile can only say "unknown".
    await rig.adapter.streamsSettled()
    let missing = try await rig.adapter.reconcile(ref, turn: ActiveTurnRef(nativeTurnId: "turn-3"))
    #expect(missing.activeTurnOutcome == .known(.failed))
    let error = try await rig.collector.waitFor { $0.kind == .adapterError }
    #expect(error.payload["errorCode"]?.stringValue == "submission_unknown")
    #expect(error.nativeIds["turnId"] == "turn-3")
    let idle = try await rig.adapter.reconcile(ref, turn: nil)
    #expect(idle.activeTurnOutcome == nil)
    await rig.stop()
  }

  @Test func endpointAuthIsVerifiedOnTheFirstTurn() async throws {
    let server = try await FakeB4Server.start(environment: ["FAKE_B4_TOKEN": "s3cret"])
    let anonymous = Rig.attach(server)
    let inspection = try await anonymous.adapter.inspectConnection()
    #expect(inspection.status == .ready)
    let ref = try await anonymous.adapter.createSession(NewSessionInput())
    do {
      _ = try await anonymous.turn(ref, "hello")
      Issue.record("an unauthorized turn must fail")
    } catch let error as WorkspaceError {
      #expect(error.code == .authRequired)
      #expect(error.details?["status"]?.numberValue == 401)
    }
    let changed = try await anonymous.collector.waitFor { $0.kind == .connectionChanged }
    #expect(changed.payload["authStatus"]?.stringValue == "error")
    await anonymous.adapter.dispose()

    let authorized = Rig.attach(server, authorization: "s3cret")
    #expect(try await authorized.adapter.inspectConnection().authStatus == .unknown)
    let receipt = try await authorized.turn(ref, "hello")
    #expect(try await authorized.finished(receipt).payload["outcome"]?.stringValue == "completed")
    await authorized.stop()
  }

  @Test func routeProblemsAreCompatibilityResults() async throws {
    let server = try await FakeB4Server.start()
    let wrong = Rig.attach(server, route: "/other#agent")
    let ref = try await wrong.adapter.createSession(NewSessionInput())
    do {
      _ = try await wrong.turn(ref, "hello")
      Issue.record("an unknown route must fail")
    } catch let error as WorkspaceError {
      #expect(error.code == .incompatibleVersion)
      #expect(error.message.contains("Unknown route"))
    }
    let changed = try await wrong.collector.waitFor { $0.kind == .connectionChanged }
    #expect(changed.payload["status"]?.stringValue == "incompatible")

    let workflow = Rig.attach(server, route: "/dispatch#workflow")
    let inspection = try await workflow.adapter.inspectConnection()
    #expect(inspection.status == .incompatible)
    #expect(inspection.error?.code == .unsupportedCapability)
    do {
      _ = try await workflow.adapter.createSession(NewSessionInput())
      Issue.record("a workflow route must not start a thread")
    } catch let error as WorkspaceError {
      #expect(error.code == .unsupportedCapability)
    }
    let malformed = Rig.attach(server, route: "chat")
    #expect(try await malformed.adapter.inspectConnection().status == .error)
    await wrong.adapter.dispose()
    await server.stop()
  }

  @Test func secretsAreSentOnlyToTheConfiguredOrigin() async throws {
    let client = try B4HTTPClient(baseURL: "http://127.0.0.1:1", authorization: "Bearer t")
    #expect(client.origin == "http://127.0.0.1:1")
    #expect(B4HTTPClient.authorizationHeader(secret: "abc") == "Bearer abc")
    #expect(B4HTTPClient.authorizationHeader(secret: "Basic xyz") == "Basic xyz")
    #expect(B4HTTPClient.isLoopback("localhost"))
    #expect(!B4HTTPClient.isLoopback("agent.example.com"))
  }
}
