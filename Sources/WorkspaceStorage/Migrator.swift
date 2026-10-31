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

  static func applied(_ connection: PostgresConnection) throws -> [String] {
    try connection.execute(
      "CREATE TABLE IF NOT EXISTS \(Rows.quote(table)) (\"name\" text PRIMARY KEY, \"appliedAt\" text NOT NULL)"
    )
    return try connection.execute("SELECT \"name\" FROM \(Rows.quote(table)) ORDER BY \"name\"").rows
      .compactMap {
        $0.text("name")
      }
  }

  /// Apply every pending migration. Returns the names applied this time.
  @discardableResult
  static func migrate(_ connection: PostgresConnection) throws -> [String] {
    let done = Set(try applied(connection))
    var appliedNow: [String] = []
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
        throw WorkspaceError(.internalError, "Migration \(file.name) failed: \(error)")
      }
      appliedNow.append(file.name)
    }
    return appliedNow
  }
}
