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

  /// Canonical inspection only. It never creates a missing ledger and may run in a preflight or
  /// backup read-only transaction. Such an inspection is not permission to migrate without a lock.
  static func recorded(_ connection: PostgresConnection) throws -> [String] {
    try migrationLedger(connection)
  }

  struct Plan {
    let files: [StoreMigrationResource]
    let done: Set<String>
    var hasPending: Bool { files.contains { !done.contains($0.name) } }
  }

  /// Load once for actual application, so the guarded migration hashes/decodes its same Data.
  /// Call under withMigrationLock for migration; preflight is only a noncreating advisory read.
  static func prepare(_ connection: PostgresConnection) throws -> Plan {
    let names = try recorded(connection)
    let done = Set(names)
    let files: [StoreMigrationResource]
    do { files = try resources() } catch { throw EnvironmentHistoryMigrationGuard.failure() }
    if let newest = files.last?.name, let future = done.filter({ $0 > newest }).min() {
      throw WorkspaceError(
        .incompatibleVersion,
        "The database was migrated by a newer version of Agent Workspace (\(future)); this version knows migrations up to \(newest). Update Agent Workspace."
      )
    }
    // Admission applies to current reopens too: an extra old draft name cannot turn a
    // noncanonical ledger into a no-pending path that bypasses closed archive admission.
    // Keep the higher-future-version error above, before this fixed privacy-safe refusal.
    guard names == Array(files.prefix(names.count).map(\.name)) else {
      throw EnvironmentHistoryMigrationGuard.failure()
    }
    // Unpublished14 changed shape before release. Its name alone cannot admit an older draft,
    // even on a no-pending reopen. This is catalog-only and never reads protocol row material.
    if done.contains("0014_agent_protocol") { try validateProtocolGenerationSchema(connection) }
    return Plan(files: files, done: done)
  }

  /// The authoritative changed14 tables only; pre14 preparation does not touch these catalogs.
  /// Kept independent of archive capture to avoid prepare/capture recursion or row traversal.
  static func validateProtocolGenerationSchema(_ connection: PostgresConnection) throws {
    struct Column {
      let name: String
      let kind: String
      var nullable = false
    }
    let tables: [(name: String, columns: [Column], primary: [String])] = [
      (
        "protocolSubscriptions",
        [
          Column(name: "threadId", kind: "text"), Column(name: "connectionId", kind: "text"),
          Column(name: "nativeThreadId", kind: "text"),
          Column(name: "generation", kind: "text", nullable: true),
          Column(name: "localObservationEpoch", kind: "text", nullable: true),
          Column(name: "channels", kind: "jsonb"), Column(name: "namespaces", kind: "jsonb"),
          Column(name: "appliedEventId", kind: "text", nullable: true),
          Column(name: "appliedSeq", kind: "int8", nullable: true),
          Column(name: "coverage", kind: "jsonb"), Column(name: "updatedAt", kind: "text"),
        ], ["threadId"]
      ),
      (
        "protocolRunSegments",
        [
          Column(name: "connectionId", kind: "text"), Column(name: "threadId", kind: "text"),
          Column(name: "identityEpochKind", kind: "text"), Column(name: "identityEpochId", kind: "text"),
          Column(name: "namespace", kind: "jsonb"), Column(name: "nativeRunId", kind: "text"),
          Column(name: "rootRunId", kind: "text", nullable: true),
          Column(name: "predecessorRunId", kind: "text", nullable: true),
          Column(name: "localTurnId", kind: "text", nullable: true),
          Column(name: "submissionId", kind: "text", nullable: true),
          Column(name: "facts", kind: "jsonb"), Column(name: "updatedAt", kind: "text"),
        ], ["connectionId", "threadId", "identityEpochKind", "identityEpochId", "namespace", "nativeRunId"]
      ),
    ]
    do {
      for table in tables {
        let qualified = "public." + Rows.quote(table.name)
        let identity = try connection.execute(
          """
          SELECT c.oid::text AS oid FROM pg_catalog.pg_class c
          WHERE c.oid=pg_catalog.to_regclass($1) AND c.oid=pg_catalog.to_regclass($2)
            AND c.relnamespace='public'::regnamespace AND c.relkind='r' AND c.relpersistence='p'
            AND NOT pg_catalog.row_security_active(c.oid)
          """, [qualified, Rows.quote(table.name)]
        ).rows
        guard identity.count == 1, let oid = identity[0].text("oid") else {
          throw protocolGenerationSchemaFailure()
        }
        let columns = try connection.execute(
          """
          SELECT a.attname AS name,a.attnotnull AS required,a.atttypmod::text AS typmod,
            CASE a.atttypid WHEN 'pg_catalog.text'::regtype THEN 'text'
              WHEN 'pg_catalog.jsonb'::regtype THEN 'jsonb'
              WHEN 'pg_catalog.int8'::regtype THEN 'int8' ELSE '' END AS kind
          FROM pg_catalog.pg_attribute a WHERE a.attrelid=$1::oid
            AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
          """, [oid]
        ).rows
        guard columns.count == table.columns.count else { throw protocolGenerationSchemaFailure() }
        for (actual, expected) in zip(columns, table.columns) {
          guard actual.text("name") == expected.name, actual.text("kind") == expected.kind,
            actual.text("typmod") == "-1", actual.text("required") == (expected.nullable ? "f" : "t")
          else { throw protocolGenerationSchemaFailure() }
        }
        let primary = try connection.execute(
          """
          SELECT a.attname AS name FROM pg_catalog.pg_constraint k
          JOIN pg_catalog.pg_index i ON i.indexrelid=k.conindid
          CROSS JOIN LATERAL unnest(k.conkey) WITH ORDINALITY AS key(attnum,position)
          JOIN pg_catalog.pg_attribute a ON a.attrelid=k.conrelid AND a.attnum=key.attnum
          WHERE k.conrelid=$1::oid AND k.contype='p' AND k.convalidated
            AND i.indisprimary AND i.indisunique AND i.indisvalid AND i.indisready
            AND i.indnkeyatts=$2::integer ORDER BY key.position
          """, [oid, String(table.primary.count)]
        ).rows.compactMap { $0.text("name") }
        guard primary == table.primary else { throw protocolGenerationSchemaFailure() }
      }
    } catch { throw protocolGenerationSchemaFailure() }
  }

  private static func protocolGenerationSchemaFailure() -> WorkspaceError {
    WorkspaceError(.incompatibleVersion, "The private protocol schema is incompatible with this build.")
  }

  static func pending(_ connection: PostgresConnection) throws -> Bool {
    try prepare(connection).hasPending
  }

  /// Canonical admission never writes unless creation is explicitly requested after backup.
  /// Migration preparation is autocommit; a read-only preflight/capture may inspect without creating.
  private static func migrationLedger(
    _ connection: PostgresConnection, createIfMissing: Bool = false
  ) throws -> [String] {
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
        guard createIfMissing else { return [] }
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

  /// One session scope shared by direct migration and constructor backup admission. The caller
  /// supplies an autocommit connection. It must not wrap this scope in an outer transaction.
  static func withMigrationLock<T>(
    _ connection: PostgresConnection, _ body: () throws -> T
  ) throws -> T {
    var locked = false
    var unlockAttempted = false
    do {
      do {
        try connection.execute("SELECT pg_catalog.pg_advisory_lock($1::bigint)", [String(migrationLockKey)])
        locked = true
      } catch { throw EnvironmentHistoryMigrationGuard.failure() }
      let value = try body()
      unlockAttempted = true
      try unlock(connection)
      return value
    } catch {
      let primary = error
      if locked && !unlockAttempted {
        unlockAttempted = true
        try? unlock(connection)
      }
      // The constructor disposes its failed unreturned private pool. A direct raw caller owns
      // its connection and has no automatic backup/disposal guarantee after failed cleanup.
      throw primary
    }
  }

  @discardableResult
  static func migrate(_ connection: PostgresConnection) throws -> [String] {
    try withMigrationLock(connection) {
      try applyPrepared(connection, plan: prepare(connection))
    }
  }

  /// Only the two same-connection entrypoints above and migrateWithBackup call this while holding
  /// the migration session lock. Backup has COMMITTED before this function may create a ledger.
  @discardableResult
  static func applyPrepared(_ connection: PostgresConnection, plan: Plan) throws -> [String] {
    guard Set(try migrationLedger(connection, createIfMissing: true)) == plan.done else {
      throw EnvironmentHistoryMigrationGuard.failure()
    }
    var appliedNow: [String] = []
    for file in plan.files where !plan.done.contains(file.name) {
      if file.name == EnvironmentHistoryMigrationGuard.name {
        try EnvironmentHistoryMigrationGuard.apply(connection, file: file)
      } else {
        // Preserve ordinary per-file boundaries and error behavior for all other migrations.
        try connection.execute("BEGIN")
        do {
          try connection.execute(file.sql())
          if file.name == "0014_agent_protocol" { try validateProtocolGenerationSchema(connection) }
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
    return appliedNow
  }
}
