import CoreFoundation
import Foundation
import WorkspaceProtocol

/// The fixed local archive contract, not an author protocol or a general JSON serializer.
enum WorkspaceArchive {
  static let format = "b4app-export"
  static let version = 4
  static let protocolSchema = "generation_epochs_v1"
  static let dataTables = [
    "localServers", "environments", "environmentFolders", "connections", "threads", "appFolders", "turns",
    "displayItems",
    "runtimeRequests", "drafts", "devices", "changes", "columnClocks", "settings", "usageReadings",
    "tokenUsage", "connectionUsage", "threadDeletes", "protocolSubscriptions", "protocolRunSegments",
    "protocolOperations", "protocolGrantSecrets", "protocolGrants", "protocolPromptAnswers",
    "protocolHistoryAnchors",
  ]
  static let contextTables = [Migrator.table, "hubLink"]
  static let legacyTables = [
    "localServers", "projects", "projectFolders", "connections", "threads", "turns", "displayItems",
    "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
  ]
  static let migrations = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay", "0006_usage",
    "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice", "0010_owned_rows",
    "0011_environments", "0012_app_folders", "0013_agent_protocol",
  ]
  enum Rejection: Error { case invalid, future, joined, notEmpty }
  struct Schema {
    let migrations: [String]
    let data: [String]
    let context: [String]
    var tables: [String] { context + data }
  }
  // Fixed inventory from bundled0001–0013 column declarations; no SQL parser runs in production.
  // Missing/unknown columns fail closed rather than silently discarding owner obligations.
  private static let currentColumns: [String: String] = [
    "appFolders": "path threadId createdAt",
    "changes": "seq deviceId wall table rowId op column value synced hlc",
    "columnClocks": "table rowId column hlc",
    "connectionUsage": "connectionId reading tokens updatedAt",
    "connections":
      "id kind label enabled profileRevision target routeKey b4Mode localServerId authReference nativeScope capabilities status authStatus createdAt updatedAt environmentId models peerProfile agentId authMode authHeaderName protocolRetiredAt protocolRetiredReason",
    "devices": "id name createdAt",
    "displayItems": "id threadId turnId nativeItemId role type payload sequence provenance createdAt",
    "drafts": "threadId text updatedAt",
    "hubLink":
      "id url deviceId deviceName tokenRef orgSlug username cursor lastPushAt lastError joinedAt ownedAs",
    "localServers":
      "id name projectPath nodePath cliPath cliVersion launchMode envFilePath requestedPort actualPort generation pid processStartedAt ownershipVerified health statusMessage routes logPath createdAt updatedAt",
    "environmentFolders": "id environmentId path createdAt",
    "environments": "id name manual createdAt updatedAt",
    "protocolGrantSecrets": "reference connectionId threadId material createdAt",
    "protocolGrants":
      "threadId pausedGeneration namespace interruptId proposalHash connectionId grantReference disposition updatedAt",
    "protocolHistoryAnchors":
      "threadId generation anchor connectionId coverage revision nextBefore updatedAt",
    "protocolOperations":
      "operationId connectionId threadId kind operationThreadId targetRunId payload grantReferences expectations fingerprint status acceptedRunId receipt createdAt updatedAt",
    "protocolPromptAnswers":
      "threadId pausedGeneration namespace interruptId proposalHash connectionId answer status updatedAt",
    "protocolRunSegments":
      "connectionId threadId identityEpochKind identityEpochId namespace nativeRunId rootRunId predecessorRunId localTurnId submissionId facts updatedAt",
    "protocolSubscriptions":
      "threadId connectionId nativeThreadId generation localObservationEpoch channels namespaces appliedEventId appliedSeq coverage updatedAt",
    "runtimeRequests":
      "id nativeRequestId threadId turnId adapterGeneration kind state payload createdAt updatedAt",
    "schemaMigrations": "name appliedAt",
    "settings": "key value",
    "threadDeletes": "threadId state attempts nextAttemptAt lastError updatedAt",
    "threads":
      "id connectionId nativeThreadId nativeScope title context pinned archived continuity createdAt updatedAt environmentId readTurnId userDeletedAt model permission",
    "tokenUsage": "turnId connectionId recordedAt totalTokens",
    "turns": "id threadId operationId nativeTurnId inputRef status submission outcome createdAt updatedAt",
    "usageReadings": "connectionId reading observedAt",
  ]
  private static let tableSince: [String: Int] = [
    "appFolders": 12,
    "changes": 2,
    "columnClocks": 4,
    "connectionUsage": 7,
    "connections": 1,
    "devices": 2,
    "displayItems": 1,
    "drafts": 1,
    "hubLink": 3,
    "localServers": 1,
    "environmentFolders": 4,
    "environments": 4,
    "protocolGrantSecrets": 13,
    "protocolGrants": 13,
    "protocolHistoryAnchors": 13,
    "protocolOperations": 13,
    "protocolPromptAnswers": 13,
    "protocolRunSegments": 13,
    "protocolSubscriptions": 13,
    "runtimeRequests": 1,
    "schemaMigrations": 0,
    "settings": 5,
    "threadDeletes": 8,
    "threads": 1,
    "tokenUsage": 6,
    "turns": 1,
    "usageReadings": 6,
  ]
  private static let columnSince: [String: [String: Int]] = [
    "changes": ["hlc": 4],
    "connections": [
      "environmentId": 5, "models": 9, "peerProfile": 13, "agentId": 13, "authMode": 13, "authHeaderName": 13,
      "protocolRetiredAt": 13, "protocolRetiredReason": 13,
    ],
    "hubLink": ["ownedAs": 10],
    "threads": ["environmentId": 4, "readTurnId": 4, "userDeletedAt": 8, "model": 9, "permission": 9],
  ]
  static func schema(_ names: [String]) throws -> Schema {
    guard names.count <= migrations.count else { throw Rejection.future }
    guard names == Array(migrations.prefix(names.count)) else { throw Rejection.future }
    let present = Set(tableSince.keys.filter { tableSince[$0]! <= names.count })
    return Schema(
      migrations: names,
      data: dataTables.filter(present.contains).map { names.count < 11 ? historicalTable($0) : $0 },
      context: contextTables.filter(present.contains))
  }
  private static func currentTable(_ table: String) -> String {
    table == "projects" ? "environments" : (table == "projectFolders" ? "environmentFolders" : table)
  }
  private static func historicalTable(_ table: String) -> String {
    table == "environments" ? "projects" : (table == "environmentFolders" ? "projectFolders" : table)
  }
  private static let associationTables: Set<String> = [
    "projectFolders", "environmentFolders", "connections", "threads",
  ]
  static func columns(_ table: String, at count: Int) throws -> Set<String> {
    let current = currentTable(table)
    guard let names = currentColumns[current], let since = tableSince[current] else {
      throw Rejection.invalid
    }
    return Set(
      names.split(separator: " ").map(String.init).filter {
        (columnSince[current]?[$0] ?? since) <= count
      }.map { count < 11 && $0 == "environmentId" && associationTables.contains(table) ? "projectId" : $0 })
  }

  /// Only relational identifiers and whole-row INSERT keys change. Column JSON values remain opaque.
  private static func currentRow(
    _ table: String, _ input: [String: Any], version: Int
  ) throws -> [String: Any] {
    var row = input
    if associationTables.contains(table), let value = row.removeValue(forKey: "projectId") {
      guard row["environmentId"] == nil else { throw Rejection.invalid }
      row["environmentId"] = value
    }
    if table == "changes" || table == "columnClocks", let stored = row["table"] as? String {
      row["table"] = currentTable(stored)
      if associationTables.contains(stored), row["column"] as? String == "projectId" {
        row["column"] = "environmentId"
      }
      if table == "changes", row["op"] as? String == "insert",
        row["column"] == nil || row["column"] is NSNull, associationTables.contains(stored)
      {
        if version >= 2, let text = row["value"] as? String {
          // Rewrite only the top-level key token, preserving nested JSON and exact number lexemes.
          row["value"] = try Line.renaming(text, "projectId", to: "environmentId")
        } else if let image = row["value"] as? [String: Any] {
          var renamed = image
          if let value = renamed.removeValue(forKey: "projectId") {
            guard renamed["environmentId"] == nil else { throw Rejection.invalid }
            renamed["environmentId"] = value
          }
          row["value"] = renamed
        }
      }
    }
    return row
  }
  /// Infer only relational naming, never keys inside an opaque column update.
  private static func legacyFamilies(table: String, row: [String: Any], version: Int) throws -> Set<String> {
    var result: Set<String> = []
    func tableName(_ name: String) {
      if name == "projects" || name == "projectFolders" { result.insert("projectId") }
      if name == "environments" || name == "environmentFolders" || name == "appFolders" {
        result.insert("environmentId")
      }
    }
    tableName(table)
    if associationTables.contains(table) {
      for key in ["projectId", "environmentId"] where row[key] != nil { result.insert(key) }
    }
    if table == "changes" || table == "columnClocks", let stored = row["table"] as? String {
      tableName(stored)
      if associationTables.contains(stored) {
        if let column = row["column"] as? String, ["projectId", "environmentId"].contains(column) {
          result.insert(column)
        }
        if table == "changes", row["op"] as? String == "insert",
          row["column"] == nil || row["column"] is NSNull
        {
          let keys: Set<String>
          if version >= 2, let text = row["value"] as? String {
            keys = try Line.fieldNames(text)
          } else {
            keys = Set((row["value"] as? [String: Any] ?? [:]).keys)
          }
          result.formUnion(keys.intersection(["projectId", "environmentId"]))
        }
      }
    }
    return result
  }
  static func captureSchema(_ c: PostgresConnection, present: Set<String>) throws -> Schema {
    guard try Migrator.files().map(\.name) == migrations else { throw Rejection.future }
    let schema = try schema(Migrator.recorded(c))
    guard present == Set(schema.tables) else { throw Rejection.invalid }
    if schema.migrations.count == 13 { try Migrator.validateProtocolGenerationSchema(c) }
    for table in schema.tables {
      let actual = Set(
        try c.execute(
          "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1",
          [table]
        ).rows.compactMap { $0.text("column_name") })
      guard actual == (try columns(table, at: schema.migrations.count)) else { throw Rejection.invalid }
    }
    return schema
  }
  @discardableResult
  static func write(
    _ c: PostgresConnection, schema: Schema, purpose: String, handle: FileHandle,
    headerWritten: (() throws -> Void)? = nil
  ) throws -> Int {
    func line(_ object: [String: Any]) throws {
      try handle.write(
        contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data("\n".utf8))
    }
    try ProtocolGrantProtection.verify(c)
    var header: [String: Any] = [
      "format": format, "version": version, "at": Timestamp.now(), "purpose": purpose,
      "migrations": schema.migrations, "requiredTables": schema.data, "sourceContextTables": schema.context,
    ]
    if schema.migrations.count == 13 { header["protocolSchema"] = protocolSchema }
    try line(header)
    try headerWritten?()
    var counts = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0, 0) })
    var total = 0, dataCount = 0
    for table in schema.tables {
      try ProtocolGrantProtection.verify(c)
      for row in try c.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows {
        var object: [String: Any] = [:]
        for (name, cell) in row.cells { object[name] = try WorkspaceDatabase.jsonObject(cell) }
        try line(["table": table, "row": object])
        counts[table, default: 0] += 1; total += 1
        if schema.data.contains(table) { dataCount += 1 }
      }
    }
    try ProtocolGrantProtection.verify(c)
    try line(["format": "b4app-export-end", "version": version, "rows": total, "tableRows": counts])
    return dataCount
  }
  struct Record {
    let table: String
    var row: [String: Any]
    let sequence: Int64?
  }
  struct Input {
    let version: Int
    let records: [String: [Record]]
    let nextSequence: Int64
    let clocks: [HLC]
    var dataCount: Int { records.filter { dataTables.contains($0.key) }.values.reduce(0) { $0 + $1.count } }
  }
  static func read(_ data: Data) throws -> Input {
    var lines = data.split(separator: 0x0a, omittingEmptySubsequences: false).map { Data($0) }
    guard let first = lines.first, !first.isEmpty else { throw Rejection.invalid }
    let header = try Line(first)
    guard header.object["format"] as? String == format else { throw Rejection.invalid }
    let parsedVersion = try header.integer("version") ?? 1
    guard parsedVersion >= 1 else { throw Rejection.invalid }
    guard parsedVersion <= 4 else { throw Rejection.future }
    let version = Int(parsedVersion)
    lines.removeFirst()
    var source: Schema?
    var footer: Line?
    var declared = Set(
      legacyTables + ["environments", "environmentFolders"] + (version == 3 ? ["appFolders"] : []))
    if version == 4 {
      guard data.last == 0x0a, lines.last?.isEmpty == true else { throw Rejection.invalid }
      lines.removeLast()
      guard let final = lines.popLast(), !final.isEmpty, lines.allSatisfy({ !$0.isEmpty }),
        let at = header.object["at"] as? String, !at.isEmpty,
        let purpose = header.object["purpose"] as? String, ["onDemand", "preMigration"].contains(purpose),
        let names = header.object["migrations"] as? [String],
        let dataNames = header.object["requiredTables"] as? [String],
        let contextNames = header.object["sourceContextTables"] as? [String]
      else { throw Rejection.invalid }
      let schema = try schema(names)
      var headerFields: Set<String> = [
        "format", "version", "at", "purpose", "migrations", "requiredTables", "sourceContextTables",
      ]
      if schema.migrations.count == 13 {
        headerFields.insert("protocolSchema")
        guard header.object["protocolSchema"] as? String == protocolSchema else { throw Rejection.invalid }
      }
      guard Set(header.object.keys) == headerFields else { throw Rejection.invalid }
      guard dataNames.count == Set(dataNames).count, contextNames.count == Set(contextNames).count,
        Set(dataNames).isDisjoint(with: Set(contextNames)), Set(dataNames) == Set(schema.data),
        Set(contextNames) == Set(schema.context)
      else { throw Rejection.invalid }
      source = schema; declared = Set(schema.tables)
      let end = try Line(final)
      guard Set(end.object.keys) == Set(["format", "version", "rows", "tableRows"]),
        end.object["format"] as? String == "b4app-export-end", try end.integer("version") == 4,
        try end.integer("rows") == Int64(lines.count)
      else { throw Rejection.invalid }
      footer = end
    } else {
      // Produced1–3 need no footer. Legacy extra HEADER metadata is retained compatibility;
      // provided row tables/columns are never used to silently discard a protocol obligation.
      lines.removeAll {
        String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      if let value = header.object["migrations"] {
        guard let names = value as? [String] else { throw Rejection.invalid }
        _ = try schema(names)
      }
    }
    var records: [String: [Record]] = [:]
    var relationalNames: [String: String] = [:]
    var associationName: String?
    var counts = Dictionary(uniqueKeysWithValues: declared.map { ($0, 0) })
    var maximum: Int64?
    var clocks: [HLC] = []
    for bytes in lines {
      let line = try Line(bytes)
      guard Set(line.object.keys) == Set(["table", "row"]), let table = line.object["table"] as? String,
        declared.contains(table), var row = line.object["row"] as? [String: Any], !row.isEmpty,
        let rowRange = line.fields["row"]
      else { throw Rejection.invalid }
      let fields = try line.fields(in: rowRange)  // duplicate provided columns refuse, not last-value-wins
      guard Set(fields.keys) == Set(row.keys) else { throw Rejection.invalid }
      try representable(row)
      if let source {
        guard Set(row.keys) == (try columns(table, at: source.migrations.count)) else {
          throw Rejection.invalid
        }
        let expectedFamily = source.migrations.count < 11 ? "projectId" : "environmentId"
        guard try legacyFamilies(table: table, row: row, version: version).isSubset(of: [expectedFamily])
        else {
          throw Rejection.invalid
        }
      } else {
        let historical = table == "projects" || table == "projectFolders" || row["projectId"] != nil
        let count = historical ? 10 : (table == "appFolders" ? 12 : 11)
        var allowed = try columns(table, at: count)
        if table == "connections" {
          allowed.formUnion((columnSince["connections"] ?? [:]).filter { $0.value == 13 }.keys)
        }
        guard Set(row.keys).isSubset(of: allowed) else { throw Rejection.invalid }
        let canonical = currentTable(table)
        if let previous = relationalNames[canonical], previous != table { throw Rejection.invalid }
        relationalNames[canonical] = table
        let families = try legacyFamilies(table: table, row: row, version: version)
        guard families.count <= 1 else { throw Rejection.invalid }
        if let family = families.first {
          guard associationName == nil || associationName == family else { throw Rejection.invalid }
          associationName = family
        }
        if table == "connections" {
          guard row["kind"] as? String != "agentProtocol" else { throw Rejection.invalid }
          let newFields = (columnSince["connections"] ?? [:]).filter { $0.value == 13 }.keys
          for key in newFields {
            if let value = row[key], !(value is NSNull) { throw Rejection.invalid }
          }
        }
      }
      var sequence: Int64?
      if table == "changes" {
        guard let range = fields["seq"] else { throw Rejection.invalid }
        let value = try line.integer(in: range)
        sequence = value; maximum = max(maximum ?? value, value)
        if row["hlc"] == nil, let wall = row["wall"] as? Int, let device = row["deviceId"] as? String {
          row["hlc"] = WorkspaceDatabase.wallClock(wall: wall, deviceId: device)
        }
      }
      if table == "changes" || table == "columnClocks", let raw = row["hlc"] as? String,
        let stamp = HLC(rawValue: raw)
      {
        clocks.append(stamp)
      }
      let destination = currentTable(table)
      if source.map({ $0.migrations.count < 11 }) ?? true {
        row = try currentRow(table, row, version: version)
      }
      records[destination, default: []].append(Record(table: destination, row: row, sequence: sequence))
      counts[table, default: 0] += 1
    }
    if let footer, let source {
      guard let range = footer.fields["tableRows"] else { throw Rejection.invalid }
      let fields = try footer.fields(in: range)
      guard Set(fields.keys) == declared else { throw Rejection.invalid }
      for (table, range) in fields {
        guard try footer.integer(in: range) == Int64(counts[table]!) else { throw Rejection.invalid }
      }
      let ledger = records[Migrator.table] ?? []
      let names = try ledger.map { record -> String in
        guard let name = record.row["name"] as? String, record.row["appliedAt"] is String else {
          throw Rejection.invalid
        }
        return name
      }
      guard names.sorted() == source.migrations, Set(names).count == names.count,
        (records["hubLink"] ?? []).count <= 1
      else { throw Rejection.invalid }
    }
    guard maximum != Int64.max else { throw Rejection.invalid }
    let next = max(1, (maximum ?? 0) + 1)
    return Input(version: version, records: records, nextSequence: next, clocks: clocks)
  }

  /// Representation checks only, no envelope/status/operation/prompt semantics. JSON stays opaque.
  static func representable(_ value: Any) throws {
    if let text = value as? String {
      guard !text.utf8.contains(0) else { throw Rejection.invalid }
    } else if let values = value as? [String: Any] {
      for (key, value) in values { try representable(key); try representable(value) }
    } else if let values = value as? [Any] {
      for value in values { try representable(value) }
    }
  }
  static func parameter(_ value: Any) throws -> String? {
    if value is NSNull { return nil }
    if let text = value as? String { try representable(text); return text }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
      // No Double conversion: integer NSNumber preserves the entire supported Int64 spelling.
      return number.stringValue
    }
    throw Rejection.invalid
  }

  /// Foundation parses JSON values. The lexical locator retains exact key/value ranges for integer
  /// tokens and schema-owned key renames; it does not create a second general JSON object model.
  private struct Line {
    let bytes: [UInt8]
    let object: [String: Any]
    let fields: [String: Range<Int>]
    init(_ data: Data) throws {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw Rejection.invalid
      }
      self.bytes = Array(data); self.object = object
      let located = try Self.objectFields(Array(data), in: 0..<data.count)
      self.fields = located.values
    }
    func fields(in range: Range<Int>) throws -> [String: Range<Int>] {
      try Self.objectFields(bytes, in: range).values
    }
    // Inner JSON text belongs to PostgreSQL, whose numeric range exceeds Foundation's. Locate
    // only root keys; never parse/re-encode its opaque nested values through JSONSerialization.
    static func fieldNames(_ source: String) throws -> Set<String> {
      let bytes = Array(source.utf8)
      return Set(try objectFields(bytes, in: 0..<bytes.count).keys.keys)
    }
    static func renaming(_ source: String, _ old: String, to new: String) throws -> String {
      var bytes = Array(source.utf8)
      let keys = try objectFields(bytes, in: 0..<bytes.count).keys
      guard let range = keys[old] else { return source }
      guard keys[new] == nil else { throw Rejection.invalid }
      bytes.replaceSubrange(
        range, with: try JSONSerialization.data(withJSONObject: new, options: [.fragmentsAllowed]))
      return String(decoding: bytes, as: UTF8.self)
    }
    func integer(_ key: String) throws -> Int64? {
      guard let range = fields[key] else { return nil }
      return try integer(in: range)
    }
    func integer(in range: Range<Int>) throws -> Int64 {
      let token = Array(bytes[range])
      var i = 0
      if token.first == 45 { i += 1 }
      guard i < token.count else { throw Rejection.invalid }
      let start = i
      while i < token.count, (48...57).contains(token[i]) { i += 1 }
      guard i == token.count, token[start] != 48 || i - start == 1, token != [45, 48],
        let value = Int64(String(decoding: token, as: UTF8.self))
      else { throw Rejection.invalid }
      return value
    }
    private static func objectFields(
      _ bytes: [UInt8], in range: Range<Int>
    ) throws -> (values: [String: Range<Int>], keys: [String: Range<Int>]) {
      var i = range.lowerBound
      func whitespace() { while i < range.upperBound, [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
      func stringEnd() throws -> Int {
        guard i < range.upperBound, bytes[i] == 34 else { throw Rejection.invalid }
        i += 1
        while i < range.upperBound {
          if bytes[i] == 92 { i += 2; continue }
          if bytes[i] == 34 { i += 1; return i }
          i += 1
        }
        throw Rejection.invalid
      }
      func valueEnd() throws -> Int {
        guard i < range.upperBound else { throw Rejection.invalid }
        if bytes[i] == 34 { return try stringEnd() }
        if bytes[i] == 123 || bytes[i] == 91 {
          var depth = 0
          repeat {
            if bytes[i] == 34 { _ = try stringEnd(); continue }
            if bytes[i] == 123 || bytes[i] == 91 { depth += 1 }
            if bytes[i] == 125 || bytes[i] == 93 { depth -= 1 }
            i += 1
          } while i < range.upperBound && depth > 0
          guard depth == 0 else { throw Rejection.invalid }
          return i
        }
        while i < range.upperBound, ![9, 10, 13, 32, 44, 125, 93].contains(bytes[i]) { i += 1 }
        return i
      }
      whitespace()
      guard i < range.upperBound, bytes[i] == 123 else { throw Rejection.invalid }
      i += 1; whitespace()
      var result: [String: Range<Int>] = [:], keys: [String: Range<Int>] = [:]
      if i < range.upperBound, bytes[i] == 125 {
        i += 1
      } else {
        while true {
          let keyStart = i, keyEnd = try stringEnd()
          guard
            let key = try JSONSerialization.jsonObject(
              with: Data(bytes[keyStart..<keyEnd]), options: [.fragmentsAllowed]) as? String,
            result[key] == nil
          else { throw Rejection.invalid }
          whitespace(); guard i < range.upperBound, bytes[i] == 58 else { throw Rejection.invalid }
          i += 1; whitespace(); let start = i, end = try valueEnd()
          guard start < end else { throw Rejection.invalid }
          result[key] = start..<end; keys[key] = keyStart..<keyEnd
          whitespace(); guard i < range.upperBound else { throw Rejection.invalid }
          if bytes[i] == 125 { i += 1; break }
          guard bytes[i] == 44 else { throw Rejection.invalid }
          i += 1; whitespace()
        }
      }
      whitespace(); guard i == range.upperBound else { throw Rejection.invalid }
      return (result, keys)
    }
  }
}
