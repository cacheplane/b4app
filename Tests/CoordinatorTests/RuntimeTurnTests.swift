import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import Coordinator

func runtimeAck(_ connection: Connection, _ thread: ConversationThread, turn: String) -> AdapterEvent {
  AdapterEvent(
    kind: .turnAcknowledged, connectionId: connection.id,
    nativeIds: ["threadId": thread.nativeThreadId, "turnId": .init(turn)],
    payload: ["origin": "runtime", "status": "inProgress"])
}

func injecting() async throws -> (Harness, AsyncStream<AdapterEvent>.Continuation) {
  let (injected, deliver) = AsyncStream<AdapterEvent>.makeStream()
  let h = try await Harness.start(adapterFactory: { connection, environment, version, secrets in
    InjectingAdapter(
      inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
      injected: injected)
  })
  return (h, deliver)
}

@Suite struct RuntimeTurnTests {
  struct Fixture {
    let h: Harness
    let deliver: AsyncStream<AdapterEvent>.Continuation
    let connection: Connection
    let thread: ConversationThread

    static func make() async throws -> Fixture {
      let (h, deliver) = try await injecting()
      let connection = try await h.addCodex()
      let thread = try await h.newThread(connection)
      let turn = try await h.send(thread, "hello there")
      _ = try await h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn.id }
      // The fake runtime then reports the thread idle; a test that counts events must not take it for its own.
      _ = try await h.events.waitFor {
        $0.kind == .turnStateChanged && $0.payload["nativeStatus"]?.stringValue == "idle"
      }
      return Fixture(h: h, deliver: deliver, connection: connection, thread: thread)
    }

    /// Delivers `event` and waits for the coordinator to publish an event of its kind.
    func send(_ event: AdapterEvent) async {
      let kind = event.kind
      let before = await h.events.events.filter { $0.event.kind == kind }.count
      deliver.yield(event)
      _ = await h.events.until { $0.filter { $0.kind == kind }.count > before }
    }

    func event(
      _ kind: EventKind, turn: String?, payload: JSONValue = [:], item: String? = nil
    )
      -> AdapterEvent
    {
      var ids = ["threadId": thread.nativeThreadId]
      if let turn { ids["turnId"] = turn }
      if let item { ids["itemId"] = item }
      return AdapterEvent(kind: kind, connectionId: connection.id, nativeIds: ids, payload: payload)
    }

    func message(turn: String?, id: String = "m-1") -> AdapterEvent {
      event(
        .messageCompleted, turn: turn,
        payload: [
          "role": "assistant", "type": "agentMessage",
          "item": ["text": "done"],
        ], item: id)
    }

    func turns() async throws -> [Turn] { try await h.read(thread).turns }

    func projectionErrors() async throws -> Int {
      try await h.coordinator.diagnostics.read().recentErrors.filter { $0.scope == "projection" }.count
    }
  }

  @Test func aRuntimeAcknowledgementMakesATurnRow() async throws {
    let f = try await Fixture.make()
    let itemsBefore = try await f.h.read(f.thread).items.count
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let turns = try await f.turns()
    #expect(turns.count == 2)
    let made = try #require(turns.first { $0.nativeTurnId == "rt-1" })
    #expect(made.origin == "runtime")
    #expect(made.operationId == "runtime:\(f.thread.id):rt-1")
    #expect(made.status == .running)
    #expect(made.submission == .acknowledged)
    let published = try #require(
      await f.h.events.events.last { $0.event.kind == .turnAcknowledged }?.event)
    #expect(published.turnId == made.id)
    #expect(published.payload["turn"]?["id"]?.stringValue == made.id)
    #expect(try await f.h.read(f.thread).items.count == itemsBefore)
    await f.h.stop()
  }

  @Test func aRuntimeTurnTakesItsItemsAndItsEnd() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(f.message(turn: "rt-1"))
    await f.send(
      f.event(.turnFinished, turn: "rt-1", payload: ["outcome": "completed", "origin": "task-notification"]))
    let made = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "m-1" })
    #expect(item.turnId == made.id)
    #expect(made.status == .terminal)
    #expect(made.outcome == .completed)
    #expect(made.origin == "task-notification")
    await f.h.stop()
  }

  @Test func aRepeatedRuntimeAcknowledgementMakesOneRow() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let before = try await f.projectionErrors()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    #expect(try await f.turns().count == 2)
    #expect(try await f.projectionErrors() == before)
    await f.h.stop()
  }

  @Test func aRuntimeAcknowledgementDuringAnUnfinishedTurnMakesNoRow() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-2"))
    #expect(try await f.turns().count == 2)
    let first = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    await f.send(f.message(turn: "rt-2"))
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "m-1" })
    #expect(item.turnId == first.id)
    await f.send(f.event(.turnFinished, turn: "rt-2", payload: ["outcome": "completed"]))
    let after = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    #expect(after.status == .running)
    await f.h.stop()
  }

  @Test func aFinishNamingAnUnknownTurnEndsNoTurn() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let before = try await f.turns()
    await f.send(f.event(.turnFinished, turn: "zz", payload: ["outcome": "completed"]))
    let after = try await f.turns()
    let running = try #require(after.first { $0.nativeTurnId == "rt-1" })
    #expect(running.status == .running)
    #expect(after.first?.updatedAt == before.first?.updatedAt)
    #expect(after == before)
    await f.h.stop()
  }

  @Test func anAcknowledgementWithoutOriginMakesNoRow() async throws {
    let f = try await Fixture.make()
    await f.send(f.event(.turnAcknowledged, turn: "rt-9", payload: ["status": "inProgress"]))
    #expect(try await f.turns().count == 1)
    await f.h.stop()
  }

  @Test func anEventNamingNoTurnStillJoinsTheActiveTurn() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await f.send(f.message(turn: nil))
    let made = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "m-1" })
    #expect(item.turnId == made.id)
    await f.h.stop()
  }

  @Test func twoThreadsCanEachHoldARuntimeTurnWithTheSameNativeId() async throws {
    let (h, deliver) = try await injecting()
    let connection = try await h.addCodex()
    let first = try await h.newThread(connection)
    let second = try await h.newThread(connection)
    for thread in [first, second] {
      let before = await h.events.events.filter { $0.event.kind == .turnAcknowledged }.count
      deliver.yield(runtimeAck(connection, thread, turn: "rt-1"))
      _ = await h.events.until { $0.filter { $0.kind == .turnAcknowledged }.count > before }
    }
    for thread in [first, second] {
      let turns = try await h.read(thread).turns
      #expect(turns.count == 1)
      #expect(turns.first?.origin == "runtime")
      #expect(turns.first?.operationId == "runtime:\(thread.id):rt-1")
    }
    let errors = try await h.coordinator.diagnostics.read().recentErrors
    #expect(errors.filter { $0.scope == "projection" }.isEmpty)
    await h.stop()
  }

  @Test func aRequestNamingAnUnknownTurnStillJoinsTheActiveTurn() async throws {
    let f = try await Fixture.make()
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let made = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    var event = f.event(
      .runtimeRequestOpened, turn: "zz",
      payload: ["kind": "command_approval", "command": "ls"])
    event.nativeIds["requestId"] = "req-1"
    await f.send(event)
    let opened = try #require(
      await f.h.events.events.last { $0.event.kind == .runtimeRequestOpened }?.event)
    let request = try #require(try opened.payload["runtimeRequest"]?.decode(RuntimeRequest.self))
    #expect(request.turnId == made.id)
    let after = try #require(try await f.turns().first { $0.id == made.id })
    #expect(after.status == .waitingForUser)
    await f.h.stop()
  }

  @Test func aRefusedRuntimeTurnsFinishDoesNotEndAnUnacknowledgedTurn() async throws {
    let (injected, deliver) = AsyncStream<AdapterEvent>.makeStream()
    let gate = SendGate()
    let h = try await Harness.start(adapterFactory: { connection, environment, version, secrets in
      HeldSendAdapter(
        inner: InjectingAdapter(
          inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
          injected: injected),
        gate: gate)
    })
    let connection = try await h.addCodex()
    let thread = try await h.newThread(connection)
    let sending = Task { try await h.send(thread, "hello there") }
    // The owner's turn is saved as submitting before the runtime is asked to take it.
    let saved = try await h.events.waitFor { $0.kind == .turnStateChanged && $0.threadId == thread.id }
    let owners = try #require(saved.turnId)
    func settle(_ event: AdapterEvent) async {
      let kind = event.kind
      let before = await h.events.events.filter { $0.event.kind == kind }.count
      deliver.yield(event)
      _ = await h.events.until { $0.filter { $0.kind == kind }.count > before }
    }
    await settle(runtimeAck(connection, thread, turn: "rt-1"))
    await settle(
      AdapterEvent(
        kind: .turnFinished, connectionId: connection.id,
        nativeIds: ["threadId": thread.nativeThreadId, "turnId": "rt-1"],
        payload: ["outcome": "completed"]))
    // The thread cannot be read while the send is held, so the published events tell what happened.
    let seen = await h.events.events.map(\.event)
    let stray = try #require(seen.last { $0.kind == .turnFinished })
    #expect(stray.turnId == nil)
    #expect(stray.payload["turn"] == nil)
    #expect(!seen.contains { $0.kind == .turnFinished && $0.turnId == owners })
    await gate.open()
    let sent = try await sending.value
    #expect(sent.id == owners)
    #expect(sent.status != .terminal || sent.nativeTurnId != "rt-1")
    await h.stop()
  }
}

/// Holds `sendTurn` until the test opens the gate, so an owner's turn stays submitting.
actor SendGate {
  private var opened = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func open() {
    opened = true
    for waiter in waiting { waiter.resume() }
    waiting = []
  }
}

struct HeldSendAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let gate: SendGate
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    await gate.wait()
    return try await inner.sendTurn(ref, input: input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    try await inner.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    try await inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await inner.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { inner.events() }
  func dispose() async { await inner.dispose() }
}

func agent(
  _ kind: EventKind, _ connection: Connection, _ thread: ConversationThread, id: String, turn: String?,
  status: String
) -> AdapterEvent {
  var ids = ["threadId": thread.nativeThreadId, "itemId": .init(id)]
  if let turn { ids["turnId"] = .init(turn) }
  return AdapterEvent(
    kind: kind, connectionId: connection.id, nativeIds: ids,
    payload: [
      "type": "toolUse", "role": "tool",
      "item": ["agent": true, "title": "Look", "status": .string(status)],
    ])
}

@Suite struct OpenWorkTests {
  let f: RuntimeTurnTests.Fixture
  let first: Turn
  let native: String

  init() async throws {
    f = try await .make()
    first = try #require(try await f.turns().first)
    native = try #require(first.nativeTurnId)
  }

  func turnNow() async throws -> Turn {
    try #require(try await f.turns().first { $0.id == first.id })
  }

  /// Sends an agent event and waits for the turn event that follows when the count changes.
  func change(_ kind: EventKind, _ id: String, status: String, turn: String? = nil) async {
    let before = await f.h.events.events.filter { $0.event.kind == .turnStateChanged }.count
    await f.send(agent(kind, f.connection, f.thread, id: id, turn: turn ?? native, status: status))
    _ = await f.h.events.until { $0.filter { $0.kind == .turnStateChanged }.count > before }
  }

  /// Sends an event that changes nothing, then a message behind it, so the event is handled by the time this returns.
  func settle(_ event: AdapterEvent) async {
    await f.send(event)
    await f.send(f.message(turn: native, id: "sentinel-\(UUID().uuidString)"))
  }

  @Test func anAgentStillRunningIsOpenWork() async throws {
    await change(.toolStarted, "a1", status: "inProgress")
    let turn = try await turnNow()
    #expect(turn.status == .terminal)
    #expect(turn.openWork == 1)
    let published = try #require(
      await f.h.events.events.last { $0.event.kind == .turnStateChanged }?.event)
    #expect(published.turnId == turn.id)
    #expect(published.payload["turn"]?["openWork"]?.numberValue == 1)
    let listed = try await f.h.client.request(ThreadList.self, ThreadList.Params()).threads
    let summary = try #require(listed.first { $0.id == f.thread.id })
    #expect(summary.activity?.openWork == 1)
    #expect(Attention.state(of: summary) == .working)
    await f.h.stop()
  }

  @Test func theItemIsPublishedBeforeTheTurnsCount() async throws {
    await change(.toolStarted, "a1", status: "inProgress")
    let kinds = await f.h.events.events.map(\.event.kind)
    let item = try #require(kinds.lastIndex(of: .toolStarted))
    let turn = try #require(kinds.lastIndex(of: .turnStateChanged))
    #expect(item < turn)
    await f.h.stop()
  }

  @Test func openWorkFollowsEachAgent() async throws {
    var stamps = [try await turnNow().updatedAt]
    await change(.toolStarted, "a1", status: "inProgress")
    await change(.toolStarted, "a2", status: "inProgress")
    #expect(try await turnNow().openWork == 2)
    stamps.append(try await turnNow().updatedAt)
    await change(.toolCompleted, "a1", status: "completed")
    #expect(try await turnNow().openWork == 1)
    stamps.append(try await turnNow().updatedAt)
    await change(.toolCompleted, "a2", status: "failed")
    #expect(try await turnNow().openWork == 0)
    stamps.append(try await turnNow().updatedAt)
    for (earlier, later) in zip(stamps, stamps.dropFirst()) { #expect(later > earlier) }
    await f.h.stop()
  }

  @Test func anAgentCompletedTwiceCountsOnce() async throws {
    await change(.toolStarted, "a1", status: "inProgress")
    await change(.toolCompleted, "a1", status: "completed")
    let before = try await turnNow()
    await settle(agent(.toolCompleted, f.connection, f.thread, id: "a1", turn: native, status: "completed"))
    let after = try await turnNow()
    #expect(after.openWork == 0)
    #expect(after.updatedAt == before.updatedAt)
    await f.h.stop()
  }

  @Test func anAgentSeenOnlyAtItsEndCountsNothing() async throws {
    await settle(agent(.toolCompleted, f.connection, f.thread, id: "a1", turn: native, status: "completed"))
    let turn = try await turnNow()
    #expect(turn.openWork == 0)
    #expect(turn.updatedAt == first.updatedAt)
    #expect(try await f.h.read(f.thread).items.contains { $0.nativeItemId == "a1" })
    await f.h.stop()
  }

  @Test func aStepThatIsNotAnAgentIsNotOpenWork() async throws {
    await settle(
      AdapterEvent(
        kind: .toolStarted, connectionId: f.connection.id,
        nativeIds: ["threadId": f.thread.nativeThreadId, "turnId": .init(native), "itemId": "t1"],
        payload: ["type": "toolUse", "role": "tool", "item": ["title": "Look", "status": "inProgress"]]))
    let turn = try await turnNow()
    #expect(turn.openWork == 0)
    #expect(turn.updatedAt == first.updatedAt)
    await f.h.stop()
  }

  @Test func anAgentWithNoTurnCountsNowhere() async throws {
    await settle(agent(.toolStarted, f.connection, f.thread, id: "a1", turn: nil, status: "inProgress"))
    let turns = try await f.turns()
    #expect(turns.allSatisfy { $0.openWork == 0 })
    let item = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "a1" })
    #expect(item.turnId == nil)
    await f.h.stop()
  }

  @Test func aRunningTurnsAgentCountsToo() async throws {
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    await change(.toolStarted, "a1", status: "inProgress", turn: "rt-1")
    let made = try #require(try await f.turns().first { $0.nativeTurnId == "rt-1" })
    #expect(made.status == .running)
    #expect(made.openWork == 1)
    await f.h.stop()
  }
}

@Suite struct OpenWorkEndsTests {
  func exit(
    _ f: RuntimeTurnTests.Fixture, thread: ConversationThread? = nil
  ) -> AdapterEvent {
    var ids: [String: String] = [:]
    if let thread { ids["threadId"] = thread.nativeThreadId }
    return AdapterEvent(
      kind: .connectionChanged, connectionId: f.connection.id, nativeIds: ids,
      payload: ["transport": "disconnected"])
  }

  /// Opens an agent on the thread's last turn and waits until its count is stored.
  func open(
    _ f: RuntimeTurnTests.Fixture, _ thread: ConversationThread, id: String
  ) async throws -> Turn {
    let turn = try #require(try await f.h.read(thread).turns.last)
    let before = await f.h.events.events.filter { $0.event.kind == .turnStateChanged }.count
    f.deliver.yield(
      agent(
        .toolStarted, f.connection, thread, id: id, turn: try #require(turn.nativeTurnId),
        status: "inProgress"))
    _ = await f.h.events.until { $0.filter { $0.kind == .turnStateChanged }.count > before }
    return turn
  }

  /// The count follows the item's announcement, so wait until the turn's is stored.
  func settled(
    _ f: RuntimeTurnTests.Fixture, _ thread: ConversationThread, _ turnId: String
  )
    async throws
  {
    for _ in 0..<600 {
      if try await f.h.read(thread).turns.first(where: { $0.id == turnId })?.openWork == 0 { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw WorkspaceError(.internalError, "the turn's open work never reached 0")
  }

  func completions(_ f: RuntimeTurnTests.Fixture) async -> Int {
    await f.h.events.events.filter { $0.event.kind == .toolCompleted }.count
  }

  func expectStopped(
    _ f: RuntimeTurnTests.Fixture, _ thread: ConversationThread, _ id: String
  )
    async throws
  {
    let item = try #require(try await f.h.read(thread).items.first { $0.nativeItemId == id })
    #expect(item.payload["status"]?.stringValue == "stopped")
    #expect(item.payload["endedAt"]?.stringValue != nil)
    #expect(item.payload["agent"]?.boolValue == true)
  }

  @Test func aSessionThatExitsClosesItsOpenWork() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    let turn = try await open(f, f.thread, id: "a1")
    #expect(try await f.turns().first { $0.id == turn.id }?.openWork == 1)
    let before = await completions(f)
    f.deliver.yield(exit(f, thread: f.thread))
    _ = await f.h.events.until { $0.filter { $0.kind == .toolCompleted }.count > before }
    try await expectStopped(f, f.thread, "a1")
    let done = try #require(await f.h.events.events.last { $0.event.kind == .toolCompleted }?.event)
    #expect(done.payload["displayItem"]?["payload"]?["status"]?.stringValue == "stopped")
    try await settled(f, f.thread, turn.id)
    let stored = try #require(try await f.turns().first { $0.id == turn.id })
    #expect(stored.openWork == 0)
    await f.h.stop()
  }

  @Test func anAgentAlreadyClosedIsNotRewritten() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    let turn = try await open(f, f.thread, id: "a1")
    let native = try #require(turn.nativeTurnId)
    f.deliver.yield(
      agent(.toolCompleted, f.connection, f.thread, id: "a1", turn: native, status: "completed"))
    _ = await f.h.events.until { $0.contains { $0.kind == .toolCompleted } }
    let closed = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "a1" })
    let stamp = try #require(try await f.turns().first { $0.id == turn.id }).updatedAt
    let before = await completions(f)
    f.deliver.yield(exit(f, thread: f.thread))
    f.deliver.yield(f.message(turn: native, id: "sentinel"))
    _ = await f.h.events.until { $0.contains { $0.nativeIds["itemId"] == "sentinel" } }
    let after = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "a1" })
    #expect(after.payload["status"]?.stringValue == "completed")
    #expect(after.payload == closed.payload)
    #expect(await completions(f) == before)
    #expect(try await f.turns().first { $0.id == turn.id }?.updatedAt == stamp)
    await f.h.stop()
  }

  @Test func aConnectionThatDropsClosesEveryThreadsOpenWork() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    let second = try await f.h.newThread(f.connection)
    let turn2 = try await f.h.send(second, "and here")
    _ = try await f.h.events.waitFor { $0.kind == .turnFinished && $0.turnId == turn2.id }
    _ = await f.h.events.until {
      $0.filter { $0.kind == .turnStateChanged && $0.payload["nativeStatus"]?.stringValue == "idle" }.count
        >= 2
    }
    let one = try await open(f, f.thread, id: "a1")
    let two = try await open(f, second, id: "a2")
    let before = await completions(f)
    f.deliver.yield(exit(f))
    _ = await f.h.events.until { $0.filter { $0.kind == .toolCompleted }.count >= before + 2 }
    try await expectStopped(f, f.thread, "a1")
    try await expectStopped(f, second, "a2")
    try await settled(f, f.thread, one.id)
    try await settled(f, second, two.id)
    #expect(try await f.turns().first { $0.id == one.id }?.openWork == 0)
    #expect(try await f.h.read(second).turns.first { $0.id == two.id }?.openWork == 0)
    await f.h.stop()
  }

  @Test func aRunningTurnGoesToReconcilingAndEarlierOpenWorkIsClosed() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    let first = try await open(f, f.thread, id: "a1")
    await f.send(runtimeAck(f.connection, f.thread, turn: "rt-1"))
    let before = await completions(f)
    f.deliver.yield(exit(f, thread: f.thread))
    _ = await f.h.events.until { $0.filter { $0.kind == .toolCompleted }.count > before }
    let turns = try await f.turns()
    #expect(turns.first { $0.nativeTurnId == "rt-1" }?.status == .reconciling)
    #expect(turns.first { $0.id == first.id }?.openWork == 0)
    await f.h.stop()
  }

  @Test func startUpClosesOpenWorkLeftBehind() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    let turn = try await open(f, f.thread, id: "a1")
    let paths = f.h.coordinator.paths
    #expect(try f.h.coordinator.database.turn(id: turn.id)?.openWork == 1)
    await f.h.stop()
    // The close below is start()'s only if it is stamped after the restart began; one made while the
    // first coordinator shut down would carry an earlier stamp.
    let restartedAt = Date()
    let back = try await Harness.start(paths: paths)
    for _ in 0..<600 {
      if try back.coordinator.database.turn(id: turn.id)?.openWork == 0 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try back.coordinator.database.turn(id: turn.id)?.openWork == 0)
    let item = try #require(
      try back.coordinator.database.displayItems(threadId: f.thread.id).first { $0.nativeItemId == "a1" })
    #expect(item.payload["status"]?.stringValue == "stopped")
    let ended = try #require(item.payload["endedAt"]?.stringValue.flatMap(Timestamp.date(from:)))
    #expect(ended >= restartedAt.addingTimeInterval(-0.001))
    await back.stop()
  }

  /// The ids of a thread's agent items that are open now, as `start()` takes them.
  func openItems(_ f: RuntimeTurnTests.Fixture, _ thread: ConversationThread) throws -> [String: String] {
    var ids: [String: String] = [:]
    for item in try f.h.coordinator.database.displayItems(threadId: thread.id)
    where item.payload["agent"]?.boolValue == true && item.payload["status"]?.stringValue == "inProgress" {
      ids[item.nativeItemId ?? ""] = item.id
    }
    return ids
  }

  @Test func startUpDoesNotCloseAnAgentOpenedAfterIt() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    _ = try await open(f, f.thread, id: "a1")
    let taken = try openItems(f, f.thread)
    _ = try await open(f, f.thread, id: "a2")
    let before = await completions(f)
    try await f.h.coordinator.sessions.closeOpenWork(
      threadId: f.thread.id, reason: "coordinator_started", items: [try #require(taken["a1"])])
    _ = await f.h.events.until { $0.filter { $0.kind == .toolCompleted }.count > before }
    let items = try await f.h.read(f.thread).items
    #expect(items.first { $0.nativeItemId == "a1" }?.payload["status"]?.stringValue == "stopped")
    let later = try #require(items.first { $0.nativeItemId == "a2" })
    #expect(later.payload["status"]?.stringValue == "inProgress")
    #expect(later.payload["endedAt"] == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try await f.turns().last?.openWork == 1)
    await f.h.stop()
  }

  /// The list a close works from is a snapshot; `a2` ends for real after it was taken, so when the
  /// close reaches it the stored row is no longer open.
  @Test func aCloseDoesNotOverwriteAnAgentThatEndedMeanwhile() async throws {
    let f = try await RuntimeTurnTests.Fixture.make()
    let turn = try await open(f, f.thread, id: "a1")
    _ = try await open(f, f.thread, id: "a2")
    let taken = try openItems(f, f.thread)
    #expect(taken.count == 2)
    let native = try #require(turn.nativeTurnId)
    await f.send(agent(.toolCompleted, f.connection, f.thread, id: "a2", turn: native, status: "completed"))
    let ended = try #require(try await f.h.read(f.thread).items.first { $0.nativeItemId == "a2" })
    let before = await completions(f)
    try await f.h.coordinator.sessions.closeOpenWork(
      threadId: f.thread.id, reason: "runtime_exited", items: Array(taken.values))
    _ = await f.h.events.until { $0.filter { $0.kind == .toolCompleted }.count > before }
    try await Task.sleep(for: .milliseconds(300))
    let items = try await f.h.read(f.thread).items
    let kept = try #require(items.first { $0.nativeItemId == "a2" })
    #expect(kept.payload == ended.payload)
    #expect(kept.payload["status"]?.stringValue == "completed")
    #expect(items.first { $0.nativeItemId == "a1" }?.payload["status"]?.stringValue == "stopped")
    let published = await f.h.events.events.filter {
      $0.event.kind == .toolCompleted
        && $0.event.payload["displayItem"]?["payload"]?["status"]?.stringValue == "stopped"
    }
    #expect(published.count == 1)
    await f.h.stop()
  }
}
