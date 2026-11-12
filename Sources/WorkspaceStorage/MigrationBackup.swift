import Darwin
import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// Internal, per-invocation observations for deterministic backup boundary tests. No row, path or
/// authority is carried, and normal opens install no observer.
enum MigrationBackupStage: Sendable, Equatable {
  case locked, contentsWritten, fileSynchronized, renamed, directorySynchronized, willMigrate
}

extension WorkspaceDatabase {
  /// The admission path shared by normal initialization and private boundary tests.
  static func migrateWithBackup(
    _ c: PostgresConnection, endpoint: PostgresEndpoint, backupDirectory: String?,
    observe: (@Sendable (MigrationBackupStage) throws -> Void)? = nil
  ) throws {
    try Migrator.withMigrationLock(c) {
      // Canonical inspection is noncreating and remains outside any transaction. Only then fence
      // normal local/remote writers, in migration-key -> remoteApply-key order on this connection.
      let plan = try Migrator.prepare(c)
      var locked = false
      var unlockAttempted = false
      do {
        do {
          try c.execute("SELECT pg_catalog.pg_advisory_lock($1::bigint)", [String(Self.remoteApplyLockKey)])
          locked = true
        } catch { throw EnvironmentHistoryMigrationGuard.failure() }
        // This observation means BOTH locks are held, before any backup/material work.
        try observe?(.locked)
        if plan.hasPending {
          try Self.backupBeforeMigration(c, endpoint: endpoint, directory: backupDirectory, observe: observe)
        }
        // backupBeforeMigration has committed its RR transaction. In particular it has not pinned
        // the snapshot of pending11's separate transaction before that transaction's first six AXs.
        try observe?(.willMigrate)
        try Migrator.applyPrepared(c, plan: plan)
        unlockAttempted = true
        try unlockMigrationWrites(c)
      } catch {
        let primary = error
        if locked && !unlockAttempted {
          unlockAttempted = true
          try? unlockMigrationWrites(c)
        }
        throw primary
      }
    }
  }

  private static func unlockMigrationWrites(_ c: PostgresConnection) throws {
    do {
      let rows = try c.execute(
        "SELECT pg_catalog.pg_advisory_unlock($1::bigint) AS unlocked", [String(Self.remoteApplyLockKey)]
      ).rows
      guard rows.count == 1, rows[0].text("unlocked") == "t" else {
        throw EnvironmentHistoryMigrationGuard.failure()
      }
    } catch { throw EnvironmentHistoryMigrationGuard.failure() }
  }

  /// A raw, version-aware snapshot for migration admission. This uses the already-locked migration
  /// connection, not export(), which acquires another pool lease and assumes the current schema.
  /// Snapshot format/inventory is shared with on-demand export and restore. Scope quiescence and
  /// the already-held exclusive migration lock remain the caller's responsibility.
  static func backupBeforeMigration(
    _ c: PostgresConnection, endpoint: PostgresEndpoint, directory: String?,
    observe: (@Sendable (MigrationBackupStage) throws -> Void)? = nil
  ) throws {
    do {
      try c.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
      do {
        let present = Set(
          try c.execute(
            "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public'"
          ).rows.compactMap { $0.text("tablename") })
        // A new empty database has no old data to protect. Do not create an archive or ledger yet.
        if !present.isEmpty {
          // Catalog names above contain no authority. Protect before traversing any old rows or
          // creating the archive; a server that cannot establish privacy refuses before material.
          try ProtocolGrantProtection.establish(c)
          let schema = try WorkspaceArchive.captureSchema(c, present: present)
          let path = try migrationBackupDirectory(endpoint: endpoint, explicit: directory)
          try writeMigrationSnapshot(c, directory: path, schema: schema, observe: observe)
          try ProtocolGrantProtection.verify(c)
        }
        try c.execute("COMMIT")
      } catch {
        try? c.execute("ROLLBACK")
        throw error
      }
    } catch {
      // Never return PostgreSQL DETAIL, SQL or a filesystem cause here: an old private row may
      // contain authority. Failure is admission failure, before any ledger or schema mutation.
      throw WorkspaceError(
        .internalError,
        "The required pre-migration backup could not be saved. The existing database was not migrated."
      )
    }
  }

  private static func migrationBackupDirectory(
    endpoint: PostgresEndpoint, explicit: String?
  ) throws -> String {
    if let explicit {
      guard (explicit as NSString).isAbsolutePath,
        URL(fileURLWithPath: explicit).standardizedFileURL.path != "/"
      else { throw SnapshotFailure.unavailable }
      return explicit
    }
    // An external socket does not identify a protected backup location. Its caller must supply one.
    guard let data = endpoint.dataDir, (data as NSString).isAbsolutePath,
      let database = endpoint.database.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))),
      !database.isEmpty, database != ".", database != ".."
    else { throw SnapshotFailure.unavailable }
    let backups = URL(fileURLWithPath: data).deletingLastPathComponent()
      .appendingPathComponent("backups")
    return backups.appendingPathComponent(database).path
  }

  private enum SnapshotFailure: Error { case unavailable }

  private static func writeMigrationSnapshot(
    _ c: PostgresConnection, directory: String, schema: WorkspaceArchive.Schema,
    observe: (@Sendable (MigrationBackupStage) throws -> Void)?
  ) throws {
    let destination = (directory as NSString).appendingPathComponent("\(UUID().uuidString).jsonl")
    try ArchivePublication.write(
      to: destination, privateDirectory: true,
      observe: { stage in
        // The existing qualified B boundaries stay in their actual durability order.
        switch stage {
        case .contentsWritten: try observe?(.contentsWritten)
        case .fileSynchronized: try observe?(.fileSynchronized)
        case .renamed: try observe?(.renamed)
        case .directorySynchronized: try observe?(.directorySynchronized)
        }
      }
    ) { handle in
      try WorkspaceArchive.write(c, schema: schema, purpose: "preMigration", handle: handle)
    }
  }
}
