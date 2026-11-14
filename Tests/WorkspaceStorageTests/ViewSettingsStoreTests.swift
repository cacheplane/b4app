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
    // A column it did not set is neither carried nor clocked, so it never claims another device's value.
    #expect(insert.value?["quietThreads"] == nil && insert.value?["showArchived"] == nil)
    #expect(insert.value?.objectValue.map { Set($0.keys) } == ["id", "arrangement", "updatedAt"])
    #expect(insert.value?["updatedAt"]?.stringValue != nil)
    for column in ["quietThreads", "showArchived"] {
      #expect(try db.columnClock(table: "viewSettings", rowId: "view", column: column) == nil)
    }
    for column in ["id", "arrangement", "updatedAt"] {
      #expect(try db.columnClock(table: "viewSettings", rowId: "view", column: column) == insert.hlc)
    }

    let second = try db.setViewSettings(showArchived: true)
    #expect(second == ViewSettings(arrangement: .byEnvironment, showArchived: true))
    let updates = try viewChanges(db).dropFirst()
    #expect(updates.allSatisfy { $0.op == "update" && $0.rowId == "view" })
    #expect(Set(updates.compactMap(\.column)) == ["showArchived", "updatedAt"])
    #expect(updates.count == 2)
    #expect(updates.first { $0.column == "showArchived" }?.value == .bool(true))
    #expect(try db.viewSettings() == second)
    #expect(try storedRow(db)?["quietThreads"] == .some(nil))
    // The later write clocks its own column.
    let archived = try #require(updates.first { $0.column == "showArchived" })
    #expect(try db.columnClock(table: "viewSettings", rowId: "view", column: "showArchived") == archived.hlc)
    #expect(try db.columnClock(table: "viewSettings", rowId: "view", column: "quietThreads") == nil)

    // Replaying the log rebuilds the row from an insert that omits keys.
    let target = try WorkspaceDatabase.temporary()
    #expect(try target.replay(try db.changes(after: 0)) == viewChanges(db).count)
    #expect(try storedRow(target) == storedRow(db))
  }

  @Test func aRemoteChangeToOneColumnKeepsTheOthers() throws {
    let db = try joined()
    _ = try db.setViewSettings(arrangement: .byEnvironment, showArchived: true)
    let local = try #require(
      try db.columnClock(table: "viewSettings", rowId: "view", column: "arrangement").flatMap(
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
    let after = try db.setViewSettings(quietThreads: .collapsed)
    #expect(after == ViewSettings(quietThreads: .collapsed))
    #expect(try storedRow(db)?["arrangement"] == .some("spiral"))
    #expect(
      try viewChanges(db).filter { $0.op == "update" }.compactMap(\.column).sorted() == [
        "quietThreads", "updatedAt",
      ])
  }

  @Test func densityIsStoredAndReadBack() throws {
    let db = try WorkspaceDatabase.temporary()
    #expect(try db.setViewSettings(density: .dense) == ViewSettings(density: .dense))
    #expect(try db.viewSettings() == ViewSettings(density: .dense))
    #expect(try storedRow(db)?["density"] == .some("dense"))
    let inserted = try viewChanges(db)
    #expect(inserted.count == 1)
    let insert = try #require(inserted.first)
    #expect(insert.op == "insert" && insert.value?["density"] == "dense")
    #expect(insert.value?["quietThreads"] == nil)
    #expect(try db.columnClock(table: "viewSettings", rowId: "view", column: "density") == insert.hlc)
    #expect(try db.columnClock(table: "viewSettings", rowId: "view", column: "quietThreads") == nil)
  }

  /// A row an older build wrote (`tiny`, no density) that the migration has not seen, such as one a
  /// remote change brought in: setting the sidebar alone keeps the dense rows `tiny` implied.
  @Test func aSidebarChangeOnAnUnconvertedRowKeepsDense() throws {
    let db = try WorkspaceDatabase.temporary()
    try db.write { c in
      try c.execute("SET LOCAL b4app.replaying = 'on'")
      try c.execute("INSERT INTO \"viewSettings\" (\"id\", \"quietThreads\") VALUES ('view', 'tiny')")
    }
    #expect(try db.viewSettings() == ViewSettings(quietThreads: .shown, density: .dense))
    let after = try db.setViewSettings(quietThreads: .collapsed)
    #expect(after == ViewSettings(quietThreads: .collapsed, density: .dense))
    #expect(try storedRow(db)?["density"] == .some("dense"))
    #expect(try storedRow(db)?["quietThreads"] == .some("collapsed"))
    #expect(try db.viewSettings() == after)
    // A density given with it wins over the implied one.
    let fresh = try WorkspaceDatabase.temporary()
    try fresh.write { c in
      try c.execute("SET LOCAL b4app.replaying = 'on'")
      try c.execute("INSERT INTO \"viewSettings\" (\"id\", \"quietThreads\") VALUES ('view', 'tiny')")
    }
    #expect(
      try fresh.setViewSettings(quietThreads: .hidden, density: .normal)
        == ViewSettings(quietThreads: .hidden, density: .normal))
    #expect(try storedRow(fresh)?["density"] == .some("normal"))
    // A stored density this build does not know is a newer build's value: it is kept.
    let newer = try WorkspaceDatabase.temporary()
    try newer.write { c in
      try c.execute("SET LOCAL b4app.replaying = 'on'")
      try c.execute(
        "INSERT INTO \"viewSettings\" (\"id\", \"quietThreads\", \"density\") VALUES ('view', 'tiny', 'huge')"
      )
    }
    try newer.setViewSettings(quietThreads: .collapsed)
    #expect(try storedRow(newer)?["density"] == .some("huge"))
    #expect(try storedRow(newer)?["quietThreads"] == .some("collapsed"))
  }

  /// Migration 0015 rewrites the old sidebar values into `quietThreads` and `density`, logging and
  /// clocking nothing.
  @Test(arguments: [
    (old: "small" as String?, quietThreads: "shown" as String?, density: "normal" as String?),
    (old: "tiny", quietThreads: "shown", density: "dense"),
    (old: "collapsed", quietThreads: "collapsed", density: "normal"),
    (old: "hidden", quietThreads: "hidden", density: "normal"),
    (old: nil, quietThreads: nil, density: nil),
  ])
  func theMigrationConvertsEachOldValue(
    _ row: (old: String?, quietThreads: String?, density: String?)
  ) throws {
    let root =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory()
      + "view-density-migration-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let endpoint = try EphemeralPostgres.endpoint()
    let lib = try LibPQ.load(binDir: endpoint.binDir!)
    let raw = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(endpoint.database) user=\(NSUserName())")
    _ = try Migrator.applied(raw)
    for file in try Migrator.files() where file.name < "0015" {
      try raw.execute(file.sql)
      try raw.execute(
        "INSERT INTO \"schemaMigrations\" (\"name\", \"appliedAt\") VALUES ($1, 'then')", [file.name])
    }
    // The row an older build wrote, logged and clocked as it would have been.
    try raw.execute(
      "INSERT INTO \"viewSettings\" (\"id\", \"arrangement\", \"quietThreads\") VALUES ('view', 'byEnvironment', $1)",
      [row.old])
    func state() throws -> (changes: String?, clocks: String?) {
      let changes = try raw.execute("SELECT count(*)::text AS n FROM \"changes\"").rows.first?.text("n")
      let clocks = try raw.execute(
        "SELECT string_agg(\"table\" || '.' || \"rowId\" || '.' || \"column\" || '=' || \"hlc\", ',' ORDER BY \"table\", \"rowId\", \"column\") AS c FROM \"columnClocks\""
      ).rows.first?.text("c")
      return (changes, clocks)
    }
    let before = try state()
    #expect(before.changes == "1")

    let db = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backups")
    let outcome = Result<Void, any Error> { () throws -> Void in
      let ledger = try db.appliedMigrations()
      #expect(ledger.contains("0015_density") && ledger.last == "0016_agent_protocol")
      #expect(ledger == AgentProtocolFoundationFixture.migrations)
      let stored = try #require(try storedRow(db))
      #expect(stored["quietThreads"] == .some(row.quietThreads))
      #expect(stored["density"] == .some(row.density))
      #expect(stored["arrangement"] == .some("byEnvironment"))
      let after = try state()
      #expect(after.changes == before.changes && after.clocks == before.clocks)
      // The migration leaves replaying off: a later write is logged.
      _ = try db.setViewSettings(showArchived: true)
      #expect(try viewChanges(db).contains { $0.op == "update" && $0.column == "showArchived" })
    }
    switch outcome {
    case .success: try db.close()
    case .failure: try? db.close()
    }
    try outcome.get()
  }

  @Test func viewSettingsSurviveBackupAndRestore() throws {
    let source = try WorkspaceDatabase.temporary()
    let set = try source.setViewSettings(
      arrangement: .byEnvironment, quietThreads: .hidden, showArchived: true)
    let path =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory()
      + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
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

  /// A store whose only row is its view settings counts as empty to a restore (it has no connections),
  /// so the archive's `view` row replaces the local one instead of colliding with it.
  @Test func aRestoreOntoAStoreWithOnlyViewSettingsTakesTheArchivedRow() throws {
    let source = try WorkspaceDatabase.temporary()
    _ = try source.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/bin/codex"))
    let archived = try source.setViewSettings(arrangement: .byEnvironment, quietThreads: .collapsed)
    let path =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory()
      + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let summary = try source.export(to: path)

    let target = try WorkspaceDatabase.temporary()
    _ = try target.setViewSettings(quietThreads: .hidden, showArchived: true)
    #expect(try target.restore(from: path).rows == summary.rows)
    #expect(try target.viewSettings() == archived)
    #expect(try storedRow(target) == storedRow(source))
    #expect(try target.listConnections().map(\.id) == ["c1"])
  }
}
