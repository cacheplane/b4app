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
    "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_agent_protocol",
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
  static let dataTables = appFolderDataTables + protocolTables

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
  static let addedColumns = [
    "connections": [
      "models", "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt",
      "protocolRetiredReason",
    ],
    "threads": ["model", "permission"],
  ]
  struct ArchiveFacts: Sendable, Equatable {
    var jsonColumns: [String: Set<String>]
    var primaryKeys: [String: [String]]
    var encodedJSONCells: [String: [String]]
  }
  struct Document {
    var header: [String: Any]
    var rows: [String: [[String: Any]]]
    var rowCount: Int
  }
  static func knownFiles() throws -> [(name: String, sql: String)] {
    let files = try Migrator.files()
    guard files.map(\.name) == migrations else { throw Failure.canonicalSet }
    return files
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
    var encoded: [String: [String]] = [:]
    for (table, columns) in json {
      guard let primary = keys[table], !primary.isEmpty else { throw Failure.schema }
      encoded[table] = try c.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows.map { row in
        var cells: [String: Any] = [:]
        for name in Set(primary).union(columns) {
          // Source primary IDs are TEXT except the change counter. Keep its exact decimal spelling.
          cells[name] = row.text(name).map { $0 as Any } ?? NSNull()
        }
        return try taggedJSON(cells, keys: primary, columns: columns)
      }.sorted()
    }
    return ArchiveFacts(jsonColumns: json, primaryKeys: keys, encodedJSONCells: encoded)
  }
  static func readV4(
    _ text: String, expectedRows: [String: [String]], expectedMigrations: [String], facts: ArchiveFacts,
    canonicalPrefixCount: Int = 8
  ) throws -> Document {
    guard text.utf8.last == 10 else { throw Failure.framing }
    let pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard pieces.last?.isEmpty == true, pieces.count >= 3 else { throw Failure.framing }
    let lines = pieces.dropLast()
    func object(_ line: Substring) throws -> [String: Any] {
      guard let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
        throw Failure.framing
      }
      return value
    }
    let header = try object(try #require(lines.first)), footer = try object(try #require(lines.last))
    let expectedContext = [Migrator.table, "hubLink"]
    // Through10 project names;11 environments;12 adds appFolders;13 adds AP tables.
    // Never infer a smaller schema from missing tables; unknown or absent tables are failures.
    let baseTables =
      canonicalPrefixCount >= 12
      ? appFolderDataTables
      : (canonicalPrefixCount >= 11 ? legacyDataTables.map { currentTable(old: $0) } : legacyDataTables)
    let expectedData = baseTables + (canonicalPrefixCount == 13 ? protocolTables : [])
    guard (8...13).contains(canonicalPrefixCount),
      expectedMigrations == Array(migrations.prefix(canonicalPrefixCount)),
      Set(expectedRows.keys) == Set(expectedData + expectedContext),
      Set(header.keys)
        == Set(["format", "version", "at", "purpose", "migrations", "requiredTables", "sourceContextTables"]),
      header["format"] as? String == "b4app-export", header["version"] as? Int == 4,
      header["purpose"] as? String == "preMigration", !(header["at"] as? String ?? "").isEmpty,
      header["migrations"] as? [String] == expectedMigrations,
      header["requiredTables"] as? [String] == expectedData,
      header["sourceContextTables"] as? [String] == expectedContext,
      Set(footer.keys) == Set(["format", "version", "rows", "tableRows"]),
      footer["format"] as? String == "b4app-export-end", footer["version"] as? Int == 4,
      let counts = footer["tableRows"] as? [String: Any], Set(counts.keys) == Set(expectedRows.keys)
    else { throw Failure.framing }
    var rows: [String: [[String: Any]]] = [:], count = 0
    for line in lines.dropFirst().dropLast() {
      let entry = try object(line)
      guard Set(entry.keys) == Set(["table", "row"]), let table = entry["table"] as? String,
        expectedRows[table] != nil, let row = entry["row"] as? [String: Any]
      else { throw Failure.framing }
      rows[table, default: []].append(row); count += 1
    }
    guard footer["rows"] as? Int == count else { throw Failure.framing }
    for (table, old) in expectedRows {
      guard counts[table] as? Int == old.count, (rows[table]?.count ?? 0) == old.count else {
        throw Failure.framing
      }
      if let columns = facts.jsonColumns[table] {
        let primary = try #require(facts.primaryKeys[table])
        let encoded = try (rows[table] ?? []).map { try taggedJSON($0, keys: primary, columns: columns) }
          .sorted()
        let exactCells = encoded == facts.encodedJSONCells[table]
        // SQL NULL remains different from the JSON-text string "null",
        // keyed by owner row.
        #expect(exactCells)
      }
    }
    return Document(header: header, rows: rows, rowCount: count)
  }
  static func assertArchiveRows(_ document: Document, oldRows: [String: [String]], facts: ArchiveFacts) throws
  {
    #expect(document.rowCount == oldRows.values.reduce(0) { $0 + $1.count })
    for (table, original) in oldRows {
      let expected = try original.map { text in
        try canonical(try JSONSerialization.jsonObject(with: Data(text.utf8)))
      }.sorted()
      let actual = try (document.rows[table] ?? []).map { archived in
        var row = archived
        for column in facts.jsonColumns[table] ?? [] {
          guard let value = row[column], !(value is NSNull) else { continue }
          let text = try #require(value as? String)
          row[column] = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        }
        return try canonical(row)
      }.sorted()
      let allFieldsRetained = actual == expected
      #expect(allFieldsRetained)
    }
  }
  static func projectedRows(_ c: PostgresConnection, table: String) throws -> [String] {
    let columns = addedColumns[table] ?? []
    let expression = columns.isEmpty ? "to_jsonb(t)" : "to_jsonb(t) - $1::text[]"
    let params: [String?] = columns.isEmpty ? [] : ["{" + columns.joined(separator: ",") + "}"]
    return try c.execute("SELECT (\(expression))::text AS row FROM \(Rows.quote(table)) t ORDER BY 1", params)
      .rows.compactMap { $0.text("row") }
  }
  static func assertCurrentPreservesOld(_ c: PostgresConnection, oldRows: [String: [String]]) throws {
    var currentRows: [String: [String]] = [:]
    for table in try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap({
      $0.text("tablename")
    }) {
      currentRows[table] = try projectedRows(c, table: table)
    }
    #expect(try Migrator.recorded(c) == migrations)
    try assertCurrentLedgerAndInventory(currentRows, oldRows: oldRows)
    for (table, rows) in oldRows where table != Migrator.table {
      let currentName = currentTable(old: table)
      func normalized(_ values: [String], table: String) throws -> [String] {
        try values.map { text in
          guard let row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
          else { throw Failure.row }
          return try canonical(currentRow(table: table, row: row))
        }.sorted()
      }
      let unchanged =
        try (try #require(currentRows[currentName])).map { text in
          try canonical(JSONSerialization.jsonObject(with: Data(text.utf8)))
        }.sorted() == normalized(rows, table: table)
      #expect(unchanged)
    }
    try assertAdditionsNullAndPrivateEmpty(c)
  }
  /// Value-only inventory/ledger oracle, also usable by L1's deliberately nine-table history
  /// comparison. Account tokens/link rows retain their dedicated lifecycle assertions.
  static func assertCurrentLedgerAndInventory(
    _ currentRows: [String: [String]], oldRows: [String: [String]]
  ) throws {
    #expect(Set(currentRows.keys) == Set(dataTables + [Migrator.table, "hubLink"]))
    for table in protocolTables { #expect(currentRows[table]?.isEmpty == true) }
    if oldRows["appFolders"] == nil { #expect(currentRows["appFolders"]?.isEmpty == true) }
    let oldLedger = try #require(oldRows[Migrator.table])
    let currentLedger = try #require(currentRows[Migrator.table])
    func names(_ rows: [String]) throws -> [String] {
      try rows.map { text in
        try #require(
          (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["name"] as? String)
      }.sorted()
    }
    let oldNames = try names(oldLedger)
    guard (8...13).contains(oldNames.count),
      oldNames == Array(migrations.prefix(oldNames.count))
    else {
      throw Failure.canonicalSet
    }
    #expect(try names(currentLedger) == migrations)
    #expect(Set(oldLedger).isSubset(of: Set(currentLedger)))  // Includes every original appliedAt.
    let additions = migrations.filter { !oldNames.contains($0) }
    #expect(additions == Array(migrations.dropFirst(oldNames.count)))
    #expect(currentLedger.count == oldLedger.count + additions.count)
  }
  /// Snapshot only value facts about known columns that actually exist at this schema prefix.
  /// Checking PostgreSQL IS NOT NULL preserves SQL NULL versus jsonb's non-NULL JSON null.
  static func additiveSQLNullFacts(_ c: PostgresConnection) throws -> [String: Bool] {
    var facts: [String: Bool] = [:]
    for row in try c.execute(
      "SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('connections','threads')"
    ).rows {
      guard let table = row.text("table_name"), let column = row.text("column_name") else {
        throw Failure.schema
      }
      guard addedColumns[table]?.contains(column) == true else { continue }
      facts["\(table).\(column)"] = try c.execute(
        "SELECT 1 FROM \(Rows.quote(table)) WHERE \(Rows.quote(column)) IS NOT NULL LIMIT 1"
      ).rows.isEmpty
    }
    return facts
  }
  static func assertAdditionsNullAndPrivateEmpty(_ c: PostgresConnection) throws {
    for (table, columns) in addedColumns {
      let predicate = columns.map { Rows.quote($0) + " IS NOT NULL" }.joined(separator: " OR ")
      let allNull = try c.execute("SELECT 1 FROM \(Rows.quote(table)) WHERE \(predicate)").rows.isEmpty
      #expect(allNull)
    }
    for table in protocolTables {
      let empty = try c.execute("SELECT 1 FROM \(Rows.quote(table)) LIMIT 1").rows.isEmpty
      #expect(empty)
    }
  }
}
