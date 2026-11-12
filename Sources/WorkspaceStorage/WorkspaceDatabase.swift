import Foundation
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol

public struct ThreadFilter: Sendable, Equatable {
  public var connectionId: String?
  public var includeArchived: Bool
  public var query: String?
  public var environmentId: String?
  public init(
    connectionId: String? = nil, includeArchived: Bool = false, query: String? = nil,
    environmentId: String? = nil
  ) {
    self.connectionId = connectionId
    self.includeArchived = includeArchived
    self.query = query
    self.environmentId = environmentId
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
  private let currentDeviceId = Mutex("local")

  /// Stamps every write transaction (`b4app.hlc`); its device id always equals `deviceId`.
  public let clock: HybridClock

  /// The device id the change-log trigger records on every write (`b4app.device_id`). `local` until
  /// this Mac joins a hub; the hub's device id afterwards.
  public var deviceId: String {
    get { currentDeviceId.withLock { $0 } }
    set {
      currentDeviceId.withLock {
        $0 = newValue
        clock.deviceId = newValue
      }
    }
  }

  /// Connect to a running cluster, create the database when it is missing (unless `createIfMissing` is
  /// false, when a missing one is `not_found`), and migrate. A failed migration closes the pool and
  /// throws. `wall` is the clock's time source (tests pin it to replay recorded clocks).
  public init(
    endpoint: PostgresEndpoint, binDir: String, createIfMissing: Bool = true,
    backupDirectory: String? = nil,
    wall: @escaping @Sendable () -> UInt64 = epochMillis
  ) throws {
    self.endpoint = endpoint
    clock = HybridClock(deviceId: "local", wall: wall)
    let lib = try LibPQ.load(binDir: binDir)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) application_name=b4app"
    adminConnectionString = base + " dbname=postgres"
    let admin = try PostgresConnection(lib: lib, connectionString: adminConnectionString)
    let exists = try admin.execute("SELECT 1 FROM pg_database WHERE datname = $1", [endpoint.database]).rows
    if exists.isEmpty {
      guard createIfMissing else {
        throw WorkspaceError(.notFound, "The database \(endpoint.database) does not exist.")
      }
      try admin.execute("CREATE DATABASE \(Rows.quote(endpoint.database))")
    }
    pool = try ConnectionPool(lib: lib, connectionString: base + " dbname=\(endpoint.database)", size: 4)
    do {
      try pool.withConnection { c in
        try Self.migrateWithBackup(c, endpoint: endpoint, backupDirectory: backupDirectory)
      }
    } catch {
      pool.close()
      throw error
    }
  }

  /// A fresh database on the shared ephemeral test cluster.
  public static func temporary(
    wall: @escaping @Sendable () -> UInt64 = epochMillis
  ) throws
    -> WorkspaceDatabase
  {
    let endpoint = try EphemeralPostgres.endpoint()
    return try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!, wall: wall)
  }

  public func appliedMigrations() throws -> [String] {
    try pool.withConnection { try Migrator.applied($0) }
  }

  public func close() throws { pool.close() }

  /// Storage-module admission facts for the account lifecycle, not a protocol/UI state.
  public enum MigrationState: Sendable, Equatable {
    case missing, current, pending
  }

  /// Inspect migration state without creating a database/ledger or opening a migrating pool. The
  /// normal initializer must still recheck under its exclusive advisory lock before applying SQL.
  public static func preflightMigration(
    endpoint: PostgresEndpoint, binDir: String
  ) throws
    -> MigrationState
  {
    let lib = try LibPQ.load(binDir: binDir)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) application_name=b4app"
    let admin = try PostgresConnection(lib: lib, connectionString: base + " dbname=postgres")
    guard try !admin.execute("SELECT 1 FROM pg_database WHERE datname = $1", [endpoint.database]).rows.isEmpty
    else { return .missing }
    let connection = try PostgresConnection(
      lib: lib, connectionString: base + " dbname=\(endpoint.database)")
    try connection.execute("BEGIN READ ONLY")
    defer { _ = try? connection.execute("ROLLBACK") }
    return try Migrator.pending(connection) ? .pending : .current
  }

  /// Close admission and bound the wait for this database's admitted pool leases. False never
  /// authorizes migration; the account lifecycle must quiesce its scope before requesting capture.
  public func closeForMigration(timeout: Duration) -> Bool {
    pool.closeForMigration(timeout: timeout)
  }

  // MARK: - Plumbing

  func read<T>(_ body: (PostgresConnection) throws -> T) throws -> T {
    do { return try pool.withConnection(body) } catch { throw Self.mapped(error) }
  }

  /// The transaction-scoped advisory lock that orders local writes against pulled batches: every
  /// `write` holds it shared, `applyRemote` exclusive (any fixed value works; this is "b4ap" in ASCII).
  static let remoteApplyLockKey: Int64 = 0x6234_6170

  /// One transaction. It first takes `remoteApplyLockKey`, shared (or exclusive, for `applyRemote`),
  /// before anything else, and only then sets `b4app.hlc` to the next clock stamp, so every change the
  /// transaction records shares it, and, when this Mac has a hub device id, `b4app.device_id` so the
  /// change-log trigger records it. (`read` runs outside a transaction, where a transaction-local
  /// setting would not persist, and no trigger fires on a read.)
  ///
  /// The lock comes first so a local write that starts while a pull batch is being applied waits for
  /// the batch to commit before it takes its clock, which has by then observed every pulled clock: the
  /// local edit is stamped after them and wins, on this Mac and at the hub alike. And because a pull
  /// takes the lock before any row lock and a local write takes it before any row lock, a pull never
  /// holds a row lock that a local write waits on, or the reverse, so the two cannot deadlock.
  func write<T>(exclusive: Bool = false, _ body: (PostgresConnection) throws -> T) throws -> T {
    let device = deviceId
    do {
      return try pool.withConnection { c in
        try c.execute("BEGIN")
        do {
          try c.execute(
            exclusive
              ? "SELECT pg_advisory_xact_lock($1::bigint)"
              : "SELECT pg_advisory_xact_lock_shared($1::bigint)",
            [String(Self.remoteApplyLockKey)])
          try c.execute("SELECT set_config('b4app.hlc', $1, true)", [clock.next().rawValue])
          if device != "local" { try c.execute("SELECT set_config('b4app.device_id', $1, true)", [device]) }
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

  /// Inserts `value`'s stored properties. A property that is not a column of the table (a thread's
  /// computed `activity` and `ownerDeviceName`) is dropped here, so computed fields are never written.
  func insert<T: Encodable>(_ c: PostgresConnection, _ table: String, _ value: T) throws {
    let known = Set(try columns(c, of: table))
    let statement = Rows.insert(table, try Rows.encode(value).filter { known.contains($0.column) })
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
    let all = try columns(c, of: table)
    let statement = Rows.upsert(
      table, try Rows.encode(value).filter { all.contains($0.column) }, key: key, allColumns: all)
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

  func byId<T: Decodable>(
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
      // Locked, so a concurrent `setConnectionEnvironment` is never overwritten by this row's old copy.
      guard
        var connection = try one(
          c, Connection.self, "SELECT * FROM \"connections\" WHERE \"id\" = $1 FOR UPDATE", [id])
      else { return nil }
      let original = connection
      mutate(&connection)
      if original.kind == .agentProtocol || connection.kind == .agentProtocol {
        func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
          switch (lhs, rhs) {
          case (nil, nil): return true
          case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
          default: return false
          }
        }
        guard sameBytes(connection.id, original.id), connection.kind == original.kind,
          sameBytes(connection.target, original.target), connection.peerProfile == original.peerProfile,
          sameBytes(connection.agentId, original.agentId),
          sameBytes(connection.nativeScope, original.nativeScope)
        else {
          throw WorkspaceError(
            .protocolInvalid, "Agent Protocol identity cannot change. Create a new connection.")
        }
      }
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

  /// Every thread column plus `activity`, computed in the same query: the latest turn (greatest
  /// `createdAt`, ties by greatest `id`), the count of pending runtime requests and of those that ask
  /// for approval (`RuntimeRequestKind.isApproval`), and the newest of the thread's `createdAt` and
  /// its latest turn's and latest request's `updatedAt`. Timestamps are ISO-8601 text, compared
  /// bytewise (`COLLATE "C"`). Callers append a WHERE clause on `t`.
  static let threadWithActivity = """
    SELECT t.*, jsonb_build_object(
      'latestTurnId', lt."id",
      'latestTurnStatus', lt."status",
      'latestTurnOutcome', lt."outcome",
      'pendingRequests', pr."n",
      'pendingApprovals', pr."approvals",
      'lastActivityAt', (
        SELECT max(v."x" COLLATE "C") FROM (VALUES (t."createdAt"), (lt."updatedAt"), (lr."updatedAt")) AS v("x"))
    ) AS "activity"
    FROM "threads" t
    LEFT JOIN LATERAL (
      SELECT "id", "status", "outcome", "updatedAt" FROM "turns" WHERE "threadId" = t."id"
      ORDER BY "createdAt" COLLATE "C" DESC, "id" COLLATE "C" DESC LIMIT 1) lt ON true
    LEFT JOIN LATERAL (
      SELECT "updatedAt" FROM "runtimeRequests" WHERE "threadId" = t."id"
      ORDER BY "updatedAt" COLLATE "C" DESC LIMIT 1) lr ON true
    CROSS JOIN LATERAL (
      SELECT count(*) AS "n",
        count(*) FILTER (
          WHERE "kind" IN ('command_approval', 'file_change_approval', 'tool_permission')) AS "approvals"
      FROM "runtimeRequests" WHERE "threadId" = t."id" AND "state" = 'pending') pr
    """

  public func listThreads(_ filter: ThreadFilter = ThreadFilter()) throws -> [ConversationThread] {
    try read { c in
      // A deleted thread is never listed, archived or not; `thread(id:)` still finds it.
      var clauses: [String] = ["t.\"userDeletedAt\" IS NULL"]
      var params: [String?] = []
      if let connectionId = filter.connectionId {
        params.append(connectionId)
        clauses.append("t.\"connectionId\" = $\(params.count)")
      }
      if let environmentId = filter.environmentId {
        params.append(environmentId)
        clauses.append("t.\"environmentId\" = $\(params.count)")
      }
      if !filter.includeArchived { clauses.append("t.\"archived\" = false") }
      if let query = filter.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "%", with: "\\%"
        )
        .replacingOccurrences(of: "_", with: "\\_")
        params.append("%\(escaped)%")
        clauses.append("t.\"title\" ILIKE $\(params.count) ESCAPE '\\'")
      }
      let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
      return try all(
        c, ConversationThread.self,
        Self.threadWithActivity + whereSQL + " ORDER BY t.\"pinned\" DESC, t.\"updatedAt\" DESC", params)
    }
  }

  public func thread(id: String) throws -> ConversationThread? {
    try read { try threadWithActivity($0, id: id) }
  }

  func threadWithActivity(_ c: PostgresConnection, id: String) throws -> ConversationThread? {
    try one(c, ConversationThread.self, Self.threadWithActivity + " WHERE t.\"id\" = $1", [id])
  }

  /// Resolve a native thread id within one connection (newest first if scopes ever overlap).
  public func thread(connectionId: String, nativeThreadId: String) throws -> ConversationThread? {
    try read {
      try one(
        $0, ConversationThread.self,
        Self.threadWithActivity
          + " WHERE t.\"connectionId\" = $1 AND t.\"nativeThreadId\" = $2 ORDER BY t.\"createdAt\" DESC LIMIT 1",
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
      // Locked, so a pulled phone edit committing meanwhile is not written back over with the old value.
      guard
        var thread = try one(
          c, ConversationThread.self, "SELECT * FROM \"threads\" WHERE \"id\" = $1 FOR UPDATE", [id])
      else { return nil }
      mutate(&thread)
      thread.updatedAt = Timestamp.now()
      try update(c, "threads", thread)
      return thread
    }
  }

  /// Mark a thread read up to `turnId`, or unread again with nil. A turn is written only when it is a
  /// terminal turn of this thread created no earlier than the turn the marker already names (same
  /// order as the latest turn: `createdAt`, ties by `id`); anything else returns the thread unchanged.
  /// Moves no `updatedAt`: reading is not an edit of the thread. Nil when the thread does not exist.
  public func markRead(threadId: String, turnId: String?) throws -> ConversationThread? {
    try write { c in
      if let turnId {
        _ = try c.execute(
          """
          UPDATE "threads" SET "readTurnId" = $2::text
          WHERE "id" = $1 AND "readTurnId" IS DISTINCT FROM $2::text
            AND EXISTS (
              SELECT 1 FROM "turns" candidate
              WHERE candidate."id" = $2::text AND candidate."threadId" = $1 AND candidate."status" = 'terminal'
                AND NOT EXISTS (
                  SELECT 1 FROM "turns" marker
                  WHERE marker."id" = "threads"."readTurnId"
                    AND (candidate."createdAt" COLLATE "C", candidate."id" COLLATE "C")
                      < (marker."createdAt" COLLATE "C", marker."id" COLLATE "C")))
          """, [threadId, turnId])
      } else {
        _ = try c.execute(
          "UPDATE \"threads\" SET \"readTurnId\" = NULL WHERE \"id\" = $1 AND \"readTurnId\" IS NOT NULL",
          [threadId])
      }
      return try threadWithActivity(c, id: threadId)
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
  /// A tagged message may also recover its canonical id within one unambiguous terminal,
  /// acknowledged native turn, matching role, type and exact text. Reserve all exact native ids
  /// before that fallback; never apply the legacy global text match to a tagged item.
  @discardableResult
  public func mergeSnapshotItems(threadId: String, items: [SnapshotItem]) throws -> SnapshotMerge {
    try write { c in
      let cached = try all(
        c, DisplayItem.self, "SELECT * FROM \"displayItems\" WHERE \"threadId\" = $1 ORDER BY \"sequence\"",
        [threadId])
      var summary = SnapshotMerge()
      var ordered: [DisplayItem] = []
      var usedRows = Set<String>()
      let turns = try all(c, Turn.self, "SELECT * FROM turns WHERE \"threadId\" = $1", [threadId])
      let reservedIds = Set(items.compactMap(\.nativeItemId))
      for item in items {
        let role = DisplayItemRole(rawValue: item.role) ?? .tool
        var match: DisplayItem?
        if let nativeId = item.nativeItemId {
          match = cached.first { $0.nativeItemId == nativeId && !usedRows.contains($0.id) }
        }
        if match == nil, let nativeTurnId = item.nativeTurnId,
          role == .user || role == .assistant,
          let text = Self.matchText(item.payload), !text.isEmpty
        {
          let candidates = turns.filter { $0.nativeTurnId == nativeTurnId }
          if candidates.count == 1, let turn = candidates.first,
            turn.status == .terminal, turn.submission == .acknowledged
          {
            match = cached.first {
              $0.turnId == turn.id && $0.provenance == .live && $0.role == role && $0.type == item.type
                && !usedRows.contains($0.id) && Self.matchText($0.payload) == text
                && ($0.nativeItemId.map { !reservedIds.contains($0) } ?? true)
            }
          }
        }
        if match == nil, item.nativeTurnId == nil, item.nativeItemId == nil,
          let text = Self.matchText(item.payload), !text.isEmpty
        {
          match = cached.first {
            $0.role == role && !usedRows.contains($0.id) && Self.matchText($0.payload) == text
          }
        }
        if var row = match {
          usedRows.insert(row.id)
          if row.provenance == .live {
            if let nativeId = item.nativeItemId, row.nativeItemId != nativeId {
              row.nativeItemId = nativeId
              summary.updated += 1
            } else {
              summary.skipped += 1
            }
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
    try write { c in
      // The thread's lock first, as `applyRemote` takes it, so a pulled draft and this save queue behind
      // each other instead of each holding half of what the other needs.
      try c.execute("SELECT 1 FROM \"threads\" WHERE \"id\" = $1 FOR KEY SHARE", [threadId])
      try save(c, "drafts", draft, key: "threadId")
    }
    return draft
  }

  public func deleteDraft(threadId: String) throws {
    try write { _ = try $0.execute("DELETE FROM \"drafts\" WHERE \"threadId\" = $1", [threadId]) }
  }

  /// Empty a draft's text but keep its row, so the clearing syncs as an update and wins against an older
  /// edit; a draft is deleted only with its thread. Does nothing when there is no draft or it is empty.
  public func clearDraft(threadId: String) throws {
    try write {
      _ = try $0.execute(
        "UPDATE \"drafts\" SET \"text\" = '', \"updatedAt\" = $2 WHERE \"threadId\" = $1 AND \"text\" <> ''",
        [threadId, Timestamp.now()])
    }
  }

  // MARK: - Hub link (M8a, local only)

  /// The hub this Mac has joined. `tokenRef` names the device token in the secret store; the token
  /// itself is never stored here.
  public struct HubLink: Codable, Sendable, Equatable {
    public var url: String
    public var deviceId: String
    public var deviceName: String
    public var tokenRef: String
    public var orgSlug: String
    public var username: String
    public var cursor: Int
    public var lastPushAt: String?
    public var lastError: String?
    public var joinedAt: String

    public init(
      url: String, deviceId: String, deviceName: String, tokenRef: String, orgSlug: String, username: String,
      cursor: Int = 0, lastPushAt: String? = nil, lastError: String? = nil, joinedAt: String
    ) {
      self.url = url
      self.deviceId = deviceId
      self.deviceName = deviceName
      self.tokenRef = tokenRef
      self.orgSlug = orgSlug
      self.username = username
      self.cursor = cursor
      self.lastPushAt = lastPushAt
      self.lastError = lastError
      self.joinedAt = joinedAt
    }
  }

  /// Drop `endpoint`'s database, closing whatever connections it still has (a deleted account's, sign-in
  /// plan Task 10). Its pool must already be closed. A missing database is not an error.
  public static func drop(endpoint: PostgresEndpoint, binDir: String) throws {
    let lib = try LibPQ.load(binDir: binDir)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) application_name=b4app"
    let admin = try PostgresConnection(lib: lib, connectionString: base + " dbname=postgres")
    try admin.execute("DROP DATABASE IF EXISTS \(Rows.quote(endpoint.database)) WITH (FORCE)")
  }

  /// The URL of the hub link in another install's database, read without changing anything: no
  /// migration, no database created, one read-only transaction. Nil when the cluster has no such
  /// database, no `hubLink` table, or no link row. The cluster must be running on `endpoint`. Sign-in
  /// plan Task 3 uses it to decide whether the pre-flavour install's data belongs to the local flavour.
  public static func linkedHubURL(endpoint: PostgresEndpoint, binDir: String) throws -> String? {
    let lib = try LibPQ.load(binDir: binDir)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) application_name=b4app"
    let admin = try PostgresConnection(lib: lib, connectionString: base + " dbname=postgres")
    guard try !admin.execute("SELECT 1 FROM pg_database WHERE datname = $1", [endpoint.database]).rows.isEmpty
    else { return nil }
    let connection = try PostgresConnection(
      lib: lib, connectionString: base + " dbname=\(endpoint.database)")
    try connection.execute("BEGIN READ ONLY")
    defer { _ = try? connection.execute("ROLLBACK") }
    guard
      try connection.execute("SELECT to_regclass('\"hubLink\"')::text AS name").rows.first?.text("name")
        != nil
    else { return nil }
    return try connection.execute("SELECT \"url\" FROM \"hubLink\" WHERE \"id\" = 1").rows.first?.text("url")
  }

  public func hubLink() throws -> HubLink? {
    try read { try one($0, HubLink.self, "SELECT * FROM \"hubLink\" WHERE \"id\" = 1") }
  }

  /// Insert or replace the one link row. Replacing keeps the stored `cursor`, which only the pull moves
  /// (`applyRemote`, `setHubCursor`), so a push recording its outcome never rewinds a pull that committed
  /// meanwhile.
  public func saveHubLink(_ link: HubLink) throws {
    try saveHubLink(link, membershipChange: .preserveIfUnchanged)
  }

  /// Invalidate local comparison facts when the membership changes. Labels, token refreshes and
  /// cursor/status updates for the same native membership preserve those facts byte for byte.
  public func saveHubLink(_ link: HubLink, membershipChange: ProtocolMembershipChange) throws {
    do {
      try write(exclusive: true) { c -> Void in
        let previous = try one(c, HubLink.self, "SELECT * FROM \"hubLink\" WHERE \"id\" = 1 FOR UPDATE")
        try ProtocolActivationControl.mutateMembership(
          c, oldLink: previous, newLink: link, change: membershipChange)
        try persistHubLink(c, link: link, insertingOnly: false)
      }
    } catch { throw ProtocolActivationControl.failure }
  }

  /// Transaction borrower only. The owner already locked hubLink→control and owns rollback/COMMIT.
  /// Ordinary wrappers retain the exact original UPSERT; checked captured absence uses INSERT-only.
  @discardableResult
  func persistHubLink(_ c: PostgresConnection, link: HubLink, insertingOnly: Bool) throws -> Int {
    if insertingOnly {
      return try c.execute(
        """
        INSERT INTO "hubLink" ("id", "url", "deviceId", "deviceName", "tokenRef", "orgSlug", "username",
          "cursor", "lastPushAt", "lastError", "joinedAt")
        VALUES (1, $1, $2, $3, $4, $5, $6, $7::bigint, $8, $9, $10)
        """,
        [
          link.url, link.deviceId, link.deviceName, link.tokenRef, link.orgSlug, link.username,
          String(link.cursor), link.lastPushAt, link.lastError, link.joinedAt,
        ]
      ).affected
    }
    return try c.execute(
      """
      INSERT INTO "hubLink" ("id", "url", "deviceId", "deviceName", "tokenRef", "orgSlug", "username",
        "cursor", "lastPushAt", "lastError", "joinedAt")
      VALUES (1, $1, $2, $3, $4, $5, $6, $7::bigint, $8, $9, $10)
      ON CONFLICT ("id") DO UPDATE SET "url" = EXCLUDED."url", "deviceId" = EXCLUDED."deviceId",
        "deviceName" = EXCLUDED."deviceName", "tokenRef" = EXCLUDED."tokenRef",
        "orgSlug" = EXCLUDED."orgSlug", "username" = EXCLUDED."username",
        "lastPushAt" = EXCLUDED."lastPushAt", "lastError" = EXCLUDED."lastError",
        "joinedAt" = EXCLUDED."joinedAt"
      """,
      [
        link.url, link.deviceId, link.deviceName, link.tokenRef, link.orgSlug, link.username,
        String(link.cursor), link.lastPushAt, link.lastError, link.joinedAt,
      ]
    ).affected
  }

  /// The tables whose rows carry an owner: the device of a row's latest insert, on the hub
  /// (`owner_device_id`) and in the phone's mirror (`ownerDeviceId`).
  static let ownedTables = ["connections", "environments", "threads"]

  /// Re-announce this Mac's own rows as its current hub device, once per device (D-184): when the
  /// link's `ownedAs` is not its `deviceId`, append an insert for every row of `ownedTables` to the
  /// change log and record the device. The inserts carry the oldest clock there is, so on the hub and
  /// in the mirror they move the row's owner and its Mac-only columns and never win a clocked column
  /// (a phone's rename or pin stays). Returns the inserts appended; 0 with no link or nothing to do.
  ///
  /// With nothing in the log synced yet, it only records the device: the coming upload is the whole
  /// log as this device, every row's own insert included (the log is never pruned, and `clearHubLink`
  /// marks it unsynced for the next join).
  @discardableResult
  public func claimOwnedRows() throws -> Int {
    try write { c in
      guard
        let row = try c.execute(#"SELECT "deviceId", "ownedAs" FROM "hubLink" WHERE "id" = 1"#).rows.first,
        let device = row.text("deviceId")
      else { return 0 }
      if row.text("ownedAs") == device { return 0 }
      let pushed = try !c.execute(#"SELECT 1 FROM "changes" WHERE "synced" LIMIT 1"#).rows.isEmpty
      guard pushed else {
        try c.execute(#"UPDATE "hubLink" SET "ownedAs" = $1 WHERE "id" = 1"#, [device])
        return 0
      }
      let wall = String(Int(Date().timeIntervalSince1970 * 1000))
      let oldest = "000000000000-0000-" + device
      var appended = 0
      for table in Self.ownedTables {
        let quoted = Rows.quote(table)
        let inserted = try c.execute(
          """
          INSERT INTO "changes" ("deviceId", "wall", "table", "rowId", "op", "value", "hlc")
          SELECT $1, $2::bigint, $3, t."id", 'insert', to_jsonb(t), $4 FROM \(quoted) t
          RETURNING "seq"
          """, [device, wall, table, oldest])
        appended += inserted.rows.count
      }
      try c.execute(#"UPDATE "hubLink" SET "ownedAs" = $1 WHERE "id" = 1"#, [device])
      return appended
    }
  }

  /// Forget the hub: remove the link and mark the whole change log unsynced, so a later join (to this
  /// or another hub) uploads everything again.
  public func clearHubLink() throws {
    do {
      try write(exclusive: true) { c -> Void in
        let previous = try one(c, HubLink.self, "SELECT * FROM \"hubLink\" WHERE \"id\" = 1 FOR UPDATE")
        try ProtocolActivationControl.mutateMembership(
          c, oldLink: previous, newLink: nil, change: .replace)
        try c.execute("DELETE FROM \"hubLink\"")
        try c.execute("UPDATE \"changes\" SET \"synced\" = false WHERE \"synced\"")
      }
    } catch { throw ProtocolActivationControl.failure }
  }

  /// Record this device in `devices` (the hub's id and name), keeping an existing row's creation time.
  public func saveDevice(id: String, name: String) throws {
    try write { c in
      try c.execute(
        """
        INSERT INTO "devices" ("id", "name", "createdAt") VALUES ($1, $2, $3)
        ON CONFLICT ("id") DO UPDATE SET "name" = EXCLUDED."name"
        """, [id, name, Timestamp.now()])
    }
  }
}
