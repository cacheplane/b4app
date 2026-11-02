import Foundation
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

/// A clock tests move by hand (a copy of `WorkspaceSyncTests`' `ManualClock`). Sleepers wake in
/// deadline order when `advance` passes their deadline; a cancelled sleeper leaves at once.
final class ManualClock: Clock, @unchecked Sendable {
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

  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [Sleeper] = []
  private var nextID = 0
  private var cancelledEarly: Set<Int> = []

  var now: Instant { lock.withLock { current } }
  var minimumResolution: Duration { .nanoseconds(1) }
  var sleeperCount: Int { lock.withLock { sleepers.count } }

  /// Whether something sleeps until exactly `duration` from now.
  func hasSleeper(dueIn duration: Duration) -> Bool {
    lock.withLock { sleepers.contains { $0.deadline == current.advanced(by: duration) } }
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
  }
}

/// A monotonic "now" tests move by hand, for the transport's placeholder lifetime.
final class ManualNow: Sendable {
  private let base = ContinuousClock.now
  private let offset = Mutex(Duration.zero)
  func advance(by duration: Duration) { offset.withLock { $0 += duration } }
  var instant: ContinuousClock.Instant { base.advanced(by: offset.withLock { $0 }) }
  var now: @Sendable () -> ContinuousClock.Instant { { self.instant } }
}

/// Polls until `condition` holds; fails the test after `seconds` of real time.
func waitUntil(
  seconds: Double = 15, _ comment: Comment = "condition", sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @Sendable () async -> Bool
) async {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(comment)", sourceLocation: sourceLocation)
}

func relayHello(hubTime: Date = Date()) -> RelayMessage {
  .hello(
    protocol: 1, minClientProtocol: 1, deviceId: "phone-1", role: .client, heartbeatSeconds: 10,
    hubTime: Timestamp.string(from: hubTime))
}

/// A `MirrorRelay` on a fake hub connection and a manual clock, with jitter fixed at 1.0.
struct RelayHarness {
  let connection = FakeHubLinkConnection()
  let clock = ManualClock()
  let relay: MirrorRelay

  init() {
    relay = MirrorRelay(
      url: URL(string: "https://hub.example.com")!, token: { "tok" }, connection: connection, clock: clock,
      jitter: { 1.0 })
  }

  /// Starts the relay and answers its next open with a `hello`, returning the hub's side.
  func connect(hubTime: Date = Date()) async -> FakeHubLinkSocket {
    await relay.start()
    return await answerNextOpen(hubTime: hubTime)
  }

  func answerNextOpen(hubTime: Date = Date()) async -> FakeHubLinkSocket {
    let socket = await connection.nextSocket()
    socket.deliver(relayHello(hubTime: hubTime))
    await waitUntil("connected") { await relay.isConnected }
    return socket
  }

  /// Moves the clock on by `duration` in 10 s steps, keeping the link alive with a frame before each
  /// step (handled before the clock moves), so the 30 s silence timer never fires.
  func idle(_ socket: FakeHubLinkSocket, for duration: Duration) async {
    var left = duration
    var step = 0
    while left > .zero {
      step += 1
      let marker = RelayHostPresence(deviceId: "idle-\(step)", name: "", online: true)
      socket.deliver(.presence(hosts: [marker]))
      await waitUntil("the idle frame") { await relay.hosts == [marker] }
      let move = min(left, .seconds(10))
      clock.advance(by: move)
      left -= move
    }
  }

  /// The commands the device has sent on `socket`.
  static func commands(_ socket: FakeHubLinkSocket) -> [RelayMessage] {
    socket.sentMessages.filter { if case .command = $0 { true } else { false } }
  }

  /// Waits for the next command the device sends, skipping every other frame.
  static func nextCommand(_ socket: FakeHubLinkSocket) async throws -> RelayMessage {
    while true {
      let frame = try await socket.nextSent()
      if case .command = frame { return frame }
    }
  }

  /// Waits for the next frame the device sends that is not a `ping`.
  static func nextFrame(_ socket: FakeHubLinkSocket) async throws -> RelayMessage {
    while true {
      let frame = try await socket.nextSent()
      if frame != .ping { return frame }
    }
  }
}

/// A turn as the Mac's reply carries it.
func relayTurn(
  _ id: String, threadId: String = "thread-1", operationId: String, status: TurnStatus = .running
)
  -> Turn
{
  Turn(
    id: id, threadId: threadId, operationId: operationId, status: status, submission: .acknowledged,
    createdAt: "2026-11-01T10:00:00.000Z", updatedAt: "2026-11-01T10:00:01.000Z")
}

@Suite(.timeLimit(.minutes(1)))
struct MirrorRelayTests {
  @Test func sendGoesThroughTheRelayWithTheOperationId() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    let h = RelayHarness()
    let socket = await h.connect()
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay))
    _ = try await client.ready()

    async let sent = client.request(
      TurnSend.self, .init(threadId: "thread-1", text: "Ship it"),
      options: RequestOptions(operationId: "op-7"))
    let frame = try await RelayHarness.nextFrame(socket)
    #expect(
      frame
        == .command(
          id: "op-7", method: .turnSend, params: ["threadId": "thread-1", "text": "Ship it"]))
    let turn = relayTurn("turn-9", operationId: "op-7")
    socket.deliver(.reply(id: "op-7", result: ["turn": try JSONValue(encoding: turn)]))
    #expect(try await sent.turn == turn)

    // A Mac error keeps its code and details, so the phone can tell an accepted turn from a refusal.
    let refused = Task {
      try await client.request(
        TurnSend.self, .init(threadId: "thread-1", text: "Again"),
        options: RequestOptions(operationId: "op-8"))
    }
    _ = try await RelayHarness.nextFrame(socket)
    socket.deliver(
      .reply(
        id: "op-8",
        error: RelayWireError(
          .deviceOffline, "Brian's Mac is offline", details: ["deviceName": "Brian's Mac"])))
    let error = await #expect(throws: WorkspaceError.self) { try await refused.value }
    #expect(error?.code == .deviceOffline && error?.details?["deviceName"] == "Brian's Mac")

    // Stop and answer get an id of their own; lookup goes through too.
    async let stopped = client.request(
      TurnInterrupt.self, .init(threadId: "thread-1"), options: RequestOptions(operationId: "op-9"))
    guard
      case .command(let stopId, .turnInterrupt, let params, nil, nil) = try await RelayHarness.nextFrame(
        socket)
    else {
      Issue.record("expected a turn.interrupt command")
      return
    }
    #expect(stopId != "op-9" && !stopId.isEmpty && params == ["threadId": "thread-1"])
    socket.deliver(.reply(id: stopId, result: ["turn": try JSONValue(encoding: turn)]))
    #expect(try await stopped.turn == turn)

    async let looked = client.request(TurnLookup.self, .init(operationId: "op-7", threadId: "thread-1"))
    guard case .command(let lookupId, .turnLookup, _, nil, nil) = try await RelayHarness.nextFrame(socket)
    else {
      Issue.record("expected a turn.lookup command")
      return
    }
    socket.deliver(.reply(id: lookupId, result: ["state": "in_flight"]))
    #expect(try await looked.state == .inFlight)
    await client.close()
    await h.relay.stop()
  }

  /// Review Focus 5: a message too large for a client frame is refused on the phone, before anything is
  /// sent, and it never surfaces as a link error.
  @Test func oversizedTurnIsRefusedBeforeSending() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    let h = RelayHarness()
    let socket = await h.connect()
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay))
    _ = try await client.ready()

    let huge = String(repeating: "é", count: 32_500)  // 65 000 bytes of UTF-8: about 63 KiB
    let refused = await #expect(throws: WorkspaceError.self) {
      try await client.request(
        TurnSend.self, .init(threadId: "thread-1", text: huge), options: RequestOptions(operationId: "op-1"))
    }
    #expect(refused?.code == .protocolInvalid)
    #expect(refused?.message == "This message is too long to send from the phone.")
    let start = await #expect(throws: WorkspaceError.self) {
      try await client.request(
        ThreadStart.self, .init(threadId: "t-new", projectId: "p1", connectionId: "conn-1", text: huge),
        options: RequestOptions(operationId: "op-2"))
    }
    #expect(start?.message == "This message is too long to send from the phone.")

    // The relay's own check, at the boundary: the encoded frame may be 65 536 - 1 024 bytes, no more.
    let frame = { (text: String) throws -> Int in
      try JSONEncoder().encode(
        RelayMessage.command(
          id: "op-3", method: .turnSend, params: ["threadId": "thread-1", "text": .string(text)])
      ).count
    }
    let overhead = try frame("")
    let fits = String(repeating: "a", count: 65_536 - 1_024 - overhead)
    #expect(try frame(fits) == 64_512)
    let over = await h.relay.command(
      id: "op-4", method: .turnSend, params: ["threadId": "thread-1", "text": .string(fits + "a")])
    #expect(
      over
        == .failure(
          WorkspaceError(
            .protocolInvalid, "This message is too long to send from the phone.",
            details: ["reason": "too_long", "maxBytes": 64_512])))
    #expect(RelayHarness.commands(socket).isEmpty)
    #expect(await h.relay.isConnected)

    async let accepted = h.relay.command(
      id: "op-3", method: .turnSend, params: ["threadId": "thread-1", "text": .string(fits)])
    _ = try await RelayHarness.nextFrame(socket)
    socket.deliver(
      .reply(id: "op-3", result: ["turn": try JSONValue(encoding: relayTurn("t", operationId: "op-3"))]))
    guard case .success = await accepted else {
      Issue.record("a frame at the limit is sent")
      return
    }
    await client.close()
    await h.relay.stop()
  }

  /// Stop and answer wait 90 s, send and start 30 s; then the phone says "not confirmed" on its own.
  @Test(arguments: [
    (RelayMethod.turnInterrupt, 90), (.requestRespond, 90), (.turnSend, 30), (.threadStart, 30),
  ])
  func aCommandWithNoReplyIsNotConfirmedAfterThePhonesWait(method: RelayMethod, seconds: Int) async throws {
    let h = RelayHarness()
    let socket = await h.connect()
    #expect(MirrorRelay.wait(for: method) == .seconds(seconds))
    let task = Task { await h.relay.command(id: "c1", method: method, params: ["threadId": "thread-1"]) }
    _ = try await RelayHarness.nextFrame(socket)
    await waitUntil("the reply wait") { h.clock.hasSleeper(dueIn: .seconds(seconds)) }
    await h.idle(socket, for: .seconds(seconds - 1))
    #expect(await h.relay.pendingCount == 1)
    h.clock.advance(by: .seconds(1))
    guard case .failure(let error) = await task.value else {
      Issue.record("expected not confirmed")
      return
    }
    #expect(error.code == MirrorRelay.notConfirmedCode)
    #expect(error.message == "Not confirmed: your Mac may not have received this.")
    #expect(error.details?["reason"] == "timeout")
    // A reply after the phone gave up goes nowhere.
    socket.deliver(.reply(id: "c1", result: [:]))
    await h.relay.stop()
  }

  @Test func aDroppedLinkLeavesAPendingCommandNotConfirmed() async throws {
    let h = RelayHarness()
    let socket = await h.connect()
    let task = Task {
      await h.relay.command(id: "c1", method: .turnSend, params: ["threadId": "t", "text": "x"])
    }
    _ = try await RelayHarness.nextFrame(socket)
    socket.closeFromHub(code: 1001)
    guard case .failure(let error) = await task.value else {
      Issue.record("expected not confirmed")
      return
    }
    #expect(error.code == .relayTimeout && error.details?["reason"] == "link_dropped")
    await h.relay.stop()
  }

  @Test func aCommandWithoutALinkIsNotSent() async throws {
    let h = RelayHarness()
    let result = await h.relay.command(id: "c1", method: .turnSend, params: ["threadId": "t", "text": "x"])
    guard case .failure(let error) = result else {
      Issue.record("expected a refusal")
      return
    }
    #expect(error.code == .endpointUnavailable && error.message == "Connecting to the hub…")
    #expect(error.details?["sent"] == false)
    #expect(h.connection.openCount == 0)
  }

  @Test func watchesAreResentAfterReconnect() async throws {
    let h = RelayHarness()
    await h.relay.watch("thread-1")
    let first = await h.connect()
    #expect(try await RelayHarness.nextFrame(first) == .watch(threadId: "thread-1"))
    await h.relay.watch("thread-2")
    #expect(try await RelayHarness.nextFrame(first) == .watch(threadId: "thread-2"))
    await h.relay.unwatch("thread-2")
    #expect(try await RelayHarness.nextFrame(first) == .unwatch(threadId: "thread-2"))
    await h.relay.watchOnly("thread-3")
    #expect(try await RelayHarness.nextFrame(first) == .unwatch(threadId: "thread-1"))
    #expect(try await RelayHarness.nextFrame(first) == .watch(threadId: "thread-3"))

    // The hub restarts: the next link watches the same thread again.
    first.closeFromHub(code: 1001)
    await waitUntil("the backoff") { !(await h.relay.isConnected) && h.clock.hasSleeper(dueIn: .seconds(1)) }
    h.clock.advance(by: .seconds(1))
    let second = await h.answerNextOpen()
    #expect(try await RelayHarness.nextFrame(second) == .watch(threadId: "thread-3"))

    // Going to the background stops the link (the hub forgets its watches); the next start re-sends.
    await h.relay.stop()
    let third = await h.connect()
    #expect(try await RelayHarness.nextFrame(third) == .watch(threadId: "thread-3"))
    #expect(await h.relay.watched == ["thread-3"])
    await h.relay.stop()
  }

  @Test func presenceBecomesHostPresenceEvents() async throws {
    let store = try MirrorStore.inMemory()
    let h = RelayHarness()
    // The hub's clock runs 120 s ahead of the phone's.
    let socket = await h.connect(hubTime: Date().addingTimeInterval(120))
    let client = WorkspaceClient(transport: MirrorTransport(store: store, version: "0.2.0", relay: h.relay))
    _ = try await client.ready()
    let events = await client.events()
    var iterator = events.makeAsyncIterator()

    let seenOnHub = Date().addingTimeInterval(120 - 30)
    socket.deliver(
      .presence(hosts: [
        RelayHostPresence(
          deviceId: "mac-1", name: "Brian's MacBook Pro", online: false,
          lastSeenAt: Timestamp.string(from: seenOnHub)),
        RelayHostPresence(deviceId: "mac-2", name: "Studio", online: true),
      ]))
    var hosts: [HostPresence] = []
    while hosts.isEmpty, let envelope = await iterator.next() {
      #expect(envelope.event.kind == .hostPresence)
      if let set = envelope.event.presenceHosts {
        #expect(envelope.event.presenceLink == .connected)
        hosts = set
      }
    }
    #expect(hosts.map(\.deviceId) == ["mac-1", "mac-2"])
    #expect(hosts[0].name == "Brian's MacBook Pro" && !hosts[0].online)
    // On the phone's clock: about 30 s ago, not 90 s in the future.
    let seen = try #require(hosts[0].lastSeenAt.flatMap(Timestamp.date(from:)))
    #expect(abs(seen.timeIntervalSinceNow + 30) < 5)
    #expect(hosts[1].online && hosts[1].lastSeenAt == nil)
    // The snapshot carries the same, so a model that connects after these events still knows them.
    let snapshot = try await client.request(EventsSnapshot.self, EmptyParams())
    #expect(snapshot.presence == PresenceSnapshot(link: .connected, hosts: hosts))

    // The next frame is the whole set again: a Mac missing from it (revoked) is gone.
    socket.deliver(.presence(hosts: [RelayHostPresence(deviceId: "mac-2", name: "Studio", online: true)]))
    while let envelope = await iterator.next() {
      if let set = envelope.event.presenceHosts {
        #expect(set.map(\.deviceId) == ["mac-2"])
        break
      }
    }
    let after = try await client.request(EventsSnapshot.self, EmptyParams())
    #expect(after.presence?.hosts.map(\.deviceId) == ["mac-2"])

    // The phone's own link going down makes every host unknown.
    socket.closeFromHub(code: 1001)
    while let envelope = await iterator.next() {
      if envelope.event.kind == .hostPresence, envelope.event.presenceLink == .connecting {
        #expect(envelope.event.presenceHost == nil)
        break
      }
    }
    let down = try await client.request(EventsSnapshot.self, EmptyParams())
    #expect(down.presence == PresenceSnapshot(link: .connecting, hosts: []))
    await client.close()
    await h.relay.stop()
  }
}
