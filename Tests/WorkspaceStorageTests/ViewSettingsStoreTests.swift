import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private let mac = "dev-mac"
private let phone = "dev-phone"

private func stamp(_ millis: UInt64, _ device: String) -> String {
  HLC(millis: millis, counter: 0, deviceId: device).rawValue
}

/// A Mac joined to a hub as `mac`, so changes from `phone` merge.
private func joined() throws -> WorkspaceDatabase {
  let db = try WorkspaceDatabase.temporary()
  try db.saveHubLink(
    WorkspaceDatabase.HubLink(
      url: "http://localhost:8080", deviceId: mac, deviceName: "Mac", tokenRef: "ref", orgSlug: "acme",
      username: "brian", joinedAt: "2026-10-31T12:00:00.000Z"))
  db.deviceId = mac
  return db
}

/// The stored row's raw columns (nil when there is no row), so a value this build does not know shows.
private func storedRow(_ db: WorkspaceDatabase) throws -> [String: String?]? {
  try db.read {
    try $0.execute("SELECT * FROM \"viewSettings\" WHERE \"id\" = 'view'").rows.first.map { row in
      row.cells.mapValues(\.text)
    }
  }
}

private func viewChanges(_ db: WorkspaceDatabase) throws -> [ChangeRecord] {
  try db.changes(after: 0).filter { $0.table == "viewSettings" }
}

@Suite struct ViewSettingsStoreTests {
  @Test func readingWithNoRowGivesDefaultsAndWritesNothing() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(try db.viewSettings() == ViewSettings())
    #expect(try storedRow(db) == nil)
    #expect(try db.changes(after: 0).isEmpty)
    // A set with nothing in it writes nothing either.
    #expect(try db.setViewSettings() == ViewSettings())
    #expect(try storedRow(db) == nil)
    #expect(try db.changes(after: 0).isEmpty)
  }

  @Test func settingOneFieldWritesOnlyThatColumn() throws {
    let db = try WorkspaceDatabase.temporary()
    let first = try db.setViewSettings(arrangement: .byEnvironment)
    #expect(first == ViewSettings(arrangement: .byEnvironment))
    let inserted = try viewChanges(db)
    #expect(inserted.count == 1)
    let insert = try #require(inserted.first)
    #expect(insert.op == "insert" && insert.rowId == "view")
    #expect(insert.value?["arrangement"] == "byEnvironment")
    #expect(insert.value?["quietThreads"] == .some(.null) && insert.value?["showArchived"] == .some(.null))
    #expect(insert.value?["updatedAt"]?.stringValue != nil)

    let second = try db.setViewSettings(showArchived: true)
    #expect(second == ViewSettings(arrangement: .byEnvironment, showArchived: true))
    let updates = try viewChanges(db).dropFirst()
    #expect(updates.allSatisfy { $0.op == "update" && $0.rowId == "view" })
    #expect(Set(updates.compactMap(\.column)) == ["showArchived", "updatedAt"])
    #expect(updates.count == 2)
    #expect(updates.first { $0.column == "showArchived" }?.value == .bool(true))
    #expect(try db.viewSettings() == second)
    #expect(try storedRow(db)?["quietThreads"] == .some(nil))
  }

  @Test func aRemoteChangeToOneColumnKeepsTheOthers() throws {
    let db = try joined()
    _ = try db.setViewSettings(arrangement: .byEnvironment, showArchived: true)
    let local = try #require(
      try db.columnClock(table: "viewSettings", rowId: "view", column: "quietThreads").flatMap(
        HLC.init(rawValue:)))
    let applied = try db.applyRemote(
      [
        RemoteChange(
          deviceId: phone, hlc: stamp(local.millis + 1, phone), table: "viewSettings", rowId: "view",
          op: "update", column: "quietThreads", value: "collapsed")
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 1)
    #expect(applied.applied == 1 && applied.touchedViewSettings)
    #expect(
      try db.viewSettings()
        == ViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed, showArchived: true))
  }

  @Test func anOlderRemoteClockLoses() throws {
    let db = try joined()
    _ = try db.setViewSettings(quietThreads: .hidden)
    let local = try #require(
      try db.columnClock(table: "viewSettings", rowId: "view", column: "quietThreads").flatMap(
        HLC.init(rawValue:)))
    let applied = try db.applyRemote(
      [
        RemoteChange(
          deviceId: phone, hlc: stamp(local.millis - 1, phone), table: "viewSettings", rowId: "view",
          op: "update", column: "quietThreads", value: "tiny")
      ], ownDeviceId: mac, macDeviceIds: [mac], cursor: 1)
    #expect(applied.applied == 0 && applied.skipped == 1 && !applied.touchedViewSettings)
    #expect(try db.viewSettings().quietThreads == .hidden)
  }

  @Test func anUnknownStoredValueSurvivesALocalWriteToAnotherField() throws {
    let db = try WorkspaceDatabase.temporary()
    try db.write {
      _ = try $0.execute(
        "INSERT INTO \"viewSettings\" (\"id\", \"arrangement\", \"quietThreads\") VALUES ('view', 'spiral', 'micro')"
      )
    }
    #expect(try db.viewSettings() == ViewSettings())
    let after = try db.setViewSettings(quietThreads: .tiny)
    #expect(after == ViewSettings(quietThreads: .tiny))
    #expect(try storedRow(db)?["arrangement"] == .some("spiral"))
    #expect(
      try viewChanges(db).filter { $0.op == "update" }.compactMap(\.column).sorted() == [
        "quietThreads", "updatedAt",
      ])
  }

  @Test func viewSettingsSurviveBackupAndRestore() throws {
    let source = try WorkspaceDatabase.temporary()
    let set = try source.setViewSettings(
      arrangement: .byEnvironment, quietThreads: .hidden, showArchived: true)
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let summary = try source.export(to: path)
    #expect(try source.tableCounts()["viewSettings"] == 1)

    let target = try WorkspaceDatabase.temporary()
    #expect(try target.restore(from: path).rows == summary.rows)
    #expect(try target.viewSettings() == set)
    #expect(try storedRow(target) == storedRow(source))
    #expect(try target.changes(after: 0) == source.changes(after: 0))
    for column in ["arrangement", "quietThreads", "showArchived", "updatedAt"] {
      #expect(
        try target.columnClock(table: "viewSettings", rowId: "view", column: column)
          == source.columnClock(table: "viewSettings", rowId: "view", column: column))
    }
  }
}
