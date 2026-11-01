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
  }

  private struct State {
    var sequence = 0
    var connections: [Connection] = []
    var threads: [ConversationThread] = []
    var projects: [Project] = []
    var reads: [String: ThreadRead.Result] = [:]
    var drafts: [String: Draft] = [:]
    var calls: [Call] = []
  }

  init() {
    (incoming, continuation) = AsyncStream.makeStream(of: Data.self)
    let hello = HelloEnvelope(
      epoch: epoch, sequence: 0, coordinator: CoordinatorIdentity(version: "t", pid: 1))
    continuation.yield(try! NDJSON.encodeLine(hello))
  }

  // Scripting

  func set(
    connections: [Connection]? = nil, threads: [ConversationThread]? = nil, projects: [Project]? = nil
  ) {
    state.withLock {
      if let connections { $0.connections = connections }
      if let threads { $0.threads = threads }
      if let projects { $0.projects = projects }
    }
  }

  func setRead(_ read: ThreadRead.Result) { state.withLock { $0.reads[read.thread.id] = read } }
  func setDraft(_ draft: Draft) { state.withLock { $0.drafts[draft.threadId] = draft } }

  func emit(_ event: AdapterEvent) {
    state.withLock { state in
      state.sequence += 1
      let envelope = EventEnvelope(epoch: epoch, sequence: state.sequence, event: event)
      continuation.yield(try! NDJSON.encodeLine(envelope))
    }
  }

  func calls(_ method: WorkspaceProtocol.Method) -> [JSONValue] {
    state.withLock { $0.calls.filter { $0.method == method.rawValue }.map(\.params) }
  }

  // Transport

  func send(_ line: Data) async throws {
    let envelope = try JSONCoding.decoder.decode(CommandEnvelope.self, from: line)
    let params = envelope.params ?? .object([:])
    let response: ResponseEnvelope = state.withLock { state in
      state.calls.append(Call(method: envelope.method, params: params))
      do {
        return .success(envelope.requestId, result: try answer(envelope.method, params, &state))
      } catch {
        return .failure(envelope.requestId, error: WorkspaceError.from(error))
      }
    }
    continuation.yield(try NDJSON.encodeLine(response))
  }

  func close() async { continuation.finish() }

  private func answer(_ method: String, _ params: JSONValue, _ state: inout State) throws -> JSONValue {
    switch WorkspaceProtocol.Method(rawValue: method) {
    case .eventsSnapshot?:
      return try JSONValue(
        encoding: EventsSnapshot.Result(
          epoch: epoch, sequence: state.sequence, connections: state.connections, threads: state.threads))
    case .projectList?:
      return try JSONValue(encoding: ProjectList.Result(projects: state.projects))
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
    case .projectRename?:
      let id = params["projectId"]?.stringValue ?? ""
      guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceError(.notFound, "no project \(id)")
      }
      state.projects[index].name = params["name"]?.stringValue ?? ""
      return try JSONValue(encoding: ProjectCreate.Result(project: state.projects[index]))
    case .projectCreate?:
      let project = Project(id: "p-new", name: params["name"]?.stringValue ?? "")
      state.projects.append(project)
      return try JSONValue(encoding: ProjectCreate.Result(project: project))
    case .projectUpdate?:
      let id = params["projectId"]?.stringValue ?? ""
      guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceError(.notFound, "no project \(id)")
      }
      return try JSONValue(encoding: ProjectCreate.Result(project: state.projects[index]))
    case .projectDelete?:
      let id = params["projectId"]?.stringValue ?? ""
      state.projects.removeAll { $0.id == id }
      return try JSONValue(encoding: ProjectDelete.Result(projectId: id))
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
  _ id: String, project: String? = nil, pinned: Bool = false, archived: Bool = false, title: String? = nil,
  readTurnId: String? = nil, activity: ThreadActivity? = nil
) -> ConversationThread {
  ConversationThread(
    id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: title ?? id, pinned: pinned,
    archived: archived, createdAt: minutes(0), updatedAt: minutes(0), projectId: project,
    readTurnId: readTurnId, activity: activity)
}

private func activity(
  turn: String? = nil, status: TurnStatus? = nil, outcome: TurnOutcome? = nil, pending: Int = 0, at: Int = 1
) -> ThreadActivity {
  ThreadActivity(
    latestTurnId: turn, latestTurnStatus: status, latestTurnOutcome: outcome, pendingRequests: pending,
    lastActivityAt: minutes(at))
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

private func project(_ id: String, _ name: String) -> Project { Project(id: id, name: name) }

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
private func connected(
  _ transport: ScriptedTransport, now: Date = Date(timeIntervalSince1970: 1_793_000_000 + 600)
) async throws -> WorkspaceModel {
  let model = WorkspaceModel(transportProvider: { transport })
  model.now = { now }
  model.connect()
  try await waitUntil("ready") { model.link == .ready }
  return model
}

/// The part of `attention.json` the model needs: threads with `activity` computed the way the stores do.
private struct AttentionDocument: Decodable {
  struct Expected: Decodable { var order: [String] }
  var connections: [Connection]
  var threads: [ConversationThread]
  var turns: [Turn]
  var runtimeRequests: [RuntimeRequest]
  var expected: Expected

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
        pendingRequests: requests.filter { $0.state == .pending }.count, lastActivityAt: stamps.max()!)
      return copy
    }
  }
}

// MARK: - Tests

@Suite(.serialized) @MainActor struct AttentionModelTests {
  @Test func ordersPinnedThenBandsThenActivity() async throws {
    let document = try AttentionDocument.load()
    let transport = ScriptedTransport()
    transport.set(connections: document.connections, threads: document.threadsWithActivity.reversed())
    let model = try await connected(transport)
    #expect(model.orderedThreads.map(\.id) == document.expected.order)
    #expect(model.pinnedThreads.map(\.id) == ["t-pinned-working", "t-pinned-quiet"])
    #expect(model.band(of: model.orderedThreads[2]) == .needsInput)
    #expect(model.visibleThreads.map(\.id) == document.expected.order)
  }

  @Test func projectSectionsExcludePinnedAndRiseWithUrgency() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread(
          "quiet-a", project: "pa", readTurnId: "u1",
          activity: activity(turn: "u1", status: .terminal, at: 50)),
        thread("quiet-a2", project: "pa", activity: activity(at: 40)),
        thread("waiting-b", project: "pb", activity: activity(pending: 1, at: 5)),
        thread("pinned-b", project: "pb", pinned: true, activity: activity(pending: 1, at: 90)),
        thread("loose", activity: activity(turn: "u2", status: .running, at: 30)),
        thread("unread-c", project: "pc", activity: activity(turn: "u3", status: .terminal, at: 20)),
        thread(
          "quiet-c", project: "pc", readTurnId: "u4",
          activity: activity(turn: "u4", status: .terminal, at: 99)),
      ],
      projects: [project("pa", "Alpha"), project("pb", "Beta"), project("pc", "Gamma")])
    let model = try await connected(transport)
    #expect(model.pinnedThreads.map(\.id) == ["pinned-b"])
    // Beta holds a thread that needs input; Gamma an unread one; Other a working one; Alpha only quiet.
    #expect(model.projectSections.map(\.id) == ["pb", "pc", "other", "pa"])
    #expect(model.projectSections.map(\.title) == ["Beta", "Gamma", "Other", "Alpha"])
    #expect(model.projectSections.flatMap(\.threads).map(\.id).contains("pinned-b") == false)
    #expect(model.projectSections[0].threads.map(\.id) == ["waiting-b"])
    #expect(model.projectSections[1].threads.map(\.id) == ["unread-c", "quiet-c"])
    #expect(model.projectSections[3].threads.map(\.id) == ["quiet-a", "quiet-a2"])
  }

  @Test func sectionsInOneBandBreakTiesByRecentActivityThenTitle() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread("a", project: "pa", activity: activity(at: 10)),
        thread("b", project: "pb", activity: activity(at: 20)),
        thread("c", project: "pc", activity: activity(at: 20)),
      ],
      projects: [project("pa", "Alpha"), project("pb", "Zulu"), project("pc", "Bravo")])
    let model = try await connected(transport)
    #expect(model.projectSections.map(\.title) == ["Bravo", "Zulu", "Alpha"])
  }

  @Test func aProjectWithoutAnExplicitNameShowsItsFolder() async throws {
    let transport = ScriptedTransport()
    let auto = Project(
      id: "pa", name: "",
      folders: [ProjectFolder(id: "f1", projectId: "pa", path: "/Users/brian/repos/b4app")])
    transport.set(threads: [thread("a", project: "pa")], projects: [auto])
    let model = try await connected(transport)
    #expect(model.projectSections.map(\.title) == ["b4app"])
  }

  @Test func projectFilterNarrowsTheList() async throws {
    let transport = ScriptedTransport()
    transport.set(
      threads: [
        thread("in-a", project: "pa", activity: activity(at: 3)),
        thread("in-b", project: "pb", activity: activity(at: 2)),
        thread("loose", activity: activity(at: 1)),
        thread("old", project: "pa", archived: true, activity: activity(at: 4)),
      ],
      projects: [project("pa", "Alpha"), project("pb", "Beta")])
    let model = try await connected(transport)
    #expect(model.projectFilter == .all)
    #expect(model.orderedThreads.map(\.id) == ["in-a", "in-b", "loose"])
    model.projectFilter = .project("pa")
    #expect(model.orderedThreads.map(\.id) == ["in-a"])
    model.projectFilter = .other
    #expect(model.orderedThreads.map(\.id) == ["loose"])
    model.projectFilter = .archived
    #expect(model.orderedThreads.map(\.id) == ["old"])
    model.projectFilter = .all
    model.searchText = "in-"
    #expect(model.orderedThreads.map(\.id) == ["in-a", "in-b"])
    model.searchText = ""
    #expect(model.archivedThreads.map(\.id) == ["old"])
  }

  @Test func openingAnUnreadThreadMarksItRead() async throws {
    let transport = ScriptedTransport()
    let unread = thread("t1", activity: activity(turn: "u1", status: .terminal, at: 2))
    transport.set(threads: [unread])
    transport.setRead(read(unread, turns: [turn("u0", in: "t1", at: 1), turn("u1", in: "t1", at: 2)]))
    let model = try await connected(transport)
    #expect(model.band(of: model.threads[0]) == .unread)

    await model.openThread(id: "t1")
    let sent = transport.calls(.threadMarkRead)
    #expect(sent.count == 1)
    #expect(sent.first?["threadId"]?.stringValue == "t1")
    #expect(sent.first?["turnId"]?.stringValue == "u1")
    // The row changes band at once, without waiting for an event.
    #expect(model.threads[0].readTurnId == "u1")
    #expect(model.band(of: model.threads[0]) == .quiet)

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
    #expect(model.band(of: model.threads[0]) == .working)
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
    try await Task.sleep(for: .milliseconds(100))
    #expect(transport.calls(.threadMarkRead).count == 1)
  }

  @Test func aReplyOnAnotherThreadIsNotMarkedRead() async throws {
    let transport = ScriptedTransport()
    let open = thread("t1", readTurnId: "u1", activity: activity(turn: "u1", status: .terminal, at: 2))
    let other = thread("t2", activity: activity(turn: "x1", status: .running, at: 2))
    transport.set(threads: [open, other])
    transport.setRead(read(open, turns: [turn("u1", in: "t1", at: 2)]))
    let model = try await connected(transport)
    await model.openThread(id: "t1")
    transport.emit(try finished(turn("x1", in: "t2", at: 2)))
    transport.emit(delta("t1"))  // a sentinel: events arrive in order
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
    #expect(model.band(of: model.threads[0]) == .unread)

    await model.openThread(id: "t1")
    #expect(transport.calls(.threadMarkRead).count == 2)
    #expect(transport.calls(.threadMarkRead).last?["turnId"]?.stringValue == "u1")
  }

  @Test func reasonLinesFollowTheBandAndTheRequestKind() async throws {
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
    WorkspaceModel.draftSaveDelay = .seconds(30)
    defer { WorkspaceModel.draftSaveDelay = .milliseconds(600) }
    let transport = ScriptedTransport()
    let t = thread("t1")
    transport.set(threads: [t])
    transport.setRead(read(t))
    let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    let model = WorkspaceModel(transportProvider: { transport })
    model.now = { clock.withLock { $0 } }
    model.connect()
    try await waitUntil("ready") { model.link == .ready }
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
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.composerText == "typing here")

    // Two seconds after the last keystroke the same event replaces it, and that does not save it back.
    clock.withLock { $0 = $0.addingTimeInterval(2) }
    let saves = transport.calls(.draftSave).count
    transport.emit(try .threadUpdated(renamed))
    try await waitUntil("replaced") { model.composerText == "from the phone" }
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.calls(.draftSave).count == saves)
  }

  @Test func aBurstOfDeltasSendsNoReadAndTurnEventsCoalesce() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1", activity: activity(turn: "u1", status: .running, at: 2))
    transport.set(threads: [t])
    transport.setRead(read(t, turns: [turn("u1", in: "t1", status: .running, at: 2)]))
    let model = try await connected(transport)
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
    try await Task.sleep(for: .milliseconds(500))
    #expect(transport.calls(.threadRead).count == baseline)
  }

  @Test func aTurnEventRefreshesTheRowsActivity() async throws {
    let transport = ScriptedTransport()
    let t = thread("t1", readTurnId: "u0", activity: activity(turn: "u0", status: .terminal, at: 1))
    transport.set(threads: [t])
    let model = try await connected(transport)
    #expect(model.band(of: model.threads[0]) == .quiet)

    var waiting = t
    waiting.activity = activity(turn: "u1", status: .waitingForUser, pending: 1, at: 3)
    transport.setRead(read(waiting, turns: [turn("u1", in: "t1", status: .waitingForUser, at: 3)]))
    transport.emit(
      AdapterEvent(
        kind: .runtimeRequestOpened, connectionId: "c1", threadId: "t1",
        payload: ["runtimeRequest": try JSONValue(encoding: request("r1", in: "t1", kind: .toolPermission))]))
    try await waitUntil("needs input") { model.band(of: model.threads[0]) == .needsInput }
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
    #expect(model.band(of: model.threads[0]) == .needsInput)
  }

  @Test func projectCommandsSendTheirParamsAndTheListFollowsProjectChanged() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [], projects: [project("pa", "Alpha")])
    let model = try await connected(transport)
    #expect(model.projects.map(\.id) == ["pa"])

    await model.renameProject(id: "pa", name: "Renamed")
    #expect(transport.calls(.projectRename).first?["projectId"]?.stringValue == "pa")
    #expect(transport.calls(.projectRename).first?["name"]?.stringValue == "Renamed")
    #expect(model.projects.first?.name == "Renamed")

    let created = await model.createProject(name: "New", folders: ["/Users/brian/x"])
    #expect(created?.id == "p-new")
    #expect(
      transport.calls(.projectCreate).first?["folders"]?.arrayValue?.compactMap(\.stringValue) == [
        "/Users/brian/x"
      ])
    #expect(model.projects.map(\.id).contains("p-new"))

    await model.addFolder(projectId: "pa", path: "/Users/brian/y")
    let update = try #require(transport.calls(.projectUpdate).first)
    #expect(update["projectId"]?.stringValue == "pa")
    #expect(update["addFolders"]?.arrayValue?.compactMap(\.stringValue) == ["/Users/brian/y"])

    model.projectFilter = .project("pa")
    await model.deleteProject(id: "pa")
    #expect(transport.calls(.projectDelete).first?["projectId"]?.stringValue == "pa")
    #expect(model.projects.map(\.id) == ["p-new"])
    #expect(model.projectFilter == .all)

    // An event from elsewhere (the other device renamed one) refetches the list.
    transport.set(projects: [project("p-new", "Elsewhere")])
    transport.emit(.projectChanged(projectId: "p-new"))
    try await waitUntil("refetched") { model.projects.first?.name == "Elsewhere" }
  }

  @Test func aRefusedProjectCommandSurfacesTheReason() async throws {
    let transport = ScriptedTransport()
    transport.set(threads: [], projects: [])
    let model = try await connected(transport)
    await model.renameProject(id: "missing", name: "x")
    #expect(model.lastError?.contains("no project missing") == true)
  }
}
