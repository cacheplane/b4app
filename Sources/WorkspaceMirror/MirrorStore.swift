import Foundation
import SQLite3
import WorkspaceProtocol
import WorkspaceSync

/// The hub this device has joined. `tokenRef` names the device token in the secret store; the token
/// itself is never stored here.
public struct MirrorLink: Codable, Sendable, Equatable {
  public var hubURL: String
  public var deviceId: String
  public var deviceName: String
  public var tokenRef: String
  public var orgSlug: String
  public var username: String
  public var lastSyncAt: String?
  public var lastError: String?

  public init(
    hubURL: String, deviceId: String, deviceName: String, tokenRef: String, orgSlug: String, username: String,
    lastSyncAt: String? = nil, lastError: String? = nil
  ) {
    self.hubURL = hubURL
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.tokenRef = tokenRef
    self.orgSlug = orgSlug
    self.username = username
    self.lastSyncAt = lastSyncAt
    self.lastError = lastError
  }
}

/// What one `apply` changed, for the transport to turn into events: threads (their own rows, and the
/// thread of every turn and runtime request written), projects (their rows and their folders'),
/// connections, the display items written (as they now read), how many changes were not applied, and
/// how many rows the batch wrote that this build cannot decode (stored, but left out of reads). A
/// change whose clocked columns all lost to newer clocks wrote nothing: it touches nothing and is not
/// counted as skipped.
public struct AppliedBatch: Sendable, Equatable {
  public var touchedThreadIds: Set<String>
  public var touchedItems: [DisplayItem]
  public var touchedConnectionIds: Set<String>
  public var touchedProjectIds: Set<String>
  public var skipped: Int
  public var undecodableRows: Int

  public init(
    touchedThreadIds: Set<String> = [], touchedItems: [DisplayItem] = [],
    touchedConnectionIds: Set<String> = [], touchedProjectIds: Set<String> = [],
    skipped: Int = 0, undecodableRows: Int = 0
  ) {
    self.touchedThreadIds = touchedThreadIds
    self.touchedItems = touchedItems
    self.touchedConnectionIds = touchedConnectionIds
    self.touchedProjectIds = touchedProjectIds
    self.skipped = skipped
    self.undecodableRows = undecodableRows
  }
}

/// Why a mirror file could not be opened as this build's schema.
public enum MirrorStoreError: Error, Equatable, CustomStringConvertible {
  /// The file's schema is newer than this build knows, or migrating it failed. The file is left as
  /// it was. `outboxEmpty` is true when it holds no unsent edits (no outbox table, or an empty one),
  /// so `MirrorStore.rebuild(path:)` loses nothing; otherwise the host keeps the file and reports.
  case needsRebuild(outboxEmpty: Bool)

  public var description: String {
    switch self {
    case .needsRebuild(true):
      "The mirror database needs rebuilding: this build cannot read its schema."
    case .needsRebuild(false):
      "The mirror database needs rebuilding, but it holds edits not yet uploaded, so it was kept."
    }
  }
}

/// A mirror of the Mac's synced tables in the system SQLite, fed by the hub's change feed, plus the
/// phone's own edits. Replay follows `WorkspaceDatabase.replay` on the Mac (an insert upserts the
/// provided columns, an update sets one column, a delete deletes, and a change that violates a
/// constraint, such as a row whose parent is missing, is skipped and counted), except that the
/// `SyncColumns.clocked` columns merge last-writer-wins, as `WorkspaceDatabase.applyRemote` does:
/// each applies only when the change's clock is greater (bytewise) than the column's `columnClocks`
/// entry (a missing entry is older), and then the entry advances. An insert counts as one write per
/// clocked column at its clock. Every received clock, clamped first when more than five minutes ahead
/// of the wall clock, is folded into `clock`, so a later local edit sorts after it.
///
/// Rows read back through the protocol's `Codable` types. A row this build cannot decode (a value a
/// newer Mac wrote) is kept, left out of reads, and counted: per batch in
/// `AppliedBatch.undecodableRows`, and in total by `undecodableRowCount()`.
///
/// The mirror never stores a connection's `authReference`, `localServerId`, or `target`, whatever
/// arrives: the Mac blanks them before upload, and the mirror does not rely on that.
///
/// Every statement runs on one serial queue over one connection.
public final class MirrorStore: @unchecked Sendable {
  /// The SQLite file, or `:memory:`.
  public let path: String
  /// Stamps the phone's edits; its device id is the link's (`local` before joining).
  public let clock: HybridClock
  let db: OpaquePointer
  private let queue = DispatchQueue(label: "b4app.mirror.store")
  let wall: @Sendable () -> UInt64
  /// Column names and declared types per synced table, read from the schema at open.
  var columns: [String: [String: String]] = [:]

  /// Opens (creating when missing) and migrates the file. Throws `MirrorStoreError.needsRebuild` when
  /// its schema is newer than this build's or a migration fails, leaving the file untouched.
  public convenience init(path: String) throws {
    try self.init(path: path, wall: epochMillis)
  }

  init(path: String, wall: @escaping @Sendable () -> UInt64) throws {
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let status = sqlite3_open_v2(path, &handle, flags, nil)
    guard status == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
      if let handle { sqlite3_close_v2(handle) }
      throw WorkspaceError(.internalError, "Could not open the mirror database: \(message)")
    }
    sqlite3_extended_result_codes(handle, 1)
    do {
      try Self.prepare(handle)
    } catch let error as SQLiteError {
      sqlite3_close_v2(handle)
      throw WorkspaceError(.internalError, "Mirror store: \(error.message)")
    } catch {
      sqlite3_close_v2(handle)
      throw error
    }
    self.path = path
    self.db = handle
    self.wall = wall
    self.clock = HybridClock(deviceId: "local", wall: wall)
    try locked {
      for (table, _) in MirrorSchema.syncedTables {
        var declared: [String: String] = [:]
        for row in try query("PRAGMA table_info(\(Self.quote(table)))") {
          if case .text(let name) = row["name"], case .text(let type) = row["type"] { declared[name] = type }
        }
        columns[table] = declared
      }
      if let link = try storedLink() { clock.deviceId = link.deviceId }
      // Start after every clock already stored, so a local edit made now wins over what was seen.
      let latest = try query(
        #"SELECT max("hlc") AS "hlc" FROM (SELECT "hlc" FROM "columnClocks" UNION ALL SELECT "hlc" FROM "outbox")"#
      ).first?["hlc"]
      if case .text(let text)? = latest, let hlc = HLC(rawValue: text) { clock.observe(hlc) }
    }
  }

  /// A store that lives only as long as this object (tests, previews).
  public static func inMemory() throws -> MirrorStore { try MirrorStore(path: ":memory:") }

  /// Deletes the file at `path` with its `-wal` and `-shm` files and creates a fresh one at the current
  /// schema. Everything in the old file is lost, the link and the outbox included: the host calls this
  /// only after `needsRebuild(outboxEmpty: true)`.
  @discardableResult
  public static func rebuild(path: String) throws -> MirrorStore {
    for suffix in ["", "-wal", "-shm"] {
      let file = path + suffix
      guard FileManager.default.fileExists(atPath: file) else { continue }
      try FileManager.default.removeItem(atPath: file)
    }
    return try MirrorStore(path: path)
  }

  deinit { sqlite3_close_v2(db) }

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
  private func finish(_ state: BatchState) throws -> AppliedBatch {
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
  private func applyOne(_ change: StoredChange, at hlc: String) throws -> Outcome {
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

  // MARK: - Reads

  public func connections() throws -> [Connection] {
    try locked {
      try all(Connection.self, "connections", #"SELECT * FROM "connections" ORDER BY "createdAt""#)
    }
  }

  /// Every thread column, the owner's device name from `devices`, and `activity`: the latest turn
  /// (greatest `createdAt`, ties by greatest `id`), the count of pending runtime requests, and the
  /// newest of the thread's `createdAt` and its latest turn's and latest request's `updatedAt`, all
  /// compared bytewise, the same as the Mac's query. Callers append a WHERE clause on `t`.
  static let threadWithActivity = """
    SELECT t.*, d."name" AS "ownerDeviceName", json_object(
      'latestTurnId', lt."id",
      'latestTurnStatus', lt."status",
      'latestTurnOutcome', lt."outcome",
      'pendingRequests', (
        SELECT count(*) FROM "runtimeRequests" WHERE "threadId" = t."id" AND "state" = 'pending'),
      'lastActivityAt', max(
        t."createdAt", coalesce(lt."updatedAt", ''),
        coalesce((SELECT max("updatedAt") FROM "runtimeRequests" WHERE "threadId" = t."id"), ''))
    ) AS "activity"
    FROM "threads" t
    LEFT JOIN "turns" lt ON lt."id" = (
      SELECT "id" FROM "turns" WHERE "threadId" = t."id" ORDER BY "createdAt" DESC, "id" DESC LIMIT 1)
    LEFT JOIN "devices" d ON d."id" = t."ownerDeviceId"
    """

  /// Threads ordered as the Mac lists them (pinned first, then most recently updated); `query` matches
  /// the title case-insensitively, with `%` and `_` taken literally.
  public func threads(
    includeArchived: Bool, connectionId: String?, query: String?, projectId: String? = nil
  ) throws
    -> [ConversationThread]
  {
    var clauses: [String] = []
    var binds: [Bind] = []
    if let connectionId {
      clauses.append(#"t."connectionId" = ?"#)
      binds.append(.text(connectionId))
    }
    if let projectId {
      clauses.append(#"t."projectId" = ?"#)
      binds.append(.text(projectId))
    }
    if !includeArchived { clauses.append(#"t."archived" = 0"#) }
    if let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
      let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
      clauses.append(#"t."title" LIKE ? ESCAPE '\'"#)
      binds.append(.text("%\(escaped)%"))
    }
    let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
    return try locked {
      try all(
        ConversationThread.self, "threads",
        Self.threadWithActivity + whereSQL + #" ORDER BY t."pinned" DESC, t."updatedAt" DESC"#, binds)
    }
  }

  public func thread(id: String) throws -> ConversationThread? {
    try locked { try threadLocked(id: id) }
  }

  func threadLocked(id: String) throws -> ConversationThread? {
    try one(ConversationThread.self, "threads", Self.threadWithActivity + #" WHERE t."id" = ?"#, [.text(id)])
  }

  public func turns(threadId: String) throws -> [Turn] {
    try locked {
      try all(
        Turn.self, "turns", #"SELECT * FROM "turns" WHERE "threadId" = ? ORDER BY "createdAt""#,
        [.text(threadId)])
    }
  }

  public func items(threadId: String) throws -> [DisplayItem] {
    try locked {
      try all(
        DisplayItem.self, "displayItems",
        #"SELECT * FROM "displayItems" WHERE "threadId" = ? ORDER BY "sequence""#, [.text(threadId)])
    }
  }

  /// Every runtime request of the thread, in any state, oldest first.
  public func requests(threadId: String) throws -> [RuntimeRequest] {
    try locked {
      try all(
        RuntimeRequest.self, "runtimeRequests",
        #"SELECT * FROM "runtimeRequests" WHERE "threadId" = ? ORDER BY "createdAt""#, [.text(threadId)])
    }
  }

  public func draft(threadId: String) throws -> Draft? {
    try locked {
      try one(Draft.self, "drafts", #"SELECT * FROM "drafts" WHERE "threadId" = ?"#, [.text(threadId)])
    }
  }

  /// Every project, oldest first (ties by id), each with its folders oldest first, as the Mac lists
  /// them; `displayName` resolves from them.
  public func projects() throws -> [Project] {
    try locked {
      let projects = try all(
        Project.self, "projects", #"SELECT * FROM "projects" ORDER BY "createdAt", "id""#)
      let folders = Dictionary(
        grouping: try all(
          ProjectFolder.self, "projectFolders", #"SELECT * FROM "projectFolders" ORDER BY "createdAt", "id""#),
        by: \.projectId)
      return projects.map {
        var project = $0
        project.folders = folders[project.id] ?? []
        return project
      }
    }
  }

  func projectLocked(id: String) throws -> Project? {
    guard
      var project = try one(
        Project.self, "projects", #"SELECT * FROM "projects" WHERE "id" = ?"#, [.text(id)])
    else { return nil }
    project.folders = try all(
      ProjectFolder.self, "projectFolders",
      #"SELECT * FROM "projectFolders" WHERE "projectId" = ? ORDER BY "createdAt", "id""#, [.text(id)])
    return project
  }

  /// The user's devices as `saveDevices` last stored them, in the hub's order.
  public func devices() throws -> [DeviceInfo] {
    try locked { try all(DeviceInfo.self, "devices", #"SELECT * FROM "devices" ORDER BY rowid"#) }
  }

  /// Replaces the stored device list with `devices` (from `GET /v1/devices`).
  public func saveDevices(_ devices: [DeviceInfo]) throws {
    try locked {
      try transaction {
        try exec(#"DELETE FROM "devices""#)
        for device in devices {
          try run(
            #"INSERT INTO "devices" ("id", "name", "platform", "lastSeenAt", "revokedAt") VALUES (?, ?, ?, ?, ?)"#,
            [
              .text(device.id), .text(device.name), .text(device.platform),
              device.lastSeenAt.map(Bind.text) ?? .null,
              device.revokedAt.map(Bind.text) ?? .null,
            ])
        }
      }
    }
  }

  /// The clock of a clocked column's latest write here, nil when it has none.
  public func columnClock(table: String, rowId: String, column: String) throws -> String? {
    try locked { try columnClockLocked(table, rowId, column) }
  }

  /// The device whose insert last wrote the row (tests and diagnostics).
  func ownerDeviceId(table: String, rowId: String) throws -> String? {
    try locked {
      guard MirrorSchema.ownedTables.contains(table) else { return nil }
      let cell = try query(
        "SELECT \"ownerDeviceId\" AS \"o\" FROM \(Self.quote(table)) WHERE \"id\" = ?", [.text(rowId)]
      ).first?["o"]
      if case .text(let id)? = cell { return id }
      return nil
    }
  }

  /// Rows stored in a synced table, decodable or not (tests and diagnostics).
  func rowCount(_ table: String) throws -> Int {
    try locked {
      guard MirrorSchema.syncedTables.contains(where: { $0.table == table }) else { return 0 }
      if case .integer(let count) = try query("SELECT count(*) AS n FROM \(Self.quote(table))").first?["n"] {
        return Int(count)
      }
      return 0
    }
  }

  /// Stored rows of every synced table that this build cannot decode, so reads leave them out.
  /// Served from `undecodableRows`, which `apply` keeps current; the row tables are not read.
  public func undecodableRowCount() throws -> Int {
    try locked {
      if case .integer(let count) = try query(#"SELECT count(*) AS "n" FROM "undecodableRows""#).first?["n"] {
        return Int(count)
      }
      return 0
    }
  }

  // MARK: - Sync state

  /// The hub sequence the mirror has applied through (0 before the first pull).
  public var cursor: Int {
    let value = try? locked {
      try query(#"SELECT "cursor" FROM "syncState" WHERE "id" = 1"#).first?["cursor"]
    }
    if case .integer(let cursor)? = value { return Int(cursor) }
    return 0
  }

  public func setCursor(_ cursor: Int) throws {
    try locked { try run(#"UPDATE "syncState" SET "cursor" = ? WHERE "id" = 1"#, [.integer(Int64(cursor))]) }
  }

  public func link() throws -> MirrorLink? {
    try locked { try storedLink() }
  }

  private func storedLink() throws -> MirrorLink? {
    guard case .text(let text) = try query(#"SELECT "link" FROM "syncState" WHERE "id" = 1"#).first?["link"]
    else { return nil }
    return try JSONCoding.decoder.decode(MirrorLink.self, from: Data(text.utf8))
  }

  /// Stores the link; the phone's edits are stamped with its device id from now on.
  public func saveLink(_ link: MirrorLink) throws {
    let text = String(decoding: try JSONCoding.encoder.encode(link), as: UTF8.self)
    try locked {
      try run(#"UPDATE "syncState" SET "link" = ? WHERE "id" = 1"#, [.text(text)])
      clock.deviceId = link.deviceId
    }
  }

  public func clearLink() throws {
    try locked {
      try run(#"UPDATE "syncState" SET "link" = NULL WHERE "id" = 1"#)
      clock.deviceId = "local"
    }
  }

  /// Deletes every mirrored row and its column clocks and rewinds the cursor to 0 (the hub answered
  /// `resync_required`). The link and the outbox stay.
  public func clearRows() throws {
    try locked {
      try transaction {
        try deleteRows()
        try exec(#"UPDATE "syncState" SET "cursor" = 0 WHERE "id" = 1"#)
      }
    }
  }

  private func deleteRows() throws {
    for (table, _) in MirrorSchema.syncedTables.reversed() {
      try exec("DELETE FROM \(Self.quote(table))")
    }
    try exec(#"DELETE FROM "undecodableRows""#)
    try exec(#"DELETE FROM "columnClocks""#)
  }

  // MARK: - Schema

  /// Before anything else touches the file: refuses a schema newer than this build's, then sets the
  /// pragmas and runs the migrations after the file's `user_version`, all in one transaction. A
  /// migration that fails is rolled back, so the file is as it was.
  private static func prepare(_ db: OpaquePointer) throws {
    let current = try integer(db, "PRAGMA user_version")
    guard current <= MirrorSchema.version else {
      throw MirrorStoreError.needsRebuild(outboxEmpty: outboxEmpty(db))
    }
    for pragma in MirrorSchema.pragmas { try execute(db, pragma) }
    guard current < MirrorSchema.version else { return }
    try execute(db, "BEGIN IMMEDIATE")
    do {
      for migration in MirrorSchema.migrations where migration.version > current {
        for statement in migration.statements { try execute(db, statement) }
      }
      try execute(db, "PRAGMA user_version = \(MirrorSchema.version)")
      try execute(db, "COMMIT")
    } catch {
      try? execute(db, "ROLLBACK")
      throw MirrorStoreError.needsRebuild(outboxEmpty: outboxEmpty(db))
    }
  }

  /// True when the file holds no unsent edits: no outbox table, or an empty one. Anything that cannot
  /// be read counts as not empty, so a rebuild is never offered over edits that might be there.
  private static func outboxEmpty(_ db: OpaquePointer) -> Bool {
    guard
      let tables = try? integer(
        db, #"SELECT count(*) FROM "sqlite_master" WHERE "type" = 'table' AND "name" = 'outbox'"#)
    else { return false }
    if tables == 0 { return true }
    return (try? integer(db, #"SELECT EXISTS (SELECT 1 FROM "outbox")"#)) == 0
  }

  private static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int {
    guard case .integer(let value)? = try rows(db, sql, []).first?.cells.first else {
      throw SQLiteError(code: SQLITE_ERROR, message: "\(sql) returned nothing")
    }
    return Int(value)
  }

  // MARK: - Rows

  /// A row as JSON in the shape of the protocol type, built like `Rows.decode` on the Mac: booleans
  /// from 0/1, JSON columns inline, integers as numbers, text as strings. A row this build cannot
  /// decode (a value a newer Mac wrote) is left out rather than failing the whole read.
  private func decode<T: Decodable>(_ type: T.Type, table: String, _ row: Row) -> T? {
    let booleans = MirrorSchema.booleanColumns[table] ?? []
    let jsons = (MirrorSchema.jsonColumns[table] ?? []).union(MirrorSchema.computedJSONColumns)
    var json = "{"
    for (index, name) in row.names.enumerated() {
      if index > 0 { json += "," }
      json += Self.jsonString(name) + ":"
      switch row.cells[index] {
      case .null: json += "null"
      case .integer(let value):
        json += booleans.contains(name) ? (value != 0 ? "true" : "false") : String(value)
      case .real(let value): json += String(value)
      case .text(let value):
        json += jsons.contains(name) ? value : Self.jsonString(value)
      }
    }
    json += "}"
    return try? JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
  }

  private static func jsonString(_ text: String) -> String {
    (try? JSONCoding.encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
  }

  /// A JSON value as the column stores it: JSON text for JSON columns, 0/1 for booleans, integers as
  /// integers, everything else as text.
  func bindable(_ value: JSONValue, table: String, column: String) -> Bind {
    if case .null = value { return .null }
    if MirrorSchema.jsonColumns[table]?.contains(column) == true { return .text(Self.jsonText(value)) }
    switch value {
    case .bool(let flag): return .integer(flag ? 1 : 0)
    case .number(let number):
      let integral = number == number.rounded() && abs(number) < 9.0e15
      if integral, columns[table]?[column] == "INTEGER" { return .integer(Int64(number)) }
      return .text(integral ? String(Int64(number)) : String(number))
    case .string(let text): return .text(text)
    default: return .text(Self.jsonText(value))
    }
  }

  static func jsonText(_ value: JSONValue) -> String {
    (try? JSONCoding.encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }

  /// Whether a row of `table` decodes as its protocol type.
  private func decodes(table: String, _ row: Row) -> Bool {
    switch table {
    case "connections": return decode(Connection.self, table: table, row) != nil
    case "projects": return decode(Project.self, table: table, row) != nil
    case "projectFolders": return decode(ProjectFolder.self, table: table, row) != nil
    case "threads": return decode(ConversationThread.self, table: table, row) != nil
    case "turns": return decode(Turn.self, table: table, row) != nil
    case "displayItems": return decode(DisplayItem.self, table: table, row) != nil
    case "runtimeRequests": return decode(RuntimeRequest.self, table: table, row) != nil
    case "drafts": return decode(Draft.self, table: table, row) != nil
    default: return true
    }
  }

  func all<T: Decodable>(
    _ type: T.Type, _ table: String, _ sql: String, _ binds: [Bind] = []
  ) throws
    -> [T]
  {
    try statement(sql, binds).compactMap { decode(type, table: table, $0) }
  }

  func one<T: Decodable>(_ type: T.Type, _ table: String, _ sql: String, _ binds: [Bind]) throws -> T? {
    try statement(sql, binds).first.flatMap { decode(type, table: table, $0) }
  }

  // MARK: - SQLite

  enum Bind {
    case null
    case integer(Int64)
    case text(String)
  }

  enum Cell: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
  }

  struct Row {
    var names: [String]
    var cells: [Cell]
    subscript(name: String) -> Cell? { names.firstIndex(of: name).map { cells[$0] } }
  }

  struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String
    var isConstraint: Bool { code & 0xff == SQLITE_CONSTRAINT }
    var description: String { "SQLite \(code): \(message)" }
  }

  /// Runs `body` on the store's queue; SQLite failures surface as `WorkspaceError(.internalError)`.
  func locked<T>(_ body: () throws -> T) throws -> T {
    try queue.sync {
      do {
        return try body()
      } catch let error as SQLiteError {
        throw WorkspaceError(.internalError, "Mirror store: \(error.message)")
      }
    }
  }

  /// Runs `body` in one `BEGIN IMMEDIATE` transaction, rolled back when it throws. Call inside `locked`.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try exec("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try exec("COMMIT")
      return result
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  /// Every statement text run while set (tests).
  private var statementLog: [String]?

  func recordStatements() { queue.sync { statementLog = [] } }
  func recordedStatements() -> [String] { queue.sync { statementLog ?? [] } }

  func exec(_ sql: String) throws {
    statementLog?.append(sql)
    try Self.execute(db, sql)
  }

  /// Rows the last statement changed.
  var changedRows: Int { Int(sqlite3_changes(db)) }

  func run(_ sql: String, _ binds: [Bind] = []) throws { _ = try statement(sql, binds) }

  func query(_ sql: String, _ binds: [Bind] = []) throws -> [Row] { try statement(sql, binds) }

  private func statement(_ sql: String, _ binds: [Bind]) throws -> [Row] {
    statementLog?.append(sql)
    return try Self.rows(db, sql, binds)
  }

  private static func execute(_ db: OpaquePointer, _ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(db, sql, nil, nil, &message)
    guard status == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
      sqlite3_free(message)
      throw SQLiteError(code: sqlite3_extended_errcode(db), message: text)
    }
  }

  private static func rows(_ db: OpaquePointer, _ sql: String, _ binds: [Bind]) throws -> [Row] {
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
      throw SQLiteError(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(prepared) }
    for (index, bind) in binds.enumerated() {
      let position = Int32(index + 1)
      switch bind {
      case .null: sqlite3_bind_null(prepared, position)
      case .integer(let value): sqlite3_bind_int64(prepared, position, value)
      case .text(let value): sqlite3_bind_text(prepared, position, value, -1, Self.transient)
      }
    }
    let count = sqlite3_column_count(prepared)
    let names = (0..<count).map { String(cString: sqlite3_column_name(prepared, $0)) }
    var rows: [Row] = []
    while true {
      let status = sqlite3_step(prepared)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else {
        throw SQLiteError(code: sqlite3_extended_errcode(db), message: String(cString: sqlite3_errmsg(db)))
      }
      rows.append(Row(names: names, cells: (0..<count).map { Self.cell(prepared, $0) }))
    }
    return rows
  }

  private static func cell(_ statement: OpaquePointer, _ index: Int32) -> Cell {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
    case SQLITE_NULL: return .null
    default:
      guard let bytes = sqlite3_column_text(statement, index) else { return .null }
      let length = Int(sqlite3_column_bytes(statement, index))
      return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self))
    }
  }

  /// `SQLITE_TRANSIENT`: SQLite copies the bound text before `bind` returns.
  private static var transient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }

  static func quote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
