import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceSync

/// A clock tests move by hand. Sleepers wake in deadline order when `advance` passes their deadline;
/// a cancelled sleeper leaves at once, so `sleeperCount` is what the code under test is waiting on.
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
  /// Sleepers cancelled before they registered.
  private var cancelledEarly: Set<Int> = []

  var now: Instant { lock.withLock { current } }
  var minimumResolution: Duration { .nanoseconds(1) }
  var sleeperCount: Int { lock.withLock { sleepers.count } }

  /// How long until the earliest sleeper wakes, or nil with none.
  var nextWake: Duration? {
    lock.withLock { sleepers.map(\.deadline).min().map { current.duration(to: $0) } }
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

actor LinkRecorder {
  private(set) var states: [RelayLinkState] = []
  private(set) var messages: [RelayMessage] = []
  func state(_ state: RelayLinkState) { states.append(state) }
  func message(_ message: RelayMessage) { messages.append(message) }
  var last: RelayLinkState? { states.last }
}

func isoString(_ date: Date) -> String {
  date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
}

func helloMessage(role: RelayRole = .host, hubTime: Date = Date()) -> RelayMessage {
  .hello(
    protocol: 1, minClientProtocol: 1, deviceId: "d1", role: role, heartbeatSeconds: 10,
    hubTime: isoString(hubTime))
}

/// A `RelayLink` on a fake connection and a manual clock, with jitter fixed at 1.0.
struct LinkHarness {
  let connection = FakeHubLinkConnection()
  let clock = ManualClock()
  let recorder = LinkRecorder()
  let link: RelayLink

  init(token: @escaping @Sendable () async throws -> String? = { "tok" }, maxBackoff: Duration = .seconds(30))
  {
    let connection = connection
    let clock = clock
    let recorder = recorder
    link = RelayLink(
      url: URL(string: "https://hub.example.com")!, token: token, connection: connection,
      maxBackoff: maxBackoff, clock: clock, jitter: { 1.0 },
      onMessage: { await recorder.message($0) }, onState: { await recorder.state($0) })
  }

  /// Starts the link and answers its first open with a `hello`, returning the hub's side.
  func connect(role: RelayRole = .host) async -> FakeHubLinkSocket {
    await link.start()
    let socket = await connection.nextSocket()
    socket.deliver(helloMessage(role: role))
    await waitUntil("connected") {
      if case .connected? = await recorder.last { return true }
      return false
    }
    return socket
  }

  /// Waits until the link has published a retry after the first `seen` states and is sleeping out its
  /// backoff (the retry is published after the connection's timers are cancelled, so a lone sleeper
  /// is the backoff). Returns the wait and the state count.
  func awaitBackoff(pastStates seen: Int) async -> (delay: Duration, states: Int) {
    await waitUntil("a retry") {
      guard await recorder.states.count > seen, case .connecting(_, let error)? = await recorder.last else {
        return false
      }
      return error != nil
    }
    await waitUntil("the backoff sleep") { clock.sleeperCount == 1 }
    return (clock.nextWake ?? .zero, await recorder.states.count)
  }

  /// Delivers `frame` and waits until the link has handled it (frames are handled in order).
  func flush(_ socket: FakeHubLinkSocket) async {
    let marker = RelayMessage.streamGap(threadId: "flush-\(UUID().uuidString)")
    socket.deliver(marker)
    await waitUntil("flush") { await recorder.messages.contains(marker) }
  }
}

@Suite(.timeLimit(.minutes(1)))
struct RelayLinkTests {
  @Test func connectsAndReportsTheRoleFromHello() async throws {
    let h = LinkHarness()
    await h.link.start()
    let socket = await h.connection.nextSocket()
    #expect(socket.token == "tok")
    #expect(socket.protocolVersion == 1)
    #expect(socket.url.absoluteString == "https://hub.example.com")
    #expect(await h.recorder.states == [.connecting(attempt: 1, lastError: nil)])

    socket.deliver(helloMessage(role: .client))
    await waitUntil("connected") { await h.recorder.states.count == 2 }
    guard case .connected(_, let role)? = await h.recorder.last else {
      Issue.record("expected connected, got \(String(describing: await h.recorder.last))")
      return
    }
    #expect(role == .client)
  }

  @Test func framesReachOnMessageInOrderAndPongsStayInside() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    let presence = RelayMessage.presence(hosts: [])
    socket.deliver(.pong(hubTime: isoString(Date())))
    socket.deliver(presence)
    await waitUntil("presence") { await h.recorder.messages.contains(presence) }
    let seen = await h.recorder.messages
    #expect(!seen.contains { if case .pong = $0 { true } else { false } })
  }

  @Test func sendWritesToTheHubAndThrowsWhenNotConnected() async throws {
    let h = LinkHarness()
    await #expect(throws: HubLinkError.notConnected) { try await h.link.send(.ping) }
    let socket = await h.connect()
    let watch = RelayMessage.watch(threadId: "t1")
    try await h.link.send(watch)
    #expect(try await socket.nextSent() == watch)
  }

  @Test func backoffDoublesToTheCapWithJitterAndResets() async throws {
    let h = LinkHarness()
    h.connection.failNext(HubLinkError.failed("down"), times: 7)
    await h.link.start()

    var delays: [Duration] = []
    var seen = 1
    for _ in 0..<7 {
      let backoff = await h.awaitBackoff(pastStates: seen)
      delays.append(backoff.delay)
      seen = backoff.states
      h.clock.advance(by: backoff.delay)
    }
    #expect(delays == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })

    // The eighth attempt connects and stays 60 s.
    let socket = await h.connection.nextSocket()
    socket.deliver(helloMessage())
    await waitUntil("connected") { if case .connected? = await h.recorder.last { true } else { false } }
    for _ in 0..<6 {
      await waitUntil("timers") { h.clock.sleeperCount == 3 }
      h.clock.advance(by: .seconds(10))
      #expect(try await socket.nextSent() == .ping)
      socket.deliver(.pong(hubTime: isoString(Date())))
      await h.flush(socket)
    }
    // At 60 s connected the stability timer is spent: the heartbeat and the watchdog remain.
    await waitUntil("stable") { h.clock.sleeperCount == 2 }
    await h.flush(socket)
    try await Task.sleep(for: .milliseconds(30))

    let seenStates = await h.recorder.states.count
    socket.closeFromHub(code: 1001)
    #expect(await h.awaitBackoff(pastStates: seenStates).delay == .seconds(1))
  }

  @Test func aLinkThatDropsBeforeSixtySecondsKeepsGrowingTheBackoff() async throws {
    let h = LinkHarness()
    await h.link.start()
    for expected in [1, 2, 4] {
      let socket = await h.connection.nextSocket()
      socket.deliver(helloMessage())
      await waitUntil("connected") { if case .connected? = await h.recorder.last { true } else { false } }
      let seenStates = await h.recorder.states.count
      socket.closeFromHub(code: 1001)
      let backoff = await h.awaitBackoff(pastStates: seenStates)
      #expect(backoff.delay == .seconds(expected))
      h.clock.advance(by: backoff.delay)
    }
  }

  @Test func jitterScalesTheDelay() async throws {
    let connection = FakeHubLinkConnection()
    let clock = ManualClock()
    let link = RelayLink(
      url: URL(string: "https://hub.example.com")!, token: { "tok" }, connection: connection,
      maxBackoff: .seconds(30), clock: clock, jitter: { 0.25 }, onMessage: { _ in }, onState: { _ in })
    connection.failNext(HubLinkError.failed("down"), times: 1)
    await link.start()
    await waitUntil("backoff") { clock.sleeperCount == 1 }
    #expect(clock.nextWake == .milliseconds(250))
    await link.stop()
  }

  @Test func pingsEveryTenSecondsAndReconnectsAfterThirtySilent() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    await waitUntil("timers") { h.clock.sleeperCount == 3 }
    h.clock.advance(by: .seconds(10))
    #expect(try await socket.nextSent() == .ping)
    await waitUntil("timers") { h.clock.sleeperCount == 3 }
    h.clock.advance(by: .seconds(10))
    #expect(try await socket.nextSent() == .ping)
    await waitUntil("timers") { h.clock.sleeperCount == 3 }
    h.clock.advance(by: .seconds(10))  // 30 s since the hello

    await waitUntil("dropped for silence") {
      await h.recorder.last == .connecting(attempt: 1, lastError: "silent")
    }
    #expect(socket.deviceClosedCode != nil)
    await waitUntil("backoff") { h.clock.sleeperCount == 1 }
    h.clock.advance(by: .seconds(1))
    _ = await h.connection.nextSocket()
    #expect(h.connection.openCount == 2)
  }

  @Test func anyFrameKeepsTheLinkAlive() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    for _ in 0..<4 {
      await waitUntil("timers") { h.clock.sleeperCount >= 2 }
      h.clock.advance(by: .seconds(20))
      await h.flush(socket)
    }
    #expect(socket.deviceClosedCode == nil)
  }

  @Test func unauthorizedStopsWithoutRetrying() async throws {
    let h = LinkHarness()
    h.connection.refuseWith(status: 401)
    await h.link.start()
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: "unauthorized") }
    h.clock.advance(by: .seconds(120))
    try await Task.sleep(for: .milliseconds(30))
    #expect(h.connection.openCount == 1)
    #expect(h.clock.sleeperCount == 0)
  }

  @Test func noTokenStopsAsUnauthorized() async throws {
    let h = LinkHarness(token: { nil })
    await h.link.start()
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: "unauthorized") }
    #expect(h.connection.openCount == 0)
  }

  @Test func aTokenThatThrowsIsRetried() async throws {
    struct Broken: Error {}
    let h = LinkHarness(token: { throw Broken() })
    await h.link.start()
    await waitUntil("backoff") { h.clock.sleeperCount == 1 }
    #expect(h.connection.openCount == 0)
    guard case .connecting? = await h.recorder.last else {
      Issue.record("expected connecting")
      return
    }
    await h.link.stop()
  }

  @Test func rateLimitedUpgradeIsRetriedWithBackoff() async throws {
    let h = LinkHarness()
    h.connection.refuseWith(status: 429)
    await h.link.start()
    await waitUntil("backoff") { h.clock.sleeperCount == 1 }
    #expect(await h.recorder.last == .connecting(attempt: 2, lastError: "refused (429)"))
    h.clock.advance(by: .seconds(1))
    _ = await h.connection.nextSocket()
    #expect(h.connection.openCount == 2)
  }

  @Test func replacedStops() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    socket.deliver(.error(code: "link_replaced", message: "replaced"))
    socket.closeFromHub(code: 4000)
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: "replaced") }
    h.clock.advance(by: .seconds(120))
    try await Task.sleep(for: .milliseconds(30))
    #expect(h.connection.openCount == 1)
  }

  @Test(arguments: [(4000, "replaced"), (4001, "revoked"), (4002, "client_too_old")])
  func terminalCloseCodesStop(code: Int, reason: String) async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    socket.closeFromHub(code: code)
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: reason) }
    #expect(h.connection.openCount == 1)
  }

  @Test func clientTooOldErrorFrameStopsEvenBeforeHello() async throws {
    let h = LinkHarness()
    await h.link.start()
    let socket = await h.connection.nextSocket()
    socket.deliver(.error(code: "client_too_old", message: "update", details: nil))
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: "client_too_old") }
    #expect(await h.recorder.messages.count == 1)
    #expect(socket.deviceClosedCode != nil)
  }

  @Test(arguments: [4003, 1001, 1006])
  func otherClosesAreRetried(code: Int) async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    socket.closeFromHub(code: code)
    await waitUntil("a retry") {
      await h.recorder.last == .connecting(attempt: 1, lastError: "closed (\(code))")
    }
  }

  @Test func hubNowUsesTheLatestPongOffset() async throws {
    let h = LinkHarness()
    #expect(await h.link.hubNow() == nil)
    await h.link.start()
    let socket = await h.connection.nextSocket()
    socket.deliver(helloMessage(hubTime: Date().addingTimeInterval(120)))
    await waitUntil("hello") { await h.link.hubNow() != nil }
    let afterHello = try #require(await h.link.hubNow())
    #expect(abs(afterHello.timeIntervalSinceNow - 120) < 2)

    socket.deliver(.pong(hubTime: isoString(Date().addingTimeInterval(-300))))
    await waitUntil("pong") { (await h.link.hubNow().map { $0.timeIntervalSinceNow < -200 }) == true }
    let afterPong = try #require(await h.link.hubNow())
    #expect(abs(afterPong.timeIntervalSinceNow + 300) < 2)
  }

  @Test func reconnectNowSkipsTheBackoffWait() async throws {
    let h = LinkHarness()
    h.connection.failNext(HubLinkError.failed("down"), times: 1)
    await h.link.start()
    await waitUntil("backoff") { h.clock.sleeperCount == 1 }
    await h.link.reconnectNow()
    _ = await h.connection.nextSocket()  // no clock.advance
    #expect(h.connection.openCount == 2)
  }

  @Test func reconnectNowDropsAConnectedLinkAndReopensAtOnce() async throws {
    let h = LinkHarness()
    let first = await h.connect()
    await h.link.reconnectNow()
    #expect(first.deviceClosedCode != nil)
    let second = await h.connection.nextSocket()
    #expect(second !== first)
    #expect(h.clock.nextWake != .seconds(1))
  }

  @Test func stopClosesTheSocketAndStartsAgain() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    await h.link.stop()
    #expect(socket.deviceClosedCode != nil)
    #expect(await h.recorder.last == .stopped(reason: "stopped"))
    await #expect(throws: HubLinkError.notConnected) { try await h.link.send(.ping) }
    #expect(h.clock.sleeperCount == 0)

    let opens = h.connection.openCount
    await h.link.start()
    _ = await h.connection.nextSocket()
    #expect(h.connection.openCount == opens + 1)
  }

  @Test func aTerminalCloseCodeWinsOverALocalReconnect() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    socket.closeFromHub(code: 4001)
    await h.link.reconnectNow()
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: "revoked") }
    #expect(h.connection.openCount == 1)
  }

  @Test func aTerminalCloseCodeWinsOverTheSilenceTimer() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    await waitUntil("timers") { h.clock.sleeperCount == 3 }
    socket.closeFromHub(code: 4001)
    h.clock.advance(by: .seconds(30))
    await waitUntil("stopped") { await h.recorder.last == .stopped(reason: "revoked") }
    #expect(h.connection.openCount == 1)
  }

  @Test func reconnectNowDuringAnInFlightOpenSkipsTheBackoff() async throws {
    let gate = GatedConnection()
    let clock = ManualClock()
    let link = RelayLink(
      url: URL(string: "https://hub.example.com")!, token: { "tok" }, connection: gate,
      maxBackoff: .seconds(30),
      clock: clock, jitter: { 1.0 }, onMessage: { _ in }, onState: { _ in })
    await link.start()
    await waitUntil("the first open") { gate.openCount == 1 }
    await link.reconnectNow()
    gate.release()  // the first open fails
    _ = await gate.inner.nextSocket()  // the second open, with no clock.advance
    #expect(gate.openCount == 2)
    await link.stop()
  }

  @Test func reconnectNowWhileTheTokenIsBeingFetchedSkipsTheBackoff() async throws {
    let connection = FakeHubLinkConnection()
    let clock = ManualClock()
    let tokenGate = TokenGate()
    let link = RelayLink(
      url: URL(string: "https://hub.example.com")!, token: { try await tokenGate.next() },
      connection: connection,
      maxBackoff: .seconds(30), clock: clock, jitter: { 1.0 }, onMessage: { _ in }, onState: { _ in })
    await link.start()
    await waitUntil("the first token request") { await tokenGate.requests == 1 }
    await link.reconnectNow()
    await tokenGate.release(nil, throwing: true)  // the first fetch fails
    await waitUntil("the second token request") { await tokenGate.requests == 2 }
    await tokenGate.release("tok", throwing: false)
    _ = await connection.nextSocket()
    #expect(connection.openCount == 1)
    await link.stop()
  }

  @Test func aStaleRunsUndecodableFrameDoesNotReplaceTheNewRunsWatchdog() async throws {
    let connection = FakeHubLinkConnection()
    let clock = ManualClock()
    let recorder = LinkRecorder()
    let handlerGate = MessageGate()
    let link = RelayLink(
      url: URL(string: "https://hub.example.com")!, token: { "tok" }, connection: connection,
      maxBackoff: .seconds(30), clock: clock, jitter: { 1.0 },
      onMessage: { message in
        // The old run's loop sits in its handler for the first message (the hello).
        if await handlerGate.shouldHold() { await handlerGate.waitForRelease() }
        await recorder.message(message)
      },
      onState: { await recorder.state($0) })

    await link.start()
    let old = await connection.nextSocket()
    old.deliver(helloMessage())
    await waitUntil("the old run is in its handler") { await handlerGate.holding }
    old.deliverUndecodable()  // buffered behind the hello, for the old loop to read later
    await link.stop()
    await link.start()
    let current = await connection.nextSocket()
    current.deliver(helloMessage())
    await waitUntil("the new run is connected") {
      await recorder.states.filter { if case .connected = $0 { true } else { false } }.count == 2
    }

    await handlerGate.release()  // the old loop reads the undecodable frame now
    try await Task.sleep(for: .milliseconds(50))
    await waitUntil("timers") { clock.sleeperCount == 3 }
    clock.advance(by: .seconds(30))
    await waitUntil("the new link dropped for silence") { current.deviceClosedCode != nil }
    await link.stop()
  }

  @Test func anUndecodableFrameDoesNotEndTheLink() async throws {
    let h = LinkHarness()
    let socket = await h.connect()
    socket.deliverUndecodable()
    await h.flush(socket)
    #expect(socket.deviceClosedCode == nil)
  }
}

/// A connection whose first open waits for `release()` and then fails; later opens go to a fake.
final class GatedConnection: HubLinkConnection, @unchecked Sendable {
  let inner = FakeHubLinkConnection()
  private let lock = NSLock()
  private var count = 0
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  var openCount: Int { lock.withLock { count } }

  func release() {
    let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      released = true
      defer { continuation = nil }
      return continuation
    }
    waiting?.resume()
  }

  func open(url: URL, token: String, protocolVersion: Int) async throws -> any HubLinkSocket {
    let first = lock.withLock { () -> Bool in
      count += 1
      return count == 1
    }
    guard first else { return try await inner.open(url: url, token: token, protocolVersion: protocolVersion) }
    await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        if released { return true }
        continuation = waiting
        return false
      }
      if ready { waiting.resume() }
    }
    throw HubLinkError.failed("down")
  }
}

/// A token closure whose calls wait for the test to answer them, one at a time.
actor TokenGate {
  private(set) var requests = 0
  private var waiting: [CheckedContinuation<String?, any Error>] = []

  func next() async throws -> String? {
    requests += 1
    return try await withCheckedThrowingContinuation { waiting.append($0) }
  }

  struct Failure: Error {}

  func release(_ token: String?, throwing: Bool) {
    guard !waiting.isEmpty else { return }
    let continuation = waiting.removeFirst()
    if throwing {
      continuation.resume(throwing: Failure())
    } else {
      continuation.resume(returning: token)
    }
  }
}

/// Holds the first message handler call until released.
actor MessageGate {
  private(set) var holding = false
  private var used = false
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?

  func shouldHold() -> Bool {
    guard !used else { return false }
    used = true
    holding = true
    return true
  }

  func waitForRelease() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
