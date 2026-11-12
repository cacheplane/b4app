import Foundation
import Testing

@testable import WorkspaceStorage

/// Pure archive-contract checks. No bundle, migration execution, store or fixture endpoint is opened.
@Suite struct AgentProtocolArchiveSchemaIntegrationTests {
  private typealias F = ArchiveSchemaIntegrationFixture

  @Test func schemaNineExcludesOwnedAsAndAgentProtocolObligations() throws {
    let schema = try WorkspaceArchive.schema(F.nine)
    #expect(schema.migrations == F.nine)
    #expect(schema.data == F.preProtocolTables)
    #expect(schema.context == ["schemaMigrations", "hubLink"])
    #expect(try WorkspaceArchive.columns("hubLink", at: 9) == F.hubColumns)
    #expect(try WorkspaceArchive.columns("connections", at: 9) == F.connectionColumns)
  }

  @Test func mainTenPreservesOwnedAsBeforeAgentProtocolSchema() throws {
    // Deployed main10 is valid input; a future-schema rejection here is the intended initial RED.
    let schema = try WorkspaceArchive.schema(F.ten)
    #expect(schema.migrations == F.ten)
    #expect(schema.data == F.preProtocolTables)
    #expect(schema.context == ["schemaMigrations", "hubLink"])
    #expect(try WorkspaceArchive.columns("hubLink", at: 10) == F.hubColumns.union(["ownedAs"]))
    #expect(try WorkspaceArchive.columns("connections", at: 10) == F.connectionColumns)
  }

  @Test func successorThirteenDeclaresOwnedAsAndAgentProtocolObligations() throws {
    let schema = try WorkspaceArchive.schema(F.thirteen)
    #expect(WorkspaceArchive.version == 4)
    #expect(schema.migrations == F.thirteen)
    #expect(schema.data == F.appFolderTables + F.protocolTables)
    #expect(schema.context == ["schemaMigrations", "hubLink"])
    #expect(try WorkspaceArchive.columns("hubLink", at: 12) == F.hubColumns.union(["ownedAs"]))
    #expect(
      try WorkspaceArchive.columns("connections", at: 13)
        == F.environmentConnectionColumns.union(F.protocolFields.map { $0.name }))
  }

  @Test func ownedAsAndProtocolColumnsUseDifferentMigrationOrdinals() throws {
    #expect(
      try WorkspaceArchive.columns("connections", at: 8)
        == F.connectionColumns.subtracting(["models"]))
    #expect(try WorkspaceArchive.columns("connections", at: 9) == F.connectionColumns)
    #expect(try WorkspaceArchive.columns("hubLink", at: 9) == F.hubColumns)
    #expect(try WorkspaceArchive.columns("hubLink", at: 10) == F.hubColumns.union(["ownedAs"]))
    #expect(try WorkspaceArchive.columns("connections", at: 10) == F.connectionColumns)
    for table in F.protocolTables {
      let before = try WorkspaceArchive.columns(table, at: 12)
      let after = try WorkspaceArchive.columns(table, at: 13)
      #expect(before.isEmpty, "Protocol table columns must not exist in published12: \(table)")
      #expect(!after.isEmpty, "Protocol table columns begin in successor13: \(table)")
    }
  }

  @Test func environmentElevenRenamesOnlySchemaOwnedNamesBeforeProtocolThirteen() throws {
    let schema = try WorkspaceArchive.schema(F.eleven)
    #expect(schema.data == F.environmentTables)
    #expect(try WorkspaceArchive.columns("connections", at: 11) == F.environmentConnectionColumns)
    #expect(
      try WorkspaceArchive.columns("projectFolders", at: 10) == Set(["id", "projectId", "path", "createdAt"]))
    #expect(
      try WorkspaceArchive.columns("environmentFolders", at: 11)
        == Set(["id", "environmentId", "path", "createdAt"]))
    #expect(throws: WorkspaceArchive.Rejection.self) {
      try WorkspaceArchive.schema(F.ten + ["0011_agent_protocol"])
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

  @Test func mainElevenVersionThreeKeepsEnvironmentAssociationsAndOpaqueUpdates() throws {
    let opaque = #"{"projectId":"external","environmentId":"keep"}"#
    let lines: [[String: Any]] = [
      ["format": "b4app-export", "version": 3],
      ["table": "environments", "row": ["id": "p", "name": "Environment"]],
      ["table": "environmentFolders", "row": ["id": "f", "environmentId": "p"]],
      ["table": "connections", "row": ["id": "c", "kind": "b4", "environmentId": "p"]],
      [
        "table": "changes",
        "row": ["seq": 1, "table": "displayItems", "op": "update", "column": "payload", "value": opaque],
      ],
    ]
    let bytes = try F.lines(lines)
    let input = try WorkspaceArchive.read(bytes)
    #expect(input.records["environments"]?.first?.row["id"] as? String == "p")
    #expect(input.records["connections"]?.first?.row["environmentId"] as? String == "p")
    #expect(input.records["changes"]?.first?.row["value"] as? String == opaque)
  }

  @Test func legacyMixedRelationalNamesAndUnknownUnpublishedLedgerRefuse() throws {
    let variants: [[[String: Any]]] = [
      [["table": "projects", "row": ["id": "old"]], ["table": "environments", "row": ["id": "new"]]],
      [["table": "connections", "row": ["id": "c", "projectId": "p", "environmentId": "p"]]],
      [
        ["table": "projects", "row": ["id": "p"]],
        ["table": "threads", "row": ["id": "t", "environmentId": "p"]],
      ],
      [
        [
          "table": "changes",
          "row": [
            "seq": 1, "table": "threads", "op": "insert", "value": #"{"projectId":"p","environmentId":"p"}"#,
          ],
        ]
      ],
      [
        [
          "table": "columnClocks",
          "row": ["table": "projectFolders", "rowId": "f", "column": "environmentId"],
        ]
      ],
    ]
    for records in variants {
      let bytes = try F.lines([["format": "b4app-export", "version": 3]] + records)
      #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(bytes) }
    }
    for version in 1...3 {
      let bytes = try F.lines([
        ["format": "b4app-export", "version": version, "migrations": F.ten + ["0011_agent_protocol"]]
      ])
      #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(bytes) }
    }
  }

  @Test func versionFourValidatesEachSourcePrefixBeforeRelationalMapping() throws {
    for names in [F.nine, F.ten, F.eleven, F.twelve, F.thirteen] {
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
      let header: [String: Any] = [
        "format": "b4app-export", "version": 4, "at": "then", "purpose": "preMigration", "migrations": names,
        "requiredTables": dataTables, "sourceContextTables": ["schemaMigrations", "hubLink"],
      ]
      let footer: [String: Any] = [
        "format": "b4app-export-end", "version": 4, "rows": records.count, "tableRows": counts,
      ]
      let input = try WorkspaceArchive.read(F.lines([header] + records + [footer]))
      #expect(input.records["environmentFolders"]?.first?.row["environmentId"] as? String == "p")
      #expect(input.records["projectFolders"] == nil)
      #expect(input.dataCount == 1)
    }
  }

  @Test func versionFourRejectsReferencesFromTheOtherRelationalSchemaFamily() throws {
    for names in [F.nine, F.ten, F.eleven, F.twelve, F.thirteen] {
      let current = names.count >= 11
      let association = current ? "environmentId" : "projectId"
      let wrong = current ? "projectId" : "environmentId"
      let table = current ? "environments" : "projects"
      let wrongTable = current ? "projects" : "environments"
      let change: [String: Any] = [
        "seq": 1, "deviceId": "fixture", "wall": 1, "table": "threads", "rowId": "t", "op": "update",
        "column": association, "value": #""p""#, "synced": false, "hlc": "000000001000-0000-fixture",
      ]
      let clock: [String: Any] = [
        "table": "threads", "rowId": "t", "column": association, "hlc": "000000001000-0000-fixture",
      ]
      _ = try WorkspaceArchive.read(
        F.v4(
          names: names,
          records: [["table": "changes", "row": change], ["table": "columnClocks", "row": clock]]))
      var badColumn = change; badColumn["column"] = wrong
      var badTable = change; badTable["table"] = wrongTable; badTable["column"] = "name"
      var badClock = clock; badClock["column"] = wrong
      var badClockTable = clock; badClockTable["table"] = wrongTable; badClockTable["column"] = "name"
      var goodInsert = change; goodInsert["op"] = "insert"; goodInsert["column"] = NSNull()
      goodInsert["value"] = "{\"id\":\"t\",\"\(association)\":\"p\"}"
      _ = try WorkspaceArchive.read(F.v4(names: names, records: [["table": "changes", "row": goodInsert]]))
      var badInsert = goodInsert; badInsert["value"] = "{\"id\":\"t\",\"\(wrong)\":\"p\"}"
      var goodTable = change; goodTable["table"] = table; goodTable["column"] = "name"
      _ = try WorkspaceArchive.read(F.v4(names: names, records: [["table": "changes", "row": goodTable]]))
      let invalidRecords: [[String: Any]] = [
        ["table": "changes", "row": badColumn], ["table": "changes", "row": badTable],
        ["table": "columnClocks", "row": badClock], ["table": "columnClocks", "row": badClockTable],
        ["table": "changes", "row": badInsert],
      ]
      for record in invalidRecords {
        #expect(throws: WorkspaceArchive.Rejection.self) {
          try WorkspaceArchive.read(F.v4(names: names, records: [record]))
        }
      }
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

  @Test func legacyArchivesPreserveNullProtocolFieldsForVersionsOneThroughThree() throws {
    for version in 1...3 {
      var row = F.legacyRow
      for field in F.protocolFields { row[field.name] = NSNull() }
      let input = try WorkspaceArchive.read(F.legacy(version: version, row: row))
      #expect(input.version == version)
      #expect(input.dataCount == 1)
      let record = try #require(input.records["connections"]?.first)
      #expect(record.row["id"] as? String == "legacy-fixed")
      #expect(record.row["kind"] as? String == "b4")
      for field in F.protocolFields { #expect(record.row[field.name] is NSNull) }
    }
  }

  @Test func legacyArchivesReadUnextendedB4RowsForVersionsOneThroughThree() throws {
    for version in 1...3 {
      let input = try WorkspaceArchive.read(F.legacy(version: version, row: F.legacyRow))
      #expect(input.version == version)
      #expect(input.dataCount == 1)
      let record = try #require(input.records["connections"]?.first)
      #expect(Set(record.row.keys) == Set(F.legacyRow.keys))
      #expect(record.row["nativeScope"] as? String == "historical-scope")
      #expect(record.row["authReference"] as? String == "secret:reference-only")
    }
  }

  @Test func legacyArchivesStillRejectAgentProtocolConnectionKind() throws {
    for version in 1...3 {
      var row = F.legacyRow
      row["kind"] = "agentProtocol"
      do {
        _ = try WorkspaceArchive.read(F.legacy(version: version, row: row))
        Issue.record("Legacy\(version) accepted an Agent Protocol connection.")
      } catch WorkspaceArchive.Rejection.invalid {
      } catch {
        Issue.record("Legacy\(version) rejected the new kind for the wrong reason: \(error).")
      }
    }
  }
}

/// Fixed independent contracts, not aliases of WorkspaceArchive or the shared AP oracle.
private enum ArchiveSchemaIntegrationFixture {
  static let nine = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
  ]
  static let ten = nine + ["0010_owned_rows"]
  static let eleven = ten + ["0011_environments"]
  static let twelve = eleven + ["0012_app_folders"]
  static let thirteen = twelve + ["0013_agent_protocol"]
  static let environmentTables = preProtocolTables.map {
    $0 == "projects" ? "environments" : ($0 == "projectFolders" ? "environmentFolders" : $0)
  }
  static let appFolderTables = environmentTables.flatMap { table in
    table == "threads" ? ["threads", "appFolders"] : [table]
  }
  static func tables(at count: Int) -> [String] {
    let base = count < 11 ? preProtocolTables : (count < 12 ? environmentTables : appFolderTables)
    return base + (count >= 13 ? protocolTables : [])
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
    let header: [String: Any] = [
      "format": "b4app-export", "version": 4, "at": "then", "purpose": "preMigration", "migrations": names,
      "requiredTables": dataTables, "sourceContextTables": context,
    ]
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
