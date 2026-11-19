import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

/// The Mac's answer to a request: the card goes with the coordinator's reply, not with the event
/// that follows it, so its buttons are never offered again in between (D-253).
@Suite @MainActor struct RequestAnswerTests {
  private let thread = ConversationThread(id: "th", connectionId: "c", nativeThreadId: "native")

  private func request(_ state: RuntimeRequestState) -> RuntimeRequest {
    RuntimeRequest(
      id: "r1", nativeRequestId: "n-r1", threadId: "th", adapterGeneration: 1, kind: .commandApproval,
      state: state, payload: ["answerable": true], createdAt: PhoneFixture.at(0),
      updatedAt: PhoneFixture.at(0))
  }

  private func model(_ transport: ScriptedTransport, open: Bool = true) async throws -> WorkspaceModel {
    transport.set(
      connections: [Connection(id: "c", kind: .codex, label: "Codex", target: "", status: .ready)],
      threads: [thread])
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: [request(.pending)]))
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try #require(await model.settledLink() == .ready)
    model.refetchDelay = .seconds(3600)
    if open {
      await model.openThread(id: thread.id)
      try #require(model.detail?.requests.map(\.id) == ["r1"])
      try #require(model.canAnswer(request(.pending)))
    }
    return model
  }

  @Test func anAnsweredRequestLeavesWithTheReplyBeforeItsEvent() async throws {
    let transport = ScriptedTransport()
    transport.script(
      .requestRespond,
      [.result(try JSONValue(encoding: RequestRespond.Result(request: request(.resolved))))])
    let model = try await model(transport)
    await model.respond(requestId: "r1", decision: .allowOnce)
    // No resolved event has arrived, and the reply is all the model has heard.
    #expect(model.detail?.requests.isEmpty == true)
    #expect(model.lastError == nil)
    #expect(!model.canAnswer(request(.pending)))
    await model.respond(requestId: "r1", decision: .allowOnce)
    await model.answer(requestId: "r1", answers: ["q0": ["red"]])
    #expect(transport.recorded(.requestRespond).count == 1)
    await model.disconnect()
  }

  @Test func answersToAQuestionLeaveWithTheReplyToo() async throws {
    let transport = ScriptedTransport()
    transport.script(
      .requestRespond,
      [.result(try JSONValue(encoding: RequestRespond.Result(request: request(.resolved))))])
    let model = try await model(transport)
    await model.answer(requestId: "r1", answers: ["q0": ["red"]])
    #expect(model.detail?.requests.isEmpty == true)
    #expect(!model.canAnswer(request(.pending)))
    await model.answer(requestId: "r1", answers: ["q0": ["red"]])
    await model.respond(requestId: "r1", decision: .allowOnce)
    #expect(transport.recorded(.requestRespond).count == 1)
    await model.disconnect()
  }

  /// A refused answer, and a reply that says the request is still pending, keep the card.
  @Test func aRequestThatWasNotAnsweredStays() async throws {
    let transport = ScriptedTransport()
    transport.script(
      .requestRespond,
      [
        .failure(WorkspaceError(.unsupportedCapability, "Nothing wider here.")),
        .result(try JSONValue(encoding: RequestRespond.Result(request: request(.pending)))),
      ])
    let model = try await model(transport)
    await model.respond(requestId: "r1", decision: .allowAlways)
    #expect(model.detail?.requests.map(\.id) == ["r1"])
    #expect(model.lastFailure?.code == .unsupportedCapability)
    #expect(model.canAnswer(request(.pending)))
    await model.respond(requestId: "r1", decision: .allowOnce)
    #expect(model.detail?.requests.map(\.id) == ["r1"])
    #expect(model.canAnswer(request(.pending)))
    #expect(transport.recorded(.requestRespond).count == 2)
    await model.disconnect()
  }

  private func reply(_ request: RuntimeRequest) throws -> ScriptedTransport.Reply {
    .result(try JSONValue(encoding: RequestRespond.Result(request: request)))
  }

  private func event(_ kind: EventKind, _ request: RuntimeRequest) throws -> AdapterEvent {
    AdapterEvent(
      kind: kind, connectionId: "c", threadId: thread.id,
      adapterGeneration: request.adapterGeneration,
      payload: ["runtimeRequest": try JSONValue(encoding: request)])
  }

  /// Exercise the public command across an actual transport suspension. Cleanup also releases it
  /// when a fixture assertion throws, so a broken precondition cannot leave a held command behind.
  private func withHeldAnswer(
    _ model: WorkspaceModel, _ transport: ScriptedTransport, question: Bool = false,
    returning response: RuntimeRequest,
    whileHeld: () async throws -> Void
  ) async throws {
    transport.script(.requestRespond, [.hold])
    let answer = Task {
      if question {
        await model.answer(requestId: "r1", answers: ["q0": ["red"]])
      } else {
        await model.respond(requestId: "r1", decision: .allowOnce)
      }
    }
    do {
      try await waitUntil("answer reached transport") { transport.heldCount(.requestRespond) == 1 }
      try await whileHeld()
    } catch {
      transport.release(.requestRespond, with: .failure(WorkspaceError(.internalError, "fixture cleanup")))
      await model.disconnect()
      await answer.value
      throw error
    }
    let released = transport.release(.requestRespond, with: try reply(response))
    await answer.value
    #expect(released)
  }

  @Test(arguments: ["decision", "question"])
  func matchingReplyRetiresTargetAfterSelectionChanges(action: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    let other = ConversationThread(id: "other", connectionId: "c", nativeThreadId: "other-native")
    model.store(other)
    transport.setRead(ThreadRead.Result(thread: other, turns: [], items: [], requests: []))
    try await withHeldAnswer(
      model, transport, question: action == "question", returning: request(.resolved)
    ) {
      await model.openThread(id: other.id)
      try #require(model.detail?.thread.id == other.id)
    }
    #expect(model.detail?.thread.id == other.id && model.detail?.requests.isEmpty == true)
    #expect(!model.canAnswer(request(.pending)))
    #expect(model.pendingRequestTargets["r1"] == nil)
    await model.respond(requestId: "r1", decision: .allowOnce)
    await model.answer(requestId: "r1", answers: [:])
    #expect(transport.recorded(.requestRespond).count == 1)
    await model.disconnect()
  }

  @Test(arguments: ["id", "thread", "nativeRequestId", "adapterGeneration"])
  func mismatchedTerminalReplyPreservesPendingTarget(field: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    var terminal = request(.resolved)
    switch field {
    case "id": terminal.id = "other"
    case "thread": terminal.threadId = "other"
    case "nativeRequestId": terminal.nativeRequestId = "other"
    default: terminal.adapterGeneration += 1
    }
    var readTask: Task<Void, Never>?
    try await withHeldAnswer(model, transport, returning: terminal) {
      transport.script(.threadRead, [.hold])
      readTask = Task { await model.openThread(id: thread.id) }
      try await waitUntil("read issued before mismatched reply") { transport.heldCount(.threadRead) == 1 }
    }
    #expect(model.detail?.requests == [request(.pending)])
    #expect(model.canAnswer(request(.pending)))
    #expect(model.lastError == nil)
    var newlyRead = request(.pending)
    newlyRead.id = "newly-read"
    newlyRead.nativeRequestId = "newly-read-native"
    let read = ThreadRead.Result(
      thread: thread, turns: [], items: [], requests: [request(.pending), newlyRead])
    #expect(transport.release(.threadRead, with: .result(try JSONValue(encoding: read))))
    await readTask?.value
    #expect(model.detail?.requests == [request(.pending), newlyRead])
    #expect(model.canAnswer(newlyRead))
    transport.script(.requestRespond, [try reply(request(.pending))])
    await model.respond(requestId: "r1", decision: .allowOnce)
    #expect(transport.recorded(.requestRespond).count == 2)
    await model.disconnect()
  }

  @Test(arguments: ["nativeRequestId", "adapterGeneration"])
  func replacedTargetSurvivesOlderTerminalReply(field: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    var replacement = request(.pending)
    if field == "nativeRequestId" { replacement.nativeRequestId = "new-native" }
    else { replacement.adapterGeneration += 1 }
    try await withHeldAnswer(model, transport, returning: request(.resolved)) {
      let replacementRead = ThreadRead.Result(thread: thread, turns: [], items: [], requests: [replacement])
      transport.script(.threadReconcile, [.result(try JSONValue(encoding: replacementRead))])
      await model.reconcileThread(id: thread.id)
    }
    #expect(model.detail?.requests == [replacement])
    #expect(model.canAnswer(replacement))
    #expect(!model.canAnswer(request(.pending)))
    await model.disconnect()
  }

  @Test(arguments: [
    "account", "client", "deletedThread", "missingThread", "connectionId", "threadNativeScope",
    "connectionKind", "connectionNativeScope",
  ])
  func changedAccountOrRuntimeContextRejectsOlderReply(change: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    let oldClient = model.client
    var replacementClient: WorkspaceClient?
    try await withHeldAnswer(model, transport, returning: request(.resolved)) {
      switch change {
      case "account": model.accountGeneration += 1
      case "client":
        let client = WorkspaceClient(transport: ScriptedTransport())
        replacementClient = client
        model.client = client
      case "deletedThread": model.forget(threadId: thread.id)
      case "missingThread":
        let other = ConversationThread(id: "other", connectionId: "c", nativeThreadId: "other-native")
        model.store(other)
        transport.setRead(ThreadRead.Result(thread: other, turns: [], items: [], requests: []))
        await model.openThread(id: other.id)
        model.threads = []
      case "connectionId":
        var changed = thread
        changed.connectionId = "other"
        model.store(changed)
      case "threadNativeScope":
        var changed = thread
        changed.nativeScope = "rebound"
        model.store(changed)
      default:
        var changed = try #require(model.connection(id: "c"))
        if change == "connectionKind" { changed.kind = .claude }
        else { changed.nativeScope = "rebound" }
        model.merge(changed)
      }
    }
    if change == "deletedThread" {
      #expect(model.pendingRequestTargets["r1"] == nil && model.detail == nil)
    } else {
      #expect(model.pendingRequestTargets["r1"]?.nativeRequestId == "n-r1")
      if change != "missingThread" { #expect(model.detail?.requests == [request(.pending)]) }
    }
    if change == "client" { model.client = oldClient }
    await replacementClient?.close()
    await model.disconnect()
  }

  @Test(arguments: ["labelAndProfileRevision", "disabledAndStatus"])
  func cosmeticConnectionChangesStillPermitMatchingReply(change: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    try await withHeldAnswer(model, transport, returning: request(.resolved)) {
      var connection = try #require(model.connection(id: "c"))
      if change == "labelAndProfileRevision" {
        connection.label = "Renamed"
        connection.profileRevision += 1
      } else {
        connection.enabled = false
        connection.status = .offline
        connection.authStatus = .required
      }
      model.merge(connection)
      // A different request's event advances this thread's revision, but does not change r1.
      var unrelated = request(.pending)
      unrelated.id = "unrelated"
      unrelated.nativeRequestId = "unrelated-native"
      model.apply(try event(.runtimeRequestOpened, unrelated))
    }
    #expect(!model.canAnswer(request(.pending)))
    #expect(model.pendingRequestTargets["r1"] == nil)
    #expect(model.detail?.requests.map(\.id) == ["unrelated"])
    await model.disconnect()
  }

  @Test(arguments: ["noReplacement", "newNative", "newGeneration"])
  func terminalEventBeforeReplyIsIdempotent(replacement: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    var newer = request(.pending)
    if replacement == "newNative" { newer.nativeRequestId = "new-native" }
    if replacement == "newGeneration" { newer.adapterGeneration += 1 }
    try await withHeldAnswer(model, transport, returning: request(.resolved)) {
      model.apply(try event(.runtimeRequestResolved, request(.resolved)))
      if replacement != "noReplacement" { model.apply(try event(.runtimeRequestOpened, newer)) }
    }
    if replacement == "noReplacement" {
      #expect(model.pendingRequestTargets["r1"] == nil && model.detail?.requests.isEmpty == true)
    } else {
      #expect(model.canAnswer(newer))
      #expect(model.detail?.requests == [newer])
    }
    await model.disconnect()
  }

  @Test(arguments: ["loadDetail", "reconcileThread", "refetch"])
  func olderPendingReadCannotRestoreSettledRequest(path: String) async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    var stale = ThreadRead.Result(thread: thread, turns: [], items: [], requests: [request(.pending)])
    stale.turns = [
      PhoneFixture.turn("stale-read-turn", in: thread.id, operationId: "read", status: .terminal)
    ]
    let method: WorkspaceProtocol.Method = path == "reconcileThread" ? .threadReconcile : .threadRead
    var readTask: Task<Void, Never>?
    try await withHeldAnswer(model, transport, returning: request(.resolved)) {
      transport.script(method, [.hold])
      if path == "refetch" {
        model.refetchDelay = .zero
        model.apply(AdapterEvent(
          kind: .threadUpdated, connectionId: "c", threadId: thread.id,
          payload: ["thread": try JSONValue(encoding: thread)]))
      } else {
        readTask = Task {
          if path == "loadDetail" { await model.openThread(id: thread.id) }
          else { await model.reconcileThread(id: thread.id) }
        }
      }
      try await waitUntil("older read reached transport") { transport.heldCount(method) == 1 }
    }
    #expect(!model.canAnswer(request(.pending)))
    let released = transport.release(method, with: .result(try JSONValue(encoding: stale)))
    #expect(released)
    await readTask?.value
    try await waitUntil("nonrequest read fields applied") {
      model.detail?.turns.first?.id == "stale-read-turn"
    }
    #expect(model.detail?.requests.isEmpty == true)
    #expect(!model.canAnswer(request(.pending)))
    await model.disconnect()
  }

  @Test func staleInitialReadStillBuildsDetailWithoutSettledCard() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport, open: false)
    model.apply(try event(.runtimeRequestOpened, request(.pending)))
    transport.script(.threadRead, [.hold])
    transport.script(.draftRead, [.hold])
    let opening = Task { await model.openThread(id: thread.id) }
    do {
      try await waitUntil("initial read held") { transport.heldCount(.threadRead) == 1 }
      let stale = ThreadRead.Result(thread: thread, turns: [], items: [], requests: [request(.pending)])
      let released = transport.release(.threadRead, with: .result(try JSONValue(encoding: stale)))
      #expect(released)
      try await waitUntil("initial draft held") { transport.heldCount(.draftRead) == 1 }
      // Settlement during the last await must fence the pending read too.
      transport.script(.requestRespond, [try reply(request(.resolved))])
      await model.respond(requestId: "r1", decision: .allowOnce)
      #expect(model.detail == nil && !model.canAnswer(request(.pending)))
      let draft = DraftRead.Result(draft: nil)
      #expect(transport.release(.draftRead, with: .result(try JSONValue(encoding: draft))))
      await opening.value
      #expect(model.detail?.thread.id == thread.id && model.detail?.requests.isEmpty == true)
    } catch {
      await model.disconnect()
      await opening.value
      throw error
    }
    await model.disconnect()
  }

  @Test func staleInitialReadKeepsOnlyExactSurvivingPendingIdentities() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport, open: false)
    let survivor = request(.pending)
    var second = survivor
    second.id = "second"
    second.nativeRequestId = "second-native"
    var unknown = survivor
    unknown.id = "unknown"
    var wrongThread = survivor
    wrongThread.id = "wrong-thread"
    wrongThread.threadId = "elsewhere"
    var oldGeneration = survivor
    oldGeneration.adapterGeneration += 1
    var oldNative = survivor
    oldNative.id = "second"
    oldNative.nativeRequestId = "older-native"
    let terminal = request(.resolved)
    transport.script(.threadRead, [.hold])
    let opening = Task { await model.openThread(id: thread.id) }
    do {
      try await waitUntil("initial read held") { transport.heldCount(.threadRead) == 1 }
      model.apply(try event(.runtimeRequestOpened, survivor))
      model.apply(try event(.runtimeRequestOpened, second))
      let read = ThreadRead.Result(
        thread: thread, turns: [], items: [],
        requests: [unknown, second, wrongThread, oldGeneration, terminal, oldNative, survivor])
      let released = transport.release(.threadRead, with: .result(try JSONValue(encoding: read)))
      #expect(released)
      await opening.value
      #expect(model.detail?.requests == [second, survivor])
      #expect(model.canAnswer(survivor) && model.canAnswer(second))
    } catch {
      await model.disconnect()
      await opening.value
      throw error
    }
    await model.disconnect()
  }

  @Test func staleReadPreservesNewerSameThreadCards() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    var newer = request(.pending)
    newer.id = "new-card"
    newer.nativeRequestId = "new-card-native"
    transport.script(.threadRead, [.hold])
    let opening = Task { await model.openThread(id: thread.id) }
    do {
      try await waitUntil("older read held") { transport.heldCount(.threadRead) == 1 }
      model.apply(try event(.runtimeRequestResolved, request(.resolved)))
      model.apply(try event(.runtimeRequestOpened, newer))
      let current = model.detail?.requests
      let stale = ThreadRead.Result(thread: thread, turns: [], items: [], requests: [request(.pending)])
      let released = transport.release(.threadRead, with: .result(try JSONValue(encoding: stale)))
      #expect(released)
      await opening.value
      #expect(model.detail?.requests == current && current == [newer])
      #expect(model.canAnswer(newer) && !model.canAnswer(request(.pending)))
    } catch {
      await model.disconnect()
      await opening.value
      throw error
    }
    await model.disconnect()
  }
}
