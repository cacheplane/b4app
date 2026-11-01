import Foundation
import WorkspaceProtocol
import WorkspaceSync

/// The phone's own edits (M8b spec, "Phone writes"): only `SyncColumns.phoneWritable` columns. Each
/// write applies to the mirror at once, so the UI shows it, and in the same SQLite transaction stamps
/// one `clock.next()` for the whole write, advances `columnClocks` for the columns it wrote, and appends
/// one outbox row per changed column (a new draft is one insert row) for `MirrorSync` to push. A write
/// that changes nothing stamps nothing and queues nothing. No write touches `threads.updatedAt` or
/// `projects.updatedAt`, which are the Mac's.
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

  /// Rename, pin, or archive a thread; nil arguments are left as they are. Nil when the thread does not
  /// exist (or this build cannot read it).
  public func updateThread(
    id: String, title: String?, pinned: Bool?, archived: Bool?
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
        try writeColumns(changes, key: "id")
        try record(changes)
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

  /// Rename a project; the empty string restores its folder-name `displayName`. Nil when the project
  /// does not exist.
  public func renameProject(id: String, name: String) throws -> Project? {
    try locked {
      try transaction {
        guard let current = try projectLocked(id: id) else { return nil }
        guard current.name != name else { return current }
        let changes = [
          LocalChange(table: "projects", rowId: id, op: "update", column: "name", value: .string(name))
        ]
        try writeColumns(changes, key: "id")
        try record(changes)
        return try projectLocked(id: id)
      }
    }
  }

  // MARK: - The outbox

  /// The oldest `limit` unsent edits, in `deviceSeq` order, as `POST /v1/changes` takes them; `wall` is
  /// the clock's milliseconds.
  public func outbox(limit: Int) throws -> [SyncChange] {
    try locked { try outboxRows(limit: limit) }
  }

  /// Drops every edit the hub has accepted, through `deviceSeq`.
  public func removeOutbox(through deviceSeq: Int) throws {
    try locked {
      try run(#"DELETE FROM "outbox" WHERE "deviceSeq" <= ?"#, [.integer(Int64(deviceSeq))])
    }
  }

  /// How many edits wait to be uploaded (0 when the count cannot be read).
  public var outboxCount: Int {
    let value = try? locked { try query(#"SELECT count(*) AS "n" FROM "outbox""#).first?["n"] }
    if case .integer(let count)? = value { return Int(count) }
    return 0
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
  /// mark, which then moves.
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
      let written = change.op == "insert" ? clocked.sorted() : [change.column].compactMap { $0 }
      for column in written where clocked.contains(column) {
        try advanceClock(change.table, change.rowId, column, to: hlc)
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
