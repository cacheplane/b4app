import Foundation
import SQLite3
import WorkspaceProtocol

/// One-time import of the SQLite store of versions before 0.2 (GRDB schema v1 to v3) into the
/// PostgreSQL store (decision D-041). Column names are identical on both sides, so every table is
/// copied `SELECT *` to `INSERT`, text to text: integers of boolean columns become `true`/`false`,
/// other numbers become their decimal text, JSON text columns go in as text and PostgreSQL casts them
/// to `jsonb`, NULL stays NULL. Columns the PostgreSQL table does not have are skipped.
public enum SQLiteImporter {
  public struct Summary: Sendable, Equatable {
    /// Rows inserted per table; empty when nothing was imported.
    public var rows: [String: Int]
    public init(rows: [String: Int] = [:]) { self.rows = rows }
    public var isEmpty: Bool { rows.isEmpty }
    public var total: Int { rows.values.reduce(0, +) }
  }

  /// Tables in dependency order (foreign keys point at earlier tables).
  public static let tables = [
    "localServers", "connections", "threads", "turns", "displayItems", "runtimeRequests", "drafts",
  ]

  /// SQLite stores these as 0/1 integers; PostgreSQL wants booleans.
  static let booleanColumns: Set<String> = ["enabled", "pinned", "archived", "ownershipVerified"]

  /// Copy every table of the SQLite file at `path` into `database`. Idempotent: when the PostgreSQL
  /// `connections` table already has rows the import is skipped and the summary is empty.
  public static func importFile(at path: String, into database: WorkspaceDatabase) throws -> Summary {
    guard try database.rowCount(table: "connections") == 0 else { return Summary() }
    let source = try SQLiteFile(path: path)
    defer { source.close() }
    var summary = Summary()
    var batches: [(table: String, columns: [String], rows: [[String?]])] = []
    for table in tables {
      guard try source.hasTable(table) else { continue }
      let target = Set(try database.tableColumns(table))
      let read = try source.rows(of: table)
      let kept = read.columns.enumerated().filter { target.contains($0.element) }
      let columns = kept.map(\.element)
      let rows = read.rows.map { row in kept.map { row[$0.offset] } }
      batches.append((table, columns, rows))
      summary.rows[table] = rows.count
    }
    // All or nothing: a failure in any table leaves the store empty and the file in place.
    try database.insertRaw(batches: batches)
    return summary
  }

  /// Rename `path` (and its `-wal` and `-shm` siblings) to `.imported` names. Deletes nothing; a
  /// name already taken gets a timestamp suffix instead.
  public static func retire(fileAt path: String) throws {
    let fm = FileManager.default
    for candidate in [path, path + "-wal", path + "-shm"] where fm.fileExists(atPath: candidate) {
      var destination = candidate + ".imported"
      if fm.fileExists(atPath: destination) {
        destination += "-" + String(Int(Date().timeIntervalSince1970))
      }
      try fm.moveItem(atPath: candidate, toPath: destination)
    }
  }

  // MARK: - SQLite access (system library, read-only)

  struct TableRows {
    var columns: [String]
    var rows: [[String?]]
  }

  final class SQLiteFile {
    private var handle: OpaquePointer?

    init(path: String) throws {
      var db: OpaquePointer?
      // Read-write (never create): a WAL-mode file needs its -shm, and a read-only open cannot
      // create one. Nothing is written to the old store.
      let status = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
      guard status == SQLITE_OK, let db else {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed (\(status))"
        if let db { sqlite3_close_v2(db) }
        throw WorkspaceError(.internalError, "Cannot open SQLite file \(path): \(message)")
      }
      handle = db
    }

    func close() {
      if let handle { sqlite3_close_v2(handle) }
      handle = nil
    }

    func hasTable(_ table: String) throws -> Bool {
      let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_text(statement, 1, table, -1, Self.transient)
      return sqlite3_step(statement) == SQLITE_ROW
    }

    /// Every row of `table` as text cells, converting by the stored type of each cell.
    func rows(of table: String) throws -> TableRows {
      let statement = try prepare("SELECT * FROM \(Rows.quote(table))")
      defer { sqlite3_finalize(statement) }
      let count = Int(sqlite3_column_count(statement))
      let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
      var rows: [[String?]] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW else { throw error("Reading \(table)") }
        rows.append(try (0..<count).map { try cell(statement, Int32($0), column: columns[$0], table: table) })
      }
      return TableRows(columns: columns, rows: rows)
    }

    private func cell(
      _ statement: OpaquePointer?, _ index: Int32, column: String, table: String
    ) throws -> String? {
      switch sqlite3_column_type(statement, index) {
      case SQLITE_NULL:
        return nil
      case SQLITE_INTEGER:
        let value = sqlite3_column_int64(statement, index)
        if booleanColumns.contains(column) { return value != 0 ? "true" : "false" }
        return String(value)
      case SQLITE_FLOAT:
        return String(sqlite3_column_double(statement, index))
      case SQLITE_TEXT:
        return String(cString: sqlite3_column_text(statement, index))
      case SQLITE_BLOB:
        let bytes = sqlite3_column_blob(statement, index)
        let length = Int(sqlite3_column_bytes(statement, index))
        let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
          throw WorkspaceError(.internalError, "\(table).\(column) holds a non-UTF-8 blob")
        }
        return text
      default:
        throw WorkspaceError(.internalError, "\(table).\(column) has an unknown SQLite type")
      }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw error(sql) }
      return statement
    }

    private func error(_ context: String) -> WorkspaceError {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
      return WorkspaceError(.internalError, "SQLite: \(message) (\(context))")
    }

    /// `SQLITE_TRANSIENT`: SQLite copies the bound text before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }
}
