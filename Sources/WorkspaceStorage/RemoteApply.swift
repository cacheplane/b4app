import Foundation
import WorkspaceProtocol

/// A change another device wrote, as the coordinator pulled it from the hub. `deviceId` is the device
/// the hub attributes it to; `hlc` its clock. `value` is the inserted row (an object) or the updated
/// column's new value.
public struct RemoteChange: Sendable, Equatable {
  public var deviceId: String
  public var hlc: String
  public var table: String
  public var rowId: String
  public var op: String
  public var column: String?
  public var value: JSONValue?

  public init(
    deviceId: String, hlc: String, table: String, rowId: String, op: String, column: String? = nil,
    value: JSONValue? = nil
  ) {
    self.deviceId = deviceId
    self.hlc = hlc
    self.table = table
    self.rowId = rowId
    self.op = op
    self.column = column
    self.value = value
  }
}

/// What one `applyRemote` batch changed, for the events the coordinator publishes afterwards. A change
/// is `applied` when it wrote at least one column, otherwise `skipped`.
public struct RemoteApplied: Sendable, Equatable {
  public var touchedThreadIds: Set<String>
  public var touchedEnvironmentIds: Set<String>
  public var touchedDraftThreadIds: Set<String>
  /// The view settings row (`viewSettings`, id `view`) changed.
  public var touchedViewSettings: Bool
  public var applied: Int
  public var skipped: Int

  public init(
    touchedThreadIds: Set<String> = [], touchedEnvironmentIds: Set<String> = [],
    touchedDraftThreadIds: Set<String> = [], touchedViewSettings: Bool = false, applied: Int = 0,
    skipped: Int = 0
  ) {
    self.touchedThreadIds = touchedThreadIds
    self.touchedEnvironmentIds = touchedEnvironmentIds
    self.touchedDraftThreadIds = touchedDraftThreadIds
    self.touchedViewSettings = touchedViewSettings
    self.applied = applied
    self.skipped = skipped
  }
}

extension WorkspaceDatabase {
  /// Merge other devices' edits into this Mac's rows: a narrow merge, never a row copy (M8b spec, "The
  /// coordinator pulls"). The hub holds only filtered copies of the Mac's rows (blanked connection
  /// targets and secrets, hashed scopes), so nothing it sends may overwrite a Mac-only value:
  ///
  /// - A change from `ownDeviceId`, any of `macDeviceIds`, or `local` (this Mac before it joined), by
  ///   attribution or by its clock's device, is the Mac's own history and is skipped, except a change
  ///   to `viewSettings`: that row's source of truth is the hub, so another Mac's settings must reach
  ///   this one, and its per-column clocks make this Mac's own echo a no-op.
  /// - Only updates of `SyncColumns.phoneWritable` columns of `threads` and `environments` rows that exist
  ///   here apply, plus inserts and updates of `drafts` whose thread exists here, and inserts and updates
  ///   of the `viewSettings` row whose id is `view` (either creates the row when it is missing). No other
  ///   table is inserted into, no other column is written, and nothing is deleted. A null for a
  ///   `SyncColumns.neverCleared` column (a thread's delete mark) is skipped.
  /// - Each column applies only when the change's clock is greater than the column's `columnClocks`
  ///   entry (a missing entry is older than any clock), and then the entry advances to it. A draft or
  ///   view settings insert onto an existing row is one write per column at the insert's clock; a view
  ///   settings insert writes only the columns it carries with a value (a null there is "not set").
  /// - Every received clock (clamped first when it is more than five minutes ahead of this Mac's wall
  ///   clock) is folded into `clock`, so later local edits sort after it.
  /// - A change whose value the store refuses (SQLSTATE class 22 or 23) is rolled back to its own
  ///   savepoint and skipped; it never fails the batch. Any other failure (a deadlock, a lock timeout, a
  ///   cancelled statement, a lost connection) fails the whole batch, cursor included, so it is retried.
  /// - The batch holds `remoteApplyLockKey` exclusively, taken first, while every local `write` holds it
  ///   shared: a local edit is never stamped while a batch is in flight (it waits, then stamps after
  ///   every clock the batch applied), and a batch never waits on a row a local write has locked.
  ///   Each target row is still locked (`FOR UPDATE`; a draft's thread too) before its clock is read;
  ///   with the advisory lock held no `write` can hold a conflicting row lock, so these never wait, and
  ///   they double as the existence checks.
  ///
  /// Runs in one transaction with `b4app.replaying` on, so nothing is recorded in the change log (and so
  /// nothing echoes back to the hub), and sets `hubLink.cursor` to `cursor` in the same transaction even
  /// when every change was skipped.
  @discardableResult
  public func applyRemote(
    _ changes: [RemoteChange], ownDeviceId: String, macDeviceIds: Set<String>, cursor: Int
  ) throws -> RemoteApplied {
    try applyRemote(changes, ownDeviceId: ownDeviceId, macDeviceIds: macDeviceIds, cursor: cursor) { _ in }
  }

  /// `applyRemote`, calling `didLock` inside the transaction once the advisory lock is held and before
  /// any change is looked at (tests start a local write there).
  func applyRemote(
    _ changes: [RemoteChange], ownDeviceId: String, macDeviceIds: Set<String>, cursor: Int,
    didLock: (PostgresConnection) throws -> Void
  ) throws -> RemoteApplied {
    try write(exclusive: true) { c in
      try didLock(c)
      try c.execute("SET LOCAL b4app.replaying = 'on'")
      var result = RemoteApplied()
      let wall = epochMillis()
      // `local` is this Mac's id before it joined; a phone always stamps its enrolled id.
      let macs = macDeviceIds.union([ownDeviceId, "local"])
      for change in changes {
        guard let parsed = HLC(rawValue: change.hlc) else {
          result.skipped += 1
          continue
        }
        let hlc = parsed.clamped(toWall: wall)
        clock.observe(hlc)
        // The view settings row's source of truth is the hub, not a Mac, so it is the one table a Mac
        // accepts from a Mac (its own echo included): its merge is by column clock, so an echo is a
        // no-op and an older write loses.
        if change.table != "viewSettings", macs.contains(change.deviceId) || macs.contains(hlc.deviceId) {
          result.skipped += 1
          continue
        }
        try c.execute("SAVEPOINT \"remoteChange\"")
        do {
          let wrote = try merge(c, change, at: hlc.rawValue)
          try c.execute("RELEASE SAVEPOINT \"remoteChange\"")
          guard wrote else {
            result.skipped += 1
            continue
          }
          result.applied += 1
          switch change.table {
          case "threads": result.touchedThreadIds.insert(change.rowId)
          case "environments": result.touchedEnvironmentIds.insert(change.rowId)
          case "viewSettings": result.touchedViewSettings = true
          default: result.touchedDraftThreadIds.insert(change.rowId)
          }
        } catch  where Self.isDataError(error) {
          try c.execute("ROLLBACK TO SAVEPOINT \"remoteChange\"")
          try c.execute("RELEASE SAVEPOINT \"remoteChange\"")
          result.skipped += 1
        }
      }
      try c.execute("UPDATE \"hubLink\" SET \"cursor\" = $1::bigint WHERE \"id\" = 1", [String(cursor)])
      return result
    }
  }

  /// The clock of a merged column's latest write here, nil when it has none.
  public func columnClock(table: String, rowId: String, column: String) throws -> String? {
    try read {
      try $0.execute(
        "SELECT \"hlc\" FROM \"columnClocks\" WHERE \"table\" = $1 AND \"rowId\" = $2 AND \"column\" = $3",
        [table, rowId, column]
      ).rows.first?.text("hlc")
    }
  }

  /// Move the pull cursor (`hubLink.cursor`); does nothing when this Mac has not joined.
  public func setHubCursor(_ cursor: Int) throws {
    try write {
      _ = try $0.execute("UPDATE \"hubLink\" SET \"cursor\" = $1::bigint WHERE \"id\" = 1", [String(cursor)])
    }
  }

  // MARK: - The merge

  /// Applies one change that passed the device check; true when it wrote at least one column.
  private func merge(_ c: PostgresConnection, _ change: RemoteChange, at hlc: String) throws -> Bool {
    switch (change.table, change.op) {
    case ("threads", "update"), ("environments", "update"):
      guard let column = change.column, SyncColumns.isPhoneWritable(table: change.table, column: column),
        let value = change.value,
        value != .null || !SyncColumns.isNeverCleared(table: change.table, column: column),
        try lock(c, change.table, key: "id", change.rowId)
      else { return false }
      return try mergeColumn(c, table: change.table, key: "id", rowId: change.rowId, column, value, at: hlc)
    case ("drafts", "update"):
      // The key never changes; only the text and its time merge.
      guard let column = change.column, column != "threadId",
        SyncColumns.isPhoneWritable(table: "drafts", column: column), let value = change.value,
        try lock(c, "threads", key: "id", change.rowId), try lock(c, "drafts", key: "threadId", change.rowId)
      else { return false }
      return try mergeColumn(c, table: "drafts", key: "threadId", rowId: change.rowId, column, value, at: hlc)
    case ("drafts", "insert"):
      return try mergeDraft(c, change, at: hlc)
    case ("viewSettings", "update"):
      // The key never changes.
      guard change.rowId == ViewSettings.rowId, let column = change.column, column != "id",
        SyncColumns.isPhoneWritable(table: "viewSettings", column: column), let value = change.value
      else { return false }
      return try mergeViewSettings(c, [column: value], at: hlc)
    case ("viewSettings", "insert"):
      guard change.rowId == ViewSettings.rowId, let row = change.value?.objectValue,
        row["id"].map({ $0 == .string(ViewSettings.rowId) }) ?? true
      else { return false }
      // A null in an insert body is "not set" (migration 0013), never a write.
      return try mergeViewSettings(c, row.filter { $0.key != "id" && $0.value != .null }, at: hlc)
    default:
      return false
    }
  }

  /// A whole draft from another device: created when this Mac has none for an existing thread, else
  /// merged column by column at the insert's clock. Locking the thread first serialises this against a
  /// local `saveDraft` (whose foreign-key check takes a share lock on the same row), so neither side can
  /// insert the draft while the other is deciding whether it exists.
  private func mergeDraft(_ c: PostgresConnection, _ change: RemoteChange, at hlc: String) throws -> Bool {
    guard let row = change.value?.objectValue, row["threadId"].map({ $0 == .string(change.rowId) }) ?? true,
      try lock(c, "threads", key: "id", change.rowId)
    else { return false }
    let columns = ["text", "updatedAt"]
    guard try lock(c, "drafts", key: "threadId", change.rowId) else {
      guard let text = row["text"]?.stringValue, let updatedAt = row["updatedAt"]?.stringValue else {
        return false
      }
      try c.execute(
        "INSERT INTO \"drafts\" (\"threadId\", \"text\", \"updatedAt\") VALUES ($1, $2, $3)",
        [change.rowId, text, updatedAt])
      for column in ["threadId"] + columns {
        try advanceClock(c, table: "drafts", rowId: change.rowId, column: column, to: hlc)
      }
      return true
    }
    var wrote = false
    for column in columns {
      guard let value = row[column] else { continue }
      if try mergeColumn(c, table: "drafts", key: "threadId", rowId: change.rowId, column, value, at: hlc) {
        wrote = true
      }
    }
    return wrote
  }

  /// Columns of the view settings row from another device, each merged at `hlc`; the row is created
  /// first (its id alone, every other column null) when this Mac has none, so a change to one column
  /// never needs the others. True when the row was created or any column written.
  private func mergeViewSettings(
    _ c: PostgresConnection, _ columns: [String: JSONValue], at hlc: String
  ) throws -> Bool {
    var wrote = false
    if !(try lock(c, "viewSettings", key: "id", ViewSettings.rowId)) {
      try c.execute("INSERT INTO \"viewSettings\" (\"id\") VALUES ($1)", [ViewSettings.rowId])
      try advanceClock(c, table: "viewSettings", rowId: ViewSettings.rowId, column: "id", to: hlc)
      wrote = true
    }
    for (column, value) in columns.sorted(by: { $0.key < $1.key })
    where SyncColumns.isPhoneWritable(table: "viewSettings", column: column) {
      if try mergeColumn(
        c, table: "viewSettings", key: "id", rowId: ViewSettings.rowId, column, value, at: hlc)
      {
        wrote = true
      }
    }
    return wrote
  }

  /// Writes one column when `hlc` is newer than its stored clock, then advances the clock.
  private func mergeColumn(
    _ c: PostgresConnection, table: String, key: String, rowId: String, _ column: String, _ value: JSONValue,
    at hlc: String
  ) throws -> Bool {
    if let stored = try c.execute(
      "SELECT \"hlc\" FROM \"columnClocks\" WHERE \"table\" = $1 AND \"rowId\" = $2 AND \"column\" = $3",
      [table, rowId, column]
    ).rows.first?.text("hlc"), !(Self.isOlder(stored, than: hlc)) {
      return false
    }
    try c.execute(
      "UPDATE \(Rows.quote(table)) SET \(Rows.quote(column)) = $1 WHERE \(Rows.quote(key)) = $2",
      [try Rows.param(Self.foundation(value)), rowId])
    try advanceClock(c, table: table, rowId: rowId, column: column, to: hlc)
    return true
  }

  private func advanceClock(
    _ c: PostgresConnection, table: String, rowId: String, column: String, to hlc: String
  ) throws {
    try c.execute(
      """
      INSERT INTO "columnClocks" ("table", "rowId", "column", "hlc") VALUES ($1, $2, $3, $4)
      ON CONFLICT ("table", "rowId", "column") DO UPDATE SET "hlc" = EXCLUDED."hlc"
      WHERE "columnClocks"."hlc" COLLATE "C" < EXCLUDED."hlc" COLLATE "C"
      """, [table, rowId, column, hlc])
  }

  /// Locks the row for the rest of the transaction (waiting for a local writer that holds it) and says
  /// whether it exists.
  private func lock(_ c: PostgresConnection, _ table: String, key: String, _ id: String) throws -> Bool {
    !(try c.execute(
      "SELECT 1 FROM \(Rows.quote(table)) WHERE \(Rows.quote(key)) = $1 FOR UPDATE", [id]
    ).rows.isEmpty)
  }

  /// A value the store refused (data exception or integrity violation), which skips one change. Anything
  /// else is a failure of the batch.
  static func isDataError(_ error: any Error) -> Bool {
    guard let pg = error as? PostgresError else { return false }
    return pg.sqlState.hasPrefix("22") || pg.sqlState.hasPrefix("23")
  }

  /// Plain byte-order comparison, the same as `COLLATE "C"` and the hub's.
  static func isOlder(_ stored: String, than incoming: String) -> Bool {
    Array(stored.utf8).lexicographicallyPrecedes(Array(incoming.utf8))
  }
}
