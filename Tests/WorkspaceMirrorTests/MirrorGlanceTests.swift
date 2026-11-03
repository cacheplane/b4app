import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let link = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Brian's iPhone",
  tokenRef: "secret:hub-token", orgSlug: "cacheplane", username: "blove")

/// A file-backed mirror seeded from the attention fixture, with two projects: `p1` named "Alpha" for
/// the first pinned thread, `p2` unnamed with a folder for the late request's thread.
private func seededStore(at path: String, link: MirrorLink? = nil) throws -> (MirrorStore, AttentionFixture) {
  let fixture = try AttentionFixture.load()
  let store = try MirrorStore(path: path)
  let batch = try store.apply(
    fixture.inserts + [
      change("projects", "p1", "insert", value: projectJSON("p1", name: "Alpha")),
      change("projects", "p2", "insert", value: projectJSON("p2")),
      change(
        "projectFolders", "f2", "insert", value: folderJSON("f2", projectId: "p2", path: "/Users/x/beta")),
      change("threads", "t-pinned-working", "update", column: "projectId", value: "p1"),
      change("threads", "t-ask-request-late", "update", column: "projectId", value: "p2"),
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
  @Test func loadsTheTopThreeInAttentionOrderWithProjectNames() throws {
    let path = tempPath()
    defer { remove(path) }
    let (store, fixture) = try seededStore(at: path, link: link)
    let glance = try MirrorGlance.load(store: store)
    #expect(glance.linked)
    #expect(glance.rows.map(\.threadId) == Array(fixture.expected.order.prefix(3)))
    #expect(glance.rows.map(\.pinned) == [true, true, false])
    #expect(glance.rows.map(\.projectName) == ["Alpha", nil, "beta"])
    let ordered = Attention.ordered(try store.threads(includeArchived: false, connectionId: nil, query: nil))
    #expect(glance.rows.map(\.band) == ordered.prefix(3).map { Attention.band(of: $0) })
    #expect(glance.rows.map(\.title) == ordered.prefix(3).map(\.title))
    #expect(try MirrorGlance.load(store: store, limit: 5).rows.count == 5)
  }

  @Test func archivedThreadsAreLeftOut() throws {
    let path = tempPath()
    defer { remove(path) }
    let (store, fixture) = try seededStore(at: path, link: link)
    _ = try store.apply([change("threads", "t-pinned-working", "update", column: "archived", value: true)])
    let glance = try MirrorGlance.load(store: store)
    #expect(glance.rows.map(\.threadId) == Array(fixture.expected.order.dropFirst().prefix(3)))
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
