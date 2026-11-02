import Foundation
import WorkspaceProtocol

/// Versioned SQL files (`SQL/NNNN_name.sql`), applied in name order inside one transaction each and
/// recorded in `schemaMigrations` (decision D-041). The same files and the same code serve the local
/// cluster and, later, the hub.
public enum Migrator {
  public static let table = "schemaMigrations"

  /// The bundled migration files, sorted by name.
  public static func files() throws -> [(name: String, sql: String)] {
    guard let urls = Bundle.module.urls(forResourcesWithExtension: "sql", subdirectory: "SQL"), !urls.isEmpty
    else {
      throw WorkspaceError(.internalError, "No SQL migrations are bundled with WorkspaceStorage.")
    }
    return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
      ($0.deletingPathExtension().lastPathComponent, try String(contentsOf: $0, encoding: .utf8))
    }
  }

  /// Create the ledger `table` when it is missing; true when this call created it. The table is
  /// looked up first (`to_regclass`) rather than created `IF NOT EXISTS`, which makes the server send
  /// a NOTICE that libpq prints to standard error on every open.
  @discardableResult
  static func ensureLedger(_ connection: PostgresConnection, table: String) throws -> Bool {
    let quoted = Rows.quote(table)
    let found = try connection.execute("SELECT to_regclass($1)::text AS name", [quoted]).rows.first?.text(
      "name")
    guard found == nil else { return false }
    try connection.execute(
      "CREATE TABLE IF NOT EXISTS \(quoted) (\"name\" text PRIMARY KEY, \"appliedAt\" text NOT NULL)")
    return true
  }

  static func applied(_ connection: PostgresConnection) throws -> [String] {
    try ensureLedger(connection, table: table)
    return try connection.execute("SELECT \"name\" FROM \(Rows.quote(table)) ORDER BY \"name\"").rows
      .compactMap {
        $0.text("name")
      }
  }

  /// Apply every pending migration. Returns the names applied this time. A database that records a
  /// migration newer than every bundled one was written by a newer build: it is refused with
  /// `incompatible_version` before anything is applied.
  @discardableResult
  static func migrate(_ connection: PostgresConnection) throws -> [String] {
    let done = Set(try applied(connection))
    let files = try files()
    if let newest = files.last?.name, let future = done.filter({ $0 > newest }).min() {
      throw WorkspaceError(
        .incompatibleVersion,
        "The database was migrated by a newer version of Agent Workspace (\(future)); this version knows migrations up to \(newest). Update Agent Workspace."
      )
    }
    var appliedNow: [String] = []
    for file in files where !done.contains(file.name) {
      try connection.execute("BEGIN")
      do {
        try connection.execute(file.sql)
        try connection.execute(
          "INSERT INTO \(Rows.quote(table)) (\"name\", \"appliedAt\") VALUES ($1, $2)",
          [file.name, Timestamp.now()])
        try connection.execute("COMMIT")
      } catch {
        try? connection.execute("ROLLBACK")
        throw WorkspaceError(.internalError, "Migration \(file.name) failed: \(error)")
      }
      appliedNow.append(file.name)
    }
    return appliedNow
  }
}
