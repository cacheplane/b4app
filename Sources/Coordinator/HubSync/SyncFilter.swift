import Foundation
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// What of the local change log may leave the Mac, and in what shape (M8a global constraints). Pure:
/// the same record always maps to the same wire change.
///
/// - Only `WorkspaceDatabase.syncedTables` travel; `localServers`, `devices`, and `hubLink` never do.
/// - `connections.authReference`, `.localServerId`, and `.target` are machine-local (a secret
///   reference, a managed-server id, a path or URL): an insert carries them blanked, and an update of
///   one of them is not sent at all.
/// - A `displayItems.payload` whose JSON is over 1 MiB travels as `{"truncated": true, "bytes": n}`,
///   on an insert and on an update of the `payload` column alike (the hub refuses any value over
///   2 MiB, so an oversized update would otherwise block the queue).
/// - An update that cleared a column carries JSON `null` (the hub's "set it to NULL").
enum SyncFilter {
  static let payloadLimit = 1_048_576
  static let blankedConnectionColumns: Set<String> = ["authReference", "localServerId", "target"]
  private static let syncedTables = Set(WorkspaceDatabase.syncedTables.map(\.table))

  static func outbound(_ record: ChangeRecord) -> SyncChange? {
    guard syncedTables.contains(record.table) else { return nil }
    var value = record.value
    switch (record.table, record.op) {
    case ("connections", "insert"):
      if case .object(var row) = value {
        row["authReference"] = .null
        row["localServerId"] = .null
        row["target"] = .string("")
        value = .object(row)
      }
    case ("connections", "update"):
      if let column = record.column, blankedConnectionColumns.contains(column) { return nil }
    case ("displayItems", "insert"):
      if case .object(var row) = value, let payload = row["payload"] {
        row["payload"] = truncated(payload)
        value = .object(row)
      }
    case ("displayItems", "update") where record.column == "payload":
      value = value.map(truncated)
    default:
      break
    }
    // The change log stores a cleared column as JSON null, which decodes as an absent value.
    if record.op == "update", value == nil { value = .null }
    return SyncChange(
      deviceSeq: record.seq, wall: record.wall, table: record.table, rowId: record.rowId, op: record.op,
      column: record.column, value: value)
  }

  /// The payload itself, or a marker with its JSON size when that is over `payloadLimit`.
  static func truncated(_ payload: JSONValue) -> JSONValue {
    let bytes = (try? JSONCoding.encoder.encode(payload).count) ?? 0
    guard bytes > payloadLimit else { return payload }
    return ["truncated": true, "bytes": .number(Double(bytes))]
  }
}
