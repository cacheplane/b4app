import Foundation
import WorkspaceProtocol
import WorkspaceSync

/// The phone's own edits (M8b spec, "Phone writes"): only `SyncColumns.phoneWritable` columns. Each
/// write applies to the mirror at once, so the UI shows it, and in the same SQLite transaction stamps
/// one `clock.next()` for the whole write, advances `columnClocks` for the columns it wrote, and appends
/// one outbox row per changed column (a new draft is one insert row) for `MirrorSync` to push. A write
/// that changes nothing stamps nothing and queues nothing. No write touches `threads.updatedAt` or
/// `environments.updatedAt`, which are the Mac's.
///
/// Outbox `deviceSeq` values are strictly increasing and never reused, even after rows are removed or
/// a snapshot replaces the mirror: the high-water mark is kept in `syncState.lastDeviceSeq`.
extension MirrorStore {
  /// One column (or, for an insert, one row) a local write changed.
  struct LocalChange {
    var table: String
    var rowId: String
    var op: String
    var column: String?
    var value: JSONValue
  }

  /// Rename, pin, archive, or set the model or permission of a thread; nil arguments are left as they
  /// are. Nil when the thread does not exist (or this build cannot read it).
  public func updateThread(
    id: String, title: String?, pinned: Bool?, archived: Bool?, model: String? = nil,
    permission: String? = nil
  ) throws -> ConversationThread? {
    try locked {
      try transaction {
        guard
          let current = try one(
            ConversationThread.self, "threads", #"SELECT * FROM "threads" WHERE "id" = ?"#, [.text(id)])
        else { return nil }
        var changes: [LocalChange] = []
        if let title, title != current.title {
          changes.append(
            LocalChange(table: "threads", rowId: id, op: "update", column: "title", value: .string(title)))
        }
        if let pinned, pinned != current.pinned {
          changes.append(
            LocalChange(table: "threads", rowId: id, op: "update", column: "pinned", value: .bool(pinned)))
        }
        if let archived, archived != current.archived {
          changes.append(
            LocalChange(table: "threads", rowId: id, op: "update", column: "archived", value: .bool(archived))
          )
        }
        if let model, model != current.model {
          changes.append(
            LocalChange(table: "threads", rowId: id, op: "update", column: "model", value: .string(model)))
        }
        if let permission, permission != current.permission {
          changes.append(
            LocalChange(
              table: "threads", rowId: id, op: "update", column: "permission", value: .string(permission)))
        }
        try writeColumns(changes, key: "id")
        try record(changes)
        return try threadLocked(id: id)
      }
    }
  }

  /// Delete a thread: mark it deleted at `at`, hidden from every list, for the Mac to delete the
  /// runtime's copy once it pulls the mark. A thread already deleted keeps its first time and queues
  /// nothing. Nil when the thread does not exist.
  public func deleteThread(id: String, at: String) throws -> ConversationThread? {
    try locked {
      try transaction {
        guard
          let current = try one(
            ConversationThread.self, "threads", #"SELECT * FROM "threads" WHERE "id" = ?"#, [.text(id)])
        else { return nil }
        if current.userDeletedAt == nil {
          let changes = [
            LocalChange(
              table: "threads", rowId: id, op: "update", column: "userDeletedAt", value: .string(at))
          ]
          try writeColumns(changes, key: "id")
          try record(changes)
        }
        return try threadLocked(id: id)
      }
    }
  }

  /// Mark a thread read up to `turnId`, or unread again with nil, under the Mac's guard
  /// (`WorkspaceDatabase.markRead`): a turn is written only when it is a terminal turn of this thread
  /// created no earlier (by `createdAt`, then `id`) than the turn the marker already names. Anything
  /// else returns the thread unchanged. Nil when the thread does not exist.
  public func markRead(threadId: String, turnId: String?) throws -> ConversationThread? {
    try locked {
      try transaction {
        if let turnId {
          try run(
            """
            UPDATE "threads" SET "readTurnId" = ?2
            WHERE "id" = ?1 AND "readTurnId" IS NOT ?2
              AND EXISTS (
                SELECT 1 FROM "turns" candidate
                WHERE candidate."id" = ?2 AND candidate."threadId" = ?1 AND candidate."status" = 'terminal'
                  AND NOT EXISTS (
                    SELECT 1 FROM "turns" marker
                    WHERE marker."id" = "threads"."readTurnId"
                      AND (candidate."createdAt", candidate."id") < (marker."createdAt", marker."id")))
            """, [.text(threadId), .text(turnId)])
        } else {
          try run(
            #"UPDATE "threads" SET "readTurnId" = NULL WHERE "id" = ? AND "readTurnId" IS NOT NULL"#,
            [.text(threadId)])
        }
        if changedRows > 0 {
          try record([
            LocalChange(
              table: "threads", rowId: threadId, op: "update", column: "readTurnId",
              value: turnId.map(JSONValue.string) ?? .null)
          ])
        }
        return try threadLocked(id: threadId)
      }
    }
  }

  /// Save the thread's shared draft (clearing it is saving `""`; drafts are never deleted). A new draft
  /// queues one insert of the whole row; an existing one queues updates of `text` and `updatedAt` where
  /// they changed. Throws `notFound` when the thread does not exist.
  public func saveDraft(threadId: String, text: String) throws -> Draft {
    let draft = Draft(threadId: threadId, text: text)
    try locked {
      try transaction {
        guard try exists("threads", key: "id", threadId) else {
          throw WorkspaceError(.notFound, "Thread \(threadId) does not exist.")
        }
        let stored = try query(
          #"SELECT "text", "updatedAt" FROM "drafts" WHERE "threadId" = ?"#, [.text(threadId)]
        ).first
        guard let stored else {
          let row: JSONValue = [
            "threadId": .string(threadId), "text": .string(text), "updatedAt": .string(draft.updatedAt),
          ]
          try run(
            #"INSERT INTO "drafts" ("threadId", "text", "updatedAt") VALUES (?, ?, ?)"#,
            [.text(threadId), .text(text), .text(draft.updatedAt)])
          try record([LocalChange(table: "drafts", rowId: threadId, op: "insert", value: row)])
          return
        }
        var changes: [LocalChange] = []
        if stored["text"] != .text(text) {
          changes.append(
            LocalChange(table: "drafts", rowId: threadId, op: "update", column: "text", value: .string(text)))
        }
        if stored["updatedAt"] != .text(draft.updatedAt) {
          changes.append(
            LocalChange(
              table: "drafts", rowId: threadId, op: "update", column: "updatedAt",
              value: .string(draft.updatedAt)))
        }
        try writeColumns(changes, key: "threadId")
        try record(changes)
      }
    }
    return draft
  }

  /// Write the given view settings fields and `updatedAt` (a field not given keeps its stored value,
  /// known to this build or not) and return the result. With the row missing, one insert of the key and
  /// the given fields is queued, and claims no clock for a field it does not set, so it never overrides
  /// another device's first write of that field; otherwise an update per changed field, and of
  /// `updatedAt` when anything changed. A write that changes nothing queues nothing. Setting
  /// `quietThreads` without `density` over a stored value that implies one (`tiny` with a null density:
  /// `ViewSettings.impliedDensity`) also writes that density, so the rows keep their size when the old
  /// value is replaced; a stored density, even one this build does not know, is never replaced.
  @discardableResult
  public func setViewSettings(
    arrangement: ViewSettings.Arrangement? = nil, quietThreads: ViewSettings.QuietThreads? = nil,
    showArchived: Bool? = nil, density: ViewSettings.Density? = nil
  ) throws -> ViewSettings {
    var fields: [(column: String, value: JSONValue)] = []
    if let arrangement { fields.append(("arrangement", .string(arrangement.rawValue))) }
    if let quietThreads { fields.append(("quietThreads", .string(quietThreads.rawValue))) }
    if let showArchived { fields.append(("showArchived", .bool(showArchived))) }
    if let density { fields.append(("density", .string(density.rawValue))) }
    let rowId = ViewSettings.rowId
    return try locked {
      try transaction {
        guard !fields.isEmpty else { return try viewSettingsLocked() }
        let updatedAt = JSONValue.string(Timestamp.now())
        guard
          let stored = try query(#"SELECT * FROM "viewSettings" WHERE "id" = ?"#, [.text(rowId)]).first
        else {
          let row = fields + [("updatedAt", updatedAt)]
          try run(
            "INSERT INTO \"viewSettings\" (\"id\", \(row.map { Self.quote($0.column) }.joined(separator: ", ")))"
              + " VALUES (?, \(row.map { _ in "?" }.joined(separator: ", ")))",
            [.text(rowId)] + row.map { bindable($0.value, table: "viewSettings", column: $0.column) })
          var object: [String: JSONValue] = ["id": .string(rowId)]
          for (column, value) in row { object[column] = value }
          try record([LocalChange(table: "viewSettings", rowId: rowId, op: "insert", value: .object(object))])
          return try viewSettingsLocked()
        }
        var fields = fields
        if quietThreads != nil, density == nil, stored["density"] == .null,
          case .text(let storedQuietThreads)? = stored["quietThreads"],
          let implied = ViewSettings.impliedDensity(
            storedQuietThreads: storedQuietThreads, storedDensity: nil)
        {
          fields.append(("density", .string(implied.rawValue)))
        }
        var changes = fields.filter { field in
          stored[field.column] != cell(bindable(field.value, table: "viewSettings", column: field.column))
        }.map {
          LocalChange(table: "viewSettings", rowId: rowId, op: "update", column: $0.column, value: $0.value)
        }
        if !changes.isEmpty,
          stored["updatedAt"] != cell(bindable(updatedAt, table: "viewSettings", column: "updatedAt"))
        {
          changes.append(
            LocalChange(
              table: "viewSettings", rowId: rowId, op: "update", column: "updatedAt", value: updatedAt))
        }
        try writeColumns(changes, key: "id")
        try record(changes)
        return try viewSettingsLocked()
      }
    }
  }

  /// A bound value as the cell it stores.
  private func cell(_ bind: Bind) -> Cell {
    switch bind {
    case .null: .null
    case .integer(let value): .integer(value)
    case .text(let text): .text(text)
    }
  }

  /// Rename an environment; the empty string restores its folder-name `displayName`. Nil when the environment
  /// does not exist.
  public func renameEnvironment(id: String, name: String) throws -> WorkEnvironment? {
    try locked {
      try transaction {
        guard let current = try environmentLocked(id: id) else { return nil }
        guard current.name != name else { return current }
        let changes = [
          LocalChange(table: "environments", rowId: id, op: "update", column: "name", value: .string(name))
        ]
        try writeColumns(changes, key: "id")
        try record(changes)
        return try environmentLocked(id: id)
      }
    }
  }

  // MARK: - The outbox

  /// The oldest `limit` unsent edits, in `deviceSeq` order, as `POST /v1/changes` takes them; `wall` is
  /// the clock's milliseconds.
  public func outbox(limit: Int) throws -> [SyncChange] {
    try locked { try outboxRows(limit: limit) }
  }

  /// The next push: the oldest unsent edits, at most `rows` of them and `bytes` of encoded request body
  /// but always at least one (the rule of the Mac's `HubSync.batch`), so a backlog larger than the hub's
  /// body limit drains in several pushes instead of being refused whole on every retry. The rows
  /// returned count as sent from now on (`sentThrough`), in the same locked step that reads them, so a
  /// local write made while the push is in flight never collapses into one of them.
  public func nextUpload(rows: Int, bytes: Int) throws -> [SyncChange] {
    try locked {
      let batch = Self.uploadPrefix(try outboxRows(limit: rows), rows: rows, bytes: bytes)
      if let last = batch.last { sentThrough = max(sentThrough, last.deviceSeq) }
      return batch
    }
  }

  /// The longest prefix of `changes` with at most `rows` changes and at most `bytes` of
  /// `{"changes":[...]}` body, and never empty when `changes` is not.
  static func uploadPrefix(_ changes: [SyncChange], rows: Int, bytes limit: Int) -> [SyncChange] {
    var batch: [SyncChange] = []
    var bytes = 16  // {"changes":[]}
    for change in changes {
      let size = ((try? JSONCoding.encoder.encode(change).count) ?? 0) + 1
      if !batch.isEmpty, batch.count >= rows || bytes + size > limit { break }
      batch.append(change)
      bytes += size
    }
    return batch
  }

  /// Drops every edit the hub has accepted, through `deviceSeq`.
  public func removeOutbox(through deviceSeq: Int) throws {
    try locked {
      try run(#"DELETE FROM "outbox" WHERE "deviceSeq" <= ?"#, [.integer(Int64(deviceSeq))])
    }
  }

  /// How many edits wait to be uploaded, for Diagnostics. It reads 0 when the count cannot be read, so
  /// it must never decide whether a rebuild is safe: only `MirrorStoreError.needsRebuild(outboxEmpty:)`,
  /// which counts an unreadable outbox as not empty, decides that.
  public var outboxCount: Int {
    let value = try? locked { try query(#"SELECT count(*) AS "n" FROM "outbox""#).first?["n"] }
    if case .integer(let count)? = value { return Int(count) }
    return 0
  }

  /// What the hub's answer to a push settled: drops every edit through `deviceSeq` (accepted, or
  /// refused and covered by it) and adds the refused ones to the running count, in one transaction.
  public func completeUpload(through deviceSeq: Int, refused: Int) throws {
    try locked {
      try transaction {
        try run(#"DELETE FROM "outbox" WHERE "deviceSeq" <= ?"#, [.integer(Int64(deviceSeq))])
        if refused > 0 {
          try run(
            #"UPDATE "syncState" SET "refusedUploads" = "refusedUploads" + ? WHERE "id" = 1"#,
            [.integer(Int64(refused))])
        }
      }
    }
  }

  /// Edits the hub has refused over this mirror's life (it survives restarts; a rebuild starts over).
  public var refusedUploads: Int {
    get throws {
      try locked {
        if case .integer(let count)? = try query(#"SELECT "refusedUploads" FROM "syncState" WHERE "id" = 1"#)
          .first?["refusedUploads"]
        {
          return Int(count)
        }
        return 0
      }
    }
  }

  /// Adds to the refused count (`completeUpload` does this with the removal; this is for tests).
  func addRefusedUploads(_ count: Int) throws {
    try locked {
      try run(
        #"UPDATE "syncState" SET "refusedUploads" = "refusedUploads" + ? WHERE "id" = 1"#,
        [.integer(Int64(count))])
    }
  }

  /// The highest `deviceSeq` this device has issued; the next edit is numbered after it.
  public var lastDeviceSeq: Int {
    get throws {
      try locked {
        if case .integer(let seq)? = try query(#"SELECT "lastDeviceSeq" FROM "syncState" WHERE "id" = 1"#)
          .first?["lastDeviceSeq"]
        {
          return Int(seq)
        }
        return 0
      }
    }
  }

  /// Raises the high-water mark to `seq` when that is higher (the hub has recorded a later one for this
  /// device than the mirror ever issued), so the next edit is numbered past it. Never lowers it.
  public func raiseLastDeviceSeq(to seq: Int) throws {
    try locked {
      try run(
        #"UPDATE "syncState" SET "lastDeviceSeq" = max("lastDeviceSeq", ?) WHERE "id" = 1"#,
        [.integer(Int64(seq))])
    }
  }

  func outboxRows(limit: Int?) throws -> [SyncChange] {
    let sql = #"SELECT * FROM "outbox" ORDER BY "deviceSeq""# + (limit == nil ? "" : " LIMIT ?")
    return try query(sql, limit.map { [.integer(Int64($0))] } ?? []).compactMap { row in
      guard case .integer(let seq)? = row["deviceSeq"], case .text(let hlc)? = row["hlc"],
        case .text(let table)? = row["table"], case .text(let rowId)? = row["rowId"],
        case .text(let op)? = row["op"]
      else { return nil }
      var column: String?
      if case .text(let name)? = row["column"] { column = name }
      var value: JSONValue?
      if case .text(let text)? = row["value"] {
        value = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(text.utf8))
      }
      return SyncChange(
        deviceSeq: Int(seq), wall: Int(HLC(rawValue: hlc)?.millis ?? 0), table: table, rowId: rowId, op: op,
        column: column, value: value, hlc: hlc)
    }
  }

  // MARK: - Writing

  /// Applies column updates to the mirror inside the open transaction.
  private func writeColumns(_ changes: [LocalChange], key: String) throws {
    for change in changes {
      guard let column = change.column else { continue }
      try run(
        "UPDATE \(Self.quote(change.table)) SET \(Self.quote(column)) = ? WHERE \(Self.quote(key)) = ?",
        [bindable(change.value, table: change.table, column: column), .text(change.rowId)])
    }
  }

  /// Inside the open transaction, after the mirror rows are written: one clock for the whole write,
  /// the written columns' clocks advanced to it, and one outbox row per change after the high-water
  /// mark, which then moves. An update of a column that already has an update queued and not yet sent
  /// (`deviceSeq` above `sentThrough`) replaces that row's value and clock and keeps its `deviceSeq`
  /// instead, so typing a draft offline queues one row per column, not one per save.
  private func record(_ changes: [LocalChange]) throws {
    guard !changes.isEmpty else { return }
    let hlc = clock.next().rawValue
    guard
      case .integer(let last)? = try query(#"SELECT "lastDeviceSeq" FROM "syncState" WHERE "id" = 1"#)
        .first?["lastDeviceSeq"]
    else { throw WorkspaceError(.internalError, "Mirror store: the sync state row is missing.") }
    var seq = last
    for change in changes {
      let clocked = SyncColumns.clocked[change.table] ?? []
      // An insert claims the clocks of the columns it carries, and no others.
      let written =
        change.op == "insert"
        ? (change.value.objectValue.map { Array($0.keys) } ?? []).sorted() : [change.column].compactMap { $0 }
      for column in written where clocked.contains(column) {
        try advanceClock(change.table, change.rowId, column, to: hlc)
      }
      if change.op == "update", let column = change.column {
        try run(
          """
          UPDATE "outbox" SET "hlc" = ?1, "value" = ?2
          WHERE "deviceSeq" = (
            SELECT max("deviceSeq") FROM "outbox"
            WHERE "table" = ?3 AND "rowId" = ?4 AND "op" = 'update' AND "column" = ?5 AND "deviceSeq" > ?6)
          """,
          [
            .text(hlc), .text(Self.jsonText(change.value)), .text(change.table), .text(change.rowId),
            .text(column), .integer(Int64(sentThrough)),
          ])
        if changedRows > 0 { continue }
      }
      seq += 1
      try run(
        #"INSERT INTO "outbox" ("deviceSeq", "hlc", "table", "rowId", "op", "column", "value") VALUES (?, ?, ?, ?, ?, ?, ?)"#,
        [
          .integer(seq), .text(hlc), .text(change.table), .text(change.rowId), .text(change.op),
          change.column.map(Bind.text) ?? .null, .text(Self.jsonText(change.value)),
        ])
    }
    try run(#"UPDATE "syncState" SET "lastDeviceSeq" = ? WHERE "id" = 1"#, [.integer(seq)])
  }
}
