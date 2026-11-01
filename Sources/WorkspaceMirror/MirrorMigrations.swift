import Foundation
import SQLite3
import WorkspaceProtocol
import WorkspaceSync

/// Opening a file at this build's schema, and replacing one it cannot open.
extension MirrorStore {
  /// Deletes the file at `path` with its `-wal` and `-shm` files and creates a fresh one at the current
  /// schema. The rows, clocks, and outbox are lost (the host calls this only after
  /// `needsRebuild(outboxEmpty: true)`), but the link and the outbox `deviceSeq` high-water mark are
  /// carried into the new file together, in one transaction, so the phone keeps its device and
  /// restores from the snapshot without reusing a sequence number the hub has already accepted (the
  /// hub would drop a reused one as a duplicate). The old file is read best-effort first: the link
  /// when it decodes, and the counter as the greater of `syncState.lastDeviceSeq` and the outbox's
  /// greatest `deviceSeq` (a missing column or table counts 0). When the counter cannot be read, the
  /// link is dropped too and the phone joins again under a new device id.
  @discardableResult
  public static func rebuild(path: String) throws -> MirrorStore {
    let carried = carriedState(path: path)
    for suffix in ["", "-wal", "-shm"] {
      let file = path + suffix
      guard FileManager.default.fileExists(atPath: file) else { continue }
      try FileManager.default.removeItem(atPath: file)
    }
    let store = try MirrorStore(path: path)
    try store.restore(link: carried.link, lastDeviceSeq: carried.lastDeviceSeq)
    return store
  }

  /// What a rebuild keeps from the old file.
  struct CarriedState {
    var link: MirrorLink?
    var lastDeviceSeq: Int
  }

  /// The old file's link and sequence counter, or nothing when the counter cannot be read.
  static func carriedState(path: String) -> CarriedState {
    let nothing = CarriedState(link: nil, lastDeviceSeq: 0)
    guard path != ":memory:", FileManager.default.fileExists(atPath: path) else { return nothing }
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
      if let handle { sqlite3_close_v2(handle) }
      return nothing
    }
    defer { sqlite3_close_v2(handle) }
    guard let counter = sequenceHighWater(handle) else { return nothing }
    return CarriedState(link: storedLink(handle), lastDeviceSeq: counter)
  }

  /// The greatest `deviceSeq` the file ever issued; nil when a counter that exists cannot be read.
  private static func sequenceHighWater(_ db: OpaquePointer) -> Int? {
    do {
      var high = 0
      if try hasColumn(db, "syncState", "lastDeviceSeq") {
        switch try rows(db, #"SELECT "lastDeviceSeq" FROM "syncState" WHERE "id" = 1"#, []).first?.cells.first
        {
        case .integer(let value)?: high = max(high, Int(value))
        case nil, .null?: break
        default: return nil
        }
      }
      if try hasTable(db, "outbox") {
        guard try hasColumn(db, "outbox", "deviceSeq") else { return nil }
        switch try rows(db, #"SELECT max("deviceSeq") FROM "outbox""#, []).first?.cells.first {
        case .integer(let value)?: high = max(high, Int(value))
        case nil, .null?: break
        default: return nil
        }
      }
      return high
    } catch {
      return nil
    }
  }

  /// The old file's link when it reads and decodes, else nil.
  private static func storedLink(_ db: OpaquePointer) -> MirrorLink? {
    guard (try? hasColumn(db, "syncState", "link")) == true,
      case .text(let text)? = try? rows(db, #"SELECT "link" FROM "syncState" WHERE "id" = 1"#, []).first?
        .cells.first
    else { return nil }
    return try? JSONCoding.decoder.decode(MirrorLink.self, from: Data(text.utf8))
  }

  private static func hasTable(_ db: OpaquePointer, _ table: String) throws -> Bool {
    try integer(db, #"SELECT count(*) FROM "sqlite_master" WHERE "type" = 'table' AND "name" = '\#(table)'"#)
      > 0
  }

  private static func hasColumn(_ db: OpaquePointer, _ table: String, _ column: String) throws -> Bool {
    guard
      case .integer(let count)? = try rows(
        db, #"SELECT count(*) FROM pragma_table_info(?) WHERE "name" = ?"#, [.text(table), .text(column)]
      ).first?.cells.first
    else { return false }
    return count > 0
  }

  /// Writes a rebuilt file's carried link and counter in one transaction.
  private func restore(link: MirrorLink?, lastDeviceSeq: Int) throws {
    let text = try link.map { String(decoding: try JSONCoding.encoder.encode($0), as: UTF8.self) }
    try locked {
      try transaction {
        try run(
          #"UPDATE "syncState" SET "link" = ?, "lastDeviceSeq" = ? WHERE "id" = 1"#,
          [text.map(Bind.text) ?? .null, .integer(Int64(lastDeviceSeq))])
      }
      clock.deviceId = link?.deviceId ?? "local"
    }
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
