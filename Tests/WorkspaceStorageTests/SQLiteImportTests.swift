import Foundation
import SQLite3
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceStorage

/// The pre-0.2 store: GRDB schema v1 plus the v2 and v3 alterations, exactly as the old
/// `Migrations.swift` laid them out (constraints left aside; the data is what the import copies).
private enum SQLiteFixture {
  static let schema = """
    CREATE TABLE localServers (
      id TEXT PRIMARY KEY, projectPath TEXT NOT NULL UNIQUE, nodePath TEXT NOT NULL, cliPath TEXT NOT NULL,
      launchMode TEXT NOT NULL, envFilePath TEXT, requestedPort INTEGER, actualPort INTEGER,
      generation INTEGER NOT NULL DEFAULT 0, ownershipVerified BOOLEAN NOT NULL DEFAULT 0,
      health TEXT NOT NULL, logPath TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);
    CREATE TABLE connections (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, label TEXT NOT NULL, enabled BOOLEAN NOT NULL DEFAULT 1,
      profileRevision INTEGER NOT NULL DEFAULT 0, target TEXT NOT NULL, routeKey TEXT, b4Mode TEXT,
      localServerId TEXT REFERENCES localServers(id) ON DELETE SET NULL, authReference TEXT,
      capabilities TEXT NOT NULL, status TEXT NOT NULL, authStatus TEXT NOT NULL,
      createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);
    CREATE TABLE threads (
      id TEXT PRIMARY KEY, connectionId TEXT NOT NULL REFERENCES connections(id) ON DELETE RESTRICT,
      nativeThreadId TEXT NOT NULL, nativeScope TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '',
      context TEXT, pinned BOOLEAN NOT NULL DEFAULT 0, archived BOOLEAN NOT NULL DEFAULT 0,
      createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, UNIQUE (connectionId, nativeScope, nativeThreadId));
    CREATE INDEX threadsByConnection ON threads (connectionId, updatedAt);
    CREATE TABLE turns (
      id TEXT PRIMARY KEY, threadId TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
      operationId TEXT NOT NULL UNIQUE, nativeTurnId TEXT, inputRef TEXT, status TEXT NOT NULL,
      submission TEXT NOT NULL, outcome TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);
    CREATE TABLE displayItems (
      id TEXT PRIMARY KEY, threadId TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
      turnId TEXT REFERENCES turns(id) ON DELETE SET NULL, nativeItemId TEXT, role TEXT NOT NULL,
      type TEXT NOT NULL, payload TEXT NOT NULL, sequence INTEGER NOT NULL, provenance TEXT NOT NULL,
      createdAt TEXT NOT NULL, UNIQUE (threadId, sequence));
    CREATE TABLE runtimeRequests (
      id TEXT PRIMARY KEY, nativeRequestId TEXT NOT NULL,
      threadId TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
      turnId TEXT REFERENCES turns(id) ON DELETE SET NULL, adapterGeneration INTEGER NOT NULL,
      kind TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL,
      createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, UNIQUE (threadId, adapterGeneration, nativeRequestId));
    CREATE TABLE drafts (
      threadId TEXT PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE, text TEXT NOT NULL,
      updatedAt TEXT NOT NULL);
    -- v2
    ALTER TABLE localServers ADD COLUMN name TEXT NOT NULL DEFAULT '';
    ALTER TABLE localServers ADD COLUMN cliVersion TEXT;
    ALTER TABLE localServers ADD COLUMN pid INTEGER;
    ALTER TABLE localServers ADD COLUMN processStartedAt DOUBLE;
    ALTER TABLE localServers ADD COLUMN statusMessage TEXT;
    ALTER TABLE localServers ADD COLUMN routes TEXT NOT NULL DEFAULT '[]';
    CREATE UNIQUE INDEX localServersByName ON localServers (name);
    -- v3
    ALTER TABLE connections ADD COLUMN nativeScope TEXT;
    ALTER TABLE threads ADD COLUMN continuity TEXT NOT NULL DEFAULT 'available';
    CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
    INSERT INTO grdb_migrations VALUES ('v1'), ('v2'), ('v3');
    """

  static let data = """
    INSERT INTO localServers (id, projectPath, nodePath, cliPath, launchMode, envFilePath, requestedPort, actualPort,
      generation, ownershipVerified, health, logPath, createdAt, updatedAt, name, cliVersion, pid, processStartedAt,
      statusMessage, routes)
    VALUES ('s1', '/Users/me/research', '/usr/local/bin/node', '/Users/me/research/node_modules/@b4run/cli/dist/index.js',
      'source', NULL, 3101, 3101, 2, 1, 'stopped', '/tmp/logs/research.log', '2026-01-01T00:00:00Z',
      '2026-01-02T00:00:00Z', 'research', '0.9.1', 4242, 1700000000.5, 'exited',
      '[{"id":"/chat","kind":"agent","entryFile":"src/app/chat/index.ts"}]');
    INSERT INTO connections (id, kind, label, enabled, profileRevision, target, routeKey, b4Mode, localServerId,
      authReference, capabilities, status, authStatus, createdAt, updatedAt, nativeScope)
    VALUES ('c1', 'codex', 'Codex', 1, 3, '/opt/homebrew/bin/codex', NULL, NULL, NULL, NULL,
      '{"streaming":"supported","native_resume":"unverified"}', 'ready', 'authenticated',
      '2026-01-01T00:00:00Z', '2026-01-03T00:00:00Z', 'me@example.com');
    INSERT INTO connections (id, kind, label, enabled, profileRevision, target, routeKey, b4Mode, localServerId,
      authReference, capabilities, status, authStatus, createdAt, updatedAt, nativeScope)
    VALUES ('c2', 'b4', 'Research chat', 0, 0, 'http://127.0.0.1:3101', '/chat#agent', 'managed_local', 's1',
      'keychain:c2', '{"streaming":"supported","reconnect":"unsupported"}', 'offline', 'not_required',
      '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z', NULL);
    INSERT INTO threads (id, connectionId, nativeThreadId, nativeScope, title, context, pinned, archived,
      createdAt, updatedAt, continuity)
    VALUES ('t1', 'c1', 'thr_1', 'me@example.com', 'Release notes', '/Users/me/project', 1, 0,
      '2026-01-01T00:00:00Z', '2026-01-04T00:00:00Z', 'available');
    INSERT INTO threads (id, connectionId, nativeThreadId, nativeScope, title, context, pinned, archived,
      createdAt, updatedAt, continuity)
    VALUES ('t2', 'c2', 'conv_9', 'http://127.0.0.1:3101', 'Old chat', '/chat#agent', 0, 1,
      '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z', 'missing');
    INSERT INTO turns (id, threadId, operationId, nativeTurnId, inputRef, status, submission, outcome, createdAt, updatedAt)
    VALUES ('u1', 't1', 'op-1', 'turn_1', NULL, 'terminal', 'acknowledged', 'completed',
      '2026-01-01T00:01:00Z', '2026-01-01T00:02:00Z');
    INSERT INTO turns (id, threadId, operationId, nativeTurnId, inputRef, status, submission, outcome, createdAt, updatedAt)
    VALUES ('u2', 't1', 'op-2', NULL, NULL, 'running', 'prepared', NULL, '2026-01-04T00:00:00Z', '2026-01-04T00:00:00Z');
    INSERT INTO displayItems (id, threadId, turnId, nativeItemId, role, type, payload, sequence, provenance, createdAt)
    VALUES ('d1', 't1', 'u1', NULL, 'user', 'userMessage', '{"text":"Write the release notes"}', 0, 'live',
      '2026-01-01T00:01:00Z');
    INSERT INTO displayItems (id, threadId, turnId, nativeItemId, role, type, payload, sequence, provenance, createdAt)
    VALUES ('d2', 't1', 'u1', 'item_1', 'assistant', 'agentMessage',
      '{"text":"Done","content":[{"type":"text","text":"Done"}],"tokens":42,"final":true}', 1, 'snapshot',
      '2026-01-01T00:02:00Z');
    INSERT INTO displayItems (id, threadId, turnId, nativeItemId, role, type, payload, sequence, provenance, createdAt)
    VALUES ('d3', 't2', NULL, 'm_1', 'tool', 'toolCall', '{"name":"search","args":{"q":"b4"}}', 0, 'cache',
      '2026-01-02T00:00:00Z');
    INSERT INTO runtimeRequests (id, nativeRequestId, threadId, turnId, adapterGeneration, kind, state, payload,
      createdAt, updatedAt)
    VALUES ('r1', 'req_7', 't1', 'u2', 3, 'command_approval', 'pending', '{"command":"rm -rf build"}',
      '2026-01-04T00:00:01Z', '2026-01-04T00:00:01Z');
    INSERT INTO drafts (threadId, text, updatedAt) VALUES ('t1', 'unsent reply', '2026-01-04T00:00:02Z');
    """

  /// Write the fixture at `path` with the system SQLite library.
  static func write(to path: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db
    else {
      throw WorkspaceError(.internalError, "Cannot create the SQLite fixture at \(path)")
    }
    defer { sqlite3_close_v2(db) }
    for sql in [schema, data] {
      var message: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
        let text = message.map { String(cString: $0) } ?? "unknown error"
        sqlite3_free(message)
        throw WorkspaceError(.internalError, "SQLite fixture: \(text)")
      }
    }
  }

  static func temporaryPath(_ name: String) throws -> String {
    let dir = NSTemporaryDirectory() + "b4app-sqlite-import-\(UUID().uuidString.lowercased())"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (dir as NSString).appendingPathComponent(name)
  }

  static let expectedCounts = [
    "localServers": 1, "connections": 2, "threads": 2, "turns": 2, "displayItems": 3, "runtimeRequests": 1,
    "drafts": 1,
  ]
}

@Suite struct SQLiteImportTests {
  @Test func importsEveryTableWithTypedValues() throws {
    let path = try SQLiteFixture.temporaryPath("workspace.sqlite")
    try SQLiteFixture.write(to: path)
    let db = try WorkspaceDatabase.temporary()
    defer { try? db.close() }

    let summary = try SQLiteImporter.importFile(at: path, into: db)
    #expect(summary.rows == SQLiteFixture.expectedCounts)
    #expect(summary.total == 12)

    // Local server: integers, a real, a boolean, and the routes JSON.
    let server = try #require(try db.localServer(id: "s1"))
    #expect(server.name == "research")
    #expect(server.launchMode == .source)
    #expect(server.requestedPort == 3101)
    #expect(server.generation == 2)
    #expect(server.pid == 4242)
    #expect(server.processStartedAt == 1700000000.5)
    #expect(server.ownershipVerified == true)
    #expect(server.cliVersion == "0.9.1")
    #expect(server.statusMessage == "exited")
    #expect(
      server.routes == [LocalServerRoute(id: "/chat", kind: "agent", entryFile: "src/app/chat/index.ts")])
    #expect(try db.listLocalServers().count == 1)

    // Connections: enabled flag, nullable v3 column, capabilities JSON, the local server link.
    let enabled = try db.listConnections()
    #expect(enabled.map(\.id) == ["c1"])
    let all = try db.listConnections(includeDisabled: true)
    #expect(all.map(\.id) == ["c1", "c2"])
    let codex = all[0]
    #expect(codex.kind == .codex)
    #expect(codex.profileRevision == 3)
    #expect(codex.nativeScope == "me@example.com")
    #expect(codex.status == .ready)
    #expect(codex.authStatus == .authenticated)
    #expect(codex.capabilities[.streaming] == .supported)
    #expect(codex.capabilities[.nativeResume] == .unverified)
    #expect(codex.capabilities[.reconnect] == nil)
    let b4 = all[1]
    #expect(b4.kind == .b4)
    #expect(b4.enabled == false)
    #expect(b4.b4Mode == .managedLocal)
    #expect(b4.routeKey == "/chat#agent")
    #expect(b4.localServerId == "s1")
    #expect(b4.authReference == "keychain:c2")
    #expect(b4.nativeScope == nil)
    #expect(b4.authStatus == .notRequired)
    #expect(try db.connections(localServerId: "s1").map(\.id) == ["c2"])

    // Threads: pinned first, archived only when asked, continuity preserved.
    #expect(try db.listThreads().map(\.id) == ["t1"])
    let threads = try db.listThreads(ThreadFilter(includeArchived: true))
    #expect(threads.map(\.id) == ["t1", "t2"])
    #expect(threads[0].pinned == true)
    #expect(threads[0].archived == false)
    #expect(threads[0].continuity == .available)
    #expect(threads[0].context == "/Users/me/project")
    #expect(threads[0].nativeScope == "me@example.com")
    #expect(threads[1].archived == true)
    #expect(threads[1].pinned == false)
    #expect(threads[1].continuity == .missing)
    #expect(try db.thread(connectionId: "c2", nativeThreadId: "conv_9")?.id == "t2")

    // Turns: enums and the nullable outcome.
    let turns = try db.turns(threadId: "t1")
    #expect(turns.map(\.id) == ["u1", "u2"])
    #expect(turns[0].status == .terminal)
    #expect(turns[0].submission == .acknowledged)
    #expect(turns[0].outcome == .completed)
    #expect(turns[0].nativeTurnId == "turn_1")
    #expect(turns[1].status == .running)
    #expect(turns[1].outcome == nil)
    #expect(try db.activeTurn(threadId: "t1")?.id == "u2")
    #expect(try db.turn(operationId: "op-1")?.id == "u1")

    // Display items: JSON payloads became jsonb and decode as structured values.
    let items = try db.displayItems(threadId: "t1")
    #expect(items.map(\.id) == ["d1", "d2"])
    #expect(items[0].role == .user)
    #expect(items[0].turnId == "u1")
    #expect(items[0].provenance == .live)
    #expect(items[0].payload["text"]?.stringValue == "Write the release notes")
    #expect(items[1].nativeItemId == "item_1")
    #expect(items[1].sequence == 1)
    #expect(items[1].provenance == .snapshot)
    #expect(items[1].payload["tokens"] == 42)
    #expect(items[1].payload["final"] == true)
    #expect(items[1].payload["content"]?.arrayValue?.first?["text"]?.stringValue == "Done")
    let cached = try db.displayItems(threadId: "t2")
    #expect(cached.count == 1)
    #expect(cached[0].role == .tool)
    #expect(cached[0].provenance == .cache)
    #expect(cached[0].payload["args"]?["q"]?.stringValue == "b4")
    #expect(try db.nextDisplaySequence(threadId: "t1") == 2)

    // Runtime request and draft.
    let pending = try db.pendingRuntimeRequests(threadId: "t1")
    #expect(pending.map(\.id) == ["r1"])
    #expect(pending[0].kind == .commandApproval)
    #expect(pending[0].adapterGeneration == 3)
    #expect(pending[0].turnId == "u2")
    #expect(pending[0].payload["command"]?.stringValue == "rm -rf build")
    #expect(try db.runtimeRequest(threadId: "t1", nativeRequestId: "req_7", adapterGeneration: 3)?.id == "r1")
    #expect(try db.draft(threadId: "t1")?.text == "unsent reply")
    #expect(try db.draft(threadId: "t1")?.updatedAt == "2026-01-04T00:00:02Z")
    #expect(try db.draft(threadId: "t2") == nil)
  }

  @Test func secondImportIsANoOp() throws {
    let path = try SQLiteFixture.temporaryPath("workspace.sqlite")
    try SQLiteFixture.write(to: path)
    let db = try WorkspaceDatabase.temporary()
    defer { try? db.close() }
    #expect(try SQLiteImporter.importFile(at: path, into: db).isEmpty == false)
    let before = try db.listThreads(ThreadFilter(includeArchived: true))

    let again = try SQLiteImporter.importFile(at: path, into: db)
    #expect(again == SQLiteImporter.Summary())
    #expect(again.isEmpty)
    for (table, count) in SQLiteFixture.expectedCounts {
      #expect(try db.rowCount(table: table) == count, "\(table)")
    }
    #expect(try db.listThreads(ThreadFilter(includeArchived: true)) == before)
  }

  @Test func skipsAStoreThatAlreadyHasConnections() throws {
    let path = try SQLiteFixture.temporaryPath("workspace.sqlite")
    try SQLiteFixture.write(to: path)
    let db = try WorkspaceDatabase.temporary()
    defer { try? db.close() }
    _ = try db.insertConnection(Connection(id: "existing", kind: .claude, label: "Claude", target: "/claude"))
    #expect(try SQLiteImporter.importFile(at: path, into: db).isEmpty)
    #expect(try db.listConnections().map(\.id) == ["existing"])
    #expect(try db.listLocalServers().isEmpty)
  }

  @Test func failsClearlyWhenTheFileIsNotADatabase() throws {
    let path = try SQLiteFixture.temporaryPath("workspace.sqlite")
    try Data("not a database at all".utf8).write(to: URL(fileURLWithPath: path))
    let db = try WorkspaceDatabase.temporary()
    defer { try? db.close() }
    #expect(throws: WorkspaceError.self) { try SQLiteImporter.importFile(at: path, into: db) }
    #expect(try db.rowCount(table: "connections") == 0)
  }

  @Test func storeBootImportsAndRetiresTheOldFile() async throws {
    let base = NSTemporaryDirectory() + "b4app-boot-import-\(UUID().uuidString.lowercased())"
    let dataDir = (base as NSString).appendingPathComponent("data")
    try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(
      runtimeDir: (base as NSString).appendingPathComponent("run"), dataDir: dataDir)
    try SQLiteFixture.write(to: paths.databasePath)
    let fm = FileManager.default
    // Stale journal siblings of a rollback-mode file are ignored by SQLite and retired alongside it.
    #expect(fm.createFile(atPath: paths.databasePath + "-wal", contents: Data()))
    #expect(fm.createFile(atPath: paths.databasePath + "-shm", contents: Data()))

    let boot = try await StoreBoot.open(paths: paths, environment: [:])
    defer { try? boot.database.close() }
    #expect(boot.imported?.rows == SQLiteFixture.expectedCounts)
    #expect(!fm.fileExists(atPath: paths.databasePath))
    #expect(!fm.fileExists(atPath: paths.databasePath + "-wal"))
    #expect(!fm.fileExists(atPath: paths.databasePath + "-shm"))
    #expect(fm.fileExists(atPath: paths.databasePath + ".imported"))
    #expect(fm.fileExists(atPath: paths.databasePath + "-wal.imported"))
    #expect(fm.fileExists(atPath: paths.databasePath + "-shm.imported"))
    #expect(try boot.database.listConnections(includeDisabled: true).map(\.id) == ["c1", "c2"])
    #expect(try boot.database.listThreads(ThreadFilter(includeArchived: true)).count == 2)
    #expect(try boot.database.draft(threadId: "t1")?.text == "unsent reply")

    // The retired file is still a readable SQLite database (nothing was deleted or rewritten).
    let retired = try SQLiteImporter.SQLiteFile(path: paths.databasePath + ".imported")
    #expect(try retired.hasTable("threads"))
    #expect(try retired.rows(of: "threads").rows.count == 2)
    retired.close()

    // Opening again finds no file to import and keeps the data.
    let second = try await StoreBoot.open(paths: paths, environment: [:])
    defer { try? second.database.close() }
    #expect(second.imported == nil)
    #expect(try second.database.listConnections(includeDisabled: true).count == 2)
  }
}
