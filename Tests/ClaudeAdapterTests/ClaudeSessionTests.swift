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
}

struct Rig {
  let adapter: ClaudeAdapter
  let collector: EventCollector
  let workDir: String
  let projects: String
  /// The fake's `FAKE_CLAUDE_LOG`: its argv, control requests, and user messages, one JSON line each.
  let log: String

  init(environment extra: [String: String] = [:]) throws {
    let base = NSTemporaryDirectory() + "b4claude-\(UUID().uuidString.prefix(8))"
    workDir = base + "/work"
    projects = base + "/projects"
    log = base + "/fake-claude.log"
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
    var env = ProcessInfo.processInfo.environment
    env["FAKE_CLAUDE_PROJECTS"] = projects
    env["ANTHROPIC_API_KEY"] = nil
    env["FAKE_CLAUDE_LOG"] = log
    for (key, value) in extra { env[key] = value }
    adapter = ClaudeAdapter(
      connectionId: "c1", executablePath: fakeClaudePath(), environment: env, clientVersion: "test")
    collector = EventCollector(adapter.events())
  }

  func turn(
    _ ref: NativeSessionRef, _ text: String, model: String? = nil, permission: String? = nil,
    additionalDirectories: [String] = []
  ) async throws -> SubmissionReceipt {
    try await adapter.sendTurn(
      ref,
      input: TurnInput(
        operationId: UUID().uuidString, text: text, workingDirectory: workDir, model: model,
        permission: permission, additionalDirectories: additionalDirectories))
  }

  /// A turn that runs to its end.
  func completedTurn(
    _ ref: NativeSessionRef, _ text: String, model: String? = nil, permission: String? = nil,
    additionalDirectories: [String] = []
  ) async throws {
    let receipt = try await turn(
      ref, text, model: model, permission: permission, additionalDirectories: additionalDirectories)
    let finished = try await collector.waitFor {
      $0.kind == .turnFinished && $0.nativeIds["turnId"] == receipt.nativeTurnId
    }
    #expect(finished.payload["outcome"]?.stringValue == "completed")
  }

  func logLines() throws -> [JSONValue] {
    let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    return try text.split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

  /// Each launch's arguments, in order.
  func launches() throws -> [[String]] {
    try logLines().compactMap { $0["argv"]?.arrayValue?.compactMap(\.stringValue) }
  }

  /// The log entries for control requests of `subtype`.
  func controls(_ subtype: String) throws -> [JSONValue] {
    try logLines().filter { $0["control"]?.stringValue == subtype }
  }
}

/// The values that follow each occurrence of `flag`.
func values(of flag: String, in argv: [String]) -> [String] {
  argv.indices.filter { argv[$0] == flag && $0 + 1 < argv.count }.map { argv[$0 + 1] }
}

@Suite(.serialized) struct ClaudeSessionTests {
  /// A dispose is final: no `claude` process starts after it.
  @Test func aDisposedAdapterStartsNoProcessAgain() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    await rig.adapter.dispose()
    let sent = await #expect(throws: WorkspaceError.self) { _ = try await rig.turn(ref, "hello") }
    #expect(sent?.code == .endpointUnavailable)
    await #expect(throws: WorkspaceError.self) {
      _ = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    }
    await #expect(throws: WorkspaceError.self) { _ = try await rig.adapter.startLogin() }
  }

  @Test func inspectsThroughTheFixture() async throws {
    let rig = try Rig()
    let inspection = try await rig.adapter.inspectConnection()
    #expect(inspection.status == .ready)
    #expect(inspection.authStatus == .authenticated)
    #expect(inspection.nativeScope == "owner@example.com")
    #expect(inspection.version == "2.1.282")
    #expect(inspection.capabilities[.permissionDecisions] == .supported)
    #expect(inspection.models?.map(\.id) == ["opus", "sonnet", "haiku"])
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
    let kinds = await rig.collector.events.map(\.kind).filter {
      $0 != .turnStateChanged && $0 != .usageChanged && $0 != .commandsChanged
    }
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

  /// The CLI's "No conversation found" line can arrive after its exit is seen (a grandchild still
  /// holds stderr, or the pipe simply drains late); the session reads stderr to its end before it
  /// reports the exit, so a missing session is still told apart from a crash.
  @Test func aMissingSessionIsRecognisedWhenStderrTrailsTheExit() async throws {
    let rig = try Rig()
    do {
      _ = try await rig.turn(
        NativeSessionRef(nativeSessionId: "missing-late", nativeScope: "owner@example.com"), "hi")
      Issue.record("expected native_session_missing")
    } catch let error as WorkspaceError {
      #expect(error.code == .nativeSessionMissing)
    }
    await rig.adapter.dispose()
  }
  @Test func launchPassesModelPermissionAndDirectories() async throws {
    let rig = try Rig()
    _ = try await rig.adapter.createSession(
      NewSessionInput(
        workingDirectory: rig.workDir, model: "opus", permission: "plan", additionalDirectories: ["/x", "/z"])
    )
    let argv = try #require(try rig.launches().first)
    #expect(argv.filter { $0.hasPrefix("--model") } == ["--model=opus"])
    #expect(values(of: "--permission-mode", in: argv) == ["plan"])
    #expect(values(of: "--add-dir", in: argv) == ["/x", "/z"])
    await rig.adapter.dispose()
  }

  /// No permission ("As configured"), or one Claude Code does not know, leaves Claude Code's settings.
  @Test func asConfiguredOmitsPermissionMode() async throws {
    let rig = try Rig()
    _ = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.adapter.createSession(
      NewSessionInput(workingDirectory: rig.workDir, permission: "yolo"))
    let launches = try rig.launches()
    #expect(launches.count == 2)
    for argv in launches {
      #expect(!argv.contains("--permission-mode"))
      #expect(!argv.contains { $0.hasPrefix("--model") })
      #expect(!argv.contains("--add-dir"))
    }
    await rig.adapter.dispose()
  }

  @Test func aChangedPermissionIsSentAsAControlRequest() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    try await rig.completedTurn(ref, "hello")
    try await rig.completedTurn(ref, "hello again", permission: "acceptEdits")
    let sent = try rig.controls("set_permission_mode")
    #expect(sent.map { $0["request"]?["mode"]?.stringValue } == ["acceptEdits"])
    // Sent before the turn's user message, on the same process.
    let order = try rig.logLines().compactMap { $0["control"]?.stringValue ?? $0["user"]?.stringValue }
    #expect(order.suffix(2) == ["set_permission_mode", "hello again"])
    #expect(try rig.launches().count == 1)
    // Unchanged sends nothing more.
    try await rig.completedTurn(ref, "third", permission: "acceptEdits")
    #expect(try rig.controls("set_permission_mode").count == 1)
    #expect(try rig.launches().count == 1)
    // Unset ("As configured") restarts on the same conversation without the flag, as a fresh launch would.
    try await rig.completedTurn(ref, "fourth")
    #expect(try rig.controls("set_permission_mode").count == 1)
    let launches = try rig.launches()
    #expect(launches.count == 2)
    let restarted = try #require(launches.last)
    #expect(values(of: "--resume", in: restarted) == [ref.nativeSessionId])
    #expect(!restarted.contains("--permission-mode"))
    await rig.adapter.dispose()
  }

  /// Claude Code refuses to switch a live process into `bypassPermissions` unless it launched in it, so
  /// a change to it restarts on the same conversation with the flag rather than sending a control request.
  @Test func aChangeToBypassPermissionsRestartsWithTheFlag() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(
      NewSessionInput(workingDirectory: rig.workDir, permission: "acceptEdits"))
    try await rig.completedTurn(ref, "hello", permission: "acceptEdits")
    try await rig.completedTurn(ref, "hello again", permission: "bypassPermissions")
    #expect(try rig.controls("set_permission_mode").isEmpty)
    let launches = try rig.launches()
    #expect(launches.count == 2)
    let restarted = try #require(launches.last)
    #expect(values(of: "--resume", in: restarted) == [ref.nativeSessionId])
    #expect(values(of: "--permission-mode", in: restarted) == ["bypassPermissions"])
    // Leaving it is an ordinary control request on the process that launched in it.
    try await rig.completedTurn(ref, "third", permission: "plan")
    #expect(try rig.controls("set_permission_mode").map { $0["request"]?["mode"]?.stringValue } == ["plan"])
    #expect(try rig.launches().count == 2)
    await rig.adapter.dispose()
  }

  @Test func aChangedModelIsSentAsAControlRequest() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(
      NewSessionInput(workingDirectory: rig.workDir, model: "opus"))
    try await rig.completedTurn(ref, "hello", model: "opus")
    #expect(try rig.controls("set_model").isEmpty)
    try await rig.completedTurn(ref, "hello again", model: "sonnet")
    #expect(try rig.controls("set_model").map { $0["request"]?["model"]?.stringValue } == ["sonnet"])
    #expect(try rig.launches().count == 1)
    // Unset ("Default") restarts on the same conversation without `--model`.
    try await rig.completedTurn(ref, "back to default")
    #expect(try rig.controls("set_model").count == 1)
    let launches = try rig.launches()
    #expect(launches.count == 2)
    let restarted = try #require(launches.last)
    #expect(values(of: "--resume", in: restarted) == [ref.nativeSessionId])
    #expect(!restarted.contains { $0.hasPrefix("--model") })
    await rig.adapter.dispose()
  }

  @Test func aRefusedControlRequestFailsTheTurn() async throws {
    let rig = try Rig(environment: ["FAKE_CLAUDE_REJECT_CONTROL": "set_model"])
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    try await rig.completedTurn(ref, "hello")
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.turn(ref, "hello again", model: "sonnet")
    }
    #expect(refused?.code == .unsupportedCapability)
    #expect(refused?.message.contains("set_model") == true)
    // The turn's message never reached Claude Code.
    #expect(try rig.logLines().compactMap { $0["user"]?.stringValue } == ["hello"])
    await rig.adapter.dispose()
  }

  /// `--add-dir` is a launch flag: a new directory set restarts the process on the same conversation.
  @Test func changedDirectoriesRestartWithResume() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(
      NewSessionInput(workingDirectory: rig.workDir, permission: "plan", additionalDirectories: ["/x"]))
    try await rig.completedTurn(ref, "hello", permission: "plan", additionalDirectories: ["/x"])
    try await rig.completedTurn(ref, "hello again", permission: "plan", additionalDirectories: ["/y"])
    let launches = try rig.launches()
    #expect(launches.count == 2)
    let restarted = try #require(launches.last)
    #expect(values(of: "--resume", in: restarted) == [ref.nativeSessionId])
    #expect(values(of: "--add-dir", in: restarted) == ["/y"])
    // The thread's permission is a launch flag again.
    #expect(values(of: "--permission-mode", in: restarted) == ["plan"])
    // A deliberate restart is not reported as the runtime exiting.
    let exits = await rig.collector.events.filter {
      $0.kind == .connectionChanged && $0.payload["transport"]?.stringValue == "disconnected"
    }
    #expect(exits.isEmpty)
    await rig.adapter.dispose()
  }

  // MARK: Commands

  @Test func aStartedSessionReportsItsCommands() async throws {
    let rig = try Rig()
    _ = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    let event = try await rig.collector.waitFor { $0.kind == .commandsChanged }
    let commands = try #require(try event.payload["commands"]?.decode([RuntimeCommand].self))
    // The entry no composer token can spell is dropped; a description keeps its first line.
    #expect(commands.map(\.name) == ["context", "compact", "superpowers:brainstorming"])
    #expect(commands[1].description == "Summarize the conversation so far")
    #expect(commands[1].argumentHint == "[instructions]")
    #expect(commands[0].argumentHint == nil)
    #expect(commands[2].aliases == ["brainstorming"])
    #expect(event.connectionId == "c1")
    #expect(event.nativeIds.isEmpty)
    await rig.adapter.dispose()
  }

  @Test func readsCommandsWithoutSendingAMessage() async throws {
    let rig = try Rig()
    let commands = try await rig.adapter.readCommands()
    #expect(commands.map(\.name) == ["context", "compact", "superpowers:brainstorming"])
    // One launch, and no user message.
    #expect(try rig.logLines().filter { $0["commandRead"] != nil }.count == 1)
    #expect(try rig.launches().isEmpty)
    #expect(try rig.logLines().allSatisfy { $0["user"] == nil })
    // The fixture opens its transcript at launch; nothing was written to it.
    let written = FileManager.default.enumerator(atPath: rig.projects)?.compactMap { $0 as? String } ?? []
    for file in written where file.hasSuffix(".jsonl") {
      #expect(try Data(contentsOf: URL(fileURLWithPath: rig.projects + "/" + file)).isEmpty)
    }
    await rig.adapter.dispose()
  }

  /// As 2.1.282 answers a local command live: one synthetic message, no inference, a plain result.
  @Test func aCommandSentAsAMessageRunsAsATurn() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    try await rig.completedTurn(ref, "/context")
    let completed = await rig.collector.events.first { $0.kind == .messageCompleted }
    #expect(completed?.payload["item"]?["text"]?.stringValue?.hasPrefix("## Context Usage") == true)
    #expect(await rig.collector.events.filter { $0.kind == .messageCompleted }.count == 1)
    await rig.adapter.dispose()
  }
}
