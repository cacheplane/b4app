import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// Protocol14 correction controls. Old protocol13 is frozen DDL, distinct from published viewSettings13.
/// No provider, account, socket or protocol observation is started by these storage tests.
@Suite(.serialized) struct AgentProtocolGenerationSchemaTests {
  private struct Fixture {
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let root: String
    var backups: String { root + "/backups" }
  }

  private static func withFixture(_ body: (Fixture) throws -> Void) throws {
    var endpoint = try AgentProtocolResourceFixture.endpoint()
    endpoint.dataDir = nil
    let root =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "ap-generation-" + UUID().uuidString
    try FileManager.default.createDirectory(
      atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
      try? FileManager.default.removeItem(atPath: root)
      #expect(!FileManager.default.fileExists(atPath: root))
    }
    let raw = try PostgresConnection(
      lib: LibPQ.load(binDir: endpoint.binDir!),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
    try body(Fixture(endpoint: endpoint, raw: raw, root: root))
    #expect(
      try raw.execute(
        "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
        [endpoint.database]
      ).rows.isEmpty)
  }

  private static func seed(_ f: Fixture, count: Int, oldThirteen: Bool = false) throws {
    try Migrator.ensureLedger(f.raw, table: Migrator.table)
    for file in try Migrator.files().prefix(count) {
      try f.raw.execute(
        oldThirteen && file.name == "0014_agent_protocol" ? oldThirteenSQL : file.sql)
      try f.raw.execute(
        "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'fixed-source')",
        [file.name])
    }
  }

  private static func seedOwner(_ f: Fixture) throws {
    try f.raw.execute(
      """
      INSERT INTO public.connections (id,kind,label,target,capabilities,status,"authStatus","createdAt","updatedAt")
        VALUES ('c','codex','Fixture','/fixture/codex','{}','ready','authenticated','then','then');
      INSERT INTO public.threads (id,"connectionId","nativeThreadId","createdAt","updatedAt")
        VALUES ('t','c','raw-native-thread','then','then');
      """)
  }

  private static func snapshot(_ f: Fixture) throws -> [String] {
    var facts = try f.raw.execute(
      """
      SELECT table_name||':'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'') AS fact
      FROM information_schema.columns WHERE table_schema='public'
      """
    ).rows.compactMap { $0.text("fact") }
    facts += try f.raw.execute(
      """
      SELECT r.relname||':'||c.conname||':'||pg_catalog.pg_get_constraintdef(c.oid) AS fact
      FROM pg_catalog.pg_constraint c JOIN pg_catalog.pg_class r ON r.oid=c.conrelid
      WHERE r.relnamespace='public'::regnamespace
      """
    ).rows.compactMap { $0.text("fact") }
    // No authority material is seeded by this suite; compare every row and sequence exactly.
    for table in try f.raw.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'"
    ).rows.compactMap({ $0.text("tablename") }) {
      facts += try f.raw.execute(
        "SELECT $1||':'||to_jsonb(r)::text AS fact FROM public.\(Rows.quote(table)) r", [table]
      ).rows.compactMap { $0.text("fact") }
    }
    for name in try f.raw.execute(
      "SELECT sequencename FROM pg_catalog.pg_sequences WHERE schemaname='public'"
    ).rows.compactMap({ $0.text("sequencename") }) {
      facts += try f.raw.execute(
        "SELECT $1||':'||last_value::text||':'||log_cnt::text||':'||is_called::text AS fact FROM public.\(Rows.quote(name))",
        [name]
      ).rows.compactMap { $0.text("fact") }
    }
    return facts.sorted()
  }

  private static func files(_ f: Fixture) throws -> [String] {
    guard FileManager.default.fileExists(atPath: f.backups) else { return [] }
    return try FileManager.default.subpathsOfDirectory(atPath: f.backups).sorted()
  }

  private static func assertRefusal(_ f: Fixture, oldAlias: Bool = false) throws {
    let before = try snapshot(f), beforeFiles = try files(f)
    let preflight = Result {
      try WorkspaceDatabase.preflightMigration(endpoint: f.endpoint, binDir: f.endpoint.binDir!)
    }
    var openError: (any Error)?
    do {
      let db = try WorkspaceDatabase(
        endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false,
        backupDirectory: f.backups)
      try db.close()
    } catch { openError = error }
    #expect(throws: WorkspaceError.self) { try preflight.get() }
    #expect(try snapshot(f) == before)
    #expect(try files(f) == beforeFiles)
    #expect(!FileManager.default.fileExists(atPath: f.backups))
    let failure = try #require(openError as? WorkspaceError)
    #expect(failure.code == (oldAlias ? .internalError : .incompatibleVersion))
    #expect(
      failure.message
        == (oldAlias
          ? EnvironmentHistoryMigrationGuard.message
          : "The private protocol schema is incompatible with this build."))
    #expect(failure.details == nil)
  }

  @Test func segmentKeysSeparateGenerationLocalEpochAndNamespace() throws {
    try Self.withFixture { f in
      try Self.seed(f, count: 14)
      try Self.seedOwner(f)
      let identities = [
        ("b4", "generation-a", #"["a/b"]"#),
        ("b4", "generation-b", #"["a/b"]"#),
        ("b4", "generation-a", #"["a","b"]"#),
        ("local", "generation-a", #"["a/b"]"#),
      ]
      for (kind, epoch, namespace) in identities {
        try f.raw.execute(
          #"INSERT INTO public."protocolRunSegments" ("connectionId","threadId","identityEpochKind","identityEpochId","namespace","nativeRunId","rootRunId","facts","updatedAt") VALUES ('c','t',$1,$2,$3,'same-native-run','raw-root','{}','then')"#,
          [kind, epoch, namespace])
      }
      let actual = try f.raw.execute(
        #"SELECT "identityEpochKind"||':'||"identityEpochId"||':'||"namespace"::text||':'||"nativeRunId"||':'||"rootRunId" AS fact FROM public."protocolRunSegments" ORDER BY 1"#
      ).rows.compactMap { $0.text("fact") }
      #expect(
        actual == [
          #"b4:generation-a:["a", "b"]:same-native-run:raw-root"#,
          #"b4:generation-a:["a/b"]:same-native-run:raw-root"#,
          #"b4:generation-b:["a/b"]:same-native-run:raw-root"#,
          #"local:generation-a:["a/b"]:same-native-run:raw-root"#,
        ])
      do {
        try f.raw.execute(
          #"INSERT INTO public."protocolRunSegments" ("connectionId","threadId","identityEpochKind","identityEpochId","namespace","nativeRunId","facts","updatedAt") VALUES ('c','t','b4','generation-a','["a/b"]','same-native-run','{}','later')"#
        )
        Issue.record("An exact segment identity was inserted twice.")
      } catch let error as PostgresError { #expect(error.sqlState == "23505") }
      #expect(
        try f.raw.execute(#"SELECT count(*)::text AS n FROM public."protocolRunSegments""#).rows.first?.text(
          "n") == "4")
    }
  }

  @Test func subscriptionsRequireExactlyOneNativeOrLocalEpoch() throws {
    try Self.withFixture { f in
      try Self.seed(f, count: 14)
      try Self.seedOwner(f)
      let insert =
        #"INSERT INTO public."protocolSubscriptions" ("threadId","connectionId","nativeThreadId","generation","localObservationEpoch","channels","namespaces","coverage","updatedAt") VALUES ('t','c','raw-native-thread',$1,$2,'[]','[[]]','{}','then')"#
      for (generation, local) in [("native" as String?, nil as String?), (nil, "local")] {
        try f.raw.execute(insert, [generation, local])
        let row = try #require(
          try f.raw.execute(#"SELECT generation,"localObservationEpoch" FROM public."protocolSubscriptions""#)
            .rows.first)
        #expect(row.text("generation") == generation)
        #expect(row.text("localObservationEpoch") == local)
        try f.raw.execute(#"DELETE FROM public."protocolSubscriptions""#)
      }
      for values in [[nil, nil], ["native", "local"]] as [[String?]] {
        do {
          try f.raw.execute(insert, values); Issue.record("Ambiguous subscription epoch accepted.")
        } catch let error as PostgresError { #expect(error.sqlState == "23514") }
        #expect(try f.raw.execute(#"SELECT 1 FROM public."protocolSubscriptions""#).rows.isEmpty)
      }
    }
  }

  @Test func oldThirteenRefusesBeforeBackupOnEveryPublicAdmission() throws {
    try Self.withFixture { f in
      try Self.seed(f, count: 12)
      try f.raw.execute(Self.oldThirteenSQL)
      try f.raw.execute(
        "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ('0013_agent_protocol','old-draft')"
      )
      try Self.seedOwner(f)
      #expect(
        try Migrator.recorded(f.raw) == Array(AgentProtocolFoundationFixture.migrations.prefix(12)) + [
          "0013_agent_protocol"
        ])
      try Self.assertRefusal(f, oldAlias: true)
    }
  }

  @Test func oldGenerationShapeUnderCanonicalFourteenRefusesWithoutMutation() throws {
    try Self.withFixture { f in
      try Self.seed(f, count: 14, oldThirteen: true)
      try Self.seedOwner(f)
      #expect(try Migrator.recorded(f.raw) == AgentProtocolFoundationFixture.migrations)
      try Self.assertRefusal(f)
    }
  }

  @Test(arguments: [
    "old-primary", "segment-type", "extra-typmod-column", "segment-null", "subscription-missing",
    "subscription-type", "subscription-null",
  ])
  func currentFourteenShapeDamageRefusesWithoutMutation(damage: String) throws {
    try Self.withFixture { f in
      try Self.seed(f, count: 14)
      switch damage {
      case "old-primary":
        try f.raw.execute(
          #"ALTER TABLE public."protocolRunSegments" DROP CONSTRAINT "protocolRunSegments_pkey", ADD PRIMARY KEY ("connectionId","threadId","namespace","nativeRunId")"#
        )
      case "segment-type":
        try f.raw.execute(
          #"ALTER TABLE public."protocolRunSegments" ALTER COLUMN "identityEpochId" TYPE varchar(80)"#)
      case "extra-typmod-column":
        try f.raw.execute(
          #"ALTER TABLE public."protocolRunSegments" ADD COLUMN "unexpectedBounded" varchar(8)"#)
      case "segment-null":
        try f.raw.execute(#"ALTER TABLE public."protocolRunSegments" ALTER COLUMN "rootRunId" SET NOT NULL"#)
      case "subscription-missing":
        try f.raw.execute(#"ALTER TABLE public."protocolSubscriptions" DROP COLUMN "localObservationEpoch""#)
      case "subscription-type":
        try f.raw.execute(
          #"ALTER TABLE public."protocolSubscriptions" ALTER COLUMN "localObservationEpoch" TYPE varchar(80)"#
        )
      default:
        try f.raw.execute(
          #"ALTER TABLE public."protocolSubscriptions" ALTER COLUMN "localObservationEpoch" SET NOT NULL"#)
      }
      try Self.assertRefusal(f)
    }
  }

  @Test(arguments: [0, 12, 13, 14])
  func freshPublishedTwelveThirteenAndCurrentReopensRemainValid(prefix: Int) throws {
    try Self.withFixture { f in
      if prefix > 0 { try Self.seed(f, count: prefix) }
      for _ in 0..<2 {
        let db = try WorkspaceDatabase(
          endpoint: f.endpoint, binDir: f.endpoint.binDir!, createIfMissing: false,
          backupDirectory: f.backups)
        let outcome = Result<Void, any Error> { () throws -> Void in
          #expect(try db.appliedMigrations() == AgentProtocolFoundationFixture.migrations)
          #expect(
            try f.raw.execute(
              #"SELECT "identityEpochKind","identityEpochId" FROM public."protocolRunSegments""#
            ).rows.isEmpty)
          #expect(
            try f.raw.execute(#"SELECT "localObservationEpoch" FROM public."protocolSubscriptions""#).rows
              .isEmpty)
        }
        try db.close()
        try outcome.get()
      }
      #expect(try Self.files(f).count == ((prefix == 12 || prefix == 13) ? 1 : 0))
    }
  }

  private static func archive(
    prefix: Int, marker: Any? = nil, oldProtocolThirteen: Bool = false
  ) throws -> Data {
    let schema = try WorkspaceArchive.schema(Array(AgentProtocolFoundationFixture.migrations.prefix(prefix)))
    let names =
      oldProtocolThirteen
      ? Array(AgentProtocolFoundationFixture.migrations.prefix(12)) + ["0013_agent_protocol"]
      : schema.migrations
    let dataTables =
      oldProtocolThirteen
      ? AgentProtocolFoundationFixture.dataTables.filter { $0 != "viewSettings" } : schema.data
    let context = schema.context
    var header: [String: Any] = [
      "format": "b4app-export", "version": 4, "at": "then", "purpose": "preMigration",
      "migrations": names, "requiredTables": dataTables, "sourceContextTables": context,
    ]
    if let marker { header["protocolSchema"] = marker }
    let rows: [[String: Any]] = names.map {
      ["table": "schemaMigrations", "row": ["name": $0, "appliedAt": "then"]]
    }
    var counts = Dictionary(uniqueKeysWithValues: (dataTables + context).map { ($0, 0) })
    counts["schemaMigrations"] = rows.count
    let footer: [String: Any] = [
      "format": "b4app-export-end", "version": 4, "rows": rows.count, "tableRows": counts,
    ]
    return try ([header] + rows + [footer]).reduce(into: Data()) { data, row in
      data += try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8)
    }
  }

  @Test func emptyOldThirteenArchiveWithoutMarkerRefuses() throws {
    // No protocol rows exist: column-only row validation cannot distinguish this old archive.
    #expect(throws: WorkspaceArchive.Rejection.self) {
      try WorkspaceArchive.read(Self.archive(prefix: 13, oldProtocolThirteen: true))
    }
  }

  @Test func v4ProtocolSchemaMarkerHasExactValue() throws {
    #expect(throws: WorkspaceArchive.Rejection.self) {
      try WorkspaceArchive.read(Self.archive(prefix: 14))
    }
    for wrong in ["", "unknown", 1, NSNull()] as [Any] {
      #expect(throws: WorkspaceArchive.Rejection.self) {
        try WorkspaceArchive.read(Self.archive(prefix: 14, marker: wrong))
      }
    }
    let input = try WorkspaceArchive.read(Self.archive(prefix: 14, marker: "generation_epochs_v1"))
    #expect(input.version == 4)
    #expect(input.dataCount == 0)
  }

  @Test func publishedThroughThirteenArchivesKeepTheirClosedHeader() throws {
    for prefix in [8, 9, 10, 11, 12, 13] {
      #expect(try WorkspaceArchive.read(Self.archive(prefix: prefix)).dataCount == 0)
      #expect(throws: WorkspaceArchive.Rejection.self) {
        try WorkspaceArchive.read(Self.archive(prefix: prefix, marker: "generation_epochs_v1"))
      }
    }
  }

  private static let oldThirteenSQL = #"""
    -- A3 local profile storage only. This unpublished migration is still incomplete until the
    -- separately tested owner-private obligation/grant/archive work is incorporated before release.
    -- Existing connection rows keep their kind/native identity/credentials and gain NULL metadata.
    ALTER TABLE "connections"
      ADD COLUMN "peerProfile" text,
      ADD COLUMN "agentId" text,
      ADD COLUMN "authMode" text,
      ADD COLUMN "authHeaderName" text,
      ADD COLUMN "protocolRetiredAt" text,
      ADD COLUMN "protocolRetiredReason" text;

    -- The inline kind CHECK in canonical 0001_init is named connections_kind_check by PostgreSQL.
    ALTER TABLE "connections" DROP CONSTRAINT "connections_kind_check";
    ALTER TABLE "connections" ADD CONSTRAINT "connections_kind_check"
      CHECK ("kind" IN ('codex', 'claude', 'b4', 'agentProtocol'));

    -- CHECK accepts SQL NULL unless rejected explicitly. Historical kinds remain valid with all
    -- new fields absent; only a fresh agentProtocol profile requires an explicit complete selection.
    ALTER TABLE "connections" ADD CONSTRAINT "connections_protocol_profile_check" CHECK (
      "kind" <> 'agentProtocol' OR (
        "peerProfile" IS NOT NULL AND "peerProfile" IN ('b4', 'agentProtocol') AND
        "agentId" IS NOT NULL AND "agentId" <> '' AND
        "nativeScope" IS NOT NULL AND "nativeScope" <> '' AND
        "authMode" IS NOT NULL AND "authMode" IN ('none', 'bearer', 'header') AND
        (
          ("authMode" = 'header' AND "authHeaderName" IS NOT NULL AND "authHeaderName" <> '') OR
          ("authMode" IN ('none', 'bearer') AND "authHeaderName" IS NULL)
        )
      )
    );

    -- Schema validity does not activate retirement. A4 alone may persist these facts after its
    -- verified v2 boundary; this migration never supplies a timestamp, reason or UPDATE statement.
    ALTER TABLE "connections" ADD CONSTRAINT "connections_protocol_retirement_check" CHECK (
      ("protocolRetiredAt" IS NULL AND "protocolRetiredReason" IS NULL) OR
      (
        "protocolRetiredAt" IS NOT NULL AND "protocolRetiredAt" <> '' AND
        "protocolRetiredReason" IS NOT NULL AND "protocolRetiredReason" = 'agent_protocol_cutover'
      )
    );

    -- A3 owner-private schema allocation. No sync triggers, row rewrites or authority values.
    -- Grant credential APIs, sanitized failure boundaries and self-contained archive4 remain separate
    -- tested stages; this whole migration remains unpublished and unshippable until A3 is complete.
    CREATE FUNCTION b4app_protocol_string_array(candidate jsonb) RETURNS boolean
      LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT jsonb_typeof(candidate) = 'array' AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(candidate) = 'array' THEN candidate ELSE '[]'::jsonb END
        ) AS item(element) WHERE jsonb_typeof(item.element) <> 'string'
      )
    $$;

    CREATE FUNCTION b4app_protocol_namespace_array(candidate jsonb) RETURNS boolean
      LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT jsonb_typeof(candidate) = 'array' AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(candidate) = 'array' THEN candidate ELSE '[]'::jsonb END
        ) AS item(element) WHERE NOT b4app_protocol_string_array(item.element)
      )
    $$;

    -- Match SecretRef(rawValue:) exactly: prefix plus a nonempty opaque tail, not UUID-only.
    CREATE FUNCTION b4app_protocol_secret_reference(candidate text) RETURNS boolean
      LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT left(candidate, 7) = 'secret:' AND char_length(candidate) > 7
    $$;

    CREATE FUNCTION b4app_protocol_secret_references(candidate jsonb) RETURNS boolean
      LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
      SELECT b4app_protocol_string_array(candidate) AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(candidate) = 'array' THEN candidate ELSE '[]'::jsonb END
        ) AS item(element)
        WHERE jsonb_typeof(item.element) <> 'string'
          OR NOT b4app_protocol_secret_reference(item.element #>> '{}')
      )
    $$;

    -- Redundant unique keys permit exact owner-bound foreign keys; existing row IDs do not change.
    ALTER TABLE "threads" ADD CONSTRAINT "threads_protocol_owner_key" UNIQUE ("id", "connectionId");
    ALTER TABLE "turns" ADD CONSTRAINT "turns_protocol_owner_key" UNIQUE ("id", "threadId");

    CREATE TABLE "protocolSubscriptions" (
      "threadId" text PRIMARY KEY CHECK ("threadId" <> ''),
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      "nativeThreadId" text NOT NULL CHECK ("nativeThreadId" <> ''),
      "generation" text CHECK ("generation" IS NULL OR "generation" <> ''),
      "channels" jsonb NOT NULL CHECK (b4app_protocol_string_array("channels")),
      "namespaces" jsonb NOT NULL CHECK (b4app_protocol_namespace_array("namespaces")),
      "appliedEventId" text CHECK ("appliedEventId" IS NULL OR "appliedEventId" <> ''),
      "appliedSeq" bigint CHECK ("appliedSeq" >= 0),
      "coverage" jsonb NOT NULL CHECK (jsonb_typeof("coverage") = 'object'),
      "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
    );

    CREATE TABLE "protocolRunSegments" (
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      "threadId" text NOT NULL CHECK ("threadId" <> ''),
      "namespace" jsonb NOT NULL CHECK (b4app_protocol_string_array("namespace")),
      "nativeRunId" text NOT NULL CHECK ("nativeRunId" <> ''),
      "rootRunId" text CHECK ("rootRunId" IS NULL OR "rootRunId" <> ''),
      "predecessorRunId" text CHECK ("predecessorRunId" IS NULL OR "predecessorRunId" <> ''),
      "localTurnId" text CHECK ("localTurnId" IS NULL OR "localTurnId" <> ''),
      "submissionId" text CHECK ("submissionId" IS NULL OR "submissionId" <> ''),
      "facts" jsonb NOT NULL CHECK (jsonb_typeof("facts") = 'object'),
      "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
      PRIMARY KEY ("connectionId", "threadId", "namespace", "nativeRunId"),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT,
      FOREIGN KEY ("localTurnId", "threadId") REFERENCES "turns" ("id", "threadId") ON DELETE RESTRICT
    );

    CREATE TABLE "protocolOperations" (
      "operationId" text PRIMARY KEY CHECK ("operationId" <> ''),
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      "threadId" text NOT NULL CHECK ("threadId" <> ''),
      "kind" text NOT NULL CHECK ("kind" <> ''),
      "operationThreadId" text NOT NULL CHECK ("operationThreadId" <> ''),
      "targetRunId" text CHECK ("targetRunId" IS NULL OR "targetRunId" <> ''),
      "payload" jsonb NOT NULL,
      "grantReferences" jsonb NOT NULL CHECK (b4app_protocol_secret_references("grantReferences")),
      "expectations" jsonb NOT NULL CHECK (jsonb_typeof("expectations") = 'object'),
      "fingerprint" text NOT NULL CHECK ("fingerprint" <> ''),
      "status" text NOT NULL CHECK ("status" <> ''),
      "acceptedRunId" text CHECK ("acceptedRunId" IS NULL OR "acceptedRunId" <> ''),
      "receipt" jsonb CHECK ("receipt" IS NULL OR jsonb_typeof("receipt") = 'object'),
      "createdAt" text NOT NULL CHECK ("createdAt" <> ''),
      "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
    );

    -- Internal credential-value store schema ONLY. Metadata carries typed SecretRef; values may be
    -- written/read only by the later dedicated same-transaction credential component, never RPC/UI/sync.
    CREATE TABLE "protocolGrantSecrets" (
      "reference" text PRIMARY KEY CHECK (b4app_protocol_secret_reference("reference")),
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      "threadId" text NOT NULL CHECK ("threadId" <> ''),
      "material" text NOT NULL CHECK ("material" <> ''),
      "createdAt" text NOT NULL CHECK ("createdAt" <> ''),
      UNIQUE ("reference", "threadId", "connectionId"),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
    );

    CREATE TABLE "protocolGrants" (
      "threadId" text NOT NULL CHECK ("threadId" <> ''),
      "pausedGeneration" text NOT NULL CHECK ("pausedGeneration" <> ''),
      "namespace" jsonb NOT NULL CHECK (b4app_protocol_string_array("namespace")),
      "interruptId" text NOT NULL CHECK ("interruptId" <> ''),
      "proposalHash" text NOT NULL CHECK ("proposalHash" <> ''),
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      "grantReference" text CHECK ("grantReference" IS NULL OR b4app_protocol_secret_reference("grantReference")),
      "disposition" text NOT NULL CHECK ("disposition" <> ''),
      "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
      PRIMARY KEY ("threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash"),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT,
      FOREIGN KEY ("grantReference", "threadId", "connectionId")
        REFERENCES "protocolGrantSecrets" ("reference", "threadId", "connectionId") ON DELETE RESTRICT
    );

    CREATE TABLE "protocolPromptAnswers" (
      "threadId" text NOT NULL CHECK ("threadId" <> ''),
      "pausedGeneration" text NOT NULL CHECK ("pausedGeneration" <> ''),
      "namespace" jsonb NOT NULL CHECK (b4app_protocol_string_array("namespace")),
      "interruptId" text NOT NULL CHECK ("interruptId" <> ''),
      "proposalHash" text NOT NULL CHECK ("proposalHash" <> ''),
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      -- Opaque JSON values, including JSON null, are valid; only SQL NULL is absent.
      "answer" jsonb NOT NULL,
      "status" text NOT NULL CHECK ("status" <> ''),
      "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
      PRIMARY KEY ("threadId", "pausedGeneration", "namespace", "interruptId", "proposalHash"),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
    );

    CREATE TABLE "protocolHistoryAnchors" (
      "threadId" text NOT NULL CHECK ("threadId" <> ''),
      "generation" text NOT NULL CHECK ("generation" <> ''),
      "anchor" text NOT NULL CHECK ("anchor" <> ''),
      "connectionId" text NOT NULL CHECK ("connectionId" <> ''),
      "coverage" jsonb NOT NULL CHECK (jsonb_typeof("coverage") = 'object'),
      "revision" text NOT NULL CHECK ("revision" <> ''),
      "nextBefore" text,
      "updatedAt" text NOT NULL CHECK ("updatedAt" <> ''),
      PRIMARY KEY ("threadId", "generation", "anchor"),
      FOREIGN KEY ("threadId", "connectionId") REFERENCES "threads" ("id", "connectionId") ON DELETE RESTRICT
    );
    """#
}
