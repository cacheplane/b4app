import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

/// `Tests/Fixtures/sync/attention.json`, which `ActivityQueryTests` (the Mac's Postgres query) and the
/// protocol tests also read. Its rows are applied as the hub would serve them: one insert per row,
/// connections, threads, turns, then requests.
struct AttentionFixture: Decodable {
  struct Expected: Decodable {
    var bands: [String: String]
    var order: [String]
  }
  var connections: [JSONValue]
  var threads: [JSONValue]
  var turns: [JSONValue]
  var runtimeRequests: [JSONValue]
  var expected: Expected

  static func load(file: StaticString = #filePath) throws -> AttentionFixture {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/attention.json")
    return try JSONCoding.decoder.decode(AttentionFixture.self, from: Data(contentsOf: url))
  }

  var inserts: [StoredChange] {
    let tables: [(String, [JSONValue])] = [
      ("connections", connections), ("threads", threads), ("turns", turns),
      ("runtimeRequests", runtimeRequests),
    ]
    return tables.flatMap { table, rows in
      rows.map { row in change(table, row["id"]?.stringValue ?? "", "insert", value: row) }
    }
  }

  func store() throws -> MirrorStore {
    let store = try MirrorStore.inMemory()
    let batch = try store.apply(inserts)
    #expect(batch.skipped == 0)
    #expect(batch.undecodableRows == 0)
    return store
  }
}

/// The fixture's band name for a state (approve and reply were "needs input", failed and finished
/// "unread"; the fixture has no read failure).
private func fixtureBandName(_ state: ThreadState) -> String {
  switch state {
  case .approve, .reply: "needsInput"
  case .failed, .finished: "unread"
  case .working: "working"
  case .quiet: "quiet"
  }
}

/// The fixture's pinned-first `order`, stably re-sorted by state and then pin (decision 5): inside one
/// (state, pin) group the fixture's activity-and-id order still decides.
private func fixtureStateOrder(_ order: [String], threads: [ConversationThread]) -> [String] {
  let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
  return order.enumerated().sorted { lhs, rhs in
    let (l, r) = (byId[lhs.element]!, byId[rhs.element]!)
    let (ls, rs) = (Attention.state(of: l), Attention.state(of: r))
    if ls != rs { return ls < rs }
    if l.pinned != r.pinned { return l.pinned }
    return lhs.offset < rhs.offset
  }.map(\.element)
}

private func requestRow(
  _ id: String, thread: String, kind: RuntimeRequestKind, state: RuntimeRequestState = .pending
) throws -> JSONValue {
  try JSONValue(
    encoding: RuntimeRequest(
      id: id, nativeRequestId: "n-\(id)", threadId: thread, adapterGeneration: 1, kind: kind, state: state,
      payload: [:], createdAt: "2026-10-31T13:00:00Z", updatedAt: "2026-10-31T13:00:00Z"))
}

@Suite struct MirrorActivityTests {
  @Test func activityMatchesTheSharedFixture() throws {
    let fixture = try AttentionFixture.load()
    let store = try fixture.store()
    let threads = try store.threads(includeArchived: true, connectionId: nil, query: nil)
    #expect(threads.count == fixture.threads.count)
    #expect(threads.allSatisfy { $0.activity != nil })
    for thread in threads {
      #expect(
        fixtureBandName(Attention.state(of: thread)) == fixture.expected.bands[thread.id], "\(thread.id)")
    }
    #expect(
      Attention.ordered(threads).map(\.id) == fixtureStateOrder(fixture.expected.order, threads: threads))
    for thread in threads { #expect(try store.thread(id: thread.id)?.activity == thread.activity) }
  }

  /// The same computation `ActivityQueryTests` checks the Postgres query against, so both stores agree
  /// value for value, not only on bands.
  @Test func activityMatchesTheFixtureValueForValue() throws {
    let fixture = try AttentionFixture.load()
    let store = try fixture.store()
    let turns = try fixture.turns.map { try $0.decode(Turn.self) }
    let requests = try fixture.runtimeRequests.map { try $0.decode(RuntimeRequest.self) }
    for row in fixture.threads {
      let thread = try row.decode(ConversationThread.self)
      let latest = turns.filter { $0.threadId == thread.id }.max {
        ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
      }
      let own = requests.filter { $0.threadId == thread.id }
      let stamps = [thread.createdAt] + [latest?.updatedAt].compactMap { $0 } + own.map(\.updatedAt)
      let expected = ThreadActivity(
        latestTurnId: latest?.id, latestTurnStatus: latest?.status, latestTurnOutcome: latest?.outcome,
        pendingRequests: own.filter { $0.state == .pending }.count,
        pendingApprovals: own.filter { $0.state == .pending && $0.kind.isApproval }.count,
        lastActivityAt: stamps.max()!)
      #expect(try store.thread(id: thread.id)?.activity == expected, "\(thread.id)")
    }
  }

  @Test func pendingApprovalsCountOnlyPendingApprovalKinds() throws {
    let store = try AttentionFixture.load().store()
    func activity() throws -> ThreadActivity? { try store.thread(id: "t-working")?.activity }
    _ = try store.apply([
      change(
        "runtimeRequests", "r-cmd", "insert",
        value: try requestRow("r-cmd", thread: "t-working", kind: .commandApproval)),
      change(
        "runtimeRequests", "r-ask", "insert",
        value: try requestRow("r-ask", thread: "t-working", kind: .userQuestion)),
    ])
    #expect(try activity()?.pendingRequests == 2 && activity()?.pendingApprovals == 1)
    _ = try store.apply([
      change(
        "runtimeRequests", "r-done", "insert",
        value: try requestRow("r-done", thread: "t-working", kind: .fileChangeApproval, state: .resolved)),
      change(
        "runtimeRequests", "r-tool", "insert",
        value: try requestRow("r-tool", thread: "t-working", kind: .toolPermission)),
      change(
        "runtimeRequests", "r-file", "insert",
        value: try requestRow("r-file", thread: "t-working", kind: .fileChangeApproval)),
    ])
    let after = try activity()
    #expect(after?.pendingRequests == 4 && after?.pendingApprovals == 3)
    let listed = try store.threads(includeArchived: true, connectionId: nil, query: nil).first {
      $0.id == "t-working"
    }
    #expect(listed?.activity == after)
    #expect(listed.map(Attention.state(of:)) == .approve)
  }

  @Test func threadsFilterByEnvironment() throws {
    let fixture = try AttentionFixture.load()
    let store = try fixture.store()
    _ = try store.apply([
      change("environments", "p1", "insert", value: environmentJSON("p1")),
      change("threads", "t-working", "update", column: "environmentId", value: "p1"),
    ])
    #expect(
      try store.threads(includeArchived: true, connectionId: nil, query: nil, environmentId: "p1").map(\.id)
        == [
          "t-working"
        ])
  }
}

func environmentJSON(_ id: String, name: String = "", created: String = "2026-10-31T05:00:00Z") -> JSONValue {
  [
    "id": .string(id), "name": .string(name), "manual": false, "createdAt": .string(created),
    "updatedAt": .string(created),
  ]
}

func folderJSON(
  _ id: String, environmentId: String, path: String, created: String = "2026-10-31T05:00:00Z"
)
  -> JSONValue
{
  [
    "id": .string(id), "environmentId": .string(environmentId), "path": .string(path),
    "createdAt": .string(created),
  ]
}

extension JSONValue {
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: try JSONCoding.encoder.encode(self))
  }
}
