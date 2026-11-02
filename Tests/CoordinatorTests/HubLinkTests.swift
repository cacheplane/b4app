import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

private let enrolled = EnrollResponse(
  deviceId: "dev-mac", token: "tok-link-secret", org: OrgInfo(slug: "acme", name: "Acme"),
  user: UserInfo(username: "brian", displayName: "Brian"))
private let enrollCode = "BCDF2345"

// MARK: - Clock and waiting (a copy of WorkspaceSyncTests' manual clock)

/// A clock tests move by hand. Sleepers wake in deadline order when `advance` passes their deadline;
/// a cancelled sleeper leaves at once, so `sleeperCount` is what the code under test is waiting on.
final class LinkTestClock: Clock, @unchecked Sendable {
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
private func waitUntil(
  seconds: Double = 30, _ comment: Comment = "condition", sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @Sendable () async -> Bool
) async {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(comment)", sourceLocation: sourceLocation)
}

private func hello(hubTime: Date = Date()) -> RelayMessage {
  .hello(
    protocol: 1, minClientProtocol: 1, deviceId: "dev-mac", role: .host, heartbeatSeconds: 10,
    hubTime: Timestamp.string(from: hubTime))
}

/// The next frame the Mac sent that is not a heartbeat.
private func nextFrame(_ socket: FakeHubLinkSocket) async throws -> RelayMessage {
  while true {
    let message = try await socket.nextSent()
    if message != .ping { return message }
  }
}

/// The event inside a frame, or nil (and a recorded issue) when it is not an `event`.
private func event(
  _ message: RelayMessage, sourceLocation: SourceLocation = #_sourceLocation
) -> AdapterEvent? {
  guard case .event(let event) = message else {
    Issue.record("expected an event frame, got \(message)", sourceLocation: sourceLocation)
    return nil
  }
  return event
}

private func delta(thread: String, item: String, _ text: String, turn: String = "turn-1") -> AdapterEvent {
  AdapterEvent(
    kind: .messageDelta, connectionId: "conn-1", threadId: thread, turnId: turn,
    nativeIds: ["itemId": item, "threadId": "native-\(thread)"], payload: ["delta": .string(text)])
}

private func plain(_ kind: EventKind, thread: String, payload: JSONValue = .object([:])) -> AdapterEvent {
  AdapterEvent(kind: kind, connectionId: "conn-1", threadId: thread, turnId: "turn-1", payload: payload)
}

/// A path monitor the test fires by hand.
private final class FakePathMonitor: NetworkPathMonitoring, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () async -> Void)?
  var started: Bool { lock.withLock { handler != nil } }
  func start(onSatisfied: @escaping @Sendable () async -> Void) { lock.withLock { handler = onSatisfied } }
  func stop() { lock.withLock { handler = nil } }
  func becomeSatisfied() async {
    let handler = lock.withLock { self.handler }
    await handler?()
  }
}

/// Holds `sendTurn` until the test opens it, so a relayed turn takes as long as the test wants.
private actor TurnGate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var arrivals = 0
  func pass() async {
    arrivals += 1
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    open = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

/// The fake Codex runtime with `sendTurn` held at `gate`.
private struct GatedAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let gate: TurnGate
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    await gate.pass()
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

// MARK: - Harness

/// A coordinator over a scratch store with the fake Codex runtime, and a `HubLink` built over its event
/// log and a `RelayExecutor`, on a fake connection and a manual clock. The coordinator itself has not
/// joined a hub, so the only link is the test's.
private struct LinkHarness {
  let coordinator: RunningCoordinator
  let connection = FakeHubLinkConnection()
  let clock = LinkTestClock()
  let paths = FakePathMonitor()
  let link: HubLink
  let base: String

  static func start(adapterFactory: SessionService.AdapterFactory? = nil) async throws -> LinkHarness {
    let base = NSTemporaryDirectory() + "b4l-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["ANTHROPIC_API_KEY"] = nil
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: MemorySecretStore(), adapterFactory: adapterFactory))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    return LinkHarness(coordinator: coordinator, base: base)
  }

  private init(coordinator: RunningCoordinator, base: String) {
    self.coordinator = coordinator
    self.base = base
    let executor = RelayExecutor(
      sessions: coordinator.sessions, projects: coordinator.projects, database: coordinator.database,
      diagnostics: coordinator.diagnostics)
    link = HubLink(
      url: URL(string: "http://localhost:8080")!, token: { "tok-link-secret" }, executor: executor,
      eventLog: coordinator.eventLog, connection: connection, clock: clock, jitter: { 1.0 },
      pathMonitor: paths)
  }

  /// Starts the link and answers its first open with `hello`.
  func connect() async throws -> FakeHubLinkSocket {
    await link.start()
    let socket = await connection.nextSocket()
    socket.deliver(hello())
    await waitUntil("connected") { await link.status().state == .connected }
    return socket
  }

  /// Tells the link which threads are watched, and waits until it has taken the set.
  func watch(_ socket: FakeHubLinkSocket, _ threadIds: [String]) async {
    socket.deliver(.watching(threadIds: threadIds))
    await waitUntil("watching \(threadIds)") { await link.watchedThreads == Set(threadIds) }
  }

  func publish(_ event: AdapterEvent) async {
    await coordinator.eventLog.publish(event)
  }

  func addCodex() async throws -> Connection {
    try await coordinator.sessions.connectionAdd(
      ConnectionAdd.Params(kind: .codex, label: "Fake Codex", executablePath: fakeCodex)
    ).connection
  }

  func newThread(_ connection: Connection) async throws -> ConversationThread {
    try await coordinator.sessions.threadCreate(
      ThreadCreate.Params(connectionId: connection.id, workingDirectory: base + "/work")
    ).thread
  }

  func close() async {
    await link.stop()
    await coordinator.close()
  }
}

/// A coordinator with a fake hub API and a fake link connection, for the `HubSync` wiring: join starts
/// the link, leave and a 401 stop it, and the wake signal reconnects it.
private struct JoinedHarness {
  let coordinator: RunningCoordinator
  let fake: FakeHubAPI
  let connection: FakeHubLinkConnection

  static func start() async throws -> JoinedHarness {
    let base = NSTemporaryDirectory() + "b4j-\(UUID().uuidString.prefix(8))"
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(enrollCode, enrolled)
    let connection = FakeHubLinkConnection()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: MemorySecretStore(), hubAPIFactory: { _, _ in fake },
        hubLinkConnection: connection))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    return JoinedHarness(coordinator: coordinator, fake: fake, connection: connection)
  }

  /// Joins and answers the link's first open with `hello`.
  func join() async throws -> FakeHubLinkSocket {
    _ = try await coordinator.hub.join(url: "http://localhost:8080", code: enrollCode, deviceName: "Test Mac")
    let socket = await connection.nextSocket()
    socket.deliver(hello())
    await waitUntil("connected") { (try? await coordinator.hub.status().link?.state) == .connected }
    return socket
  }

  func close() async { await coordinator.close() }
}

// MARK: - Tests

@Suite(.serialized, .timeLimit(.minutes(2))) struct HubLinkTests {
  @Test func commandFromTheHubRunsAndReplies() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let thread = try await h.newThread(try await h.addCodex())
    let finished = await h.coordinator.eventLog.subscribe()
    let socket = try await h.connect()
    let id = UUID().uuidString.lowercased()
    socket.deliver(
      .command(
        id: id, method: .turnSend,
        params: try JSONValue(encoding: TurnSend.Params(threadId: thread.id, text: "hi")),
        deadline: Timestamp.string(from: Date().addingTimeInterval(8)),
        from: RelayFrom(deviceId: "phone-1", name: "iPhone")))
    guard case .reply(let replyId, let result, let error) = try await nextFrame(socket) else {
      Issue.record("expected a reply")
      return
    }
    #expect(replyId == id)
    #expect(error == nil)
    let turn = try #require(result).decode(TurnSend.Result.self).turn
    #expect(turn.operationId == id)
    #expect(turn.threadId == thread.id)
    for await envelope in finished
    where envelope.event.kind == .turnFinished && envelope.event.turnId == turn.id {
      break
    }
    #expect(try h.coordinator.database.turns(threadId: thread.id).map(\.outcome) == [.completed])
  }

  @Test func commandsDoNotHoldUpTheLink() async throws {
    let gate = TurnGate()
    let h = try await LinkHarness.start(adapterFactory: { connection, environment, version, secrets in
      GatedAdapter(
        inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets), gate: gate
      )
    })
    defer { Task { await h.close() } }
    let thread = try await h.newThread(try await h.addCodex())
    let socket = try await h.connect()
    let id = UUID().uuidString.lowercased()
    socket.deliver(
      .command(
        id: id, method: .turnSend,
        params: try JSONValue(encoding: TurnSend.Params(threadId: thread.id, text: "slow")),
        deadline: Timestamp.string(from: Date().addingTimeInterval(8))))
    await waitUntil("the turn reaches the runtime") { await gate.arrivals == 1 }
    // The command is still running: the next frames are read and events flow meanwhile.
    await h.watch(socket, ["t-other"])
    await h.publish(delta(thread: "t-other", item: "i1", "meanwhile"))
    #expect(event(try await nextFrame(socket))?.payload["delta"]?.stringValue == "meanwhile")
    await gate.release()
    var reply: RelayMessage?
    while reply == nil {
      let frame = try await nextFrame(socket)
      if case .reply = frame { reply = frame }
    }
    guard case .reply(let replyId, _, let error) = try #require(reply) else { return }
    #expect(replyId == id)
    #expect(error == nil)
  }

  @Test func expiredOrUndatedCommandIsRefused() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let thread = try await h.newThread(try await h.addCodex())
    let socket = try await h.connect()
    let params = try JSONValue(encoding: TurnSend.Params(threadId: thread.id, text: "late"))
    socket.deliver(
      .command(
        id: "late", method: .turnSend, params: params,
        deadline: Timestamp.string(from: Date().addingTimeInterval(-1))))
    guard case .reply("late", nil, let late?) = try await nextFrame(socket) else {
      Issue.record("expected an error reply")
      return
    }
    #expect(late.code == ErrorCode.commandExpired.rawValue)
    socket.deliver(.command(id: "undated", method: .turnSend, params: params))
    guard case .reply("undated", nil, let undated?) = try await nextFrame(socket) else {
      Issue.record("expected an error reply")
      return
    }
    #expect(undated.code == ErrorCode.commandExpired.rawValue)
    #expect(try h.coordinator.database.turns(threadId: thread.id).isEmpty)
  }

  @Test func onlyWatchedThreadsEventsAreSent() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.connect()
    await h.watch(socket, ["t1"])
    await h.publish(delta(thread: "t2", item: "i2", "not watched"))
    await h.publish(delta(thread: "t1", item: "i1", "watched"))
    let first = event(try await nextFrame(socket))
    #expect(first?.threadId == "t1")
    #expect(first?.payload["delta"]?.stringValue == "watched")
    // A new set replaces the old one.
    await h.watch(socket, ["t2"])
    await h.publish(delta(thread: "t1", item: "i1", " no longer"))
    await h.publish(plain(.turnFinished, thread: "t2"))
    // t2's open text "not watched" catches up first, then its live events.
    let caughtUp = event(try await nextFrame(socket))
    #expect(caughtUp?.threadId == "t2")
    #expect(caughtUp?.payload["delta"]?.stringValue == "not watched")
    let next = event(try await nextFrame(socket))
    #expect(next?.kind == .turnFinished)
    #expect(next?.threadId == "t2")
  }

  @Test func forwardedKindsOnly() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.connect()
    await h.watch(socket, ["t1"])
    await h.publish(
      AdapterEvent.connectionChanged(
        connectionId: "conn-1", status: .ready, authStatus: .authenticated, transport: .connected))
    var connectionChanged = plain(.connectionChanged, thread: "t1")
    connectionChanged.payload = ["status": "ready"]
    await h.publish(connectionChanged)
    await h.publish(plain(.threadUpdated, thread: "t1"))
    await h.publish(plain(.adapterError, thread: "t1"))
    await h.publish(plain(.runtimeRequestExpired, thread: "t1"))
    await h.publish(plain(.reconciliationSnapshot, thread: "t1"))
    for kind in RelayLimits.forwardedEventKinds { await h.publish(plain(kind, thread: "t1")) }
    var kinds: [EventKind] = []
    for _ in RelayLimits.forwardedEventKinds {
      if let event = event(try await nextFrame(socket)) { kinds.append(event.kind) }
    }
    #expect(kinds == RelayLimits.forwardedEventKinds)
  }

  @Test func oversizedEventIsSkipped() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.connect()
    await h.watch(socket, ["t1"])
    let big = String(repeating: "x", count: RelayLimits.hostFrameMax)
    await h.publish(plain(.toolCompleted, thread: "t1", payload: ["output": .string(big)]))
    // Just under the limit once encoded: still sent.
    var fits = plain(.toolCompleted, thread: "t1", payload: ["output": ""])
    let overhead = try JSONEncoder().encode(RelayMessage.event(fits)).count
    fits.payload = ["output": .string(String(repeating: "y", count: RelayLimits.hostFrameMax - overhead))]
    #expect(try JSONEncoder().encode(RelayMessage.event(fits)).count == RelayLimits.hostFrameMax)
    await h.publish(fits)
    let sent = event(try await nextFrame(socket))
    #expect(sent?.payload["output"]?.stringValue?.hasPrefix("y") == true)
  }

  @Test func newWatchFirstGetsTheTextSoFar() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.connect()
    await h.publish(delta(thread: "t1", item: "i1", "Hel"))
    await h.publish(delta(thread: "t1", item: "i1", "lo"))
    await h.publish(delta(thread: "t1", item: "i0", "done"))
    await h.publish(
      AdapterEvent(
        kind: .messageCompleted, connectionId: "conn-1", threadId: "t1", turnId: "turn-1",
        nativeIds: ["itemId": "i0"]))
    await waitUntil("the text so far") { await h.link.openText(threadId: "t1") == ["i1": "Hello"] }
    socket.deliver(.watching(threadIds: ["t1"]))
    let first = try #require(event(try await nextFrame(socket)))
    #expect(first.kind == .messageDelta)
    #expect(first.threadId == "t1")
    #expect(first.turnId == "turn-1")
    #expect(first.connectionId == "conn-1")
    #expect(first.nativeIds["itemId"] == "i1")
    #expect(first.payload["delta"]?.stringValue == "Hello")
    await h.publish(delta(thread: "t1", item: "i1", "!"))
    #expect(event(try await nextFrame(socket))?.payload["delta"]?.stringValue == "!")
    // Already watched: a repeat of the set sends no catch-up.
    socket.deliver(.watching(threadIds: ["t1"]))
    await h.publish(plain(.turnFinished, thread: "t1"))
    #expect(event(try await nextFrame(socket))?.kind == .turnFinished)
    #expect(await h.link.openText(threadId: "t1").isEmpty)
  }

  @Test func reconnectCatchesUpTheWatchedThreadsAgain() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.connect()
    await h.watch(socket, ["t1"])
    await h.publish(delta(thread: "t1", item: "i1", "Hi"))
    #expect(event(try await nextFrame(socket))?.payload["delta"]?.stringValue == "Hi")
    await h.link.reconnectNow()
    let again = await h.connection.nextSocket()
    again.deliver(hello())
    again.deliver(.watching(threadIds: ["t1"]))
    let first = event(try await nextFrame(again))
    #expect(first?.payload["delta"]?.stringValue == "Hi")
  }

  @Test func wakeReconnectsAtOnce() async throws {
    let h = try await JoinedHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.join()
    #expect(socket.token == enrolled.token)
    let gap = await h.coordinator.sleepWatcher.tick(
      continuous: .now + .seconds(120), suspending: .now)
    #expect(gap != nil)
    let again = await h.connection.nextSocket()
    #expect(socket.deviceClosedCode != nil)
    #expect(h.connection.openCount == 2)
    again.deliver(hello())
    await waitUntil("connected again") { (try? await h.coordinator.hub.status().link?.state) == .connected }
  }

  @Test func pathChangeReconnectsAtOnce() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.connect()
    #expect(h.paths.started)
    await h.paths.becomeSatisfied()
    let again = await h.connection.nextSocket()
    #expect(socket.deviceClosedCode != nil)
    #expect(h.clock.now.offset == .zero)
    again.deliver(hello())
    await waitUntil("connected again") { await h.link.status().state == .connected }
    await h.link.stop()
    #expect(!h.paths.started)
  }

  @Test func unauthorizedStopsTheLink() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    h.connection.refuseWith(status: 401)
    await h.link.start()
    await waitUntil("offline after the refusal") {
      let status = await h.link.status()
      return status.state == .offline && status.lastError != nil
    }
    let status = await h.link.status()
    #expect(status.lastError?.contains("join") == true)
    #expect(status.lastError?.contains("tok-link-secret") == false)
    h.clock.advance(by: .seconds(60))
    try await Task.sleep(for: .milliseconds(50))
    #expect(h.connection.openCount == 1)
  }

  @Test func aRefusedPushStopsTheLink() async throws {
    let h = try await JoinedHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.join()
    await h.fake.setFailNext(
      HubError(kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401))
    _ = try? await h.coordinator.hub.pushNow()
    await waitUntil("closed") { socket.deviceClosedCode != nil }
    let link = try #require(try await h.coordinator.hub.status().link)
    #expect(link.state == .offline)
  }

  @Test func statusReportsConnectedAndLastError() async throws {
    let h = try await LinkHarness.start()
    defer { Task { await h.close() } }
    #expect(await h.link.status() == HubLinkStatus(state: .offline))
    h.connection.failNext(HubLinkError.failed("hub unreachable"))
    await h.link.start()
    await waitUntil("the backoff") { h.clock.sleeperCount == 1 }
    let connecting = await h.link.status()
    #expect(connecting.state == .connecting)
    #expect(connecting.lastError == "hub unreachable")
    #expect(connecting.since.flatMap(Timestamp.date(from:)) != nil)
    h.clock.advance(by: .seconds(1))
    let socket = await h.connection.nextSocket()
    socket.deliver(hello())
    await waitUntil("connected") { await h.link.status().state == .connected }
    let connected = await h.link.status()
    #expect(connected.lastError == nil)
    #expect(connected.since.flatMap(Timestamp.date(from:)) != nil)
    // The hub drops the link: connecting again, with the reason.
    socket.closeFromHub(code: 4003)
    await waitUntil("connecting again") { await h.link.status().state == .connecting }
    #expect(await h.link.status().lastError == "closed (4003)")
    await h.link.stop()
    #expect(await h.link.status().state == .offline)
    #expect(await h.link.status().lastError == nil)
  }

  @Test func leaveStopsTheLink() async throws {
    let h = try await JoinedHarness.start()
    defer { Task { await h.close() } }
    let socket = try await h.join()
    let joined = try await h.coordinator.hub.status()
    #expect(joined.link?.state == .connected)
    try await h.coordinator.hub.leave()
    #expect(socket.deviceClosedCode != nil)
    let left = try await h.coordinator.hub.status()
    #expect(left.joined == false)
    #expect(left.link == nil)
  }

  @Test func statusDecodesWithoutALink() throws {
    let old = Data(#"{"joined":true,"url":"https://hub.test","unsyncedChanges":0}"#.utf8)
    let decoded = try JSONDecoder().decode(HubStatus.Result.self, from: old)
    #expect(decoded.link == nil)
    let status = HubStatus.Result(
      joined: true, unsyncedChanges: 0,
      link: HubLinkStatus(state: .connected, since: "2026-11-01T10:00:00.000Z"))
    let round = try JSONDecoder().decode(HubStatus.Result.self, from: try JSONEncoder().encode(status))
    #expect(round == status)
    let unknown = Data(#"{"state":"sleeping"}"#.utf8)
    #expect(try JSONDecoder().decode(HubLinkStatus.self, from: unknown).state == .offline)
  }
}
