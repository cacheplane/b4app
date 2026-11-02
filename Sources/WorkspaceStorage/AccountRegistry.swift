import Foundation
import Security
import WorkspacePlatform
import WorkspaceProtocol

/// One account that has signed in on this Mac: a hub user and the database holding their workspace.
public struct AccountRow: Sendable, Equatable {
  public var id: String
  public var hubURL: String
  public var hubUserId: String
  public var deviceId: String
  public var database: String
  public var displayName: String
  public var orgName: String
  /// The secret-store reference of the current session's token; nil while signed out.
  public var tokenRef: String?
  public var lastSignedInAt: String?
  public var active: Bool

  public init(
    id: String, hubURL: String, hubUserId: String, deviceId: String, database: String,
    displayName: String, orgName: String, tokenRef: String? = nil, lastSignedInAt: String? = nil,
    active: Bool = false
  ) {
    self.id = id
    self.hubURL = hubURL
    self.hubUserId = hubUserId
    self.deviceId = deviceId
    self.database = database
    self.displayName = displayName
    self.orgName = orgName
    self.tokenRef = tokenRef
    self.lastSignedInAt = lastSignedInAt
    self.active = active
  }
}

/// The list of accounts that have signed in on this Mac, in the `registry` database of the
/// coordinator's cluster. Opened only by the coordinator. It migrates with its own list
/// (`SQL/registry/`, recorded in `registryMigrations`), never the workspace `Migrator`'s.
public final class AccountRegistry: Sendable {
  public static let table = "registryMigrations"

  private let pool: ConnectionPool

  /// Connect to a running cluster, create the registry database when it is missing, and migrate it.
  /// `databaseName` exists so tests can give each registry its own database.
  public init(endpoint: PostgresEndpoint, binDir: String, databaseName: String = "registry") throws {
    let lib = try LibPQ.load(binDir: binDir)
    let base = "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) application_name=b4app"
    let admin = try PostgresConnection(lib: lib, connectionString: base + " dbname=postgres")
    let exists = try admin.execute("SELECT 1 FROM pg_database WHERE datname = $1", [databaseName]).rows
    if exists.isEmpty { try admin.execute("CREATE DATABASE \(Rows.quote(databaseName))") }
    pool = try ConnectionPool(lib: lib, connectionString: base + " dbname=\(databaseName)", size: 2)
    try pool.withConnection { try Self.migrate($0) }
  }

  public func close() { pool.close() }

  /// The registry migrations applied so far, by name.
  public func appliedMigrations() throws -> [String] {
    try run { try Self.applied($0) }
  }

  // MARK: - Ids

  /// A new local account id: 16 lowercase hex characters from the system's secure random source.
  public static func newId() -> String {
    var bytes = [UInt8](repeating: 0, count: 8)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      var generator = SystemRandomNumberGenerator()
      bytes = (0..<8).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// The name of the account's own database.
  public static func databaseName(id: String) -> String { "workspace_" + id }

  // MARK: - Queries

  public func all() throws -> [AccountRow] {
    try run { c in
      try c.execute("SELECT \(Self.columns) FROM \"accounts\" ORDER BY \"id\"").rows.map(Self.account)
    }
  }

  public func active() throws -> AccountRow? {
    try run { c in
      try c.execute("SELECT \(Self.columns) FROM \"accounts\" WHERE \"active\"").rows.first.map(Self.account)
    }
  }

  public func find(hubURL: String, hubUserId: String) throws -> AccountRow? {
    try run { c in
      try c.execute(
        "SELECT \(Self.columns) FROM \"accounts\" WHERE \"hub_url\" = $1 AND \"hub_user_id\" = $2",
        [hubURL, hubUserId]
      ).rows.first.map(Self.account)
    }
  }

  // MARK: - Writes

  /// Add an account. `(hubURL, hubUserId)` and `database` are unique, and at most one row is active.
  public func insert(_ row: AccountRow) throws {
    try run { c in
      try c.execute(
        """
        INSERT INTO "accounts" ("id", "hub_url", "hub_user_id", "device_id", "database", "display_name",
          "org_name", "token_ref", "last_signed_in_at", "active")
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::boolean)
        """,
        [
          row.id, row.hubURL, row.hubUserId, row.deviceId, row.database, row.displayName, row.orgName,
          row.tokenRef, row.lastSignedInAt, row.active ? "true" : "false",
        ])
    }
  }

  /// Make `id` the active account with `tokenRef`, stamp its sign-in time, and deactivate every other
  /// account, all in one transaction.
  public func activate(id: String, tokenRef: String) throws {
    try run { c in
      try c.execute("BEGIN")
      do {
        // Deactivate first: the partial unique index allows one active row at a time.
        try c.execute("UPDATE \"accounts\" SET \"active\" = false WHERE \"active\" AND \"id\" <> $1", [id])
        let updated = try c.execute(
          "UPDATE \"accounts\" SET \"active\" = true, \"token_ref\" = $2, \"last_signed_in_at\" = $3 WHERE \"id\" = $1",
          [id, tokenRef, Timestamp.now()])
        guard updated.affected == 1 else { throw WorkspaceError(.notFound, "No account \(id).") }
        try c.execute("COMMIT")
      } catch {
        try? c.execute("ROLLBACK")
        throw error
      }
    }
  }

  /// Clear the account's token reference and deactivate it. The row stays registered.
  public func signOut(id: String) throws {
    try run { c in
      let updated = try c.execute(
        "UPDATE \"accounts\" SET \"token_ref\" = NULL, \"active\" = false WHERE \"id\" = $1", [id])
      guard updated.affected == 1 else { throw WorkspaceError(.notFound, "No account \(id).") }
    }
  }

  public func remove(id: String) throws {
    try run { try $0.execute("DELETE FROM \"accounts\" WHERE \"id\" = $1", [id]) }
  }

  // MARK: - Plumbing

  private static let columns =
    "\"id\", \"hub_url\", \"hub_user_id\", \"device_id\", \"database\", \"display_name\", \"org_name\", \"token_ref\", \"last_signed_in_at\", \"active\""

  private static func account(_ row: Row) throws -> AccountRow {
    func required(_ column: String) throws -> String {
      guard let value = row.text(column) else {
        throw WorkspaceError(.internalError, "The registry row has no \(column).")
      }
      return value
    }
    return AccountRow(
      id: try required("id"), hubURL: try required("hub_url"), hubUserId: try required("hub_user_id"),
      deviceId: try required("device_id"), database: try required("database"),
      displayName: try required("display_name"), orgName: try required("org_name"),
      tokenRef: row.text("token_ref"), lastSignedInAt: row.text("last_signed_in_at"),
      active: try required("active") == "t")
  }

  /// Run `body` on a pooled connection, reporting a constraint violation as `protocol_invalid` and any
  /// other database failure as `internal`, as `WorkspaceDatabase` does.
  private func run<T>(_ body: (PostgresConnection) throws -> T) throws -> T {
    do { return try pool.withConnection(body) } catch let error as PostgresError {
      throw WorkspaceError(
        error.isConstraintViolation ? .protocolInvalid : .internalError, "PostgreSQL: \(error.description)")
    }
  }

  // MARK: - Migrations

  private static func files() throws -> [(name: String, sql: String)] {
    guard
      let urls = Bundle.module.urls(forResourcesWithExtension: "sql", subdirectory: "SQL/registry"),
      !urls.isEmpty
    else {
      throw WorkspaceError(.internalError, "No registry migrations are bundled with WorkspaceStorage.")
    }
    return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
      ($0.deletingPathExtension().lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
    }
  }

  private static func applied(_ connection: PostgresConnection) throws -> [String] {
    try connection.execute(
      "CREATE TABLE IF NOT EXISTS \(Rows.quote(table)) (\"name\" text PRIMARY KEY, \"appliedAt\" text NOT NULL)"
    )
    return try connection.execute("SELECT \"name\" FROM \(Rows.quote(table)) ORDER BY \"name\"").rows
      .compactMap { $0.text("name") }
  }

  private static func migrate(_ connection: PostgresConnection) throws {
    let done = Set(try applied(connection))
    for file in try files() where !done.contains(file.name) {
      try connection.execute("BEGIN")
      do {
        try connection.execute(file.sql)
        try connection.execute(
          "INSERT INTO \(Rows.quote(table)) (\"name\", \"appliedAt\") VALUES ($1, $2)",
          [file.name, Timestamp.now()])
        try connection.execute("COMMIT")
      } catch {
        try? connection.execute("ROLLBACK")
        throw WorkspaceError(.internalError, "Registry migration \(file.name) failed: \(error)")
      }
    }
  }
}
