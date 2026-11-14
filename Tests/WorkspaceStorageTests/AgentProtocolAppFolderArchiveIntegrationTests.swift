import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

/// The published app-folder schema is a real source prefix, not an alias for an AP development DB.
@Suite(.serialized) struct AgentProtocolAppFolderArchiveIntegrationTests {
  private static let twelve = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay",
    "0006_usage", "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice",
    "0010_owned_rows", "0011_environments", "0012_app_folders",
  ]
  private static let thirteen = twelve + ["0013_view_settings"]
  private static let fourteen = thirteen + ["0014_connection_commands"]
  private static let fifteen = fourteen + ["0015_density"]
  private static let sixteen = fifteen + ["0016_agent_protocol"]
  private static let publishedTables = [
    "localServers", "environments", "environmentFolders", "connections", "threads", "appFolders",
    "turns", "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
    "settings", "usageReadings", "tokenUsage", "connectionUsage", "threadDeletes",
  ]
  private static let protocolTables = [
    "protocolSubscriptions", "protocolRunSegments", "protocolOperations", "protocolGrantSecrets",
    "protocolGrants", "protocolPromptAnswers", "protocolHistoryAnchors",
  ]

  @Test func publishedTwelveAndProtocolFourteenHaveDistinctClosedManifests() throws {
    let published = try WorkspaceArchive.schema(Self.twelve)
    let successor = try WorkspaceArchive.schema(Self.sixteen)
    #expect(published.data == Self.publishedTables)
    #expect(successor.data == Self.publishedTables + ["viewSettings"] + Self.protocolTables)
    #expect(successor.data.count == 26)
    #expect(published.context == ["schemaMigrations", "hubLink"])
    let viewSettings = try WorkspaceArchive.schema(Self.thirteen)
    #expect(viewSettings.data == Self.publishedTables + ["viewSettings"])
    #expect(viewSettings.context == published.context)
    #expect(try WorkspaceArchive.columns("viewSettings", at: 12).isEmpty)
    #expect(
      try WorkspaceArchive.columns("viewSettings", at: 13)
        == Set(["id", "arrangement", "quietThreads", "showArchived", "updatedAt"]))
    for table in Self.protocolTables { #expect(try WorkspaceArchive.columns(table, at: 13).isEmpty) }
    #expect(throws: WorkspaceArchive.Rejection.self) {
      try WorkspaceArchive.schema(Self.twelve + ["0013_agent_protocol"])
    }
    #expect(try WorkspaceArchive.columns("appFolders", at: 11).isEmpty)
    #expect(try WorkspaceArchive.columns("appFolders", at: 12) == Set(["path", "threadId", "createdAt"]))
    for table in Self.protocolTables {
      #expect(try WorkspaceArchive.columns(table, at: 12).isEmpty)
      #expect(try !WorkspaceArchive.columns(table, at: 16).isEmpty)
    }
    #expect(try !WorkspaceArchive.columns("connections", at: 12).contains("authMode"))
    #expect(try WorkspaceArchive.columns("connections", at: 16).contains("authMode"))
    #expect(try WorkspaceArchive.schema(Self.fourteen).data == Self.publishedTables + ["viewSettings"])
    #expect(try WorkspaceArchive.columns("connections", at: 14).contains("commands"))
    #expect(try !WorkspaceArchive.columns("connections", at: 13).contains("commands"))
    #expect(try !WorkspaceArchive.columns("connections", at: 14).contains("authMode"))
    for table in Self.protocolTables { #expect(try WorkspaceArchive.columns(table, at: 14).isEmpty) }
    #expect(
      try WorkspaceArchive.columns("viewSettings", at: 15)
        == Set(["id", "arrangement", "quietThreads", "showArchived", "updatedAt", "density"]))
    #expect(try !WorkspaceArchive.columns("viewSettings", at: 14).contains("density"))
    #expect(try !WorkspaceArchive.columns("connections", at: 15).contains("authMode"))
    for table in Self.protocolTables { #expect(try WorkspaceArchive.columns(table, at: 15).isEmpty) }
    for (prefixCount, draft) in [
      (10, "0011_agent_protocol"), (11, "0012_agent_protocol"), (13, "0014_agent_protocol"),
      (14, "0015_agent_protocol"),
    ] {
      let names = Array(Self.fifteen.prefix(prefixCount)) + [draft]
      #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.schema(names) }
    }
  }

  @Test func publishedV3AppFoldersKeepOpaqueJSONAndRejectUnknownFolderColumns() throws {
    let opaque = #"{"projectId":"external","environmentId":"keep","n":1e400}"#
    let folder: [String: Any] = ["path": "/fixture/app", "threadId": "t", "createdAt": "then"]
    func document(_ row: [String: Any]) throws -> Data {
      try Self.lines([
        ["format": "b4app-export", "version": 3, "migrations": Self.twelve],
        ["table": "appFolders", "row": row],
        [
          "table": "changes",
          "row": ["seq": 1, "table": "displayItems", "op": "update", "column": "payload", "value": opaque],
        ],
      ])
    }
    let input = try WorkspaceArchive.read(document(folder))
    #expect(input.records["appFolders"]?.first?.row["path"] as? String == "/fixture/app")
    #expect(input.records["changes"]?.first?.row["value"] as? String == opaque)
    var unknown = folder; unknown["grantMaterial"] = "must-refuse"
    #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(document(unknown)) }
    let mixed = try Self.lines([
      ["format": "b4app-export", "version": 3],
      ["table": "appFolders", "row": folder],
      ["table": "projects", "row": ["id": "old", "name": "mixed"]],
    ])
    #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(mixed) }
  }

  @Test func publishedThirteenViewSettingsStayOpaqueAndRejectUnknownColumns() throws {
    let row: [String: Any] = [
      "id": "view", "arrangement": "future-arrangement", "quietThreads": "future-quiet", "showArchived": true,
      "updatedAt": NSNull(),
    ]
    func archive(_ value: [String: Any]) throws -> Data {
      try Self.lines([
        ["format": "b4app-export", "version": 3, "migrations": Self.thirteen],
        ["table": "viewSettings", "row": value],
      ])
    }
    let input = try WorkspaceArchive.read(archive(row))
    let stored = try #require(input.records["viewSettings"]?.first?.row)
    #expect(stored as NSDictionary == row as NSDictionary)
    var unknown = row; unknown["unknownColumn"] = "must-refuse"
    #expect(throws: WorkspaceArchive.Rejection.self) { try WorkspaceArchive.read(archive(unknown)) }
    for version in [1, 2] {
      #expect(throws: WorkspaceArchive.Rejection.self) {
        try WorkspaceArchive.read(
          Self.lines([
            ["format": "b4app-export", "version": version], ["table": "viewSettings", "row": row],
          ]))
      }
    }
  }

  @Test func publishedV3DensityIsNullableOpaqueTextAndDoesNotAdmitOtherColumns() throws {
    for density in ["normal", "dense", "", "future-density", NSNull()] as [Any] {
      let row: [String: Any] = ["id": "view", "quietThreads": "tiny", "density": density]
      let bytes = try Self.lines([
        ["format": "b4app-export", "version": 3, "migrations": Self.fifteen],
        ["table": "viewSettings", "row": row],
      ])
      let stored = try #require(try WorkspaceArchive.read(bytes).records["viewSettings"]?.first?.row)
      #expect(stored as NSDictionary == row as NSDictionary)
      var unknown = row; unknown["peerProfile"] = "must-refuse"
      #expect(throws: WorkspaceArchive.Rejection.self) {
        try WorkspaceArchive.read(
          Self.lines([
            ["format": "b4app-export", "version": 3], ["table": "viewSettings", "row": unknown],
          ]))
      }
      for version in [1, 2] {
        #expect(throws: WorkspaceArchive.Rejection.self) {
          try WorkspaceArchive.read(
            Self.lines([
              ["format": "b4app-export", "version": version], ["table": "viewSettings", "row": row],
            ]))
        }
      }
    }
    for invalid in [true, 1, ["nested": "not-text"]] as [Any] {
      #expect(throws: WorkspaceArchive.Rejection.self) {
        try WorkspaceArchive.read(
          Self.lines([
            ["format": "b4app-export", "version": 3],
            ["table": "viewSettings", "row": ["id": "view", "density": invalid]],
          ]))
      }
    }
  }

  private struct PublishedCase: Sendable {
    let prefix: Int
    let quiet: String?
    let density: String?
    let hasRow: Bool
  }
  private static let publishedCases: [PublishedCase] =
    [
      .init(prefix: 12, quiet: nil, density: nil, hasRow: false),
      .init(prefix: 13, quiet: "future-quiet", density: nil, hasRow: true),
    ]
    + [13, 14].flatMap { prefix in
      ["small", "tiny", "collapsed", "hidden", "shown", "future-quiet"].map {
        PublishedCase(prefix: prefix, quiet: $0, density: nil, hasRow: true)
      } + [
        .init(prefix: prefix, quiet: nil, density: nil, hasRow: true),
        .init(prefix: prefix, quiet: nil, density: nil, hasRow: false),
      ]
    } + [
      .init(prefix: 15, quiet: "shown", density: "normal", hasRow: true),
      .init(prefix: 15, quiet: "shown", density: "dense", hasRow: true),
      .init(prefix: 15, quiet: "future-quiet", density: "future-density", hasRow: true),
      .init(prefix: 15, quiet: "tiny", density: nil, hasRow: true),
      .init(prefix: 15, quiet: "tiny", density: "future-density", hasRow: true),
      .init(prefix: 15, quiet: "hidden", density: "", hasRow: true),
      .init(prefix: 15, quiet: nil, density: nil, hasRow: true),
      .init(prefix: 15, quiet: nil, density: nil, hasRow: false),
    ]
  @Test(arguments: Self.publishedCases)
  private func genuinePublishedFoldersViewAndCommandsArchivesSurviveSixteenAndReopen(
    fixture: PublishedCase
  ) throws {
    let prefix = fixture.prefix
    let sourceNames =
      prefix == 12
      ? Self.twelve
      : prefix == 13
        ? Self.thirteen
        : prefix == 14 ? Self.fourteen : Self.fifteen
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "ap-app-folders-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let backups = root + "/backups"
    let v3 = root + "/published-v3.jsonl", v4 = root + "/published-v4.jsonl"
    let before: [String: [String]]
    let beforeDensity: AgentProtocolFoundationFixture.DensityFacts
    let beforeFacts: AgentProtocolFoundationFixture.ArchiveFacts
    let beforeSequence: String?
    let beforeLedger: [String]
    let beforeHubContext: [String]
    let sourcePrefix = try AgentProtocolFoundationFixture.preservationPrefix(
      sourceNames, expectedCount: prefix)
    do {
      let raw = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      try Migrator.ensureLedger(raw, table: Migrator.table)
      for file in try Migrator.files().prefix(prefix) {
        try raw.execute(file.sql)
        try raw.execute(
          "INSERT INTO \"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'published12')", [file.name])
      }
      try #require(try Migrator.recorded(raw) == sourceNames)
      try raw.execute(
        """
        SET b4app.replaying='on';
        INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
          VALUES ('c','codex','Native','/fixture/codex','{}','ready','authenticated','then','then');
        INSERT INTO threads (id,"connectionId","nativeThreadId",context,"createdAt","updatedAt")
          VALUES ('t','c','native-12','/fixture/app','then','then');
        INSERT INTO "appFolders" (path,"threadId","createdAt") VALUES ('/fixture/app','t','then');
        INSERT INTO turns (id,"threadId","operationId",status,submission,outcome,"createdAt","updatedAt")
          VALUES ('u','t','op','terminal','acknowledged','completed','then','then');
        INSERT INTO "displayItems" (id,"threadId","turnId",role,type,payload,sequence,provenance,"createdAt")
          VALUES ('i','t','u','assistant','agentMessage','{"projectId":"external","environmentId":"keep","n":1e400}',0,'cache','then');
        INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
          VALUES ('fixture',1,'displayItems','i','update','payload','{"projectId":"external","n":1e-400}','000000001000-0000-fixture');
        RESET b4app.replaying;
        """)
      if prefix >= 13, fixture.hasRow {
        try raw.execute("SET b4app.replaying='on'")
        try raw.execute(
          #"INSERT INTO "viewSettings" (id,arrangement,"quietThreads","showArchived","updatedAt") VALUES ('view','future-arrangement',$1,true,NULL)"#,
          [fixture.quiet])
        if prefix >= 15 {
          try raw.execute(#"UPDATE "viewSettings" SET density=$1 WHERE id='view'"#, [fixture.density])
        }
        try raw.execute("RESET b4app.replaying")
      }
      if prefix >= 14 {
        try Self.seedPublishedCommands(raw)
      }
      _ = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: prefix)
      beforeDensity = try AgentProtocolFoundationFixture.densityFacts(raw, source: sourcePrefix)
      before = try Self.snapshot(raw, includeViewSettings: prefix >= 13)
      beforeFacts = try AgentProtocolFoundationFixture.archiveFacts(raw)
      beforeSequence = try raw.execute(
        #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
      ).rows.first?.text("value")
      beforeHubContext = try raw.execute(#"SELECT to_jsonb(h)::text AS row FROM "hubLink" h ORDER BY id"#)
        .rows.compactMap { $0.text("row") }
      beforeLedger = try raw.execute(
        #"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m ORDER BY name"#
      )
      .rows.compactMap { $0.text("row") }
      // The legacy12/13 fixtures intentionally retain NULL runtime choices, independently of projection.
      if prefix < 14 {
        #expect(try raw.execute(#"SELECT 1 FROM connections WHERE models IS NOT NULL"#).rows.isEmpty)
        #expect(
          try raw.execute(#"SELECT 1 FROM threads WHERE model IS NOT NULL OR permission IS NOT NULL"#).rows
            .isEmpty)
      }
      // This is the fixed published v3 writer order, independent of the current v4 manifest.
      let legacyTables =
        [
          "localServers", "connections", "environments", "environmentFolders", "threads", "appFolders",
          "turns",
          "displayItems", "runtimeRequests", "drafts", "devices", "changes", "columnClocks",
        ] + (prefix >= 13 ? ["viewSettings"] : [])
      var records: [[String: Any]] = [["format": "b4app-export", "version": 3, "migrations": sourceNames]]
      for table in legacyTables {
        for row in try raw.execute("SELECT * FROM \(Rows.quote(table)) ORDER BY 1").rows {
          var values: [String: Any] = [:]
          for (key, cell) in row.cells { values[key] = try WorkspaceDatabase.jsonObject(cell) }
          records.append(["table": table, "row": values])
        }
      }
      let legacyBytes = try Self.lines(records)
      try #require(
        FileManager.default.createFile(
          atPath: v3, contents: legacyBytes, attributes: [.posixPermissions: 0o600]))
      try raw.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
      do {
        try ProtocolGrantProtection.establish(raw)
        let present = Set(
          try raw.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'").rows.compactMap {
            $0.text("tablename")
          })
        let schema = try WorkspaceArchive.captureSchema(raw, present: present)
        try #require(schema.migrations == sourceNames)
        try ArchivePublication.write(to: v4) { handle in
          _ = try WorkspaceArchive.write(raw, schema: schema, purpose: "preMigration", handle: handle)
        }
        try raw.execute("COMMIT")
      } catch { try? raw.execute("ROLLBACK"); throw error }
    }
    let restoredExpected = try Self.expectedRows(before, density: beforeDensity, path: .archiveRestore)
    let migratedExpected = try Self.expectedRows(before, density: beforeDensity, path: .nativeMigration)
    for path in [v3, v4] {
      let target = try AgentProtocolResourceFixture.database()
      let destinationLedger = try target.read {
        try $0.execute(#"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m ORDER BY name"#).rows
          .compactMap { $0.text("row") }
      }
      let outcome = Result<Void, any Error> { () throws -> Void in
        try target.restore(from: path)
        #expect(
          try target.read {
            try $0.execute(#"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m ORDER BY name"#).rows
              .compactMap { $0.text("row") }
          } == destinationLedger)
        #expect(try target.read { try $0.execute(#"SELECT 1 FROM "hubLink""#).rows.isEmpty })
        let restored = try target.read { c -> [String: [String]] in
          _ = try ProtocolActivationRestoreOracle.inactive(c, revision: 0)
          try AgentProtocolFoundationFixture.requireNativeJSONRetained(
            beforeFacts,
            after: AgentProtocolFoundationFixture.archiveFacts(c), tables: Array(before.keys))
          var rows = try Self.snapshot(
            c, includeViewSettings: prefix >= 13, source: sourcePrefix, originalRows: before,
            density: beforeDensity, densityPath: .archiveRestore)
          rows["settings"] = try c.execute(
            "SELECT to_jsonb(t)::text AS row FROM settings t WHERE key IS DISTINCT FROM $1 ORDER BY 1",
            [ProtocolActivationRestoreOracle.key]
          ).rows.compactMap { $0.text("row") }
          return rows
        }
        #expect(
          restored.mapValues { $0.map { Data($0.utf8) } }
            == restoredExpected.mapValues { $0.map { Data($0.utf8) } })
        if fixture.quiet == "tiny", fixture.density == nil {
          let rawBeforeRead = try target.read { try Self.snapshot($0, includeViewSettings: true) }
          #expect(try target.viewSettings().quietThreads == .shown)
          #expect(try target.viewSettings().density == .dense)
          #expect(try target.read { try Self.snapshot($0, includeViewSettings: true) } == rawBeforeRead)
          try target.read {
            try AgentProtocolFoundationFixture.requireDensity(
              $0, original: beforeDensity, path: .archiveRestore)
          }
          try target.write { raw in
            try raw.execute("SET LOCAL b4app.replaying='on'; SAVEPOINT raw_density_oracle")
            do {
              try #require(
                try raw.execute(
                  #"UPDATE "viewSettings" SET "quietThreads"='shown',density='dense' WHERE id='view'"#
                ).affected == 1)
              var refused = false
              do {
                try AgentProtocolFoundationFixture.requireDensity(
                  raw, original: beforeDensity, path: .archiveRestore)
              } catch AgentProtocolFoundationFixture.Failure.row { refused = true }
              #expect(refused)
              try raw.execute(
                "ROLLBACK TO SAVEPOINT raw_density_oracle; RELEASE SAVEPOINT raw_density_oracle")
            } catch { try? raw.execute("ROLLBACK TO SAVEPOINT raw_density_oracle"); throw error }
          }
          #expect(try target.read { try Self.snapshot($0, includeViewSettings: true) } == rawBeforeRead)
        }
        let currentPath = root + "/restored-current16-" + URL(fileURLWithPath: path).lastPathComponent
        try target.export(to: currentPath)
        let again = try AgentProtocolResourceFixture.database()
        let currentOutcome = Result<Void, any Error> { () throws -> Void in
          let currentDensity = try target.read {
            try AgentProtocolFoundationFixture.densityFacts(
              $0,
              source: AgentProtocolFoundationFixture.preservationPrefix($0, expectedCount: 16))
          }
          try again.restore(from: currentPath)
          try again.read {
            try AgentProtocolFoundationFixture.requireDensity(
              $0, original: currentDensity, path: .archiveRestore)
          }
          let currentBefore = try target.read { raw in
            var result = try Self.snapshot(raw, includeViewSettings: true)
            result["settings"] = try raw.execute(
              "SELECT to_jsonb(t)::text AS row FROM settings t WHERE key IS DISTINCT FROM $1 ORDER BY 1",
              [ProtocolActivationRestoreOracle.key]
            ).rows.compactMap { $0.text("row") }
            return result
          }
          let currentAfter = try again.read { raw in
            _ = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: 16)
            try AgentProtocolFoundationFixture.requireNativeJSONRetained(
              beforeFacts,
              after: AgentProtocolFoundationFixture.archiveFacts(raw), tables: Array(before.keys))
            try Self.assertFixturePrivateEmpty(raw)
            _ = try ProtocolActivationRestoreOracle.inactive(raw, revision: 0)
            var result = try Self.snapshot(raw, includeViewSettings: true)
            result["settings"] = try raw.execute(
              "SELECT to_jsonb(t)::text AS row FROM settings t WHERE key IS DISTINCT FROM $1 ORDER BY 1",
              [ProtocolActivationRestoreOracle.key]
            ).rows.compactMap { $0.text("row") }
            return result
          }
          #expect(
            currentAfter.mapValues { $0.map { Data($0.utf8) } }
              == currentBefore.mapValues { $0.map { Data($0.utf8) } })
        }
        try again.close()
        try currentOutcome.get()
        #expect(try target.appliedMigrations() == Self.sixteen)
        try target.read {
          if prefix < 14 { try AgentProtocolFoundationFixture.assertAdditionsNullAndPrivateEmpty($0) }
          try Self.assertFixturePrivateEmpty($0)
        }
        #expect(
          try target.read {
            try $0.execute("SELECT 1 FROM \"schemaMigrations\" WHERE \"appliedAt\"='published12'").rows
              .isEmpty
          })
      }
      try target.close()
      try outcome.get()
    }
    let source = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backups)
    let outcome = Result<Void, any Error> { () throws -> Void in
      #expect(try source.appliedMigrations() == Self.sixteen)
      #expect(
        try source.read {
          try $0.execute(
            #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
          ).rows.first?.text("value")
        } == beforeSequence)
      try source.read {
        if prefix < 14 { try AgentProtocolFoundationFixture.assertAdditionsNullAndPrivateEmpty($0) }
        try Self.assertFixturePrivateEmpty($0)
        try AgentProtocolFoundationFixture.requireNativeJSONRetained(
          beforeFacts,
          after: AgentProtocolFoundationFixture.archiveFacts($0), tables: Array(before.keys))
        let ledger = try $0.execute(
          #"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m WHERE name<'0016' ORDER BY name"#
        )
        .rows.compactMap { $0.text("row") }
        #expect(Set(beforeLedger).isSubset(of: Set(ledger)))
        #expect(
          try $0.execute(#"SELECT to_jsonb(h)::text AS row FROM "hubLink" h ORDER BY id"#).rows.compactMap {
            $0.text("row")
          } == beforeHubContext)
      }
      #expect(
        try source.read {
          try Self.snapshot(
            $0, includeViewSettings: prefix >= 13, source: sourcePrefix, originalRows: before,
            density: beforeDensity, densityPath: .nativeMigration)
        }.mapValues { $0.map { Data($0.utf8) } } == migratedExpected.mapValues { $0.map { Data($0.utf8) } })
      #expect(try source.appFolder(threadId: "t")?.path == "/fixture/app")
      #expect(try source.thread(id: "t")?.environmentId == nil)
      let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups)
      try #require(backupNames.count == 1 && backupNames[0].hasSuffix(".jsonl"))
      let backup = try WorkspaceArchive.read(
        Data(contentsOf: URL(fileURLWithPath: backups + "/" + backupNames[0])))
      #expect(backup.records["schemaMigrations"]?.compactMap { $0.row["name"] as? String } == sourceNames)
      #expect(backup.records["appFolders"]?.first?.row["threadId"] as? String == "t")
      let nativePayload: String? = try source.read { (raw: PostgresConnection) throws -> String? in
        let rows = try raw.execute(#"SELECT payload::text AS payload FROM "displayItems" WHERE id='i'"#).rows
        return rows.first?.text("payload")
      }
      let backupPayload = backup.records["displayItems"]?.first?.row["payload"] as? String
      #expect(backupPayload.map { Data($0.utf8) } == nativePayload.map { Data($0.utf8) })
      try source.export(to: root + "/current16.jsonl")
      let exported = try WorkspaceArchive.read(
        Data(contentsOf: URL(fileURLWithPath: root + "/current16.jsonl")))
      #expect(exported.records["appFolders"]?.first?.row["threadId"] as? String == "t")
      let migratedRestore = try AgentProtocolResourceFixture.database()
      let migratedOutcome = Result<Void, any Error> { () throws -> Void in
        let destinationLedger = try migratedRestore.read {
          try $0.execute(#"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m ORDER BY name"#).rows
            .compactMap { $0.text("row") }
        }
        let currentDensity = try source.read {
          try AgentProtocolFoundationFixture.densityFacts(
            $0,
            source: AgentProtocolFoundationFixture.preservationPrefix($0, expectedCount: 16))
        }
        try migratedRestore.restore(from: root + "/current16.jsonl")
        try migratedRestore.read {
          try AgentProtocolFoundationFixture.requireDensity(
            $0, original: currentDensity, path: .archiveRestore)
        }
        try migratedRestore.read {
          _ = try AgentProtocolFoundationFixture.preservationPrefix($0, expectedCount: 16)
          _ = try ProtocolActivationRestoreOracle.inactive($0, revision: 0)
          try Self.assertFixturePrivateEmpty($0)
          try AgentProtocolFoundationFixture.requireNativeJSONRetained(
            beforeFacts,
            after: AgentProtocolFoundationFixture.archiveFacts($0), tables: Array(before.keys))
          #expect(
            try $0.execute(#"SELECT to_jsonb(m)::text AS row FROM "schemaMigrations" m ORDER BY name"#).rows
              .compactMap { $0.text("row") } == destinationLedger)
          #expect(try $0.execute(#"SELECT 1 FROM "hubLink""#).rows.isEmpty)
        }
        let migratedRows = try source.read { try Self.snapshot($0, includeViewSettings: true) }
        var restoredRows = try migratedRestore.read { try Self.snapshot($0, includeViewSettings: true) }
        restoredRows["settings"] = try migratedRestore.read {
          try $0.execute(
            "SELECT to_jsonb(t)::text AS row FROM settings t WHERE key IS DISTINCT FROM $1 ORDER BY 1",
            [ProtocolActivationRestoreOracle.key]
          ).rows.compactMap { $0.text("row") }
        }
        #expect(
          restoredRows.mapValues { $0.map { Data($0.utf8) } }
            == migratedRows.mapValues { $0.map { Data($0.utf8) } })
      }
      try migratedRestore.close()
      try migratedOutcome.get()
    }
    try source.close()
    try outcome.get()
    let published = try FileManager.default.contentsOfDirectory(atPath: backups).sorted()
    let reopened = try WorkspaceDatabase(
      endpoint: endpoint, binDir: endpoint.binDir!, backupDirectory: backups)
    let reopenedOutcome = Result<Void, any Error> { () throws -> Void in
      try reopened.read {
        try AgentProtocolFoundationFixture.requireNativeJSONRetained(
          beforeFacts,
          after: AgentProtocolFoundationFixture.archiveFacts($0), tables: Array(before.keys))
        try Self.assertFixturePrivateEmpty($0)
        #expect(
          try $0.execute(#"SELECT to_jsonb(h)::text AS row FROM "hubLink" h ORDER BY id"#).rows.compactMap {
            $0.text("row")
          } == beforeHubContext)
      }
      #expect(
        try reopened.read {
          try Self.snapshot(
            $0, includeViewSettings: prefix >= 13, source: sourcePrefix, originalRows: before,
            density: beforeDensity, densityPath: .nativeMigration)
        }.mapValues { $0.map { Data($0.utf8) } } == migratedExpected.mapValues { $0.map { Data($0.utf8) } })
      #expect(try reopened.appliedMigrations() == Self.sixteen)
      #expect(
        try reopened.read {
          try $0.execute(
            #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
          ).rows.first?.text("value")
        } == beforeSequence)
      #expect(try FileManager.default.contentsOfDirectory(atPath: backups).sorted() == published)
    }
    try reopened.close()
    try reopenedOutcome.get()
  }

  /// A separate SQL15 BODY control on a canonical15 table. It does not admit a physical density
  /// column under a14 ledger and does not model15→16, which must never run this conversion again.
  @Test(arguments: [
    (
      quiet: "tiny", density: "future-density" as String?, expectedQuiet: "shown",
      expectedDensity: "future-density"
    ),
    (quiet: "small", density: "", expectedQuiet: "shown", expectedDensity: ""),
    (quiet: "collapsed", density: "dense", expectedQuiet: "collapsed", expectedDensity: "dense"),
    (quiet: "hidden", density: "normal", expectedQuiet: "hidden", expectedDensity: "normal"),
    (quiet: "tiny", density: nil, expectedQuiet: "shown", expectedDensity: "dense"),
    (quiet: "tiny", density: "normal", expectedQuiet: "shown", expectedDensity: "normal"),
    (quiet: "small", density: "dense", expectedQuiet: "shown", expectedDensity: "dense"),
    (
      quiet: "future-quiet", density: "future-density", expectedQuiet: "future-quiet",
      expectedDensity: "future-density"
    ),
  ])
  func publishedDensityBodyKeepsAnAlreadyStoredDensity(
    row: (quiet: String, density: String?, expectedQuiet: String, expectedDensity: String)
  ) throws {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    let files = try Migrator.files()
    for file in files.prefix(15) {
      try raw.execute("BEGIN")
      do {
        try raw.execute(file.sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" (name,"appliedAt") VALUES ($1,'density-body-source15')"#,
          [file.name])
        try raw.execute("COMMIT")
      } catch { try? raw.execute("ROLLBACK"); throw error }
    }
    let source = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: 15)
    try raw.execute(
      #"INSERT INTO "viewSettings" (id,arrangement,"quietThreads",density,"showArchived","updatedAt") VALUES ('view','future-arrangement',$1,$2,true,'then')"#,
      [row.quiet, row.density])
    let original = try Self.snapshot(raw, includeViewSettings: true)
    let originalDensity = try AgentProtocolFoundationFixture.densityFacts(raw, source: source)
    #expect(
      originalDensity.rows["view"]?["density"] == AgentProtocolFoundationFixture.NativeTextCell(row.density))
    let ledger = try raw.execute(#"SELECT to_jsonb(t)::text AS row FROM "schemaMigrations" t ORDER BY name"#)
      .rows.compactMap { $0.text("row") }
    let sequence = try raw.execute(
      #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
    ).rows.first?.text("value")
    let sql = try #require(files.first { $0.name == "0015_density" }?.sql)
    let bodyStart = try #require(sql.range(of: "SET LOCAL b4app.replaying = 'on';"))
    let body = String(sql[bodyStart.lowerBound...])
    try raw.execute("BEGIN")
    do { try raw.execute(body); try raw.execute("COMMIT") } catch {
      try? raw.execute("ROLLBACK"); throw error
    }
    let actual = try Self.snapshot(raw, includeViewSettings: true)
    let actualDensity = try AgentProtocolFoundationFixture.densityFacts(raw, source: source)
    #expect(
      actualDensity.rows["view"] == [
        "quietThreads": AgentProtocolFoundationFixture.NativeTextCell(row.expectedQuiet),
        "density": AgentProtocolFoundationFixture.NativeTextCell(row.expectedDensity),
      ])
    for (table, values) in original where table != "viewSettings" {
      #expect(actual[table]?.map { Data($0.utf8) } == values.map { Data($0.utf8) })
    }
    let expectedView = try (original["viewSettings"] ?? []).map { text -> Data in
      guard var expected = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      else { throw AgentProtocolFoundationFixture.Failure.row }
      expected["quietThreads"] = row.expectedQuiet; expected["density"] = row.expectedDensity
      return Data(try AgentProtocolFoundationFixture.canonical(expected).utf8)
    }
    let actualView = try (actual["viewSettings"] ?? []).map {
      Data(
        try AgentProtocolFoundationFixture.canonical(JSONSerialization.jsonObject(with: Data($0.utf8))).utf8)
    }
    #expect(actualView == expectedView)
    #expect(
      try raw.execute(#"SELECT to_jsonb(t)::text AS row FROM "schemaMigrations" t ORDER BY name"#)
        .rows.compactMap { $0.text("row") } == ledger)
    #expect(
      try raw.execute(
        #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
      ).rows.first?.text("value") == sequence)
  }

  @Test func everyEmptyOriginalPrefixRequiresItsLiteralLedgerAndPhysicalBoundary() throws {
    for count in 8...16 {
      let endpoint = try AgentProtocolResourceFixture.endpoint()
      let raw = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      try Migrator.ensureLedger(raw, table: Migrator.table)
      let names = Array(AgentProtocolFoundationFixture.migrations.prefix(count))
      for file in try Migrator.files().prefix(count) {
        try raw.execute(file.sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" (name,"appliedAt") VALUES ($1,'empty-prefix')"#, [file.name])
      }
      #expect(try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: count).names == names)
      if count == 14 {
        try raw.execute("BEGIN")
        do {
          try raw.execute(#"ALTER TABLE "viewSettings" ADD COLUMN density text"#)
          var refused = false
          do {
            _ = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: count)
          } catch AgentProtocolFoundationFixture.Failure.schema { refused = true }
          #expect(refused)
          try raw.execute("ROLLBACK")
        } catch { try? raw.execute("ROLLBACK"); throw error }
      }
    }
    for malformed in [
      Self.thirteen + ["0014_agent_protocol"], Self.fourteen + ["0015_agent_protocol"],
      Self.fifteen + ["0016_unknown"], Self.fifteen + ["0015_density"],
      Array(Self.sixteen.reversed()),
    ] {
      var refused = false
      do {
        _ = try AgentProtocolFoundationFixture.preservationPrefix(malformed, expectedCount: malformed.count)
      } catch AgentProtocolFoundationFixture.Failure.canonicalSet { refused = true }
      #expect(refused)
    }
  }

  @Test(arguments: Self.publishedCases.filter { $0.prefix >= 13 })
  private func densityOracleRejectsWrongValuesLostQuietAndMissingOrExtraOriginalRows(
    fixture: PublishedCase
  ) throws {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    try Migrator.ensureLedger(raw, table: Migrator.table)
    for file in try Migrator.files().prefix(fixture.prefix) {
      try raw.execute(file.sql)
      try raw.execute(
        #"INSERT INTO "schemaMigrations" (name,"appliedAt") VALUES ($1,'density-oracle')"#, [file.name])
    }
    if fixture.hasRow {
      try raw.execute("SET b4app.replaying='on'")
      try raw.execute(
        #"INSERT INTO "viewSettings" (id,arrangement,"quietThreads") VALUES ('view','future-arrangement',$1)"#,
        [fixture.quiet])
      if fixture.prefix == 15 {
        try raw.execute(#"UPDATE "viewSettings" SET density=$1 WHERE id='view'"#, [fixture.density])
      }
      try raw.execute("RESET b4app.replaying")
    }
    let source = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: fixture.prefix)
    let density = try AgentProtocolFoundationFixture.densityFacts(raw, source: source)
    _ = try Migrator.migrate(raw)
    try AgentProtocolFoundationFixture.requireDensity(raw, original: density, path: .nativeMigration)
    let baseline = try Self.snapshot(raw, includeViewSettings: true)
    let sequence = try raw.execute(
      #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
    ).rows.first?.text("value")
    var mutations = [
      #"INSERT INTO "viewSettings" (id,"quietThreads",density) VALUES ('extra-original','tiny',NULL)"#
    ]
    if fixture.hasRow {
      mutations += [
        #"UPDATE "viewSettings" SET "quietThreads"='corrupt-quiet' WHERE id='view'"#,
        #"UPDATE "viewSettings" SET density='corrupt-density' WHERE id='view'"#,
        #"DELETE FROM "viewSettings" WHERE id='view'"#,
      ]
      let expected = try AgentProtocolFoundationFixture.expectedDensityCells(
        try #require(density.rows["view"]), source: source, path: .nativeMigration)
      if expected["quietThreads"]?.isNull == false {
        mutations.append(#"UPDATE "viewSettings" SET "quietThreads"=NULL WHERE id='view'"#)
      }
      if expected["density"]?.isNull == false {
        mutations.append(#"UPDATE "viewSettings" SET density=NULL WHERE id='view'"#)
      }
    }
    for sql in mutations {
      try raw.execute("BEGIN; SET LOCAL b4app.replaying='on'")
      do {
        try #require(try raw.execute(sql).affected == 1)
        var refused = false
        do {
          try AgentProtocolFoundationFixture.requireDensity(raw, original: density, path: .nativeMigration)
        } catch AgentProtocolFoundationFixture.Failure.row { refused = true }
        #expect(refused)
        try raw.execute("ROLLBACK")
      } catch { try? raw.execute("ROLLBACK"); throw error }
      #expect(try Self.snapshot(raw, includeViewSettings: true) == baseline)
      #expect(
        try raw.execute(
          #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
        ).rows.first?.text("value") == sequence)
    }
  }

  @Test func fixedPrimaryKeyLocatorIgnoresNestedAndQuotedIDText() throws {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    let id = "owner-🌱-\"quoted\"-\\tail"
    let row = try #require(
      try raw.execute(
        #"SELECT jsonb_build_object('id',$1::text,'commands','{"id":"nested","text":"\"id\":\"misleading\"","n":1e400}'::jsonb)::text AS row"#,
        [id]
      ).rows.first?.text("row"))
    #expect(try Data(AgentProtocolFoundationFixture.rowIdentifier(row, key: "id").utf8) == Data(id.utf8))
    for invalid in [
      #"{"commands":{"id":"nested"}}"#, #"{"id":"one","id":"two"}"#,
      #"{"id":null}"#, #"{"id":true}"#, #"{"id":1.5}"#, #"{"id":{"id":"nested"}}"#,
    ] {
      var refused = false
      do {
        _ = try AgentProtocolFoundationFixture.rowIdentifier(invalid, key: "id")
      } catch AgentProtocolFoundationFixture.Failure.row { refused = true }
      #expect(refused)
    }
  }

  @Test func preservationOracleRejectsOpaqueCorruptionAndPrematureCommands() throws {
    for prefix in [13, 14] {
      let endpoint = try AgentProtocolResourceFixture.endpoint()
      let raw = try PostgresConnection(
        lib: LibPQ.load(binDir: endpoint.binDir!),
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
      try Migrator.ensureLedger(raw, table: Migrator.table)
      for file in try Migrator.files().prefix(prefix) {
        try raw.execute(file.sql)
        try raw.execute(
          #"INSERT INTO "schemaMigrations" (name,"appliedAt") VALUES ($1,'oracle-source')"#, [file.name])
      }
      if prefix == 13 {
        // A physical commands column under a genuine13 ledger fails even without any row value.
        try raw.execute("BEGIN")
        do {
          try raw.execute("ALTER TABLE connections ADD COLUMN commands jsonb")
          var refused = false
          do {
            _ = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: 13)
          } catch AgentProtocolFoundationFixture.Failure.schema { refused = true }
          #expect(refused)
          try raw.execute("ROLLBACK")
        } catch { try? raw.execute("ROLLBACK"); throw error }
      }
      try raw.execute(
        """
        SET b4app.replaying='on';
        INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
          VALUES ('c','codex','Retained','/fixture/codex','{}','ready','authenticated','then','then');
        INSERT INTO threads (id,"connectionId","nativeThreadId","createdAt","updatedAt")
          VALUES ('t','c','oracle-thread','then','then');
        INSERT INTO turns (id,"threadId","operationId",status,submission,outcome,"createdAt","updatedAt")
          VALUES ('u','t','op','terminal','acknowledged','completed','then','then');
        RESET b4app.replaying;
        """)
      if prefix == 14 { try Self.seedPublishedCommands(raw) }
      let source = try AgentProtocolFoundationFixture.preservationPrefix(raw, expectedCount: prefix)
      let before = try Self.snapshot(raw, includeViewSettings: true)
      let facts = try AgentProtocolFoundationFixture.archiveFacts(raw)
      let density = try AgentProtocolFoundationFixture.densityFacts(raw, source: source)
      _ = try Migrator.migrate(raw)
      try Self.requireRetainedFixture(raw, before: before, facts: facts, source: source, density: density)
      let updates =
        prefix == 13
        ? [
          #"UPDATE connections SET commands='[{"name":"illicit"}]' WHERE id='c'"#,
          #"UPDATE connections SET commands='null' WHERE id='c'"#,
        ]
        : [
          #"UPDATE connections SET commands='[{"name":"review","unknown":{"changed":true}}]' WHERE id='c'"#,
          #"UPDATE connections SET commands='null' WHERE id='command-sql-null'"#,
          #"UPDATE connections SET commands=NULL WHERE id='command-json-null'"#,
          #"UPDATE connections SET commands='{"unknown":[false,null],"n":1e400}' WHERE id='command-object'"#,
          #"UPDATE connections SET commands='"changed scalar"' WHERE id='command-string'"#,
          #"UPDATE connections SET commands='1e399' WHERE id='command-number'"#,
          #"UPDATE connections SET models='[{"id":"corrupt"}]' WHERE id='c'"#,
          #"UPDATE connections SET models='null' WHERE id='command-sql-null'"#,
          #"UPDATE threads SET model='changed-model' WHERE id='t'"#,
          #"UPDATE threads SET permission='changed-permission' WHERE id='t'"#,
        ]
      let exactCurrent = try Self.snapshot(raw, includeViewSettings: true)
      let sequence = try raw.execute(
        #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
      ).rows.first?.text("value")
      for update in updates {
        try raw.execute("BEGIN; SET LOCAL b4app.replaying='on'")
        do {
          try raw.execute(update)
          var refused = false
          do {
            try Self.requireRetainedFixture(
              raw, before: before, facts: facts, source: source, density: density)
          } catch AgentProtocolFoundationFixture.Failure.row { refused = true }
          #expect(refused)
          try raw.execute("ROLLBACK")
        } catch { try? raw.execute("ROLLBACK"); throw error }
        #expect(try Self.snapshot(raw, includeViewSettings: true) == exactCurrent)
        #expect(
          try raw.execute(
            #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
          ).rows.first?.text("value") == sequence)
      }
    }
    for names in [
      Self.thirteen + ["0014_agent_protocol"], Self.thirteen + ["0014_unknown"],
      Self.thirteen + ["0013_view_settings"],
    ] {
      var refused = false
      do {
        _ = try AgentProtocolFoundationFixture.preservationPrefix(names, expectedCount: 14)
      } catch AgentProtocolFoundationFixture.Failure.canonicalSet { refused = true }
      #expect(refused)
    }
  }

  private static func requireRetainedFixture(
    _ raw: PostgresConnection,
    before: [String: [String]], facts: AgentProtocolFoundationFixture.ArchiveFacts,
    source: AgentProtocolFoundationFixture.PreservationPrefix,
    density: AgentProtocolFoundationFixture.DensityFacts
  ) throws {
    try AgentProtocolFoundationFixture.requireNativeJSONRetained(
      facts,
      after: AgentProtocolFoundationFixture.archiveFacts(raw), tables: Array(before.keys))
    guard
      try snapshot(
        raw, includeViewSettings: true, source: source, originalRows: before,
        density: density, densityPath: .nativeMigration
      ).mapValues({
        $0.map { Data($0.utf8) }
      })
        == expectedRows(before, density: density, path: .nativeMigration).mapValues({
          $0.map { Data($0.utf8) }
        })
    else { throw AgentProtocolFoundationFixture.Failure.row }
  }

  @Test func viewSettingsRestoreExceptionDoesNotAdmitUnrelatedSettings() throws {
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "ap-view-empty-\(UUID())"
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: root) }
    let source = try AgentProtocolResourceFixture.database()
    defer { try? source.close() }
    let target = try AgentProtocolResourceFixture.database()
    defer { try? target.close() }
    try source.export(to: root + "/empty.jsonl")
    _ = try target.setViewSettings(quietThreads: .hidden, showArchived: true)
    try target.setSetting(key: "unrelated-owner-setting", value: .string("keep-exact"))
    let before = try target.read { try Self.snapshot($0, includeViewSettings: true) }
    let ledger = try target.appliedMigrations()
    let sequence = try #require(
      try target.read {
        try $0.execute(
          #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
        ).rows.first?.text("value")
      })
    let outcome = Result<Void, any Error> { () throws -> Void in
      var failure: (any Error)?
      do { try target.restore(from: root + "/empty.jsonl") } catch { failure = error }
      let refusal = try #require(failure as? WorkspaceError)
      #expect(refusal.code == .protocolInvalid)
      #expect(refusal.message == "The store is not empty; pass --replace to overwrite it from the archive.")
      #expect(refusal.details == nil)
      #expect(
        try target.read { try Self.snapshot($0, includeViewSettings: true) }.mapValues {
          $0.map { Data($0.utf8) }
        } == before.mapValues { $0.map { Data($0.utf8) } })
      #expect(try target.appliedMigrations() == ledger)
      #expect(
        try target.read {
          try $0.execute(
            #"SELECT last_value::text||':'||log_cnt::text||':'||is_called::text AS value FROM "changes_seq_seq""#
          ).rows.first?.text("value")
        } == sequence)
      #expect(try target.settings(key: "unrelated-owner-setting") == .string("keep-exact"))
    }
    try target.close()
    try source.close()
    try outcome.get()
  }

  private static func assertFixturePrivateEmpty(_ raw: PostgresConnection) throws {
    for table in protocolTables {
      guard try raw.execute("SELECT 1 FROM \(Rows.quote(table)) LIMIT 1").rows.isEmpty else {
        throw AgentProtocolFoundationFixture.Failure.row
      }
    }
  }
  private static func seedPublishedCommands(_ raw: PostgresConnection) throws {
    // These are opaque published JSONB cells, not RuntimeCommand execution or normalization inputs.
    try raw.execute(
      """
      SET b4app.replaying='on';
      UPDATE connections SET models='[{"id":"model","unknown":{"n":1e400,"id":"wrong-nested-owner","text":"key-like id text"}}]',
        commands='[{"name":"review","description":"Retained description","args":"<path>","aliases":["rv"],"unknown":{"n":1e400,"id":"wrong-nested-owner","text":"key-like id text"}}]'
        WHERE id='c';
      INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt",commands,models)
        VALUES ('command-object','codex','Object','/fixture/codex','{}','ready','authenticated','then','then','{"unknown":[true,null],"n":1e400}','null'),
          ('command-string','claude','String','/fixture/claude','{}','ready','authenticated','then','then','"opaque command string"','[]'),
          ('command-number','codex','Number','/fixture/codex','{}','ready','authenticated','then','then','1e400','1e-400'),
          ('command-sql-null','claude','SQL NULL','/fixture/claude','{}','ready','authenticated','then','then',NULL,NULL),
          ('command-json-null','codex','JSON null','/fixture/codex','{}','ready','authenticated','then','then','null','null');
      UPDATE threads SET model='{"id":"picked","opaque":1e400}',permission='{"mode":"future","unknown":true}',
        pinned=true,archived=true,"readTurnId"='u' WHERE id='t';
      UPDATE turns SET submission='unknown',outcome=NULL WHERE id='u';
      INSERT INTO drafts ("threadId",text,"updatedAt") VALUES ('t','Retained unsent draft','then');
      INSERT INTO environments (id,name,manual,"createdAt","updatedAt")
        VALUES ('retained-environment','Retained environment',true,'then','then');
      INSERT INTO "environmentFolders" (id,"environmentId",path,"createdAt")
        VALUES ('retained-folder','retained-environment','/fixture/retained','then');
      INSERT INTO "hubLink" (id,url,"deviceId","deviceName","tokenRef","orgSlug",username,"joinedAt","ownedAs")
        VALUES (1,'https://example.invalid/source-hub','source-device','Source device','secret:source-context','source-org','source-user','then','source-owner');
      INSERT INTO "columnClocks" ("table","rowId","column",hlc)
        VALUES ('threads','t','title','000000001000-0000-fixture');
      RESET b4app.replaying;
      """)
  }
  private static func expectedRows(
    _ original: [String: [String]], density: AgentProtocolFoundationFixture.DensityFacts,
    path: AgentProtocolFoundationFixture.DensityPath
  ) throws -> [String: [String]] {
    var expected = original
    if let rows = original["viewSettings"] {
      expected["viewSettings"] = try AgentProtocolFoundationFixture.expectedViewRows(
        rows, facts: density, path: path)
    }
    return expected
  }
  private static func snapshot(
    _ raw: PostgresConnection, includeViewSettings: Bool = false,
    source: AgentProtocolFoundationFixture.PreservationPrefix? = nil,
    originalRows: [String: [String]] = [:],
    density: AgentProtocolFoundationFixture.DensityFacts? = nil,
    densityPath: AgentProtocolFoundationFixture.DensityPath? = nil
  ) throws -> [String: [String]] {
    if source != nil, includeViewSettings {
      guard let density, let densityPath else { throw AgentProtocolFoundationFixture.Failure.row }
      try AgentProtocolFoundationFixture.requireDensity(raw, original: density, path: densityPath)
    }
    var result: [String: [String]] = [:]
    for table in publishedTables + (includeViewSettings ? ["viewSettings"] : []) {
      if let source {
        try AgentProtocolFoundationFixture.requireIntroducedSQLNull(
          raw, source: source,
          table: table, originalRows: originalRows[table] ?? [])
      }
      var columns =
        source.map {
          AgentProtocolFoundationFixture.projectionColumns(after: $0, table: table)
        } ?? []
      if table == "viewSettings", let source, source.count < 15 { columns.append("density") }
      let projection = columns.isEmpty ? "to_jsonb(t)" : "to_jsonb(t) - $1::text[]"
      let params: [String?] = columns.isEmpty ? [] : ["{" + columns.joined(separator: ",") + "}"]
      result[table] = try raw.execute(
        "SELECT (\(projection))::text AS row FROM \(Rows.quote(table)) t ORDER BY 1", params
      ).rows.compactMap { $0.text("row") }
      if table == "viewSettings", source != nil {
        result[table] = try (result[table] ?? []).map {
          try AgentProtocolFoundationFixture.canonical(JSONSerialization.jsonObject(with: Data($0.utf8)))
        }.sorted()
      }
    }
    return result
  }

  private static func lines(_ values: [[String: Any]]) throws -> Data {
    try values.reduce(into: Data()) { data, value in
      data += try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data("\n".utf8)
    }
  }
}
