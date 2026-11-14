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
    "0014_connection_commands", "0015_density", "0016_agent_protocol",
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
    var nativeSQLNullCells: [String: [String]]
    var nativeThreadChoices: [String]
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
    // Through10 project names;11 environments;12 appFolders;13 viewSettings;14 commands;15 density;16 AP tables.
    // Never infer a smaller schema from missing tables; unknown or absent tables are failures.
    let baseTables =
      canonicalPrefixCount >= 13
      ? viewSettingsDataTables
      : canonicalPrefixCount >= 12
        ? appFolderDataTables
        : (canonicalPrefixCount >= 11 ? legacyDataTables.map { currentTable(old: $0) } : legacyDataTables)
    let expectedData = baseTables + (canonicalPrefixCount == 16 ? protocolTables : [])
    var headerFields: Set<String> = [
      "format", "version", "at", "purpose", "migrations", "requiredTables", "sourceContextTables",
    ]
    if canonicalPrefixCount == 16 { headerFields.insert("protocolSchema") }
    guard (8...16).contains(canonicalPrefixCount),
      expectedMigrations == Array(migrations.prefix(canonicalPrefixCount)),
      Set(expectedRows.keys) == Set(expectedData + expectedContext),
      Set(header.keys) == headerFields,
      canonicalPrefixCount != 16 || header["protocolSchema"] as? String == "generation_epochs_v1",
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
        let exactCells = encoded.map { Data($0.utf8) } == facts.encodedJSONCells[table]?.map { Data($0.utf8) }
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
  /// The original ledger is the authority for a preservation comparison, even for an empty store.
  struct PreservationPrefix {
    let names: [String]
    var count: Int { names.count }
    fileprivate init(names: [String]) { self.names = names }
  }
  static func preservationPrefix(_ originalNames: [String], expectedCount: Int) throws -> PreservationPrefix {
    guard (8...16).contains(expectedCount), originalNames.count == expectedCount,
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
      "models": 9, "commands": 14, "peerProfile": 16, "agentId": 16,
      "authMode": 16, "authHeaderName": 16, "protocolRetiredAt": 16, "protocolRetiredReason": 16,
    ],
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
      sourceTables + (source.count == 16 ? protocolTables : [])
      + ["schemaMigrations", "hubLink"]
    guard tables == Set(expectedTables) else { throw Failure.schema }
    for table in protocolTables {
      guard tables.contains(table) == (source.count == 16) else { throw Failure.schema }
    }
    guard tables.contains("appFolders") == (source.count >= 12),
      tables.contains("viewSettings") == (source.count >= 13)
    else { throw Failure.schema }
    return source
  }
  /// Prove each new cell is native SQL NULL on each retained original ID before subtraction.
  /// A jsonb null yields is_null=false and text="null" and must refuse.
  static func requireIntroducedSQLNull(
    _ raw: PostgresConnection, source: PreservationPrefix, table: String, originalRows: [String]
  ) throws {
    _ = try preservationPrefix(raw, expectedCount: 16)
    let destination = currentTable(old: table)
    let columns = introducedColumns(after: source, table: table)
    guard !columns.isEmpty else { return }
    let key: String
    switch destination {
    case "connections", "threads", "hubLink": key = "id"
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
        guard found.count == 1, found[0].text("is_null") == "true", found[0].text("value") == nil
        else { throw Failure.row }
      }
    }
  }
  /// Native text facts are independent from whole-row JSON and distinguish SQL NULL from text.
  struct NativeTextCell: Equatable {
    let isNull: Bool
    let bytes: Data?
    init(_ text: String?) { isNull = text == nil; bytes = text.map { Data($0.utf8) } }
  }
  struct DensityFacts {
    let source: PreservationPrefix
    let rows: [String: [String: NativeTextCell]]
  }
  enum DensityPath: Equatable { case nativeMigration, archiveRestore }
  static func densityFacts(_ raw: PostgresConnection, source: PreservationPrefix) throws -> DensityFacts {
    _ = try preservationPrefix(raw, expectedCount: source.count)
    guard source.count >= 13 else { return DensityFacts(source: source, rows: [:]) }
    let columns = ["quietThreads"] + (source.count >= 15 ? ["density"] : [])
    let fields = columns.flatMap { column in
      [
        "(" + Rows.quote(column) + " IS NULL)::text AS " + Rows.quote("null:" + column),
        Rows.quote(column) + "::text AS " + Rows.quote(column),
      ]
    }
    var result: [String: [String: NativeTextCell]] = [:]
    for row in try raw.execute(
      "SELECT id::text AS id," + fields.joined(separator: ",") + " FROM \"viewSettings\" ORDER BY id"
    ).rows {
      guard let id = row.text("id"), result[id] == nil else { throw Failure.row }
      var cells: [String: NativeTextCell] = [:]
      for column in columns {
        let cell = NativeTextCell(row.text(column))
        guard row.text("null:" + column) == (cell.isNull ? "true" : "false") else { throw Failure.row }
        cells[column] = cell
      }
      result[id] = cells
    }
    return DensityFacts(source: source, rows: result)
  }
  /// This literal table is TEST-owned. Native migration runs SQL15; raw archive restore does not.
  static func expectedDensityCells(
    _ cells: [String: NativeTextCell], source: PreservationPrefix, path: DensityPath
  ) throws -> [String: NativeTextCell] {
    guard let quiet = cells["quietThreads"] else { throw Failure.row }
    if source.count >= 15 {
      guard cells["density"] != nil else { throw Failure.row }
      return cells
    }
    var result = cells
    result["density"] = NativeTextCell(nil)
    if path == .nativeMigration {
      if quiet.bytes == Data("small".utf8) {
        result["quietThreads"] = NativeTextCell("shown"); result["density"] = NativeTextCell("normal")
      } else if quiet.bytes == Data("tiny".utf8) {
        result["quietThreads"] = NativeTextCell("shown"); result["density"] = NativeTextCell("dense")
      } else if quiet.bytes == Data("collapsed".utf8) || quiet.bytes == Data("hidden".utf8) {
        result["density"] = NativeTextCell("normal")
      }
    }
    return result
  }
  static func requireDensity(
    _ raw: PostgresConnection, original: DensityFacts, path: DensityPath, targetCount: Int = 16
  ) throws {
    guard targetCount == 15 || targetCount == 16 else { throw Failure.canonicalSet }
    let current = try preservationPrefix(raw, expectedCount: targetCount)
    let actual = try densityFacts(raw, source: current)
    guard Set(actual.rows.keys) == Set(original.rows.keys) else { throw Failure.row }
    for (id, cells) in original.rows {
      let expected = try expectedDensityCells(cells, source: original.source, path: path)
      guard actual.rows[id] == expected else { throw Failure.row }
    }
  }
  /// A separate expected view row retains every source field; only SQL15's quiet rewrite is applied.
  /// No opaque JSON cell is decoded by this viewSettings-only helper.
  static func expectedViewRows(_ rows: [String], facts: DensityFacts, path: DensityPath) throws -> [String] {
    try rows.map { text in
      guard var row = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
        let id = row["id"] as? String, let cells = facts.rows[id]
      else { throw Failure.row }
      let expected = try expectedDensityCells(cells, source: facts.source, path: path)
      guard let quiet = expected["quietThreads"] else { throw Failure.row }
      row["quietThreads"] = quiet.bytes.map { String(decoding: $0, as: UTF8.self) as Any } ?? NSNull()
      return try canonical(row)
    }.sorted()
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
  static func projectedRows(
    _ c: PostgresConnection, table: String, source: PreservationPrefix, originalRows: [String]
  ) throws -> [String] {
    try requireIntroducedSQLNull(c, source: source, table: table, originalRows: originalRows)
    let columns = projectionColumns(after: source, table: table)
    let expression = columns.isEmpty ? "to_jsonb(t)" : "to_jsonb(t) - $1::text[]"
    let params: [String?] = columns.isEmpty ? [] : ["{" + columns.joined(separator: ",") + "}"]
    return try c.execute("SELECT (\(expression))::text AS row FROM \(Rows.quote(table)) t ORDER BY 1", params)
      .rows.compactMap { $0.text("row") }
  }
  static func assertCurrentPreservesOld(_ c: PostgresConnection, oldRows: [String: [String]]) throws {
    let source = try preservationPrefix(ledgerNames(oldRows), expectedCount: 8)
    var currentRows: [String: [String]] = [:]
    for table in try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap({
      $0.text("tablename")
    }) {
      let oldName =
        oldRows[table] == nil
        ? (table == "environments" ? "projects" : table == "environmentFolders" ? "projectFolders" : table)
        : table
      currentRows[table] = try projectedRows(
        c, table: table, source: source, originalRows: oldRows[oldName] ?? [])
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
    if oldRows["viewSettings"] == nil { #expect(currentRows["viewSettings"]?.isEmpty == true) }
    let oldLedger = try #require(oldRows[Migrator.table])
    let currentLedger = try #require(currentRows[Migrator.table])
    func names(_ rows: [String]) throws -> [String] {
      try rows.map { text in
        try #require(
          (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["name"] as? String)
      }.sorted()
    }
    let oldNames = try names(oldLedger)
    guard (8...16).contains(oldNames.count),
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
