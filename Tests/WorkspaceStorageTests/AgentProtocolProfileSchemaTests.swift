import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Only real private PostgreSQL storage; no account, service, provider, listener or adapter starts.
@Suite(.serialized) struct AgentProtocolProfileSchemaTests {
  private static let migration = "0016_agent_protocol"
  private static let profileColumns = [
    "peerProfile", "agentId", "authMode", "authHeaderName", "protocolRetiredAt", "protocolRetiredReason",
  ]
  private struct Snapshot: Sendable, Equatable {
    var rows: [String: [String]]
    var catalog: [String]
    var sequences: [String]
    var jsonColumns: [String: Set<String>]
  }
  private struct Fixture: Sendable {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let backup: String
    let before: Snapshot
    let archiveFacts: AgentProtocolFoundationFixture.ArchiveFacts
  }
  private enum SetupFailure: Error { case unexpectedCanonicalNine }

  private static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }

  private static func withFixture(_ body: (Fixture) throws -> Void) throws {
    // endpoint() completes strict startup-intent/live identity/runner ACK BEFORE any fixture SQL.
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil  // An external socket is not a protected backup location.
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-profile-schema-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root)
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let c = try connection(endpoint)
    defer {
      // Body-local database defers run before this; raw inspector does not use this app name.
      #expect(
        (try? c.execute(
          "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
          [endpoint.database]
        ).rows.isEmpty) == true)
    }
    let files = try Migrator.files().filter { $0.name <= "0009_thread_runtime_choice" }
    guard
      files.map(\.name) == [
        "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay", "0006_usage",
        "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
      ]
    else { throw SetupFailure.unexpectedCanonicalNine }
    try Migrator.ensureLedger(c, table: Migrator.table)
    for file in files {
      try c.execute(file.sql)
      try c.execute(
        #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,'fixture')"#, [file.name])
    }
    try c.execute(
      """
      INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt")
        VALUES ('project-old', 'Preserve project', true, 'created', 'updated');
      INSERT INTO "projectFolders" ("id", "projectId", "path", "createdAt")
        VALUES ('folder-old', 'project-old', '/fixture/project', 'created');
      INSERT INTO "connections" ("id", "kind", "label", "target", "routeKey", "b4Mode",
        "authReference", "nativeScope", "projectId", "capabilities", "status", "authStatus",
        "createdAt", "updatedAt") VALUES
        ('legacy-b4', 'b4', 'Old endpoint', 'https://example.invalid/prefix', '/chat#agent', 'remote',
         'secret:legacy-reference', 'https://example.invalid', 'project-old', '{}', 'ready',
         'authenticated', 'created', 'updated'),
        ('codex-old', 'codex', 'Codex', '/fixture/codex', NULL, NULL, NULL, 'account:codex', NULL,
         '{}', 'ready', 'authenticated', 'created', 'updated'),
        ('claude-old', 'claude', 'Claude', '/fixture/claude', NULL, NULL, NULL, 'account:claude', NULL,
         '{}', 'ready', 'authenticated', 'created', 'updated');
      INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "nativeScope", "title",
        "context", "pinned", "archived", "projectId", "readTurnId", "createdAt", "updatedAt")
        VALUES ('thread-old', 'legacy-b4', 'reused-native-id', 'https://example.invalid', 'History',
        '/chat#agent', true, true, 'project-old', 'turn-old', 'created', 'updated');
      INSERT INTO "turns" ("id", "threadId", "operationId", "nativeTurnId", "status", "submission",
        "outcome", "createdAt", "updatedAt") VALUES
        ('turn-old', 'thread-old', 'operation-old', '1', 'reconciling', 'unknown', NULL,
         'created', 'updated');
      INSERT INTO "displayItems" ("id", "threadId", "turnId", "nativeItemId", "role", "type",
        "payload", "sequence", "provenance", "createdAt") VALUES
        ('item-old', 'thread-old', 'turn-old', 'item-native-old', 'assistant', 'agentMessage',
         '{"text":"Partial output 🌱","opaque":{"unknown":true}}', 0, 'cache', 'created');
      INSERT INTO "runtimeRequests" ("id", "nativeRequestId", "threadId", "turnId",
        "adapterGeneration", "kind", "state", "payload", "createdAt", "updatedAt") VALUES
        ('request-old', '7', 'thread-old', 'turn-old', 3, 'command_approval', 'pending',
         '{"command":"fixture-only"}', 'created', 'updated');
      INSERT INTO "drafts" ("threadId", "text", "updatedAt")
        VALUES ('thread-old', 'Deliberately unsent draft', 'updated');

      """)
    _ = try AgentProtocolFoundationFixture.preservationPrefix(c, expectedCount: 9)
    try body(
      Fixture(
        endpoint: endpoint, raw: c, backup: root + "/backups/" + endpoint.database,
        before: snapshot(c), archiveFacts: AgentProtocolFoundationFixture.archiveFacts(c)))
  }

  private static func normalized(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
  }
  private static func snapshot(_ c: PostgresConnection) throws -> Snapshot {
    let tables = try c.execute(
      "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows.compactMap { $0.text("tablename") }
    var rows: [String: [String]] = [:]
    for table in tables {
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
        .rows.map { row in
          try normalized(JSONSerialization.jsonObject(with: Data(try #require(row.text("row")).utf8)))
        }.sorted()
    }
    var catalog: [String] = []
    for sql in [
      """
      SELECT 'column:'||table_name||':'||column_name||':'||data_type||':'||is_nullable||':'||
        coalesce(column_default,'') AS fact FROM information_schema.columns WHERE table_schema='public'
      """,
      """
      SELECT 'constraint:'||r.relname||':'||c.conname||':'||pg_get_constraintdef(c.oid) AS fact
        FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid
        JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public'
      """,
      "SELECT 'index:'||tablename||':'||indexname||':'||indexdef AS fact FROM pg_indexes WHERE schemaname='public'",
      """
      SELECT 'function:'||p.proname||':'||pg_get_functiondef(p.oid) AS fact FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f'
      """,
      """
      SELECT 'trigger:'||r.relname||':'||t.tgname||':'||pg_get_triggerdef(t.oid) AS fact
        FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid
        JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal
      """,
    ] { catalog += try c.execute(sql).rows.compactMap { $0.text("fact") } }
    var sequences: [String] = []
    for row in try c.execute("SELECT sequencename FROM pg_sequences WHERE schemaname='public'").rows {
      let name = try #require(row.text("sequencename"))
      let state = try #require(
        try c.execute(
          "SELECT last_value::text AS value,is_called::text AS called FROM \(Rows.quote(name))"
        ).rows.first)
      sequences.append(name + ":" + (state.text("value") ?? "NULL") + ":" + (state.text("called") ?? "NULL"))
    }
    var jsonColumns: [String: Set<String>] = [:]
    for row in try c.execute(
      """
      SELECT table_name,column_name FROM information_schema.columns
        WHERE table_schema='public' AND data_type IN ('json','jsonb')
      """
    ).rows {
      jsonColumns[try #require(row.text("table_name")), default: []]
        .insert(try #require(row.text("column_name")))
    }
    return Snapshot(
      rows: rows, catalog: catalog.sorted(), sequences: sequences.sorted(), jsonColumns: jsonColumns)
  }

  private static func archives(_ directory: String) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "jsonl" }
  }
  private static func assertOldArchive(_ fixture: Fixture) throws {
    let files = try archives(fixture.backup)
    #expect(files.count == 1)
    let file = try #require(files.first)
    let document = try AgentProtocolFoundationFixture.readV4(
      String(contentsOf: file, encoding: .utf8), expectedRows: fixture.before.rows,
      expectedMigrations: Array(AgentProtocolFoundationFixture.migrations.prefix(9)),
      facts: fixture.archiveFacts, canonicalPrefixCount: 9)
    let header = document.header
    #expect((header["migrations"] as? [String])?.last == "0009_thread_runtime_choice")
    #expect(!(header["migrations"] as? [String] ?? []).contains(migration))
    var decoded: [String: [String]] = [:]
    for (table, records) in document.rows {
      for var row in records {
        for column in fixture.before.jsonColumns[table] ?? [] {
          guard let value = row[column], !(value is NSNull) else { continue }
          row[column] = try JSONSerialization.jsonObject(
            with: Data(try #require(value as? String).utf8), options: [.fragmentsAllowed])
        }
        decoded[table, default: []].append(try normalized(row))
        if table == "connections" { #expect(profileColumns.allSatisfy { row[$0] == nil }) }
      }
    }
    #expect(
      decoded.values.reduce(0) { $0 + $1.count } == fixture.before.rows.values.reduce(0) { $0 + $1.count })
    for (table, rows) in fixture.before.rows { #expect((decoded[table] ?? []).sorted() == rows) }
    #expect(
      (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        == 0o600)
    #expect(
      (try FileManager.default.attributesOfItem(atPath: fixture.backup)[.posixPermissions] as? NSNumber)?
        .intValue == 0o700)
  }
  private static func assertOldRows(_ fixture: Fixture, allowNewRows: Bool = false) throws {
    let after = try snapshot(fixture.raw)
    let source = try AgentProtocolFoundationFixture.preservationPrefix(
      AgentProtocolFoundationFixture.ledgerNames(fixture.before.rows), expectedCount: 9)
    try AgentProtocolFoundationFixture.requireNativeJSONRetained(
      fixture.archiveFacts,
      after: AgentProtocolFoundationFixture.archiveFacts(fixture.raw),
      tables: Array(fixture.before.rows.keys).filter { $0 != "changes" })
    #expect(try Migrator.recorded(fixture.raw) == AgentProtocolFoundationFixture.migrations)
    for (table, before) in fixture.before.rows {
      try AgentProtocolFoundationFixture.requireIntroducedSQLNull(
        fixture.raw, source: source,
        table: table, originalRows: before)
      let currentTable = AgentProtocolFoundationFixture.currentTable(old: table)
      let normalizedBefore = try before.map { text in
        let row = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try normalized(AgentProtocolFoundationFixture.currentRow(table: table, row: row))
      }
      let introduced = AgentProtocolFoundationFixture.projectionColumns(after: source, table: table)
      let originalIDs = try Set(
        introduced.isEmpty
          ? [] : before.map { try AgentProtocolFoundationFixture.rowIdentifier($0, key: "id") })
      let normalizedAfter = try (after.rows[currentTable] ?? []).map { text in
        var row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        if !introduced.isEmpty,
          originalIDs.contains(try AgentProtocolFoundationFixture.rowIdentifier(text, key: "id"))
        {
          for column in introduced { row.removeValue(forKey: column) }
        }
        return try normalized(row)
      }
      if table == Migrator.table {
        #expect(Set(normalizedBefore).isSubset(of: Set(normalizedAfter)))
        #expect(normalizedAfter.count == before.count + 7)
        let addedNames = try Set(normalizedAfter).subtracting(normalizedBefore).map { text in
          let row = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
          return try #require(row["name"] as? String)
        }
        #expect(
          Set(addedNames)
            == Set([
              "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
              "0014_connection_commands", "0015_density", "0016_agent_protocol",
            ]))
      } else if allowNewRows {
        #expect(Set(normalizedBefore).isSubset(of: Set(normalizedAfter)))
      } else {
        #expect(normalizedBefore.sorted() == normalizedAfter.sorted())
      }
    }
    #expect(
      try fixture.raw.execute(
        #"SELECT 1 FROM connections WHERE id IN ('legacy-b4','codex-old','claude-old') AND models IS NOT NULL"#
      ).rows.isEmpty)
    #expect(
      try fixture.raw.execute(
        #"SELECT 1 FROM threads WHERE id='thread-old' AND (model IS NOT NULL OR permission IS NOT NULL)"#
      ).rows.isEmpty)
    #expect(
      try fixture.raw.execute(
        #"SELECT 1 FROM "connections" WHERE "id" IN ('legacy-b4','codex-old','claude-old') AND ("peerProfile" IS NOT NULL OR "agentId" IS NOT NULL OR "authMode" IS NOT NULL OR "authHeaderName" IS NOT NULL OR "protocolRetiredAt" IS NOT NULL OR "protocolRetiredReason" IS NOT NULL)"#
      ).rows.isEmpty)
    #expect(
      try fixture.raw.execute(
        #"SELECT "submission","outcome" FROM "turns" WHERE "id"='turn-old'"#
      ).rows.first?.text("submission") == "unknown")
    #expect(
      try fixture.raw.execute(
        #"SELECT "outcome" FROM "turns" WHERE "id"='turn-old'"#
      ).rows.first?.text("outcome") == nil)
  }
  private static func profile(_ id: String, peer: ProtocolPeerProfile, mode: ConnectionAuthMode) -> Connection
  {
    Connection(
      id: id, kind: .agentProtocol, label: "Fresh explicit profile", target: "https://example.invalid/base",
      authReference: mode == .none ? nil : "secret:fixture-reference",
      nativeScope: #"["agent-protocol-v1","\#(peer.rawValue)","https://example.invalid/base"]"#,
      peerProfile: peer, agentId: "canonical-agent", authMode: mode,
      authHeaderName: mode == .header ? "x-api-key" : nil, createdAt: "created", updatedAt: "updated")
  }

  @Test func publicOnlyProtocolProfileHasNoDeviceAuthSelection() throws {
    let db = try AgentProtocolResourceFixture.database()
    defer { try? db.close() }
    for peer in [ProtocolPeerProfile.b4, .agentProtocol] {
      var profile = Self.profile("public-only-" + peer.rawValue, peer: peer, mode: ConnectionAuthMode.none)
      profile.target = ""
      profile.authMode = nil
      profile.authReference = nil
      #expect(try db.insertConnection(profile) == profile)
      let stored = try #require(try db.connection(id: profile.id))
      #expect(stored.peerProfile == peer)
      #expect(stored.agentId == "canonical-agent")
      #expect(stored.nativeScope == profile.nativeScope)
      #expect(stored.target.isEmpty)
      #expect(stored.authMode == nil)
      #expect(stored.authMode != ConnectionAuthMode.none)
      #expect(stored.authHeaderName == nil)
      #expect(stored.authReference == nil)
    }
    let privateColumnsAreSQLNull = try db.read { c in
      try c.execute(
        #"SELECT 1 FROM public.connections WHERE id LIKE 'public-only-%' AND ("authMode" IS NOT NULL OR "authHeaderName" IS NOT NULL OR "authReference" IS NOT NULL)"#
      ).rows.isEmpty
    }
    #expect(privateColumnsAreSQLNull)
  }

  @Test func optionalPrivateAuthNeverAdmitsPartialBundlesOrIncompletePublicIdentity() throws {
    let db = try AgentProtocolResourceFixture.database()
    defer { try? db.close() }
    var base = Self.profile("valid-public", peer: .agentProtocol, mode: ConnectionAuthMode.none)
    base.target = ""
    base.authMode = nil
    base.authReference = nil
    _ = try db.insertConnection(base)
    let before = try db.read { try Self.snapshot($0) }
    let bundles: [(String?, String?)] = [
      (nil, "x-api-key"), ("header", nil), ("header", ""), ("none", "x-api-key"),
      ("bearer", "x-api-key"), ("", nil), ("implicit", nil),
    ]
    var invalid: [[(column: String, param: String?)]] = []
    for (mode, header) in bundles {
      var values = try Rows.encode(base)
      values.removeAll { ["authMode", "authHeaderName"].contains($0.column) }
      values += [("authMode", mode), ("authHeaderName", header)]
      invalid.append(values)
    }
    let publicFields: [(String, String?)] = [
      ("peerProfile", nil), ("peerProfile", "unknown"), ("agentId", nil), ("agentId", ""),
      ("nativeScope", nil), ("nativeScope", ""),
    ]
    for (field, value) in publicFields {
      var values = try Rows.encode(base)
      values.removeAll { $0.column == field }
      values.append((field, value))
      invalid.append(values)
    }
    for (index, row) in invalid.enumerated() {
      var values = row
      values.removeAll { $0.column == "id" }; values.append(("id", "invalid-public-\(index)"))
      let state = try db.read { c -> String? in
        try c.execute("BEGIN")
        var state: String?
        var unexpected: (any Error)?
        do {
          let q = Rows.insert("connections", values)
          try c.execute(q.sql, q.params)
        } catch let error as PostgresError { state = error.sqlState } catch { unexpected = error }
        do { try c.execute("ROLLBACK") } catch { if unexpected == nil { unexpected = error } }
        if let unexpected { throw unexpected }
        return state
      }
      #expect(state == "23514", "Malformed public/private shape must be a native CHECK refusal.")
      #expect(try db.read { try Self.snapshot($0) } == before)
    }
  }

  @Test func protocolProfileRequiresCompleteExplicitIdentityAndAuth() throws {
    try Self.withFixture { fixture in
      let db = try WorkspaceDatabase(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!, backupDirectory: fixture.backup)
      defer { try? db.close() }
      try #require(try db.appliedMigrations().last == Self.migration)
      // Explicit enum value avoids Optional.none: .none is an intentional auth selection.
      let none: ConnectionAuthMode = ConnectionAuthMode.none
      for peer in [ProtocolPeerProfile.b4, .agentProtocol] {
        for mode in [none, ConnectionAuthMode.bearer, .header] {
          let profile = Self.profile("new-\(peer.rawValue)-\(mode.rawValue)", peer: peer, mode: mode)
          #expect(try db.insertConnection(profile) == profile)
          #expect(try db.connection(id: profile.id) == profile)
        }
      }
      try Self.assertOldRows(fixture, allowNewRows: true)
      let beforeFailures = try Self.snapshot(fixture.raw)
      let invalid: [(String, String?)] = [
        ("peerProfile", nil), ("peerProfile", ""), ("peerProfile", "legacy"),
        ("agentId", nil), ("agentId", ""), ("authMode", nil), ("authMode", ""),
        ("authMode", "implicit"), ("nativeScope", nil), ("nativeScope", ""),
        ("authHeaderName", nil), ("authHeaderName", ""),
      ]
      for (index, field) in invalid.enumerated() {
        var values = try Rows.encode(Self.profile("invalid-\(index)", peer: .agentProtocol, mode: .header))
        values.removeAll { $0.column == field.0 }; values.append((field.0, field.1))
        try fixture.raw.execute("BEGIN")
        var sqlState: String?
        do { let q = Rows.insert("connections", values); try fixture.raw.execute(q.sql, q.params) } catch let
          error as PostgresError
        { sqlState = error.sqlState } catch { Issue.record(error) }
        try fixture.raw.execute("ROLLBACK")
        #expect(
          sqlState == "23514" || sqlState == "23502", "Required field must reject SQL NULL/value: \(field.0)")
        #expect(try Self.snapshot(fixture.raw) == beforeFailures)
      }
      for mode in [none, ConnectionAuthMode.bearer] {
        var values = try Rows.encode(
          Self.profile("unexpected-header-\(mode.rawValue)", peer: .agentProtocol, mode: mode))
        values.append(("authHeaderName", "x-api-key"))
        try fixture.raw.execute("BEGIN")
        var sqlState: String?
        do { let q = Rows.insert("connections", values); try fixture.raw.execute(q.sql, q.params) } catch let
          error as PostgresError
        { sqlState = error.sqlState } catch { Issue.record(error) }
        try fixture.raw.execute("ROLLBACK")
        #expect(sqlState == "23514" || sqlState == "23502")
        #expect(try Self.snapshot(fixture.raw) == beforeFailures)
      }
      try Self.assertOldRows(fixture, allowNewRows: true)
    }
  }

  @Test func profileMigrationBacksUpNineBeforeAdditiveTen() throws {
    try Self.withFixture { fixture in
      let observed = Mutex(false)
      try WorkspaceDatabase.migrateWithBackup(
        fixture.raw, endpoint: fixture.endpoint, backupDirectory: fixture.backup
      ) { stage in
        if stage == .willMigrate {
          // Existing internal admission core used by normal init. At this observed boundary every
          // old row/catalog/sequence is intact and the durable old9 archive is already complete.
          #expect(try Self.snapshot(fixture.raw) == fixture.before)
          try Self.assertOldArchive(fixture)
          observed.withLock { $0 = true }
        }
      }
      #expect(observed.withLock { $0 })
      let db = try WorkspaceDatabase(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!, backupDirectory: fixture.backup)
      defer { try? db.close() }
      #expect(try db.appliedMigrations().last == Self.migration)
      try Self.assertOldRows(fixture)
      #expect(try Self.snapshot(fixture.raw).sequences == fixture.before.sequences)
      let archives = try Self.archives(fixture.backup)
      let again = try WorkspaceDatabase(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!, backupDirectory: fixture.backup)
      defer { try? again.close() }
      #expect(try Self.archives(fixture.backup) == archives)
      var freshEndpoint = try AgentProtocolResourceFixture.endpoint()
      freshEndpoint.dataDir = nil
      let freshRaw = try Self.connection(freshEndpoint)
      defer {
        var noFreshApplicationBackends: Bool?
        var freshCleanupFacts: [String] = []
        do {
          let originalRows = try freshRaw.execute(
            "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
            [freshEndpoint.database]
          ).rows
          noFreshApplicationBackends = originalRows.isEmpty
          freshCleanupFacts.append("originalRowCount=\(originalRows.count)")
          freshCleanupFacts.append("originalRows=\(String(reflecting: originalRows))")
          if !originalRows.isEmpty {
            do {
              let laterIdentityRows = try freshRaw.execute(
                "SELECT pid,state,application_name FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
                [freshEndpoint.database]
              ).rows
              freshCleanupFacts.append("laterIdentityRows=\(String(reflecting: laterIdentityRows))")
            } catch {
              freshCleanupFacts.append("identityErrorType=\(String(reflecting: type(of: error)))")
              freshCleanupFacts.append("identitySQLState=\((error as? PostgresError)?.sqlState ?? "<none>")")
            }
          }
        } catch {
          noFreshApplicationBackends = nil
          freshCleanupFacts.append("originalErrorType=\(String(reflecting: type(of: error)))")
          freshCleanupFacts.append("originalSQLState=\((error as? PostgresError)?.sqlState ?? "<none>")")
        }
        let freshCleanupDiagnostic = freshCleanupFacts.joined(separator: "; ")
        print("A3_PROFILE_CLEANUP_DIAGNOSTIC " + freshCleanupDiagnostic)
        #expect(
          noFreshApplicationBackends == true,
          Comment(rawValue: freshCleanupDiagnostic))
      }
      let freshPath = (fixture.backup as NSString).deletingLastPathComponent + "/fresh"
      let fresh = try WorkspaceDatabase(
        endpoint: freshEndpoint, binDir: freshEndpoint.binDir!, backupDirectory: freshPath)
      defer { try? fresh.close() }
      #expect(try fresh.appliedMigrations().last == Self.migration)
      #expect(!FileManager.default.fileExists(atPath: freshPath))
    }
  }

  @Test func profileSchemaFailurePreservesExistingStore() throws {
    try Self.withFixture { fixture in
      let parent = (fixture.backup as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(
        atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try Data("private-directory-blocker".utf8).write(to: URL(fileURLWithPath: fixture.backup))
      let before = try Self.snapshot(fixture.raw)
      var refused = false
      do {
        let unexpected = try WorkspaceDatabase(
          endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!, backupDirectory: fixture.backup)
        try unexpected.close()
      } catch { refused = true }
      #expect(refused)
      #expect(try Self.snapshot(fixture.raw) == before)
      #expect(
        try Data(contentsOf: URL(fileURLWithPath: fixture.backup)) == Data("private-directory-blocker".utf8))
    }
    try Self.withFixture { fixture in
      try fixture.raw.execute(
        #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ('9999_future','fixture')"#)
      let before = try Self.snapshot(fixture.raw)
      var code: ErrorCode?
      do {
        let unexpected = try WorkspaceDatabase(
          endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!, backupDirectory: fixture.backup)
        try unexpected.close()
      } catch { code = WorkspaceError.from(error).code }
      #expect(code == .incompatibleVersion)
      #expect(try Self.snapshot(fixture.raw) == before)
      #expect(!FileManager.default.fileExists(atPath: fixture.backup))
    }
  }
}
