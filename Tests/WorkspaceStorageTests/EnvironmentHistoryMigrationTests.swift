import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

// The Root-owned native run supplies this one private config. Missing/invalid configured inputs
// throw; only an ordinary CI invocation with no config uses the existing shared test fixture.
private struct StoreHistoryOwnedConfig: Decodable {
  var version: Int
  var endpoint: PostgresEndpoint
  var expectedDataDir: String
  var expectedClusterName: String
}

private enum StoreHistoryFixtureError: Error { case unavailable }

private func storeHistoryEndpoint() throws -> PostgresEndpoint {
  guard let path = ProcessInfo.processInfo.environment["B4APP_TEST_STORE_HISTORY_OWNED_CONFIG"] else {
    return try EphemeralPostgres.endpoint()
  }
  guard !path.isEmpty else { throw StoreHistoryFixtureError.unavailable }
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  guard data.count <= 65_536 else { throw StoreHistoryFixtureError.unavailable }
  let config = try JSONDecoder().decode(StoreHistoryOwnedConfig.self, from: data)
  let endpoint = config.endpoint
  guard config.version == 1, endpoint.dataDir == nil,
    (1...65_535).contains(endpoint.port), let binDir = endpoint.binDir,
    (binDir as NSString).isAbsolutePath,
    endpoint.socketDir.hasPrefix("/private/tmp/"),
    config.expectedDataDir.hasPrefix("/private/tmp/"),
    config.expectedClusterName.hasPrefix("store_history_"),
    endpoint.database.hasPrefix("store_history_"), endpoint.database.utf8.count <= 63,
    endpoint.database.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
    [endpoint.socketDir, binDir, config.expectedDataDir, config.expectedClusterName].allSatisfy({
      !$0.isEmpty && !$0.utf8.contains(0) && !$0.contains(where: { $0.isWhitespace })
    })
  else { throw StoreHistoryFixtureError.unavailable }
  let lib = try LibPQ.load(binDir: binDir)
  let admin = try PostgresConnection(
    lib: lib,
    connectionString:
      "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=postgres user=\(NSUserName())")
  let identity = try admin.execute(
    """
    SELECT current_setting('data_directory') AS data_dir,
      current_setting('cluster_name') AS cluster_name, current_setting('port') AS port,
      current_setting('unix_socket_directories') AS sockets,
      current_database() AS database, current_user AS owner
    """
  ).rows.first
  guard identity?.text("data_dir") == config.expectedDataDir,
    identity?.text("cluster_name") == config.expectedClusterName,
    identity?.text("port") == String(endpoint.port),
    identity?.text("sockets") == endpoint.socketDir,
    identity?.text("database") == "postgres", identity?.text("owner") == NSUserName()
  else { throw StoreHistoryFixtureError.unavailable }
  // No IF NOT EXISTS, adoption, process startup/shutdown, or cleanup. Root proves native ownership
  // independently before releasing this config; this check is only fixture endpoint consistency.
  try admin.execute("CREATE DATABASE \(Rows.quote(endpoint.database))")
  return endpoint
}

struct EnvironmentHistoryMigrationTests {
  @Test func environmentsRenameRunnerPreservesOpaqueJSONHistory() throws {
    let endpoint = try storeHistoryEndpoint()
    let binDir = try #require(endpoint.binDir)
    let lib = try LibPQ.load(binDir: binDir)
    let raw = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(endpoint.database) user=\(NSUserName())")
    let files = try Migrator.files()
    _ = try Migrator.applied(raw)
    let prefix = files.filter { $0.name < "0011" }
    for file in prefix {
      try raw.execute(file.sql)
      try raw.execute(
        "INSERT INTO \"schemaMigrations\" (\"name\", \"appliedAt\") VALUES ($1, 'then')",
        [file.name])
    }
    try #require(try Migrator.applied(raw) == prefix.map(\.name))
    // Build valid live rows while controlling the test feed explicitly through the supported
    // replay GUC. Sequences on changes still allocate normally for the ten prepared feed rows.
    try raw.execute("SET b4app.replaying = 'on'")
    try raw.execute(
      """
      INSERT INTO "projects" (id,name,"createdAt","updatedAt") VALUES ('p1','before','now','now');
      INSERT INTO "projectFolders" (id,"projectId",path,"createdAt") VALUES ('f1','p1','/tmp/fixture','now');
      INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","projectId","createdAt","updatedAt")
        VALUES ('c1','codex','Fixture','/fixture','{"projectId":"external","environmentId":"keep"}','ready','authenticated','p1','now','now');
      INSERT INTO threads (id,"connectionId","nativeThreadId","projectId","createdAt","updatedAt")
        VALUES ('t1','c1','native-1','p1','now','now');
      INSERT INTO "columnClocks" ("table","rowId","column",hlc)
        VALUES ('projects','p1','name','clock'),('threads','t1','projectId','clock');
      INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
      SELECT 'fixture-device',s.wall,s.tbl,s.row_id,s.op,s.col,s.val,'fixture-' || s.wall::text
      FROM (VALUES
        (1::bigint,'projects','p1','insert',NULL::text,'{"id":"p1","name":"before"}'::jsonb),
        (2,'projectFolders','f1','insert',NULL,'{"id":"f1","projectId":"p1"}'::jsonb),
        (3,'threads','t1','insert',NULL,'{"id":"t1","projectId":"p1"}'::jsonb),
        (4,'threads','t1','update','projectId','"p1"'::jsonb),
        (5,'connections','c1','insert',NULL,'{"id":"c1","projectId":"p1"}'::jsonb),
        (101,'displayItems','opaque-single','update','payload','{"projectId":"external"}'::jsonb),
        (102,'displayItems','opaque-both','update','payload','{"projectId":"external","environmentId":"keep","nested":{"projectId":"inside"},"n":123456789012345678901234567890.1234567890123456789}'::jsonb),
        (103,'displayItems','opaque-nested','update','payload','{"nested":{"projectId":"inside"}}'::jsonb),
        (104,'displayItems','opaque-array','update','payload','[{"projectId":"external"}]'::jsonb),
        (105,'connections','opaque-capabilities','update','capabilities','{"projectId":"external","environmentId":"keep"}'::jsonb)
      ) s(wall,tbl,row_id,op,col,val);
      CREATE TEMP TABLE store_history_expected AS
        SELECT c.seq,to_jsonb(c) AS whole_row,c.value::text AS value_text
        FROM changes c WHERE "rowId" LIKE 'opaque-%';
      CREATE TEMP TABLE store_history_count AS SELECT count(*) AS n FROM changes;
      DO $$ BEGIN
        IF (SELECT count(*) FROM store_history_expected) <> 5
          OR (SELECT n FROM store_history_count) <> 10 THEN
          RAISE EXCEPTION 'Store history fixture cardinality is invalid';
        END IF;
        IF (SELECT atttypid FROM pg_attribute WHERE attrelid='public.changes'::regclass AND attname='value') <> 'jsonb'::regtype THEN
          RAISE EXCEPTION 'Store history fixture value must be JSONB';
        END IF;
      END $$;
      """
    )
    // Public initialization executes its real per-file Migrator transaction and ledger path.
    // The idle raw connection retains only private TEMP oracle rows, not an open transaction.
    let db = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir, createIfMissing: false)
    let outcome = Result<Void, any Error> {
      try #require(try db.appliedMigrations() == files.map(\.name))
      try raw.execute(
        """
        DO $$ BEGIN
          IF (SELECT count(*) FROM environments WHERE id='p1' AND name='before') <> 1
            OR (SELECT count(*) FROM "environmentFolders" WHERE id='f1' AND "environmentId"='p1') <> 1
            OR (SELECT count(*) FROM threads WHERE id='t1' AND "environmentId"='p1') <> 1
            OR (SELECT count(*) FROM connections WHERE id='c1' AND "environmentId"='p1'
              AND capabilities='{"projectId":"external","environmentId":"keep"}'::jsonb) <> 1 THEN
            RAISE EXCEPTION 'Store structural live-row rename failed';
          END IF;
          IF (SELECT count(*) FROM changes WHERE op='insert' AND "table" IN ('environmentFolders','threads','connections')
              AND value->>'environmentId'='p1') <> 3
            OR NOT EXISTS (SELECT 1 FROM changes WHERE "table"='threads' AND op='update' AND "column"='environmentId' AND value='"p1"'::jsonb)
            OR EXISTS (SELECT 1 FROM changes WHERE "table" IN ('projects','projectFolders') OR "column"='projectId')
            OR NOT EXISTS (SELECT 1 FROM "columnClocks" WHERE "table"='environments' AND "rowId"='p1' AND "column"='name' AND hlc='clock')
            OR NOT EXISTS (SELECT 1 FROM "columnClocks" WHERE "table"='threads' AND "rowId"='t1' AND "column"='environmentId' AND hlc='clock')
            OR EXISTS (SELECT 1 FROM "columnClocks" WHERE "table" IN ('projects','projectFolders') OR "column"='projectId') THEN
            RAISE EXCEPTION 'Store structural change or clock rename failed';
          END IF;
          IF (SELECT count(*) FROM changes) <> (SELECT n FROM store_history_count) THEN
            RAISE EXCEPTION 'Store feed row count changed';
          END IF;
        END $$;
        """
      )
      // Return only a native boolean. Whole JSONB rows and their rendered value::text stay in SQL.
      let preserved = try raw.execute(
        """
        SELECT NOT EXISTS (
          SELECT 1 FROM store_history_expected b LEFT JOIN changes a USING(seq)
          WHERE to_jsonb(a) IS DISTINCT FROM b.whole_row OR a.value::text IS DISTINCT FROM b.value_text
        ) AS preserved
        """
      ).rows.first?.text("preserved")
      #expect(preserved == "t", "The environment rename must preserve opaque Store history.")
    }
    try db.close()
    try outcome.get()
    // raw has no close method: its lexical scope/deinit finishes libpq on return or throw.
  }
}
