import Foundation
import WorkspaceProtocol

/// One row of the change log (migration 0002): what a device wrote, in commit order on that device.
public struct ChangeRecord: Codable, Sendable, Equatable {
  public var seq: Int
  public var deviceId: String
  public var wall: Int
  public var table: String
  public var rowId: String
  public var op: String
  public var column: String?
  public var value: JSONValue?
  public var synced: Bool
  /// The hybrid logical clock of the transaction that wrote this change (migration 0004).
  public var hlc: String
}

extension WorkspaceDatabase {
  /// The synced tables, in dependency order, with their key column.
  public static let syncedTables: [(table: String, key: String)] = [
    ("connections", "id"), ("projects", "id"), ("projectFolders", "id"), ("threads", "id"), ("turns", "id"),
    ("displayItems", "id"), ("runtimeRequests", "id"), ("drafts", "threadId"),
  ]

  /// Changes after `seq`, oldest first.
  public func changes(after seq: Int, limit: Int = 10_000) throws -> [ChangeRecord] {
    try read {
      try all(
        $0, ChangeRecord.self,
        "SELECT * FROM \"changes\" WHERE \"seq\" > $1::bigint ORDER BY \"seq\" LIMIT $2::int",
        [String(seq), String(limit)])
    }
  }

  /// The oldest unsynced changes, in `seq` order.
  public func unsyncedChanges(limit: Int) throws -> [ChangeRecord] {
    try read {
      try all(
        $0, ChangeRecord.self,
        "SELECT * FROM \"changes\" WHERE NOT \"synced\" ORDER BY \"seq\" LIMIT $1::int", [String(limit)])
    }
  }

  /// Mark every change up to and including `seq` as synced (the hub accepted through it).
  public func markSynced(through seq: Int) throws {
    try write {
      _ = try $0.execute(
        "UPDATE \"changes\" SET \"synced\" = true WHERE \"seq\" <= $1::bigint AND NOT \"synced\"",
        [String(seq)])
    }
  }

  public func unsyncedChangeCount() throws -> Int {
    try read {
      try $0.execute("SELECT count(*) AS \"n\" FROM \"changes\" WHERE NOT \"synced\"").rows.first?.int("n")
        ?? 0
    }
  }

  /// Apply changes from another device (or a replay test) without recording them again: inserts
  /// become upserts, updates set one column, deletes delete. Each change runs in its own savepoint, so
  /// one the store refuses (SQLSTATE class 22 or 23: a row whose parent is missing, a value its column
  /// refuses) is skipped, not fatal, and a partial log never poisons the rest; any other failure fails
  /// the whole replay. Returns how many changes applied.
  @discardableResult
  public func replay(_ changes: [ChangeRecord]) throws -> Int {
    try write { c in
      try c.execute("SET LOCAL b4app.replaying = 'on'")
      var applied = 0
      for change in changes {
        guard let key = Self.syncedTables.first(where: { $0.table == change.table })?.key else { continue }
        try c.execute("SAVEPOINT \"replayChange\"")
        do {
          let wrote = try replayOne(c, change, key: key)
          try c.execute("RELEASE SAVEPOINT \"replayChange\"")
          if wrote { applied += 1 }
        } catch  where Self.isDataError(error) {
          try c.execute("ROLLBACK TO SAVEPOINT \"replayChange\"")
          try c.execute("RELEASE SAVEPOINT \"replayChange\"")
        }
      }
      return applied
    }
  }

  /// One change of `replay`; false when there was nothing to apply.
  private func replayOne(_ c: PostgresConnection, _ change: ChangeRecord, key: String) throws -> Bool {
    switch change.op {
    case "insert":
      guard let object = change.value?.objectValue else { return false }
      let columns = try columns(c, of: change.table).filter { object[$0] != nil }
      let values = try columns.map { try Rows.param(Self.foundation(object[$0]!)) }
      let statement = Rows.upsert(
        change.table, Array(zip(columns, values)).map { (column: $0.0, param: $0.1) }, key: key,
        allColumns: try self.columns(c, of: change.table))
      try c.execute(statement.sql, statement.params)
    case "update":
      guard let column = change.column, let value = change.value else { return false }
      try c.execute(
        "UPDATE \(Rows.quote(change.table)) SET \(Rows.quote(column)) = $1 WHERE \(Rows.quote(key)) = $2",
        [try Rows.param(Self.foundation(value)), change.rowId])
    case "delete":
      try c.execute(
        "DELETE FROM \(Rows.quote(change.table)) WHERE \(Rows.quote(key)) = $1", [change.rowId])
    default: return false
    }
    return true
  }

  /// A JSON value as the Foundation object `Rows.param` understands.
  static func foundation(_ value: JSONValue) -> Any {
    let data = (try? JSONCoding.encoder.encode(value)) ?? Data("null".utf8)
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
  }
}
