import Darwin
import Foundation
import Testing
import WorkspacePlatform

@testable import WorkspaceStorage

/// Temporary causal diagnostic on genuine prefix10. No authority/profile/runtime rows are seeded.
/// Uses only common pre-generation13 APIs so it can run on the captured old13 CI head too.
@Suite(.serialized) struct AgentProtocolBackupStageDiagnosticTests {
  private enum DiagnosticFailure: Error { case catalog, settings, incomplete, physicalBase }
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

  /// POSIX identity of an existing base, before the new leaf is made. No Foundation normalization
  /// participates in this arm's chosen path; malloc storage from realpath(path, NULL) is always released.
  private static func physicalBase(_ literal: String) throws -> String {
    let (resolved, code) = literal.withCString { input in
      let result = Darwin.realpath(input, nil)
      return (result, result == nil ? errno : Int32(0))
    }
    guard let buffer = resolved else {
      // No raw connection or fixture root exists on this early setup refusal.
      print("A3_BACKUP_DIAGNOSTIC arm=physical stage=fixture realpath_errno=\(code)")
      throw DiagnosticFailure.physicalBase
    }
    defer { Darwin.free(buffer) }
    return String(cString: buffer)
  }

  /// Observation only, never admission. lstat resolves parent chains but does not follow the final
  /// component; an earlier recorded link therefore remains a link, not proof of a no-follow walk.
  /// No component name, path, native error description or row value enters these retained facts.
  private static func componentFacts(_ path: String, arm: String, pass: String) -> [String] {
    var prefixes = ["/"]
    var prefix = ""
    for component in path.split(separator: "/") {
      prefix += "/" + String(component)
      prefixes.append(prefix)
    }
    return prefixes.enumerated().map { index, candidate in
      var info = stat()
      let (succeeded, code) = candidate.withCString { input in
        let result = lstat(input, &info)
        return (result == 0, result == 0 ? Int32(0) : errno)
      }
      let kind: String
      if !succeeded {
        kind = code == ENOENT ? "missing" : "error"
      } else if info.st_mode & S_IFMT == S_IFDIR {
        kind = "dir"
      } else if info.st_mode & S_IFMT == S_IFLNK {
        kind = "link"
      } else {
        kind = "other"
      }
      // For missing/error records these false flags are unobserved, not permission conclusions.
      let owned = succeeded && info.st_uid == getuid()
      let ownerRead = succeeded && info.st_mode & 0o400 != 0
      let ownerWrite = succeeded && info.st_mode & 0o200 != 0
      let ownerSearch = succeeded && info.st_mode & 0o100 != 0
      let groupWrite = succeeded && info.st_mode & 0o020 != 0
      let worldWrite = succeeded && info.st_mode & 0o002 != 0
      return
        "A3_BACKUP_DIAGNOSTIC arm=\(arm) pass=\(pass) component=\(index) type=\(kind) errno=\(code) statSucceeded=\(succeeded) uidMatches=\(owned) ownerRead=\(ownerRead) ownerWrite=\(ownerWrite) ownerSearch=\(ownerSearch) groupWrite=\(groupWrite) worldWrite=\(worldWrite)"
    }
  }

  /// Fixed read-only resource observations, not an FD census, limit change or causal conclusion.
  /// Every successfully opened descriptor is closed exactly once; close failure prevents success.
  private static func directoryControlFacts(_ arm: String) -> (facts: [String], healthy: Bool) {
    var facts: [String] = []
    var limits = rlimit()
    let limitResult = getrlimit(RLIMIT_NOFILE, &limits)
    let limitErrno = limitResult == 0 ? Int32(0) : errno
    if limitResult == 0 {
      facts.append(
        "A3_BACKUP_DIAGNOSTIC arm=\(arm) nofileSucceeded=true soft=\(limits.rlim_cur) hard=\(limits.rlim_max) errno=0"
      )
    } else {
      facts.append("A3_BACKUP_DIAGNOSTIC arm=\(arm) nofileSucceeded=false errno=\(limitErrno)")
    }
    let (fd, openErrno) = "/".withCString { input in
      let result = Darwin.open(input, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      return (result, result < 0 ? errno : Int32(0))
    }
    var closeResult: Int32 = 0
    var closeErrno: Int32 = 0
    if fd >= 0 {
      closeResult = Darwin.close(fd)
      closeErrno = closeResult == 0 ? Int32(0) : errno
    }
    facts.append(
      "A3_BACKUP_DIAGNOSTIC arm=\(arm) rootOpenSucceeded=\(fd >= 0) rootOpenErrno=\(openErrno) rootCloseAttempted=\(fd >= 0) rootCloseSucceeded=\(fd >= 0 && closeResult == 0) rootCloseErrno=\(closeErrno)"
    )
    return (facts, limitResult == 0 && fd >= 0 && closeResult == 0)
  }

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
    let base: String
    if physical { base = try Self.physicalBase(literal) } else { base = literal }
    // Keep realpath's bytes through the new descendants; no Foundation URL/path normalization.
    let root = base + (base.hasSuffix("/") ? "" : "/") + "a3-backup-stage-" + UUID().uuidString
    let directory = root + "/backups"
    let path = directory + "/probe.jsonl"
    let writeParent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let selectedHasAlias = root != URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    let parentChanged = writeParent != directory
    print(
      "A3_BACKUP_DIAGNOSTIC arm=\(arm) selectedAlias=\(selectedHasAlias) writeParentChanged=\(parentChanged)")
    var stage = Stage.fixture
    var failed: (String, String)?
    var catalogMessages: [String] = []
    var pathFacts: [String] = []
    var fileControlFailed = false
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
          pathFacts += Self.componentFacts(directory, arm: arm, pass: "before-directory")
          let control = Self.directoryControlFacts(arm)
          pathFacts += control.facts
          fileControlFailed = !control.healthy
          do {
            let directoryFD = try ArchivePublication.directory(directory)
            let result = Darwin.close(directoryFD)
            let code = result == 0 ? Int32(0) : errno
            if result != 0 { fileControlFailed = true }
            pathFacts.append(
              "A3_BACKUP_DIAGNOSTIC arm=\(arm) directoryCloseSucceeded=\(result == 0) directoryCloseErrno=\(code)"
            )
          } catch {
            let observedErrno = errno
            // directory() also has guards and closes its walk FD on throw. This is merely the
            // first available observed errno, not a promise that it is the refusing syscall's code.
            pathFacts.append(
              "A3_BACKUP_DIAGNOSTIC arm=\(arm) directoryRefused=true observedErrno=\(observedErrno)")
            pathFacts += Self.componentFacts(directory, arm: arm, pass: "after-directory-failure")
            throw error
          }
          pathFacts += Self.componentFacts(directory, arm: arm, pass: "after-directory")
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
    for fact in pathFacts { print(fact) }
    for message in catalogMessages { Issue.record(Comment(rawValue: message)) }
    if let failed {
      Issue.record(
        "A3_BACKUP_DIAGNOSTIC arm=\(arm) failedStage=\(stage.rawValue) class=\(failed.0) sqlstate=\(failed.1)"
      )
    }
    #expect(failed == nil, "The selected archive pipeline must complete every required stage.")
    #expect(!fileControlFailed)
    #expect(!rollbackFailed)
    #expect(!cleanupFailed)
    #expect(!FileManager.default.fileExists(atPath: root))
  }
}
