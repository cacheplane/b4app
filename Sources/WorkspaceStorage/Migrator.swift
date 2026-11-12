import Foundation
import WorkspaceProtocol

/// Bytes are read once. The guarded migration hashes and decodes this same immutable value.
struct StoreMigrationResource {
  let name: String
  let bytes: Data

  func sql() throws -> String {
    guard let value = String(data: bytes, encoding: .utf8) else {
      throw WorkspaceError(.internalError, "A bundled SQL migration is not UTF-8.")
    }
    return value
  }
}

/// Versioned SQL files (`SQL/NNNN_name.sql`), applied in name order inside one transaction each and
/// recorded in `schemaMigrations` (decision D-041).
public enum Migrator {
  public static let table = "schemaMigrations"
  // A database-scoped SESSION lock, separate from WorkspaceDatabase.remoteApplyLockKey. It covers
  // ledger admission and the whole file chain, while each file keeps its own transaction.
  static let migrationLockKey: Int64 = 0x6234_6d69_6772_6174

  private static func resources() throws -> [StoreMigrationResource] {
    guard let urls = StorageResources.bundle.urls(forResourcesWithExtension: "sql", subdirectory: "SQL"),
      !urls.isEmpty
    else {
      throw WorkspaceError(.internalError, "No SQL migrations are bundled with WorkspaceStorage.")
    }
    return try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
      StoreMigrationResource(
        name: $0.deletingPathExtension().lastPathComponent, bytes: try Data(contentsOf: $0))
    }
  }

  /// The bundled migration files, sorted by name. Keep the public labelled tuple API unchanged.
  public static func files() throws -> [(name: String, sql: String)] {
    try resources().map { (name: $0.name, sql: try $0.sql()) }
  }

  /// Shared with the registry; its existing independent ledger behavior is unchanged.
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
      .compactMap { $0.text("name") }
  }

  /// Migration-only public admission. This runs under the session lock but outside a transaction;
  /// none of these queries can pin the later pending11 Repeatable Read snapshot.
  private static func migrationLedger(_ connection: PostgresConnection) throws -> [String] {
    do {
      guard try connection.execute("SELECT current_schema() AS name").rows.first?.text("name") == "public"
      else {
        throw EnvironmentHistoryMigrationGuard.failure()
      }
      let publicOID = try connection.execute(
        "SELECT pg_catalog.to_regclass('public.\"schemaMigrations\"')::oid::text AS oid"
      ).rows.first?.text("oid")
      let resolvedOID = try connection.execute(
        "SELECT pg_catalog.to_regclass('\"schemaMigrations\"')::oid::text AS oid"
      ).rows.first?.text("oid")
      guard publicOID == resolvedOID else { throw EnvironmentHistoryMigrationGuard.failure() }
      if publicOID == nil {
        try connection.execute(
          "CREATE TABLE public.\"schemaMigrations\" (\"name\" text PRIMARY KEY, \"appliedAt\" text NOT NULL)")
      }
      let valid = try connection.execute(
        """
        SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
          WHERE c.oid = 'public."schemaMigrations"'::regclass AND c.relkind = 'r'
            AND c.relpersistence = 'p' AND c.relnamespace = 'public'::regnamespace
            AND NOT pg_catalog.row_security_active(c.oid)
            AND pg_catalog.to_regclass('"schemaMigrations"') = c.oid)
          AND (SELECT count(*) FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = 'public."schemaMigrations"'::regclass AND a.attnum > 0 AND NOT a.attisdropped
              AND a.attname IN ('name','appliedAt') AND a.atttypid = 'text'::regtype AND a.attnotnull) = 2
          AND EXISTS (SELECT 1 FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_attribute a ON a.attrelid=i.indrelid AND a.attname='name' AND NOT a.attisdropped
            JOIN pg_catalog.pg_constraint k ON k.conindid=i.indexrelid AND k.contype='p' AND k.convalidated
            WHERE i.indrelid='public."schemaMigrations"'::regclass AND i.indisprimary AND i.indisunique
              AND i.indisvalid AND i.indisready AND i.indnkeyatts=1 AND i.indkey[0]=a.attnum) AS valid
        """
      ).rows.first?.text("valid")
      guard valid == "t" else { throw EnvironmentHistoryMigrationGuard.failure() }
      return try connection.execute("SELECT \"name\" FROM public.\"schemaMigrations\" ORDER BY \"name\"").rows
        .map { row in
          guard let name = row.text("name") else { throw EnvironmentHistoryMigrationGuard.failure() }
          return name
        }

    } catch {
      throw EnvironmentHistoryMigrationGuard.failure()
    }
  }

  private static func unlock(_ connection: PostgresConnection) throws {
    do {
      let rows = try connection.execute(
        "SELECT pg_catalog.pg_advisory_unlock($1::bigint) AS unlocked", [String(migrationLockKey)]
      ).rows
      guard rows.count == 1, rows[0].text("unlocked") == "t" else {
        throw EnvironmentHistoryMigrationGuard.failure()
      }
    } catch {
      throw EnvironmentHistoryMigrationGuard.failure()
    }
  }

  /// The constructor supplies a fresh autocommit connection. Errors close its private pool; this
  /// does not support migration inside a caller-owned transaction or reuse after failed cleanup.
  @discardableResult
  static func migrate(_ connection: PostgresConnection) throws -> [String] {
    var locked = false
    var unlockAttempted = false
    do {
      do {
        try connection.execute("SELECT pg_catalog.pg_advisory_lock($1::bigint)", [String(migrationLockKey)])
        locked = true
      } catch {
        throw EnvironmentHistoryMigrationGuard.failure()
      }
      let done = Set(try migrationLedger(connection))
      let files: [StoreMigrationResource]
      do { files = try resources() } catch { throw EnvironmentHistoryMigrationGuard.failure() }
      if let newest = files.last?.name, let future = done.filter({ $0 > newest }).min() {
        throw WorkspaceError(
          .incompatibleVersion,
          "The database was migrated by a newer version of Agent Workspace (\(future)); this version knows migrations up to \(newest). Update Agent Workspace."
        )
      }
      var appliedNow: [String] = []
      for file in files where !done.contains(file.name) {
        if file.name == EnvironmentHistoryMigrationGuard.name {
          try EnvironmentHistoryMigrationGuard.apply(connection, file: file)
        } else {
          // Preserve ordinary per-file boundaries and error behavior for all other migrations.
          try connection.execute("BEGIN")
          do {
            try connection.execute(file.sql())
            try connection.execute(
              "INSERT INTO public.\"schemaMigrations\" (\"name\", \"appliedAt\") VALUES ($1, $2)",
              [file.name, Timestamp.now()])
            try connection.execute("COMMIT")
          } catch {
            try? connection.execute("ROLLBACK")
            throw WorkspaceError(.internalError, "Migration \(file.name) failed: \(error)")
          }
        }
        appliedNow.append(file.name)
      }
      unlockAttempted = true
      try unlock(connection)
      return appliedNow
    } catch {
      let primary = error
      if locked && !unlockAttempted {
        unlockAttempted = true
        // Never replace the primary with an unlock/aborted-transaction error. The initializer's
        // existing catch closes this unreturned private pool, even if the connection is healthy.
        try? unlock(connection)
      }
      throw primary
    }
  }
}
