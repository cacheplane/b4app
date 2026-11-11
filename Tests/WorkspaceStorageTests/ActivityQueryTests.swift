import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// `Tests/Fixtures/sync/attention.json`, the file the protocol tests, the hub, and the mirror also read.
private struct AttentionRows: Decodable {
  struct Expected: Decodable {
    var bands: [String: String]
    var order: [String]
  }
  var connections: [Connection]
  var threads: [ConversationThread]
  var turns: [Turn]
  var runtimeRequests: [RuntimeRequest]
  var expected: Expected

  static func load(file: StaticString = #filePath) throws -> AttentionRows {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/attention.json")
    return try JSONCoding.decoder.decode(AttentionRows.self, from: Data(contentsOf: url))
  }

  func store() throws -> WorkspaceDatabase {
    let db = try WorkspaceDatabase.temporary()
    for connection in connections { _ = try db.insertConnection(connection) }
    for thread in threads { _ = try db.insertThread(thread) }
    for turn in turns { _ = try db.insertTurn(turn) }
    for request in runtimeRequests { _ = try db.insertRuntimeRequest(request) }
    return db
  }
}

/// The fixture's band name for a state (approve and reply were "needs input", failed and finished
/// "unread"; the fixture has no read failure).
private func bandName(_ state: ThreadState) -> String {
  switch state {
  case .approve, .reply: "needsInput"
  case .failed, .finished: "unread"
  case .working: "working"
  case .quiet: "quiet"
  }
}

/// The fixture's pinned-first `order`, stably re-sorted by state and then pin (decision 5): inside one
/// (state, pin) group the fixture's activity-and-id order still decides.
private func stateOrder(_ order: [String], threads: [ConversationThread]) -> [String] {
  let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
  return order.enumerated().sorted { lhs, rhs in
    let (l, r) = (byId[lhs.element]!, byId[rhs.element]!)
    let (ls, rs) = (Attention.state(of: l), Attention.state(of: r))
    if ls != rs { return ls < rs }
    if l.pinned != r.pinned { return l.pinned }
    return lhs.offset < rhs.offset
  }.map(\.element)
}

private func request(
  _ id: String, kind: RuntimeRequestKind, state: RuntimeRequestState = .pending,
  at: String = "2026-10-31T09:10:00Z"
) -> RuntimeRequest {
  RuntimeRequest(
    id: id, nativeRequestId: "n-\(id)", threadId: "t1", adapterGeneration: 1, kind: kind, state: state,
    payload: [:], createdAt: at, updatedAt: at)
}

private func seed(_ db: WorkspaceDatabase, turns: [Turn] = []) throws {
  _ = try db.insertConnection(
    Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
  _ = try db.insertThread(
    ConversationThread(
      id: "t1", connectionId: "c1", nativeThreadId: "n1", title: "First", context: "/tmp/p",
      createdAt: "2026-10-31T09:00:00Z", updatedAt: "2026-10-31T09:00:00Z"))
  for turn in turns { _ = try db.insertTurn(turn) }
}

private func turn(
  _ id: String, status: TurnStatus = .terminal, outcome: TurnOutcome? = .completed, created: String,
  updated: String? = nil
) -> Turn {
  Turn(
    id: id, threadId: "t1", operationId: "op-\(id)", status: status, submission: .acknowledged,
    outcome: outcome, createdAt: created, updatedAt: updated ?? created)
}

@Suite struct ActivityQueryTests {
  @Test func activityMatchesTheSharedFixture() throws {
    let fixture = try AttentionRows.load()
    let db = try fixture.store()
    let threads = try db.listThreads(ThreadFilter(includeArchived: true))
    #expect(threads.count == fixture.threads.count)
    #expect(threads.allSatisfy { $0.activity != nil })
    for thread in threads {
      #expect(bandName(Attention.state(of: thread)) == fixture.expected.bands[thread.id], "\(thread.id)")
    }
    #expect(
      Attention.ordered(threads).map(\.id) == stateOrder(fixture.expected.order, threads: threads))
    // A single thread reads the same activity as the list.
    for thread in threads { #expect(try db.thread(id: thread.id)?.activity == thread.activity) }
  }

  @Test func activityMatchesTheFixtureValueForValue() throws {
    let fixture = try AttentionRows.load()
    let db = try fixture.store()
    for thread in fixture.threads {
      let own = fixture.turns.filter { $0.threadId == thread.id }
      let latest = own.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      let requests = fixture.runtimeRequests.filter { $0.threadId == thread.id }
      let stamps = [thread.createdAt] + [latest?.updatedAt].compactMap { $0 } + requests.map(\.updatedAt)
      let expected = ThreadActivity(
        latestTurnId: latest?.id, latestTurnStatus: latest?.status, latestTurnOutcome: latest?.outcome,
        pendingRequests: requests.filter { $0.state == .pending }.count,
        pendingApprovals: requests.filter { $0.state == .pending && $0.kind.isApproval }.count,
        lastActivityAt: stamps.max()!)
      #expect(try db.thread(id: thread.id)?.activity == expected, "\(thread.id)")
    }
  }

  @Test func aThreadWithNoTurnsIsQuietFromItsCreation() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let activity = try #require(try db.thread(id: "t1")?.activity)
    #expect(
      activity
        == ThreadActivity(
          latestTurnId: nil, latestTurnStatus: nil, latestTurnOutcome: nil, pendingRequests: 0,
          lastActivityAt: "2026-10-31T09:00:00Z"))
  }

  @Test func pendingApprovalsCountOnlyPendingApprovalKinds() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    _ = try db.insertRuntimeRequest(request("r-cmd", kind: .commandApproval))
    _ = try db.insertRuntimeRequest(request("r-ask", kind: .userQuestion))
    var activity = try #require(try db.thread(id: "t1")?.activity)
    #expect(activity.pendingRequests == 2 && activity.pendingApprovals == 1)
    #expect(Attention.state(of: try #require(try db.thread(id: "t1"))) == .approve)

    _ = try db.insertRuntimeRequest(request("r-done", kind: .fileChangeApproval, state: .resolved))
    _ = try db.insertRuntimeRequest(request("r-tool", kind: .toolPermission))
    _ = try db.insertRuntimeRequest(request("r-file", kind: .fileChangeApproval))
    activity = try #require(try db.thread(id: "t1")?.activity)
    #expect(activity.pendingRequests == 4 && activity.pendingApprovals == 3)
    #expect(try db.listThreads().first { $0.id == "t1" }?.activity == activity)

    #expect(try db.transitionRuntimeRequest(id: "r-cmd", to: .resolved))
    #expect(try db.transitionRuntimeRequest(id: "r-tool", to: .expired))
    #expect(try db.transitionRuntimeRequest(id: "r-file", to: .resolved))
    let thread = try #require(try db.thread(id: "t1"))
    #expect(thread.activity?.pendingRequests == 1 && thread.activity?.pendingApprovals == 0)
    #expect(Attention.state(of: thread) == .reply)
  }

  @Test func activityIsNeverWrittenBack() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db, turns: [turn("u1", created: "2026-10-31T09:05:00Z")])
    _ = try db.updateThread(id: "t1") { $0.title = "Renamed" }
    let rows = try db.changes(after: 0).filter { $0.table == "threads" }
    #expect(rows.allSatisfy { $0.column != "activity" && $0.value?.objectValue?["activity"] == nil })
    #expect(try db.tableColumns("threads").contains("activity") == false)
  }

  @Test func markReadIgnoresAnOlderTurn() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(
      db,
      turns: [
        turn("t1a", created: "2026-10-31T09:01:00Z"),
        turn("t1b", created: "2026-10-31T09:02:00Z"),
      ])
    let afterNewer = try #require(try db.markRead(threadId: "t1", turnId: "t1b"))
    #expect(afterNewer.readTurnId == "t1b")
    let afterOlder = try #require(try db.markRead(threadId: "t1", turnId: "t1a"))
    #expect(afterOlder.readTurnId == "t1b")
    #expect(try db.thread(id: "t1")?.readTurnId == "t1b")
    // The same turn again changes nothing and records no change.
    let seqBefore = try db.changes(after: 0).count
    _ = try db.markRead(threadId: "t1", turnId: "t1b")
    #expect(try db.changes(after: 0).count == seqBefore)
  }

  @Test func markReadBreaksACreatedAtTieByTheGreaterId() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(
      db,
      turns: [
        turn("u-a", created: "2026-10-31T09:01:00Z"),
        turn("u-b", created: "2026-10-31T09:01:00Z"),
      ])
    #expect(try db.markRead(threadId: "t1", turnId: "u-b")?.readTurnId == "u-b")
    #expect(try db.markRead(threadId: "t1", turnId: "u-a")?.readTurnId == "u-b")
  }

  @Test func markReadAcceptsOnlyATerminalTurnOfThatThread() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(
      db,
      turns: [
        turn("done", created: "2026-10-31T09:01:00Z"),
        turn("busy", status: .running, outcome: nil, created: "2026-10-31T09:02:00Z"),
      ])
    _ = try db.insertThread(
      ConversationThread(id: "t2", connectionId: "c1", nativeThreadId: "n2"))
    _ = try db.insertTurn(
      Turn(id: "other", threadId: "t2", operationId: "op-other", status: .terminal, outcome: .completed))

    #expect(try db.markRead(threadId: "t1", turnId: "busy")?.readTurnId == nil)
    #expect(try db.markRead(threadId: "t1", turnId: "other")?.readTurnId == nil)
    #expect(try db.markRead(threadId: "t1", turnId: "no-such-turn")?.readTurnId == nil)
    #expect(try db.markRead(threadId: "t1", turnId: "done")?.readTurnId == "done")
    #expect(try db.markRead(threadId: "no-such-thread", turnId: "done") == nil)
  }

  @Test func markReadNilMarksTheThreadUnreadAgain() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db, turns: [turn("u1", created: "2026-10-31T09:01:00Z")])
    let read = try #require(try db.markRead(threadId: "t1", turnId: "u1"))
    #expect(Attention.state(of: read) == .quiet)
    let unread = try #require(try db.markRead(threadId: "t1", turnId: nil))
    #expect(unread.readTurnId == nil)
    #expect(Attention.state(of: unread) == .finished)
    // After clearing, any terminal turn is acceptable again, including an old one.
    #expect(try db.markRead(threadId: "t1", turnId: "u1")?.readTurnId == "u1")
  }

  @Test func markReadDoesNotBumpTheThreadAndRecordsAClockedChange() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db, turns: [turn("u1", created: "2026-10-31T09:01:00Z")])
    let before = try #require(try db.thread(id: "t1"))
    let marked = try #require(try db.markRead(threadId: "t1", turnId: "u1"))
    #expect(marked.updatedAt == before.updatedAt)
    let changes = try db.changes(after: 0).filter {
      $0.table == "threads" && $0.op == "update"
    }
    #expect(changes.map(\.column) == ["readTurnId"])
    #expect(changes.first?.value?.stringValue == "u1")
    #expect(marked.activity == before.activity)
  }

  @Test func clearDraftKeepsTheRow() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    _ = try db.saveDraft(threadId: "t1", text: "unsent")
    let before = try #require(try db.draft(threadId: "t1"))
    try db.clearDraft(threadId: "t1")
    let after = try #require(try db.draft(threadId: "t1"))
    #expect(after.text == "")
    #expect(after.updatedAt >= before.updatedAt)

    let changes = try db.changes(after: 0).filter { $0.table == "drafts" }
    #expect(!changes.contains { $0.op == "delete" })
    let textUpdate = try #require(changes.last { $0.op == "update" && $0.column == "text" })
    #expect(textUpdate.value?.stringValue == "")
    // Clearing a draft that does not exist creates nothing.
    try db.clearDraft(threadId: "missing")
    #expect(try db.draft(threadId: "missing") == nil)
  }
}
