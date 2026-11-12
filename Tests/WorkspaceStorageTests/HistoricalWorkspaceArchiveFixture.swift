import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Independent legacy fixture writer. This fixed old0001-0009 table/column contract is encoded
/// directly from SQL rows; no current exporter, archive reader, v4 header/footer or table manifest
/// participates. Version1 converts JSON text cells independently; versions2/3 keep the text encoding.
/// The optional main11 naming mode writes its known environment names, without AP columns.
enum HistoricalWorkspaceArchiveFixture {
  private struct Table {
    let name: String
    let columns: [String]
    let json: Set<String>
  }
  private static let tables = [
    Table(
      name: "localServers",
      columns: [
        "id", "name", "projectPath", "nodePath", "cliPath", "cliVersion", "launchMode", "envFilePath",
        "requestedPort", "actualPort", "generation", "pid", "processStartedAt", "ownershipVerified", "health",
        "statusMessage", "routes", "logPath", "createdAt", "updatedAt",
      ], json: ["routes"]),
    Table(
      name: "connections",
      columns: [
        "id", "kind", "label", "enabled", "profileRevision", "target", "routeKey", "b4Mode", "localServerId",
        "authReference", "nativeScope", "capabilities", "status", "authStatus", "createdAt", "updatedAt",
        "projectId", "models",
      ], json: ["capabilities", "models"]),
    Table(name: "projects", columns: ["id", "name", "manual", "createdAt", "updatedAt"], json: []),
    Table(name: "projectFolders", columns: ["id", "projectId", "path", "createdAt"], json: []),
    Table(
      name: "threads",
      columns: [
        "id", "connectionId", "nativeThreadId", "nativeScope", "title", "context", "pinned", "archived",
        "continuity", "createdAt", "updatedAt", "projectId", "readTurnId", "userDeletedAt", "model",
        "permission",
      ], json: []),
    Table(
      name: "turns",
      columns: [
        "id", "threadId", "operationId", "nativeTurnId", "inputRef", "status", "submission", "outcome",
        "createdAt", "updatedAt",
      ], json: []),
    Table(
      name: "displayItems",
      columns: [
        "id", "threadId", "turnId", "nativeItemId", "role", "type", "payload", "sequence", "provenance",
        "createdAt",
      ], json: ["payload"]),
    Table(
      name: "runtimeRequests",
      columns: [
        "id", "nativeRequestId", "threadId", "turnId", "adapterGeneration", "kind", "state", "payload",
        "createdAt", "updatedAt",
      ], json: ["payload"]),
    Table(name: "drafts", columns: ["threadId", "text", "updatedAt"], json: []),
    Table(name: "devices", columns: ["id", "name", "createdAt"], json: []),
    Table(
      name: "changes",
      columns: ["seq", "deviceId", "wall", "table", "rowId", "op", "column", "value", "synced", "hlc"],
      json: ["value"]),
    Table(name: "columnClocks", columns: ["table", "rowId", "column", "hlc"], json: []),
  ]
  private static func quoted(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
  static func currentTable(_ historical: String) -> String {
    historical == "projects"
      ? "environments" : (historical == "projectFolders" ? "environmentFolders" : historical)
  }
  static func historicalRow(
    table: String, row input: [String: Any], jsonColumnsAsText: Bool
  ) throws -> [String: Any] {
    var row = input
    let referenceTables = ["connections", "threads", "projectFolders", "environmentFolders"]
    if referenceTables.contains(table), let value = row.removeValue(forKey: "environmentId") {
      guard row["projectId"] == nil else {
        throw WorkspaceError(.internalError, "Ambiguous fixture association.")
      }
      row["projectId"] = value
    }
    if table == "changes" || table == "columnClocks", let stored = row["table"] as? String {
      row["table"] =
        stored == "environments" ? "projects" : (stored == "environmentFolders" ? "projectFolders" : stored)
      if referenceTables.contains(stored), row["column"] as? String == "environmentId" {
        row["column"] = "projectId"
      }
      if table == "changes", row["op"] as? String == "insert", referenceTables.contains(stored) {
        let image: [String: Any]?
        if jsonColumnsAsText, let text = row["value"] as? String {
          image = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        } else {
          image = row["value"] as? [String: Any]
        }
        if var image, let value = image.removeValue(forKey: "environmentId") {
          guard image["projectId"] == nil else {
            throw WorkspaceError(.internalError, "Ambiguous fixture image.")
          }
          image["projectId"] = value
          if jsonColumnsAsText {
            row["value"] = String(
              decoding: try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]),
              as: UTF8.self)
          } else {
            row["value"] = image
          }
        }
      }
    }
    return row
  }
  static func write(
    _ source: WorkspaceDatabase, version: Int, path: String, omitChangeClocks: Bool = false,
    environmentNames: Bool = false
  ) throws -> Int {
    #expect((1...3).contains(version))
    var records: [[String: Any]] = []
    try source.read { connection in
      for table in tables {
        if omitChangeClocks && table.name == "columnClocks" { continue }
        let columns = table.columns.filter { !(omitChangeClocks && table.name == "changes" && $0 == "hlc") }
        let pairs = columns.map { column in
          let currentColumn = column == "projectId" ? "environmentId" : column
          let identifier = quoted(currentColumn)
          let value =
            table.json.contains(column)
            ? "CASE WHEN \(identifier) IS NULL THEN NULL ELSE to_jsonb(\(identifier)::text) END"
            : identifier
          let writtenColumn = environmentNames ? currentColumn : column
          return "'\(writtenColumn)', \(value)"
        }.joined(separator: ",")
        let rows = try connection.execute(
          "SELECT jsonb_build_object(\(pairs))::text AS row FROM \(quoted(currentTable(table.name))) ORDER BY 1"
        ).rows
        for result in rows {
          let text = try #require(result.text("row"))
          var row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          if !environmentNames {
            row = try historicalRow(table: table.name, row: row, jsonColumnsAsText: true)
          }
          if version == 1 {
            for column in table.json {
              if let text = row[column] as? String {
                row[column] = try JSONSerialization.jsonObject(
                  with: Data(text.utf8), options: [.fragmentsAllowed])
              }
            }
          }
          records.append(["table": environmentNames ? currentTable(table.name) : table.name, "row": row])
        }
      }
    }
    let header: [String: Any] = ["format": "b4app-export", "version": version]
    var data = Data()
    for object in [header] + records {
      data += try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8)
    }
    guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      throw WorkspaceError(.internalError, "Legacy archive fixture publication failed.")
    }
    return records.count
  }
}
