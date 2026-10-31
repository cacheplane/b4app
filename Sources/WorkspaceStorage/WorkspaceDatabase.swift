import Foundation
import Synchronization
import WorkspacePlatform
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

/// The workspace index on the private PostgreSQL cluster (decision D-041). Opened only by the
/// coordinator. Every method is synchronous and each write runs in one transaction, so the
/// coordinator's actors keep their atomic sequences.
public final class WorkspaceDatabase: Sendable {
  public let endpoint: PostgresEndpoint
  private let pool: ConnectionPool
  private let adminConnectionString: String
  private let columnCache = Mutex<[String: [String]]>([:])

  /// Connect to a running cluster, create the database when it is missing, and migrate.
  public init(endpoint: PostgresEndpoint, binDir: String) throws {
    self.endpoint = endpoint
    let lib = try LibPQ.load(binDir: binDir)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) application_name=b4app"
    adminConnectionString = base + " dbname=postgres"
    let admin = try PostgresConnection(lib: lib, connectionString: adminConnectionString)
    let exists = try admin.execute("SELECT 1 FROM pg_database WHERE datname = $1", [endpoint.database]).rows
    if exists.isEmpty { try admin.execute("CREATE DATABASE \(Rows.quote(endpoint.database))") }
    pool = try ConnectionPool(lib: lib, connectionString: base + " dbname=\(endpoint.database)", size: 4)
    try pool.withConnection { try Migrator.migrate($0) }
  }

  /// A fresh database on the shared ephemeral test cluster.
  public static func temporary() throws -> WorkspaceDatabase {
    let endpoint = try EphemeralPostgres.endpoint()
    return try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
  }

  public func appliedMigrations() throws -> [String] {
    try pool.withConnection { try Migrator.applied($0) }
  }

  public func close() throws { pool.close() }

  // MARK: - Plumbing

  func read<T>(_ body: (PostgresConnection) throws -> T) throws -> T {
    do { return try pool.withConnection(body) } catch { throw Self.mapped(error) }
  }

  func write<T>(_ body: (PostgresConnection) throws -> T) throws -> T {
    do {
      return try pool.withConnection { c in
        try c.execute("BEGIN")
        do {
          let value = try body(c)
          try c.execute("COMMIT")
          return value
        } catch {
          try? c.execute("ROLLBACK")
          throw error
        }
      }
    } catch { throw Self.mapped(error) }
  }

  private static func mapped(_ error: any Error) -> any Error {
    if let pg = error as? PostgresError {
      return WorkspaceError(
        pg.isConstraintViolation ? .protocolInvalid : .internalError, "PostgreSQL: \(pg.description)")
    }
    return error
  }

  func one<T: Decodable>(
    _ c: PostgresConnection, _ type: T.Type, _ sql: String, _ params: [String?] = []
  ) throws -> T? {
    try c.execute(sql, params).rows.first.map { try Rows.decode(T.self, from: $0) }
  }

  func all<T: Decodable>(
    _ c: PostgresConnection, _ type: T.Type, _ sql: String, _ params: [String?] = []
  ) throws -> [T] {
    try c.execute(sql, params).rows.map { try Rows.decode(T.self, from: $0) }
  }

  private func insert<T: Encodable>(_ c: PostgresConnection, _ table: String, _ value: T) throws {
    let statement = Rows.insert(table, try Rows.encode(value))
    try c.execute(statement.sql, statement.params)
  }

  private func update<T: Encodable>(
    _ c: PostgresConnection, _ table: String, _ value: T, key: String = "id"
  ) throws {
    let statement = Rows.update(
      table, try Rows.encode(value), key: key, allColumns: try columns(c, of: table))
    try c.execute(statement.sql, statement.params)
  }

  private func save<T: Encodable>(
    _ c: PostgresConnection, _ table: String, _ value: T, key: String = "id"
  ) throws {
    let statement = Rows.upsert(
      table, try Rows.encode(value), key: key, allColumns: try columns(c, of: table))
    try c.execute(statement.sql, statement.params)
  }

  /// The table's columns in order, from the catalog, cached for the life of this store.
  func columns(_ c: PostgresConnection, of table: String) throws -> [String] {
    if let cached = columnCache.withLock({ $0[table] }) { return cached }
    let names = try c.execute(
      "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 ORDER BY ordinal_position",
      [table]
    ).rows.compactMap { $0.text("column_name") }
    guard !names.isEmpty else { throw WorkspaceError(.internalError, "Unknown table \(table)") }
    columnCache.withLock { $0[table] = names }
    return names
  }

  private func byId<T: Decodable>(
    _ c: PostgresConnection, _ type: T.Type, _ table: String, _ id: String, key: String = "id"
  ) throws -> T? {
    try one(c, T.self, "SELECT * FROM \(Rows.quote(table)) WHERE \(Rows.quote(key)) = $1", [id])
  }

  // MARK: - Raw access (the one-time SQLite import)

  /// The table's columns, from the catalog.
  func tableColumns(_ table: String) throws -> [String] {
    try read { try columns($0, of: table) }
  }

  func rowCount(table: String) throws -> Int {
    try read {
      try $0.execute("SELECT count(*) AS \"n\" FROM \(Rows.quote(table))").rows.first?.int("n") ?? 0
    }
  }

  /// Insert text rows as they are, one INSERT per row in one transaction; PostgreSQL casts each value
  /// by its column's type (booleans from `true`/`false`, `jsonb` from JSON text).
  func insertRaw(table: String, columns: [String], rows: [[String?]]) throws {
    try insertRaw(batches: [(table, columns, rows)])
  }

  /// Several tables' rows in one transaction, each batch one `INSERT` per row.
  func insertRaw(batches: [(table: String, columns: [String], rows: [[String?]])]) throws {
    try write { c in
      for batch in batches where !batch.rows.isEmpty && !batch.columns.isEmpty {
        let names = batch.columns.map(Rows.quote).joined(separator: ", ")
        let placeholders = (1...batch.columns.count).map { "$\($0)" }.joined(separator: ", ")
        let sql = "INSERT INTO \(Rows.quote(batch.table)) (\(names)) VALUES (\(placeholders))"
        for row in batch.rows {
          guard row.count == batch.columns.count else {
            throw WorkspaceError(
              .internalError,
              "Row of \(batch.table) has \(row.count) values for \(batch.columns.count) columns")
          }
          try c.execute(sql, row)
        }
      }
    }
  }

  // MARK: - Connections

  public func listConnections(includeDisabled: Bool = false) throws -> [Connection] {
    try read { c in
      try all(
        c, Connection.self,
        "SELECT * FROM \"connections\"" + (includeDisabled ? "" : " WHERE \"enabled\" = true")
          + " ORDER BY \"createdAt\"")
    }
  }

  public func connection(id: String) throws -> Connection? {
    try read { try byId($0, Connection.self, "connections", id) }
  }

  public func connections(kind: ConnectionKind) throws -> [Connection] {
    try read {
      try all(
        $0, Connection.self, "SELECT * FROM \"connections\" WHERE \"kind\" = $1 ORDER BY \"createdAt\"",
        [kind.rawValue])
    }
  }

  public func updateConnection(
    id: String, _ mutate: @Sendable (inout Connection) -> Void
  ) throws -> Connection? {
    try write { c in
      guard var connection = try byId(c, Connection.self, "connections", id) else { return nil }
      mutate(&connection)
      connection.updatedAt = Timestamp.now()
      try update(c, "connections", connection)
      return connection
    }
  }

  public func insertConnection(_ connection: Connection) throws -> Connection {
    try write { c in
      try insert(c, "connections", connection)
      return connection
    }
  }

  public func updateConnectionStatus(
    id: String, status: ConnectionStatus, authStatus: AuthStatus, capabilities: Capabilities
  ) throws {
    _ = try updateConnection(id: id) {
      $0.status = status
      $0.authStatus = authStatus
      $0.capabilities = capabilities
    }
  }

  // MARK: - Local servers

  public func listLocalServers() throws -> [LocalServer] {
    try read { try all($0, LocalServer.self, "SELECT * FROM \"localServers\" ORDER BY \"createdAt\"") }
  }

  public func insertLocalServer(_ server: LocalServer) throws -> LocalServer {
    try write { c in
      try insert(c, "localServers", server)
      return server
    }
  }

  public func localServer(id: String) throws -> LocalServer? {
    try read { try byId($0, LocalServer.self, "localServers", id) }
  }

  public func localServer(name: String) throws -> LocalServer? {
    try read { try one($0, LocalServer.self, "SELECT * FROM \"localServers\" WHERE \"name\" = $1", [name]) }
  }

  public func localServer(projectPath: String) throws -> LocalServer? {
    try read {
      try one(
        $0, LocalServer.self, "SELECT * FROM \"localServers\" WHERE \"projectPath\" = $1", [projectPath])
    }
  }

  public func updateLocalServer(
    id: String, _ mutate: @Sendable (inout LocalServer) -> Void
  ) throws -> LocalServer? {
    try write { c in
      guard var server = try byId(c, LocalServer.self, "localServers", id) else { return nil }
      mutate(&server)
      server.updatedAt = Timestamp.now()
      try update(c, "localServers", server)
      return server
    }
  }

  public func connections(localServerId: String) throws -> [Connection] {
    try read {
      try all(
        $0, Connection.self,
        "SELECT * FROM \"connections\" WHERE \"localServerId\" = $1 ORDER BY \"createdAt\"", [localServerId])
    }
  }

  // MARK: - Threads

  public func listThreads(_ filter: ThreadFilter = ThreadFilter()) throws -> [ConversationThread] {
    try read { c in
      var clauses: [String] = []
      var params: [String?] = []
      if let connectionId = filter.connectionId {
        params.append(connectionId)
        clauses.append("\"connectionId\" = $\(params.count)")
      }
      if !filter.includeArchived { clauses.append("\"archived\" = false") }
      if let query = filter.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "%", with: "\\%"
        )
        .replacingOccurrences(of: "_", with: "\\_")
        params.append("%\(escaped)%")
        clauses.append("\"title\" ILIKE $\(params.count) ESCAPE '\\'")
      }
      let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
      return try all(
        c, ConversationThread.self,
        "SELECT * FROM \"threads\"" + whereSQL + " ORDER BY \"pinned\" DESC, \"updatedAt\" DESC", params)
    }
  }

  public func thread(id: String) throws -> ConversationThread? {
    try read { try byId($0, ConversationThread.self, "threads", id) }
  }

  /// Resolve a native thread id within one connection (newest first if scopes ever overlap).
  public func thread(connectionId: String, nativeThreadId: String) throws -> ConversationThread? {
    try read {
      try one(
        $0, ConversationThread.self,
        "SELECT * FROM \"threads\" WHERE \"connectionId\" = $1 AND \"nativeThreadId\" = $2 ORDER BY \"createdAt\" DESC LIMIT 1",
        [connectionId, nativeThreadId])
    }
  }

  public func insertThread(_ thread: ConversationThread) throws -> ConversationThread {
    try write { c in
      try insert(c, "threads", thread)
      return thread
    }
  }

  public func updateThread(
    id: String, _ mutate: @Sendable (inout ConversationThread) -> Void
  ) throws -> ConversationThread? {
    try write { c in
      guard var thread = try byId(c, ConversationThread.self, "threads", id) else { return nil }
      mutate(&thread)
      thread.updatedAt = Timestamp.now()
      try update(c, "threads", thread)
      return thread
    }
  }

  // MARK: - Turns

  public func insertTurn(_ turn: Turn) throws -> Turn {
    try write { c in
      try insert(c, "turns", turn)
      return turn
    }
  }

  public func turn(operationId: String) throws -> Turn? {
    try read { try one($0, Turn.self, "SELECT * FROM \"turns\" WHERE \"operationId\" = $1", [operationId]) }
  }

  public func turn(id: String) throws -> Turn? {
    try read { try byId($0, Turn.self, "turns", id) }
  }

  public func turns(threadId: String) throws -> [Turn] {
    try read {
      try all(
        $0, Turn.self, "SELECT * FROM \"turns\" WHERE \"threadId\" = $1 ORDER BY \"createdAt\"", [threadId])
    }
  }

  /// The one non-terminal turn of a thread, if any (spec 10.1: at most one active turn per session).
  public func activeTurn(threadId: String) throws -> Turn? {
    try read {
      try one(
        $0, Turn.self,
        "SELECT * FROM \"turns\" WHERE \"threadId\" = $1 AND \"status\" <> 'terminal' ORDER BY \"createdAt\" DESC LIMIT 1",
        [threadId])
    }
  }

  public func turn(threadId: String, nativeTurnId: String) throws -> Turn? {
    try read {
      try one(
        $0, Turn.self, "SELECT * FROM \"turns\" WHERE \"threadId\" = $1 AND \"nativeTurnId\" = $2 LIMIT 1",
        [threadId, nativeTurnId])
    }
  }

  public func unresolvedTurns() throws -> [Turn] {
    try read {
      try all($0, Turn.self, "SELECT * FROM \"turns\" WHERE \"status\" <> 'terminal' ORDER BY \"createdAt\"")
    }
  }

  public func updateTurn(id: String, _ mutate: @Sendable (inout Turn) -> Void) throws -> Turn? {
    try write { c in
      guard var turn = try byId(c, Turn.self, "turns", id) else { return nil }
      mutate(&turn)
      turn.updatedAt = Timestamp.now()
      try update(c, "turns", turn)
      return turn
    }
  }

  // MARK: - Display items

  public func displayItems(threadId: String) throws -> [DisplayItem] {
    try read {
      try all(
        $0, DisplayItem.self, "SELECT * FROM \"displayItems\" WHERE \"threadId\" = $1 ORDER BY \"sequence\"",
        [threadId])
    }
  }

  public func nextDisplaySequence(threadId: String) throws -> Int {
    try read { try Self.nextSequence($0, threadId: threadId) }
  }

  private static func nextSequence(_ c: PostgresConnection, threadId: String) throws -> Int {
    let rows = try c.execute(
      "SELECT COALESCE(MAX(\"sequence\"), -1) + 1 AS \"next\" FROM \"displayItems\" WHERE \"threadId\" = $1",
      [threadId]
    ).rows
    return rows.first?.int("next") ?? 0
  }

  public func insertDisplayItem(_ item: DisplayItem) throws -> DisplayItem {
    try write { c in
      try insert(c, "displayItems", item)
      return item
    }
  }

  /// Insert a display item or, when a native id is given and already cached for the thread, replace
  /// that item's payload, type, and provenance in place (its sequence is stable).
  public func upsertDisplayItem(
    threadId: String, turnId: String?, nativeItemId: String?, role: DisplayItemRole, type: String,
    payload: JSONValue, provenance: DisplayProvenance
  ) throws -> DisplayItem {
    try write { c in
      if let nativeItemId,
        var existing = try one(
          c, DisplayItem.self,
          "SELECT * FROM \"displayItems\" WHERE \"threadId\" = $1 AND \"nativeItemId\" = $2 ORDER BY \"sequence\" LIMIT 1",
          [threadId, nativeItemId])
      {
        existing.payload = payload
        existing.type = type
        existing.role = role
        existing.provenance = provenance
        if existing.turnId == nil { existing.turnId = turnId }
        try update(c, "displayItems", existing)
        return existing
      }
      let item = DisplayItem(
        id: UUID().uuidString.lowercased(), threadId: threadId, turnId: turnId, nativeItemId: nativeItemId,
        role: role, type: type, payload: payload, sequence: try Self.nextSequence(c, threadId: threadId),
        provenance: provenance)
      try insert(c, "displayItems", item)
      return item
    }
  }

  /// The first user item of a turn that has no native id yet (the composer stored it before dispatch).
  public func unlinkedUserItem(threadId: String, turnId: String) throws -> DisplayItem? {
    try read {
      try one(
        $0, DisplayItem.self,
        "SELECT * FROM \"displayItems\" WHERE \"threadId\" = $1 AND \"turnId\" = $2 AND \"role\" = 'user' AND \"nativeItemId\" IS NULL ORDER BY \"sequence\" LIMIT 1",
        [threadId, turnId])
    }
  }

  public func updateDisplayItem(
    id: String, _ mutate: @Sendable (inout DisplayItem) -> Void
  ) throws -> DisplayItem? {
    try write { c in
      guard var item = try byId(c, DisplayItem.self, "displayItems", id) else { return nil }
      mutate(&item)
      try update(c, "displayItems", item)
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
    try write { c in
      let cached = try all(
        c, DisplayItem.self, "SELECT * FROM \"displayItems\" WHERE \"threadId\" = $1 ORDER BY \"sequence\"",
        [threadId])
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
          try c.execute("DELETE FROM \"displayItems\" WHERE \"id\" = $1", [row.id])
          summary.removed += 1
        }
      }
      // (threadId, sequence) is unique: park the existing rows below zero before renumbering so no
      // intermediate state collides.
      for (index, var row) in ordered.enumerated() where usedRows.contains(row.id) || row.provenance == .live
      {
        row.sequence = -(index + 1)
        try update(c, "displayItems", row)
      }
      for (index, var row) in ordered.enumerated() {
        row.sequence = index
        try save(c, "displayItems", row)
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

  /// Drop a thread's whole transcript cache (a lost cache; the next read rebuilds it from the runtime).
  public func deleteDisplayItems(threadId: String) throws -> Int {
    try write { try $0.execute("DELETE FROM \"displayItems\" WHERE \"threadId\" = $1", [threadId]).affected }
  }

  /// Replace cached items that came from a snapshot while keeping live items of unresolved turns.
  public func replaceSnapshotItems(threadId: String, with items: [DisplayItem]) throws {
    try write { c in
      try c.execute(
        "DELETE FROM \"displayItems\" WHERE \"threadId\" = $1 AND \"provenance\" IN ('snapshot', 'cache')",
        [threadId])
      for item in items { try save(c, "displayItems", item) }
    }
  }

  // MARK: - Runtime requests

  public func pendingRuntimeRequests(threadId: String) throws -> [RuntimeRequest] {
    try read {
      try all(
        $0, RuntimeRequest.self,
        "SELECT * FROM \"runtimeRequests\" WHERE \"threadId\" = $1 AND \"state\" = 'pending' ORDER BY \"createdAt\"",
        [threadId])
    }
  }

  public func insertRuntimeRequest(_ request: RuntimeRequest) throws -> RuntimeRequest {
    try write { c in
      try insert(c, "runtimeRequests", request)
      return request
    }
  }

  public func runtimeRequest(id: String) throws -> RuntimeRequest? {
    try read { try byId($0, RuntimeRequest.self, "runtimeRequests", id) }
  }

  public func runtimeRequest(
    threadId: String, nativeRequestId: String, adapterGeneration: Int
  ) throws -> RuntimeRequest? {
    try read {
      try one(
        $0, RuntimeRequest.self,
        "SELECT * FROM \"runtimeRequests\" WHERE \"threadId\" = $1 AND \"nativeRequestId\" = $2 AND \"adapterGeneration\" = $3::int LIMIT 1",
        [threadId, nativeRequestId, String(adapterGeneration)])
    }
  }

  /// Expire every pending request (coordinator restart: no runtime process survived).
  public func expireAllRuntimeRequests() throws -> Int {
    try write {
      try $0.execute(
        "UPDATE \"runtimeRequests\" SET \"state\" = 'expired', \"updatedAt\" = $1 WHERE \"state\" = 'pending'",
        [Timestamp.now()]
      ).affected
    }
  }

  public func pendingRuntimeRequests(connectionId: String) throws -> [RuntimeRequest] {
    try read {
      try all(
        $0, RuntimeRequest.self,
        "SELECT * FROM \"runtimeRequests\" WHERE \"state\" = 'pending' AND \"threadId\" IN (SELECT \"id\" FROM \"threads\" WHERE \"connectionId\" = $1)",
        [connectionId])
    }
  }

  /// Non-terminal turns of harness threads (Codex, Claude) with their threads, for the directory lock
  /// (spec 10.1.5). Derived from stored state, so it survives restarts and holds through `reconciling`.
  public func activeHarnessTurns() throws -> [(turn: Turn, thread: ConversationThread)] {
    try read { c in
      let turns = try all(
        c, Turn.self,
        """
        SELECT * FROM "turns" WHERE "status" <> 'terminal' AND "threadId" IN (
          SELECT t."id" FROM "threads" t JOIN "connections" c ON c."id" = t."connectionId"
          WHERE c."kind" IN ('codex', 'claude')) ORDER BY "createdAt"
        """)
      return try turns.compactMap { turn in
        try byId(c, ConversationThread.self, "threads", turn.threadId).map { (turn: turn, thread: $0) }
      }
    }
  }

  public func unresolvedTurns(connectionId: String) throws -> [Turn] {
    try read {
      try all(
        $0, Turn.self,
        "SELECT * FROM \"turns\" WHERE \"status\" <> 'terminal' AND \"threadId\" IN (SELECT \"id\" FROM \"threads\" WHERE \"connectionId\" = $1)",
        [connectionId])
    }
  }

  /// Expire every pending request of every thread on a connection (its runtime process is gone).
  public func expireRuntimeRequests(connectionId: String) throws -> Int {
    try write {
      try $0.execute(
        "UPDATE \"runtimeRequests\" SET \"state\" = 'expired', \"updatedAt\" = $1 WHERE \"state\" = 'pending' AND \"threadId\" IN (SELECT \"id\" FROM \"threads\" WHERE \"connectionId\" = $2)",
        [Timestamp.now(), connectionId]
      ).affected
    }
  }

  /// Transition a pending request exactly once; false if it was already resolved or expired.
  public func transitionRuntimeRequest(id: String, to state: RuntimeRequestState) throws -> Bool {
    try write {
      try $0.execute(
        "UPDATE \"runtimeRequests\" SET \"state\" = $1, \"updatedAt\" = $2 WHERE \"id\" = $3 AND \"state\" = 'pending'",
        [state.rawValue, Timestamp.now(), id]
      ).affected == 1
    }
  }

  public func expireRuntimeRequests(threadId: String, olderThanGeneration generation: Int) throws -> Int {
    try write {
      try $0.execute(
        "UPDATE \"runtimeRequests\" SET \"state\" = 'expired', \"updatedAt\" = $1 WHERE \"threadId\" = $2 AND \"adapterGeneration\" < $3::int AND \"state\" = 'pending'",
        [Timestamp.now(), threadId, String(generation)]
      ).affected
    }
  }

  // MARK: - Drafts

  public func draft(threadId: String) throws -> Draft? {
    try read { try byId($0, Draft.self, "drafts", threadId, key: "threadId") }
  }

  public func saveDraft(threadId: String, text: String) throws -> Draft {
    let draft = Draft(threadId: threadId, text: text)
    try write { try save($0, "drafts", draft, key: "threadId") }
    return draft
  }

  public func deleteDraft(threadId: String) throws {
    try write { _ = try $0.execute("DELETE FROM \"drafts\" WHERE \"threadId\" = $1", [threadId]) }
  }
}
