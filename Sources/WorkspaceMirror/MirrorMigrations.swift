import Foundation
import SQLite3
import WorkspaceProtocol

/// Opening a file at this build's schema, and replacing one it cannot open.
extension MirrorStore {
  /// Deletes the file at `path` with its `-wal` and `-shm` files and creates a fresh one at the current
  /// schema. Everything in the old file is lost, the link and the outbox included: the host calls this
  /// only after `needsRebuild(outboxEmpty: true)`.
  @discardableResult
  public static func rebuild(path: String) throws -> MirrorStore {
    for suffix in ["", "-wal", "-shm"] {
      let file = path + suffix
      guard FileManager.default.fileExists(atPath: file) else { continue }
      try FileManager.default.removeItem(atPath: file)
    }
    return try MirrorStore(path: path)
  }

  // MARK: - Schema

  /// Before anything else touches the file: refuses a schema newer than this build's, then sets the
  /// pragmas and runs the migrations after the file's `user_version`, all in one transaction. A
  /// migration that fails is rolled back, so the file is as it was.
  static func prepare(_ db: OpaquePointer) throws {
    let current = try integer(db, "PRAGMA user_version")
    guard current <= MirrorSchema.version else {
      throw MirrorStoreError.needsRebuild(outboxEmpty: outboxEmpty(db))
    }
    for pragma in MirrorSchema.pragmas { try execute(db, pragma) }
    guard current < MirrorSchema.version else { return }
    try execute(db, "BEGIN IMMEDIATE")
    do {
      for migration in MirrorSchema.migrations where migration.version > current {
        for statement in migration.statements { try execute(db, statement) }
      }
      try execute(db, "PRAGMA user_version = \(MirrorSchema.version)")
      try execute(db, "COMMIT")
    } catch {
      try? execute(db, "ROLLBACK")
      throw MirrorStoreError.needsRebuild(outboxEmpty: outboxEmpty(db))
    }
  }

  /// True when the file holds no unsent edits: no outbox table, or an empty one. Anything that cannot
  /// be read counts as not empty, so a rebuild is never offered over edits that might be there.
  private static func outboxEmpty(_ db: OpaquePointer) -> Bool {
    guard
      let tables = try? integer(
        db, #"SELECT count(*) FROM "sqlite_master" WHERE "type" = 'table' AND "name" = 'outbox'"#)
    else { return false }
    if tables == 0 { return true }
    return (try? integer(db, #"SELECT EXISTS (SELECT 1 FROM "outbox")"#)) == 0
  }

  private static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int {
    guard case .integer(let value)? = try rows(db, sql, []).first?.cells.first else {
      throw SQLiteError(code: SQLITE_ERROR, message: "\(sql) returned nothing")
    }
    return Int(value)
  }
}
