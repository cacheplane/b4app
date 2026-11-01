import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func seedThread(_ db: WorkspaceDatabase, _ id: String = "t1") throws {
  if try db.connection(id: "c1") == nil {
    _ = try db.insertConnection(
      Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
  }
  _ = try db.insertThread(
    ConversationThread(
      id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: "First", context: "/tmp/p"))
}

private func clocks(_ db: WorkspaceDatabase, table: String, rowId: String) throws -> [String: String] {
  try db.read { c in
    let rows = try c.execute(
      "SELECT \"column\", \"hlc\" FROM \"columnClocks\" WHERE \"table\" = $1 AND \"rowId\" = $2",
      [table, rowId]
    ).rows
    return Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        row.text("column").flatMap { c in row.text("hlc").map { (c, $0) } }
      })
  }
}

@Suite struct OrganisationSchemaTests {
  @Test func everyChangeCarriesAClockAndOneTransactionSharesIt() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.write { c in
      try c.execute(
        "INSERT INTO \"connections\" (\"id\", \"kind\", \"label\", \"target\", \"capabilities\", \"status\", \"authStatus\", \"createdAt\", \"updatedAt\") VALUES ('c1', 'codex', 'Codex', '/x', '{}', 'ready', 'authenticated', 'now', 'now')"
      )
      try c.execute(
        "INSERT INTO \"threads\" (\"id\", \"connectionId\", \"nativeThreadId\", \"createdAt\", \"updatedAt\") VALUES ('t1', 'c1', 'n1', 'now', 'now')"
      )
    }
    _ = try db.updateThread(id: "t1") { $0.title = "Renamed" }

    let changes = try db.changes(after: 0)
    let first = changes.filter { $0.table == "connections" || ($0.table == "threads" && $0.op == "insert") }
    #expect(first.count == 2)
    #expect(Set(first.map(\.hlc)).count == 1)
    let rename = try #require(changes.first { $0.op == "update" && $0.column == "title" })
    #expect(rename.hlc > first[0].hlc)
    for change in changes {
      let hlc = try #require(HLC(rawValue: change.hlc))
      #expect(hlc.deviceId == "local")
    }
  }

  @Test func theClockFollowsTheDeviceId() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db)
    db.deviceId = "dev-1"
    #expect(db.clock.deviceId == "dev-1")
    _ = try db.updateThread(id: "t1") { $0.pinned = true }
    let last = try #require(try db.changes(after: 0).last)
    #expect(last.deviceId == "dev-1")
    #expect(HLC(rawValue: last.hlc)?.deviceId == "dev-1")
  }

  @Test func clockedColumnsRecordTheirClock() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db)
    let insertHLC = try #require(try db.changes(after: 0).last { $0.table == "threads" }?.hlc)
    let inserted = try clocks(db, table: "threads", rowId: "t1")
    #expect(Set(inserted.keys) == SyncColumns.clocked["threads"])
    #expect(Set(inserted.values) == [insertHLC])

    _ = try db.updateThread(id: "t1") { $0.title = "Renamed" }
    let afterTitle = try clocks(db, table: "threads", rowId: "t1")
    let titleHLC = try #require(afterTitle["title"])
    #expect(titleHLC > insertHLC)
    for column in SyncColumns.clocked["threads"]!.subtracting(["title"]) {
      #expect(afterTitle[column] == insertHLC)
    }

    // continuity (and updatedAt) are Mac-only and unclocked.
    _ = try db.updateThread(id: "t1") { $0.continuity = .missing }
    let afterContinuity = try clocks(db, table: "threads", rowId: "t1")
    #expect(afterContinuity == afterTitle)
    #expect(afterContinuity["continuity"] == nil)
    #expect(afterContinuity["updatedAt"] == nil)
  }

  /// The trigger holds its own list of clocked columns; this keeps it equal to `SyncColumns.clocked`.
  @Test func theTriggerClockedListEqualsSyncColumns() throws {
    let db = try WorkspaceDatabase.temporary()
    try seedThread(db, "t1")
    try seedThread(db, "t2")
    _ = try db.write { c in
      try c.execute(
        "INSERT INTO \"projects\" (\"id\", \"name\", \"createdAt\", \"updatedAt\") VALUES ('p1', 'P', 'now', 'now')"
      )
      try c.execute(
        "INSERT INTO \"drafts\" (\"threadId\", \"text\", \"updatedAt\") VALUES ('t1', 'hello', 'now')")
    }
    let rows = ["threads": "t1", "projects": "p1", "drafts": "t1"]
    // Insert records every clocked column and nothing else.
    for (table, columns) in SyncColumns.clocked {
      #expect(Set(try clocks(db, table: table, rowId: rows[table]!).keys) == columns, "insert: \(table)")
    }
    #expect(Set(SyncColumns.clocked.keys) == Set(rows.keys))

    // Each clocked column's own update advances that column's clock and no other. A draft's key is
    // `threadId`, so updating it moves the row: that column is checked on its own below.
    let updates: [String: [String: String]] = [
      "threads": [
        "title": "'x'", "pinned": "true", "archived": "true", "readTurnId": "'u9'", "projectId": "'p1'",
      ],
      "projects": ["name": "'Renamed'"],
      "drafts": ["threadId": "'t2'", "text": "'again'", "updatedAt": "'later'"],
    ]
    let keys = ["threads": "id", "projects": "id", "drafts": "threadId"]
    for (table, columns) in SyncColumns.clocked {
      #expect(Set(updates[table]!.keys) == columns, "the update table covers \(table)")
      for column in columns.sorted() where !(table == "drafts" && column == "threadId") {
        let before = try clocks(db, table: table, rowId: rows[table]!)
        _ = try db.write {
          _ = try $0.execute(
            "UPDATE \(Rows.quote(table)) SET \(Rows.quote(column)) = \(updates[table]![column]!) WHERE \(Rows.quote(keys[table]!)) = $1",
            [rows[table]!])
        }
        let after = try clocks(db, table: table, rowId: rows[table]!)
        let advanced = Set(after.filter { before[$0.key] != $0.value }.keys)
        #expect(advanced == [column], "update: \(table).\(column) advanced \(advanced)")
      }
    }
    try db.write { _ = try $0.execute("UPDATE \"drafts\" SET \"threadId\" = 't2' WHERE \"threadId\" = 't1'") }
    #expect(try clocks(db, table: "drafts", rowId: "t2")["threadId"] != nil)
  }

  @Test func projectsAndFoldersAreSyncedAndLogged() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.write { c in
      try c.execute(
        "INSERT INTO \"projects\" (\"id\", \"createdAt\", \"updatedAt\") VALUES ('p1', 'now', 'now')")
      try c.execute(
        "INSERT INTO \"projectFolders\" (\"id\", \"projectId\", \"path\", \"createdAt\") VALUES ('f1', 'p1', '/tmp/a', 'now')"
      )
    }
    #expect(
      WorkspaceDatabase.syncedTables.map(\.table) == [
        "connections", "projects", "projectFolders", "threads", "turns", "displayItems", "runtimeRequests",
        "drafts",
      ])
    let changes = try db.changes(after: 0)
    #expect(changes.map(\.table) == ["projects", "projectFolders"])
    #expect(changes.allSatisfy { $0.op == "insert" })
    // The path is unique, and deleting a project removes its folders and unassigns its threads.
    #expect(throws: (any Error).self) {
      try db.write {
        _ = try $0.execute(
          "INSERT INTO \"projectFolders\" (\"id\", \"projectId\", \"path\", \"createdAt\") VALUES ('f2', 'p1', '/tmp/a', 'now')"
        )
      }
    }
    try seedThread(db)
    try db.write { _ = try $0.execute("UPDATE \"threads\" SET \"projectId\" = 'p1'") }
    #expect(try db.thread(id: "t1")?.projectId == "p1")
    try db.write { _ = try $0.execute("DELETE FROM \"projects\" WHERE \"id\" = 'p1'") }
    #expect(try db.thread(id: "t1")?.projectId == nil)
    #expect(try db.rowCount(table: "projectFolders") == 0)
  }

  @Test func readColumnsRoundTripAndComputedFieldsAreNeverStored() throws {
    let db = try WorkspaceDatabase.temporary()
    _ = try db.write { c in
      try c.execute(
        "INSERT INTO \"projects\" (\"id\", \"createdAt\", \"updatedAt\") VALUES ('p1', 'now', 'now')")
    }
    _ = try db.insertConnection(
      Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
    let activity = ThreadActivity(
      latestTurnId: "u1", pendingRequests: 1, lastActivityAt: "2026-10-31T12:00:00Z")
    let inserted = try db.insertThread(
      ConversationThread(
        id: "t1", connectionId: "c1", nativeThreadId: "n1", projectId: "p1", readTurnId: "u1",
        activity: activity, ownerDeviceName: "Brian's Mac"))
    #expect(inserted.activity == activity)
    let stored = try #require(try db.thread(id: "t1"))
    #expect(stored.projectId == "p1")
    #expect(stored.readTurnId == "u1")
    #expect(stored.activity == nil)
    #expect(stored.ownerDeviceName == nil)

    // An update through a struct that carries computed fields writes none of them either.
    let updated = try #require(
      try db.updateThread(id: "t1") {
        $0.title = "Renamed"
        $0.activity = activity
        $0.ownerDeviceName = "Brian's Mac"
        $0.readTurnId = "u2"
      })
    #expect(updated.title == "Renamed")
    let again = try #require(try db.thread(id: "t1"))
    #expect(again.readTurnId == "u2")
    #expect(again.activity == nil)
    #expect(again.ownerDeviceName == nil)
  }

  @Test func migrationBackfillsOldChangesAndKeepsReplayWorking() throws {
    // Build a store at migration 0003, with changes recorded by 0002's trigger and no clocks.
    let endpoint = try EphemeralPostgres.endpoint()
    let lib = try LibPQ.load(binDir: endpoint.binDir!)
    let raw = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(endpoint.database) user=\(NSUserName())")
    _ = try Migrator.applied(raw)
    for file in try Migrator.files() where file.name < "0004" {
      try raw.execute(file.sql)
      try raw.execute(
        "INSERT INTO \"schemaMigrations\" (\"name\", \"appliedAt\") VALUES ($1, 'then')", [file.name])
    }
    try raw.execute(
      "INSERT INTO \"connections\" (\"id\", \"kind\", \"label\", \"target\", \"capabilities\", \"status\", \"authStatus\", \"createdAt\", \"updatedAt\") VALUES ('c1', 'codex', 'Codex', '/x', '{}', 'ready', 'authenticated', 'now', 'now')"
    )
    try raw.execute(
      "INSERT INTO \"threads\" (\"id\", \"connectionId\", \"nativeThreadId\", \"createdAt\", \"updatedAt\") VALUES ('t1', 'c1', 'n1', 'now', 'now')"
    )
    try raw.execute(
      "UPDATE \"changes\" SET \"deviceId\" = 'dev-9', \"wall\" = 1761900001000 WHERE \"seq\" = 2")
    try raw.execute("UPDATE \"changes\" SET \"wall\" = 4096 WHERE \"seq\" = 1")

    let db = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    #expect(try db.appliedMigrations().contains("0004_organisation"))
    let old = try db.changes(after: 0)
    #expect(old.map(\.hlc) == ["000000001000-0000-local", "019a396c76e8-0000-dev-9"])
    #expect(old.allSatisfy { HLC(rawValue: $0.hlc) != nil })

    // Old rows replay into a fresh store, and a new write sorts after them.
    let target = try WorkspaceDatabase.temporary()
    #expect(try target.replay(old) == old.count)
    #expect(try target.thread(id: "t1")?.connectionId == "c1")
    _ = try db.updateThread(id: "t1") { $0.title = "New" }
    let newest = try #require(try db.changes(after: 0).last)
    #expect(newest.hlc.utf8.lexicographicallyPrecedes(old[1].hlc.utf8) == false)
  }

  @Test func exportAndRestoreCarryProjectsAndClocks() throws {
    let source = try WorkspaceDatabase.temporary()
    try seedThread(source)
    _ = try source.write { c in
      try c.execute(
        "INSERT INTO \"projects\" (\"id\", \"name\", \"createdAt\", \"updatedAt\") VALUES ('p1', 'P', 'now', 'now')"
      )
      try c.execute(
        "INSERT INTO \"projectFolders\" (\"id\", \"projectId\", \"path\", \"createdAt\") VALUES ('f1', 'p1', '/tmp/a', 'now')"
      )
      try c.execute("UPDATE \"threads\" SET \"projectId\" = 'p1', \"readTurnId\" = 'u1' WHERE \"id\" = 't1'")
    }
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    try source.export(to: path)
    let target = try WorkspaceDatabase.temporary()
    try target.restore(from: path)
    #expect(try target.thread(id: "t1")?.projectId == "p1")
    #expect(try target.rowCount(table: "projects") == 1)
    #expect(try target.rowCount(table: "projectFolders") == 1)
    #expect(
      try clocks(target, table: "threads", rowId: "t1") == clocks(source, table: "threads", rowId: "t1"))
    #expect(try target.changes(after: 0) == source.changes(after: 0))
  }

  /// An archive written before clocks existed has no `hlc` on its changes; restoring one derives it.
  @Test func restoreReadsAnArchiveWithoutClocks() throws {
    let source = try WorkspaceDatabase.temporary()
    try seedThread(source)
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    try source.export(to: path)
    var lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    var header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
    header["version"] = 2
    lines[0] = String(decoding: try JSONSerialization.data(withJSONObject: header), as: UTF8.self)
    for index in lines.indices.dropFirst() {
      var line = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as! [String: Any]
      guard line["table"] as? String == "changes", var row = line["row"] as? [String: Any] else { continue }
      row["hlc"] = nil
      line["row"] = row
      lines[index] = String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

    let target = try WorkspaceDatabase.temporary()
    try target.restore(from: path)
    let restored = try target.changes(after: 0)
    #expect(!restored.isEmpty)
    for change in restored {
      #expect(change.hlc == String(format: "%012llx", change.wall) + "-0000-" + change.deviceId)
    }
  }
}
