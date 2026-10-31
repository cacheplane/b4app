import Foundation
import GRDB
import WorkspaceProtocol

public struct ThreadFilter: Sendable, Equatable {
  public var connectionId: String?
  public var includeArchived: Bool
  public var query: String?
  public init(connectionId: String? = nil, includeArchived: Bool = false, query: String? = nil) {
    self.connectionId = connectionId
    self.includeArchived = includeArchived
    self.query = query
  }
}

/// The workspace index. Opened only by the coordinator; WAL mode, foreign keys, private file mode.
public final class WorkspaceDatabase: Sendable {
  public let path: String
  private let pool: DatabasePool

  public init(path: String) throws {
    self.path = path
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(5)
    pool = try DatabasePool(path: path, configuration: configuration)
    try Migrations.migrator.migrate(pool)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  /// An in-memory database for tests (DatabaseQueue semantics are not needed; a temp file keeps WAL).
  public static func temporary() throws -> WorkspaceDatabase {
    let dir = NSTemporaryDirectory() + "b4app-db-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return try WorkspaceDatabase(path: dir + "/workspace.sqlite")
  }

  public func appliedMigrations() throws -> [String] {
    try pool.read { db in try Migrations.migrator.appliedIdentifiers(db).sorted() }
  }

  public func journalMode() throws -> String {
    try pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "" }
  }

  public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
    try pool.read(block)
  }

  public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
    try pool.write(block)
  }

  public func close() throws {
    try pool.close()
  }

  // MARK: - Connections

  public func listConnections(includeDisabled: Bool = false) throws -> [Connection] {
    try pool.read { db in
      var request = Connection.order(Column("createdAt"))
      if !includeDisabled { request = request.filter(Column("enabled") == true) }
      return try request.fetchAll(db)
    }
  }

  public func connection(id: String) throws -> Connection? {
    try pool.read { db in try Connection.fetchOne(db, key: id) }
  }

  public func connections(kind: ConnectionKind) throws -> [Connection] {
    try pool.read { db in
      try Connection.filter(Column("kind") == kind.rawValue).order(Column("createdAt")).fetchAll(db)
    }
  }

  public func updateConnection(
    id: String, _ mutate: @Sendable (inout Connection) -> Void
  ) throws -> Connection? {
    try pool.write { db in
      guard var connection = try Connection.fetchOne(db, key: id) else { return nil }
      mutate(&connection)
      connection.updatedAt = Timestamp.now()
      try connection.update(db)
      return connection
    }
  }

  public func insertConnection(_ connection: Connection) throws -> Connection {
    try pool.write { db in
      try connection.insert(db)
      return connection
    }
  }

  public func updateConnectionStatus(
    id: String, status: ConnectionStatus, authStatus: AuthStatus, capabilities: Capabilities
  ) throws {
    try pool.write { db in
      guard var connection = try Connection.fetchOne(db, key: id) else { return }
      connection.status = status
      connection.authStatus = authStatus
      connection.capabilities = capabilities
      connection.updatedAt = Timestamp.now()
      try connection.update(db)
    }
  }

  // MARK: - Local servers

  public func listLocalServers() throws -> [LocalServer] {
    try pool.read { db in try LocalServer.order(Column("createdAt")).fetchAll(db) }
  }

  public func insertLocalServer(_ server: LocalServer) throws -> LocalServer {
    try pool.write { db in
      try server.insert(db)
      return server
    }
  }

  public func localServer(id: String) throws -> LocalServer? {
    try pool.read { db in try LocalServer.fetchOne(db, key: id) }
  }

  public func localServer(name: String) throws -> LocalServer? {
    try pool.read { db in try LocalServer.filter(Column("name") == name).fetchOne(db) }
  }

  public func localServer(projectPath: String) throws -> LocalServer? {
    try pool.read { db in try LocalServer.filter(Column("projectPath") == projectPath).fetchOne(db) }
  }

  public func updateLocalServer(
    id: String, _ mutate: @Sendable (inout LocalServer) -> Void
  ) throws -> LocalServer? {
    try pool.write { db in
      guard var server = try LocalServer.fetchOne(db, key: id) else { return nil }
      mutate(&server)
      server.updatedAt = Timestamp.now()
      try server.update(db)
      return server
    }
  }

  public func connections(localServerId: String) throws -> [Connection] {
    try pool.read { db in
      try Connection.filter(Column("localServerId") == localServerId).order(Column("createdAt")).fetchAll(db)
    }
  }

  // MARK: - Threads

  public func listThreads(_ filter: ThreadFilter = ThreadFilter()) throws -> [ConversationThread] {
    try pool.read { db in
      var request = ConversationThread.order(Column("pinned").desc, Column("updatedAt").desc)
      if let connectionId = filter.connectionId {
        request = request.filter(Column("connectionId") == connectionId)
      }
      if !filter.includeArchived { request = request.filter(Column("archived") == false) }
      if let query = filter.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "%", with: "\\%"
        )
        .replacingOccurrences(of: "_", with: "\\_")
        request = request.filter(sql: "title LIKE ? ESCAPE '\\'", arguments: ["%\(escaped)%"])
      }
      return try request.fetchAll(db)
    }
  }

  public func thread(id: String) throws -> ConversationThread? {
    try pool.read { db in try ConversationThread.fetchOne(db, key: id) }
  }

  /// Resolve a native thread id within one connection (newest first if scopes ever overlap).
  public func thread(connectionId: String, nativeThreadId: String) throws -> ConversationThread? {
    try pool.read { db in
      try ConversationThread.filter(
        Column("connectionId") == connectionId && Column("nativeThreadId") == nativeThreadId
      ).order(Column("createdAt").desc).fetchOne(db)
    }
  }

  public func insertThread(_ thread: ConversationThread) throws -> ConversationThread {
    try pool.write { db in
      try thread.insert(db)
      return thread
    }
  }

  public func updateThread(
    id: String, _ mutate: @Sendable (inout ConversationThread) -> Void
  ) throws -> ConversationThread? {
    try pool.write { db in
      guard var thread = try ConversationThread.fetchOne(db, key: id) else { return nil }
      mutate(&thread)
      thread.updatedAt = Timestamp.now()
      try thread.update(db)
      return thread
    }
  }

  // MARK: - Turns

  public func insertTurn(_ turn: Turn) throws -> Turn {
    try pool.write { db in
      try turn.insert(db)
      return turn
    }
  }

  public func turn(operationId: String) throws -> Turn? {
    try pool.read { db in try Turn.filter(Column("operationId") == operationId).fetchOne(db) }
  }

  public func turn(id: String) throws -> Turn? {
    try pool.read { db in try Turn.fetchOne(db, key: id) }
  }

  public func turns(threadId: String) throws -> [Turn] {
    try pool.read { db in
      try Turn.filter(Column("threadId") == threadId).order(Column("createdAt")).fetchAll(db)
    }
  }

  /// The one non-terminal turn of a thread, if any (spec 10.1: at most one active turn per session).
  public func activeTurn(threadId: String) throws -> Turn? {
    try pool.read { db in
      try Turn.filter(Column("threadId") == threadId && Column("status") != TurnStatus.terminal.rawValue)
        .order(Column("createdAt").desc).fetchOne(db)
    }
  }

  public func turn(threadId: String, nativeTurnId: String) throws -> Turn? {
    try pool.read { db in
      try Turn.filter(Column("threadId") == threadId && Column("nativeTurnId") == nativeTurnId).fetchOne(db)
    }
  }

  public func unresolvedTurns() throws -> [Turn] {
    try pool.read { db in
      try Turn.filter(Column("status") != TurnStatus.terminal.rawValue).order(Column("createdAt")).fetchAll(
        db)
    }
  }

  public func updateTurn(id: String, _ mutate: @Sendable (inout Turn) -> Void) throws -> Turn? {
    try pool.write { db in
      guard var turn = try Turn.fetchOne(db, key: id) else { return nil }
      mutate(&turn)
      turn.updatedAt = Timestamp.now()
      try turn.update(db)
      return turn
    }
  }

  // MARK: - Display items

  public func displayItems(threadId: String) throws -> [DisplayItem] {
    try pool.read { db in
      try DisplayItem.filter(Column("threadId") == threadId).order(Column("sequence")).fetchAll(db)
    }
  }

  public func nextDisplaySequence(threadId: String) throws -> Int {
    try pool.read { db in
      (try Int.fetchOne(
        db, sql: "SELECT MAX(sequence) FROM displayItems WHERE threadId = ?", arguments: [threadId]) ?? -1)
        + 1
    }
  }

  public func insertDisplayItem(_ item: DisplayItem) throws -> DisplayItem {
    try pool.write { db in
      try item.insert(db)
      return item
    }
  }

  /// Insert a display item or, when a native id is given and already cached for the thread, replace
  /// that item's payload, type, and provenance in place (its sequence is stable).
  public func upsertDisplayItem(
    threadId: String, turnId: String?, nativeItemId: String?, role: DisplayItemRole, type: String,
    payload: JSONValue, provenance: DisplayProvenance
  ) throws -> DisplayItem {
    try pool.write { db in
      if let nativeItemId,
        var existing = try DisplayItem.filter(
          Column("threadId") == threadId && Column("nativeItemId") == nativeItemId
        ).fetchOne(db)
      {
        existing.payload = payload
        existing.type = type
        existing.role = role
        existing.provenance = provenance
        if existing.turnId == nil { existing.turnId = turnId }
        try existing.update(db)
        return existing
      }
      let next =
        (try Int.fetchOne(
          db, sql: "SELECT MAX(sequence) FROM displayItems WHERE threadId = ?", arguments: [threadId]) ?? -1)
        + 1
      let item = DisplayItem(
        id: UUID().uuidString.lowercased(), threadId: threadId, turnId: turnId, nativeItemId: nativeItemId,
        role: role, type: type, payload: payload, sequence: next, provenance: provenance)
      try item.insert(db)
      return item
    }
  }

  /// The first user item of a turn that has no native id yet (the composer stored it before dispatch).
  public func unlinkedUserItem(threadId: String, turnId: String) throws -> DisplayItem? {
    try pool.read { db in
      try DisplayItem.filter(
        Column("threadId") == threadId && Column("turnId") == turnId
          && Column("role") == DisplayItemRole.user.rawValue && Column("nativeItemId") == nil
      ).order(Column("sequence")).fetchOne(db)
    }
  }

  public func updateDisplayItem(
    id: String, _ mutate: @Sendable (inout DisplayItem) -> Void
  ) throws -> DisplayItem? {
    try pool.write { db in
      guard var item = try DisplayItem.fetchOne(db, key: id) else { return nil }
      mutate(&item)
      try item.update(db)
      return item
    }
  }

  /// Outcome of a snapshot merge, for the reconcile result and tests.
  public struct SnapshotMerge: Sendable, Equatable {
    public var inserted: Int
    public var updated: Int
    public var skipped: Int
    public var removed: Int
    public init(inserted: Int = 0, updated: Int = 0, skipped: Int = 0, removed: Int = 0) {
      self.inserted = inserted
      self.updated = updated
      self.skipped = skipped
      self.removed = removed
    }
  }

  /// Merge native history into the cache (D-031). The snapshot's order is the native order, so the
  /// result is: every snapshot item in snapshot order (an item whose native id is cached keeps that
  /// row; a live row keeps its payload, a snapshot row takes the new one; an id-less item that
  /// matches a cached item of the same role and text reuses that row), then the cached live items
  /// nothing matched (the turn in flight), renumbered in one transaction. Snapshot and cache rows the
  /// snapshot no longer contains are removed. Live rows are never removed or duplicated.
  @discardableResult
  public func mergeSnapshotItems(threadId: String, items: [SnapshotItem]) throws -> SnapshotMerge {
    try pool.write { db in
      let cached = try DisplayItem.filter(Column("threadId") == threadId).order(Column("sequence")).fetchAll(
        db)
      var summary = SnapshotMerge()
      var ordered: [DisplayItem] = []
      var usedRows = Set<String>()
      for item in items {
        let role = DisplayItemRole(rawValue: item.role) ?? .tool
        let match: DisplayItem?
        if let nativeId = item.nativeItemId {
          match = cached.first { $0.nativeItemId == nativeId && !usedRows.contains($0.id) }
        } else if let text = Self.matchText(item.payload), !text.isEmpty {
          match = cached.first {
            $0.role == role && !usedRows.contains($0.id) && Self.matchText($0.payload) == text
          }
        } else {
          match = nil
        }
        if var row = match {
          usedRows.insert(row.id)
          if row.provenance == .live {
            summary.skipped += 1
          } else {
            row.payload = item.payload
            row.type = item.type
            row.role = role
            row.provenance = .snapshot
            summary.updated += 1
          }
          ordered.append(row)
        } else {
          ordered.append(
            DisplayItem(
              id: UUID().uuidString.lowercased(), threadId: threadId, turnId: nil,
              nativeItemId: item.nativeItemId,
              role: role, type: item.type, payload: item.payload, sequence: 0, provenance: .snapshot))
          summary.inserted += 1
        }
      }
      for row in cached where !usedRows.contains(row.id) {
        if row.provenance == .live {
          ordered.append(row)
        } else {
          try row.delete(db)
          summary.removed += 1
        }
      }
      // (threadId, sequence) is unique: park the existing rows below zero before renumbering so no
      // intermediate state collides.
      for (index, var row) in ordered.enumerated() where usedRows.contains(row.id) || row.provenance == .live
      {
        row.sequence = -(index + 1)
        try row.update(db)
      }
      for (index, var row) in ordered.enumerated() {
        row.sequence = index
        try row.save(db)
      }
      return summary
    }
  }

  /// The user-visible text of an item for id-less matching: `text`, or joined `content` text parts.
  static func matchText(_ payload: JSONValue) -> String? {
    if let text = payload["text"]?.stringValue { return text }
    let parts = payload["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue ?? $0.stringValue }
    guard let parts, !parts.isEmpty else { return nil }
    return parts.joined(separator: "\n")
  }

  /// Replace cached items that came from a snapshot while keeping live items of unresolved turns.
  public func replaceSnapshotItems(threadId: String, with items: [DisplayItem]) throws {
    try pool.write { db in
      try db.execute(
        sql: "DELETE FROM displayItems WHERE threadId = ? AND provenance IN ('snapshot', 'cache')",
        arguments: [threadId])
      for item in items { try item.save(db) }
    }
  }

  // MARK: - Runtime requests

  public func pendingRuntimeRequests(threadId: String) throws -> [RuntimeRequest] {
    try pool.read { db in
      try RuntimeRequest.filter(
        Column("threadId") == threadId && Column("state") == RuntimeRequestState.pending.rawValue
      )
      .order(Column("createdAt")).fetchAll(db)
    }
  }

  public func insertRuntimeRequest(_ request: RuntimeRequest) throws -> RuntimeRequest {
    try pool.write { db in
      try request.insert(db)
      return request
    }
  }

  public func runtimeRequest(id: String) throws -> RuntimeRequest? {
    try pool.read { db in try RuntimeRequest.fetchOne(db, key: id) }
  }

  public func runtimeRequest(
    threadId: String, nativeRequestId: String, adapterGeneration: Int
  ) throws -> RuntimeRequest? {
    try pool.read { db in
      try RuntimeRequest.filter(
        Column("threadId") == threadId && Column("nativeRequestId") == nativeRequestId
          && Column("adapterGeneration") == adapterGeneration
      ).fetchOne(db)
    }
  }

  /// Expire every pending request (coordinator restart: no runtime process survived).
  public func expireAllRuntimeRequests() throws -> Int {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE runtimeRequests SET state = 'expired', updatedAt = ? WHERE state = 'pending'",
        arguments: [Timestamp.now()])
      return db.changesCount
    }
  }

  public func pendingRuntimeRequests(connectionId: String) throws -> [RuntimeRequest] {
    try pool.read { db in
      try RuntimeRequest.filter(
        sql: "state = 'pending' AND threadId IN (SELECT id FROM threads WHERE connectionId = ?)",
        arguments: [connectionId]
      ).fetchAll(db)
    }
  }

  /// Non-terminal turns of harness threads (Codex, Claude) with their threads, for the directory lock
  /// (spec 10.1.5). Derived from stored state, so it survives restarts and holds through `reconciling`.
  public func activeHarnessTurns() throws -> [(turn: Turn, thread: ConversationThread)] {
    try pool.read { db in
      let turns = try Turn.filter(
        sql: """
          status != 'terminal' AND threadId IN (
            SELECT t.id FROM threads t JOIN connections c ON c.id = t.connectionId
            WHERE c.kind IN ('codex', 'claude'))
          """
      ).order(Column("createdAt")).fetchAll(db)
      return try turns.compactMap { turn in
        try ConversationThread.fetchOne(db, key: turn.threadId).map { (turn: turn, thread: $0) }
      }
    }
  }

  public func unresolvedTurns(connectionId: String) throws -> [Turn] {
    try pool.read { db in
      try Turn.filter(
        sql: "status != 'terminal' AND threadId IN (SELECT id FROM threads WHERE connectionId = ?)",
        arguments: [connectionId]
      ).fetchAll(db)
    }
  }

  /// Expire every pending request of every thread on a connection (its runtime process is gone).
  public func expireRuntimeRequests(connectionId: String) throws -> Int {
    try pool.write { db in
      try db.execute(
        sql: """
          UPDATE runtimeRequests SET state = 'expired', updatedAt = ?
          WHERE state = 'pending' AND threadId IN (SELECT id FROM threads WHERE connectionId = ?)
          """,
        arguments: [Timestamp.now(), connectionId])
      return db.changesCount
    }
  }

  /// Transition a pending request exactly once; false if it was already resolved or expired.
  public func transitionRuntimeRequest(id: String, to state: RuntimeRequestState) throws -> Bool {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE runtimeRequests SET state = ?, updatedAt = ? WHERE id = ? AND state = 'pending'",
        arguments: [state.rawValue, Timestamp.now(), id])
      return db.changesCount == 1
    }
  }

  public func expireRuntimeRequests(threadId: String, olderThanGeneration generation: Int) throws -> Int {
    try pool.write { db in
      try db.execute(
        sql:
          "UPDATE runtimeRequests SET state = 'expired', updatedAt = ? WHERE threadId = ? AND adapterGeneration < ? AND state = 'pending'",
        arguments: [Timestamp.now(), threadId, generation])
      return db.changesCount
    }
  }

  // MARK: - Drafts

  public func draft(threadId: String) throws -> Draft? {
    try pool.read { db in try Draft.fetchOne(db, key: threadId) }
  }

  public func saveDraft(threadId: String, text: String) throws -> Draft {
    let draft = Draft(threadId: threadId, text: text)
    try pool.write { db in try draft.save(db) }
    return draft
  }

  public func deleteDraft(threadId: String) throws {
    _ = try pool.write { db in try Draft.deleteOne(db, key: threadId) }
  }
}
