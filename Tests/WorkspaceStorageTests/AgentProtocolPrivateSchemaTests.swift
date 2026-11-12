import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Schema and metadata only. No private authority value or account/runtime/service/API starts.
@Suite(.serialized) struct AgentProtocolPrivateSchemaTests {
  private struct Table: Sendable {
    let name: String
    let columns: [String]
    let json: Set<String>
    let nullable: Set<String>
    let primary: [String]
  }
  private static let subscriptions = "protocolSubscriptions"
  private static let segments = "protocolRunSegments"
  private static let operations = "protocolOperations"
  private static let grants = "protocolGrants"
  private static let answers = "protocolPromptAnswers"
  private static let history = "protocolHistoryAnchors"
  private static let credentialSchema = "protocolGrantSecrets"
  private static let tables: [Table] = [
    Table(
      name: subscriptions,
      columns: [
        "threadId", "connectionId", "nativeThreadId", "generation", "channels", "namespaces",
        "appliedEventId", "appliedSeq", "coverage", "updatedAt",
      ],
      json: ["channels", "namespaces", "coverage"],
      nullable: ["generation", "appliedEventId", "appliedSeq"], primary: ["threadId"]),
    Table(
      name: segments,
      columns: [
        "connectionId", "threadId", "namespace", "nativeRunId", "rootRunId", "predecessorRunId",
        "localTurnId", "submissionId", "facts", "updatedAt",
      ],
      json: ["namespace", "facts"],
      nullable: ["rootRunId", "predecessorRunId", "localTurnId", "submissionId"],
      primary: ["connectionId", "threadId", "namespace", "nativeRunId"]),
    Table(
      name: operations,
      columns: [
        "operationId", "connectionId", "threadId", "kind", "operationThreadId", "targetRunId",
        "payload", "grantReferences", "expectations", "fingerprint", "status", "acceptedRunId", "receipt",
        "createdAt", "updatedAt",
      ],
      json: ["payload", "grantReferences", "expectations", "receipt"],
      nullable: ["targetRunId", "acceptedRunId", "receipt"], primary: ["operationId"]),
    Table(
      name: grants,
      columns: [
        "threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash", "connectionId",
        "grantReference", "disposition", "updatedAt",
      ],
      json: ["namespace"], nullable: ["grantReference"],
      primary: ["threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash"]),
    Table(
      name: answers,
      columns: [
        "threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash", "connectionId",
        "answer", "status", "updatedAt",
      ],
      json: ["namespace", "answer"], nullable: [],
      primary: ["threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash"]),
    Table(
      name: history,
      columns: [
        "threadId", "generation", "anchor", "connectionId", "coverage", "revision", "nextBefore", "updatedAt",
      ],
      json: ["coverage"], nullable: ["nextBefore"], primary: ["threadId", "generation", "anchor"]),
    Table(
      name: credentialSchema,
      columns: ["reference", "connectionId", "threadId", "material", "createdAt"], json: [], nullable: [],
      primary: ["reference"]),
  ]
  private static var metadata: [Table] { tables.filter { $0.name != credentialSchema } }
  private static let stamp = "2026-11-09T00:00:00.000Z"
  private static let nativeThread = "11111111-1111-4111-8111-111111111111"
  private static let nativeRun = "22222222-2222-4222-8222-222222222222"
  private static let generation = "33333333-3333-4333-8333-333333333333"
  private static let interrupt = "44444444-4444-4444-8444-444444444444"

  private struct Snapshot: Equatable {
    var rows: [String: [String]]
    var sequences: [String]
  }
  private struct Fixture {
    let database: WorkspaceDatabase
    let raw: PostgresConnection
  }
  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }
  private static func withFixture(_ body: (Fixture) throws -> Void) throws {
    // Strict owned startup intent, actual helper/kernel identity and independent ACK before fixture rows.
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let root = AgentProtocolResourceFixture.temporaryDirectory + "a3-private-schema-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root)
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let raw = try connection(endpoint)
    defer {
      #expect(
        (try? raw.execute(
          "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
          [endpoint.database]
        ).rows.isEmpty) == true)
    }
    let database = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: root + "/backups")
    defer { try? database.close() }
    for suffix in ["a", "b"] {
      let profile = Connection(
        id: "connection-" + suffix, kind: .agentProtocol, label: "Fixture " + suffix,
        target: "https://example.invalid/" + suffix,
        nativeScope: #"["agent-protocol-v1","agentProtocol","https://example.invalid/\#(suffix)"]"#,
        peerProfile: .agentProtocol, agentId: "fixture-agent", authMode: ConnectionAuthMode.none,
        createdAt: stamp, updatedAt: stamp)
      _ = try database.insertConnection(profile)
      try raw.execute(
        #"INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","createdAt","updatedAt") VALUES ($1,$2,$3,$4,$5,$5)"#,
        ["thread-" + suffix, profile.id, nativeThread, profile.nativeScope, stamp])
      try raw.execute(
        #"INSERT INTO "turns" ("id","threadId","operationId","nativeTurnId","status","submission","outcome","createdAt","updatedAt") VALUES ($1,$2,$3,$4,'reconciling','unknown',NULL,$5,$5)"#,
        ["turn-" + suffix, "thread-" + suffix, "local-operation-" + suffix, nativeRun, stamp])
    }
    try body(Fixture(database: database, raw: raw))
  }
  private static func canonical(_ object: Any) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }
  private static func snapshot(_ c: PostgresConnection, publicOnly: Bool = false) throws -> Snapshot {
    let names = try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")
      .rows.compactMap { $0.text("tablename") }
    var rows: [String: [String]] = [:]
    for table in names where table != credentialSchema {
      if publicOnly && metadata.contains(where: { $0.name == table }) { continue }
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
        .rows.map { row in
          let text = try #require(row.text("row"))
          return try canonical(JSONSerialization.jsonObject(with: Data(text.utf8)))
        }.sorted()
    }
    // Credential schema is deliberately never selected as row JSON, even in failure diagnostics.
    var sequences: [String] = []
    for row in try c.execute("SELECT sequencename FROM pg_sequences WHERE schemaname='public'").rows {
      let name = try #require(row.text("sequencename"))
      let state = try #require(
        try c.execute(
          "SELECT last_value::text AS value,is_called::text AS called FROM \(Rows.quote(name))"
        ).rows.first)
      sequences.append(name + ":" + (state.text("value") ?? "NULL") + ":" + (state.text("called") ?? "NULL"))
    }
    return Snapshot(rows: rows, sequences: sequences.sorted())
  }
  private static func requireTables(_ c: PostgresConnection) throws {
    let found = Set(
      try c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")
        .rows.compactMap { $0.text("tablename") })
    try #require(Set(tables.map(\.name)).isSubset(of: found))
  }
  private static func primaryKey(_ c: PostgresConnection, table: String) throws -> [String] {
    try c.execute(
      """
      SELECT a.attname AS name FROM pg_constraint c
        CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum,ord)
        JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
        WHERE c.contype='p' AND c.conrelid=to_regclass($1) ORDER BY k.ord
      """, [Rows.quote(table)]
    ).rows.compactMap { $0.text("name") }
  }
  private static func hasForeignKey(
    _ c: PostgresConnection, table: String, source: [String], target: String, destination: [String]
  ) throws -> Bool {
    for row in try c.execute(
      """
      SELECT r.relname AS target,
        (SELECT json_agg(a.attname ORDER BY k.ord) FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum,ord)
          JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum)::text AS source,
        (SELECT json_agg(a.attname ORDER BY k.ord) FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum,ord)
          JOIN pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.attnum)::text AS destination
      FROM pg_constraint c JOIN pg_class r ON r.oid=c.confrelid
        WHERE c.contype='f' AND c.conrelid=to_regclass($1)
      """, [Rows.quote(table)]
    ).rows {
      guard row.text("target") == target, let a = row.text("source"), let b = row.text("destination") else {
        continue
      }
      if try JSONSerialization.jsonObject(with: Data(a.utf8)) as? [String] == source,
        try JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String] == destination
      {
        return true
      }
    }
    return false
  }
  private static func values(_ table: String) -> [String: String?] {
    switch table {
    case subscriptions:
      return [
        "threadId": "thread-a", "connectionId": "connection-a", "nativeThreadId": nativeThread,
        "generation": nil, "channels": #"["messages"]"#, "namespaces": #"[[],["branch"]]"#,
        "appliedEventId": nil,
        "appliedSeq": "7", "coverage": #"{"opaque":{"retained":true}}"#, "updatedAt": stamp,
      ]
    case segments:
      return [
        "connectionId": "connection-a", "threadId": "thread-a", "namespace": "[]", "nativeRunId": nativeRun,
        "rootRunId": nil, "predecessorRunId": nil, "localTurnId": nil, "submissionId": nil,
        "facts": #"{"opaque":[1,true,null]}"#, "updatedAt": stamp,
      ]
    case operations:
      // Fixture labels assert nonempty storage facts only, not an A5 kind/status/envelope vocabulary.
      return [
        "operationId": "upstream-operation", "connectionId": "connection-a", "threadId": "thread-a",
        "kind": "fixture-kind", "operationThreadId": nativeThread, "targetRunId": nil,
        "payload": #"{"input":{"opaque":[true,null,"fixture"]}}"#, "grantReferences": "[]",
        "expectations": #"{"opaque":true}"#, "fingerprint": "fixture-fingerprint", "status": "fixture-status",
        "acceptedRunId": nil, "receipt": nil, "createdAt": stamp, "updatedAt": stamp,
      ]
    case grants:
      return [
        "threadId": "thread-a", "pausedGeneration": generation, "namespace": "[]", "interruptId": interrupt,
        "proposalHash": "fixture-proposal-hash", "connectionId": "connection-a", "grantReference": nil,
        "disposition": "fixture-disposition", "updatedAt": stamp,
      ]
    case answers:
      return [
        "threadId": "thread-a", "pausedGeneration": generation, "namespace": "[]", "interruptId": interrupt,
        "proposalHash": "fixture-proposal-hash", "connectionId": "connection-a",
        "answer": #"{"choice":"fixture"}"#, "status": "fixture-status", "updatedAt": stamp,
      ]
    case history:
      return [
        "threadId": "thread-a", "generation": generation, "anchor": "opaque-anchor",
        "connectionId": "connection-a",
        "coverage": #"{"opaque":[]}"#, "revision": "opaque-revision", "nextBefore": nil, "updatedAt": stamp,
      ]
    default: preconditionFailure("No credential-value fixture exists.")
    }
  }
  private static func seedMetadata(_ c: PostgresConnection) throws {
    try requireTables(c)
    for spec in metadata {
      let row = values(spec.name)
      let statement = Rows.insert(spec.name, row.keys.sorted().map { (column: $0, param: row[$0]!) })
      try c.execute(statement.sql, statement.params)
    }
    #expect(
      try c.execute("SELECT count(*) AS n FROM \(Rows.quote(credentialSchema))").rows.first?.int("n") == 0)
  }
  private static func expectedRow(_ spec: Table, updatedAt: String? = nil) throws -> String {
    var row: [String: Any] = [:]
    for (key, value) in values(spec.name) {
      guard let value else { row[key] = NSNull(); continue }
      if spec.json.contains(key) {
        row[key] = try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
      } else if key == "appliedSeq" {
        row[key] = Int(value)
      } else {
        row[key] = value
      }
    }
    if let updatedAt { row["updatedAt"] = updatedAt }
    return try canonical(row)
  }
  private static func change(
    _ c: PostgresConnection, table: String, column: String, value: String?, expectedState: String? = nil
  ) throws {
    let before = try snapshot(c)
    try c.execute("BEGIN")
    var failure: (any Error)?
    var actualState: String?
    do { try c.execute("UPDATE \(Rows.quote(table)) SET \(Rows.quote(column))=$1", [value]) } catch let error
      as PostgresError
    { actualState = error.sqlState } catch { failure = error }
    // ROLLBACK before any throwing oracle; body/driver failures never leave an open transaction.
    do { try c.execute("ROLLBACK") } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
    if let expectedState {
      #expect(actualState == expectedState, "\(table).\(column)")
    } else {
      #expect(actualState == nil, "Positive storage control: \(table).\(column)")
    }
    #expect(try snapshot(c) == before)
  }

  @Test func privateContainersPersistOwnerFactsWithoutSyncOrPresentationWrites() throws {
    try Self.withFixture { fixture in
      let c = fixture.raw
      try Self.requireTables(c)
      for spec in Self.tables {
        let columns = try c.execute(
          "SELECT column_name,data_type,is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name=$1",
          [spec.name]
        ).rows
        #expect(Set(columns.compactMap { $0.text("column_name") }) == Set(spec.columns))
        for column in columns {
          let name = try #require(column.text("column_name"))
          #expect(column.text("is_nullable") == (spec.nullable.contains(name) ? "YES" : "NO"))
          let type = spec.json.contains(name) ? "jsonb" : name == "appliedSeq" ? "bigint" : "text"
          #expect(column.text("data_type") == type)
        }
        #expect(try Self.primaryKey(c, table: spec.name) == spec.primary)
        #expect(
          try Self.hasForeignKey(
            c, table: spec.name,
            source: ["threadId", "connectionId"], target: "threads", destination: ["id", "connectionId"]))
        #expect(!WorkspaceDatabase.syncedTables.contains { $0.table == spec.name })
        #expect(
          try c.execute(
            """
            SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
              WHERE t.tgrelid=to_regclass($1) AND NOT t.tgisinternal AND p.proname='b4app_record_change'
            """, [Rows.quote(spec.name)]
          ).rows.isEmpty)
      }
      #expect(
        try Self.hasForeignKey(
          c, table: Self.segments,
          source: ["localTurnId", "threadId"], target: "turns", destination: ["id", "threadId"]))
      #expect(
        try Self.hasForeignKey(
          c, table: Self.grants,
          source: ["grantReference", "threadId", "connectionId"], target: Self.credentialSchema,
          destination: ["reference", "threadId", "connectionId"]))
      // Schema only: no SELECT material, credential put/read or authority row is constructed.
      #expect(
        try c.execute("SELECT count(*) AS n FROM \(Rows.quote(Self.credentialSchema))").rows.first?.int("n")
          == 0)
      let publicBefore = try Self.snapshot(c, publicOnly: true)
      try Self.seedMetadata(c)
      let inserted = try Self.snapshot(c)
      for spec in Self.metadata { #expect(inserted.rows[spec.name] == [try Self.expectedRow(spec)]) }
      #expect(try Self.snapshot(c, publicOnly: true) == publicBefore)
      for spec in Self.metadata {
        try c.execute("UPDATE \(Rows.quote(spec.name)) SET \"updatedAt\"=$1", ["2026-11-09T00:00:01.000Z"])
      }
      let updated = try Self.snapshot(c)
      for spec in Self.metadata {
        #expect(
          updated.rows[spec.name] == [try Self.expectedRow(spec, updatedAt: "2026-11-09T00:00:01.000Z")])
      }
      #expect(try Self.snapshot(c, publicOnly: true) == publicBefore)
      #expect(
        try c.execute("SELECT count(*) AS n FROM \(Rows.quote(Self.credentialSchema))").rows.first?.int("n")
          == 0)
    }
  }

  @Test func privateOwnerLinksRejectCrossThreadConnectionAndTurn() throws {
    try Self.withFixture { fixture in
      try Self.seedMetadata(fixture.raw)
      for spec in Self.metadata {
        try Self.change(
          fixture.raw, table: spec.name, column: "connectionId", value: "connection-b", expectedState: "23503"
        )
      }
      try Self.change(
        fixture.raw, table: Self.segments, column: "localTurnId", value: "turn-b", expectedState: "23503")
      try Self.change(fixture.raw, table: Self.segments, column: "localTurnId", value: "turn-a")
    }
  }

  @Test func privateJsonAndScalarValidityMatchesOpaqueProtocolFacts() throws {
    try Self.withFixture { fixture in
      let c = fixture.raw
      try Self.seedMetadata(c)
      // 37 required text fields: each SQL NULL (23502) and empty string (23514), 74 negatives.
      for spec in Self.metadata {
        for column in spec.columns
        where !spec.json.contains(column) && !spec.nullable.contains(column) && column != "appliedSeq" {
          try Self.change(c, table: spec.name, column: column, value: nil, expectedState: "23502")
          try Self.change(c, table: spec.name, column: column, value: "", expectedState: "23514")
        }
      }
      // Nine optional identity/reference texts permit NULL, but not a present empty identity.
      for spec in Self.metadata {
        for column in spec.nullable
        where !spec.json.contains(column) && column != "appliedSeq" && column != "nextBefore" {
          try Self.change(c, table: spec.name, column: column, value: "", expectedState: "23514")
        }
      }
      // All 12 required JSON fields distinguish SQL NULL from a stored JSON null value.
      for spec in Self.metadata {
        for column in spec.json where !spec.nullable.contains(column) {
          try Self.change(c, table: spec.name, column: column, value: nil, expectedState: "23502")
        }
      }
      let malformed: [(String, String, [String])] = [
        (Self.subscriptions, "channels", ["{}", "[1]"]),
        (Self.subscriptions, "namespaces", ["{}", #"["flat"]"#, "[[1]]"]),
        (Self.segments, "namespace", ["{}", "[1]"]),
        (Self.grants, "namespace", ["{}", "[1]"]),
        (Self.answers, "namespace", ["{}", "[1]"]),
        (
          Self.operations, "grantReferences",
          ["{}", "[1]", #"[""]"#, #"["reference-without-prefix"]"#, #"["secret:"]"#]
        ),
        (Self.subscriptions, "coverage", ["[]"]),
        (Self.segments, "facts", ["[]"]),
        (Self.operations, "expectations", ["[]"]),
        (Self.operations, "receipt", ["[]"]),
        (Self.history, "coverage", ["[]"]),
        (Self.grants, "grantReference", ["reference-without-prefix", "secret:"]),
        (Self.subscriptions, "appliedSeq", ["-1"]),
      ]
      for (table, column, values) in malformed {
        for value in values {
          try Self.change(c, table: table, column: column, value: value, expectedState: "23514")
        }
      }
      // Thirteen positive controls; all changes are rolled back and exact complete snapshots compared.
      try Self.change(c, table: Self.subscriptions, column: "appliedSeq", value: nil)
      try Self.change(c, table: Self.operations, column: "receipt", value: nil)
      try Self.change(c, table: Self.operations, column: "receipt", value: #"{"opaque":true}"#)
      for table in [Self.segments, Self.grants, Self.answers] {
        try Self.change(c, table: table, column: "namespace", value: #"["branch"]"#)
      }
      let reference = try #require(SecretRef(rawValue: "secret:x"))
      try Self.change(
        c, table: Self.operations, column: "grantReferences", value: #"["\#(reference.rawValue)"]"#)
      for answer in ["{}", "[]", #""opaque answer""#, "true", "3.25", "null"] {
        try Self.change(c, table: Self.answers, column: "answer", value: answer)
      }
    }
  }
}
