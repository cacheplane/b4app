import CryptoKit
import Foundation
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// What of the local change log may leave the Mac, and in what shape (M8a global constraints). Pure:
/// the same record always maps to the same wire change.
///
/// - Only `WorkspaceDatabase.syncedTables` travel; `localServers`, `devices`, and `hubLink` never do.
/// - A `connections` insert carries only the known columns (`connectionColumns`, the Mac schema's and
///   the hub's), so a column a later migration adds never uploads by accident; one whose value is not
///   an object is not sent at all.
/// - `connections.authReference`, `.localServerId`, and `.target` are machine-local (a secret
///   reference, a managed-server id, a path or URL): an insert carries them blanked, and an update of
///   one of them is not sent at all.
/// - A `connections.nativeScope` or `threads.nativeScope` that contains `/` (a B4 origin URL, a Claude
///   config directory) travels as `scope:` plus the first 16 hex characters of its SHA-256: stable, so
///   the mirror's uniqueness on (connection, scope, native thread) still holds, but no path, host, or
///   port leaves the Mac. Emails and Codex auth types contain no `/` and travel unchanged.
/// - A `displayItems.payload` or `runtimeRequests.payload` whose JSON is over 1 MiB travels as
///   `{"truncated": true, "bytes": n}`, on an insert and on an update of the `payload` column alike
///   (the hub refuses any value over 2 MiB, so an oversized one would otherwise block the queue).
/// - An update that cleared a column carries JSON `null` (the hub's "set it to NULL").
/// - Every change carries its transaction's clock (`hlc`), which the hub merges by.
enum SyncFilter {
  static let payloadLimit = 1_048_576
  static let blankedConnectionColumns: Set<String> = ["authReference", "localServerId", "target"]
  /// The 16 columns of `connections` in `0001_init.sql`, equal to the hub's `TableSpec`.
  static let connectionColumns: Set<String> = [
    "id", "kind", "label", "enabled", "profileRevision", "target", "routeKey", "b4Mode", "localServerId",
    "authReference", "nativeScope", "capabilities", "status", "authStatus", "createdAt", "updatedAt",
  ]
  private static let scopedTables: Set<String> = ["connections", "threads"]
  private static let payloadTables: Set<String> = ["displayItems", "runtimeRequests"]
  private static let syncedTables = Set(WorkspaceDatabase.syncedTables.map(\.table))

  static func outbound(_ record: ChangeRecord) -> SyncChange? {
    guard syncedTables.contains(record.table) else { return nil }
    var value = record.value
    switch (record.table, record.op) {
    case ("connections", "insert"):
      guard case .object(let row) = value else { return nil }
      var kept = row.filter { connectionColumns.contains($0.key) }
      kept["authReference"] = .null
      kept["localServerId"] = .null
      kept["target"] = .string("")
      value = .object(kept)
    case ("connections", "update"):
      if let column = record.column, blankedConnectionColumns.contains(column) { return nil }
    default:
      break
    }
    if scopedTables.contains(record.table) {
      if record.op == "insert", case .object(var row) = value, let scope = row["nativeScope"] {
        row["nativeScope"] = opaqueScope(scope)
        value = .object(row)
      } else if record.op == "update", record.column == "nativeScope" {
        value = value.map(opaqueScope)
      }
    }
    if payloadTables.contains(record.table) {
      if record.op == "insert", case .object(var row) = value, let payload = row["payload"] {
        row["payload"] = truncated(payload)
        value = .object(row)
      } else if record.op == "update", record.column == "payload" {
        value = value.map(truncated)
      }
    }
    // The change log stores a cleared column as JSON null, which decodes as an absent value.
    if record.op == "update", value == nil { value = .null }
    return SyncChange(
      deviceSeq: record.seq, wall: record.wall, table: record.table, rowId: record.rowId, op: record.op,
      column: record.column, value: value, hlc: record.hlc)
  }

  /// The payload itself, or a marker with its JSON size when that is over `payloadLimit`.
  static func truncated(_ payload: JSONValue) -> JSONValue {
    let bytes = (try? JSONCoding.encoder.encode(payload).count) ?? 0
    guard bytes > payloadLimit else { return payload }
    return ["truncated": true, "bytes": .number(Double(bytes))]
  }

  /// A scope unchanged, or `scope:` plus the first 16 hex characters of its SHA-256 when it contains `/`.
  static func opaqueScope(_ scope: JSONValue) -> JSONValue {
    guard case .string(let text) = scope, text.contains("/") else { return scope }
    let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    return .string("scope:" + hex.prefix(16))
  }
}
