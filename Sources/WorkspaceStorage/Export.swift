import Foundation
import WorkspaceProtocol

/// Backups and restores as one JSON-lines archive: a header, then `{"table": ..., "row": {...}}` per
/// row in dependency order. Written before every migration and on demand; the same archive carries
/// data across a major PostgreSQL version (D-041: the pinned build ships no pg_dump).
extension WorkspaceDatabase {
  public static let archiveFormat = "b4app-export"
  public static let archiveTables = [
    "localServers", "connections", "threads", "turns", "displayItems", "runtimeRequests", "drafts", "devices",
    "changes",
  ]

  public struct ArchiveSummary: Sendable, Equatable {
    public var path: String
    public var rows: Int
  }

  /// Row counts per archived table.
  public func tableCounts() throws -> [String: Int] {
    try read { c in
      var counts: [String: Int] = [:]
      for table in Self.archiveTables {
        counts[table] =
          try c.execute("SELECT count(*) AS \"n\" FROM \(Rows.quote(table))").rows.first?.int("n") ?? 0
      }
      return counts
    }
  }

  /// Write every table to `path` (mode 0600). Returns the row count.
  @discardableResult
  public func export(to path: String) throws -> ArchiveSummary {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let header: [String: Any] = [
      "format": Self.archiveFormat, "version": 1, "at": Timestamp.now(),
      "migrations": try appliedMigrations(),
    ]
    try handle.write(
      contentsOf: try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) + Data("\n".utf8)
    )
    var count = 0
    try read { c in
      for table in Self.archiveTables {
        let rows = try c.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows
        for row in rows {
          var object: [String: Any] = [:]
          for (name, cell) in row.cells { object[name] = try Self.jsonObject(cell) }
          let line: [String: Any] = ["table": table, "row": object]
          try handle.write(
            contentsOf: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
              + Data("\n".utf8))
          count += 1
        }
      }
    }
    return ArchiveSummary(path: path, rows: count)
  }

  /// Load an archive. The database must be empty unless `replace` is set, in which case every table
  /// is cleared first; the whole restore is one transaction and records no changes.
  @discardableResult
  public func restore(from path: String, replace: Bool = false) throws -> ArchiveSummary {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard let first = lines.first,
      let header = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
      header["format"] as? String == Self.archiveFormat
    else { throw WorkspaceError(.protocolInvalid, "\(path) is not a \(Self.archiveFormat) archive.") }
    lines.removeFirst()
    return try write { c in
      // Before anything else: neither the clearing nor the loading may land in the change log.
      try c.execute("SET LOCAL b4app.replaying = 'on'")
      let populated = try c.execute("SELECT count(*) AS \"n\" FROM \"connections\"").rows.first?.int("n") ?? 0
      if populated > 0 {
        guard replace else {
          throw WorkspaceError(
            .protocolInvalid, "The store is not empty; pass --replace to overwrite it from the archive.")
        }
        for table in Self.archiveTables.reversed() { try c.execute("DELETE FROM \(Rows.quote(table))") }
      }
      var count = 0
      for line in lines {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let table = object["table"] as? String, let row = object["row"] as? [String: Any],
          Self.archiveTables.contains(table)
        else { continue }
        let columns = try columns(c, of: table).filter { row[$0] != nil }
        let values = try columns.map { try Rows.param(row[$0]!) }
        let statement = Rows.insert(table, Array(zip(columns, values)).map { (column: $0.0, param: $0.1) })
        try c.execute(statement.sql, statement.params)
        count += 1
      }
      // The changes sequence must continue past the restored rows.
      try c.execute(
        "SELECT setval('\"changes_seq_seq\"', coalesce((SELECT max(\"seq\") FROM \"changes\"), 0) + 1, false)"
      )
      return ArchiveSummary(path: path, rows: count)
    }
  }

  /// A result cell as a Foundation JSON object (typed by the column's OID).
  static func jsonObject(_ cell: Row.Cell) throws -> Any {
    guard let text = cell.text else { return NSNull() }
    switch cell.typeOID {
    case 16: return text == "t"
    case 20, 21, 23, 26: return Int(text) ?? text
    case 700, 701, 1700: return Double(text) ?? text
    case 114, 3802:
      return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    default: return text
    }
  }
}
