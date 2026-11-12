import Foundation
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// MARK: - A scripted coordinator

/// A coordinator the test scripts by hand: it answers the reads the model makes from tables the test
/// sets, writes down every command, and emits events on demand. No sockets, no store.
final class ScriptedTransport: WorkspaceTransport {
  let incoming: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let epoch = "scripted-epoch"
  private let state = Mutex(State())

  struct Call: Sendable {
    var method: String
    var params: JSONValue
    var operationId: String?
  }

  private struct State {
    var sequence = 0
    var connections: [Connection] = []
    var threads: [ConversationThread] = []
    var environments: [WorkEnvironment] = []
    var reads: [String: ThreadRead.Result] = [:]
    var drafts: [String: Draft] = [:]
    var calls: [Call] = []
    var hub = HubStatus.Result(joined: false, unsyncedChanges: 0)
    var hubLeaveError: WorkspaceError?
    var pair: Result<HubPair.Result, WorkspaceError> = .failure(
      WorkspaceError(.protocolInvalid, "Join a hub first"))
    /// `hub.pairStatus` answers these in order and then the last one again.
    var pairStatuses: [HubPairStatus.Result] = [HubPairStatus.Result(state: .none)]
    var keepAwake = true
    var settingsError: WorkspaceError?
    /// Scripted answers for commands the scripted tables do not serve (the relayed chat commands), in
    /// order, by method; a `.hold` keeps the request waiting until `release`.
    var replies: [String: [Reply]] = [:]
    var held: [(method: String, requestId: String)] = []
    /// What `events.snapshot` says of presence (the phone's transport fills it; the Mac's never does).
    var presence: PresenceSnapshot?
  }

  /// One scripted answer: a result, an error, or no answer until `release`.
  enum Reply: Sendable {
    case result(JSONValue)
    case failure(WorkspaceError)
    case hold
  }

  init() {
    (incoming, continuation) = AsyncStream.makeStream(of: Data.self)
    let hello = HelloEnvelope(
      epoch: epoch, sequence: 0, coordinator: CoordinatorIdentity(version: "t", pid: 1))
    continuation.yield(try! NDJSON.encodeLine(hello))
  }

  // Scripting

  func set(
    connections: [Connection]? = nil, threads: [ConversationThread]? = nil,
    environments: [WorkEnvironment]? = nil
  ) {
    state.withLock {
      if let connections { $0.connections = connections }
      if let threads { $0.threads = threads }
      if let environments { $0.environments = environments }
    }
  }

  /// What `hub.status` answers; `hub.leave` answers not joined, or throws `leaveError`.
  func setHub(_ status: HubStatus.Result, leaveError: WorkspaceError? = nil) {
    state.withLock {
      $0.hub = status
      $0.hubLeaveError = leaveError
    }
  }

  /// What `hub.pair` answers (a failure is thrown), and the `hub.pairStatus` answers in order.
  func setPairing(
    _ pair: Result<HubPair.Result, WorkspaceError>, statuses: [HubPairStatus.Result] = []
  ) {
    state.withLock {
      $0.pair = pair
      if !statuses.isEmpty { $0.pairStatuses = statuses }
    }
  }

  func setSettings(keepAwake: Bool, error: WorkspaceError? = nil) {
    state.withLock {
      $0.keepAwake = keepAwake
      $0.settingsError = error
    }
  }

  /// Every command recorded, with the `operationId` it carried.
  func recorded(_ method: WorkspaceProtocol.Method) -> [Call] {
    state.withLock { $0.calls.filter { $0.method == method.rawValue } }
  }

  func setPresence(_ presence: PresenceSnapshot?) { state.withLock { $0.presence = presence } }

  /// Answers for `method`, used in order; a method with none left is refused as unserved.
  func script(_ method: WorkspaceProtocol.Method, _ replies: [Reply]) {
    state.withLock { $0.replies[method.rawValue, default: []].append(contentsOf: replies) }
  }

  /// Answers the oldest held request for `method`; false when none is held.
  @discardableResult
  func release(_ method: WorkspaceProtocol.Method, with reply: Reply) -> Bool {
    let line: Data? = state.withLock { state in
      guard let index = state.held.firstIndex(where: { $0.method == method.rawValue }) else { return nil }
      let requestId = state.held.remove(at: index).requestId
      switch reply {
      case .result(let value):
        return try? NDJSON.encodeLine(ResponseEnvelope.success(requestId, result: value))
      case .failure(let error):
        return try? NDJSON.encodeLine(ResponseEnvelope.failure(requestId, error: error))
      case .hold: return nil
      }
    }
    guard let line else { return false }
    continuation.yield(line)
    return true
  }

  /// How many requests for `method` wait for `release`.
  func heldCount(_ method: WorkspaceProtocol.Method) -> Int {
    state.withLock { $0.held.filter { $0.method == method.rawValue }.count }
  }

  func setRead(_ read: ThreadRead.Result) { state.withLock { $0.reads[read.thread.id] = read } }
  func setDraft(_ draft: Draft) { state.withLock { $0.drafts[draft.threadId] = draft } }

  func emit(_ event: AdapterEvent) {
    state.withLock { state in
      state.sequence += 1
      let envelope = EventEnvelope(epoch: epoch, sequence: state.sequence, event: event)
      continuation.yield(try! NDJSON.encodeLine(envelope))
    }
    ConditionNudge.post()
  }

  /// Every command's method, in the order received.
  func methods() -> [String] { state.withLock { $0.calls.map(\.method) } }

  func calls(_ method: WorkspaceProtocol.Method) -> [JSONValue] {
    state.withLock { $0.calls.filter { $0.method == method.rawValue }.map(\.params) }
  }

  // Transport

  func send(_ line: Data) async throws {
    let envelope = try JSONCoding.decoder.decode(CommandEnvelope.self, from: line)
    let params = envelope.params ?? .object([:])
    let response: ResponseEnvelope? = state.withLock { state in
      state.calls.append(Call(method: envelope.method, params: params, operationId: envelope.operationId))
      if var queue = state.replies[envelope.method], !queue.isEmpty {
        let reply = queue.removeFirst()
        state.replies[envelope.method] = queue
        switch reply {
        case .result(let value): return .success(envelope.requestId, result: value)
        case .failure(let error): return .failure(envelope.requestId, error: error)
        case .hold:
          state.held.append((envelope.method, envelope.requestId))
          return nil
        }
      }
      do {
        return .success(envelope.requestId, result: try answer(envelope.method, params, &state))
      } catch {
        return .failure(envelope.requestId, error: WorkspaceError.from(error))
      }
    }
    if let response { continuation.yield(try NDJSON.encodeLine(response)) }
    // `waitUntil` cannot observe the call log, so it is told when the log grows.
    ConditionNudge.post()
  }

  func close() async { continuation.finish() }

  private func answer(_ method: String, _ params: JSONValue, _ state: inout State) throws -> JSONValue {
    switch WorkspaceProtocol.Method(rawValue: method) {
    case .eventsSnapshot?:
      return try JSONValue(
        encoding: EventsSnapshot.Result(
          epoch: epoch, sequence: state.sequence, connections: state.connections, threads: state.threads,
          presence: state.presence))
    case .environmentList?:
      return try JSONValue(encoding: EnvironmentList.Result(environments: state.environments))
    case .threadRead?:
      let id = params["threadId"]?.stringValue ?? ""
      guard let read = state.reads[id] else { throw WorkspaceError(.notFound, "no thread \(id)") }
      return try JSONValue(encoding: read)
    case .draftRead?:
      return try JSONValue(
        encoding: DraftRead.Result(draft: state.drafts[params["threadId"]?.stringValue ?? ""]))
    case .threadMarkRead?:
      let id = params["threadId"]?.stringValue ?? ""
      let turnId = params["turnId"]?.stringValue
      guard let index = state.threads.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceError(.notFound, "no thread \(id)")
      }
      state.threads[index].readTurnId = turnId
      state.reads[id]?.thread.readTurnId = turnId
      return try JSONValue(encoding: ThreadCreate.Result(thread: state.threads[index]))
    case .environmentRename?:
      let id = params["environmentId"]?.stringValue ?? ""
      guard let index = state.environments.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceError(.notFound, "no environment \(id)")
      }
      state.environments[index].name = params["name"]?.stringValue ?? ""
      return try JSONValue(encoding: EnvironmentCreate.Result(environment: state.environments[index]))
    case .environmentCreate?:
      let environment = WorkEnvironment(id: "p-new", name: params["name"]?.stringValue ?? "")
      state.environments.append(environment)
      return try JSONValue(encoding: EnvironmentCreate.Result(environment: environment))
    case .environmentUpdate?:
      let id = params["environmentId"]?.stringValue ?? ""
      guard let index = state.environments.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceError(.notFound, "no environment \(id)")
      }
      return try JSONValue(encoding: EnvironmentCreate.Result(environment: state.environments[index]))
    case .environmentDelete?:
      let id = params["environmentId"]?.stringValue ?? ""
      state.environments.removeAll { $0.id == id }
      return try JSONValue(encoding: EnvironmentDelete.Result(environmentId: id))
    case .hubStatus?:
      return try JSONValue(encoding: state.hub)
    case .hubLeave?:
      if let error = state.hubLeaveError { throw error }
      state.hub = HubStatus.Result(joined: false, unsyncedChanges: state.hub.unsyncedChanges)
      return try JSONValue(encoding: state.hub)
    case .hubPair?:
      return try JSONValue(encoding: try state.pair.get())
    case .hubPairStatus?:
      let next = state.pairStatuses.count > 1 ? state.pairStatuses.removeFirst() : state.pairStatuses[0]
      return try JSONValue(encoding: next)
    case .settingsRead?:
      return try JSONValue(encoding: SettingsRead.Result(keepAwake: state.keepAwake))
    case .settingsUpdate?:
      if let error = state.settingsError { throw error }
      if let value = params["keepAwake"]?.boolValue { state.keepAwake = value }
      return try JSONValue(encoding: SettingsRead.Result(keepAwake: state.keepAwake))
    default:
      throw WorkspaceError(.unsupportedCapability, "scripted transport does not serve \(method)")
    }
  }
}

// MARK: - Builders

private let t0 = "2026-10-31T10:00:00Z"

private func minutes(_ n: Int) -> String {
  Timestamp.string(from: Date(timeIntervalSince1970: 1_793_000_000 + Double(n) * 60))
}

private func thread(
  _ id: String, environment: String? = nil, pinned: Bool = false, archived: Bool = false,
  title: String? = nil,
  readTurnId: String? = nil, activity: ThreadActivity? = nil
) -> ConversationThread {
  ConversationThread(
    id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: title ?? id, pinned: pinned,
    archived: archived, createdAt: minutes(0), updatedAt: minutes(0), environmentId: environment,
    readTurnId: readTurnId, activity: activity)
}

private func activity(
  turn: String? = nil, status: TurnStatus? = nil, outcome: TurnOutcome? = nil, pending: Int = 0,
  approvals: Int = 0, at: Int = 1
) -> ThreadActivity {
  ThreadActivity(
    latestTurnId: turn, latestTurnStatus: status, latestTurnOutcome: outcome, pendingRequests: pending,
    pendingApprovals: approvals, lastActivityAt: minutes(at))
}

private func turn(
  _ id: String, in threadId: String, status: TurnStatus = .terminal, outcome: TurnOutcome? = .completed,
  at: Int = 1
) -> Turn {
  Turn(
    id: id, threadId: threadId, operationId: "op-\(id)", status: status, submission: .acknowledged,
    outcome: status == .terminal ? outcome : nil, createdAt: minutes(at), updatedAt: minutes(at))
}

private func read(
  _ thread: ConversationThread, turns: [Turn] = [], requests: [RuntimeRequest] = []
) -> ThreadRead.Result {
  ThreadRead.Result(thread: thread, turns: turns, items: [], requests: requests)
}

private func request(
  _ id: String, in threadId: String, kind: RuntimeRequestKind, state: RuntimeRequestState = .pending
) -> RuntimeRequest {
  RuntimeRequest(
    id: id, nativeRequestId: "n-\(id)", threadId: threadId, adapterGeneration: 1, kind: kind, state: state,
    payload: .object([:]), createdAt: minutes(1), updatedAt: minutes(1))
}

private func environment(_ id: String, _ name: String) -> WorkEnvironment {
  WorkEnvironment(id: id, name: name)
}

private func finished(_ turn: Turn) throws -> AdapterEvent {
  AdapterEvent(
    kind: .turnFinished, connectionId: "c1", threadId: turn.threadId, turnId: turn.id,
    payload: ["turn": try JSONValue(encoding: turn)])
}

private func delta(_ threadId: String) -> AdapterEvent {
  AdapterEvent(
    kind: .messageDelta, connectionId: "c1", threadId: threadId, nativeIds: ["itemId": "i1"],
    payload: ["delta": "x"])
}

@MainActor
/// A connected model. `onScreen` stands for the views: the open thread is in front of the owner.
private func connected(
  _ transport: ScriptedTransport, now: Date = Date(timeIntervalSince1970: 1_793_000_000 + 600),
  onScreen: Bool = true
) async throws -> WorkspaceModel {
  let model = WorkspaceModel(transportProvider: { transport })
  model.now = { now }
  model.isDetailOnScreen = onScreen
  model.connect()
  let link = await model.settledLink()
  try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
  return model
}

/// The part of `attention.json` the model needs: threads with `activity` computed the way the stores do.
private struct AttentionDocument: Decodable {
  var connections: [Connection]
  var threads: [ConversationThread]
  var turns: [Turn]
  var runtimeRequests: [RuntimeRequest]

  static func load(file: StaticString = #filePath) throws -> AttentionDocument {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/attention.json")
    return try JSONCoding.decoder.decode(AttentionDocument.self, from: Data(contentsOf: url))
  }

  var threadsWithActivity: [ConversationThread] {
    threads.map { thread in
      let own = turns.filter { $0.threadId == thread.id }
      let latest = own.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      let requests = runtimeRequests.filter { $0.threadId == thread.id }
      let stamps = [thread.createdAt] + [latest?.updatedAt].compactMap { $0 } + requests.map(\.updatedAt)
      var copy = thread
      copy.activity = ThreadActivity(
        latestTurnId: latest?.id, latestTurnStatus: latest?.status, latestTurnOutcome: latest?.outcome,
        pendingRequests: requests.filter { $0.state == .pending }.count,
        pendingApprovals: requests.filter { $0.state == .pending && $0.kind.isApproval }.count,
        lastActivityAt: stamps.max()!)
      return copy
    }
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct AttentionModelTests {
  /// By state, then pinned, then activity (decision 5): a pin lifts a thread only inside its state.
  @Test func ordersByStateThenPinThenActivity() async throws {
    let document = try AttentionDocument.load()
    let transport = ScriptedTransport()
    transport.set(connections: document.connections, threads: document.threadsWithActivity.reversed())
    let model = try await connected(transport)
    let expected = [
      "t-ask-request-late", "t-ask-turn-late", "t-failed-unread", "t-unread-b", "t-unread-a",
      "t-pinned-working", "t-equal-created", "t-latest-created", "t-working", "t-pinned-quiet",
      "t-completed-read", "t-no-turns", "t-tie-a", "t-tie-b", "t-stale-updated",
    ]
    #expect(model.orderedThreads.map(\.id) == expected)
    #expect(
      model.orderedThreads.prefix(5).map { model.state(of: $0) } == [
        .approve, .approve, .failed, .finished, .finished,
      ])
  }

  @Test func groupsHoldPinnedThreadsInStateOrderAndSortByName() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread(
          "quiet-a", environment: "pa", readTurnId: "u1",
          activity: activity(turn: "u1", status: .terminal, at: 50)),
        thread("quiet-a2", environment: "pa", activity: activity(at: 40)),
        thread("waiting-b", environment: "pb", activity: activity(pending: 1, at: 5)),
        thread("pinned-b", environment: "pb", pinned: true, activity: activity(pending: 1, at: 90)),
        thread("loose", activity: activity(turn: "u2", status: .running, at: 30)),
        thread("unread-c", environment: "pc", activity: activity(turn: "u3", status: .terminal, at: 20)),
        thread(
          "quiet-c", environment: "pc", readTurnId: "u4",
          activity: activity(turn: "u4", status: .terminal, at: 99)),
      ],
      environments: [environment("pa", "Alpha"), environment("pb", "Beta"), environment("pc", "Gamma")])
    let groups = try await byEnvironment(transport)
    // There is no Pinned group: a pinned thread stays in its environment, first within its state.
    // Groups are by name whatever their threads need; No folder is last.
    #expect(groups.map(\.id) == ["pa", "pb", "pc", "other"])
    #expect(groups.map(\.title) == ["Alpha", "Beta", "Gamma", "No folder"])
    #expect(groups[0].threads.map(\.id) == ["quiet-a", "quiet-a2"])
    #expect(groups[1].threads.map(\.id) == ["pinned-b", "waiting-b"])
    #expect(groups[2].threads.map(\.id) == ["unread-c", "quiet-c"])
    #expect(groups[3].threads.map(\.id) == ["loose"])
  }

  @Test func otherComesLastEvenWhenItHoldsTheOnlyThreadThatNeedsInput() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread("asks", activity: activity(pending: 1, at: 99)),
        thread("a", environment: "pa", activity: activity(at: 1)),
        thread("b", environment: "pb", activity: activity(at: 2)),
      ],
      environments: [environment("pa", "Alpha"), environment("pb", "Beta")])
    let groups = try await byEnvironment(transport)
    #expect(groups.map(\.id) == ["pa", "pb", "other"])
    #expect(groups.last?.threads.map(\.id) == ["asks"])
  }

  @Test func aNoFolderThreadIsListedUnderNoFolder() async throws {
    let transport = ScriptedTransport()
    var loose = thread("loose", activity: activity(at: 10))
    loose.context = "/Users/me/B4App/threads/loose"
    transport.set(
      threads: [loose, thread("a", environment: "pa", activity: activity(at: 5))],
      environments: [environment("pa", "Alpha")])
    let groups = try await byEnvironment(transport)
    let group = try #require(groups.first { $0.threads.contains { $0.id == "loose" } })
    #expect(group.title == "No folder")
    #expect(groups.map(\.title) == ["Alpha", "No folder"])
  }

  @Test func groupsSortByNameNotByRecentActivity() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread("a", environment: "pa", activity: activity(at: 10)),
        thread("b", environment: "pb", activity: activity(at: 20)),
        thread("c", environment: "pc", activity: activity(at: 20)),
      ],
      environments: [environment("pa", "Alpha"), environment("pb", "Zulu"), environment("pc", "Bravo")])
    #expect(try await byEnvironment(transport).map(\.title) == ["Alpha", "Bravo", "Zulu"])
  }

  @Test func aEnvironmentWithoutAnExplicitNameShowsItsFolder() async throws {
    let transport = ScriptedTransport()
    let auto = WorkEnvironment(
      id: "pa", name: "",
      folders: [EnvironmentFolder(id: "f1", environmentId: "pa", path: "/Users/brian/repos/b4app")])
    transport.set(threads: [thread("a", environment: "pa")], environments: [auto])
    #expect(try await byEnvironment(transport).map(\.title) == ["b4app"])
  }

  /// The connected model's groups under "By environment".
  private func byEnvironment(_ transport: ScriptedTransport) async throws -> [ListLayout.Group] {
    let model = try await connected(transport)
    transport.emit(try .viewSettingsChanged(ViewSettings(arrangement: .byEnvironment)))
    try await waitUntil("by environment") { model.viewSettings.arrangement == .byEnvironment }
    guard case .byEnvironment(let groups) = model.listLayout.body else { return [] }
    return groups
  }

  @Test func theListIsEveryUnarchivedThreadAndTheArchiveIsApart() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread("in-a", environment: "pa", activity: activity(at: 3)),
        thread("in-b", environment: "pb", activity: activity(at: 2)),
        thread("loose", activity: activity(at: 1)),
        thread("old", environment: "pa", archived: true, activity: activity(at: 4)),
      ],
      environments: [environment("pa", "Alpha"), environment("pb", "Beta")])
    let model = try await connected(transport)
    #expect(model.orderedThreads.map(\.id) == ["in-a", "in-b", "loose"])
    // The archive is drawn only while "Show archived" is on.
    #expect(model.listLayout.archived.isEmpty)
  }

  @Test func openingAnUnreadThreadMarksItRead() async throws {
    let transport = ScriptedTransport()
    let unread = thread("t1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.set(threads: [unread])
    transport.setRead(read(unread, turns: [turn("u0", in: "t1", at: 1), turn("u1", in: "t1", at: 2)]))
    let model = try await connected(transport)
    #expect(model.state(of: model.threads[0]) == .finished)

    await model.openThread(id: "t1")
    let sent = transport.calls(.threadMarkRead)
    #expect(sent.count == 1)
    #expect(sent.first?["threadId"]?.stringValue == "t1")
    #expect(sent.first?["turnId"]?.stringValue == "u1")
    // The row changes state at once, without waiting for an event.
    #expect(model.threads[0].readTurnId == "u1")
    #expect(model.state(of: model.threads[0]) == .quiet)

    model.selectedThreadId = nil
    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).count == 1)
  }

  @Test func aThreadWhoseLatestTurnIsStillRunningIsNeverMarkedRead() async throws {
    let transport = ScriptedTransport()
    let busy = thread("t1", readTurnId: "u0", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [busy])
    transport.setRead(
      read(busy, turns: [turn("u0", in: "t1", at: 1), turn("u1", in: "t1", status: .running, at: 2)]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).isEmpty)
    #expect(model.state(of: model.threads[0]) == .working)
  }

  @Test func aReadThreadIsNotMarkedAgain() async throws {
    let transport = ScriptedTransport()
    let seen = thread("t1", readTurnId: "u1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.set(threads: [seen])
    transport.setRead(read(seen, turns: [turn("u1", in: "t1", at: 2)]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).isEmpty)
  }

  @Test func aReplyArrivingWhileOpenIsMarkedRead() async throws {
    let transport = ScriptedTransport()
    let running = thread("t1", readTurnId: "u0", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [running])
    transport.setRead(
      read(running, turns: [turn("u0", in: "t1", at: 1), turn("u1", in: "t1", status: .running, at: 2)]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).isEmpty)

    let done = turn("u1", in: "t1", at: 2)
    transport.emit(try finished(done))
    try await waitUntil("marked") { transport.calls(.threadMarkRead).count == 1 }
    #expect(transport.calls(.threadMarkRead).first?["turnId"]?.stringValue == "u1")
    #expect(model.threads[0].readTurnId == "u1")

    // The refetch that follows the finish does not send a second one.
    transport.setRead(read(running, turns: [turn("u0", in: "t1", at: 1), done]))
    try await waitUntil("refetched") { transport.calls(.threadRead).count >= 2 }
    // Timed on purpose: a second mark must not follow; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(100))
    #expect(transport.calls(.threadMarkRead).count == 1)
  }

  @Test func aReplyArrivingWhileTheThreadIsNotOnScreenStaysUnreadUntilItIs() async throws {
    let transport = ScriptedTransport()
    let running = thread("t1", readTurnId: "u0", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [running])
    transport.setRead(
      read(running, turns: [turn("u0", in: "t1", at: 1), turn("u1", in: "t1", status: .running, at: 2)]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    // Back to the list on the iPhone, or the Mac's window put behind another app: the thread stays
    // loaded, but it is not in front of the owner.
    model.isDetailOnScreen = false

    let done = turn("u1", in: "t1", at: 2)
    var finishedThread = running
    finishedThread.activity = activity(turn: "u1", status: .terminal, at: 2)
    transport.set(threads: [finishedThread])
    transport.setRead(read(finishedThread, turns: [turn("u0", in: "t1", at: 1), done]))
    transport.emit(try finished(done))
    try await waitUntil("refetched") { transport.calls(.threadRead).count >= 2 }
    try await waitUntil("unread") { model.state(of: model.threads[0]) == .finished }
    // Timed on purpose: no mark may follow while off screen; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(100))
    #expect(transport.calls(.threadMarkRead).isEmpty)
    #expect(model.threads[0].readTurnId == "u0")

    // Coming back on screen marks the reply read, once.
    model.isDetailOnScreen = true
    try await waitUntil("marked") { transport.calls(.threadMarkRead).count == 1 }
    #expect(transport.calls(.threadMarkRead).first?["turnId"]?.stringValue == "u1")
    #expect(model.state(of: model.threads[0]) == .quiet)
    model.isDetailOnScreen = false
    model.isDetailOnScreen = true
    // Timed on purpose: a second mark must not follow; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(100))
    #expect(transport.calls(.threadMarkRead).count == 1)
  }

  @Test func openingAThreadThatIsNotOnScreenDoesNotMarkIt() async throws {
    let transport = ScriptedTransport()
    let unread = thread("t1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.set(threads: [unread])
    transport.setRead(read(unread, turns: [turn("u1", in: "t1", at: 2)]))
    let model = try await connected(transport, onScreen: false)
    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).isEmpty)
    #expect(model.state(of: model.threads[0]) == .finished)

  }

  @Test func aReplyOnAnotherThreadIsNotMarkedRead() async throws {
    let transport = ScriptedTransport()
    let open = thread("t1", readTurnId: "u1", activity: activity(turn: "u1", status: .terminal, at: 2))
    let other = thread("t2", activity: activity(turn: "x1", status: .running, at: 2))
    transport.set(threads: [open, other])
    transport.setRead(read(open, turns: [turn("u1", in: "t1", at: 2)]))
    let done = turn("x1", in: "t2", at: 2)
    var finishedOther = other
    finishedOther.activity = activity(turn: "x1", status: .terminal, at: 2)
    transport.setRead(read(finishedOther, turns: [done]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    transport.emit(try finished(done))
    // Wait for the refetch of t2 (it follows the event within the 200 ms window): it is now unread,
    // and still nothing is marked, because t2 is not the open thread.
    try await waitUntil("t2 refetched") {
      transport.calls(.threadRead).contains { $0["threadId"]?.stringValue == "t2" }
    }
    try await waitUntil("t2 unread") { model.state(of: model.threads.first { $0.id == "t2" }!) == .finished }
    // Timed on purpose: no mark may follow for t2; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(100))
    #expect(transport.calls(.threadMarkRead).isEmpty)
  }

  @Test func markUnreadClearsTheMarkerAndOpeningMarksItReadAgain() async throws {
    let transport = ScriptedTransport()
    let seen = thread("t1", readTurnId: "u1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.set(threads: [seen])
    transport.setRead(read(seen, turns: [turn("u1", in: "t1", at: 2)]))
    let model = try await connected(transport)
    await model.markUnread(id: "t1")
    let sent = transport.calls(.threadMarkRead)
    #expect(sent.count == 1)
    #expect(sent.first?["threadId"]?.stringValue == "t1")
    #expect(sent.first?["turnId"] == .null || sent.first?["turnId"] == nil)
    #expect(model.threads[0].readTurnId == nil)
    #expect(model.state(of: model.threads[0]) == .finished)

    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).count == 2)
    #expect(transport.calls(.threadMarkRead).last?["turnId"]?.stringValue == "u1")
  }

  @Test func reasonLinesFollowTheStateAndTheRequestKind() async throws {
    let transport = ScriptedTransport()
    let waiting = thread("wait", activity: activity(turn: "u1", status: .waitingForUser, pending: 1))
    let asked = thread("ask", activity: activity(turn: "u2", status: .waitingForUser, pending: 1))
    let replied = thread(
      "replied", activity: activity(turn: "u3", status: .terminal, outcome: .completed, at: 7))
    let failed = thread("failed", activity: activity(turn: "u4", status: .terminal, outcome: .failed, at: 7))
    let stopped = thread(
      "stopped", activity: activity(turn: "u5", status: .terminal, outcome: .cancelled, at: 7))
    let working = thread("working", activity: activity(turn: "u6", status: .running))
    let read1 = thread("read", readTurnId: "u7", activity: activity(turn: "u7", status: .terminal))
    let fresh = thread("fresh", activity: activity())
    let bare = thread("bare")
    transport.set(threads: [waiting, asked, replied, failed, stopped, working, read1, fresh, bare])
    transport.setRead(read(waiting, requests: [request("r1", in: "wait", kind: .commandApproval)]))
    transport.setRead(read(asked, requests: [request("r2", in: "ask", kind: .userQuestion)]))
    let model = try await connected(transport)  // now is ten minutes after `minutes(0)`

    // Without the open thread the list knows only that something is pending.
    #expect(model.reasonLine(for: waiting) == "Waiting for your input")
    await model.openThread(id: "wait")
    #expect(model.reasonLine(for: waiting) == "Waiting for your approval")
    await model.openThread(id: "ask")
    #expect(model.reasonLine(for: asked) == "Has a question for you")

    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let ago = formatter.localizedString(for: Timestamp.date(from: minutes(7))!, relativeTo: model.now())
    #expect(ago.contains("3"))
    #expect(model.reasonLine(for: replied) == "Replied \(ago)")
    #expect(model.reasonLine(for: failed) == "Failed \(ago)")
    #expect(model.reasonLine(for: stopped) == "Stopped \(ago)")
    #expect(model.reasonLine(for: working) == "Working")
    #expect(model.reasonLine(for: read1) == "Read")
    #expect(model.reasonLine(for: fresh) == "No messages yet")
    #expect(model.reasonLine(for: bare) == "No messages yet")
  }

  @Test func aReplyWhoseTimeCannotBeReadKeepsJustTheWord() async throws {
    let transport = ScriptedTransport()
    func odd(_ id: String, _ outcome: TurnOutcome) -> ConversationThread {
      var t = thread(id, activity: activity(turn: "u-\(id)", status: .terminal, outcome: outcome))
      t.activity?.lastActivityAt = "not a time"
      return t
    }
    let replied = odd("a", .completed)
    let failed = odd("b", .failed)
    let stopped = odd("c", .cancelled)
    transport.set(threads: [replied, failed, stopped])
    let model = try await connected(transport)
    #expect(model.reasonLine(for: replied) == "Replied")
    #expect(model.reasonLine(for: failed) == "Failed")
    #expect(model.reasonLine(for: stopped) == "Stopped")
  }

  @Test func everyRequestKindHasAReasonLine() async throws {
    let expected: [RuntimeRequestKind: String] = [
      .commandApproval: "Waiting for your approval", .fileChangeApproval: "Waiting for your approval",
      .toolPermission: "Waiting for your approval", .userQuestion: "Has a question for you",
      .elicitation: "Has a question for you", .unknown: "Waiting for your input",
    ]
    #expect(Set(expected.keys) == Set(RuntimeRequestKind.allCases))
    let transport = ScriptedTransport()
    let threads = expected.keys.map { kind in
      thread("t-\(kind.rawValue)", activity: activity(turn: "u1", status: .waitingForUser, pending: 1))
    }
    transport.set(threads: threads)
    for (kind, _) in expected {
      let id = "t-\(kind.rawValue)"
      transport.setRead(
        read(threads.first { $0.id == id }!, requests: [request("r-\(id)", in: id, kind: kind)]))
    }
    let model = try await connected(transport)
    for (kind, line) in expected {
      let id = "t-\(kind.rawValue)"
      await model.openThread(id: id)
      #expect(model.reasonLine(for: threads.first { $0.id == id }!) == line, "\(kind)")
    }
  }

  @Test func remoteDraftReloadsOnlyWhenIdle() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1")
    transport.set(threads: [t])
    transport.setRead(read(t))
    let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    let model = WorkspaceModel(transportProvider: { transport })
    model.draftSaveDelay = .seconds(30)
    model.now = { clock.withLock { $0 } }
    model.connect()
    let link = await model.settledLink()
    try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
    transport.setDraft(Draft(threadId: "t1", text: ""))
    await model.openThread(id: "t1")
    #expect(model.composerText == "")

    // Typing happened half a second ago: a draft arriving from elsewhere does not replace it.
    model.composerText = "typing here"
    clock.withLock { $0 = $0.addingTimeInterval(0.5) }
    transport.setDraft(Draft(threadId: "t1", text: "from the phone"))
    transport.emit(try .threadUpdated(t))
    var renamed = t
    renamed.title = "after"
    transport.emit(try .threadUpdated(renamed))  // events are ordered, so the one before has been applied
    try await waitUntil("later event applied") { model.threads.first?.title == "after" }
    // Timed on purpose: the draft must not be replaced; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.composerText == "typing here")

    // Two seconds after the last keystroke the same event replaces it, and that does not save it back.
    clock.withLock { $0 = $0.addingTimeInterval(2) }
    let saves = transport.calls(.draftSave).count
    transport.emit(try .threadUpdated(renamed))
    try await waitUntil("replaced") { model.composerText == "from the phone" }
    // Timed on purpose: no save may follow; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.calls(.draftSave).count == saves)
  }

  @Test func aBurstOfDeltasSendsNoReadAndTurnEventsCoalesce() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [t])
    transport.setRead(read(t, turns: [turn("u1", in: "t1", status: .running, at: 2)]))
    let model = try await connected(transport)
    // The model reads the 56 events on its own task; a slow runner can take longer than the
    // default 200 ms window to get through them, which would rightly start a second window.
    model.refetchDelay = .seconds(1)
    await model.openThread(id: "t1")
    let baseline = transport.calls(.threadRead).count

    for _ in 0..<50 { transport.emit(delta("t1")) }
    transport.emit(
      AdapterEvent(
        kind: .runtimeRequestOpened, connectionId: "c1", threadId: "t1",
        payload: ["runtimeRequest": try JSONValue(encoding: request("r1", in: "t1", kind: .commandApproval))])
    )
    for _ in 0..<5 {
      transport.emit(
        AdapterEvent(
          kind: .turnStateChanged, connectionId: "c1", threadId: "t1", turnId: "u1",
          payload: ["turn": try JSONValue(encoding: turn("u1", in: "t1", status: .running, at: 2))]))
    }
    try await waitUntil("one refetch") { transport.calls(.threadRead).count == baseline + 1 }
    // Timed on purpose: no second refetch may follow; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(400))
    #expect(transport.calls(.threadRead).count == baseline + 1)
  }

  @Test func deltasAloneNeverRefetch() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [t])
    transport.setRead(read(t, turns: [turn("u1", in: "t1", status: .running, at: 2)]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    let baseline = transport.calls(.threadRead).count
    for _ in 0..<20 { transport.emit(delta("t1")) }
    // Timed on purpose: no refetch may follow; an absence has no event to await.
    try await Task.sleep(for: .milliseconds(500))
    #expect(transport.calls(.threadRead).count == baseline)
  }

  @Test func aTurnEventRefreshesTheRowsActivity() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1", readTurnId: "u0", activity: activity(turn: "u0", status: .terminal, at: 1))
    transport.set(threads: [t])
    let model = try await connected(transport)
    #expect(model.state(of: model.threads[0]) == .quiet)

    var waiting = t
    waiting.activity = activity(turn: "u1", status: .waitingForUser, pending: 1, approvals: 1, at: 3)
    transport.setRead(read(waiting, turns: [turn("u1", in: "t1", status: .waitingForUser, at: 3)]))
    transport.emit(
      AdapterEvent(
        kind: .runtimeRequestOpened, connectionId: "c1", threadId: "t1",
        payload: ["runtimeRequest": try JSONValue(encoding: request("r1", in: "t1", kind: .toolPermission))]))
    try await waitUntil("approve") { model.state(of: model.threads[0]) == .approve }
  }

  @Test func aThreadUpdatedEventKeepsTheActivityItsPayloadLacks() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1", activity: activity(pending: 1, at: 2))
    transport.set(threads: [t])
    let model = try await connected(transport)
    var renamed = t
    renamed.title = "new"
    renamed.activity = nil
    transport.emit(try .threadUpdated(renamed))
    try await waitUntil("renamed") { model.threads.first?.title == "new" }
    #expect(model.threads.first?.activity?.pendingRequests == 1)
    #expect(model.state(of: model.threads[0]) == .reply)
  }

  @Test func environmentCommandsSendTheirParamsAndTheListFollowsEnvironmentChanged() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [], environments: [environment("pa", "Alpha")])
    let model = try await connected(transport)
    #expect(model.environments.map(\.id) == ["pa"])

    let alpha = try #require(model.environments.first)
    _ = await model.editEnvironment(alpha, name: "Renamed")
    #expect(transport.calls(.environmentRename).first?["environmentId"]?.stringValue == "pa")
    #expect(transport.calls(.environmentRename).first?["name"]?.stringValue == "Renamed")
    #expect(model.environments.first?.name == "Renamed")

    // A folder change is one update, the name left alone when it did not change.
    let renamed = try #require(model.environments.first)
    _ = await model.editEnvironment(renamed, name: renamed.name, addFolders: ["/Users/brian/y"])
    let update = try #require(transport.calls(.environmentUpdate).first)
    #expect(update["environmentId"]?.stringValue == "pa")
    #expect(update["addFolders"]?.arrayValue?.compactMap(\.stringValue) == ["/Users/brian/y"])
    #expect(update["name"] == nil || update["name"] == .null)

    // The form open on it closes when it is deleted.
    model.openEnvironmentForm(id: "pa")
    #expect(await model.deleteEnvironment(id: "pa") == nil)
    #expect(transport.calls(.environmentDelete).first?["environmentId"]?.stringValue == "pa")
    #expect(model.environments.isEmpty)
    #expect(model.editingEnvironmentId == nil)

    // An event from elsewhere (the other device renamed one) refetches the list.
    transport.set(environments: [environment("p-new", "Elsewhere")])
    transport.emit(.environmentChanged(environmentId: "p-new"))
    try await waitUntil("refetched") { model.environments.first?.name == "Elsewhere" }
  }

  @Test func theEnvironmentFormClosesForAThreadTheComposerOrItsEnvironmentGoing() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [thread("t1", environment: "pa")], environments: [environment("pa", "Alpha")])
    let model = try await connected(transport)
    model.openEnvironmentForm(id: "pa")
    #expect(model.editingEnvironmentId == "pa")
    await model.openThread(id: "t1")
    #expect(model.editingEnvironmentId == nil)

    // Done shows what was under it: the selection is untouched.
    let selected = model.selectedThreadId
    model.openEnvironmentForm(id: "pa")
    model.closeEnvironmentForm()
    #expect(model.editingEnvironmentId == nil && model.selectedThreadId == selected)

    model.openEnvironmentForm(id: "pa")
    await model.openNewThread()
    #expect(model.editingEnvironmentId == nil)

    // Deleted elsewhere (the phone, or emptied by a move): the list's refetch closes it.
    model.openEnvironmentForm(id: "pa")
    transport.set(environments: [])
    transport.emit(.environmentChanged(environmentId: "pa"))
    try await waitUntil("closed") { model.editingEnvironmentId == nil }
  }

  @Test func aRefusedEnvironmentCommandSurfacesTheReason() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [], environments: [])
    let model = try await connected(transport)
    let result = await model.editEnvironment(environment("missing", "Old"), name: "x")
    guard case .failure(let error) = result else {
      Issue.record("expected a failure")
      return
    }
    #expect(error.message.contains("no environment missing"))
    // The caller shows it; the model's banner is left alone.
    #expect(model.lastError == nil)
  }

  // MARK: Arrivals

  @Test func aFilterChangeTracesNothing() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread("a", environment: "pa", activity: activity(turn: "u1", status: .terminal, at: 2)),
        thread("b", environment: "pb", activity: activity(pending: 1, at: 3)),
        thread("c", environment: "pa", activity: activity(turn: "u2", status: .running, at: 1)),
      ],
      environments: [environment("pa", "Alpha"), environment("pb", "Beta")])
    let model = try await connected(transport)
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })

    // The list empties under the filter and comes back without it: no arrival.
    model.connectionFilter = "elsewhere"
    #expect(model.orderedThreads.isEmpty)
    model.connectionFilter = nil
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })

    // The list under the new filter is the baseline: a thread finishing after it still arrives.
    var done = model.threads.first { $0.id == "c" }!
    done.activity = activity(turn: "u2", status: .terminal, at: 4)
    transport.emit(try .threadUpdated(done))
    try await waitUntil("finished") {
      model.threads.contains { $0.id == "c" && model.state(of: $0) == .finished }
    }
    #expect(model.arrival(for: done)?.laps == true)
  }

  @Test func aThreadFinishingWhileTheListShowsArrives() async throws {
    let transport = ScriptedTransport()
    let running = thread("t1", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [running, thread("t2", activity: activity(turn: "u0", status: .terminal, at: 1))])
    let now = Date(timeIntervalSince1970: 1_793_000_000 + 600)
    let model = try await connected(transport, now: now)
    // On the first load a finished thread is already there: it did not arrive.
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })

    var done = running
    done.activity = activity(turn: "u1", status: .terminal, at: 3)
    transport.emit(try .threadUpdated(done))
    try await waitUntil("finished") { model.state(of: model.threads.first { $0.id == "t1" }!) == .finished }
    #expect(model.arrival(for: done) == Arrival(threadId: "t1", at: now, laps: true))
    #expect(model.arrival(for: model.threads.first { $0.id == "t2" }!) == nil)

    // Ten seconds on, it is over.
    model.now = { now.addingTimeInterval(10) }
    #expect(model.arrival(for: done) == nil)
  }

  @Test func theListRebuiltAfterSignInTracesNothing() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [thread("t1", activity: activity(turn: "u1", status: .running, at: 2))])
    let model = try await connected(transport)

    // Signed out and in again: every thread of the new list is new, and none of them arrived.
    model.forgetWorkspace()
    transport.set(threads: [
      thread("t1", activity: activity(turn: "u1", status: .terminal, at: 3)),
      thread("t2", activity: activity(pending: 1, approvals: 1, at: 3)),
    ])
    try await model.refreshSnapshot()
    #expect(model.threads.count == 2)
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })
  }

  /// A connected model whose "live" thread has just arrived (running → finished), so each test can
  /// check that the owner's own action leaves that trace alone.
  private func modelWithALiveTrace(
    _ transport: ScriptedTransport, others: [ConversationThread], environments: [WorkEnvironment] = []
  ) async throws -> WorkspaceModel {
    let running = thread("live", activity: activity(turn: "l1", status: .running, at: 2))
    transport.set(threads: [running] + others, environments: environments)
    let model = try await connected(transport)
    var done = running
    done.activity = activity(turn: "l1", status: .terminal, at: 3)
    transport.emit(try .threadUpdated(done))
    try await waitUntil("live arrived") { model.threads.contains { $0.id == "live" && liveArrival(model) } }
    return model
  }

  @Test func aNewArrangementOrShowArchivedRebasesTheArrivals() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithALiveTrace(transport, others: [])
    // Another list, not a changed one: the live trace ends, as on a filter change.
    transport.emit(try .viewSettingsChanged(ViewSettings(arrangement: .byEnvironment)))
    try await waitUntil("rearranged") { model.viewSettings.arrangement == .byEnvironment }
    #expect(!liveArrival(model))

    let other = ScriptedTransport()
    let shown = try await modelWithALiveTrace(other, others: [])
    other.script(.viewSettingsSet, [.result(try JSONValue(encoding: ViewSettings(showArchived: true)))])
    await shown.setShowArchived(true)
    #expect(!liveArrival(shown))

    // How quiet threads are drawn changes no list: the trace goes on.
    let third = ScriptedTransport()
    let quiet = try await modelWithALiveTrace(third, others: [])
    third.emit(try .viewSettingsChanged(ViewSettings(quietThreads: .hidden)))
    try await waitUntil("quiet hidden") { quiet.viewSettings.quietThreads == .hidden }
    #expect(liveArrival(quiet))
  }

  @Test func aStowedThreadThatStartsNeedingYouArrivesInTheTopList() async throws {
    let transport = ScriptedTransport()
    let running = thread("w", activity: activity(turn: "u1", status: .running, at: 2))
    let quiet = thread("q", readTurnId: "u2", activity: activity(turn: "u2", status: .terminal, at: 1))
    transport.set(threads: [running, quiet])
    let model = try await connected(transport)
    transport.emit(try .viewSettingsChanged(ViewSettings(quietThreads: .collapsed)))
    try await waitUntil("collapsed") { model.viewSettings.quietThreads == .collapsed }
    #expect(
      model.listLayout.body
        == .needsYouFirst(top: [], lower: .collapsed(count: 2, working: 1, threads: [running, quiet])))
    // Opening or closing the stowed rows, or drawing them another way, moves no thread into the top list.
    transport.emit(try .viewSettingsChanged(ViewSettings(quietThreads: .hidden)))
    try await waitUntil("hidden") { model.viewSettings.quietThreads == .hidden }
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })

    // The stowed working thread asks for an approval: it is in the top list at once, and it arrived.
    var asks = running
    asks.activity = activity(pending: 1, approvals: 1, at: 3)
    transport.emit(try .threadUpdated(asks))
    try await waitUntil("asks") { model.threads.contains { $0.id == "w" && model.state(of: $0) == .approve } }
    guard case .needsYouFirst(let top, let lower) = model.listLayout.body else {
      Issue.record("needs you first: \(model.listLayout.body)")
      return
    }
    #expect(top.map(\.id) == ["w"])
    #expect(lower == .hidden(working: []))
    #expect(model.arrival(for: asks)?.laps == true)
  }

  // MARK: The selected thread holds its place (C6)

  /// "a" asks for an approval, "t1" and "f" are finished and unread, "q" is quiet; "t1" opens with its
  /// reply on screen, so opening it marks it read.
  private func modelWithAFinishedThread(
    _ transport: ScriptedTransport, environment: String? = nil, environments: [WorkEnvironment] = []
  ) async throws -> WorkspaceModel {
    let finishedThread = thread(
      "t1", environment: environment, activity: activity(turn: "u1", status: .terminal, at: 4))
    transport.set(
      threads: [
        thread("a", environment: environment, activity: activity(pending: 1, approvals: 1, at: 5)),
        finishedThread,
        thread("f", environment: environment, activity: activity(turn: "uf", status: .terminal, at: 3)),
        thread(
          "q", environment: environment, readTurnId: "uq",
          activity: activity(turn: "uq", status: .terminal, at: 9)),
      ],
      environments: environments)
    transport.setRead(read(finishedThread, turns: [turn("u1", in: "t1", at: 4)]))
    transport.setRead(read(thread("f"), turns: [turn("uf", in: "f", at: 3)]))
    transport.setRead(read(thread("q", readTurnId: "uq"), turns: [turn("uq", in: "q", at: 9)]))
    return try await connected(transport)
  }

  private func topList(_ model: WorkspaceModel) -> [String] {
    guard case .needsYouFirst(let top, _) = model.listLayout.body else { return [] }
    return top.map(\.id)
  }

  @Test func aFinishedThreadOpenedAndReadKeepsItsSlotUntilTheSelectionMoves() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(transport)
    #expect(topList(model) == ["a", "t1", "f"])
    let badge = model.threads.filter(Attention.countsTowardBadge).map(\.id)
    #expect(badge == ["a", "t1", "f"])

    await model.openThread(id: "t1")
    let t1 = try #require(model.threads.first { $0.id == "t1" })
    #expect(t1.readTurnId == "u1")
    // Its state is the real one (quiet, so no mark and a quiet title) and the badge no longer counts it,
    // but it keeps its slot in the top list.
    #expect(model.state(of: t1) == .quiet)
    #expect(Attention.state(of: t1) == .quiet)
    #expect(model.threads.filter(Attention.countsTowardBadge).map(\.id) == ["a", "f"])
    #expect(topList(model) == ["a", "t1", "f"])

    // Another thread selected: the hold is released and "t1" takes its real place, without tracing
    // itself or any row that shifted.
    await model.openThread(id: "q")
    #expect(topList(model) == ["a", "f"])
    guard case .needsYouFirst(_, .rows(let lower, _)) = model.listLayout.body else {
      Issue.record("Small: \(model.listLayout.body)")
      return
    }
    #expect(lower.map(\.id) == ["q", "t1"])
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })
  }

  /// The hold lasts while the selected thread's detail column shows. On a compact phone, going back to
  /// the list releases it (the thread takes its real place, nothing traces), and showing the detail
  /// again starts a fresh hold from the thread's state now, not the old one.
  @Test func onACompactPhoneGoingBackToTheListReleasesTheHold() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(transport)
    await model.openThread(id: "t1")
    #expect(model.state(of: try #require(model.threads.first { $0.id == "t1" })) == .quiet)
    #expect(topList(model) == ["a", "t1", "f"])

    // Back to the list: the detail column and the detail leave the screen; "t1" stays selected.
    model.isDetailColumnShown = false
    model.isDetailOnScreen = false
    #expect(model.selectedThreadId == "t1")
    #expect(topList(model) == ["a", "f"])
    guard case .needsYouFirst(_, .rows(let lower, _)) = model.listLayout.body else {
      Issue.record("Small: \(model.listLayout.body)")
      return
    }
    #expect(lower.map(\.id) == ["q", "t1"])
    #expect(model.threads.allSatisfy { model.arrival(for: $0) == nil })

    // Reopened: a fresh hold from its state now (quiet), not the finished one it had.
    model.isDetailColumnShown = true
    model.isDetailOnScreen = true
    await model.openThread(id: "t1")
    #expect(topList(model) == ["a", "f"])
  }

  /// On the Mac the detail column always shows: the window losing focus (the detail no longer in front
  /// of the owner) keeps the hold.
  @Test func anInactiveMacWindowKeepsTheHold() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(transport)
    await model.openThread(id: "t1")
    model.isDetailOnScreen = false
    #expect(topList(model) == ["a", "t1", "f"])
    model.isDetailOnScreen = true
    #expect(topList(model) == ["a", "t1", "f"])
  }

  @Test func everyWayTheSelectionGoesReleasesTheHold() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(transport)
    await model.openThread(id: "t1")
    #expect(topList(model) == ["a", "t1", "f"])
    // The new-thread composer selects nothing.
    await model.openNewThread()
    #expect(topList(model) == ["a", "f"])

    // Selecting it again starts a new hold from its state now (quiet): nothing to hold.
    model.selectedThreadId = "t1"
    #expect(topList(model) == ["a", "f"])

    // A row selects before it opens (`ThreadRow`); the open that follows keeps the same hold.
    model.selectedThreadId = "f"
    await model.openThread(id: "f")
    #expect(model.state(of: try #require(model.threads.first { $0.id == "f" })) == .quiet)
    #expect(topList(model) == ["a", "f"])
    // Archiving the selected thread drops its hold: it is no longer in the live list.
    var archived = try #require(model.threads.first { $0.id == "f" })
    archived.archived = true
    transport.emit(try .threadUpdated(archived))
    try await waitUntil("archived") { model.threads.contains { $0.id == "f" && $0.archived } }
    #expect(topList(model) == ["a"])
    archived.archived = false
    transport.emit(try .threadUpdated(archived))
    try await waitUntil("unarchived") { model.threads.contains { $0.id == "f" && !$0.archived } }
    // Back in the live list while still selected, it starts a new hold from its state now: quiet.
    #expect(topList(model) == ["a"])
    // Signing out drops it with everything else.
    model.forgetWorkspace()
    #expect(model.selectedThreadId == nil)
    #expect(model.threads.isEmpty)
  }

  @Test func aHeldThreadUnderCollapsedIsNotStowedUntilReleased() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(transport)
    transport.emit(try .viewSettingsChanged(ViewSettings(quietThreads: .collapsed)))
    try await waitUntil("collapsed") { model.viewSettings.quietThreads == .collapsed }
    await model.openThread(id: "t1")
    guard
      case .needsYouFirst(let top, .collapsed(let count, _, let stowed, let selected)) = model.listLayout.body
    else {
      Issue.record("Collapsed: \(model.listLayout.body)")
      return
    }
    #expect(top.map(\.id) == ["a", "t1", "f"])
    #expect(count == 1)
    #expect(stowed.map(\.id) == ["q"])
    #expect(selected == nil)

    model.selectedThreadId = nil
    guard case .needsYouFirst(let after, .collapsed(let count, _, let stowed, nil)) = model.listLayout.body
    else {
      Issue.record("Collapsed, released: \(model.listLayout.body)")
      return
    }
    #expect(after.map(\.id) == ["a", "f"])
    #expect(count == 2)
    #expect(stowed.map(\.id) == ["q", "t1"])
  }

  @Test func aHeldThreadThatAsksAgainMovesUpWithinTheTopList() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(transport)
    await model.openThread(id: "t1")
    #expect(topList(model) == ["a", "t1", "f"])

    // A new approval on the held (now read) thread: approve, newer than "a", so it leads.
    var asks = try #require(model.threads.first { $0.id == "t1" })
    asks.activity = activity(turn: "u1", status: .terminal, pending: 1, approvals: 1, at: 6)
    transport.emit(try .threadUpdated(asks))
    try await waitUntil("asks") {
      model.threads.contains { $0.id == "t1" && model.state(of: $0) == .approve }
    }
    #expect(topList(model) == ["t1", "a", "f"])

    // The approval answered, it is quiet again; the hold is now approve, so it stays first.
    var answered = asks
    answered.activity = activity(turn: "u1", status: .terminal, at: 7)
    transport.emit(try .threadUpdated(answered))
    try await waitUntil("answered") {
      model.threads.contains { $0.id == "t1" && model.state(of: $0) == .quiet }
    }
    #expect(topList(model) == ["t1", "a", "f"])
  }

  @Test func underByEnvironmentAHeldThreadKeepsItsPlaceInItsGroup() async throws {
    let transport = ScriptedTransport()
    let model = try await modelWithAFinishedThread(
      transport, environment: "pa", environments: [environment("pa", "Alpha")])
    transport.emit(try .viewSettingsChanged(ViewSettings(arrangement: .byEnvironment)))
    try await waitUntil("by environment") { model.viewSettings.arrangement == .byEnvironment }
    func order() -> [String] {
      guard case .byEnvironment(let groups) = model.listLayout.body else { return [] }
      return groups.flatMap(\.threads).map(\.id)
    }
    #expect(order() == ["a", "t1", "f", "q"])
    await model.openThread(id: "t1")
    #expect(order() == ["a", "t1", "f", "q"])
    model.selectedThreadId = nil
    #expect(order() == ["a", "f", "q", "t1"])
  }

  private func liveArrival(_ model: WorkspaceModel) -> Bool {
    model.threads.first { $0.id == "live" }.map { model.arrival(for: $0) != nil } ?? false
  }

  @Test func markAsUnreadDoesNotTrace() async throws {
    let transport = ScriptedTransport()
    let seen = thread("t1", readTurnId: "u1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.setRead(read(seen, turns: [turn("u1", in: "t1", at: 2)]))
    let model = try await modelWithALiveTrace(transport, others: [seen])
    await model.markUnread(id: "t1")
    let unread = try #require(model.threads.first { $0.id == "t1" })
    #expect(model.state(of: unread) == .finished)
    #expect(model.arrival(for: unread) == nil)
    #expect(liveArrival(model))
  }

  @Test func aMarkReadRollbackDoesNotTrace() async throws {
    let transport = ScriptedTransport()
    let unread = thread("t1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.setRead(read(unread, turns: [turn("u1", in: "t1", at: 2)]))
    transport.script(.threadMarkRead, [.failure(WorkspaceError(.endpointUnavailable, "offline"))])
    let model = try await modelWithALiveTrace(transport, others: [unread])
    // Opening marks it read at once (quiet); the refused mark puts it back (finished).
    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).count == 1)
    let back = try #require(model.threads.first { $0.id == "t1" })
    #expect(model.state(of: back) == .finished)
    #expect(model.arrival(for: back) == nil)
    #expect(liveArrival(model))
  }

  @Test func unarchivingATopListThreadDoesNotTrace() async throws {
    let transport = ScriptedTransport()
    let archived = thread("t1", archived: true, activity: activity(pending: 1, approvals: 1, at: 2))
    let model = try await modelWithALiveTrace(transport, others: [archived])
    var back = archived
    back.archived = false
    transport.emit(try .threadUpdated(back))
    try await waitUntil("unarchived") { model.orderedThreads.contains { $0.id == "t1" } }
    #expect(model.arrival(for: back) == nil)
    #expect(liveArrival(model))
  }

  @Test func aThreadMovingIntoNoFolderDoesNotTraceOnTheNextEvent() async throws {
    let transport = ScriptedTransport()
    let filed = thread("t1", environment: "pa", activity: activity(turn: "u1", status: .terminal, at: 2))
    let other = thread("t2", activity: activity(turn: "u2", status: .running, at: 1))
    let model = try await modelWithALiveTrace(
      transport, others: [filed, other], environments: [environment("pa", "Alpha")])
    // A trace that starts before the refresh, so the refresh can be seen to leave it alone.
    var otherDone = other
    otherDone.activity = activity(turn: "u2", status: .terminal, at: 4)
    transport.emit(try .threadUpdated(otherDone))
    try await waitUntil("t2 arrived") {
      model.threads.contains { $0.id == "t2" && model.arrival(for: $0) != nil }
    }

    // Its environment goes away elsewhere: the thread is now under "No folder".
    transport.set(environments: [])
    transport.emit(.environmentChanged(environmentId: "pa"))
    try await waitUntil("environments refetched") { model.environments.isEmpty }
    #expect(model.orderedThreads.contains { $0.id == "t1" })

    // The next event about any thread does not make it an arrival.
    var renamed = model.threads.first { $0.id == "live" }!
    renamed.title = "renamed"
    transport.emit(try .threadUpdated(renamed))
    try await waitUntil("renamed") { model.threads.contains { $0.title == "renamed" } }
    #expect(model.arrival(for: model.threads.first { $0.id == "t1" }!) == nil)
    #expect(model.arrival(for: model.threads.first { $0.id == "t2" }!) != nil)
  }

  @Test func aThreadMovingIntoNoFolderUnderByEnvironmentDoesNotTrace() async throws {
    let transport = ScriptedTransport()
    let filed = thread("t1", environment: "pa", activity: activity(turn: "u1", status: .terminal, at: 2))
    let other = thread("t2", activity: activity(turn: "u2", status: .running, at: 1))
    let model = try await modelWithALiveTrace(
      transport, others: [filed, other], environments: [environment("pa", "Alpha")])
    transport.emit(try .viewSettingsChanged(ViewSettings(arrangement: .byEnvironment)))
    try await waitUntil("by environment") { model.viewSettings.arrangement == .byEnvironment }
    func groups() -> [String: [String]] {
      guard case .byEnvironment(let groups) = model.listLayout.body else { return [:] }
      return Dictionary(uniqueKeysWithValues: groups.map { ($0.title, $0.threads.map(\.id)) })
    }
    #expect(groups()["Alpha"] == ["t1"])
    // A trace that starts under this arrangement, so the regrouping can be seen to leave it alone.
    var otherDone = other
    otherDone.activity = activity(turn: "u2", status: .terminal, at: 4)
    transport.emit(try .threadUpdated(otherDone))
    try await waitUntil("t2 arrived") {
      model.threads.contains { $0.id == "t2" && model.arrival(for: $0) != nil }
    }

    // Its environment is deleted elsewhere: t1 moves from Alpha's group to "No folder".
    transport.set(environments: [])
    transport.emit(.environmentChanged(environmentId: "pa"))
    try await waitUntil("environments refetched") { model.environments.isEmpty }
    #expect(groups()["Alpha"] == nil)
    #expect(groups()["No folder"]?.contains("t1") == true)
    #expect(model.arrival(for: model.threads.first { $0.id == "t1" }!) == nil)

    // Nor on the next event about any thread.
    var renamed = model.threads.first { $0.id == "live" }!
    renamed.title = "renamed"
    transport.emit(try .threadUpdated(renamed))
    try await waitUntil("renamed") { model.threads.contains { $0.title == "renamed" } }
    #expect(model.arrival(for: model.threads.first { $0.id == "t1" }!) == nil)
    #expect(model.arrival(for: model.threads.first { $0.id == "t2" }!) != nil)
  }

  // MARK: The open thread's acknowledgement

  private static let approving = thread("ap", activity: activity(pending: 1, approvals: 1, at: 2))

  /// The approving thread with a second approval, later.
  private static func newActivity(on thread: ConversationThread) -> ConversationThread {
    var later = thread
    later.activity = activity(pending: 2, approvals: 2, at: 5)
    return later
  }

  @Test func theOpenThreadStaysAcknowledgedWhenNewActivityArrives() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [Self.approving, thread("other")])
    transport.setRead(read(Self.approving))
    let model = try await connected(transport)
    await model.openThread(id: "ap")
    let later = Self.newActivity(on: Self.approving)
    // The refetch that follows the event reads the same.
    transport.setRead(read(later))
    transport.emit(try .threadUpdated(later))
    try await waitUntil("new activity") {
      model.threads.first { $0.id == "ap" }?.activity?.lastActivityAt == later.activity?.lastActivityAt
    }
    #expect(model.isAcknowledged(model.threads.first { $0.id == "ap" }!))

    // Still acknowledged once the owner moves on to another thread.
    transport.setRead(read(thread("other")))
    await model.openThread(id: "other")
    #expect(model.selectedThreadId == "other")
    #expect(model.isAcknowledged(model.threads.first { $0.id == "ap" }!))
  }

  @Test func aSelectedThreadNotOnScreenIsNotAcknowledgedByNewActivity() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [Self.approving])
    transport.setRead(read(Self.approving))
    // The phone's list is showing, or the Mac's window is behind another app.
    let model = try await connected(transport, onScreen: false)
    await model.openThread(id: "ap")
    #expect(model.isAcknowledged(model.threads[0]))
    let later = Self.newActivity(on: Self.approving)
    // The refetch that follows the event reads the same.
    transport.setRead(read(later))
    transport.emit(try .threadUpdated(later))
    try await waitUntil("new activity") {
      model.threads[0].activity?.lastActivityAt == later.activity?.lastActivityAt
    }
    #expect(model.selectedThreadId == "ap")
    #expect(!model.isAcknowledged(model.threads[0]))
  }
}
