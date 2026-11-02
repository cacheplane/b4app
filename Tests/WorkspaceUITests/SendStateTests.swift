import Foundation
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// MARK: - A clock tests move by hand

/// A clock and a calendar date that tests move together by hand: the model's `clock` sleeps on it and
/// its `now` reads `date`, so "30 s after the tap" is exact. Sleepers wake in deadline order when
/// `advance` passes their deadline; a cancelled sleeper leaves at once. (The sleeping part is a copy
/// of `WorkspaceSyncTests`' `ManualClock`.)
final class TestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
  }

  private struct Sleeper {
    var id: Int
    var deadline: Instant
    var continuation: CheckedContinuation<Void, Error>
  }

  /// A whole second, so a `lastSeenAt` rendered with milliseconds reads back exactly.
  static let start = Date(timeIntervalSince1970: 1_793_000_000)

  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [Sleeper] = []
  private var nextID = 0
  private var cancelledEarly: Set<Int> = []

  var now: Instant { lock.withLock { current } }
  var minimumResolution: Duration { .nanoseconds(1) }

  /// The calendar time matching `now`.
  var date: Date {
    let offset = lock.withLock { current.offset }
    let parts = offset.components
    return Self.start.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
  }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let outcome = lock.withLock { () -> Result<Void, any Error>? in
          if cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
          if deadline <= current { return .success(()) }
          sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return nil
        }
        if let outcome { continuation.resume(with: outcome) }
      }
    } onCancel: {
      let cancelled = lock.withLock { () -> Sleeper? in
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
          cancelledEarly.insert(id)
          return nil
        }
        return sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due = lock.withLock { () -> [Sleeper] in
      current = current.advanced(by: duration)
      let due = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
      sleepers.removeAll { $0.deadline <= current }
      return due
    }
    for sleeper in due { sleeper.continuation.resume() }
    ConditionNudge.post()
  }
}

// MARK: - The phone's fixture

/// One Mac (`mac-1`, "Brian's MacBook Pro") owning thread `t1` on connection `c1`.
enum PhoneFixture {
  static let macName = "Brian's MacBook Pro"

  static func at(_ seconds: Double) -> String {
    Timestamp.string(from: TestClock.start.addingTimeInterval(seconds))
  }

  static func thread(
    _ id: String = "t1", owner: String? = "mac-1", at seconds: Double = -600
  )
    -> ConversationThread
  {
    ConversationThread(
      id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, createdAt: at(seconds - 60),
      updatedAt: at(seconds), readTurnId: nil,
      activity: ThreadActivity(
        latestTurnId: nil, latestTurnStatus: nil, latestTurnOutcome: nil, pendingRequests: 0,
        lastActivityAt: at(seconds)),
      ownerDeviceName: owner == nil ? nil : macName, ownerDeviceId: owner)
  }

  static let connection = Connection(
    id: "c1", kind: .codex, label: "Codex", target: "", ownerDeviceId: "mac-1", status: .ready)

  /// A project of `mac-1` with one folder, for the tests that start a thread.
  static let project = Project(
    id: "p1", name: "Work", folders: [ProjectFolder(id: "f1", projectId: "p1", path: "/work")],
    ownerDeviceId: "mac-1")

  static func turn(
    _ id: String, in threadId: String = "t1", operationId: String, status: TurnStatus = .running
  ) -> Turn {
    Turn(
      id: id, threadId: threadId, operationId: operationId, nativeTurnId: "n-\(id)", status: status,
      submission: .acknowledged, outcome: status == .terminal ? .completed : nil, createdAt: at(0),
      updatedAt: at(0))
  }

  static func presence(
    _ deviceId: String = "mac-1", name: String = macName, online: Bool, lastSeen: Double? = nil,
    link: HubLinkStatus.State = .connected
  ) -> AdapterEvent {
    try! AdapterEvent.hostPresence(
      HostPresence(deviceId: deviceId, name: name, online: online, lastSeenAt: lastSeen.map(at)),
      link: link)
  }

  static func link(_ link: HubLinkStatus.State) -> AdapterEvent {
    try! AdapterEvent.hostPresence(nil, link: link)
  }

  static func turnEvent(_ kind: EventKind, _ turn: Turn) -> AdapterEvent {
    AdapterEvent(
      kind: kind, connectionId: "c1", threadId: turn.threadId, turnId: turn.id,
      payload: ["turn": try! JSONValue(encoding: turn)])
  }

  static func sent(_ turn: Turn) -> ScriptedTransport.Reply {
    .result(try! JSONValue(encoding: TurnSend.Result(turn: turn)))
  }

  static func lookup(_ state: TurnLookup.State, _ turn: Turn? = nil) -> ScriptedTransport.Reply {
    .result(try! JSONValue(encoding: TurnLookup.Result(state: state, turn: turn)))
  }

  /// The relay's own "not confirmed" (`details.local`), with why.
  static func notConfirmed(_ reason: String) -> ScriptedTransport.Reply {
    .failure(
      WorkspaceError(
        .relayTimeout, "Not confirmed: your Mac may not have received this.",
        details: ["reason": .string(reason), "local": true]))
  }

  /// A transport over the fixture, with `t1` readable (`turns` as given).
  static func transport(
    threads: [ConversationThread] = [thread()], turns: [Turn] = [], requests: [RuntimeRequest] = []
  ) -> ScriptedTransport {
    let transport = ScriptedTransport()
    transport.set(connections: [connection], threads: threads)
    for thread in threads {
      transport.setRead(
        ThreadRead.Result(
          thread: thread, turns: turns.filter { $0.threadId == thread.id }, items: [],
          requests: requests.filter { $0.threadId == thread.id }))
    }
    return transport
  }

  /// The phone's model (the host owns the account) on the test clock, connected, with presence saying
  /// the Mac is online unless `online` is nil, and `open` opened.
  @MainActor
  static func model(
    _ transport: ScriptedTransport, clock: TestClock, online: Bool? = true, open: String? = "t1"
  ) async throws -> WorkspaceModel {
    let model = WorkspaceModel(transportProvider: { transport })
    model.accountSource = .host
    model.clock = clock
    model.now = { clock.date }
    model.isDetailOnScreen = true
    model.connect()
    try #require(await model.settledLink() == .ready)
    if let online {
      transport.emit(presence(online: online, lastSeen: online ? nil : 0))
      try await waitUntil("presence") { model.hostPresence["mac-1"] != nil }
    }
    if let open {
      await model.openThread(id: open)
      try #require(model.detail?.thread.id == open)
    }
    return model
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct SendStateTests {
  private func startedReply(_ thread: ConversationThread, _ send: PendingSend) -> ScriptedTransport.Reply {
    .result(
      try! JSONValue(
        encoding: ThreadStart.Result(
          thread: thread, turn: PhoneFixture.turn("turn-1", in: thread.id, operationId: send.id))))
  }

  private func send(_ model: WorkspaceModel, _ text: String = "hello") -> Task<Void, Never> {
    model.composerText = text
    return Task { await model.send() }
  }

  @Test func acceptedClearsTheComposer() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [.hold])
    let model = try await PhoneFixture.model(transport, clock: clock)
    let task = send(model)
    try await waitUntil("sending") { transport.heldCount(.turnSend) == 1 }
    let pending = try #require(model.pendingSends["t1"])
    #expect(model.composerText == "hello")
    #expect(model.pendingMessage(for: "t1")?.text == "hello")
    #expect(model.sendStatus(for: "t1") == "Sending…")
    #expect(model.sendBlockedReason(for: PhoneFixture.thread()) != nil)
    // The send's id is its operationId, so a resend lands on the same turn.
    #expect(transport.recorded(.turnSend).map(\.operationId) == [pending.id])

    try #require(
      transport.release(
        .turnSend, with: PhoneFixture.sent(PhoneFixture.turn("turn-9", operationId: pending.id))))
    await task.value
    #expect(model.pendingSends["t1"]?.state == .accepted(turnId: "turn-9"))
    #expect(model.composerText.isEmpty)
    #expect(model.sendStatus(for: "t1") == nil)
    // The bubble stays until the turn's own user message reaches the transcript.
    #expect(model.pendingMessage(for: "t1") != nil)
    let item = DisplayItem(
      id: "u9", threadId: "t1", turnId: "turn-9", role: .user, type: "userMessage",
      payload: ["text": "hello"],
      sequence: 1, provenance: .live, createdAt: PhoneFixture.at(0))
    transport.emit(
      AdapterEvent(
        kind: .messageCompleted, connectionId: "c1", threadId: "t1", turnId: "turn-9",
        payload: ["displayItem": try JSONValue(encoding: item)]))
    try await waitUntil("the turn's message") { model.pendingMessage(for: "t1") == nil }
    await model.disconnect()
  }

  @Test func refusedKeepsTheDraftAndRemovesTheMessage() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    let offline = WorkspaceError(
      .deviceOffline, "Brian's MacBook Pro is offline.",
      details: [
        "deviceId": "mac-1", "deviceName": .string(PhoneFixture.macName),
        "lastSeenAt": .string(PhoneFixture.at(-30)),
      ])
    let limited = WorkspaceError(
      .rateLimited, "Too many messages; try again in a few seconds.", details: ["retryAfterMs": 4000])
    transport.script(.turnSend, [.failure(offline), .failure(limited)])
    let model = try await PhoneFixture.model(transport, clock: clock)

    await send(model).value
    #expect(model.pendingSends["t1"]?.state == .refused(offline))
    #expect(model.composerText == "hello")
    #expect(model.pendingMessage(for: "t1") == nil)
    let seen = HostNoticeMessage.lastSeen(Timestamp.date(from: PhoneFixture.at(-30))!, now: clock.date)
    #expect(model.sendStatus(for: "t1") == "\(PhoneFixture.macName) is offline · last seen \(seen)")
    // Refused means nothing was made: Send is available again, and a new tap is a new send.
    #expect(model.sendBlockedReason(for: PhoneFixture.thread()) == nil)

    await send(model).value
    #expect(model.pendingSends["t1"]?.state == .refused(limited))
    #expect(model.sendStatus(for: "t1") == limited.message)
    let ids = transport.recorded(.turnSend).map(\.operationId)
    #expect(ids.count == 2 && ids[0] != ids[1])
    await model.disconnect()
  }

  @Test func errorWithTurnIdIsAccepted() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    let failed = WorkspaceError(.internalError, "Your Mac could not run this.", details: ["turnId": "turn-9"])
    let blocked = WorkspaceError(
      .protocolInvalid, "A turn is still running on this thread.",
      details: ["reason": "turn_active", "blockingTurnId": "turn-1"])
    transport.script(.turnSend, [.failure(failed), .failure(blocked)])
    let model = try await PhoneFixture.model(transport, clock: clock)

    await send(model).value
    #expect(model.pendingSends["t1"]?.state == .acceptedWithError(turnId: "turn-9", failed))
    #expect(model.composerText.isEmpty)

    // A refusal before the turn existed names the turn in the way, not this send's: refused.
    await send(model, "again").value
    #expect(model.pendingSends["t1"]?.state == .refused(blocked))
    #expect(model.composerText == "again")
    await model.disconnect()
  }

  @Test func relayTimeoutIsNotConfirmed() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    // The hub's own relay_timeout: the Mac had the command and said nothing in 30 s.
    transport.script(
      .turnSend, [.failure(WorkspaceError(.relayTimeout, "Your Mac did not answer in time."))])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    #expect(model.pendingSends["t1"]?.state == .notConfirmed)
    #expect(model.composerText == "hello")
    #expect(model.pendingMessage(for: "t1")?.text == "hello")
    #expect(model.sendStatus(for: "t1") == "Not confirmed: your Mac may not have received this.")
    // No second send while the first may have reached the Mac.
    #expect(model.sendBlockedReason(for: PhoneFixture.thread()) != nil)
    await model.send()
    #expect(transport.recorded(.turnSend).count == 1)
    // A link that comes back does not resend a command the hub delivered.
    transport.emit(PhoneFixture.link(.connecting))
    transport.emit(PhoneFixture.link(.connected))
    transport.emit(PhoneFixture.presence(online: true))
    try await waitUntil("link back") {
      model.hubLinkPhase == .connected && model.hostPresence["mac-1"] != nil
    }
    #expect(transport.recorded(.turnSend).count == 1)
    await model.disconnect()
  }

  @Test func backgroundedSendRetriesOnlyWithinThirtySeconds() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport(threads: [PhoneFixture.thread("t1"), PhoneFixture.thread("t2")])
    transport.script(.turnSend, [PhoneFixture.notConfirmed("link_dropped")])
    let model = try await PhoneFixture.model(transport, clock: clock)

    // Within 30 s: the app went to the background mid-send, the link closed, and it is back at 29 s.
    await send(model).value
    let first = try #require(model.pendingSends["t1"])
    #expect(first.state == .notConfirmed)
    transport.emit(PhoneFixture.link(.offline))
    try await waitUntil("link down") { model.hubLinkPhase == .offline }
    clock.advance(by: .seconds(29))
    transport.script(.turnSend, [PhoneFixture.sent(PhoneFixture.turn("turn-9", operationId: first.id))])
    transport.emit(PhoneFixture.link(.connected))
    try await waitUntil("resent") { model.pendingSends["t1"]?.state == .accepted(turnId: "turn-9") }
    #expect(transport.recorded(.turnSend).map(\.operationId) == [first.id, first.id])

    // After 30 s: the link returns too late, nothing is resent, and only `turn.lookup` settles it.
    await model.openThread(id: "t2")
    transport.script(.turnSend, [PhoneFixture.notConfirmed("link_dropped")])
    await send(model).value
    let second = try #require(model.pendingSends["t2"])
    #expect(second.state == .notConfirmed)
    transport.emit(PhoneFixture.link(.offline))
    try await waitUntil("link down") { model.hubLinkPhase == .offline }
    clock.advance(by: .seconds(31))
    transport.script(
      .turnLookup,
      [PhoneFixture.lookup(.found, PhoneFixture.turn("turn-10", in: "t2", operationId: second.id))])
    transport.emit(PhoneFixture.link(.connected))
    transport.emit(PhoneFixture.presence(online: true))
    try await waitUntil("looked up") { model.pendingSends["t2"]?.state == .accepted(turnId: "turn-10") }
    #expect(transport.recorded(.turnSend).count == 3)
    #expect(transport.recorded(.turnLookup).map(\.params["operationId"]) == [.string(second.id)])
    await model.disconnect()
  }

  @Test func lookupFoundAccepts() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("timeout")])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    let pending = try #require(model.pendingSends["t1"])
    #expect(pending.state == .notConfirmed)

    // Not before 30 s after the tap: the command's deadline must certainly have passed.
    clock.advance(by: .seconds(29))
    await Task.yield()
    #expect(transport.recorded(.turnLookup).isEmpty)
    transport.script(
      .turnLookup, [PhoneFixture.lookup(.found, PhoneFixture.turn("turn-9", operationId: pending.id))])
    clock.advance(by: .seconds(1))
    try await waitUntil("found") { model.pendingSends["t1"]?.state == .accepted(turnId: "turn-9") }
    let call = try #require(transport.recorded(.turnLookup).first)
    #expect(call.params["operationId"] == .string(pending.id))
    #expect(call.params["threadId"] == "t1")
    #expect(model.composerText.isEmpty)
    await model.disconnect()
  }

  @Test func lookupInFlightAsksAgainAfterFiveSeconds() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("timeout")])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    let pending = try #require(model.pendingSends["t1"])
    transport.script(
      .turnLookup,
      [
        PhoneFixture.lookup(.inFlight),
        PhoneFixture.lookup(.found, PhoneFixture.turn("turn-9", operationId: pending.id)),
      ])
    clock.advance(by: .seconds(30))
    try await waitUntil("first lookup") { transport.recorded(.turnLookup).count == 1 }
    try await waitUntil("answered") { model.pendingSends["t1"]?.lookupInFlight == false }
    #expect(model.pendingSends["t1"]?.state == .notConfirmed)
    clock.advance(by: .milliseconds(4_999))
    await Task.yield()
    #expect(transport.recorded(.turnLookup).count == 1)
    clock.advance(by: .milliseconds(1))
    try await waitUntil("found") { model.pendingSends["t1"]?.state == .accepted(turnId: "turn-9") }
    #expect(transport.recorded(.turnLookup).count == 2)
    await model.disconnect()
  }

  @Test func lookupNoneIsDidNotReachAndKeepsTheDraft() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("timeout")])
    transport.script(.turnLookup, [PhoneFixture.lookup(.none)])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    clock.advance(by: .seconds(30))
    try await waitUntil("did not reach") { model.pendingSends["t1"]?.state == .didNotReach }
    #expect(model.composerText == "hello")
    #expect(model.sendStatus(for: "t1") == "Didn't reach your Mac")
    #expect(model.sendBlockedReason(for: PhoneFixture.thread()) == nil)
    await model.disconnect()
  }

  @Test func lookupWaitsForTheMacAndTheLink() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("timeout")])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    transport.emit(PhoneFixture.presence(online: false, lastSeen: 1))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    clock.advance(by: .seconds(40))
    await Task.yield()
    // While the Mac is unreachable the send stays not confirmed; nothing is asked.
    #expect(transport.recorded(.turnLookup).isEmpty)
    #expect(model.pendingSends["t1"]?.state == .notConfirmed)
    transport.script(.turnLookup, [PhoneFixture.lookup(.none)])
    transport.emit(PhoneFixture.presence(online: true))
    try await waitUntil("asked once back") { model.pendingSends["t1"]?.state == .didNotReach }
    await model.disconnect()
  }

  @Test func lookupWaitsForALateRetrysDeadline() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("link_dropped")])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    transport.emit(PhoneFixture.link(.offline))
    try await waitUntil("link down") { model.hubLinkPhase == .offline }

    // The retry goes out at 29 s (its hub deadline is about 39 s) and is lost with the link too.
    clock.advance(by: .seconds(29))
    transport.script(.turnSend, [PhoneFixture.notConfirmed("link_dropped")])
    transport.emit(PhoneFixture.link(.connected))
    try await waitUntil("retried") {
      model.pendingSends["t1"]?.attempts == 2 && model.pendingSends["t1"]?.inFlight == false
    }
    #expect(model.pendingSends["t1"]?.state == .notConfirmed)
    transport.emit(PhoneFixture.link(.offline))
    try await waitUntil("link down") { model.hubLinkPhase == .offline }

    // Back at 31 s: too late to resend, and too early to ask, since the retry may still run.
    clock.advance(by: .seconds(2))
    transport.script(.turnLookup, [PhoneFixture.lookup(.none)])
    transport.emit(PhoneFixture.link(.connected))
    transport.emit(PhoneFixture.presence(online: true))
    try await waitUntil("presence") { model.hostPhase(deviceId: "mac-1") == .connected }
    // Decided at once, not on a timer: no lookup started, and none is due before 41 s.
    #expect(model.pendingSends["t1"]?.lookupInFlight == false)
    #expect(model.pendingSends["t1"]?.nextLookupAt == TestClock.start.addingTimeInterval(41))
    clock.advance(by: .milliseconds(9_999))
    await Task.yield()
    #expect(transport.recorded(.turnLookup).isEmpty)
    #expect(transport.recorded(.turnSend).count == 2)
    // At 41 s (the retry's 29 s plus the 10 s deadline and a 2 s margin) the Mac is asked.
    clock.advance(by: .milliseconds(1))
    try await waitUntil("asked") { model.pendingSends["t1"]?.state == .didNotReach }
    #expect(transport.recorded(.turnLookup).count == 1)
    await model.disconnect()
  }

  @Test func lookupWithoutAnAnswerBacksOff() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("timeout")])
    let unanswered = ScriptedTransport.Reply.failure(
      WorkspaceError(.relayTimeout, "Not confirmed: your Mac may not have received this."))
    // No answer, no answer, `found` without its turn (still unsettled), no answer, then `none`.
    transport.script(
      .turnLookup,
      [unanswered, unanswered, PhoneFixture.lookup(.found), unanswered, PhoneFixture.lookup(.none)])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value

    func settled(_ count: Int) async throws {
      try await waitUntil("lookup \(count)") {
        transport.recorded(.turnLookup).count == count && model.pendingSends["t1"]?.lookupInFlight == false
      }
    }
    clock.advance(by: .seconds(30))
    try await settled(1)
    // 5, 10, 20, then 30 s between lookups that got no usable answer.
    for wait in [5, 10, 20, 30] {
      #expect(model.pendingSends["t1"]?.state == .notConfirmed)
      clock.advance(by: .milliseconds(wait * 1000 - 1))
      await Task.yield()
      let before = transport.recorded(.turnLookup).count
      clock.advance(by: .milliseconds(1))
      try await settled(before + 1)
    }
    #expect(model.pendingSends["t1"]?.state == .didNotReach)
    #expect(transport.recorded(.turnLookup).count == 5)
    await model.disconnect()
  }

  @Test func disconnectEndsTheRelayState() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [PhoneFixture.notConfirmed("timeout")])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    transport.emit(PhoneFixture.presence(online: false, lastSeen: 0))
    try await waitUntil("offline") { model.hostPresence["mac-1"]?.online == false }
    #expect(model.pendingSends["t1"]?.state == .notConfirmed)
    #expect(model.sendTimer != nil && model.phaseTimer != nil)

    await model.disconnect()
    #expect(model.sendTimer == nil && model.phaseTimer == nil)
    #expect(model.pendingSends.isEmpty && model.stopStates.isEmpty && model.answerStates.isEmpty)
    #expect(model.hostPresence.isEmpty && model.hubLinkPhase == nil)
    clock.advance(by: .seconds(120))
    await Task.yield()
    #expect(transport.recorded(.turnLookup).isEmpty)
  }

  @Test func syncedTurnResolvesNotConfirmed() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.script(.turnSend, [.failure(WorkspaceError(.relayTimeout, "Your Mac did not answer in time."))])
    let model = try await PhoneFixture.model(transport, clock: clock)
    await send(model).value
    let pending = try #require(model.pendingSends["t1"])
    #expect(pending.state == .notConfirmed)
    transport.emit(
      PhoneFixture.turnEvent(.turnStateChanged, PhoneFixture.turn("turn-9", operationId: pending.id)))
    try await waitUntil("accepted from sync") {
      model.pendingSends["t1"]?.state == .accepted(turnId: "turn-9")
    }
    #expect(model.composerText.isEmpty)
    clock.advance(by: .seconds(60))
    await Task.yield()
    #expect(transport.recorded(.turnLookup).isEmpty)
    await model.disconnect()
  }

  @Test func stopWaitsNinetySecondsThenNotConfirmed() async throws {
    // The client gives up only after the relay's own 90 s answer, never before it.
    #expect(WorkspaceModel.relayTimeout(for: .turnInterrupt) >= .seconds(95))
    #expect(WorkspaceModel.relayTimeout(for: .requestRespond) >= .seconds(95))
    for method in [WorkspaceProtocol.Method.turnSend, .threadStart, .turnLookup] {
      #expect(WorkspaceModel.relayTimeout(for: method) >= .seconds(35))
    }
    let clock = TestClock()
    let running = PhoneFixture.turn("turn-1", operationId: "op-1")
    let transport = PhoneFixture.transport(turns: [running])
    transport.script(.turnInterrupt, [.hold])
    let model = try await PhoneFixture.model(transport, clock: clock)
    let task = Task { await model.stop() }
    try await waitUntil("waiting") { transport.heldCount(.turnInterrupt) == 1 }
    #expect(model.stopStates["t1"]?.label == "Waiting for your Mac…")
    #expect(!model.canStop(PhoneFixture.thread()))
    #expect(!model.busy)
    try #require(
      transport.release(
        .turnInterrupt,
        with: .failure(
          WorkspaceError(
            .relayTimeout, "Not confirmed: your Mac may not have received this.",
            details: ["reason": "timeout", "local": true]))))
    await task.value
    #expect(model.stopStates["t1"] == .notConfirmed)
    #expect(model.stopStates["t1"]?.label == "Not confirmed: your Mac may not have received this.")
    // Not retried: sync shows whether it took effect, and Stop is there again.
    transport.emit(PhoneFixture.link(.connected))
    try await waitUntil("link event") { model.hubLinkPhase == .connected }
    #expect(transport.recorded(.turnInterrupt).count == 1)
    #expect(model.canStop(PhoneFixture.thread()))
    await model.disconnect()
  }

  @Test func alreadyAnsweredCopy() async throws {
    let clock = TestClock()
    let request = RuntimeRequest(
      id: "r1", nativeRequestId: "n-r1", threadId: "t1", adapterGeneration: 1, kind: .commandApproval,
      state: .pending, payload: ["answerable": true], createdAt: PhoneFixture.at(0),
      updatedAt: PhoneFixture.at(0))
    let transport = PhoneFixture.transport(
      turns: [PhoneFixture.turn("turn-1", operationId: "op-1", status: .waitingForUser)], requests: [request])
    transport.script(
      .requestRespond,
      [.hold, .failure(WorkspaceError(.staleRuntimeRequest, "This request was already answered."))])
    let model = try await PhoneFixture.model(transport, clock: clock)
    let task = Task { await model.respond(requestId: "r1", decision: .allowOnce) }
    try await waitUntil("waiting") { transport.heldCount(.requestRespond) == 1 }
    #expect(model.answerStates["r1"]?.label == "Waiting for your Mac…")
    #expect(!model.canAnswer(request))
    try #require(
      transport.release(
        .requestRespond, with: .result(try JSONValue(encoding: RequestRespond.Result(request: request)))))
    await task.value
    #expect(model.answerStates["r1"] == nil)

    await model.respond(requestId: "r1", decision: .deny)
    #expect(model.answerStates["r1"] == .alreadyAnswered)
    #expect(model.answerStates["r1"]?.label == "Already answered")
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  /// The spec: a started thread whose row never arrives loses its placeholder after 2 minutes "and the
  /// thread shows 'Not confirmed'" — never the transport's raw not-found text.
  @Test func aStartedThreadWhosePlaceholderExpiredShowsNotConfirmed() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.set(projects: [PhoneFixture.project])
    let model = try await PhoneFixture.model(transport, clock: clock, open: nil)
    transport.script(.threadStart, [.hold])
    let task = Task {
      await model.startThread(projectId: "p1", connectionId: "c1", folder: "/work", text: "Start here")
    }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    let send = try #require(model.pendingSends.values.first { $0.text == "Start here" })
    let thread = PhoneFixture.thread(send.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    try #require(transport.release(.threadStart, with: startedReply(thread, send)))
    #expect(await task.value?.state == .accepted(turnId: "turn-1"))

    // Two minutes on, the placeholder is gone and the mirror has no row.
    transport.script(
      .threadRead, [.failure(WorkspaceError(.notFound, "Thread \(send.threadId) does not exist."))])
    await model.openThread(id: send.threadId)
    #expect(model.lastError == RelayCopy.notConfirmed)
    #expect(model.pendingSends[send.threadId]?.state == .notConfirmed)
    #expect(model.sendStatus(for: send.threadId) == RelayCopy.notConfirmed)
    #expect(model.threads.contains { $0.id == send.threadId })
    await model.disconnect()
  }

  @Test func threadStartIsTrackedOnItsNewThread() async throws {
    let clock = TestClock()
    let transport = PhoneFixture.transport()
    transport.set(projects: [PhoneFixture.project])
    transport.script(.threadStart, [PhoneFixture.notConfirmed("link_dropped")])
    let model = try await PhoneFixture.model(transport, clock: clock, open: nil)
    let pending = try #require(
      await model.startThread(projectId: "p1", connectionId: "c1", folder: "/work", text: "Start here"))
    #expect(pending.state == .notConfirmed)
    #expect(pending.start?.threadId == pending.threadId)
    #expect(model.pendingSends[pending.threadId]?.id == pending.id)
    let call = try #require(transport.recorded(.threadStart).first)
    #expect(call.operationId == pending.id)
    #expect(call.params["threadId"] == .string(pending.threadId))
    #expect(call.params["text"] == "Start here")

    // A retry within 30 s starts the same thread with the same id; accepted, the thread is listed.
    let started = PhoneFixture.thread(pending.threadId)
    transport.setRead(ThreadRead.Result(thread: started, turns: [], items: [], requests: []))
    transport.script(.threadStart, [startedReply(started, pending)])
    transport.emit(PhoneFixture.link(.connecting))
    transport.emit(PhoneFixture.link(.connected))
    try await waitUntil("started") {
      model.pendingSends[pending.threadId]?.state == .accepted(turnId: "turn-1")
    }
    #expect(transport.recorded(.threadStart).map(\.operationId) == [pending.id, pending.id])
    #expect(model.threads.contains { $0.id == pending.threadId })

    // Accepted at once, the new thread opens.
    transport.script(.threadStart, [.hold])
    let task = Task {
      await model.startThread(projectId: "p1", connectionId: "c1", folder: nil, text: "Next")
    }
    try await waitUntil("starting") { transport.heldCount(.threadStart) == 1 }
    let second = try #require(model.pendingSends.values.first { $0.text == "Next" })
    #expect(second.state == .sending)
    let thread = PhoneFixture.thread(second.threadId)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    try #require(transport.release(.threadStart, with: startedReply(thread, second)))
    #expect(await task.value?.state == .accepted(turnId: "turn-1"))
    #expect(model.detail?.thread.id == second.threadId)
    #expect(model.selectedThreadId == second.threadId)
    await model.disconnect()
  }
}
