import CryptoKit
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

private enum HistoryControlError: Error { case conditionNotObserved, missingWorkerResult }

private final class HistoryControl: Sendable {
  let endpoint: PostgresEndpoint
  let binDir: String
  let backupDirectory: String

  init(endpoint supplied: PostgresEndpoint? = nil, asRole: String? = nil) throws {
    let selected = try supplied ?? EphemeralPostgres.endpoint()
    endpoint = selected
    binDir = try #require(selected.binDir)
    backupDirectory =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "history-guard-" + UUID().uuidString
      + "/backups"
    let raw = try connection()
    try raw.execute("CREATE SCHEMA guard_test")
    if let asRole {
      try raw.execute("GRANT USAGE,CREATE ON SCHEMA guard_test TO \(Rows.quote(asRole))")
      try raw.execute("SET ROLE \(Rows.quote(asRole))")
    }
    _ = try Migrator.applied(raw)
    for file in try Migrator.files() where file.name < "0011" {
      try raw.execute(file.sql)
      try raw.execute(
        "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'then')", [file.name])
    }
    try raw.execute(
      """
      SET b4app.replaying = 'on';
      INSERT INTO projects (id,name,"createdAt","updatedAt") VALUES ('p1','before','now','now');
      INSERT INTO "projectFolders" (id,"projectId",path,"createdAt") VALUES ('f1','p1','/fixture','now');
      INSERT INTO connections (id,kind,label,target,capabilities,status,"authStatus","projectId","createdAt","updatedAt")
        VALUES ('c1','codex','fixture','/fixture','{"projectId":"external","environmentId":"keep"}','ready','authenticated','p1','now','now');
      INSERT INTO threads (id,"connectionId","nativeThreadId","projectId","createdAt","updatedAt")
        VALUES ('t1','c1','native','p1','now','now');
      INSERT INTO "columnClocks" ("table","rowId","column",hlc)
        VALUES ('projects','p1','name','clock'),('threads','t1','projectId','clock');
      INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc)
      SELECT 'fixture',s.wall,s.tbl,s.id,s.op,s.col,s.val,'clock' FROM (VALUES
        (1::bigint,'projectFolders','f1','insert',NULL::text,'{"id":"f1","projectId":"p1"}'::jsonb),
        (2,'threads','t1','insert',NULL,'{"id":"t1","projectId":"p1"}'::jsonb),
        (3,'connections','c1','insert',NULL,'{"id":"c1","projectId":"p1"}'::jsonb),
        (101,'displayItems','opaque-single','update','payload','{"projectId":"external"}'::jsonb),
        (102,'displayItems','opaque-both','update','payload','{"projectId":"external","environmentId":"keep","n":123456789012345678901234567890.1234567890123456789}'::jsonb),
        (103,'displayItems','opaque-nested','update','payload','{"nested":{"projectId":"inside"}}'::jsonb),
        (104,'displayItems','opaque-array','update','payload','[{"projectId":"inside"}]'::jsonb),
        (105,'connections','opaque-capability','update','capabilities','{"projectId":"external","environmentId":"keep"}'::jsonb),
        (106,'threads','opaque-coordinate','update','projectId','{"projectId":null,"environmentId":"keep","n":1e400}'::jsonb),
        (107,'displayItems','opaque-scalar','update','payload','"projectId"'::jsonb),
        (108,'displayItems','opaque-null','update','payload',NULL::jsonb)
      ) s(wall,tbl,id,op,col,val);
      CREATE TABLE guard_test.expected AS
        SELECT c.seq,to_jsonb(c) AS whole_row,c.value::text AS value_text,c.value AS native_value FROM public.changes c
        WHERE c."rowId" LIKE 'opaque-%';
      CREATE TABLE guard_test.flags AS SELECT c.oid,c.relrowsecurity,c.relforcerowsecurity
        FROM pg_catalog.pg_class c WHERE c.oid IN ('public.projects'::regclass,'public."projectFolders"'::regclass,
          'public.threads'::regclass,'public.connections'::regclass,'public.changes'::regclass,'public."columnClocks"'::regclass);
      CREATE SEQUENCE public.guard_test_probe;
      CREATE FUNCTION public.guard_test_history_valid() RETURNS boolean LANGUAGE SQL SET search_path=pg_catalog AS $$
        SELECT NOT EXISTS (SELECT 1 FROM guard_test.expected e LEFT JOIN public.changes c USING(seq)
          WHERE c.seq IS NULL OR c.value::text IS DISTINCT FROM e.value_text
            OR to_jsonb(c) IS DISTINCT FROM (e.whole_row || jsonb_build_object(
              'table',CASE e.whole_row->>'table' WHEN 'projects' THEN 'environments'
                WHEN 'projectFolders' THEN 'environmentFolders' ELSE e.whole_row->>'table' END,
              'column',CASE WHEN e.whole_row->>'column'='projectId' THEN '"environmentId"'::jsonb ELSE e.whole_row->'column' END)))
      $$;
      CREATE FUNCTION public.guard_test_snapshot() RETURNS jsonb LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      DECLARE result jsonb := '{}'::jsonb; item record; value jsonb;
      BEGIN
        FOR item IN SELECT c.relname FROM pg_catalog.pg_class c
          WHERE c.relnamespace='public'::regnamespace AND c.relkind='r'
            AND true ORDER BY c.relname LOOP
          EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),''[]''::jsonb) FROM public.%I r',item.relname) INTO value;
          result := result || jsonb_build_object(item.relname,value);
        END LOOP;
        SELECT jsonb_agg(jsonb_build_array(c.oid,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,
          (SELECT jsonb_agg(jsonb_build_array(a.attname,a.atttypid,a.attnotnull,a.attisdropped) ORDER BY a.attnum)
             FROM pg_catalog.pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0)) ORDER BY c.oid)
          INTO value FROM pg_catalog.pg_class c WHERE c.relnamespace='public'::regnamespace
            AND c.relname <> 'guard_test_probe';
        result := result || jsonb_build_object('catalog',value);
        SELECT jsonb_agg(jsonb_build_array(t.oid,t.tgrelid,t.tgname,t.tgfoid,t.tgenabled) ORDER BY t.oid)
          INTO value FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
          WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal;
        result := result || jsonb_build_object('triggers',value);
        SELECT jsonb_agg(jsonb_build_array(k.oid,k.conname,k.conrelid,k.condeferrable,k.condeferred,k.convalidated,
          pg_get_constraintdef(k.oid)) ORDER BY k.oid) INTO value FROM pg_catalog.pg_constraint k
          JOIN pg_catalog.pg_class c ON c.oid=k.conrelid WHERE c.relnamespace='public'::regnamespace;
        result := result || jsonb_build_object('constraints',value);
        SELECT jsonb_agg(jsonb_build_array(i.indexrelid,pg_get_indexdef(i.indexrelid)) ORDER BY i.indexrelid)
          INTO value FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indrelid
          WHERE c.relnamespace='public'::regnamespace;
        result := result || jsonb_build_object('indexes',value);
        SELECT jsonb_agg(jsonb_build_array(p.oid,p.proname,p.prosrc) ORDER BY p.oid) INTO value
          FROM pg_catalog.pg_proc p WHERE p.pronamespace='public'::regnamespace;
        result := result || jsonb_build_object('functions',value);
        EXECUTE format('SELECT jsonb_build_object(''last_value'',s.last_value,''log_cnt'',s.log_cnt,''is_called'',s.is_called) FROM %s s',pg_get_serial_sequence('public.changes','seq')) INTO value;
        RETURN result || jsonb_build_object('business_sequence',value);
      END $$;
      RESET b4app.replaying;
      """
    )
  }

  deinit {
    try? FileManager.default.removeItem(atPath: (backupDirectory as NSString).deletingLastPathComponent)
  }

  func connection(database: String? = nil) throws -> PostgresConnection {
    let lib = try LibPQ.load(binDir: binDir)
    return try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(database ?? endpoint.database) user=\(NSUserName())"
    )
  }

  func open() throws -> WorkspaceDatabase {
    try WorkspaceDatabase(
      endpoint: endpoint, binDir: binDir, createIfMissing: false, backupDirectory: backupDirectory)
  }

  func snapshot(_ raw: PostgresConnection) throws -> String {
    try #require(
      try raw.execute("SELECT public.guard_test_snapshot()::text AS value").rows.first?.text("value"))
  }

  func applyRaw11(_ raw: PostgresConnection) throws {
    let file = try #require(try Migrator.files().first { $0.name == "0011_environments" })
    try raw.execute(file.sql)
    try raw.execute(
      "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ('0011_environments','old11')")
  }
}

private func historySafeError(_ error: any Error) throws -> WorkspaceError {
  let safe = try #require(error as? WorkspaceError)
  #expect(safe.code == .internalError)
  #expect(safe.message == "Store environment history preservation failed.")
  #expect(safe.details == nil)
  #expect(!String(describing: safe).contains("PRIVATE_HISTORY_CANARY"))
  #expect(!String(reflecting: safe).contains("PRIVATE_HISTORY_CANARY"))
  return safe
}

private func historySafeFailure(_ control: HistoryControl) throws -> WorkspaceError {
  let outcome = Result { try control.open() }
  switch outcome {
  case .success(let db):
    try db.close()
    Issue.record("The pending environment guard must refuse this fixture.")
    throw HistoryControlError.conditionNotObserved
  case .failure(let error):
    return try historySafeError(error)
  }
}

private func historyPreserved(_ raw: PostgresConnection) throws -> Bool {
  try raw.execute(
    """
    SELECT NOT EXISTS (SELECT 1 FROM guard_test.expected e LEFT JOIN public.changes c USING(seq)
      WHERE c.seq IS NULL OR c.value::text IS DISTINCT FROM e.value_text
        OR to_jsonb(c) IS DISTINCT FROM (e.whole_row || jsonb_build_object(
          'table',CASE e.whole_row->>'table' WHEN 'projects' THEN 'environments'
            WHEN 'projectFolders' THEN 'environmentFolders' ELSE e.whole_row->>'table' END,
          'column',CASE WHEN e.whole_row->>'column'='projectId' THEN '"environmentId"'::jsonb ELSE e.whole_row->'column' END))) AS valid
    """
  ).rows.first?.text("valid") == "t"
}

private func historyWait(_ condition: () throws -> Bool) throws {
  // Same positive native-condition polling bound/cadence as the existing RemoteApply interleaving
  // controls. A delay never counts as a witness. Callers release controllers and join on failure.
  let deadline = ContinuousClock.now + .seconds(10)
  repeat {
    if try condition() { return }
    Thread.sleep(forTimeInterval: 0.01)
  } while ContinuousClock.now < deadline
  throw HistoryControlError.conditionNotObserved
}

// A blocking libpq constructor must not compete for the cooperative pool with the observer.
// Retain the exact Thread and its result; callers release every SQL controller before joining.
private final class HistoryOpenWorker {
  private final class State: Sendable {
    let result = Mutex<Result<WorkspaceDatabase, any Error>?>(nil)
    let completed = DispatchSemaphore(value: 0)
  }

  private let state: State
  private let thread: Thread

  init(_ control: HistoryControl) {
    let state = State()
    self.state = state
    thread = Thread {
      let result = Result { try control.open() }
      state.result.withLock { $0 = result }
      state.completed.signal()
    }
    thread.start()
  }

  func join() -> Result<WorkspaceDatabase, any Error> {
    state.completed.wait()
    return state.result.withLock { $0 } ?? .failure(HistoryControlError.missingWorkerResult)
  }
}

private func historyClientsClosed(_ raw: PostgresConnection) throws {
  try historyWait {
    try raw.execute(
      "SELECT count(*)::text AS n FROM pg_catalog.pg_stat_activity WHERE datname=current_database() AND application_name='b4app'"
    ).rows.first?.text("n") == "0"
  }
}

@Suite(.serialized)
struct EnvironmentHistoryGuardTests {
  @Test func rawBytesAndPublicTupleStayCompatible() throws {
    let urls = try #require(
      StorageResources.bundle.urls(forResourcesWithExtension: "sql", subdirectory: "SQL"))
    let raw = try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
      (name: $0.deletingPathExtension().lastPathComponent, bytes: try Data(contentsOf: $0))
    }
    let files = try Migrator.files()
    #expect(raw.count == 13)
    #expect(files.map(\.name) == raw.map(\.name))
    #expect(try files.map(\.sql) == raw.map { try #require(String(data: $0.bytes, encoding: .utf8)) })
    let eleven = try #require(raw.first { $0.name == "0011_environments" })
    let twelve = try #require(raw.first { $0.name == "0012_app_folders" })
    func digest(_ bytes: Data) -> String {
      SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    #expect(digest(eleven.bytes) == "27e0b795663bb2a85922b0b7637cd6764c12bf3ee6e69913398c080528f58386")
    #expect(digest(twelve.bytes) == "0bd9a0cb2e6376676f3ddeaab81a4d9d1cdbffbfea7cb6a2c4395339583067fb")
    #expect(
      try EnvironmentHistoryMigrationGuard.checkedSQL(eleven.bytes)
        == files.first { $0.name == eleven.name }?.sql)
    #expect(throws: WorkspaceError.self) {
      try EnvironmentHistoryMigrationGuard.checkedSQL(eleven.bytes + Data([0x0a]))
    }
    #expect(throws: WorkspaceError.self) {
      try EnvironmentHistoryMigrationGuard.checkedSQL(Data([0xff]))
    }
    #expect(throws: WorkspaceError.self) {
      try StoreMigrationResource(name: eleven.name, bytes: Data([0xff])).sql()
    }
    #expect(files.last?.name == "0013_agent_protocol")
  }

  @Test func opaqueAndStructuralHistoryStayDistinct() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    for table in ["projects", "projectFolders", "threads", "connections", "changes", "columnClocks"] {
      try raw.execute(
        "ALTER TABLE public.\(Rows.quote(table)) ENABLE ROW LEVEL SECURITY; ALTER TABLE public.\(Rows.quote(table)) FORCE ROW LEVEL SECURITY"
      )
    }
    // The bootstrap superuser bypasses filtering even with FORCE. Preserve allowed flags rather
    // than treating ENABLE/FORCE itself as a reason to refuse or silently normalizing either bit.
    try #require(
      try raw.execute(
        """
        SELECT count(*)::text AS n FROM pg_catalog.pg_class c JOIN guard_test.flags f ON f.oid=c.oid
        WHERE c.relrowsecurity AND c.relforcerowsecurity AND NOT pg_catalog.row_security_active(c.oid)
        """
      ).rows.first?.text("n") == "6")
    try raw.execute(
      "UPDATE guard_test.flags f SET relrowsecurity=c.relrowsecurity,relforcerowsecurity=c.relforcerowsecurity FROM pg_catalog.pg_class c WHERE c.oid=f.oid"
    )
    let flagsSQL =
      "SELECT jsonb_agg(jsonb_build_array(c.oid,c.relrowsecurity,c.relforcerowsecurity) ORDER BY c.oid)::text AS value FROM pg_catalog.pg_class c JOIN guard_test.flags f ON f.oid=c.oid"
    let beforeFlags = try #require(try raw.execute(flagsSQL).rows.first?.text("value"))
    let db = try control.open()
    let outcome = Result<Void, any Error> { () throws -> Void in
      #expect(try historyPreserved(raw))
      #expect(try raw.execute(flagsSQL).rows.first?.text("value") == beforeFlags)
      #expect(
        try raw.execute(
          "SELECT count(*)::text AS n FROM changes WHERE op='insert' AND value->>'environmentId'='p1'"
        ).rows.first?.text("n") == "3")
      #expect(try db.appliedMigrations() == Migrator.files().map(\.name))
    }
    try db.close()
    try historyClientsClosed(raw)
    try outcome.get()
  }

  @Test func ambiguousStructuralInsertRefusesAtomically() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute(
      "UPDATE changes SET value=value || '{\"environmentId\":\"different\"}'::jsonb WHERE \"rowId\"='t1' AND op='insert'"
    )
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    try historyClientsClosed(raw)
  }

  @Test func reservedPublicPreimageRefusesAtomically() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("CREATE TABLE public.b4app_environment_history_preimage (n int)")
    let before = try control.snapshot(raw)
    let refused = Result { try Migrator.migrate(raw) }
    #expect(throws: WorkspaceError.self) { try refused.get() }
    if case .failure(let error) = refused { _ = try historySafeError(error) }
    #expect(try control.snapshot(raw) == before)
    // Direct raw guard control: the public constructor refuses this extra table at backup admission.
    try historyClientsClosed(raw)
  }

  @Test func unsupportedPublicTableRefusesAtBackupAdmission() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("CREATE TABLE public.b4app_environment_history_rows (n int)")
    let before = try control.snapshot(raw)
    let outcome = Result { try control.open() }
    if case .success(let db) = outcome { try db.close(); Issue.record("Closed backup inventory must refuse") }
    #expect(throws: WorkspaceError.self) { try outcome.get() }
    if case .failure(let error) = outcome {
      let safe = try #require(error as? WorkspaceError)
      #expect(safe.code == .internalError)
      #expect(
        safe.message
          == "The required pre-migration backup could not be saved. The existing database was not migrated.")
      #expect(safe.details == nil)
    }
    #expect(try control.snapshot(raw) == before)
    #expect(!FileManager.default.fileExists(atPath: control.backupDirectory))
    try historyClientsClosed(raw)
  }

  @Test func shadowLedgerRefusesOnTheSameRawSession() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("CREATE TEMP TABLE \"schemaMigrations\" (name text PRIMARY KEY,\"appliedAt\" text)")
    let before = try control.snapshot(raw)
    let error = Result { try Migrator.migrate(raw) }
    #expect(throws: WorkspaceError.self) { try error.get() }
    if case .failure(let reason) = error { _ = try historySafeError(reason) }
    #expect(try control.snapshot(raw) == before)
    // This session-only condition is intentionally an internal migration control, not public init.
  }

  @Test func wrongNativeValueTypeRefusesAtomically() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("ALTER TABLE public.changes ALTER COLUMN value TYPE json USING value::json")
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    try historyClientsClosed(raw)
  }

  @Test(arguments: [false, true])
  func nativeRestoreAndDeferredCommitFaultsRollback(deferred: Bool) throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    let body = """
      IF to_regclass('public.projects') IS NOT NULL
        OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0011_environments' AND "appliedAt"<>'then')
        OR EXISTS (SELECT 1 FROM guard_test.flags f LEFT JOIN pg_catalog.pg_class c ON c.oid=f.oid
          WHERE c.oid IS NULL OR c.relrowsecurity IS DISTINCT FROM f.relrowsecurity OR c.relforcerowsecurity IS DISTINCT FROM f.relforcerowsecurity)
      THEN RAISE EXCEPTION 'Fault stage control failed'; END IF;
      \(deferred ? "IF NOT (" : "IF NEW.value IS DISTINCT FROM (SELECT native_value FROM guard_test.expected WHERE seq=NEW.seq) OR NOT (")
        EXISTS (SELECT 1 FROM public.changes WHERE "rowId"='opaque-single'))
      THEN RAISE EXCEPTION 'Restored row stage control failed'; END IF;
      \(deferred ? "IF EXISTS (SELECT 1 FROM guard_test.expected e JOIN public.changes c USING(seq) WHERE c.value IS DISTINCT FROM e.native_value OR c.value::text IS DISTINCT FROM e.value_text) THEN RAISE EXCEPTION 'Deferred restoration incomplete'; END IF;" : "")
      PERFORM nextval('public.guard_test_probe');
      RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Native history fault',DETAIL='PRIVATE_HISTORY_CANARY';
      """
    try raw.execute(
      """
      CREATE FUNCTION public.guard_test_fault() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN \(body) RETURN NEW; END $$;
      \(deferred
        ? "CREATE CONSTRAINT TRIGGER guard_test_fault AFTER INSERT ON public.\"schemaMigrations\" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.name='0011_environments') EXECUTE FUNCTION public.guard_test_fault();"
        : "CREATE TRIGGER guard_test_fault BEFORE UPDATE OF value ON public.changes FOR EACH ROW WHEN (OLD.\"rowId\"='opaque-single' AND NOT (OLD.value ? 'projectId') AND NEW.value ? 'projectId') EXECUTE FUNCTION public.guard_test_fault();")
      """
    )
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    #expect(
      try raw.execute("SELECT last_value::text AS n,is_called::text AS fired FROM public.guard_test_probe")
        .rows.first?.text("n") == "1")
    #expect(
      try raw.execute("SELECT is_called::text AS fired FROM public.guard_test_probe").rows.first?.text(
        "fired") == "true")
    try historyClientsClosed(raw)
  }

  @Test(arguments: [false, true])
  func alreadyAppliedHistoryIsNotRepairedAndReopenIsStable(through12: Bool) throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try control.applyRaw11(raw)
    if through12 {
      let file = try #require(try Migrator.files().first { $0.name == "0012_app_folders" })
      try raw.execute(file.sql)
      try raw.execute(
        "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ('0012_app_folders','old12')")
    }
    let values = try raw.execute("SELECT value::text AS value FROM changes WHERE \"rowId\"='opaque-single'")
      .rows.first?.text("value")
    #expect(values?.contains("projectId") == false)  // Genuine already-applied damage is not guessed back.
    let db = try control.open()
    try db.close()
    let after = try control.snapshot(raw)
    let again = try control.open()
    try again.close()
    #expect(try control.snapshot(raw) == after)
    #expect(
      try raw.execute("SELECT value::text AS value FROM changes WHERE \"rowId\"='opaque-single'").rows.first?
        .text("value") == values)
    #expect(
      try raw.execute(
        "SELECT \"appliedAt\" AS stamp FROM \"schemaMigrations\" WHERE name='0011_environments'"
      ).rows.first?.text("stamp") == "old11")
    try historyClientsClosed(raw)
  }

  @Test func futureVersionRefusesAndDoesNotLeaveTheSessionLock() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("INSERT INTO \"schemaMigrations\" (name,\"appliedAt\") VALUES ('9999_future','future')")
    let before = try control.snapshot(raw)
    let outcome = Result { try control.open() }
    if case .success(let db) = outcome { try db.close(); Issue.record("Future ledger must refuse") }
    if case .failure(let error) = outcome {
      #expect((error as? WorkspaceError)?.code == .incompatibleVersion)
    }
    #expect(try control.snapshot(raw) == before)
    try raw.execute("DELETE FROM \"schemaMigrations\" WHERE name='9999_future'")
    let db = try control.open()
    try db.close()
    try historyClientsClosed(raw)
  }

  @Test func laterFileFailureKeepsTheEarlierGuardCommit() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    let priorLedgerSQL =
      "SELECT jsonb_agg(to_jsonb(m) ORDER BY name)::text AS value FROM public.\"schemaMigrations\" m WHERE name<'0011'"
    let priorLedger = try #require(try raw.execute(priorLedgerSQL).rows.first?.text("value"))
    try raw.execute(
      """
      CREATE FUNCTION public.guard_test_later_fault() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        IF to_regclass('public.projects') IS NOT NULL OR to_regclass('public."appFolders"') IS NULL
          OR NOT public.guard_test_history_valid()
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name='0011_environments' AND "appliedAt"<>'then')
          OR NOT EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name=NEW.name AND "appliedAt"=NEW."appliedAt")
          OR EXISTS (SELECT 1 FROM public."schemaMigrations" WHERE name<'0011' AND "appliedAt"<>'then')
          OR EXISTS (SELECT 1 FROM guard_test.flags f LEFT JOIN pg_catalog.pg_class c ON c.oid=f.oid
            WHERE c.oid IS NULL OR c.relrowsecurity IS DISTINCT FROM f.relrowsecurity OR c.relforcerowsecurity IS DISTINCT FROM f.relforcerowsecurity)
        THEN RAISE EXCEPTION 'Later COMMIT stage control failed'; END IF;
        PERFORM nextval('public.guard_test_probe');
        RAISE EXCEPTION 'Later migration test fault';
      END $$;
      CREATE CONSTRAINT TRIGGER guard_test_later_fault AFTER INSERT ON public."schemaMigrations"
        DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.name='0012_app_folders')
        EXECUTE FUNCTION public.guard_test_later_fault();
      """
    )
    let outcome = Result { try control.open() }
    if case .success(let db) = outcome { try db.close(); Issue.record("The later file must fail") }
    #expect(throws: WorkspaceError.self) { try outcome.get() }
    #expect(
      try raw.execute("SELECT last_value::text AS n FROM public.guard_test_probe WHERE is_called").rows.first?
        .text("n") == "1")
    #expect(try historyPreserved(raw))
    #expect(try raw.execute(priorLedgerSQL).rows.first?.text("value") == priorLedger)
    #expect(
      try raw.execute(
        "SELECT count(*)::text AS n FROM public.\"schemaMigrations\" WHERE name='0012_app_folders'"
      ).rows.first?.text("n") == "0")
    #expect(
      try raw.execute("SELECT to_regclass('public.\"appFolders\"')::text AS name").rows.first?.text("name")
        == nil)
    let committedElevenSQL = """
      SELECT jsonb_build_object(
        'ledger11',(SELECT to_jsonb(m) FROM public."schemaMigrations" m WHERE name='0011_environments'),
        'feed',(SELECT jsonb_agg(to_jsonb(c) ORDER BY seq) FROM public.changes c),
        'clocks',(SELECT jsonb_agg(to_jsonb(c) ORDER BY to_jsonb(c)::text) FROM public."columnClocks" c),
        'sequence',(SELECT jsonb_build_object('last_value',s.last_value,'log_cnt',s.log_cnt,'is_called',s.is_called) FROM public.changes_seq_seq s))::text AS value
      """
    let committedEleven = try #require(try raw.execute(committedElevenSQL).rows.first?.text("value"))
    let elevenStamp = try #require(
      try raw.execute(
        "SELECT \"appliedAt\" AS stamp FROM public.\"schemaMigrations\" WHERE name='0011_environments'"
      ).rows.first?.text("stamp"))
    #expect(elevenStamp != "then")
    try raw.execute("DROP TRIGGER guard_test_later_fault ON public.\"schemaMigrations\"")
    let db = try control.open()
    try db.close()
    #expect(try historyPreserved(raw))
    #expect(try raw.execute(priorLedgerSQL).rows.first?.text("value") == priorLedger)
    #expect(try raw.execute(committedElevenSQL).rows.first?.text("value") == committedEleven)
    #expect(
      try raw.execute(
        "SELECT count(*)::text AS n FROM public.\"schemaMigrations\" WHERE name='0012_app_folders' AND \"appliedAt\" NOT IN ('then','old12')"
      ).rows.first?.text("n") == "1")
    #expect(
      try raw.execute("SELECT to_regclass('public.\"appFolders\"')::text AS name").rows.first?.text("name")
        == "\"appFolders\"")
    #expect(
      try raw.execute("SELECT last_value::text AS n FROM public.guard_test_probe WHERE is_called").rows.first?
        .text("n") == "1")
    try historyClientsClosed(raw)
  }

}

extension EnvironmentHistoryGuardTests {
  @Test(arguments: [false, true])
  func malformedLedgerNullabilityOrPrimaryKeyRefuses(nullable: Bool) throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    if nullable {
      try raw.execute("ALTER TABLE public.\"schemaMigrations\" ALTER COLUMN \"appliedAt\" DROP NOT NULL")
      try raw.execute("UPDATE public.\"schemaMigrations\" SET \"appliedAt\"=NULL WHERE name='0001_init'")
    } else {
      try raw.execute(
        """
        DO $$ DECLARE key_name text; BEGIN
          SELECT conname INTO key_name FROM pg_catalog.pg_constraint
            WHERE conrelid='public."schemaMigrations"'::regclass AND contype='p';
          EXECUTE format('ALTER TABLE public."schemaMigrations" DROP CONSTRAINT %I',key_name);
        END $$;
        """
      )
    }
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    try historyClientsClosed(raw)
  }

  @Test func suppressedStructuralRenameRefusesAndRollsBack() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute(
      """
      CREATE FUNCTION public.guard_test_suppress() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        IF to_regclass('public."environmentFolders"') IS NULL THEN RAISE EXCEPTION 'Not the frozen value phase'; END IF;
        PERFORM nextval('public.guard_test_probe'); RETURN NULL;
      END $$;
      CREATE TRIGGER guard_test_suppress BEFORE UPDATE OF value ON public.changes FOR EACH ROW
        WHEN (OLD."rowId"='f1' AND OLD.op='insert' AND OLD.value ? 'projectId' AND NOT (NEW.value ? 'projectId'))
        EXECUTE FUNCTION public.guard_test_suppress();
      """
    )
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    #expect(
      try raw.execute("SELECT last_value::text AS n FROM public.guard_test_probe WHERE is_called").rows.first?
        .text("n") == "1")
    try historyClientsClosed(raw)
  }

  @Test func sameCountUncapturedValueMutationRefusesAndRollsBack() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute(
      """
      CREATE FUNCTION public.guard_test_mutate_other() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        UPDATE public.changes SET value='"silently changed"'::jsonb WHERE "rowId"='opaque-scalar';
        PERFORM nextval('public.guard_test_probe'); RETURN NEW;
      END $$;
      CREATE TRIGGER guard_test_mutate_other AFTER UPDATE OF value ON public.changes FOR EACH ROW
        WHEN (OLD."rowId"='opaque-single' AND OLD.value ? 'projectId' AND NOT (NEW.value ? 'projectId'))
        EXECUTE FUNCTION public.guard_test_mutate_other();
      """
    )
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    #expect(
      try raw.execute("SELECT last_value::text AS n FROM public.guard_test_probe WHERE is_called").rows.first?
        .text("n") == "1")
    try historyClientsClosed(raw)
  }

  @Test func suppressedLedgerInsertRefusesAndRollsBack() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute(
      """
      CREATE FUNCTION public.guard_test_suppress_ledger() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
      BEGIN
        IF to_regclass('public.projects') IS NOT NULL THEN RAISE EXCEPTION 'Not the post-SQL ledger phase'; END IF;
        PERFORM nextval('public.guard_test_probe'); RETURN NULL;
      END $$;
      CREATE TRIGGER guard_test_suppress_ledger BEFORE INSERT ON public."schemaMigrations" FOR EACH ROW
        WHEN (NEW.name='0011_environments') EXECUTE FUNCTION public.guard_test_suppress_ledger();
      """
    )
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    #expect(
      try raw.execute("SELECT last_value::text AS n FROM public.guard_test_probe WHERE is_called").rows.first?
        .text("n") == "1")
    try historyClientsClosed(raw)
  }

  @Test(arguments: ["read committed", "repeatable read"])
  func writerBeforeFirstLockIsIncluded(isolation: String) throws {
    let control = try HistoryControl()
    let observer = try control.connection()
    let worker: HistoryOpenWorker
    let observed: Result<Void, any Error>
    do {
      let writer = try control.connection()
      defer { try? writer.execute("ROLLBACK") }
      // Database+role-in-database defaults are scoped to this fresh fixture, not the shared role.
      try observer.execute(
        "ALTER DATABASE \(Rows.quote(control.endpoint.database)) SET default_transaction_isolation='\(isolation)'"
      )
      try observer.execute(
        "ALTER ROLE \(Rows.quote(NSUserName())) IN DATABASE \(Rows.quote(control.endpoint.database)) SET default_transaction_isolation='\(isolation)'"
      )
      let settings = try observer.execute(
        """
        SELECT count(*)::text AS n FROM pg_catalog.pg_db_role_setting s
        WHERE s.setdatabase=(SELECT oid FROM pg_catalog.pg_database WHERE datname=current_database())
          AND (s.setrole=0 OR s.setrole=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user))
          AND $1=ANY(s.setconfig)
        """, ["default_transaction_isolation=\(isolation)"]
      ).rows.first?.text("n")
      try #require(settings == "2")
      let writerPID = try #require(
        try writer.execute("SELECT pg_backend_pid()::text AS pid").rows.first?.text("pid"))
      try writer.execute(
        """
        BEGIN; SET LOCAL b4app.replaying='on';
        UPDATE projects SET name='committed-ahead' WHERE id='p1';
        UPDATE changes SET value='{"projectId":"new external","environmentId":"new keep","n":999999999999999999999.123456789}'::jsonb WHERE "rowId"='opaque-both';
        INSERT INTO changes ("deviceId",wall,"table","rowId",op,"column",value,hlc) VALUES
          ('writer',201,'threads','writer-structural','insert',NULL,'{"id":"writer-structural","projectId":"p1"}','writer'),
          ('writer',202,'displayItems','opaque-new','update','payload','{"projectId":"new opaque","environmentId":"keep"}','writer');
        INSERT INTO "columnClocks" ("table","rowId","column",hlc) VALUES ('threads','writer-structural','projectId','writer');
        UPDATE guard_test.expected e SET whole_row=to_jsonb(c),value_text=c.value::text,native_value=c.value
          FROM changes c WHERE c.seq=e.seq AND c."rowId"='opaque-both';
        INSERT INTO guard_test.expected SELECT c.seq,to_jsonb(c),c.value::text,c.value FROM changes c WHERE c."rowId"='opaque-new';
        """
      )
      worker = HistoryOpenWorker(control)
      observed = Result<Void, any Error> {
        try historyWait {
          try observer.execute(
            """
            SELECT count(*)::text AS n FROM pg_catalog.pg_locks l JOIN pg_catalog.pg_stat_activity a ON a.pid=l.pid
            WHERE a.datname=current_database() AND a.application_name='b4app' AND l.locktype='relation'
              AND l.relation='public.projects'::regclass AND l.mode='AccessExclusiveLock' AND NOT l.granted
              AND $1::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
            """, [writerPID]
          ).rows.first?.text("n") == "1"
        }
        try writer.execute("COMMIT")
      }
    }
    // The release attempt and lexical PQfinish precede joining the original constructor, even if
    // ROLLBACK failed. No raw writer remains alive through the join.
    let result = worker.join()
    if case .success(let db) = result { try db.close() }
    try historyClientsClosed(observer)
    try observer.execute(
      "ALTER ROLE \(Rows.quote(NSUserName())) IN DATABASE \(Rows.quote(control.endpoint.database)) RESET default_transaction_isolation"
    )
    try observed.get()
    _ = try result.get()
    #expect(try historyPreserved(observer))
    #expect(
      try observer.execute("SELECT name FROM environments WHERE id='p1'").rows.first?.text("name")
        == "committed-ahead")
    #expect(
      try observer.execute(
        "SELECT count(*)::text AS n FROM changes WHERE \"rowId\"='writer-structural' AND value->>'environmentId'='p1' AND NOT (value ? 'projectId')"
      ).rows.first?.text("n") == "1")
    #expect(
      try observer.execute(
        "SELECT count(*)::text AS n FROM \"columnClocks\" WHERE \"rowId\"='writer-structural' AND \"column\"='environmentId'"
      ).rows.first?.text("n") == "1")
  }

  @Test(arguments: ["0011_environments", "0012_app_folders"])
  func concurrentConstructorsHoldSessionLockThroughCommit(migration: String) throws {
    let control = try HistoryControl()
    let observer = try control.connection()
    if migration == "0012_app_folders" { try control.applyRaw11(observer) }
    let initialFeed = try observer.execute(
      "SELECT jsonb_agg(to_jsonb(c) ORDER BY seq)::text AS value FROM changes c"
    ).rows.first?.text("value")
    let first: HistoryOpenWorker
    var second: HistoryOpenWorker?
    let witnessed: Result<Void, any Error>
    do {
      let controller = try control.connection()
      let gate: Int64 = 0x6234_7465_7374_6761
      defer { try? controller.execute("SELECT pg_advisory_unlock($1::bigint)", [String(gate)]) }
      try controller.execute("SELECT pg_advisory_lock($1::bigint)", [String(gate)])
      let gatePID = try #require(
        try controller.execute("SELECT pg_backend_pid()::text AS pid").rows.first?.text("pid"))
      try controller.execute(
        """
        CREATE FUNCTION public.guard_test_commit_gate() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
        BEGIN
          IF EXISTS (SELECT 1 FROM guard_test.flags f LEFT JOIN pg_catalog.pg_class c ON c.oid=f.oid
            WHERE c.oid IS NULL OR c.relrowsecurity IS DISTINCT FROM f.relrowsecurity OR c.relforcerowsecurity IS DISTINCT FROM f.relforcerowsecurity)
          THEN RAISE EXCEPTION 'Commit flags changed'; END IF;
          IF to_regclass('public.projects') IS NOT NULL OR NOT EXISTS (
              SELECT 1 FROM public."schemaMigrations" WHERE name=NEW.name AND "appliedAt"=NEW."appliedAt")
          THEN RAISE EXCEPTION 'Commit gate state is invalid'; END IF;
          \(migration == "0011_environments" ? "IF NOT public.guard_test_history_valid() THEN RAISE EXCEPTION 'Opaque restore incomplete at COMMIT'; END IF;" : "IF to_regclass('public.\"appFolders\"') IS NULL THEN RAISE EXCEPTION 'App folders missing at COMMIT'; END IF;")
          PERFORM nextval('public.guard_test_probe');
          PERFORM pg_catalog.pg_advisory_xact_lock(\(gate));
          RETURN NEW;
        END $$;
        CREATE CONSTRAINT TRIGGER guard_test_commit_gate AFTER INSERT ON public."schemaMigrations"
          DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.name='\(migration)')
          EXECUTE FUNCTION public.guard_test_commit_gate();
        """
      )
      first = HistoryOpenWorker(control)
      witnessed = Result<Void, any Error> {
        try historyWait {
          try observer.execute(
            """
            SELECT count(*)::text AS n FROM pg_catalog.pg_locks l JOIN pg_catalog.pg_stat_activity a ON a.pid=l.pid
            WHERE a.datname=current_database() AND a.application_name='b4app' AND l.locktype='advisory'
              AND l.classid=$1::oid AND l.objid=$2::oid AND l.objsubid=1 AND NOT l.granted
              AND $3::int=ANY(pg_catalog.pg_blocking_pids(a.pid))
            """, [String(UInt64(gate) >> 32), String(UInt64(gate) & 0xffff_ffff), gatePID]
          ).rows.first?.text("n") == "1"
        }
        second = HistoryOpenWorker(control)
        let key = UInt64(Migrator.migrationLockKey)
        try historyWait {
          try observer.execute(
            """
            SELECT count(*)::text AS n FROM pg_catalog.pg_locks waiting
            JOIN pg_catalog.pg_stat_activity b ON b.pid=waiting.pid
            JOIN pg_catalog.pg_locks holding ON holding.locktype='advisory' AND holding.granted
              AND holding.classid=waiting.classid AND holding.objid=waiting.objid AND holding.objsubid=waiting.objsubid
            JOIN pg_catalog.pg_stat_activity a ON a.pid=holding.pid
            WHERE b.datname=current_database() AND b.application_name='b4app'
              AND a.datname=current_database() AND a.application_name='b4app' AND a.pid<>b.pid
              AND waiting.locktype='advisory' AND NOT waiting.granted AND waiting.objsubid=1
              AND waiting.classid=$1::oid AND waiting.objid=$2::oid
              AND a.pid=ANY(pg_catalog.pg_blocking_pids(b.pid))
            """, [String(key >> 32), String(key & 0xffff_ffff)]
          ).rows.first?.text("n") == "1"
        }
      }
    }
    // The gate release attempt and controller PQfinish precede both original worker joins.
    let firstResult = first.join()
    let secondResult = second?.join()
    let firstClosed = Result { if case .success(let db) = firstResult { try db.close() } }
    let secondClosed = Result { if let secondResult, case .success(let db) = secondResult { try db.close() } }
    try historyClientsClosed(observer)
    try witnessed.get()
    _ = try firstResult.get()
    _ = try #require(secondResult).get()
    try firstClosed.get()
    try secondClosed.get()
    #expect(
      try observer.execute(
        "SELECT count(*)::text AS n FROM \"schemaMigrations\" WHERE name IN ('0011_environments','0012_app_folders')"
      ).rows.first?.text("n") == "2")
    #expect(
      try observer.execute(
        "SELECT count(*)::text AS n FROM \"schemaMigrations\" WHERE name<'0011' AND \"appliedAt\"<>'then'"
      ).rows.first?.text("n") == "0")
    #expect(
      try observer.execute("SELECT last_value::text AS n FROM guard_test_probe WHERE is_called").rows.first?
        .text("n") == "1")
    if migration == "0011_environments" {
      #expect(try historyPreserved(observer))
    } else {
      #expect(
        try observer.execute("SELECT jsonb_agg(to_jsonb(c) ORDER BY seq)::text AS value FROM changes c").rows
          .first?.text("value") == initialFeed)
      #expect(
        try observer.execute(
          "SELECT \"appliedAt\" AS stamp FROM \"schemaMigrations\" WHERE name='0011_environments'"
        ).rows.first?.text("stamp") == "old11")
    }
  }
}

extension EnvironmentHistoryGuardTests {
  @Test func unexpectedCreationSchemaRefusesWithoutCreatingAnotherLedger() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("CREATE SCHEMA guard_test_other")
    try raw.execute(
      "ALTER ROLE \(Rows.quote(NSUserName())) IN DATABASE \(Rows.quote(control.endpoint.database)) SET search_path=guard_test_other,public"
    )
    defer {
      try? raw.execute(
        "ALTER ROLE \(Rows.quote(NSUserName())) IN DATABASE \(Rows.quote(control.endpoint.database)) RESET search_path"
      )
    }
    let before = try control.snapshot(raw)
    _ = try historySafeFailure(control)
    #expect(try control.snapshot(raw) == before)
    #expect(
      try raw.execute(
        "SELECT count(*)::text AS n FROM pg_catalog.pg_class WHERE relnamespace='guard_test_other'::regnamespace"
      ).rows.first?.text("n") == "0")
    try historyClientsClosed(raw)
  }

  @Test func preexistingTemporaryWitnessRefusesOnTheSameSession() throws {
    let control = try HistoryControl()
    let raw = try control.connection()
    try raw.execute("CREATE TEMP TABLE b4app_environment_history_state (n int)")
    let before = try control.snapshot(raw)
    let outcome = Result { try Migrator.migrate(raw) }
    #expect(throws: WorkspaceError.self) { try outcome.get() }
    if case .failure(let error) = outcome { _ = try historySafeError(error) }
    #expect(try control.snapshot(raw) == before)
    #expect(
      try raw.execute("SELECT count(*)::text AS n FROM pg_temp.b4app_environment_history_state").rows.first?
        .text("n") == "0")
    // Direct internal path: another connection cannot install TEMP state on a future public pool.
  }

  @Test func activeRowFilteringRefusesForANonSuperuserOwner() throws {
    let endpoint = try EphemeralPostgres.endpoint()
    let binDir = try #require(endpoint.binDir)
    let role = "guard_role_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    var roleCreated = false
    let outcome = Result<Void, any Error> {
      do {
        let lib = try LibPQ.load(binDir: binDir)
        let admin = try PostgresConnection(
          lib: lib,
          connectionString:
            "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(endpoint.database) user=\(NSUserName())"
        )
        try admin.execute("CREATE ROLE \(Rows.quote(role)) NOLOGIN")
        roleCreated = true
        try admin.execute("GRANT CREATE ON SCHEMA public TO \(Rows.quote(role))")
      }
      let control = try HistoryControl(endpoint: endpoint, asRole: role)
      let owner = try control.connection()
      let observer = try control.connection()
      try owner.execute("SET ROLE \(Rows.quote(role))")
      try owner.execute(
        "ALTER TABLE public.changes ENABLE ROW LEVEL SECURITY; ALTER TABLE public.changes FORCE ROW LEVEL SECURITY"
      )
      try #require(
        try owner.execute("SELECT pg_catalog.row_security_active('public.changes'::regclass)::text AS active")
          .rows.first?.text("active") == "true")
      let before = try control.snapshot(observer)
      let failed = Result { try Migrator.migrate(owner) }
      #expect(throws: WorkspaceError.self) { try failed.get() }
      if case .failure(let error) = failed { _ = try historySafeError(error) }
      #expect(try control.snapshot(observer) == before)
      // Explicit fixture-only positive control, AFTER the refusal snapshot: the same non-superuser
      // owner can migrate when filtering is removed. Production never changes either RLS flag.
      try owner.execute(
        "ALTER TABLE public.changes NO FORCE ROW LEVEL SECURITY; ALTER TABLE public.changes DISABLE ROW LEVEL SECURITY"
      )
      #expect(
        try Migrator.migrate(owner) == ["0011_environments", "0012_app_folders", "0013_agent_protocol"])
      #expect(try historyPreserved(owner))
    }
    // All raw connections above are out of lexical scope before normal exact-owned DB/role cleanup.
    let cleanup = Result<Void, any Error> {
      let lib = try LibPQ.load(binDir: binDir)
      let admin = try PostgresConnection(
        lib: lib,
        connectionString:
          "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=postgres user=\(NSUserName())")
      try historyWait {
        try admin.execute(
          "SELECT count(*)::text AS n FROM pg_catalog.pg_stat_activity WHERE datname=$1", [endpoint.database]
        ).rows.first?.text("n") == "0"
      }
      try admin.execute("DROP DATABASE \(Rows.quote(endpoint.database))")
      if roleCreated { try admin.execute("DROP ROLE \(Rows.quote(role))") }
    }
    if case .failure = cleanup { Issue.record("Owned history role/database cleanup did not complete.") }
    try outcome.get()
    try cleanup.get()
  }
}
