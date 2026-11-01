import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

/// `Tests/Fixtures/sync/attention.json`, which `ActivityQueryTests` (the Mac's Postgres query) and the
/// protocol tests also read. Its rows are applied as the hub would serve them: one insert per row,
/// connections, threads, turns, then requests.
private struct AttentionFixture: Decodable {
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

private func band(_ name: String) -> AttentionBand {
  switch name {
  case "needsInput": .needsInput
  case "unread": .unread
  case "working": .working
  default: .quiet
  }
}

@Suite struct MirrorActivityTests {
  @Test func activityMatchesTheSharedFixture() throws {
    let fixture = try AttentionFixture.load()
    let store = try fixture.store()
    let threads = try store.threads(includeArchived: true, connectionId: nil, query: nil)
    #expect(threads.count == fixture.threads.count)
    #expect(threads.allSatisfy { $0.activity != nil })
    for thread in threads {
      #expect(Attention.band(of: thread) == band(fixture.expected.bands[thread.id] ?? ""), "\(thread.id)")
    }
    #expect(Attention.ordered(threads).map(\.id) == fixture.expected.order)
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
        pendingRequests: own.filter { $0.state == .pending }.count, lastActivityAt: stamps.max()!)
      #expect(try store.thread(id: thread.id)?.activity == expected, "\(thread.id)")
    }
  }

  @Test func threadsFilterByProject() throws {
    let fixture = try AttentionFixture.load()
    let store = try fixture.store()
    _ = try store.apply([
      change("projects", "p1", "insert", value: projectJSON("p1")),
      change("threads", "t-working", "update", column: "projectId", value: "p1"),
    ])
    #expect(
      try store.threads(includeArchived: true, connectionId: nil, query: nil, projectId: "p1").map(\.id) == [
        "t-working"
      ])
  }
}

func projectJSON(_ id: String, name: String = "", created: String = "2026-10-31T05:00:00Z") -> JSONValue {
  [
    "id": .string(id), "name": .string(name), "manual": false, "createdAt": .string(created),
    "updatedAt": .string(created),
  ]
}

func folderJSON(
  _ id: String, projectId: String, path: String, created: String = "2026-10-31T05:00:00Z"
)
  -> JSONValue
{
  ["id": .string(id), "projectId": .string(projectId), "path": .string(path), "createdAt": .string(created)]
}

extension JSONValue {
  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: try JSONCoding.encoder.encode(self))
  }
}
