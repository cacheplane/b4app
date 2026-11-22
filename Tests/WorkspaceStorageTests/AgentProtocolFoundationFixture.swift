import CoreFoundation
import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Independent TEST oracle, duplicated byte-for-byte into the two test targets. Never calls the
/// production archive codec, WorkspaceDatabase initializer, or migration admission core.
enum AgentProtocolFoundationFixture {
  enum Failure: Error { case canonicalSet, schema, framing, row }

  static let migrations = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
    "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
    "0014_connection_commands", "0015_density", "0016_turn_open_work", "0017_agent_protocol",
  ]

  static let protocolTables = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations",
    "protocolGrantSecrets", "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  static let legacyDataTables = [
    "localServers", "projects", "projectFolders", "connections", "threads", "turns",
    "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks", "settings",
    "usageReadings", "tokenUsage", "connectionUsage", "threadDeletes",
  ]

  static let appFolderDataTables = legacyDataTables.flatMap { table in
    table == "threads" ? ["threads", "appFolders"] : [currentTable(old: table)]
  }

  static let viewSettingsDataTables = appFolderDataTables + ["viewSettings"]

  static let dataTables = viewSettingsDataTables + protocolTables

  static func currentTable(old table: String) -> String {
    switch table {
    case "projects": return "environments"
    case "projectFolders": return "environmentFolders"
    default: return table
    }
  }

  /// Only schema-owned names change. Nested opaque JSON and update-value payloads stay exact.
  static func currentRow(
    table: String, row: [String: Any], jsonColumnsAsText: Bool = false
  ) throws -> [String: Any] {
    func renamedReference(_ original: [String: Any]) throws -> [String: Any] {
      var renamed = original
      if let value = renamed["projectId"] {
        guard renamed["environmentId"] == nil else { throw Failure.row }
        renamed.removeValue(forKey: "projectId")
        renamed["environmentId"] = value
      }
      return renamed
    }
    let referenceTables = ["connections", "threads", "projectFolders", "environmentFolders"]
    var result = row
    if referenceTables.contains(table) { result = try renamedReference(row) }
    if table == "changes" || table == "columnClocks" {
      guard let target = result["table"] as? String else { throw Failure.row }
      result["table"] = currentTable(old: target)
      if referenceTables.contains(target), result["column"] as? String == "projectId" {
        result["column"] = "environmentId"
      }
      if table == "changes", result["op"] as? String == "insert",
        referenceTables.contains(target), let value = result["value"], !(value is NSNull)
      {
        if jsonColumnsAsText {
          guard let text = value as? String else { throw Failure.row }
          if let object = try JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.fragmentsAllowed]) as? [String: Any]
          {
            result["value"] = try canonical(renamedReference(object))
          }
        } else if let object = value as? [String: Any] {
          result["value"] = try renamedReference(object)
        }
      }
    }
    return result
  }

  struct ArchiveFacts: Sendable, Equatable {
    var jsonColumns: [String: Set<String>]
    var primaryKeys: [String: [String]]
    var encodedJSONCells: [String: [String]]
    var nativeSQLNullCells: [String: [String]]
    var nativeThreadChoices: [String]
  }

  static func canonical(_ object: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }

  private static func identity(_ row: [String: Any], keys: [String]) throws -> [String] {
    try keys.map { key in
      if let text = row[key] as? String { return text }
      if let number = row[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        return number.stringValue
      }
      throw Failure.row
    }
  }

  private static func taggedJSON(_ row: [String: Any], keys: [String], columns: Set<String>) throws -> String
  {
    var cells: [String: Any] = [:]
    for column in columns {
      guard let value = row[column], value is String || value is NSNull else { throw Failure.row }
      cells[column] = value
    }
    return try canonical(["identity": identity(row, keys: keys), "cells": cells])
  }

  static func archiveFacts(_ c: PostgresConnection) throws -> ArchiveFacts {
    var json: [String: Set<String>] = [:], keys: [String: [String]] = [:]
    for row in try c.execute(
      "SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public' AND data_type IN ('json','jsonb')"
    ).rows {
      guard let table = row.text("table_name"), let column = row.text("column_name") else {
        throw Failure.schema
      }
      json[table, default: []].insert(column)
    }
    for row in try c.execute(
      """
      SELECT t.relname AS table_name,a.attname AS column_name
      FROM pg_index i JOIN pg_class t ON t.oid=i.indrelid JOIN pg_namespace n ON n.oid=t.relnamespace
      JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(number,position) ON true
      JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=k.number
      WHERE n.nspname='public' AND i.indisprimary ORDER BY t.relname,k.position
      """
    ).rows {
      guard let table = row.text("table_name"), let column = row.text("column_name") else {
        throw Failure.schema
      }
      keys[table, default: []].append(column)
    }
    var encoded: [String: [String]] = [:], nulls: [String: [String]] = [:]
    for (table, columns) in json {
      guard let primary = keys[table], !primary.isEmpty else { throw Failure.schema }
      let fields =
        primary.map { Rows.quote($0) + "::text AS " + Rows.quote($0) }
        + columns.sorted().map { "(" + Rows.quote($0) + " IS NULL)::text AS " + Rows.quote("null:" + $0) }
      nulls[table] = try c.execute("SELECT " + fields.joined(separator: ",") + " FROM " + Rows.quote(table))
        .rows.map { row in
          let owner = try primary.map { name -> String in
            guard let value = row.text(name) else { throw Failure.row }
            return value
          }
          var values: [String: Any] = [:]
          for name in columns {
            guard let value = row.text("null:" + name) else { throw Failure.row }
            values[name] = value
          }
          return try canonical(["identity": owner, "cells": values])
        }.sorted()
      let nativeFields = Set(primary).union(columns).sorted().map {
        Rows.quote($0) + "::text AS " + Rows.quote($0)
      }
      encoded[table] = try c.execute(
        "SELECT " + nativeFields.joined(separator: ",") + " FROM " + Rows.quote(table)
      ).rows.map { row in
        var cells: [String: Any] = [:]
        for name in Set(primary).union(columns) {
          // Source primary IDs are TEXT except the change counter. Keep its exact decimal spelling.
          cells[name] = row.text(name).map { $0 as Any } ?? NSNull()
        }
        return try taggedJSON(cells, keys: primary, columns: columns)
      }.sorted()
    }
    let choices = try c.execute(
      "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='threads' AND column_name IN ('model','permission')"
    ).rows
    var threadChoices: [String] = []
    if !choices.isEmpty {
      guard choices.count == 2 else { throw Failure.schema }
      threadChoices = try c.execute(
        #"SELECT id::text AS id, model::text AS model, permission::text AS permission, (model IS NULL)::text AS "modelSQLNull", (permission IS NULL)::text AS "permissionSQLNull" FROM threads"#
      ).rows.map { row in
        var values: [String: Any] = [:]
        for name in ["id", "model", "permission", "modelSQLNull", "permissionSQLNull"] {
          values[name] = row.text(name).map { $0 as Any } ?? NSNull()
        }
        return try taggedJSON(
          values, keys: ["id"], columns: ["model", "permission", "modelSQLNull", "permissionSQLNull"])
      }.sorted()
    }
    return ArchiveFacts(
      jsonColumns: json, primaryKeys: keys, encodedJSONCells: encoded,
      nativeSQLNullCells: nulls, nativeThreadChoices: threadChoices)
  }

  /// Compare only source-existing JSON cells, keyed by their original SQL primary IDs.
  /// Cell text stays opaque, so SQL NULL, jsonb null and out-of-Double-range numbers remain distinct.
  static func requireNativeJSONRetained(
    _ before: ArchiveFacts, after: ArchiveFacts, tables: [String]
  ) throws {
    func cells(_ values: [String], retaining: Set<String>) throws -> [String: Data] {
      var result: [String: Data] = [:]
      for text in values {
        guard let entry = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let identity = entry["identity"] as? [String], let original = entry["cells"] as? [String: Any],
          retaining.isSubset(of: Set(original.keys))
        else { throw Failure.row }
        let key = try canonical(identity)
        guard result[key] == nil else { throw Failure.row }
        result[key] = Data(try canonical(original.filter { retaining.contains($0.key) }).utf8)
      }
      return result
    }
    if tables.contains("threads") {
      let fields: Set<String> = ["model", "permission", "modelSQLNull", "permissionSQLNull"]
      let original = try cells(before.nativeThreadChoices, retaining: fields)
      let current = try cells(after.nativeThreadChoices, retaining: fields)
      for (id, value) in original { guard current[id] == value else { throw Failure.row } }
    }
    for table in tables {
      guard let columns = before.jsonColumns[table] else { continue }
      let destination = currentTable(old: table)
      guard let afterColumns = after.jsonColumns[destination], columns.isSubset(of: afterColumns),
        before.primaryKeys[table] == after.primaryKeys[destination]
      else { throw Failure.schema }
      let original = try cells(before.encodedJSONCells[table] ?? [], retaining: columns)
      let current = try cells(after.encodedJSONCells[destination] ?? [], retaining: columns)
      for (id, value) in original { guard current[id] == value else { throw Failure.row } }
      let originalNull = try cells(before.nativeSQLNullCells[table] ?? [], retaining: columns)
      let currentNull = try cells(after.nativeSQLNullCells[destination] ?? [], retaining: columns)
      for (id, value) in originalNull { guard currentNull[id] == value else { throw Failure.row } }
    }
  }

  /// The original ledger is the authority for a preservation comparison, even for an empty store.
  struct PreservationPrefix {
    let names: [String]
    var count: Int { names.count }
    fileprivate init(names: [String]) { self.names = names }
  }

  static func preservationPrefix(_ originalNames: [String], expectedCount: Int) throws -> PreservationPrefix {
    guard (8...17).contains(expectedCount), originalNames.count == expectedCount,
      Set(originalNames).count == expectedCount,
      originalNames == Array(migrations.prefix(expectedCount))
    else { throw Failure.canonicalSet }
    return PreservationPrefix(names: originalNames)
  }

  static func ledgerNames(_ originalRows: [String: [String]]) throws -> [String] {
    guard let ledger = originalRows["schemaMigrations"] else { throw Failure.canonicalSet }
    return try ledger.map { text in
      guard let row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let name = row["name"] as? String, row["appliedAt"] is String
      else { throw Failure.canonicalSet }
      return name
    }.sorted()
  }

  private static let introduction: [String: [String: Int]] = [
    "connections": [
      "models": 9, "commands": 14, "peerProfile": 17, "agentId": 17,
      "authMode": 17, "authHeaderName": 17, "protocolRetiredAt": 17, "protocolRetiredReason": 17,
    ],
    "turns": ["openWork": 16, "origin": 16],
    "threads": ["model": 9, "permission": 9], "hubLink": ["ownedAs": 10],
  ]

  static func introducedColumns(after source: PreservationPrefix, table: String) -> [String] {
    (introduction[currentTable(old: table)] ?? [:]).filter { $0.value > source.count }.keys.sorted()
  }

  static func projectionColumns(after source: PreservationPrefix, table: String) -> [String] {
    introducedColumns(after: source, table: table)
  }

  /// Boundaries come from the validated ledger, never the first row or the comparison target.
  static func preservationPrefix(_ raw: PostgresConnection, expectedCount: Int) throws -> PreservationPrefix {
    let source = try preservationPrefix(Migrator.recorded(raw), expectedCount: expectedCount)
    var boundaries = introduction
    boundaries["viewSettings"] = ["density": 15]
    for (table, columns) in boundaries {
      let present = Set(
        try raw.execute(
          "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1",
          [table]
        ).rows.compactMap { $0.text("column_name") })
      for (column, since) in columns {
        guard present.contains(column) == (since <= source.count) else { throw Failure.schema }
      }
    }
    let tables = Set(
      try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
        .rows.compactMap { $0.text("tablename") })
    let sourceTables =
      source.count >= 13
      ? viewSettingsDataTables
      : source.count >= 12
        ? appFolderDataTables
        : source.count >= 11 ? legacyDataTables.map { currentTable(old: $0) } : legacyDataTables
    let expectedTables =
      sourceTables + (source.count == 17 ? protocolTables : [])
      + ["schemaMigrations", "hubLink"]
    guard tables == Set(expectedTables) else { throw Failure.schema }
    for table in protocolTables {
      guard tables.contains(table) == (source.count == 17) else { throw Failure.schema }
    }
    guard tables.contains("appFolders") == (source.count >= 12),
      tables.contains("viewSettings") == (source.count >= 13)
    else { throw Failure.schema }
    return source
  }

  /// Verify each introduced cell against its SQL default on the retained original ID before subtraction.
  /// A jsonb null yields is_null=false and text="null" and must refuse.
  static func requireIntroducedSQLDefaults(
    _ raw: PostgresConnection, source: PreservationPrefix, table: String, originalRows: [String]
  ) throws {
    _ = try preservationPrefix(raw, expectedCount: 17)
    let destination = currentTable(old: table)
    let columns = introducedColumns(after: source, table: table)
    guard !columns.isEmpty else { return }
    let key: String
    switch destination {
    case "connections", "threads", "turns", "hubLink": key = "id"
    default: throw Failure.schema
    }
    var ids: Set<String> = []
    for text in originalRows {
      let id = try rowIdentifier(text, key: key)
      guard ids.insert(id).inserted
      else { throw Failure.row }
      for column in columns {
        let found = try raw.execute(
          "SELECT (\(Rows.quote(column)) IS NULL)::text AS is_null, \(Rows.quote(column))::text AS value FROM \(Rows.quote(destination)) WHERE \(Rows.quote(key))=$1",
          [id]
        ).rows
        let expectsZero = destination == "turns" && column == "openWork"
        guard found.count == 1, found[0].text("is_null") == (expectsZero ? "false" : "true"),
          found[0].text("value") == (expectsZero ? "0" : nil)
        else { throw Failure.row }
      }
    }
  }

  /// Locate one fixed top-level primary key without decoding opaque JSON numbers in other cells.
  static func rowIdentifier(_ text: String, key: String) throws -> String {
    let bytes = Array(text.utf8)
    guard bytes.first == 123, bytes.last == 125 else { throw Failure.row }
    var i = 0, depth = 0, found: String?
    func stringEnd(_ start: Int) throws -> Int {
      var end = start + 1
      while end < bytes.count {
        if bytes[end] == 92 { end += 2; continue }
        if bytes[end] == 34 { return end + 1 }
        end += 1
      }
      throw Failure.row
    }
    while i < bytes.count {
      if bytes[i] == 34 {
        let end = try stringEnd(i)
        if depth == 1 {
          let name =
            try JSONSerialization.jsonObject(with: Data(bytes[i..<end]), options: [.fragmentsAllowed])
            as? String
          var colon = end
          while colon < bytes.count, [9, 10, 13, 32].contains(bytes[colon]) { colon += 1 }
          if colon < bytes.count, bytes[colon] == 58, name == key {
            guard found == nil else { throw Failure.row }
            var start = colon + 1
            while start < bytes.count, [9, 10, 13, 32].contains(bytes[start]) { start += 1 }
            guard start < bytes.count else { throw Failure.row }
            if bytes[start] == 34 {
              let stop = try stringEnd(start)
              found =
                try JSONSerialization.jsonObject(
                  with: Data(bytes[start..<stop]), options: [.fragmentsAllowed]) as? String
            } else {
              var stop = start
              while stop < bytes.count, (48...57).contains(bytes[stop]) { stop += 1 }
              guard stop > start else { throw Failure.row }
              var delimiter = stop
              while delimiter < bytes.count, [9, 10, 13, 32].contains(bytes[delimiter]) { delimiter += 1 }
              guard delimiter < bytes.count, [44, 125].contains(bytes[delimiter]) else { throw Failure.row }
              found = String(decoding: bytes[start..<stop], as: UTF8.self)
            }
          }
        }
        i = end; continue
      }
      if bytes[i] == 123 || bytes[i] == 91 { depth += 1 }
      if bytes[i] == 125 || bytes[i] == 93 { depth -= 1 }
      i += 1
    }
    guard depth == 0, let found else { throw Failure.row }
    return found
  }
}
