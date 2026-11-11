import CryptoKit
import Foundation
import WorkspaceProtocol

/// The narrowly scoped protection for the published environment rename. All witnesses remain native
/// PostgreSQL values; in particular no JSON number is decoded through Foundation or Double.
enum EnvironmentHistoryMigrationGuard {
  static let name = "0011_environments"
  static let sha256 = "27e0b795663bb2a85922b0b7637cd6764c12bf3ee6e69913398c080528f58386"
  static let message = "Store environment history preservation failed."

  static func failure() -> WorkspaceError { WorkspaceError(.internalError, message) }

  static func checkedSQL(_ bytes: Data) throws -> String {
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard digest == sha256, let sql = String(data: bytes, encoding: .utf8) else { throw failure() }
    return sql
  }

  private static func requireTrue(
    _ connection: PostgresConnection, _ sql: String, _ params: [String?] = []
  ) throws {
    let rows = try connection.execute(sql, params).rows
    guard rows.count == 1, rows[0].text("valid") == "t" else { throw failure() }
  }

  static func apply(_ connection: PostgresConnection, file: StoreMigrationResource) throws {
    var transactionAttempted = false
    do {
      guard file.name == name else { throw failure() }
      let sql = try checkedSQL(file.bytes)
      transactionAttempted = true
      try connection.execute("BEGIN")
      // LOCK, not a snapshot-taking query, must be the first statement in this transaction. Keep
      // this order identical to the frozen DDL so a writer ahead of us is visible even under RR.
      for table in ["projects", "projectFolders", "threads", "connections", "changes", "columnClocks"] {
        try connection.execute("LOCK TABLE public.\(Rows.quote(table)) IN ACCESS EXCLUSIVE MODE")
      }
      try admitObjects(connection)
      // pg_catalog is implicitly searched first. Putting it explicitly first would instead make
      // the frozen unqualified CREATE OR REPLACE FUNCTION target that creation namespace.
      try connection.execute("SET LOCAL search_path = public")
      try capture(connection)
      let tempOIDs = try connection.execute(
        """
        SELECT 'pg_temp.b4app_environment_history_preimage'::regclass::oid::text AS preimage,
          'pg_temp.b4app_environment_history_state'::regclass::oid::text AS state
        """
      ).rows.first
      guard let preimageOID = tempOIDs?.text("preimage"), let stateOID = tempOIDs?.text("state") else {
        throw failure()
      }
      try connection.execute(sql)
      let appliedAt = Timestamp.now()
      let inserted = try connection.execute(
        "INSERT INTO public.\(Rows.quote(Migrator.table)) (\"name\", \"appliedAt\") VALUES ($1, $2)",
        [file.name, appliedAt]
      ).affected
      guard inserted == 1 else { throw failure() }
      let captured = try connection.execute(
        "SELECT count(*)::text AS n FROM pg_temp.b4app_environment_history_preimage WHERE restore_value"
      ).rows.first?.text("n")
      let restored = try connection.execute(
        """
        UPDATE public.changes AS c SET value = p.value
        FROM pg_temp.b4app_environment_history_preimage AS p WHERE c.seq = p.seq AND p.restore_value
        """
      ).affected
      guard captured == String(restored) else { throw failure() }
      let identity = try connection.execute(
        """
        SELECT pg_catalog.to_regclass('pg_temp.b4app_environment_history_preimage')::oid::text = $1
          AND pg_catalog.to_regclass('pg_temp.b4app_environment_history_state')::oid::text = $2 AS valid
        """, [preimageOID, stateOID]
      ).rows.first?.text("valid")
      guard identity == "t" else { throw failure() }
      try verify(connection, appliedAt: appliedAt)
      try connection.execute("COMMIT")
    } catch {
      // BEGIN and COMMIT are both inside this boundary. A lost COMMIT response has an unknown
      // server outcome: fail the initializer, never retry or claim that rollback was proved.
      if transactionAttempted { try? connection.execute("ROLLBACK") }
      throw failure()
    }
  }

  private static func admitObjects(_ connection: PostgresConnection) throws {
    try requireTrue(
      connection,
      """
      WITH expected(name, kind) AS (VALUES
        ('projects','r'),('projectFolders','r'),('threads','r'),('connections','r'),
        ('changes','r'),('columnClocks','r'),('schemaMigrations','r'),
        ('projectFoldersByProject','i'),('threadsByProject','i'),('connectionsByProject','i'))
      SELECT coalesce(bool_and(CASE WHEN c.oid IS NULL THEN false ELSE
        c.relkind::text = e.kind AND c.relpersistence = 'p'
        AND c.relnamespace = 'public'::regnamespace
        AND pg_catalog.to_regclass(pg_catalog.quote_ident(e.name)) = c.oid
        AND CASE WHEN e.kind = 'r' THEN NOT pg_catalog.row_security_active(c.oid) ELSE true END
      END), false) AS valid
      FROM expected e LEFT JOIN pg_catalog.pg_class c
        ON c.oid = pg_catalog.to_regclass('public.' || pg_catalog.quote_ident(e.name))
      """
    )
    try requireTrue(
      connection,
      """
      WITH expected(tbl, col, typ) AS (VALUES
        ('changes','seq',20),('changes','deviceId',25),('changes','wall',20),
        ('changes','table',25),('changes','rowId',25),('changes','op',25),
        ('changes','column',25),('changes','value',3802),('changes','synced',16),('changes','hlc',25),
        ('columnClocks','table',25),('columnClocks','rowId',25),
        ('columnClocks','column',25),('columnClocks','hlc',25),
        ('schemaMigrations','name',25),('schemaMigrations','appliedAt',25))
      SELECT coalesce(bool_and(coalesce(a.atttypid = e.typ::oid AND NOT a.attisdropped, false)), false) AS valid
      FROM expected e LEFT JOIN pg_catalog.pg_attribute a
        ON a.attrelid = pg_catalog.to_regclass('public.' || pg_catalog.quote_ident(e.tbl))
        AND a.attname = e.col AND a.attnum > 0
      """
    )
    try requireTrue(
      connection,
      """
      SELECT pg_catalog.to_regprocedure('b4app_record_change()') =
          pg_catalog.to_regprocedure('public.b4app_record_change()')
        AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
          WHERE p.oid = pg_catalog.to_regprocedure('public.b4app_record_change()')
            AND p.pronamespace = 'public'::regnamespace AND p.prorettype = 'trigger'::regtype)
        AND (SELECT count(*) FROM pg_catalog.pg_trigger t WHERE NOT t.tgisinternal
          AND ((t.tgrelid = 'public.projects'::regclass AND t.tgname = 'projectsChanges')
            OR (t.tgrelid = 'public."projectFolders"'::regclass AND t.tgname = 'projectFoldersChanges'))
          AND t.tgfoid = pg_catalog.to_regprocedure('public.b4app_record_change()')) = 2
        AND pg_catalog.pg_get_serial_sequence('public.changes','seq')::regclass = 'public.changes_seq_seq'::regclass
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
          WHERE c.relname IN ('b4app_environment_history_preimage','b4app_environment_history_state')
            AND c.relnamespace IN ('public'::regnamespace, pg_catalog.pg_my_temp_schema())) AS valid
      """
    )
    try requireTrue(
      connection,
      """
      SELECT NOT EXISTS (SELECT 1 FROM public.changes
        WHERE op = 'insert' AND "column" IS NULL
          AND "table" IN ('projectFolders','threads','connections')
          AND pg_catalog.jsonb_typeof(value) = 'object'
          AND value ? 'projectId' AND value ? 'environmentId') AS valid
      """
    )
  }

  private static func capture(_ connection: PostgresConnection) throws {
    try connection.execute(
      """
      CREATE TEMP TABLE b4app_environment_history_preimage (
        seq bigint PRIMARY KEY, value jsonb, value_text text, whole_row jsonb NOT NULL,
        structural boolean NOT NULL, restore_value boolean NOT NULL
      ) ON COMMIT DROP;
      INSERT INTO pg_temp.b4app_environment_history_preimage
        SELECT c.seq,c.value,c.value::text,pg_catalog.to_jsonb(c),
          coalesce(c.op = 'insert' AND c."column" IS NULL
            AND c."table" IN ('projectFolders','threads','connections')
            AND pg_catalog.jsonb_typeof(c.value) = 'object' AND c.value ? 'projectId',false),
          coalesce(pg_catalog.jsonb_typeof(c.value) = 'object' AND c.value ? 'projectId'
            AND NOT (c.op = 'insert' AND c."column" IS NULL
              AND c."table" IN ('projectFolders','threads','connections')),false)
        FROM public.changes c;
      CREATE TEMP TABLE b4app_environment_history_state ON COMMIT DROP AS
        SELECT (SELECT count(*) FROM public.changes) AS feed_count,
          (SELECT coalesce(jsonb_agg(pg_catalog.to_jsonb(k) ORDER BY pg_catalog.to_jsonb(k)::text),'[]'::jsonb)
            FROM public."columnClocks" k) AS clocks,
          (SELECT last_value FROM public.changes_seq_seq) AS sequence_value,
          (SELECT is_called FROM public.changes_seq_seq) AS sequence_called,
          (SELECT jsonb_agg(jsonb_build_object('oid',c.oid::bigint,'name',
              CASE c.relname WHEN 'projects' THEN 'environments'
                WHEN 'projectFolders' THEN 'environmentFolders'
                WHEN 'projectFoldersByProject' THEN 'environmentFoldersByEnvironment'
                WHEN 'threadsByProject' THEN 'threadsByEnvironment'
                WHEN 'connectionsByProject' THEN 'connectionsByEnvironment' ELSE c.relname END,
              'rls',c.relrowsecurity,'force',c.relforcerowsecurity))
            FROM pg_catalog.pg_class c WHERE c.oid IN (
              'public.projects'::regclass,'public."projectFolders"'::regclass,'public.threads'::regclass,
              'public.connections'::regclass,'public.changes'::regclass,'public."columnClocks"'::regclass,
              'public."projectFoldersByProject"'::regclass,'public."threadsByProject"'::regclass,
              'public."connectionsByProject"'::regclass)) AS objects,
          (SELECT jsonb_agg(jsonb_build_object('oid',t.oid::bigint,'table',t.tgrelid::bigint,
              'enabled',t.tgenabled::text,'name',CASE t.tgname
                WHEN 'projectsChanges' THEN 'environmentsChanges'
                WHEN 'projectFoldersChanges' THEN 'environmentFoldersChanges' ELSE t.tgname END))
            FROM pg_catalog.pg_trigger t WHERE NOT t.tgisinternal AND
              ((t.tgrelid = 'public.projects'::regclass AND t.tgname = 'projectsChanges')
              OR (t.tgrelid = 'public."projectFolders"'::regclass AND t.tgname = 'projectFoldersChanges'))) AS triggers,
          (SELECT coalesce(jsonb_agg(pg_catalog.to_jsonb(m) ORDER BY m.name),'[]'::jsonb)
            FROM public."schemaMigrations" m) AS ledger,
          pg_catalog.to_regprocedure('public.b4app_record_change()')::oid AS function_oid;
      """
    )
  }

  private static func verify(_ connection: PostgresConnection, appliedAt: String) throws {
    try requireTrue(
      connection,
      """
      SELECT (SELECT count(*) FROM pg_temp.b4app_environment_history_state) = 1
        AND (SELECT count(*) FROM public."schemaMigrations") = pg_catalog.jsonb_array_length(s.ledger) + 1
        AND (SELECT count(*) FROM public."schemaMigrations" WHERE name='0011_environments' AND "appliedAt"=$1) = 1
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(s.ledger) e
          LEFT JOIN public."schemaMigrations" m ON m.name=e->>'name'
          WHERE m.name IS NULL OR pg_catalog.to_jsonb(m) IS DISTINCT FROM e)
        AND s.feed_count = (SELECT count(*) FROM public.changes)
        AND s.sequence_value = (SELECT last_value FROM public.changes_seq_seq)
        AND s.sequence_called = (SELECT is_called FROM public.changes_seq_seq)
        AND NOT EXISTS (SELECT 1 FROM public.changes c
          LEFT JOIN pg_temp.b4app_environment_history_preimage p USING(seq) WHERE p.seq IS NULL)
        AND NOT EXISTS (
          SELECT 1 FROM pg_temp.b4app_environment_history_preimage p LEFT JOIN public.changes c USING(seq)
          CROSS JOIN LATERAL (SELECT CASE WHEN p.structural
            THEN (p.value - 'projectId') || jsonb_build_object('environmentId',p.value->'projectId')
            ELSE p.value END AS value) expected
          WHERE c.seq IS NULL OR c.value IS DISTINCT FROM expected.value
            OR c.value::text IS DISTINCT FROM CASE WHEN p.structural THEN expected.value::text ELSE p.value_text END
            OR pg_catalog.to_jsonb(c) IS DISTINCT FROM (p.whole_row || jsonb_build_object(
              'table', CASE p.whole_row->>'table' WHEN 'projects' THEN 'environments'
                WHEN 'projectFolders' THEN 'environmentFolders' ELSE p.whole_row->>'table' END,
              'column', CASE WHEN p.whole_row->>'column' = 'projectId' THEN '"environmentId"'::jsonb
                ELSE p.whole_row->'column' END,
              'value',expected.value)))
        AND (SELECT coalesce(jsonb_agg(e.row ORDER BY e.row::text),'[]'::jsonb) FROM (
          SELECT k || jsonb_build_object(
            'table', CASE k->>'table' WHEN 'projects' THEN 'environments'
              WHEN 'projectFolders' THEN 'environmentFolders' ELSE k->>'table' END,
            'column', CASE WHEN k->>'column' = 'projectId' THEN '"environmentId"'::jsonb ELSE k->'column' END) AS row
          FROM pg_catalog.jsonb_array_elements(s.clocks) k) e)
          = (SELECT coalesce(jsonb_agg(pg_catalog.to_jsonb(k) ORDER BY pg_catalog.to_jsonb(k)::text),'[]'::jsonb)
              FROM public."columnClocks" k)
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(s.objects) e
          LEFT JOIN pg_catalog.pg_class c ON c.oid = (e->>'oid')::oid
          WHERE c.oid IS NULL OR c.relnamespace <> 'public'::regnamespace OR c.relname <> e->>'name'
            OR c.relrowsecurity IS DISTINCT FROM (e->>'rls')::boolean
            OR c.relforcerowsecurity IS DISTINCT FROM (e->>'force')::boolean
            OR CASE WHEN c.relkind = 'r' THEN pg_catalog.row_security_active(c.oid) ELSE false END)
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(s.triggers) e
          LEFT JOIN pg_catalog.pg_trigger t ON t.oid = (e->>'oid')::oid
          WHERE t.oid IS NULL OR t.tgname <> e->>'name' OR t.tgrelid <> (e->>'table')::oid
            OR t.tgenabled::text <> e->>'enabled' OR t.tgfoid <> s.function_oid)
        AND s.function_oid = pg_catalog.to_regprocedure('public.b4app_record_change()')::oid AS valid
      FROM pg_temp.b4app_environment_history_state s
      """, [appliedAt]
    )
  }
}
