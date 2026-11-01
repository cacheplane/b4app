import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

/// The shared wire fixture (`Tests/Fixtures/sync/changes.json`, read in place as `WireTests` does) as
/// the hub would serve it: `hubSeq = index + 1`, every change from `mac-1`. Its `connections` insert
/// is unfiltered (`authReference`, an executable path), which is what the secret tests need.
func fixtureAsStored(file: StaticString = #filePath) throws -> [StoredChange] {
  let url = URL(fileURLWithPath: "\(file)")
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sync/changes.json")
  let wire = try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
  return wire.enumerated().map { index, change in
    StoredChange(
      hubSeq: index + 1, deviceId: "mac-1", deviceSeq: change.deviceSeq, wall: change.wall,
      table: change.table, rowId: change.rowId, op: change.op, column: change.column, value: change.value)
  }
}

func itemJSON(id: String = "x", threadId: String, sequence: Int = 1) -> JSONValue {
  [
    "id": .string(id), "threadId": .string(threadId), "turnId": nil, "nativeItemId": nil, "role": "assistant",
    "type": "message", "payload": ["text": "orphan"], "sequence": .number(Double(sequence)),
    "provenance": "live", "createdAt": "2026-10-31T12:00:00Z",
  ]
}

func change(
  _ table: String, _ rowId: String, _ op: String, column: String? = nil, value: JSONValue? = nil,
  seq: Int = 1000
) -> StoredChange {
  StoredChange(
    hubSeq: seq, deviceId: "mac-1", deviceSeq: seq, wall: 0, table: table, rowId: rowId, op: op,
    column: column,
    value: value)
}

@Suite struct MirrorStoreTests {
  @Test func applyingTheFixtureMaterialisesAndSkipsOrphans() throws {
    let store = try MirrorStore.inMemory()
    let batch = try store.apply(try fixtureAsStored())

    let threads = try store.threads(includeArchived: true, connectionId: nil, query: nil)
    #expect(threads.count == 1)
    #expect(threads.first?.title == "Renamed")
    #expect(try store.thread(id: "thread-1")?.connectionId == "conn-1")
    let items = try store.items(threadId: "thread-1")
    #expect(items.map(\.id) == ["item-1", "item-2", "item-3", "item-4"])
    #expect(items[0].payload == ["text": "The login form rejects a valid password."])
    #expect(try store.draft(threadId: "thread-1") == nil)
    #expect(try store.turns(threadId: "thread-1").map(\.id) == ["turn-1", "turn-2"])
    #expect(try store.requests(threadId: "thread-1").first?.kind == .commandApproval)
    #expect(try store.connections().first?.capabilities[.permissionDecisions] == .supported)
    #expect(batch.touchedThreadIds == ["thread-1"])
    #expect(batch.touchedConnectionIds == ["conn-1"])
    #expect(batch.touchedItems.map(\.id) == ["item-1", "item-2", "item-3", "item-4"])
    #expect(batch.skipped == 0)

    let orphan = StoredChange(
      hubSeq: 99, deviceId: "d", deviceSeq: 99, wall: 0, table: "displayItems", rowId: "x", op: "insert",
      column: nil, value: itemJSON(threadId: "missing"))
    let orphaned = try store.apply([orphan])
    #expect(orphaned.skipped == 1)
    #expect(orphaned.touchedItems.isEmpty)
    #expect(try store.items(threadId: "missing").isEmpty)
  }

  @Test func applyIsIdempotentAndUpdatesOneColumn() throws {
    let store = try MirrorStore.inMemory()
    let changes = try fixtureAsStored()
    _ = try store.apply(changes)
    let again = try store.apply(changes)
    #expect(again.skipped == 0)
    #expect(try store.connections().count == 1)
    #expect(try store.threads(includeArchived: true, connectionId: nil, query: nil).count == 1)
    #expect(try store.turns(threadId: "thread-1").count == 2)
    #expect(try store.items(threadId: "thread-1").count == 4)
    #expect(try store.requests(threadId: "thread-1").count == 1)

    let before = try #require(try store.thread(id: "thread-1"))
    let renamed = try store.apply([change("threads", "thread-1", "update", column: "title", value: "Again")])
    #expect(renamed.touchedThreadIds == ["thread-1"])
    var expected = before
    expected.title = "Again"
    #expect(try store.thread(id: "thread-1") == expected)

    // A cleared column arrives as JSON null and sets NULL; an absent value is skipped.
    _ = try store.apply([change("threads", "thread-1", "update", column: "context", value: "notes")])
    #expect(try store.thread(id: "thread-1")?.context == "notes")
    _ = try store.apply([change("threads", "thread-1", "update", column: "context", value: .null)])
    #expect(try store.thread(id: "thread-1")?.context == nil)
    let absent = try store.apply([change("threads", "thread-1", "update", column: "title", value: nil)])
    #expect(absent.skipped == 1)
    #expect(try store.thread(id: "thread-1")?.title == "Again")

    // Booleans and deletes.
    _ = try store.apply([change("threads", "thread-1", "update", column: "pinned", value: true)])
    #expect(try store.thread(id: "thread-1")?.pinned == true)
    _ = try store.apply([change("displayItems", "item-4", "delete")])
    #expect(try store.items(threadId: "thread-1").count == 3)
  }

  @Test func connectionRowsNeverCarrySecretsOrPaths() throws {
    let path = NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
    defer { Self.remove(path) }
    let store = try MirrorStore(path: path)
    let fixture = try fixtureAsStored()
    #expect(fixture[0].value?["authReference"] == "secret:abc")  // the fixture is unfiltered
    let inserted = try store.apply([fixture[0]])
    #expect(inserted.touchedConnectionIds == ["conn-1"])
    _ = try store.apply([
      change("connections", "conn-1", "update", column: "authReference", value: "secret:def"),
      change("connections", "conn-1", "update", column: "target", value: "/opt/bin/codex"),
      change("connections", "conn-1", "update", column: "localServerId", value: "server-1"),
    ])

    let connection = try #require(try store.connections().first)
    #expect(connection.authReference == nil)
    #expect(connection.localServerId == nil)
    #expect(connection.target == "")
    #expect(connection.label == "Codex" && connection.status == .ready)

    // Nothing of either value reached the file (or its write-ahead log).
    for file in [path, path + "-wal"] {
      let bytes = (try? Data(contentsOf: URL(fileURLWithPath: file))) ?? Data()
      for secret in ["secret:abc", "secret:def", "/usr/local/bin/codex", "/opt/bin/codex", "server-1"] {
        #expect(bytes.range(of: Data(secret.utf8)) == nil, "\(secret) found in \(file)")
      }
    }
  }

  @Test func cursorAndLinkPersistAcrossReopenAndClearRowsKeepsTheLink() throws {
    let path = NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
    defer { Self.remove(path) }
    let link = MirrorLink(
      hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Brian's iPhone",
      tokenRef: "secret:hub-token", orgSlug: "cacheplane", username: "blove", lastSyncAt: nil, lastError: nil)
    do {
      let store = try MirrorStore(path: path)
      #expect(store.cursor == 0)
      #expect(try store.link() == nil)
      _ = try store.apply(try fixtureAsStored())
      try store.setCursor(12)
      try store.saveLink(link)
    }
    let reopened = try MirrorStore(path: path)
    #expect(reopened.cursor == 12)
    #expect(try reopened.link() == link)
    #expect(try reopened.items(threadId: "thread-1").count == 4)

    try reopened.clearRows()
    #expect(reopened.cursor == 0)
    #expect(try reopened.connections().isEmpty)
    #expect(try reopened.threads(includeArchived: true, connectionId: nil, query: nil).isEmpty)
    #expect(try reopened.link() == link)

    try reopened.clearLink()
    #expect(try reopened.link() == nil)
  }

  @Test func threadListFiltersLikeTheMac() throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(Array(try fixtureAsStored().prefix(2)))
    var second = try #require(try fixtureAsStored()[1].value?.objectValue)
    second["id"] = "thread-2"
    second["nativeThreadId"] = "native-thread-2"
    second["title"] = "Archived 100%_done"
    second["archived"] = true
    second["updatedAt"] = "2026-10-31T13:00:00Z"
    _ = try store.apply([change("threads", "thread-2", "insert", value: .object(second))])

    #expect(
      try store.threads(includeArchived: false, connectionId: nil, query: nil).map(\.id) == ["thread-1"])
    #expect(
      try store.threads(includeArchived: true, connectionId: nil, query: nil).map(\.id) == [
        "thread-2", "thread-1",
      ])
    #expect(try store.threads(includeArchived: true, connectionId: "other", query: nil).isEmpty)
    #expect(
      try store.threads(includeArchived: true, connectionId: nil, query: "LOGIN").map(\.id) == ["thread-1"])
    #expect(
      try store.threads(includeArchived: true, connectionId: nil, query: "100%_").map(\.id) == ["thread-2"])
    #expect(try store.threads(includeArchived: true, connectionId: nil, query: "0%_x").isEmpty)
  }

  @Test func protocolRowsRoundTripThroughTheirCodableTypes() throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(Array(try fixtureAsStored().prefix(2)))
    let turn = Turn(
      id: "turn-9", threadId: "thread-1", operationId: "op-9", nativeTurnId: nil, status: .terminal,
      submission: .acknowledged, outcome: .completed, createdAt: "2026-10-31T12:02:00Z",
      updatedAt: "2026-10-31T12:03:00Z")
    let request = RuntimeRequest(
      id: "request-9", nativeRequestId: "n-9", threadId: "thread-1", turnId: "turn-9", adapterGeneration: 2,
      kind: .commandApproval, state: .pending, payload: ["command": "ls", "args": [1, true, nil]],
      createdAt: "2026-10-31T12:04:00Z", updatedAt: "2026-10-31T12:04:00Z")
    let draft = Draft(threadId: "thread-1", text: "keep going", updatedAt: "2026-10-31T12:05:00Z")
    _ = try store.apply([
      change("turns", turn.id, "insert", value: try JSONValue(encoding: turn)),
      change("runtimeRequests", request.id, "insert", value: try JSONValue(encoding: request)),
      change("drafts", "thread-1", "insert", value: try JSONValue(encoding: draft)),
    ])
    #expect(try store.turns(threadId: "thread-1") == [turn])
    #expect(try store.requests(threadId: "thread-1") == [request])
    #expect(try store.draft(threadId: "thread-1") == draft)

    // A JSON column keeps a scalar string as JSON, not as bare text.
    _ = try store.apply([change("runtimeRequests", request.id, "update", column: "payload", value: "plain")])
    #expect(try store.requests(threadId: "thread-1").first?.payload == "plain")
  }

  @Test func theSharedFixtureDecodesCompletelyThroughTheProtocolTypes() throws {
    let store = try MirrorStore.inMemory()
    let batch = try store.apply(try fixtureAsStored())
    #expect(batch.skipped == 0)
    #expect(batch.undecodableRows == 0)
    #expect(try store.connections().count == 1)
    #expect(try store.threads(includeArchived: true, connectionId: nil, query: nil).count == 1)
    #expect(try store.turns(threadId: "thread-1").count == 2)
    #expect(try store.items(threadId: "thread-1").count == 4)
    #expect(try store.requests(threadId: "thread-1").count == 1)
    #expect(try store.draft(threadId: "thread-1") == nil)
    let stored = [
      "connections": 1, "threads": 1, "turns": 2, "displayItems": 4, "runtimeRequests": 1, "drafts": 0,
    ]
    for (table, count) in stored { #expect(try store.rowCount(table) == count, "\(table)") }
    #expect(try store.undecodableRowCount() == 0)
  }

  @Test func aRowANewerMacWroteIsKeptLeftOutOfReadsAndCounted() throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(Array(try fixtureAsStored().prefix(3)))
    var future = try #require(try fixtureAsStored()[3].value?.objectValue)
    future["status"] = "teleporting"  // a TurnStatus this build does not define
    let batch = try store.apply([change("turns", "turn-2", "insert", value: .object(future))])
    #expect(batch.skipped == 0)
    #expect(batch.undecodableRows == 1)
    #expect(try store.rowCount("turns") == 2)
    #expect(try store.turns(threadId: "thread-1").map(\.id) == ["turn-1"])
    #expect(try store.undecodableRowCount() == 1)

    // Once the row becomes readable it is shown again and no longer counted.
    _ = try store.apply([change("turns", "turn-2", "update", column: "status", value: "running")])
    #expect(try store.turns(threadId: "thread-1").count == 2)
    #expect(try store.undecodableRowCount() == 0)
  }

  @Test func theUndecodableCountFollowsCascadesClearsAndReopens() throws {
    let path = NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
    defer { Self.remove(path) }
    let fixture = try fixtureAsStored()
    var future = try #require(fixture[3].value?.objectValue)
    future["submission"] = "teleported"
    do {
      let store = try MirrorStore(path: path)
      _ = try store.apply(
        Array(fixture.prefix(3)) + [change("turns", "turn-2", "insert", value: .object(future))])
      #expect(try store.undecodableRowCount() == 1)
      // Writing it again does not count it twice.
      _ = try store.apply([change("turns", "turn-2", "update", column: "inputRef", value: "x")])
      #expect(try store.undecodableRowCount() == 1)
    }
    let store = try MirrorStore(path: path)
    #expect(try store.undecodableRowCount() == 1)
    // Deleting the thread cascades to the turn, and the count follows.
    _ = try store.apply([change("threads", "thread-1", "delete")])
    #expect(try store.rowCount("turns") == 0)
    #expect(try store.undecodableRowCount() == 0)

    _ = try store.apply(
      Array(fixture.prefix(3)) + [change("turns", "turn-2", "insert", value: .object(future))])
    #expect(try store.undecodableRowCount() == 1)
    _ = try store.apply([change("turns", "turn-2", "delete")])
    #expect(try store.undecodableRowCount() == 0)
    _ = try store.apply([change("turns", "turn-2", "insert", value: .object(future))])
    try store.clearRows()
    #expect(try store.undecodableRowCount() == 0)
  }

  static func remove(_ path: String) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
  }
}
