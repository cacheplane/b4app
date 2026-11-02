import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

@Suite struct HubLinkTests {
  @Test func hubLinkRoundTripsAndClearResetsSyncedFlags() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(try db.hubLink() == nil)
    let link = WorkspaceDatabase.HubLink(
      url: "http://localhost:8080", deviceId: "dev-1", deviceName: "Mac", tokenRef: "secret-ref",
      orgSlug: "acme", username: "brian", cursor: 0, lastPushAt: nil, lastError: nil,
      joinedAt: "2026-10-31T12:00:00.000Z")
    try db.saveHubLink(link)
    #expect(try db.hubLink() == link)
    var updated = link
    updated.lastError = "boom"
    updated.lastPushAt = "2026-10-31T12:01:00.000Z"
    try db.saveHubLink(updated)
    #expect(try db.hubLink() == updated)

    _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    _ = try db.insertThread(
      ConversationThread(
        id: "t1", connectionId: "c1", nativeThreadId: "thr_1", nativeScope: "acct", title: "First",
        context: "/tmp/p"))
    let all = try db.changes(after: 0)
    #expect(all.count >= 2)
    #expect(try db.unsyncedChanges(limit: 1).map(\.seq) == [all[0].seq])

    try db.markSynced(through: all[0].seq)
    #expect(try db.unsyncedChangeCount() == all.count - 1)
    #expect(try db.unsyncedChanges(limit: 100).map(\.seq) == all.dropFirst().map(\.seq))
    try db.markSynced(through: all[all.count - 1].seq)
    #expect(try db.unsyncedChangeCount() == 0)

    try db.clearHubLink()
    #expect(try db.hubLink() == nil)
    #expect(try db.unsyncedChangeCount() == all.count)
  }

  @Test func deviceIdIsRecordedOnChanges() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(db.deviceId == "local")
    _ = try db.insertConnection(Connection(id: "c0", kind: .codex, label: "Before", target: "/bin/codex"))
    db.deviceId = "dev-1"
    _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    let changes = try db.changes(after: 0)
    #expect(changes.first?.deviceId == "local")
    #expect(changes.last?.deviceId == "dev-1")
    db.deviceId = "local"
    _ = try db.updateConnection(id: "c1") { $0.label = "Renamed" }
    #expect(try db.changes(after: 0).last?.deviceId == "local")
  }
}

@Suite struct LegacyHubURLTests {
  @Test func readsTheLinkedURLWithoutMigratingOrWriting() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(try WorkspaceDatabase.linkedHubURL(endpoint: db.endpoint, binDir: db.endpoint.binDir!) == nil)
    try db.saveHubLink(
      WorkspaceDatabase.HubLink(
        url: "http://localhost:8080", deviceId: "dev-1", deviceName: "Mac", tokenRef: "secret:t",
        orgSlug: "acme", username: "brian", joinedAt: "2026-10-31T12:00:00.000Z"))
    let before = try db.changes(after: 0).count
    #expect(
      try WorkspaceDatabase.linkedHubURL(endpoint: db.endpoint, binDir: db.endpoint.binDir!)
        == "http://localhost:8080")
    #expect(try db.changes(after: 0).count == before)
  }

  @Test func aMissingDatabaseOrTableReadsAsNoLink() throws {
    let db = try WorkspaceDatabase.temporary()
    var missing = db.endpoint
    missing.database = "no_such_database_\(UUID().uuidString.prefix(8).lowercased())"
    #expect(try WorkspaceDatabase.linkedHubURL(endpoint: missing, binDir: db.endpoint.binDir!) == nil)
  }

  @Test func aDatabaseWithoutTheTableReadsAsNoLinkAndStaysUnmigrated() throws {
    let endpoint = try EphemeralPostgres.endpoint()  // created, never migrated
    #expect(try WorkspaceDatabase.linkedHubURL(endpoint: endpoint, binDir: endpoint.binDir!) == nil)
    let lib = try LibPQ.load(binDir: endpoint.binDir!)
    let connection = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    let tables = try connection.execute(
      "SELECT count(*) AS n FROM information_schema.tables WHERE table_schema = 'public'"
    ).rows.first?.int("n")
    #expect(tables == 0)
  }
}
