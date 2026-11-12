import Darwin
import Foundation
import Testing
import WorkspacePlatform

@testable import WorkspaceStorage

/// Temporary causal diagnostic on genuine prefix10. No authority/profile/runtime rows are seeded.
/// Uses only common pre-generation13 APIs so it can run on the captured old13 CI head too.
@Suite(.serialized) struct AgentProtocolBackupStageDiagnosticTests {
  private enum DiagnosticFailure: Error { case catalog, settings, incomplete }
  private enum Stage: String {
    case fixture, privacy, catalog, capture, directory, publication, writingRows, rowsWritten
    case contentsWritten, fileSynchronized, renamed, directorySynchronized, commit, readBack, complete
  }
  private static let columns: [String: String] = [
    "schemaMigrations": "name appliedAt",
    "hubLink":
      "id url deviceId deviceName tokenRef orgSlug username cursor lastPushAt lastError joinedAt ownedAs",
    "localServers":
      "id name projectPath nodePath cliPath cliVersion launchMode envFilePath requestedPort actualPort generation pid processStartedAt ownershipVerified health statusMessage routes logPath createdAt updatedAt",
    "projects": "id name manual createdAt updatedAt",
    "projectFolders": "id projectId path createdAt",
    "connections":
      "id kind label enabled profileRevision target routeKey b4Mode localServerId authReference nativeScope capabilities status authStatus createdAt updatedAt projectId models",
    "threads":
      "id connectionId nativeThreadId nativeScope title context pinned archived continuity createdAt updatedAt projectId readTurnId userDeletedAt model permission",
    "turns": "id threadId operationId nativeTurnId inputRef status submission outcome createdAt updatedAt",
    "displayItems": "id threadId turnId nativeItemId role type payload sequence provenance createdAt",
    "runtimeRequests":
      "id nativeRequestId threadId turnId adapterGeneration kind state payload createdAt updatedAt",
    "drafts": "threadId text updatedAt",
    "devices": "id name createdAt",
    "changes": "seq deviceId wall table rowId op column value synced hlc",
    "columnClocks": "table rowId column hlc",
    "settings": "key value",
    "usageReadings": "connectionId reading observedAt",
    "tokenUsage": "turnId connectionId recordedAt totalTokens",
    "connectionUsage": "connectionId reading tokens updatedAt",
    "threadDeletes": "threadId state attempts nextAttemptAt lastError updatedAt",
  ]
  private static let nonText: [String: String] = [
    "hubLink.id": "int4", "hubLink.cursor": "int8",
    "localServers.requestedPort": "int4", "localServers.actualPort": "int4",
    "localServers.generation": "int4", "localServers.pid": "int4",
    "localServers.processStartedAt": "float8", "localServers.ownershipVerified": "bool",
    "localServers.routes": "jsonb", "projects.manual": "bool", "connections.enabled": "bool",
    "connections.profileRevision": "int4", "connections.capabilities": "jsonb",
    "connections.models": "jsonb", "threads.pinned": "bool", "threads.archived": "bool",
    "displayItems.payload": "jsonb", "displayItems.sequence": "int4",
    "runtimeRequests.adapterGeneration": "int4", "runtimeRequests.payload": "jsonb",
    "changes.seq": "int8", "changes.wall": "int8", "changes.value": "jsonb", "changes.synced": "bool",
    "settings.value": "jsonb", "tokenUsage.totalTokens": "int8", "connectionUsage.reading": "jsonb",
    "connectionUsage.tokens": "jsonb", "threadDeletes.attempts": "int4",
  ]
  private static let ten = [
    "0001_init", "0002_changes", "0003_hub", "0004_organisation", "0005_relay", "0006_usage",
    "0007_connection_usage", "0008_thread_delete", "0009_thread_runtime_choice", "0010_owned_rows",
  ]

  private static func progress(_ arm: String, _ stage: Stage) {
    print("A3_BACKUP_DIAGNOSTIC arm=\(arm) stage=\(stage.rawValue)")
  }

  private static func catalog(
    _ c: PostgresConnection, arm: String, messages: inout [String]
  ) throws {
    let tables = Set(
      try c.execute(
        "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'"
      ).rows.compactMap { $0.text("tablename") })
    let expected = Set(columns.keys)
    var valid = tables == expected
    for missing in expected.subtracting(tables).sorted() {
      messages.append("A3_BACKUP_DIAGNOSTIC arm=\(arm) missing-known-table=\(missing)")
    }
    if !tables.subtracting(expected).isEmpty {
      messages.append(
        "A3_BACKUP_DIAGNOSTIC arm=\(arm) unexpected-table-count=\(tables.subtracting(expected).count)")
    }
    for table in expected.intersection(tables).sorted() {
      let actual = try c.execute(
        """
        SELECT a.attname AS name,
          CASE a.atttypid WHEN 'text'::regtype THEN 'text' WHEN 'int4'::regtype THEN 'int4'
            WHEN 'int8'::regtype THEN 'int8' WHEN 'float8'::regtype THEN 'float8'
            WHEN 'bool'::regtype THEN 'bool' WHEN 'jsonb'::regtype THEN 'jsonb' ELSE 'unknown' END AS kind
        FROM pg_catalog.pg_attribute a WHERE a.attrelid=pg_catalog.to_regclass($1)
          AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum
        """, ["public." + Rows.quote(table)]
      ).rows
      let expectedNames = Set(columns[table]!.split(separator: " ").map(String.init))
      let names = Set(actual.compactMap { $0.text("name") })
      for missing in expectedNames.subtracting(names).sorted() {
        valid = false
        messages.append("A3_BACKUP_DIAGNOSTIC arm=\(arm) missing-known-column=\(table).\(missing)")
      }
      if !names.subtracting(expectedNames).isEmpty {
        valid = false
        messages.append(
          "A3_BACKUP_DIAGNOSTIC arm=\(arm) unexpected-column-count=\(names.subtracting(expectedNames).count)")
      }
      for row in actual {
        guard let name = row.text("name"), expectedNames.contains(name) else { continue }
        if row.text("kind") != nonText[table + "." + name, default: "text"] {
          valid = false
          // Emit only a source-owned coordinate, never a native/custom type name or row value.
          messages.append("A3_BACKUP_DIAGNOSTIC arm=\(arm) type-mismatch=\(table).\(name)")
        }
      }
    }
    guard valid else { throw DiagnosticFailure.catalog }
  }

  private static func errorClass(_ error: any Error) -> (String, String) {
    if let pg = error as? PostgresError {
      let code = pg.sqlState
      let valid =
        code.utf8.count == 5
        && code.utf8.allSatisfy {
          (48...57).contains($0) || (65...90).contains($0)
        }
      return ("postgres", valid ? code : "invalid")
    }
    if error is WorkspaceArchive.Rejection { return ("archive", "none") }
    if error is DiagnosticFailure { return ("diagnostic", "none") }
    let native = error as NSError
    if native.domain == NSPOSIXErrorDomain { return ("posix", "none") }
    if native.domain == NSCocoaErrorDomain { return ("foundation", "none") }
    return ("other", "none")
  }

  @Test(arguments: [false, true])
  func genuinePrefixTenArchiveStages(physical: Bool) throws {
    let arm = physical ? "physical" : "literal"
    let literal = NSTemporaryDirectory()
    let canonical = URL(fileURLWithPath: literal).resolvingSymlinksInPath().path
    let base = physical ? canonical : literal
    let root = (base as NSString).appendingPathComponent("a3-backup-stage-" + UUID().uuidString)
    let directory = (root as NSString).appendingPathComponent("backups")
    let path = (directory as NSString).appendingPathComponent("probe.jsonl")
    let writeParent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let selectedHasAlias = root != URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    let parentChanged = writeParent != directory
    print(
      "A3_BACKUP_DIAGNOSTIC arm=\(arm) selectedAlias=\(selectedHasAlias) writeParentChanged=\(parentChanged)")
    var stage = Stage.fixture
    var failed: (String, String)?
    var catalogMessages: [String] = []
    var transactionOpen = false
    var rollbackFailed = false
    var cleanupFailed = false
    var rootCreated = false
    Self.progress(arm, stage)
    do {
      try FileManager.default.createDirectory(
        atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      rootCreated = true
      let endpoint = try EphemeralPostgres.endpoint()
      // Lexical raw libpq lifetime ends before failure reporting and fixture directory cleanup.
      do {
        let c = try PostgresConnection(
          lib: LibPQ.load(binDir: endpoint.binDir!),
          connectionString:
            "host=\(endpoint.socketDir) port=\(endpoint.port) dbname=\(endpoint.database) user=\(NSUserName())"
        )
        do {
          try Migrator.ensureLedger(c, table: Migrator.table)
          let files = try Migrator.files().filter { $0.name < "0011" }
          guard files.map(\.name) == Self.ten else { throw DiagnosticFailure.catalog }
          for file in files {
            try c.execute(file.sql)
            try c.execute(
              "INSERT INTO public.\"schemaMigrations\" (name,\"appliedAt\") VALUES ($1,'diagnostic')",
              [file.name])
          }
          try c.execute("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
          transactionOpen = true
          stage = .privacy; Self.progress(arm, stage)
          try ProtocolGrantProtection.establish(c)
          stage = .catalog; Self.progress(arm, stage)
          try Self.catalog(c, arm: arm, messages: &catalogMessages)
          stage = .capture; Self.progress(arm, stage)
          let schema = try WorkspaceArchive.captureSchema(c, present: Set(Self.columns.keys))
          stage = .directory; Self.progress(arm, stage)
          let directoryFD = try ArchivePublication.directory(directory)
          Darwin.close(directoryFD)
          stage = .publication; Self.progress(arm, stage)
          try ArchivePublication.write(
            to: path, privateDirectory: true,
            observe: { event in
              switch event {
              case .contentsWritten: stage = .contentsWritten
              case .fileSynchronized: stage = .fileSynchronized
              case .renamed: stage = .renamed
              case .directorySynchronized: stage = .directorySynchronized
              }
              Self.progress(arm, stage)
            }
          ) { handle in
            stage = .writingRows; Self.progress(arm, stage)
            try WorkspaceArchive.write(c, schema: schema, purpose: "preMigration", handle: handle)
            stage = .rowsWritten; Self.progress(arm, stage)
          }
          stage = .commit; Self.progress(arm, stage)
          try c.execute("COMMIT")
          transactionOpen = false
          stage = .readBack; Self.progress(arm, stage)
          let input = try WorkspaceArchive.read(Data(contentsOf: URL(fileURLWithPath: path)))
          guard input.version == 4, input.dataCount == 0,
            input.records["schemaMigrations"]?.count == 10,
            input.records["schemaMigrations"]?.compactMap({ $0.row["name"] as? String }).sorted() == Self.ten,
            try FileManager.default.contentsOfDirectory(atPath: directory) == ["probe.jsonl"]
          else { throw DiagnosticFailure.incomplete }
          stage = .complete; Self.progress(arm, stage)
        } catch {
          failed = Self.errorClass(error)
          if transactionOpen {
            do { try c.execute("ROLLBACK"); transactionOpen = false } catch { rollbackFailed = true }
          }
        }
      }
    } catch { failed = Self.errorClass(error) }
    if rootCreated {
      do { try FileManager.default.removeItem(atPath: root) } catch { cleanupFailed = true }
    }
    for message in catalogMessages { Issue.record(Comment(rawValue: message)) }
    if let failed {
      Issue.record(
        "A3_BACKUP_DIAGNOSTIC arm=\(arm) failedStage=\(stage.rawValue) class=\(failed.0) sqlstate=\(failed.1)"
      )
    }
    #expect(failed == nil, "The selected archive pipeline must complete every required stage.")
    #expect(!rollbackFailed)
    #expect(!cleanupFailed)
    #expect(!FileManager.default.fileExists(atPath: root))
  }
}
