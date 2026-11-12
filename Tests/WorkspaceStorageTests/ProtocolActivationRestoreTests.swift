import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// First native RED uses only today's public export/restore surface; it cannot activate a protocol.
@Suite struct ProtocolActivationRestoreTests {
  private static let controlKey = "__b4app_agent_protocol_activation_v1"
  private static let migrations = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
    "0010_owned_rows", "0011_environments", "0012_app_folders", "0013_view_settings",
    "0014_agent_protocol",
  ]
  // Independent literal inventory includes empty tables and every private obligation table.
  private static let tables = [
    "localServers", "environments", "environmentFolders", "connections", "threads", "appFolders",
    "turns", "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
    "settings", "usageReadings", "tokenUsage", "connectionUsage", "threadDeletes", "viewSettings",
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  private static func snapshot(_ db: WorkspaceDatabase) throws -> [String: [Data]] {
    try db.read { c in
      var result: [String: [Data]] = [:]
      for table in tables {
        // Only the new local control row may differ after GREEN. Never omit unrelated settings,
        // private rows, empty tables, view values, changes or clocks from this equality oracle.
        let condition = table == "settings" ? #" WHERE t."key" IS DISTINCT FROM $1"# : ""
        let parameters: [String?] = table == "settings" ? [controlKey] : []
        result[table] = try c.execute(
          "SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t\(condition)", parameters
        ).rows.map { row in
          Data(try #require(row.text("row")).utf8)
        }.sorted { $0.lexicographicallyPrecedes($1) }
      }
      return result
    }
  }

  private static func controlCount(_ db: WorkspaceDatabase) throws -> Int {
    try db.read { c in
      try #require(
        try c.execute(#"SELECT count(*) AS n FROM "settings" WHERE "key" = $1"#, [controlKey])
          .rows.first?.int("n"))
    }
  }

  private static func ledger(_ db: WorkspaceDatabase) throws -> [Data] {
    try db.read { c in
      try c.execute(#"SELECT to_jsonb(t)::text AS row FROM "schemaMigrations" t ORDER BY "name""#)
        .rows.map { row in Data(try #require(row.text("row")).utf8) }
    }
  }

  private static func nextSequence(_ db: WorkspaceDatabase) throws -> String {
    try db.read { c in
      try #require(
        try c.execute(
          #"SELECT (CASE WHEN is_called THEN last_value + 1 ELSE last_value END)::text AS next_value FROM "changes_seq_seq""#
        ).rows.first?.text("next_value"))
    }
  }

  private static func publicTables(_ db: WorkspaceDatabase) throws -> Set<String> {
    try db.read { c in
      Set(
        try c.execute("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'")
          .rows.compactMap { $0.text("tablename") })
    }
  }

  @Test func restoreWithoutSourceControlCreatesInactiveLocalFacts() throws {
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "activation-red-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let path = root + "/workspace.jsonl"
    let source = try AgentProtocolResourceFixture.database()
    defer { try? source.close() }
    let destination = try AgentProtocolResourceFixture.database()
    defer { try? destination.close() }
    let outcome = Result<Int, any Error> { () throws -> Int in
      try #require(source.endpoint.database != destination.endpoint.database)
      try #require(try source.appliedMigrations() == Self.migrations)
      try #require(try destination.appliedMigrations() == Self.migrations)
      let allTables = Set(Self.tables + ["schemaMigrations", "hubLink"])
      try #require(try Self.publicTables(source) == allTables)
      try #require(try Self.publicTables(destination) == allTables)
      try #require(WorkspaceDatabase.archiveTables == Self.tables)
      try #require(try Self.controlCount(source) == 0)
      try #require(try Self.controlCount(destination) == 0)
      try source.write { c in
        // Fixed native fixtures: no joined account, private auth, runtime or network activity.
        try c.execute(
          """
          SET LOCAL b4app.replaying='on';
          INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
            VALUES ('activation-c','codex','Stored','/fixture/codex','{}','ready','authenticated','then','then');
          INSERT INTO threads (id,"connectionId","nativeThreadId",context,"createdAt","updatedAt")
            VALUES ('activation-t','activation-c','native-t','/fixture/app','then','then');
          INSERT INTO "appFolders" (path,"threadId","createdAt")
            VALUES ('/fixture/app','activation-t','then');
          INSERT INTO turns (id,"threadId","operationId",status,submission,outcome,"createdAt","updatedAt")
            VALUES ('activation-u','activation-t','operation-u','terminal','acknowledged','completed','then','then');
          INSERT INTO "displayItems" (id,"threadId","turnId",role,type,payload,sequence,provenance,"createdAt")
            VALUES ('activation-i','activation-t','activation-u','assistant','agentMessage',
              '{"projectId":"external","environmentId":"keep","n":1e400}',0,'cache','then');
          INSERT INTO drafts ("threadId",text,"updatedAt") VALUES ('activation-t','Retained draft','then');
          INSERT INTO settings (key,value)
            VALUES ('activation-unrelated','{"n":9007199254740993,"opaque":[true,null,"keep"]}');
          INSERT INTO "viewSettings" (id,arrangement,"quietThreads","showArchived","updatedAt")
            VALUES ('view','future-arrangement',NULL,true,NULL);
          INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
            VALUES ('fixture',1,'displayItems','activation-i','update','payload',
              '{"projectId":"external","n":1e-400}','000000001000-0000-fixture');
          INSERT INTO "columnClocks" ("table","rowId","column",hlc)
            VALUES ('viewSettings','view','arrangement','000000001000-0000-fixture');
          """)
      }
      let before = try Self.snapshot(source)
      try #require(before.count == Self.tables.count)
      try #require(before["viewSettings"]?.count == 1 && before["settings"]?.count == 1)
      let sourceLedger = try Self.ledger(source)
      let destinationLedger = try Self.ledger(destination)
      let next = try Self.nextSequence(source)
      let exported = try source.export(to: path)
      #expect(exported.rows == before.values.reduce(0) { $0 + $1.count })
      #expect(try Self.snapshot(source) == before)
      #expect(try Self.ledger(source) == sourceLedger)
      #expect(try Self.controlCount(source) == 0)
      let restored = try destination.restore(from: path)
      // All existing import, native JSONB/text, unknown view, empty/private-table and ledger
      // invariants precede the one intended RED assertion. No UI-default normalization is used.
      #expect(restored.rows == exported.rows)
      #expect(try Self.snapshot(destination) == before)
      #expect(try Self.publicTables(destination) == allTables)
      #expect(try destination.appliedMigrations() == Self.migrations)
      #expect(try Self.ledger(destination) == destinationLedger)
      #expect(try Self.nextSequence(destination) == next)
      #expect(try Self.snapshot(source) == before)
      #expect(try Self.ledger(source) == sourceLedger)
      #expect(try Self.controlCount(source) == 0)
      #expect(try destination.hubLink() == nil)
      #expect(try source.hubLink() == nil)
      return try Self.controlCount(destination)
    }
    // Close both real pools before propagating setup/import errors or the intended count issue.
    let destinationClosed = Result { try destination.close() }
    let sourceClosed = Result { try source.close() }
    let restoredControlRows = try outcome.get()
    try destinationClosed.get()
    try sourceClosed.get()
    // Baseline restore creates no row (actual0). Only this missing local-state assertion is RED;
    // later GREEN tests must also validate fresh incarnations, no binding and no observation.
    #expect(restoredControlRows == 1)
  }
}

// Test-only independent native oracle shared by this test target, never a production decoder.
enum ProtocolActivationRestoreOracle {
  static let key = "__b4app_agent_protocol_activation_v1"
  struct Control: Equatable, Sendable {
    let store: String
    let member: String
    let revision: Int64
  }
  enum Failure: Error { case invalidControl, fixture }

  static func inactive(
    _ c: PostgresConnection, revision: Int64, previous: Control? = nil
  ) throws -> Control {
    let rows = try c.execute(
      #"SELECT value::text AS value,jsonb_typeof(value->'version') AS version_type,value->>'version' AS version FROM settings WHERE key=$1"#,
      [key]
    ).rows
    guard rows.count == 1, let row = rows.first, row.text("version_type") == "number",
      row.text("version") == "1", let text = row.text("value"),
      let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      Set(object.keys) == Set(["version", "storeIncarnation", "membershipIncarnation", "revision"]),
      let store = object["storeIncarnation"] as? String,
      let member = object["membershipIncarnation"] as? String,
      UUID(uuidString: store)?.uuidString == store, UUID(uuidString: member)?.uuidString == member,
      store != member, let revisionText = object["revision"] as? String,
      let actual = Int64(revisionText), actual >= 0, String(actual) == revisionText, actual == revision
    else { throw Failure.invalidControl }
    let control = Control(store: store, member: member, revision: actual)
    if let previous {
      let fresh = control.store != previous.store && control.member != previous.member
      #expect(fresh)
    }
    return control
  }
}

extension ProtocolActivationRestoreTests {
  private struct NativeState: Equatable {
    let rows: [String: [Data]]
    let jsonCells: [String: [Data]]
    let catalog: [String]
    let sequences: [String]
  }
  private enum FaultStage: String, CaseIterable, Sendable {
    case sourceInsert, finalWrite, deferredCommit
  }
  private static let oldStore = "11111111-1111-4111-8111-111111111111"
  private static let oldMember = "22222222-2222-4222-8222-222222222222"
  private static let sourceStore = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
  private static let sourceMember = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

  private static func inactiveJSON(
    _ revision: String, store: String = oldStore, member: String = oldMember
  ) -> String {
    #"{"version":1,"storeIncarnation":"\#(store)","membershipIncarnation":"\#(member)","revision":"\#(revision)"}"#
  }

  private static func activeSourceJSON(_ db: WorkspaceDatabase) throws -> String {
    let binding: [String: Any] = [
      "accountID": "source-account", "canonicalHubBase": "https://source.invalid/deploy%2Fbase",
      "hubUserID": "source-user", "hubOrgID": "source-org", "deviceID": "source-device",
      "databaseName": db.endpoint.database, "linkJoinedAt": "source-joined",
    ]
    let record: [String: Any] = [
      "version": 1, "storeIncarnation": sourceStore, "membershipIncarnation": sourceMember,
      "revision": String(Int64.max), "binding": binding,
      "observation": ["binding": binding, "reportedMinimum": 2, "reportedVersion": 2, "healthy": true],
    ]
    return String(
      decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self)
  }

  private static func putControl(_ db: WorkspaceDatabase, _ json: String) throws {
    try db.write { c in
      try c.execute(
        #"INSERT INTO settings(key,value) VALUES ($1,$2::jsonb) ON CONFLICT(key) DO UPDATE SET value=excluded.value"#,
        [controlKey, json])
    }
  }

  private static func pair(
    _ body: (WorkspaceDatabase, WorkspaceDatabase, String) throws -> Void
  ) throws {
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "activation-restore-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let source = try AgentProtocolResourceFixture.database()
    defer { try? source.close() }
    let destination = try AgentProtocolResourceFixture.database()
    defer { try? destination.close() }
    let outcome = Result<Void, any Error> { () throws -> Void in
      try #require(source.endpoint.database != destination.endpoint.database)
      try #require(try source.appliedMigrations() == migrations)
      try #require(try destination.appliedMigrations() == migrations)
      try #require(try publicTables(source) == Set(tables + ["schemaMigrations", "hubLink"]))
      try #require(try publicTables(destination) == Set(tables + ["schemaMigrations", "hubLink"]))
      let sourceLedger = try ledger(source), destinationLedger = try ledger(destination)
      try body(source, destination, root)
      let sourceLedgerUnchanged = try ledger(source) == sourceLedger
      let destinationLedgerUnchanged = try ledger(destination) == destinationLedger
      #expect(sourceLedgerUnchanged); #expect(destinationLedgerUnchanged)
      let sourceLink = try source.hubLink(), destinationLink = try destination.hubLink()
      #expect(sourceLink == nil && destinationLink == nil)
      #expect(try publicTables(source) == Set(tables + ["schemaMigrations", "hubLink"]))
      #expect(try publicTables(destination) == Set(tables + ["schemaMigrations", "hubLink"]))
    }
    let destinationClosed = Result { try destination.close() }
    let sourceClosed = Result { try source.close() }
    try outcome.get()
    try destinationClosed.get()
    try sourceClosed.get()
  }

  // The default is FULL, including the old control; failure comparisons never filter it.
  private static func nativeState(_ db: WorkspaceDatabase) throws -> NativeState {
    try db.read { c in
      try c.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
      defer { try? c.execute("ROLLBACK") }
      try ProtocolGrantProtection.establish(c)
      var rows: [String: [Data]] = [:], cells: [String: [Data]] = [:]
      for table in tables + ["schemaMigrations", "hubLink"] {
        rows[table] = try c.execute("SELECT to_jsonb(t)::text AS row FROM \(Rows.quote(table)) t ORDER BY 1")
          .rows.map { Data(try #require($0.text("row")).utf8) }
        let columns = try c.execute(
          "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND data_type IN ('json','jsonb') ORDER BY column_name",
          [table]
        ).rows.compactMap { $0.text("column_name") }
        let projection = columns.map { "jsonb_build_array(\(Rows.quote($0)),\(Rows.quote($0))::text)" }
          .joined(separator: ",")
        if !projection.isEmpty {
          cells[table] = try c.execute(
            "SELECT jsonb_build_array(\(projection))::text AS row FROM \(Rows.quote(table)) ORDER BY 1"
          ).rows.map { Data(try #require($0.text("row")).utf8) }
        }
      }
      var catalog: [String] = []
      for sql in [
        "SELECT table_name||':'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'') AS fact FROM information_schema.columns WHERE table_schema='public' ORDER BY 1",
        "SELECT r.relname||':'||conname||':'||pg_get_constraintdef(c.oid) AS fact FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public' ORDER BY 1",
        "SELECT tablename||':'||indexname||':'||indexdef AS fact FROM pg_indexes WHERE schemaname='public' ORDER BY 1",
        "SELECT r.relname||':'||t.tgname||':'||pg_get_triggerdef(t.oid) AS fact FROM pg_trigger t JOIN pg_class r ON r.oid=t.tgrelid JOIN pg_namespace n ON n.oid=r.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal ORDER BY 1",
        "SELECT p.proname||':'||pg_get_functiondef(p.oid) AS fact FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f' ORDER BY 1",
      ] { catalog += try c.execute(sql).rows.compactMap { $0.text("fact") } }
      var sequences: [String] = []
      for name in try c.execute(
        "SELECT sequencename FROM pg_sequences WHERE schemaname='public' ORDER BY sequencename"
      )
      .rows.compactMap({ $0.text("sequencename") }) {
        let row = try #require(
          try c.execute(
            "SELECT last_value::text AS v,log_cnt::text AS l,is_called::text AS c FROM \(Rows.quote(name))"
          ).rows.first)
        sequences.append(
          name + ":" + (row.text("v") ?? "NULL") + ":" + (row.text("l") ?? "NULL") + ":"
            + (row.text("c") ?? "NULL"))
      }
      return NativeState(rows: rows, jsonCells: cells, catalog: catalog, sequences: sequences)
    }
  }

  private static func seed(_ db: WorkspaceDatabase, legacy: Bool = false) throws {
    try db.write { c in
      try c.execute("SET LOCAL b4app.replaying='on'")
      try c.execute(
        """
        INSERT INTO connections(id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
          VALUES ('restore-c','codex','Stored','/fixture/codex','{}','ready','authenticated','then','then');
        INSERT INTO threads(id,"connectionId","nativeThreadId","createdAt","updatedAt")
          VALUES ('restore-t','restore-c','native-thread','then','then');
        INSERT INTO drafts("threadId",text,"updatedAt") VALUES ('restore-t','Retained draft','then');
        INSERT INTO changes("deviceId",wall,"table","rowId",op,"column",value,hlc)
          VALUES ('fixture',1,'threads','restore-t','update','title','"retained"','000000001000-0000-fixture');
        """)
      if !legacy {
        try c.execute(
          """
          INSERT INTO settings(key,value) VALUES ('unrelated','{"opaque":[true,null],"n":9007199254740993}');
          INSERT INTO "viewSettings"(id,arrangement,"quietThreads","showArchived","updatedAt")
            VALUES ('view','future-layout',NULL,true,NULL);
          INSERT INTO "appFolders"(path,"threadId","createdAt") VALUES ('/fixture/app','restore-t','then');
          """)
      }
    }
  }

  private static func safeRestoreFailure(_ error: (any Error)?) throws {
    let error = try #require(error)
    let publicError = WorkspaceError.from(error)
    let safe =
      publicError.code == .internalError
      && publicError.message == "The protected workspace archive could not be restored."
      && publicError.details == nil && (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
      && !String(reflecting: error).contains("ACTIVATION_RESTORE_PRIVATE_SENTINEL")
    #expect(safe)
  }

  private static func caught(_ action: () throws -> Void) -> (any Error)? {
    do { try action(); return nil } catch { return error }
  }

  private static func assertRows(_ source: WorkspaceDatabase, _ destination: WorkspaceDatabase) throws {
    let equal = try snapshot(source) == snapshot(destination)
    #expect(equal)
    let sequenceContinues = try nextSequence(source) == nextSequence(destination)
    #expect(sequenceContinues)
  }

  @Test func currentFourteenRestoreUsesDestinationChronologyAndNeverSourceAuthority() throws {
    for replace in [false, true] {
      for destinationExists in [false, true] {
        try Self.pair { source, destination, root in
          try Self.seed(source)
          try Self.putControl(source, Self.activeSourceJSON(source))
          if destinationExists { try Self.putControl(destination, Self.inactiveJSON("7")) }
          let original =
            destinationExists
            ? ProtocolActivationRestoreOracle.Control(
              store: Self.oldStore, member: Self.oldMember, revision: 7) : nil
          let before = try Self.nativeState(source)
          let path = root + "/current.jsonl"
          let exported = try source.export(to: path)
          let document = try WorkspaceArchive.read(Data(contentsOf: URL(fileURLWithPath: path)))
          let sourceControl = document.records["settings"]?.filter {
            $0.row["key"] as? String == Self.controlKey
          }
          let sourceControlNative = try source.read {
            try $0.execute("SELECT value::text AS value FROM settings WHERE key=$1", [Self.controlKey]).rows
              .first?.text("value")
          }
          let archivedControlExact =
            sourceControl?.count == 1
            && (sourceControl?.first?.row["value"] as? String) == sourceControlNative
          #expect(archivedControlExact)
          #expect(
            exported.rows
              == before.rows.filter { Self.tables.contains($0.key) }.values.reduce(0) { $0 + $1.count })
          let restored = try destination.restore(from: path, replace: replace)
          #expect(restored.rows == exported.rows && restored.path == path)
          try Self.assertRows(source, destination)
          let fresh = try destination.read {
            try ProtocolActivationRestoreOracle.inactive(
              $0, revision: destinationExists ? 8 : 0, previous: original)
          }
          let notSource = fresh.store != Self.sourceStore && fresh.member != Self.sourceMember
          #expect(notSource)
          let unchanged = try Self.nativeState(source) == before
          #expect(unchanged)
          let second = try destination.restore(from: path, replace: true)
          #expect(second.rows == exported.rows)
          _ = try destination.read {
            try ProtocolActivationRestoreOracle.inactive(
              $0, revision: destinationExists ? 9 : 1, previous: fresh)
          }
          try Self.assertRows(source, destination)
        }
      }
    }
  }

  @Test func opaqueSourceControlAndMissingSourceControlBothProduceFreshInactiveState() throws {
    for value in [String?.none, #"{"version":999,"foreign":true}"#, #"{"version":1,"binding":null}"#] {
      try Self.pair { source, destination, root in
        try Self.seed(source)
        if let value { try Self.putControl(source, value) }
        try Self.putControl(destination, Self.inactiveJSON("0"))
        let sourceBefore = try Self.nativeState(source)
        let path = root + "/opaque.jsonl"
        let summary = try source.export(to: path)
        let result = try destination.restore(from: path)
        #expect(result.rows == summary.rows)
        _ = try destination.read {
          try ProtocolActivationRestoreOracle.inactive(
            $0, revision: 1, previous: .init(store: Self.oldStore, member: Self.oldMember, revision: 0))
        }
        try Self.assertRows(source, destination)
        let unchanged = try Self.nativeState(source) == sourceBefore
        #expect(unchanged)
      }
    }
  }

  @Test func malformedOrExhaustedDestinationRefusesBeforeAnyImportMutation() throws {
    let malformed = [
      Self.inactiveJSON("7").replacingOccurrences(of: #""version":1"#, with: #""version":2"#),
      String(Self.inactiveJSON("7").dropLast()) + #", "unknown":true}"#,
      Self.inactiveJSON("01"), Self.inactiveJSON("-0"), Self.inactiveJSON("+1"),
      Self.inactiveJSON("9223372036854775807"), Self.inactiveJSON("9223372036854775808"),
      Self.inactiveJSON("7").replacingOccurrences(of: #""revision":"7""#, with: #""revision":7"#),
      String(Self.inactiveJSON("7").dropLast()) + #", "binding":null}"#,
    ]
    for replace in [false, true] {
      for value in malformed {
        try Self.pair { source, destination, root in
          try Self.seed(source)
          try Self.putControl(destination, Self.inactiveJSON("7"))
          _ = try destination.read { try ProtocolActivationRestoreOracle.inactive($0, revision: 7) }
          try Self.putControl(destination, String(value))
          let path = root + "/refuse.jsonl"
          try source.export(to: path)
          let before = try Self.nativeState(destination)
          let error = Self.caught { _ = try destination.restore(from: path, replace: replace) }
          try Self.safeRestoreFailure(error)
          let unchanged = try Self.nativeState(destination) == before
          #expect(unchanged)
        }
      }
    }
  }

  @Test func exactControlAndViewOnlyEmptinessDoesNotExemptAnyOtherMaterial() throws {
    for kind in ["control", "control-and-view", "prefix", "other-setting", "private", "business"] {
      try Self.pair { source, destination, root in
        try Self.seed(source)
        try Self.putControl(destination, Self.inactiveJSON("7"))
        try destination.write { c in
          switch kind {
          case "control": break
          case "control-and-view":
            try c.execute(
              #"INSERT INTO "viewSettings"(id,arrangement,"quietThreads","showArchived","updatedAt") VALUES ('view','old-layout',NULL,false,NULL)"#
            )
          case "prefix", "other-setting":
            let key = kind == "prefix" ? Self.controlKey + "_foreign" : "unrelated-owner"
            try c.execute("INSERT INTO settings(key,value) VALUES ($1,'true')", [key])
          default:
            try c.execute(
              #"INSERT INTO connections(id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt") VALUES ('material-c','codex','Keep','/fixture/codex','{}','ready','authenticated','then','then')"#
            )
            if kind == "private" {
              try c.execute(
                #"INSERT INTO threads(id,"connectionId","nativeThreadId","createdAt","updatedAt") VALUES ('material-t','material-c','native-material','then','then')"#
              )
              try c.execute(
                #"INSERT INTO "protocolSubscriptions"("connectionId","threadId","nativeThreadId","localObservationEpoch","channels","namespaces","coverage","updatedAt") VALUES ('material-c','material-t','native-material','local-material','[]','[]','{}','then')"#
              )
            }
          }
        }
        let path = root + "/empty-check.jsonl"
        try source.export(to: path)
        let before = try Self.nativeState(destination)
        if kind == "control" || kind == "control-and-view" {
          try destination.restore(from: path)
          _ = try destination.read {
            try ProtocolActivationRestoreOracle.inactive(
              $0, revision: 8, previous: .init(store: Self.oldStore, member: Self.oldMember, revision: 7))
          }
          try Self.assertRows(source, destination)
        } else {
          let error = try #require(Self.caught { _ = try destination.restore(from: path) } as? WorkspaceError)
          #expect(error.code == .protocolInvalid)
          #expect(error.message == "The store is not empty; pass --replace to overwrite it from the archive.")
          let unchanged = try Self.nativeState(destination) == before
          #expect(unchanged)
        }
      }
    }
  }

  @Test func legacyOneTwoThreeRemainClosedToControlSmugglingAndInitializeLocally() throws {
    for version in [1, 2, 3] {
      try Self.pair { source, destination, root in
        try Self.seed(source, legacy: true)
        try Self.putControl(source, Self.activeSourceJSON(source))
        try Self.putControl(destination, Self.inactiveJSON("7"))
        let path = root + "/legacy.jsonl"
        let count = try HistoricalWorkspaceArchiveFixture.write(source, version: version, path: path)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let sourceBefore = try Self.nativeState(source)
        let restored = try destination.restore(from: path)
        #expect(restored.rows == count)
        let firstControl = try destination.read {
          try ProtocolActivationRestoreOracle.inactive(
            $0, revision: 8, previous: .init(store: Self.oldStore, member: Self.oldMember, revision: 7))
        }
        try Self.assertRows(source, destination)
        let lines = bytes.split(separator: 0x0a, omittingEmptySubsequences: false)
        var header = try #require(try JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        header[Self.controlKey] = ["binding": "foreign", "active": true]
        let metadataPath = root + "/legacy-metadata.jsonl"
        let metadata =
          try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
          + Data("\n".utf8) + Data(bytes.dropFirst(lines[0].count + 1))
        try metadata.write(to: URL(fileURLWithPath: metadataPath))
        #expect(try destination.restore(from: metadataPath, replace: true).rows == count)
        _ = try destination.read {
          try ProtocolActivationRestoreOracle.inactive($0, revision: 9, previous: firstControl)
        }
        try Self.assertRows(source, destination)
        let before = try Self.nativeState(destination)
        // The added forbidden-table rows are natively valid; the unknown-column vector modifies
        // an existing complete Thread row, so missing columns/duplicate IDs cannot satisfy refusal.
        let settingsRow =
          #"{"table":"settings","row":{"key":"__b4app_agent_protocol_activation_v1","value":"{\"version\":1}"}}"#
        let linkRow =
          #"{"table":"hubLink","row":{"id":1,"url":"https://foreign.invalid","deviceId":"foreign-device","deviceName":"foreign","tokenRef":"secret:foreign","orgSlug":"foreign","username":"foreign","cursor":0,"lastPushAt":null,"lastError":null,"joinedAt":"foreign","ownedAs":"foreign"}}"#
        var unknownColumn = Data()
        var changedThread = false
        for line in bytes.split(separator: 0x0a) {
          var record = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
          if record["table"] as? String == "threads" {
            var row = try #require(record["row"] as? [String: Any])
            row[Self.controlKey] = "foreign"
            record["row"] = row
            changedThread = true
          }
          unknownColumn +=
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8)
        }
        try #require(changedThread)
        for hostileBytes in [
          bytes + Data((settingsRow + "\n").utf8),
          bytes + Data((linkRow + "\n").utf8), unknownColumn,
        ] {
          let hostile = root + "/smuggled.jsonl"
          try hostileBytes.write(to: URL(fileURLWithPath: hostile))
          let failure = Self.caught { _ = try destination.restore(from: hostile, replace: true) }
          #expect(failure != nil)
          let unchanged = try Self.nativeState(destination) == before
          #expect(unchanged)
        }
        let unchanged = try Self.nativeState(source) == sourceBefore
        #expect(unchanged)
      }
    }
  }

  private static func installFault(_ db: WorkspaceDatabase, stage: FaultStage) throws {
    try db.read { c in
      try c.execute("CREATE SCHEMA activation_fault; CREATE SEQUENCE activation_fault.progress")
      let condition =
        stage == .sourceInsert
        ? "TG_OP='INSERT' AND NEW.value->>'storeIncarnation'='\(sourceStore)'"
        : "NEW.value->>'revision'='8' AND NEW.value->>'storeIncarnation'<>'\(oldStore)' AND NEW.value->>'storeIncarnation'<>'\(sourceStore)'"
      try c.execute(
        """
        CREATE FUNCTION activation_restore_fault() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.key='__b4app_agent_protocol_activation_v1' AND (\(condition)) THEN
            PERFORM nextval('activation_fault.progress');
            RAISE EXCEPTION 'Fixture activation restore refusal' USING ERRCODE='23514',DETAIL='ACTIVATION_RESTORE_PRIVATE_SENTINEL';
          END IF;
          RETURN NEW;
        END $$;
        CREATE \(stage == .deferredCommit ? "CONSTRAINT " : "")TRIGGER activation_restore_fault
          AFTER INSERT OR UPDATE ON settings \(stage == .deferredCommit ? "DEFERRABLE INITIALLY DEFERRED" : "")
          FOR EACH ROW EXECUTE FUNCTION activation_restore_fault();
        """)
    }
  }

  @Test func nativeSourceInsertFinalWriteAndDeferredCommitFaultsRollBackThenRecover() throws {
    for stage in FaultStage.allCases {
      for replace in [false, true] {
        try Self.pair { source, destination, root in
          try Self.seed(source)
          try Self.putControl(source, Self.activeSourceJSON(source))
          if replace {
            try Self.seed(destination)
            try destination.write { c in
              try c.execute(#"UPDATE drafts SET text='Old target must survive' WHERE "threadId"='restore-t'"#)
            }
          } else {
            try destination.write {
              try $0.execute(
                #"INSERT INTO "viewSettings"(id,arrangement,"quietThreads","showArchived","updatedAt") VALUES ('view','old-target-layout',NULL,false,NULL)"#
              )
            }
          }
          try Self.putControl(destination, Self.inactiveJSON("7"))
          let path = root + "/fault.jsonl"
          let summary = try source.export(to: path)
          try Self.installFault(destination, stage: stage)
          defer {
            _ = try? destination.read {
              try $0.execute(
                "DROP TRIGGER IF EXISTS activation_restore_fault ON settings; DROP FUNCTION IF EXISTS activation_restore_fault(); DROP SCHEMA IF EXISTS activation_fault CASCADE"
              )
            }
          }
          // Independent raw SQL positive control establishes the exact trigger and private DETAIL.
          try destination.read { c in
            var code: String?, privateDetail = false
            do {
              try c.execute("BEGIN")
              try ProtocolGrantProtection.establish(c)
              try c.execute("DELETE FROM settings WHERE key=$1", [Self.controlKey])
              let value =
                stage == .sourceInsert
                ? try Self.activeSourceJSON(source)
                : Self.inactiveJSON(
                  "8", store: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC",
                  member: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")
              try c.execute(
                "INSERT INTO settings(key,value) VALUES ($1,$2::jsonb)", [Self.controlKey, value])
              if stage == .deferredCommit {
                try c.execute("SET CONSTRAINTS activation_restore_fault IMMEDIATE")
              }
            } catch let error as PostgresError {
              code = error.sqlState
              privateDetail = error.description.contains("ACTIVATION_RESTORE_PRIVATE_SENTINEL")
            } catch {
              try? c.execute("ROLLBACK")
              throw error
            }
            try c.execute("ROLLBACK")
            guard code == "23514", privateDetail else {
              throw ProtocolActivationRestoreOracle.Failure.fixture
            }
            try c.execute("ALTER SEQUENCE activation_fault.progress RESTART WITH 1")
          }
          let before = try Self.nativeState(destination)
          let sourceBefore = try Self.nativeState(source)
          let error = Self.caught { _ = try destination.restore(from: path, replace: replace) }
          try Self.safeRestoreFailure(error)
          let reached = try destination.read { c -> Bool in
            let row = try c.execute(
              "SELECT last_value::text AS n,is_called AS c FROM activation_fault.progress"
            ).rows.first
            return row?.text("n") == "1" && row?.text("c") == "t"
          }
          #expect(reached)
          let unchanged = try Self.nativeState(destination) == before
          let sourceUnchanged = try Self.nativeState(source) == sourceBefore
          #expect(unchanged); #expect(sourceUnchanged)
          _ = try destination.read {
            try $0.execute(
              "DROP TRIGGER activation_restore_fault ON settings; DROP FUNCTION activation_restore_fault(); DROP SCHEMA activation_fault CASCADE"
            )
          }
          let result = try destination.restore(from: path, replace: replace)
          #expect(result.rows == summary.rows)
          _ = try destination.read {
            try ProtocolActivationRestoreOracle.inactive(
              $0, revision: 8, previous: .init(store: Self.oldStore, member: Self.oldMember, revision: 7))
          }
          try Self.assertRows(source, destination)
        }
      }
    }
  }
}
