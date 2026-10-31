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
