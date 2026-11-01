import Foundation
import SQLite3
import WorkspaceProtocol
import WorkspaceSync

/// Applying the hub's changes and snapshots: the clock-aware replay described on `MirrorStore`.
extension MirrorStore {
  // MARK: - Applying changes

  public func apply(_ changes: [StoredChange]) throws -> AppliedBatch {
    try locked {
      try transaction {
        var state = BatchState()
        try applyChanges(changes, into: &state)
        return try finish(state)
      }
    }
  }

  /// Replaces the mirror with the hub's snapshot after `resync_required`: clears every row table and
  /// `columnClocks` (the outbox, the link, and the `deviceSeq` high-water mark stay), applies the
  /// snapshot's rows, takes its clocks as the column clocks, sets the cursor to `next`, and applies
  /// the outbox's pending edits on top by the same clock rule, so unsent edits still show unless the
  /// snapshot holds a newer write. One transaction.
  @discardableResult
  public func applySnapshot(_ snapshot: SnapshotResponse) throws -> AppliedBatch {
    try locked {
      try transaction {
        try deleteRows()
        var state = BatchState()
        try applyChanges(snapshot.changes, into: &state)
        try exec(#"DELETE FROM "columnClocks""#)
        let now = wall()
        for entry in snapshot.clocks {
          guard let parsed = HLC(rawValue: entry.hlc) else { continue }
          let hlc = parsed.clamped(toWall: now)
          clock.observe(hlc)
          try run(
            #"INSERT OR REPLACE INTO "columnClocks" ("table", "rowId", "column", "hlc") VALUES (?, ?, ?, ?)"#,
            [.text(entry.table), .text(entry.rowId), .text(entry.column), .text(hlc.rawValue)])
        }
        let own = clock.deviceId
        let pending = try outboxRows(limit: nil).map {
          StoredChange(
            hubSeq: 0, deviceId: own, deviceSeq: $0.deviceSeq, wall: $0.wall, table: $0.table,
            rowId: $0.rowId,
            op: $0.op, column: $0.column, value: $0.value, hlc: $0.hlc)
        }
        try applyChanges(pending, into: &state)
        try run(#"UPDATE "syncState" SET "cursor" = ? WHERE "id" = 1"#, [.integer(Int64(snapshot.next))])
        return try finish(state)
      }
    }
  }

  /// What a batch has done so far, inside its transaction.
  struct BatchState {
    var batch = AppliedBatch()
    var itemIds: [String] = []
    var written: [(table: String, rowId: String)] = []
    var deleted: [(table: String, rowId: String)] = []
  }

  enum Outcome {
    /// Not applied: an unknown table, column, or op, a missing value, or a violated constraint.
    case skipped
    /// Every column it carried lost to a newer clock.
    case unchanged
    case applied
  }

  /// The column that names a row's parent thread or project, for the touched sets.
  private static let parentColumns: [String: String] = [
    "turns": "threadId", "runtimeRequests": "threadId", "projectFolders": "projectId",
  ]

  /// Applies changes inside the open transaction, in order.
  func applyChanges(_ changes: [StoredChange], into state: inout BatchState) throws {
    let now = wall()
    for change in changes {
      guard let parsed = HLC(rawValue: change.hlc) else {
        state.batch.skipped += 1
        continue
      }
      let hlc = parsed.clamped(toWall: now)
      clock.observe(hlc)
      var parents: Set<String> = []
      if let column = Self.parentColumns[change.table] {
        if change.op == "insert" {
          if let id = change.value?[column]?.stringValue { parents.insert(id) }
        } else {
          if let id = try parent(of: change.table, rowId: change.rowId, column: column) { parents.insert(id) }
          if change.column == column, let id = change.value?.stringValue { parents.insert(id) }
        }
      }
      switch try applyOne(change, at: hlc.rawValue) {
      case .skipped:
        state.batch.skipped += 1
        continue
      case .unchanged:
        continue
      case .applied:
        break
      }
      let key = (change.table, change.rowId)
      if change.op == "delete" {
        state.written.removeAll { $0 == key }
        state.deleted.append(key)
      } else if !state.written.contains(where: { $0 == key }) {
        state.written.append(key)
      }
      switch change.table {
      case "connections": state.batch.touchedConnectionIds.insert(change.rowId)
      case "threads": state.batch.touchedThreadIds.insert(change.rowId)
      case "projects": state.batch.touchedProjectIds.insert(change.rowId)
      case "turns", "runtimeRequests": state.batch.touchedThreadIds.formUnion(parents)
      case "projectFolders": state.batch.touchedProjectIds.formUnion(parents)
      case "displayItems" where change.op != "delete":
        if !state.itemIds.contains(change.rowId) { state.itemIds.append(change.rowId) }
      default: break
      }
    }
  }

  /// Inside the open transaction: the batch's decodability bookkeeping, clocks of rows a delete took
  /// away, and the display items it wrote, as they now read.
  func finish(_ state: BatchState) throws -> AppliedBatch {
    var batch = state.batch
    batch.undecodableRows = try trackDecodability(written: state.written, deleted: state.deleted)
    if !state.deleted.isEmpty {
      for (table, key) in MirrorSchema.syncedTables where SyncColumns.clocked[table] != nil {
        try run(
          #"DELETE FROM "columnClocks" WHERE "table" = ? AND NOT EXISTS (SELECT 1 FROM "#
            + Self.quote(table) + " WHERE " + Self.quote(key) + #" = "columnClocks"."rowId")"#,
          [.text(table)])
      }
    }
    batch.touchedItems = try state.itemIds.compactMap {
      try one(DisplayItem.self, "displayItems", #"SELECT * FROM "displayItems" WHERE "id" = ?"#, [.text($0)])
    }
    return batch
  }

  private func parent(of table: String, rowId: String, column: String) throws -> String? {
    let cell = try query(
      "SELECT \(Self.quote(column)) AS \"p\" FROM \(Self.quote(table)) WHERE \"id\" = ?", [.text(rowId)]
    ).first?["p"]
    if case .text(let id)? = cell { return id }
    return nil
  }

  /// Inside the open transaction: decodes each row the batch wrote (one at a time) and records it in
  /// `undecodableRows` or clears it there; forgets deleted rows and rows a delete cascaded away.
  /// Returns how many written rows do not decode.
  private func trackDecodability(
    written: [(table: String, rowId: String)], deleted: [(table: String, rowId: String)]
  ) throws -> Int {
    var undecodable = 0
    for (table, rowId) in written {
      guard let key = MirrorSchema.syncedTables.first(where: { $0.table == table })?.key else { continue }
      let row = try query("SELECT * FROM \(Self.quote(table)) WHERE \(Self.quote(key)) = ?", [.text(rowId)])
        .first
      if let row, !decodes(table: table, row) {
        undecodable += 1
        try run(
          #"INSERT INTO "undecodableRows" ("table", "rowId") VALUES (?, ?) ON CONFLICT DO NOTHING"#,
          [.text(table), .text(rowId)])
      } else {
        try run(
          #"DELETE FROM "undecodableRows" WHERE "table" = ? AND "rowId" = ?"#, [.text(table), .text(rowId)])
      }
    }
    for (table, rowId) in deleted {
      try run(
        #"DELETE FROM "undecodableRows" WHERE "table" = ? AND "rowId" = ?"#, [.text(table), .text(rowId)])
    }
    if !deleted.isEmpty {
      for (table, key) in MirrorSchema.syncedTables {
        try run(
          #"DELETE FROM "undecodableRows" WHERE "table" = ? AND NOT EXISTS (SELECT 1 FROM "#
            + Self.quote(table) + " WHERE " + Self.quote(key) + #" = "undecodableRows"."rowId")"#,
          [.text(table)])
      }
    }
    return undecodable
  }

  /// Applies one change at `hlc` inside the open transaction.
  func applyOne(_ change: StoredChange, at hlc: String) throws -> Outcome {
    guard let key = MirrorSchema.syncedTables.first(where: { $0.table == change.table })?.key,
      let declared = columns[change.table]
    else { return .skipped }
    let table = change.table
    let clocked = (SyncColumns.clocked[table] ?? []).filter { declared[$0] != nil }
    do {
      switch change.op {
      case "insert":
        guard var object = change.value?.objectValue else { return .skipped }
        if object[key] == nil { object[key] = .string(change.rowId) }
        for column in MirrorSchema.localColumns { object[column] = nil }
        if table == "connections" { Self.blankConnection(&object) }
        if MirrorSchema.ownedTables.contains(table) { object["ownerDeviceId"] = .string(change.deviceId) }
        // On an existing row, a clocked column whose stored clock is not older keeps its value.
        var losing: Set<String> = []
        if try exists(table, key: key, change.rowId) {
          for column in clocked where column != key {
            if let stored = try columnClockLocked(table, change.rowId, column),
              !Self.isOlder(stored, than: hlc)
            {
              losing.insert(column)
            }
          }
        }
        let provided = object.keys.filter { declared[$0] != nil }.sorted()
        let assigned = declared.keys.filter { $0 != key && !losing.contains($0) }.sorted()
        if assigned.isEmpty, !losing.isEmpty { return .unchanged }
        let assignments = assigned.map {
          provided.contains($0)
            ? "\(Self.quote($0)) = excluded.\(Self.quote($0))" : "\(Self.quote($0)) = NULL"
        }
        let sql =
          "INSERT INTO \(Self.quote(table)) (\(provided.map(Self.quote).joined(separator: ", "))) VALUES ("
          + Array(repeating: "?", count: provided.count).joined(separator: ", ") + ") ON CONFLICT ("
          + Self.quote(key) + ") DO "
          + (assignments.isEmpty ? "NOTHING" : "UPDATE SET " + assignments.joined(separator: ", "))
        try run(sql, provided.map { bindable(object[$0]!, table: table, column: $0) })
        for column in clocked where !losing.contains(column) {
          try advanceClock(table, change.rowId, column, to: hlc)
        }
      case "update":
        guard let column = change.column, declared[column] != nil,
          !MirrorSchema.localColumns.contains(column),
          var value = change.value
        else { return .skipped }
        if clocked.contains(column), let stored = try columnClockLocked(table, change.rowId, column),
          !Self.isOlder(stored, than: hlc)
        {
          return .unchanged
        }
        if table == "connections", let blank = Self.connectionBlanks[column] { value = blank }
        try run(
          "UPDATE \(Self.quote(table)) SET \(Self.quote(column)) = ? WHERE \(Self.quote(key)) = ?",
          [bindable(value, table: table, column: column), .text(change.rowId)])
        // A clock is kept only for a row that exists.
        if clocked.contains(column), changedRows > 0 {
          try advanceClock(table, change.rowId, column, to: hlc)
        }
      case "delete":
        try run("DELETE FROM \(Self.quote(table)) WHERE \(Self.quote(key)) = ?", [.text(change.rowId)])
        try run(
          #"DELETE FROM "columnClocks" WHERE "table" = ? AND "rowId" = ?"#,
          [.text(table), .text(change.rowId)])
      default:
        return .skipped
      }
    } catch let error as SQLiteError where error.isConstraint {
      return .skipped
    }
    return .applied
  }

  func exists(_ table: String, key: String, _ rowId: String) throws -> Bool {
    !(try query("SELECT 1 FROM \(Self.quote(table)) WHERE \(Self.quote(key)) = ?", [.text(rowId)]).isEmpty)
  }

  func columnClockLocked(_ table: String, _ rowId: String, _ column: String) throws -> String? {
    let cell = try query(
      #"SELECT "hlc" FROM "columnClocks" WHERE "table" = ? AND "rowId" = ? AND "column" = ?"#,
      [.text(table), .text(rowId), .text(column)]
    ).first?["hlc"]
    if case .text(let hlc)? = cell { return hlc }
    return nil
  }

  /// Moves a column's clock forward to `hlc`; never back.
  func advanceClock(_ table: String, _ rowId: String, _ column: String, to hlc: String) throws {
    try run(
      """
      INSERT INTO "columnClocks" ("table", "rowId", "column", "hlc") VALUES (?, ?, ?, ?)
      ON CONFLICT ("table", "rowId", "column") DO UPDATE SET "hlc" = excluded."hlc"
      WHERE "columnClocks"."hlc" < excluded."hlc"
      """, [.text(table), .text(rowId), .text(column), .text(hlc)])
  }

  /// Plain byte-order comparison, as SQLite's `BINARY` collation, the Mac's `COLLATE "C"`, and the hub.
  static func isOlder(_ stored: String, than incoming: String) -> Bool {
    Array(stored.utf8).lexicographicallyPrecedes(Array(incoming.utf8))
  }

  /// What the mirror stores for a connection's secret and machine-local columns, whatever arrived.
  private static let connectionBlanks: [String: JSONValue] = [
    "authReference": .null, "localServerId": .null, "target": .string(""),
  ]

  private static func blankConnection(_ object: inout [String: JSONValue]) {
    for (column, blank) in connectionBlanks { object[column] = blank }
  }
}
