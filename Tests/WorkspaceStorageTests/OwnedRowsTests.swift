import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// D-184: a Mac re-announces its own rows when its hub device changes, so the hub and the phone see the
/// current device as their owner.
@Suite struct OwnedRowsTests {
  private func link(_ device: String) -> WorkspaceDatabase.HubLink {
    WorkspaceDatabase.HubLink(
      url: "http://localhost:8080", deviceId: device, deviceName: "Mac", tokenRef: "secret:t",
      orgSlug: "acme", username: "brian", joinedAt: Timestamp.now())
  }

  private func seed(_ db: WorkspaceDatabase) throws {
    _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    _ = try db.insertProject(Project(id: "p1", name: "b4app"), folders: ["/tmp/owned-rows-p1"])
    _ = try db.insertThread(
      ConversationThread(
        id: "t1", connectionId: "c1", nativeThreadId: "thr_1", nativeScope: "acct", title: "First",
        context: "/tmp/owned-rows-p1"))
  }

  @Test func aNewDeviceReannouncesEveryOwnedRowWithTheOldestClock() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    try db.saveHubLink(link("dev-old"))
    db.deviceId = "dev-old"
    #expect(try db.claimOwnedRows() == 0)  // nothing pushed yet: the upload carries every insert
    try db.markSynced(through: Int.max)

    try db.saveHubLink(link("dev-new"))
    db.deviceId = "dev-new"
    let before = try db.changes(after: 0).count
    #expect(try db.claimOwnedRows() == 3)
    let appended = Array(try db.changes(after: 0).dropFirst(before))
    #expect(appended.map(\.table).sorted() == ["connections", "environments", "threads"])
    #expect(appended.allSatisfy { $0.op == "insert" && $0.deviceId == "dev-new" && !$0.synced })
    #expect(appended.allSatisfy { $0.hlc == "000000000000-0000-dev-new" })
    #expect(appended.first { $0.table == "threads" }?.value?["title"] == .string("First"))

    // Once per device: another start, or a link saved again (a push recording its outcome), does nothing.
    #expect(try db.claimOwnedRows() == 0)
    var saved = try #require(try db.hubLink())
    saved.lastError = "something"
    try db.saveHubLink(saved)
    #expect(try db.claimOwnedRows() == 0)
  }

  @Test func aLinkFromBeforeTheMigrationReannouncesOnce() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    try db.saveHubLink(link("dev-mac"))
    db.deviceId = "dev-mac"
    try db.markSynced(through: Int.max)
    // `ownedAs` is null for every link the migration found: its rows may have been pushed by an
    // earlier device, so it re-announces them once.
    #expect(try db.claimOwnedRows() == 3)
    #expect(try db.claimOwnedRows() == 0)
  }

  @Test func noLinkClaimsNothing() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    #expect(try db.claimOwnedRows() == 0)
  }
}
