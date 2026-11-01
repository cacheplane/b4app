import Foundation
import Synchronization
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let phoneId = "phone-1"
private let macId = "mac-1"

private let link = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: phoneId, deviceName: "Brian's iPhone",
  tokenRef: "secret:hub-token",
  orgSlug: "cacheplane", username: "blove")

/// The shared fixture's connection, thread, and turns, with the phone's link saved.
private func linkedStore(prefix: Int = 4) throws -> MirrorStore {
  let store = try MirrorStore.inMemory()
  try store.saveLink(link)
  _ = try store.apply(Array(try fixtureAsStored().prefix(prefix)))
  return store
}

private func clock(_ text: String?) throws -> HLC { try #require(text.flatMap(HLC.init(rawValue:))) }

/// A change pulled from the hub, stamped with `hlc`.
private func pulled(
  _ table: String, _ rowId: String, _ op: String, column: String? = nil, value: JSONValue? = nil,
  deviceId: String = macId, hlc: HLC
) -> StoredChange {
  StoredChange(
    hubSeq: 500, deviceId: deviceId, deviceSeq: 500, wall: Int(hlc.millis), table: table, rowId: rowId,
    op: op,
    column: column, value: value, hlc: hlc.rawValue)
}

@Suite struct MirrorWritesTests {
  @Test func localEditAppliesAtOnceAndQueues() throws {
    let store = try linkedStore()
    let before = try #require(try store.thread(id: "thread-1"))
    let edited = try #require(
      try store.updateThread(id: "thread-1", title: "From phone", pinned: nil, archived: nil))
    #expect(edited.title == "From phone")
    #expect(edited.activity != nil)
    // A phone edit leaves the Mac-only `updatedAt` alone.
    #expect(edited.updatedAt == before.updatedAt)
    #expect(try store.thread(id: "thread-1")?.title == "From phone")

    let queued = try store.outbox(limit: 10)
    #expect(queued.count == 1)
    let first = try #require(queued.first)
    #expect(first.deviceSeq == 1)
    #expect(first.table == "threads" && first.rowId == "thread-1" && first.op == "update")
    #expect(first.column == "title" && first.value == "From phone")
    let stamp = try clock(first.hlc)
    #expect(stamp.deviceId == phoneId)
    #expect(first.wall == Int(stamp.millis))
    #expect(store.outboxCount == 1)
    #expect(try store.columnClock(table: "threads", rowId: "thread-1", column: "title") == stamp.rawValue)

    // Two columns in one write share one clock; an unchanged value queues nothing.
    _ = try store.updateThread(id: "thread-1", title: "From phone", pinned: true, archived: true)
    let all = try store.outbox(limit: 10)
    #expect(all.map(\.deviceSeq) == [1, 2, 3])
    #expect(all.dropFirst().map(\.column) == ["pinned", "archived"])
    #expect(all.dropFirst().map(\.value) == [true, true])
    #expect(all[1].hlc == all[2].hlc)
    #expect(try clock(all[1].hlc) > stamp)
    #expect(try store.outbox(limit: 2).map(\.deviceSeq) == [1, 2])

    // Nothing to change, or no such thread: no clock, no outbox row.
    _ = try store.updateThread(id: "thread-1", title: nil, pinned: true, archived: nil)
    #expect(try store.updateThread(id: "missing", title: "x", pinned: nil, archived: nil) == nil)
    #expect(store.outboxCount == 3)
  }

  @Test func deviceSequenceNumbersAreNeverReused() throws {
    let path = NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
    defer { MirrorStoreTests.remove(path) }
    var three: HLC?
    do {
      let store = try MirrorStore(path: path)
      try store.saveLink(link)
      _ = try store.apply(Array(try fixtureAsStored().prefix(2)))
      _ = try store.updateThread(id: "thread-1", title: "One", pinned: nil, archived: nil)
      _ = try store.updateThread(id: "thread-1", title: "Two", pinned: nil, archived: nil)
      try store.removeOutbox(through: 1)
      #expect(try store.outbox(limit: 10).map(\.deviceSeq) == [2])
      try store.removeOutbox(through: 2)
      #expect(store.outboxCount == 0)
      _ = try store.updateThread(id: "thread-1", title: "Three", pinned: nil, archived: nil)
      #expect(try store.outbox(limit: 10).map(\.deviceSeq) == [3])
      three = try clock(try store.outbox(limit: 1).first?.hlc)
      try store.removeOutbox(through: 3)
    }
    let reopened = try MirrorStore(path: path)
    _ = try reopened.updateThread(id: "thread-1", title: "Four", pinned: nil, archived: nil)
    let queued = try #require(try reopened.outbox(limit: 10).first)
    #expect(queued.deviceSeq == 4)
    // The reopened clock starts after the clocks it stored.
    #expect(try clock(queued.hlc) > #require(three))
  }

  @Test func pulledOlderEditLosesToALocalEdit() throws {
    let store = try linkedStore()
    _ = try store.updateThread(id: "thread-1", title: "Phone", pinned: nil, archived: nil)
    let local = try clock(try store.outbox(limit: 1).first?.hlc)
    let older = HLC(millis: local.millis - 1, counter: 0, deviceId: macId)
    let batch = try store.apply([
      pulled("threads", "thread-1", "update", column: "title", value: "Older Mac", hlc: older)
    ])
    #expect(try store.thread(id: "thread-1")?.title == "Phone")
    #expect(batch.touchedThreadIds.isEmpty)
    #expect(batch.skipped == 0)
    #expect(try store.columnClock(table: "threads", rowId: "thread-1", column: "title") == local.rawValue)

    // A newer one wins, advances the clock, and the next local stamp sorts after it.
    let newer = HLC(millis: local.millis + 1, counter: 0, deviceId: macId)
    let won = try store.apply([
      pulled("threads", "thread-1", "update", column: "title", value: "Newer Mac", hlc: newer)
    ])
    #expect(won.touchedThreadIds == ["thread-1"])
    #expect(try store.thread(id: "thread-1")?.title == "Newer Mac")
    #expect(try store.columnClock(table: "threads", rowId: "thread-1", column: "title") == newer.rawValue)
    _ = try store.updateThread(id: "thread-1", title: nil, pinned: true, archived: nil)
    #expect(try clock(try store.outbox(limit: 10).last?.hlc) > newer)
  }

  @Test func macOnlyColumnsApplyWithoutAClock() throws {
    let store = try linkedStore()
    _ = try store.updateThread(id: "thread-1", title: "Phone", pinned: nil, archived: nil)
    let local = try clock(try store.outbox(limit: 1).first?.hlc)
    let older = HLC(millis: local.millis - 1, counter: 0, deviceId: macId)
    // An older clock on a column the phone never writes still applies, as in M8a.
    _ = try store.apply([
      pulled("threads", "thread-1", "update", column: "context", value: "/tmp/x", hlc: older)
    ])
    #expect(try store.thread(id: "thread-1")?.context == "/tmp/x")
    // An insert of the whole row keeps the newer local title and takes the rest.
    var row = try #require(try fixtureAsStored()[1].value?.objectValue)
    row["nativeThreadId"] = "native-renamed"
    _ = try store.apply([pulled("threads", "thread-1", "insert", value: .object(row), hlc: older)])
    let thread = try #require(try store.thread(id: "thread-1"))
    #expect(thread.title == "Phone")
    #expect(thread.nativeThreadId == "native-renamed")
  }

  @Test func ownChangeComingBackIsANoOp() throws {
    let store = try linkedStore()
    _ = try store.updateThread(id: "thread-1", title: "Phone", pinned: nil, archived: nil)
    let pushed = try #require(try store.outbox(limit: 1).first)
    let before = try store.thread(id: "thread-1")
    let echo = StoredChange(
      hubSeq: 77, deviceId: phoneId, deviceSeq: pushed.deviceSeq, wall: pushed.wall, table: pushed.table,
      rowId: pushed.rowId, op: pushed.op, column: pushed.column, value: pushed.value, hlc: pushed.hlc)
    let batch = try store.apply([echo])
    #expect(batch == AppliedBatch())
    #expect(try store.thread(id: "thread-1") == before)
    #expect(store.outboxCount == 1)
    #expect(try store.columnClock(table: "threads", rowId: "thread-1", column: "title") == pushed.hlc)
  }

  @Test func aPulledClockFarAheadIsClamped() throws {
    let wall = Mutex<UInt64>(1_800_000_000_000)
    let store = try MirrorStore(path: ":memory:", wall: { wall.withLock { $0 } })
    try store.saveLink(link)
    _ = try store.apply(Array(try fixtureAsStored().prefix(2)))
    let ahead = HLC(millis: 1_800_000_000_000 + 3_600_000, counter: 7, deviceId: macId)
    _ = try store.apply([
      pulled("threads", "thread-1", "update", column: "title", value: "Future", hlc: ahead)
    ])
    #expect(try store.thread(id: "thread-1")?.title == "Future")
    let stored = try clock(try store.columnClock(table: "threads", rowId: "thread-1", column: "title"))
    #expect(stored == HLC(millis: 1_800_000_000_000, counter: 0, deviceId: macId))

    // A minute later the phone's edit wins over it.
    wall.withLock { $0 += 60_000 }
    _ = try store.updateThread(id: "thread-1", title: "Phone", pinned: nil, archived: nil)
    #expect(try store.thread(id: "thread-1")?.title == "Phone")
    #expect(try clock(try store.outbox(limit: 1).first?.hlc).millis == 1_800_000_060_000)
  }

  @Test func markReadAcceptsOnlyATerminalTurnNoOlderThanTheMarker() throws {
    let store = try linkedStore()
    _ = try store.apply([
      change(
        "turns", "turn-3", "insert",
        value: try JSONValue(
          encoding: Turn(
            id: "turn-3", threadId: "thread-1", operationId: "op-3", status: .terminal, outcome: .failed,
            createdAt: "2026-10-31T13:00:00Z", updatedAt: "2026-10-31T13:00:00Z")))
    ])
    let turns = try store.turns(threadId: "thread-1")
    let terminal = turns.filter { $0.status == .terminal }.sorted {
      ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
    }
    #expect(terminal.count == 2)
    let (older, newer) = (terminal[0].id, terminal[1].id)

    // turn-2 is still running.
    #expect(try store.markRead(threadId: "thread-1", turnId: "turn-2")?.readTurnId == nil)
    #expect(try store.markRead(threadId: "thread-1", turnId: "no-such-turn")?.readTurnId == nil)
    #expect(store.outboxCount == 0)
    #expect(try store.markRead(threadId: "thread-1", turnId: newer)?.readTurnId == newer)
    #expect(try store.markRead(threadId: "thread-1", turnId: older)?.readTurnId == newer)
    #expect(try store.markRead(threadId: "thread-1", turnId: newer)?.readTurnId == newer)
    #expect(try store.outbox(limit: 10).map(\.value) == [.string(newer)])
    #expect(try store.markRead(threadId: "missing", turnId: newer) == nil)

    // Nil marks it unread again, and then an older turn is acceptable.
    #expect(try store.markRead(threadId: "thread-1", turnId: nil)?.readTurnId == nil)
    #expect(try store.markRead(threadId: "thread-1", turnId: older)?.readTurnId == older)
    let queued = try store.outbox(limit: 10)
    #expect(queued.map(\.column) == ["readTurnId", "readTurnId", "readTurnId"])
    #expect(queued.map(\.value) == [.string(newer), .null, .string(older)])
  }

  @Test func saveDraftInsertsThenUpdatesColumnByColumn() throws {
    let store = try linkedStore()
    let first = try store.saveDraft(threadId: "thread-1", text: "half a thought")
    #expect(try store.draft(threadId: "thread-1") == first)
    let insert = try #require(try store.outbox(limit: 10).first)
    #expect(insert.op == "insert" && insert.table == "drafts" && insert.rowId == "thread-1")
    #expect(insert.column == nil)
    #expect(
      insert.value
        == ["threadId": "thread-1", "text": "half a thought", "updatedAt": .string(first.updatedAt)])
    for column in ["threadId", "text", "updatedAt"] {
      #expect(try store.columnClock(table: "drafts", rowId: "thread-1", column: column) == insert.hlc)
    }

    let second = try store.saveDraft(threadId: "thread-1", text: "")
    #expect(second.text == "")
    #expect(try store.draft(threadId: "thread-1") == second)
    let updates = try store.outbox(limit: 10).dropFirst()
    #expect(updates.allSatisfy { $0.op == "update" && $0.table == "drafts" })
    #expect(updates.first { $0.column == "text" }?.value == "")
    #expect(Set(updates.map(\.hlc)).count == 1)

    #expect(throws: WorkspaceError.self) { try store.saveDraft(threadId: "missing", text: "x") }
  }

  /// Review Focus 4, mirror side.
  @Test func renameProjectToEmptyShowsFolderName() throws {
    let store = try linkedStore()
    _ = try store.apply([
      change("projects", "p1", "insert", value: projectJSON("p1")),
      change(
        "projectFolders", "f2", "insert",
        value: folderJSON(
          "f2", projectId: "p1", path: "/Users/blove/repos/later", created: "2026-10-31T06:00:00Z")),
      change(
        "projectFolders", "f1", "insert",
        value: folderJSON("f1", projectId: "p1", path: "/Users/blove/repos/b4app")),
    ])
    let original = try #require(try store.projects().first)
    #expect(original.displayName == "b4app")
    #expect(original.folders.map(\.id) == ["f1", "f2"])

    let named = try #require(try store.renameProject(id: "p1", name: "Agent Workspace"))
    #expect(named.displayName == "Agent Workspace")
    #expect(named.updatedAt == original.updatedAt)
    let cleared = try #require(try store.renameProject(id: "p1", name: ""))
    #expect(cleared.name == "")
    #expect(cleared.displayName == "b4app")
    #expect(try store.projects().first?.displayName == "b4app")
    let queued = try store.outbox(limit: 10)
    #expect(queued.map(\.table) == ["projects", "projects"])
    #expect(queued.map(\.column) == ["name", "name"])
    #expect(queued.map(\.value) == ["Agent Workspace", ""])
    #expect(try store.renameProject(id: "missing", name: "x") == nil)
  }

  @Test func turnsAndRequestsTouchTheirThread() throws {
    let store = try linkedStore(prefix: 2)
    let fixture = try fixtureAsStored()
    let turn = try store.apply([fixture[2], fixture[3]])
    #expect(turn.touchedThreadIds == ["thread-1"])
    #expect(turn.touchedConnectionIds.isEmpty && turn.touchedProjectIds.isEmpty)
    let request = try store.apply([fixture[8]])
    #expect(request.touchedThreadIds == ["thread-1"])
    let resolved = try store.apply([
      change("runtimeRequests", "request-1", "update", column: "state", value: "resolved")
    ])
    #expect(resolved.touchedThreadIds == ["thread-1"])
    let gone = try store.apply([change("turns", "turn-1", "delete")])
    #expect(gone.touchedThreadIds == ["thread-1"])

    let project = try store.apply([
      change("projects", "p1", "insert", value: projectJSON("p1")),
      change("projectFolders", "f1", "insert", value: folderJSON("f1", projectId: "p1", path: "/tmp/p")),
    ])
    #expect(project.touchedProjectIds == ["p1"])
    #expect(try store.apply([change("projectFolders", "f1", "delete")]).touchedProjectIds == ["p1"])
  }

  @Test func ownerComesFromTheInsertAndItsNameFromDevices() throws {
    let store = try linkedStore(prefix: 2)
    try store.saveDevices([
      DeviceInfo(
        id: macId, name: "Brian's MacBook Pro", platform: "macos", lastSeenAt: "2026-10-31T12:00:00Z"),
      DeviceInfo(id: phoneId, name: "Brian's iPhone", platform: "ios"),
    ])
    #expect(try store.devices().map(\.id) == [macId, phoneId])
    #expect(try store.thread(id: "thread-1")?.ownerDeviceName == "Brian's MacBook Pro")
    // An update from another device does not change the owner.
    _ = try store.apply([
      change("threads", "thread-1", "update", column: "title", value: "x", deviceId: "other")
    ])
    #expect(try store.thread(id: "thread-1")?.ownerDeviceName == "Brian's MacBook Pro")
    #expect(try store.ownerDeviceId(table: "connections", rowId: "conn-1") == macId)
    // A change cannot set the owner directly.
    let refused = try store.apply([
      change("threads", "thread-1", "update", column: "ownerDeviceId", value: "other")
    ])
    #expect(refused.skipped == 1)
    // Replacing the device list drops a device no longer listed; the name then reads nil.
    try store.saveDevices([DeviceInfo(id: phoneId, name: "Brian's iPhone", platform: "ios")])
    #expect(try store.devices().count == 1)
    #expect(try store.thread(id: "thread-1")?.ownerDeviceName == nil)
  }

  @Test func snapshotKeepsTheOutbox() throws {
    let store = try linkedStore()
    _ = try store.updateThread(id: "thread-1", title: "Unsent phone title", pinned: nil, archived: nil)
    #expect(store.outboxCount == 1)
    let fixture = try fixtureAsStored()

    // The hub's view: the connection and thread (with an older title), a project, no turns.
    var thread = try #require(fixture[1].value?.objectValue)
    thread["title"] = "Hub title"
    thread["pinned"] = true
    let hubClock = HLC(millis: 1_761_900_000_000, counter: 0, deviceId: macId)
    let snapshot = SnapshotResponse(
      changes: [
        StoredChange(
          hubSeq: 0, deviceId: macId, deviceSeq: 0, wall: 0, table: "connections", rowId: "conn-1",
          op: "insert",
          value: fixture[0].value, hlc: hubClock.rawValue),
        StoredChange(
          hubSeq: 0, deviceId: macId, deviceSeq: 0, wall: 0, table: "projects", rowId: "p1", op: "insert",
          value: projectJSON("p1", name: "Hub project"), hlc: hubClock.rawValue),
        StoredChange(
          hubSeq: 0, deviceId: macId, deviceSeq: 0, wall: 0, table: "threads", rowId: "thread-1",
          op: "insert",
          value: .object(thread), hlc: hubClock.rawValue),
      ],
      clocks: [
        ColumnClock(table: "threads", rowId: "thread-1", column: "title", hlc: hubClock.rawValue),
        ColumnClock(table: "threads", rowId: "thread-1", column: "pinned", hlc: hubClock.rawValue),
      ],
      next: 77)
    try store.applySnapshot(snapshot)

    #expect(store.cursor == 77)
    #expect(store.outboxCount == 1)
    #expect(try store.link() == link)
    let restored = try #require(try store.thread(id: "thread-1"))
    // The unsent edit still shows over the snapshot; the rest is the hub's.
    #expect(restored.title == "Unsent phone title")
    #expect(restored.pinned == true)
    #expect(try store.turns(threadId: "thread-1").isEmpty)
    #expect(try store.projects().map(\.name) == ["Hub project"])
    #expect(try store.columnClock(table: "threads", rowId: "thread-1", column: "pinned") == hubClock.rawValue)
    #expect(
      try store.columnClock(table: "threads", rowId: "thread-1", column: "title")
        == store.outbox(limit: 1).first?.hlc)
    // The next write keeps counting from the high-water mark.
    _ = try store.updateThread(id: "thread-1", title: nil, pinned: false, archived: nil)
    #expect(try store.outbox(limit: 10).map(\.deviceSeq) == [1, 2])
  }

  @Test func aSnapshotClockNewerThanAnUnsentEditWins() throws {
    let store = try linkedStore()
    _ = try store.updateThread(id: "thread-1", title: "Unsent", pinned: nil, archived: nil)
    let local = try clock(try store.outbox(limit: 1).first?.hlc)
    let newer = HLC(millis: local.millis + 10, counter: 0, deviceId: macId)
    var thread = try #require(try fixtureAsStored()[1].value?.objectValue)
    thread["title"] = "Mac later"
    try store.applySnapshot(
      SnapshotResponse(
        changes: [
          StoredChange(
            hubSeq: 0, deviceId: macId, deviceSeq: 0, wall: 0, table: "connections", rowId: "conn-1",
            op: "insert",
            value: try fixtureAsStored()[0].value, hlc: newer.rawValue),
          StoredChange(
            hubSeq: 0, deviceId: macId, deviceSeq: 0, wall: 0, table: "threads", rowId: "thread-1",
            op: "insert",
            value: .object(thread), hlc: newer.rawValue),
        ],
        clocks: [ColumnClock(table: "threads", rowId: "thread-1", column: "title", hlc: newer.rawValue)],
        next: 5))
    #expect(try store.thread(id: "thread-1")?.title == "Mac later")
    #expect(store.outboxCount == 1)
  }
}

// MARK: - The cross-store conflict fixture

/// `Tests/Fixtures/sync/conflicts.json`, which `RemoteApplyTests` (the Mac) and the hub replay too.
private struct ConflictFixture: Decodable {
  struct Entry: Decodable {
    var platform: String
    var device: String
    var deviceSeq: Int
    var wall: Int
    var table: String
    var rowId: String
    var op: String
    var column: String?
    var value: JSONValue?
    var hlc: String
  }
  var changes: [Entry]
  var expected: [String: JSONValue]

  static func load(file: StaticString = #filePath) throws -> ConflictFixture {
    let url = URL(fileURLWithPath: "\(file)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/conflicts.json")
    return try JSONCoding.decoder.decode(ConflictFixture.self, from: Data(contentsOf: url))
  }

  /// The columns the mirror's `NOT NULL` schema needs and the fixture's short inserts leave out. The
  /// fixture's own values are laid over these, so every value it names (and every clock) is its own.
  static let required: [String: [String: JSONValue]] = [
    "connections": [
      "kind": "codex", "label": "", "target": "", "capabilities": [:], "status": "ready",
      "authStatus": "authenticated", "createdAt": "2026-10-31T12:00:00Z", "updatedAt": "2026-10-31T12:00:00Z",
    ],
    "threads": [
      "nativeThreadId": "native-thread-1", "createdAt": "2026-10-31T12:00:00Z",
      "updatedAt": "2026-10-31T12:00:00Z",
    ],
    "turns": [
      "operationId": "op-turn-1", "submission": "acknowledged", "outcome": "completed",
      "createdAt": "2026-10-31T12:00:00Z", "updatedAt": "2026-10-31T12:00:00Z",
    ],
  ]

  /// Each entry as the hub serves it: attributed to the device its clock names, at its own clock.
  func stored(_ entry: Entry, seq: Int) throws -> StoredChange {
    var value = entry.value
    if entry.op == "insert", let base = Self.required[entry.table], let row = entry.value?.objectValue {
      value = .object(base.merging(row) { _, own in own })
    }
    let deviceId = try #require(HLC(rawValue: entry.hlc)).deviceId
    return StoredChange(
      hubSeq: seq, deviceId: deviceId, deviceSeq: entry.deviceSeq, wall: entry.wall, table: entry.table,
      rowId: entry.rowId, op: entry.op, column: entry.column, value: value, hlc: entry.hlc)
  }
}

extension MirrorWritesTests {
  /// Every entry, Mac's and phone's, goes through the mirror's `apply` as a pulled change (the mirror
  /// is linked as the fixture's phone, so its own entries are its edits coming back). Two orders must
  /// agree with `expected`: as listed, and every insert first followed by the updates reversed.
  @Test(arguments: ["listed", "insertsFirstUpdatesReversed"])
  func conflictFixtureMergesToTheExpectedValues(order: String) throws {
    let fixture = try ConflictFixture.load()
    let phone = try #require(fixture.changes.first { $0.platform == "ios" })
    let store = try MirrorStore.inMemory()
    var phoneLink = link
    phoneLink.deviceId = try #require(HLC(rawValue: phone.hlc)).deviceId
    try store.saveLink(phoneLink)

    var entries = fixture.changes
    if order != "listed" {
      entries = entries.filter { $0.op == "insert" } + entries.filter { $0.op != "insert" }.reversed()
    }
    let changes = try entries.enumerated().map { try fixture.stored($1, seq: $0 + 1) }
    let batch = try store.apply(changes)
    #expect(batch.skipped == 0)

    let thread = try #require(try store.thread(id: "thread-1"))
    #expect(fixture.expected["threads.title"] == .string(thread.title))
    #expect(fixture.expected["threads.readTurnId"] == thread.readTurnId.map(JSONValue.string))
    #expect(
      fixture.expected["drafts.text"] == (try store.draft(threadId: "thread-1")).map { .string($0.text) })
  }
}
