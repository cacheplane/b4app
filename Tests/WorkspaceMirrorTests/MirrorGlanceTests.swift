import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let link = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Brian's iPhone",
  tokenRef: "secret:hub-token", orgSlug: "cacheplane", username: "blove")

/// A file-backed mirror seeded from the attention fixture, with two environments: `p1` named "Alpha" for
/// the first pinned thread, `p2` unnamed with a folder for the late request's thread.
private func seededStore(at path: String, link: MirrorLink? = nil) throws -> (MirrorStore, AttentionFixture) {
  let fixture = try AttentionFixture.load()
  let store = try MirrorStore(path: path)
  let batch = try store.apply(
    fixture.inserts + [
      change("environments", "p1", "insert", value: environmentJSON("p1", name: "Alpha")),
      change("environments", "p2", "insert", value: environmentJSON("p2")),
      change(
        "environmentFolders", "f2", "insert",
        value: folderJSON("f2", environmentId: "p2", path: "/Users/x/beta")),
      change("threads", "t-pinned-working", "update", column: "environmentId", value: "p1"),
      change("threads", "t-ask-request-late", "update", column: "environmentId", value: "p2"),
    ])
  #expect(batch.skipped == 0)
  if let link { try store.saveLink(link) }
  return (store, fixture)
}

private func tempPath() -> String {
  FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(UUID().uuidString).sqlite").path
}

private func remove(_ path: String) {
  for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
}

@Suite struct MirrorGlanceTests {
  @Test func loadsTheTopThreeInAttentionOrderWithEnvironmentNames() throws {
    let path = tempPath()
    defer { remove(path) }
    let (store, _) = try seededStore(at: path, link: link)
    let glance = try MirrorGlance.load(store: store)
    #expect(glance.linked)
    // State first (decision 5): the two approvals and the failure come before the pinned threads.
    #expect(glance.rows.map(\.threadId) == ["t-ask-request-late", "t-ask-turn-late", "t-failed-unread"])
    #expect(glance.rows.map(\.state) == [.approve, .approve, .failed])
    #expect(glance.rows.map(\.pinned) == [false, false, false])
    #expect(glance.rows.map(\.environmentName) == ["beta", nil, nil])
    let ordered = Attention.ordered(try store.threads(includeArchived: false, connectionId: nil, query: nil))
    #expect(glance.rows.map(\.threadId) == ordered.prefix(3).map(\.id))
    #expect(glance.rows.map(\.state) == ordered.prefix(3).map { Attention.state(of: $0) })
    #expect(glance.rows.map(\.title) == ordered.prefix(3).map(\.title))
    #expect(try MirrorGlance.load(store: store, limit: 5).rows.count == 5)
  }

  @Test func archivedThreadsAreLeftOut() throws {
    let path = tempPath()
    defer { remove(path) }
    let (store, _) = try seededStore(at: path, link: link)
    #expect(MirrorGlance.load(path: path).rows.first?.threadId == "t-ask-request-late")
    _ = try store.apply([change("threads", "t-ask-request-late", "update", column: "archived", value: true)])
    let glance = try MirrorGlance.load(store: store)
    #expect(glance.rows.map(\.threadId) == ["t-ask-turn-late", "t-failed-unread", "t-unread-b"])
    #expect(MirrorGlance.load(path: path) == glance)
  }

  /// Read failures stay failed and rank above finished, but the badge does not count them: the glance
  /// lists what the badge counts first, so they cannot fill its rows. The list's order is unchanged.
  @Test func theGlanceListsWhatTheBadgeCountsFirst() throws {
    let store = try MirrorStore.inMemory()
    let connection = Connection(
      id: "c1", kind: .codex, label: "Codex", target: "/usr/bin/codex", createdAt: "2026-10-31T05:00:00Z",
      updatedAt: "2026-10-31T05:00:00Z")
    var changes = [change("connections", "c1", "insert", value: try JSONValue(encoding: connection))]
    func add(_ id: String, outcome: TurnOutcome, read: Bool, minute: Int) throws {
      let at = String(format: "2026-10-31T10:%02d:00Z", minute)
      let thread = ConversationThread(
        id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, createdAt: at, updatedAt: at,
        readTurnId: read ? "u-\(id)" : nil)
      let turn = Turn(
        id: "u-\(id)", threadId: id, operationId: "op-\(id)", status: .terminal, submission: .acknowledged,
        outcome: outcome, createdAt: at, updatedAt: at)
      changes.append(change("threads", id, "insert", value: try JSONValue(encoding: thread)))
      changes.append(change("turns", turn.id, "insert", value: try JSONValue(encoding: turn)))
    }
    for (index, id) in ["failed-1", "failed-2", "failed-3"].enumerated() {
      try add(id, outcome: .failed, read: true, minute: 10 + index)
    }
    try add("finished-1", outcome: .completed, read: false, minute: 1)
    try add("finished-2", outcome: .completed, read: false, minute: 2)
    let batch = try store.apply(changes)
    #expect(batch.skipped == 0)

    let threads = try store.threads(includeArchived: false, connectionId: nil, query: nil)
    // The list: the failures first.
    #expect(Attention.ordered(threads).prefix(3).allSatisfy { Attention.state(of: $0) == .failed })
    #expect(threads.filter(Attention.countsTowardBadge).map(\.id).sorted() == ["finished-1", "finished-2"])

    let glance = try MirrorGlance.load(store: store)
    #expect(glance.rows.map(\.threadId) == ["finished-2", "finished-1", "failed-3"])
    #expect(glance.rows.map(\.state) == [.finished, .finished, .failed])
  }

  @Test func pathFormReadsTheSameFileReadOnly() throws {
    let path = tempPath()
    defer { remove(path) }
    var expected: Glance
    do {
      let (store, _) = try seededStore(at: path, link: link)
      expected = try MirrorGlance.load(store: store)
    }  // The writer closes here.
    #expect(!expected.rows.isEmpty)
    #expect(MirrorGlance.load(path: path) == expected)
  }

  @Test func pathFormReadsBesideAnOpenWriter() throws {
    let path = tempPath()
    defer { remove(path) }
    let (store, _) = try seededStore(at: path, link: link)
    #expect(MirrorGlance.load(path: path) == (try MirrorGlance.load(store: store)))
  }

  @Test func aReadOnlyStoreRefusesWrites() throws {
    let path = tempPath()
    defer { remove(path) }
    do { _ = try seededStore(at: path, link: link) }
    let readOnly = try MirrorStore.openReadOnly(path: path)
    #expect(throws: (any Error).self) { try readOnly.saveLink(link) }
    #expect(throws: (any Error).self) { try readOnly.clearLink() }
    #expect(try readOnly.link()?.deviceId == "phone-1")
  }

  @Test func readOnlyOpenRefusesAnUnmigratedFileWithoutChangingIt() throws {
    // A file nobody has migrated: empty, so user_version 0.
    let bare = tempPath()
    defer { remove(bare) }
    try Data().write(to: URL(fileURLWithPath: bare))
    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: true)) {
      _ = try MirrorStore.openReadOnly(path: bare)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: bare)).isEmpty)
    #expect(MirrorGlance.load(path: bare) == Glance(linked: false, rows: [], asOf: nil))
  }

  @Test func anUnlinkedFileIsNotLinked() throws {
    let path = tempPath()
    defer { remove(path) }
    do { _ = try seededStore(at: path) }
    let glance = MirrorGlance.load(path: path)
    #expect(!glance.linked)
    #expect(glance.asOf == nil)
    #expect(glance.rows.count == 3)
  }

  @Test func aMissingFileIsAnUnlinkedEmptyGlance() throws {
    let path = tempPath()
    #expect(MirrorGlance.load(path: path) == Glance(linked: false, rows: [], asOf: nil))
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(throws: WorkspaceError.self) { _ = try MirrorStore.openReadOnly(path: path) }
  }

  @Test func asOfComesFromTheLinksLastSync() throws {
    let path = tempPath()
    defer { remove(path) }
    var stamped = link
    stamped.lastSyncAt = "2026-11-02T10:00:00.000Z"
    do { _ = try seededStore(at: path, link: stamped) }
    #expect(MirrorGlance.load(path: path).asOf == Timestamp.date(from: "2026-11-02T10:00:00.000Z"))
  }

  @Test func freshDataIsNotStaleAndSchedulesTheStaleMoment() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let asOf = now.addingTimeInterval(-4 * 60)
    let glance = Glance(linked: true, rows: [], asOf: asOf)
    #expect(!glance.isStale(at: now))
    #expect(glance.staleLabel(at: now) == nil)
    #expect(glance.entryDates(now: now) == [now, asOf.addingTimeInterval(Glance.staleAfter)])
  }

  @Test func oldDataIsStaleAndLabelled() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let asOf = now.addingTimeInterval(-6 * 60)
    let glance = Glance(linked: true, rows: [], asOf: asOf)
    #expect(glance.isStale(at: now))
    #expect(glance.staleLabel(at: now)?.hasPrefix("as of ") == true)
    #expect(glance.staleLabel(at: now) == "as of " + asOf.formatted(date: .omitted, time: .shortened))
    #expect(glance.entryDates(now: now) == [now])
  }

  @Test func dataTurnsStaleExactlyAtTheScheduledEntry() {
    let asOf = Date(timeIntervalSince1970: 1_800_000_000)
    let glance = Glance(linked: true, rows: [], asOf: asOf)
    let staleAt = asOf.addingTimeInterval(Glance.staleAfter)
    #expect(!glance.isStale(at: staleAt.addingTimeInterval(-1)))
    #expect(glance.staleLabel(at: staleAt.addingTimeInterval(-1)) == nil)
    #expect(glance.isStale(at: staleAt))
    #expect(glance.staleLabel(at: staleAt) == "as of " + asOf.formatted(date: .omitted, time: .shortened))
    // The entry scheduled for that moment is the one that reads as stale.
    #expect(glance.entryDates(now: asOf.addingTimeInterval(240)).last == staleAt)
    #expect(glance.entryDates(now: staleAt) == [staleAt])
  }

  @Test func undatedDataIsNeverStale() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let glance = Glance(linked: false, rows: [], asOf: nil)
    #expect(!glance.isStale(at: now))
    #expect(glance.staleLabel(at: now) == nil)
    #expect(glance.entryDates(now: now) == [now])
  }

  @Test func reloadIsFifteenMinutesOut() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Glance(linked: true, rows: [], asOf: nil).reloadDate(now: now) == now.addingTimeInterval(900))
    #expect(Glance.reloadAfter == 900)
    #expect(Glance.staleAfter == 300)
  }
}
