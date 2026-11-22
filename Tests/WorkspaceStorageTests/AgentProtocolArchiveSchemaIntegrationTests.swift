import Foundation
import Testing

@testable import WorkspaceStorage

/// Pure archive-contract checks. No bundle, migration execution, store or fixture endpoint is opened.
struct AgentProtocolArchiveSchemaIntegrationTests {
  private typealias F = ArchiveSchemaIntegrationFixture

  @Test func ownedAsAndProtocolColumnsUseDifferentMigrationOrdinals() throws {
    #expect(
      try WorkspaceArchive.columns("connections", at: 8)
        == F.connectionColumns.subtracting(["models"]))
    #expect(try WorkspaceArchive.columns("connections", at: 9) == F.connectionColumns)
    #expect(try WorkspaceArchive.columns("hubLink", at: 9) == F.hubColumns)
    #expect(try WorkspaceArchive.columns("hubLink", at: 10) == F.hubColumns.union(["ownedAs"]))
    #expect(try WorkspaceArchive.columns("connections", at: 10) == F.connectionColumns)
    for table in F.protocolTables {
      let before = try WorkspaceArchive.columns(table, at: 13)
      let after = try WorkspaceArchive.columns(table, at: 17)
      #expect(before.isEmpty, "Protocol table columns must not exist in published13: \(table)")
      #expect(!after.isEmpty, "Protocol table columns begin in successor17: \(table)")
    }
  }

  @Test func publishedLegacyAssociationsMapWithoutChangingOpaqueJSONUpdateValues() throws {
    for version in 1...3 {
      let opaque = #"{ "projectId":"external", "environmentId":"keep", "precise":1.00000000000000000001 }"#
      let image =
        #"{ "id":"t", "projectId":"p", "opaque":{"projectId":"nested","precise":1.00000000000000000001} }"#
      let value: Any =
        version == 1
        ? try JSONSerialization.jsonObject(with: Data(image.utf8)) : image
      let update: Any =
        version == 1
        ? try JSONSerialization.jsonObject(with: Data(opaque.utf8)) : opaque
      let lines: [[String: Any]] = [
        ["format": "b4app-export", "version": version],
        [
          "table": "projectFolders",
          "row": ["id": "f", "projectId": "p", "path": "/fixture", "createdAt": "then"],
        ],
        ["table": "connections", "row": ["id": "c", "kind": "b4", "projectId": "p"]],
        ["table": "threads", "row": ["id": "t", "projectId": "p"]],
        [
          "table": "changes",
          "row": ["seq": 1, "table": "threads", "op": "insert", "column": NSNull(), "value": value],
        ],
        [
          "table": "changes",
          "row": ["seq": 2, "table": "displayItems", "op": "update", "column": "payload", "value": update],
        ],
        [
          "table": "columnClocks",
          "row": [
            "table": "threads", "rowId": "t", "column": "projectId", "hlc": "000000001000-0000-fixture",
          ],
        ],
      ]
      let bytes = try lines.reduce(into: Data()) { result, line in
        result += try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data("\n".utf8)
      }
      let input = try WorkspaceArchive.read(bytes)
      #expect(input.records["projectFolders"] == nil)
      #expect(input.records["environmentFolders"]?.first?.row["environmentId"] as? String == "p")
      #expect(input.records["connections"]?.first?.row["environmentId"] as? String == "p")
      #expect(input.records["threads"]?.first?.row["environmentId"] as? String == "p")
      #expect(input.records["columnClocks"]?.first?.row["column"] as? String == "environmentId")
      let insert = try #require(input.records["changes"]?.first?.row["value"])
      let actualUpdate = try #require(input.records["changes"]?.last?.row["value"])
      if version == 1 {
        let parsed = try #require(insert as? [String: Any])
        #expect(parsed["projectId"] == nil)
        #expect(parsed["environmentId"] as? String == "p")
        #expect((parsed["opaque"] as? [String: Any])?["projectId"] as? String == "nested")
        #expect(actualUpdate as? NSDictionary == update as? NSDictionary)
      } else {
        #expect(
          insert as? String
            == image.replacingOccurrences(of: #""projectId":"p""#, with: #""environmentId":"p""#))
        #expect(actualUpdate as? String == opaque)
      }
    }
  }

  @Test func versionFourValidatesEachSourcePrefixBeforeRelationalMapping() throws {
    for names in F.sourceLedgers {
      let renamed = names.count >= 11
      let dataTables = F.tables(at: names.count)
      let table = renamed ? "environmentFolders" : "projectFolders"
      let association = renamed ? "environmentId" : "projectId"
      var records: [[String: Any]] = names.map {
        ["table": "schemaMigrations", "row": ["name": $0, "appliedAt": "then"]]
      }
      records.append([
        "table": table, "row": ["id": "f", association: "p", "path": "/fixture", "createdAt": "then"],
      ])
      var counts = Dictionary(
        uniqueKeysWithValues: (dataTables + ["schemaMigrations", "hubLink"]).map { ($0, 0) })
      counts["schemaMigrations"] = names.count; counts[table] = 1
      var header: [String: Any] = [
        "format": "b4app-export", "version": 4, "at": "then", "purpose": "preMigration", "migrations": names,
        "requiredTables": dataTables, "sourceContextTables": ["schemaMigrations", "hubLink"],
      ]
      if names.count == 17 { header["protocolSchema"] = "generation_epochs_v1" }
      let footer: [String: Any] = [
        "format": "b4app-export-end", "version": 4, "rows": records.count, "tableRows": counts,
      ]
      let input = try WorkspaceArchive.read(F.lines([header] + records + [footer]))
      #expect(input.records["environmentFolders"]?.first?.row["environmentId"] as? String == "p")
      #expect(input.records["projectFolders"] == nil)
      #expect(input.dataCount == 1)
    }
  }

  @Test func encodedInsertKeysPreservePostgresNumbersAndRejectEscapedDoubleAliases() throws {
    // PostgreSQL numeric/jsonb supports these exponent ranges; Foundation JSON numbers need not.
    // They remain TEXT inside the archive, never parsed as Foundation numbers by the reader.
    let image = #"{ "project\u0049d":"p", "opaque":{"high":1e400,"low":1e-400,"projectId":"nested"} }"#
    let expected = #"{ "environmentId":"p", "opaque":{"high":1e400,"low":1e-400,"projectId":"nested"} }"#
    for version in [2, 3, 4] {
      func document(_ text: String) throws -> Data {
        let row: [String: Any] = [
          "seq": 1, "deviceId": "fixture", "wall": 1, "table": "threads", "rowId": "t", "op": "insert",
          "column": NSNull(), "value": text, "synced": false, "hlc": "000000001000-0000-fixture",
        ]
        let record: [String: Any] = ["table": "changes", "row": row]
        return version == 4
          ? try F.v4(names: F.ten, records: [record])
          : try F.lines([["format": "b4app-export", "version": version], record])
      }
      let input = try WorkspaceArchive.read(document(image))
      #expect(input.records["changes"]?.first?.row["value"] as? String == expected)
      for ambiguous in [
        #"{"projectId":"p","project\u0049d":"other","opaque":1e400}"#,
        #"{"projectId":"p","environment\u0049d":"other","opaque":1e400}"#,
        #"{"project\u0049d":"p","environmentId":"other","opaque":1e400}"#,
      ] {
        #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(document(ambiguous)) }
      }
    }
  }

  @Test func legacyArchivesRejectEveryNonNullAgentProtocolConnectionField() throws {
    for version in 1...3 {
      for field in F.protocolFields {
        var row = F.legacyRow
        row[field.name] = field.value
        do {
          _ = try WorkspaceArchive.read(F.legacy(version: version, row: row))
          Issue.record("Legacy\(version) accepted non-null AP field \(field.name).")
        } catch WorkspaceArchive.Rejection.invalid {
          // The provided obligation must be rejected, never silently discarded.
        } catch {
          Issue.record("Legacy\(version) rejected \(field.name) for the wrong reason: \(error).")
        }
      }
    }
  }
}
private enum ArchiveSchemaIntegrationFixture {
  static let nine = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
  ]
  static let ten = nine + ["0010_owned_rows"]
  static let eleven = ten + ["0011_environments"]
  static let twelve = eleven + ["0012_app_folders"]
  static let thirteen = twelve + ["0013_view_settings"]
  static let fourteen = thirteen + ["0014_connection_commands"]
  static let fifteen = fourteen + ["0015_density"]
  static let sixteen = fifteen + ["0016_turn_open_work"]
  static let seventeen = sixteen + ["0017_agent_protocol"]
  static let sourceLedgers = [nine, ten, eleven, twelve, thirteen, fourteen, fifteen, sixteen, seventeen]
  static let environmentTables = preProtocolTables.map {
    $0 == "projects" ? "environments" : ($0 == "projectFolders" ? "environmentFolders" : $0)
  }
  static let appFolderTables = environmentTables.flatMap { table in
    table == "threads" ? ["threads", "appFolders"] : [table]
  }
  static let viewSettingsTables = appFolderTables + ["viewSettings"]
  static func tables(at count: Int) -> [String] {
    let base =
      count < 11
      ? preProtocolTables
      : (count < 12 ? environmentTables : (count < 13 ? appFolderTables : viewSettingsTables))
    return base + (count >= 17 ? protocolTables : [])
  }
  static var environmentConnectionColumns: Set<String> {
    connectionColumns.subtracting(["projectId"]).union(["environmentId"])
  }
  static let preProtocolTables = [
    "localServers", "projects", "projectFolders", "connections", "threads", "turns", "displayItems",
    "runtimeRequests", "drafts", "devices", "changes", "columnClocks", "settings", "usageReadings",
    "tokenUsage", "connectionUsage", "threadDeletes",
  ]
  static let protocolTables = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]
  static let hubColumns = Set([
    "id", "url", "deviceId", "deviceName", "tokenRef", "orgSlug", "username", "cursor", "lastPushAt",
    "lastError", "joinedAt",
  ])
  static let connectionColumns = Set([
    "id", "kind", "label", "enabled", "profileRevision", "target", "routeKey", "b4Mode", "localServerId",
    "authReference", "nativeScope", "capabilities", "status", "authStatus", "createdAt", "updatedAt",
    "projectId", "models",
  ])
  static let protocolFields: [(name: String, value: String)] = [
    ("peerProfile", "b4"), ("agentId", "fixture-agent"), ("authMode", "none"),
    ("authHeaderName", "X-Fixture"), ("protocolRetiredAt", "2026-11-10T00:00:00.000Z"),
    ("protocolRetiredReason", "agent_protocol_cutover"),
  ]
  static var legacyRow: [String: Any] {
    [
      "id": "legacy-fixed", "kind": "b4", "label": "Historical connection",
      "target": "https://example.invalid/retained", "routeKey": "/chat#agent", "b4Mode": "remote",
      "nativeScope": "historical-scope", "authReference": "secret:reference-only",
    ]
  }
  static func v4(names: [String], records: [[String: Any]]) throws -> Data {
    let dataTables = tables(at: names.count)
    let context = ["schemaMigrations", "hubLink"]
    let ledger: [[String: Any]] = names.map {
      ["table": "schemaMigrations", "row": ["name": $0, "appliedAt": "then"]]
    }
    let body = ledger + records
    var counts = Dictionary(uniqueKeysWithValues: (dataTables + context).map { ($0, 0) })
    for record in body { counts[try #require(record["table"] as? String), default: 0] += 1 }
    var header: [String: Any] = [
      "format": "b4app-export", "version": 4, "at": "then", "purpose": "preMigration", "migrations": names,
      "requiredTables": dataTables, "sourceContextTables": context,
    ]
    if names.count == 17 { header["protocolSchema"] = "generation_epochs_v1" }
    let footer: [String: Any] = [
      "format": "b4app-export-end", "version": 4, "rows": body.count, "tableRows": counts,
    ]
    return try lines([header] + body + [footer])
  }
  static func lines(_ lines: [[String: Any]]) throws -> Data {
    try lines.reduce(into: Data()) { result, line in
      result += try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data("\n".utf8)
    }
  }
  static func legacy(version: Int, row: [String: Any]) throws -> Data {
    let lines: [[String: Any]] = [
      ["format": "b4app-export", "version": version, "at": "fixed-fixture"],
      ["table": "connections", "row": row],
    ]
    var data = Data()
    for line in lines {
      data.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
      data.append(0x0a)
    }
    return data
  }
}
