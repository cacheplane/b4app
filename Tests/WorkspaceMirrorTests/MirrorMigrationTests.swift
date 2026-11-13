import Foundation
import SQLite3
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

/// A bare SQLite connection, for writing files the way an older or newer build left them.
struct RawSQLite {
  let db: OpaquePointer

  init(path: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
      let handle
    else { throw WorkspaceError(.internalError, "could not open \(path)") }
    db = handle
  }

  func exec(_ sql: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
      let text = message.map { String(cString: $0) } ?? "?"
      sqlite3_free(message)
      throw WorkspaceError(.internalError, "\(sql): \(text)")
    }
  }

  func integer(_ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw WorkspaceError(.internalError, String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int64(statement, 0))
  }

  func close() { sqlite3_close_v2(db) }
}

private func temporaryPath() -> String {
  NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
}

private func bytes(_ path: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data() }

private let phoneLink = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Brian's iPhone",
  tokenRef: "secret:hub-token", orgSlug: "cacheplane", username: "blove")

/// A file as M8a's build left it: the v1 DDL, a connection, a thread with a turn and a draft, a
/// cursor, and a link.
private func writeVersion1File(_ path: String) throws {
  let raw = try RawSQLite(path: path)
  defer { raw.close() }
  try raw.exec("PRAGMA journal_mode = WAL")
  let v1 = try #require(MirrorSchema.migrations.first { $0.version == 1 })
  try raw.exec("BEGIN")
  for statement in v1.statements { try raw.exec(statement) }
  try raw.exec("PRAGMA user_version = 1")
  try raw.exec(
    """
    INSERT INTO "connections" ("id", "kind", "label", "enabled", "profileRevision", "target", "capabilities",
      "status", "authStatus", "createdAt", "updatedAt")
    VALUES ('conn-1', 'codex', 'Codex', 1, 1, '', '{}', 'ready', 'authenticated',
      '2026-10-31T12:00:00Z', '2026-10-31T12:00:00Z')
    """)
  try raw.exec(
    """
    INSERT INTO "threads" ("id", "connectionId", "nativeThreadId", "title", "createdAt", "updatedAt")
    VALUES ('thread-1', 'conn-1', 'native-1', 'Kept', '2026-10-31T12:00:00Z', '2026-10-31T12:00:00Z')
    """)
  try raw.exec(
    """
    INSERT INTO "turns" ("id", "threadId", "operationId", "status", "submission", "outcome", "createdAt",
      "updatedAt")
    VALUES ('turn-1', 'thread-1', 'op-1', 'terminal', 'acknowledged', 'completed', '2026-10-31T12:01:00Z',
      '2026-10-31T12:02:00Z')
    """)
  try raw.exec(
    """
    INSERT INTO "drafts" ("threadId", "text", "updatedAt") VALUES ('thread-1', 'unsent', '2026-10-31T12:03:00Z')
    """)
  let link = String(decoding: try JSONCoding.encoder.encode(phoneLink), as: UTF8.self)
    .replacingOccurrences(of: "'", with: "''")
  try raw.exec(#"UPDATE "syncState" SET "cursor" = 42, "link" = '\#(link)' WHERE "id" = 1"#)
  try raw.exec("COMMIT")
}

@Suite struct MirrorMigrationTests {
  @Test func aNewFileIsCreatedAtTheCurrentVersion() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    do { _ = try MirrorStore(path: path) }
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    #expect(MirrorSchema.version == 8)
    #expect(MirrorSchema.migrations.map(\.version) == [1, 2, 3, 4, 5, 6, 7, 8])
    for table in ["environments", "environmentFolders", "devices", "outbox", "columnClocks"] {
      #expect(try raw.integer("SELECT count(*) FROM sqlite_master WHERE name = '\(table)'") == 1, "\(table)")
    }
  }

  @Test func v1FileMigratesInPlaceKeepingRowsAndCursor() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)

    let store = try MirrorStore(path: path)
    #expect(store.cursor == 42)
    #expect(try store.link() == phoneLink)
    let thread = try #require(try store.thread(id: "thread-1"))
    #expect(thread.title == "Kept")
    #expect(thread.environmentId == nil && thread.readTurnId == nil)
    #expect(thread.activity?.latestTurnId == "turn-1")
    #expect(try store.draft(threadId: "thread-1")?.text == "unsent")
    #expect(try store.connections().map(\.id) == ["conn-1"])
    #expect(try store.environments().isEmpty)
    #expect(store.outboxCount == 0)

    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    for (table, column) in [
      ("threads", "environmentId"), ("threads", "readTurnId"), ("threads", "ownerDeviceId"),
      ("connections", "ownerDeviceId"), ("environments", "ownerDeviceId"), ("connections", "environmentId"),
    ] {
      #expect(
        try raw.integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)'") == 1,
        "\(table).\(column)")
    }
    // The migrated file takes local writes like a new one.
    _ = try store.updateThread(id: "thread-1", title: "Edited", pinned: nil, archived: nil)
    #expect(store.outboxCount == 1)
  }

  /// Review Focus 5: a newer file holding unsent edits is reported, never replaced.
  /// M8b's file gains `connections.environmentId` in place, keeping its rows, cursor, link, and outbox.
  @Test func migratesV2ToV3() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      let v2 = try #require(MirrorSchema.migrations.first { $0.version == 2 })
      try raw.exec("BEGIN")
      for statement in v2.statements { try raw.exec(statement) }
      try raw.exec(
        #"INSERT INTO "outbox" ("deviceSeq", "hlc", "table", "rowId", "op", "column", "value") "#
          + #"VALUES (1, '019a396c76e8-0000-phone-1', 'threads', 'thread-1', 'update', 'title', '"x"')"#)
      try raw.exec(#"UPDATE "syncState" SET "lastDeviceSeq" = 1 WHERE "id" = 1"#)
      try raw.exec("PRAGMA user_version = 2")
      try raw.exec("COMMIT")
    }

    let store = try MirrorStore(path: path)
    #expect(store.cursor == 42)
    #expect(try store.link() == phoneLink)
    #expect(store.outboxCount == 1)
    let connection = try #require(try store.connections().first)
    #expect(connection.id == "conn-1" && connection.environmentId == nil)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    #expect(
      try raw.integer(#"SELECT count(*) FROM pragma_table_info('connections') WHERE name = 'environmentId'"#)
        == 1
    )
    #expect(try raw.integer(Self.nativeItemIndex) == 1)
  }

  /// A version 5 file gains a thread's `model` and `permission` and a connection's `models` in place,
  /// keeping its rows, and the models list round-trips as JSON.
  @Test func version6AddsRuntimeChoiceColumns() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      try raw.exec("BEGIN")
      for migration in MirrorSchema.migrations where (2...5).contains(migration.version) {
        for statement in migration.statements { try raw.exec(statement) }
      }
      try raw.exec("PRAGMA user_version = 5")
      try raw.exec("COMMIT")
    }

    let store = try MirrorStore(path: path)
    let thread = try #require(try store.thread(id: "thread-1"))
    #expect(thread.title == "Kept" && thread.model == nil && thread.permission == nil)
    #expect(try store.connections().first?.models == nil)
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
      for (table, column) in [("threads", "model"), ("threads", "permission"), ("connections", "models")] {
        #expect(
          try raw.integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)'") == 1,
          "\(table).\(column)")
      }
    }

    let models = [RuntimeModel(id: "opus", label: "Opus"), RuntimeModel(id: "sonnet", label: "Sonnet")]
    let value = try JSONCoding.decoder.decode(JSONValue.self, from: JSONCoding.encoder.encode(models))
    _ = try store.apply([change("connections", "conn-1", "update", column: "models", value: value)])
    _ = try store.apply([change("threads", "thread-1", "update", column: "permission", value: "plan")])
    #expect(try store.connections().first?.models == models)
    #expect(try store.thread(id: "thread-1")?.permission == "plan")
  }

  /// A version 6 file holding an environment with a folder and a thread in it, a connection serving it, an
  /// unsent rename of the environment, an unsent draft insert, and the per-column clocks and undecodable
  /// markers that name the old tables, becomes a version 7 file under the new names, keeping all of it.
  @Test func mirrorUpgradeRenamesEnvironmentsAndKeepsAnUnsentRename() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      try raw.exec("BEGIN")
      for migration in MirrorSchema.migrations where (2...6).contains(migration.version) {
        for statement in migration.statements { try raw.exec(statement) }
      }
      try raw.exec(
        """
        INSERT INTO "projects" ("id", "name", "manual", "createdAt", "updatedAt", "ownerDeviceId")
        VALUES ('project-1', 'b4app', 1, '2026-10-31T12:00:00Z', '2026-10-31T12:00:00Z', 'phone-1')
        """)
      try raw.exec(
        """
        INSERT INTO "projectFolders" ("id", "projectId", "path", "createdAt")
        VALUES ('folder-1', 'project-1', '/work/b4app', '2026-10-31T12:00:00Z')
        """)
      try raw.exec(#"UPDATE "threads" SET "projectId" = 'project-1' WHERE "id" = 'thread-1'"#)
      try raw.exec(#"UPDATE "connections" SET "projectId" = 'project-1' WHERE "id" = 'conn-1'"#)
      try raw.exec(
        #"INSERT INTO "outbox" ("deviceSeq", "hlc", "table", "rowId", "op", "column", "value") "#
          + #"VALUES (1, '019a396c76e8-0000-phone-1', 'projects', 'project-1', 'update', 'name', '"app"'), "#
          + #"(2, '019a396c76e9-0000-phone-1', 'threads', 'thread-1', 'update', 'projectId', '"project-1"'), "#
          + #"(3, '019a396c76ea-0000-phone-1', 'projectFolders', 'folder-2', 'insert', NULL, "#
          + #"'{"id":"folder-2","projectId":"project-1","path":"/x"}'), "#
          + #"(4, '019a396c76eb-0000-phone-1', 'drafts', 'thread-1', 'insert', NULL, "#
          + #"'{"threadId":"thread-1","text":"projectId stays in text"}')"#)
      try raw.exec(#"UPDATE "syncState" SET "lastDeviceSeq" = 4 WHERE "id" = 1"#)
      try raw.exec(
        #"INSERT INTO "columnClocks" ("table", "rowId", "column", "hlc") VALUES "#
          + #"('projects', 'project-1', 'name', '019a396c76e8-0000-phone-1'), "#
          + #"('threads', 'thread-1', 'projectId', '019a396c76e9-0000-phone-1'), "#
          + #"('threads', 'thread-1', 'title', '019a396c76e7-0000-phone-1')"#)
      try raw.exec(
        #"INSERT INTO "undecodableRows" ("table", "rowId") VALUES ('projects', 'bad-1'), ('projectFolders', 'bad-2')"#
      )
      try raw.exec("PRAGMA user_version = 6")
      try raw.exec("COMMIT")
    }

    let store = try MirrorStore(path: path)
    #expect(store.outboxCount == 4)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    #expect(try raw.integer(#"SELECT count(*) FROM "environments" WHERE "name" = 'b4app'"#) == 1)
    #expect(
      try raw.integer(#"SELECT count(*) FROM "environmentFolders" WHERE "environmentId" = 'project-1'"#) == 1)
    #expect(try raw.integer(#"SELECT count(*) FROM "threads" WHERE "environmentId" = 'project-1'"#) == 1)
    #expect(try raw.integer(#"SELECT count(*) FROM "connections" WHERE "environmentId" = 'project-1'"#) == 1)
    #expect(try raw.integer(#"SELECT count(*) FROM "environments" WHERE "ownerDeviceId" = 'phone-1'"#) == 1)
    for gone in ["projects", "projectFolders", "projectFoldersByProject", "threadsByProject"] {
      #expect(try raw.integer("SELECT count(*) FROM sqlite_master WHERE name = '\(gone)'") == 0, "\(gone)")
    }
    for (table, column) in [("environmentFolders", "environmentId"), ("threads", "environmentId")] {
      #expect(
        try raw.integer("SELECT count(*) FROM pragma_table_info('\(table)') WHERE name = '\(column)'") == 1)
    }
    for index in ["environmentFoldersByEnvironment", "threadsByEnvironment"] {
      #expect(
        try raw.integer("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = '\(index)'") == 1,
        "\(index)")
    }
    // The foreign key follows the table: deleting the environment still cascades to its folders.
    try raw.exec("PRAGMA foreign_keys = ON")
    try raw.exec(#"DELETE FROM "environments" WHERE "id" = 'project-1'"#)
    #expect(try raw.integer(#"SELECT count(*) FROM "environmentFolders""#) == 0)

    // The unsent rename is still queued, under the new table name, with its value intact.
    let pending = try store.outbox(limit: 10)
    #expect(pending.map(\.deviceSeq) == [1, 2, 3, 4])
    #expect(pending[0].table == "environments" && pending[0].column == "name")
    #expect(pending[0].value == .string("app"))
    #expect(pending[1].table == "threads" && pending[1].column == "environmentId")
    #expect(pending[2].table == "environmentFolders")
    #expect(pending[2].value?["environmentId"]?.stringValue == "project-1")
    #expect(pending[2].value?["projectId"] == nil)
    #expect(pending[3].table == "drafts")
    #expect(pending[3].value?["text"]?.stringValue == "projectId stays in text")

    #expect(
      try raw.integer(
        #"SELECT count(*) FROM "columnClocks" WHERE "table" = 'environments' AND "column" = 'name'"#)
        == 1)
    #expect(
      try raw.integer(
        #"SELECT count(*) FROM "columnClocks" WHERE "table" = 'threads' AND "column" = 'environmentId'"#) == 1
    )
    #expect(
      try raw.integer(
        #"SELECT count(*) FROM "columnClocks" WHERE "table" LIKE 'project%' OR "column" = 'projectId'"#) == 0)
    #expect(
      try raw.integer(
        #"SELECT count(*) FROM "undecodableRows" WHERE "table" IN ('environments', 'environmentFolders')"#)
        == 2)
  }

  /// A version 7 file gains the `viewSettings` table in place, keeping its rows, cursor, link, and an
  /// unsent edit; the new table is empty, so the settings read as their defaults.
  @Test func upgradingFromVersion7KeepsExistingRows() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      try raw.exec("BEGIN")
      for migration in MirrorSchema.migrations where (2...7).contains(migration.version) {
        for statement in migration.statements { try raw.exec(statement) }
      }
      try raw.exec(
        #"INSERT INTO "outbox" ("deviceSeq", "hlc", "table", "rowId", "op", "column", "value") "#
          + #"VALUES (1, '019a396c76e8-0000-phone-1', 'threads', 'thread-1', 'update', 'title', '"Kept"')"#)
      try raw.exec(#"UPDATE "syncState" SET "lastDeviceSeq" = 1 WHERE "id" = 1"#)
      try raw.exec("PRAGMA user_version = 7")
      try raw.exec("COMMIT")
    }
    #expect(MirrorSchema.version == 8)

    let store = try MirrorStore(path: path)
    #expect(try store.thread(id: "thread-1")?.title == "Kept")
    #expect(try store.turns(threadId: "thread-1").map(\.id) == ["turn-1"])
    #expect(try store.draft(threadId: "thread-1")?.text == "unsent")
    #expect(store.cursor == 42)
    #expect(try store.link() == phoneLink)
    #expect(store.outboxCount == 1)
    #expect(try store.viewSettings() == ViewSettings())
    #expect(try store.rowCount("viewSettings") == 0)

    // The table takes the settings, and the outbox keeps counting after the unsent edit.
    _ = try store.setViewSettings(quietThreads: .collapsed, showArchived: true)
    #expect(try store.viewSettings() == ViewSettings(quietThreads: .collapsed, showArchived: true))
    #expect(try store.outbox(limit: 10).map(\.deviceSeq) == [1, 2])

    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == 8)
  }

  /// The index the relay's per-delta lookup uses: on `displayItems`, by thread then native item id.
  static let nativeItemIndex = """
    SELECT count(*) FROM sqlite_master m WHERE m.type = 'index' AND m.tbl_name = 'displayItems'
      AND (SELECT group_concat(name, ',') FROM pragma_index_info(m.name)) = 'threadId,nativeItemId'
    """

  @Test func aNewFileHasTheNativeItemIndex() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    do { _ = try MirrorStore(path: path) }
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer(Self.nativeItemIndex) == 1)
  }

  /// The Mac's `environmentId` (a local B4 connection's environment) arrives in the change log and is kept.
  @Test func connectionEnvironmentIdIsStored() throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(Array(try fixtureAsStored().prefix(1)))
    #expect(try store.connections().first?.environmentId == "project-1")
    _ = try store.apply([
      change("connections", "conn-1", "update", column: "environmentId", value: "project-2")
    ])
    #expect(try store.connections().first?.environmentId == "project-2")
    _ = try store.apply([change("connections", "conn-1", "update", column: "environmentId", value: .null)])
    #expect(try store.connections().first?.environmentId == nil)
  }

  @Test func failedMigrationWithPendingEditsKeepsTheFile() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    do {
      let store = try MirrorStore(path: path)
      try store.saveLink(phoneLink)
      _ = try store.apply(Array(try fixtureAsStored().prefix(2)))
      _ = try store.updateThread(id: "thread-1", title: "Unsent", pinned: nil, archived: nil)
      #expect(store.outboxCount == 1)
    }
    do {
      let raw = try RawSQLite(path: path)
      try raw.exec("PRAGMA user_version = \(MirrorSchema.version + 1)")
      raw.close()
    }
    let before = bytes(path)
    #expect(!before.isEmpty)

    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: false)) { try MirrorStore(path: path) }
    #expect(bytes(path) == before)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version + 1)
    #expect(try raw.integer(#"SELECT count(*) FROM "outbox""#) == 1)
  }

  @Test func aMigrationThatThrowsRollsBackAndReportsAnEmptyOutbox() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)
    do {
      // Something v2 creates already exists, so the v2 migration fails part way.
      let raw = try RawSQLite(path: path)
      try raw.exec(#"CREATE TABLE "devices" ("id" TEXT PRIMARY KEY) STRICT"#)
      raw.close()
    }
    let before = bytes(path)

    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: true)) { try MirrorStore(path: path) }
    #expect(bytes(path) == before)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == 1)
    #expect(try raw.integer("SELECT count(*) FROM sqlite_master WHERE name = 'projects'") == 0)
    #expect(try raw.integer(#"SELECT count(*) FROM "threads""#) == 1)
  }

  @Test func aNewerFileWithoutAnOutboxReportsItEmpty() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    do {
      let raw = try RawSQLite(path: path)
      try raw.exec(#"CREATE TABLE "something" ("id" TEXT)"#)
      try raw.exec("PRAGMA user_version = \(MirrorSchema.version + 2)")
      raw.close()
    }
    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: true)) { try MirrorStore(path: path) }
  }

  /// A file a newer build left: a current store with the link saved, then marked one version past
  /// this build's, with the sequence counter and outbox as given.
  private func writeNewerFile(_ path: String, lastDeviceSeq: Int, outboxSeq: Int? = nil) throws {
    do {
      let store = try MirrorStore(path: path)
      try store.saveLink(phoneLink)
    }
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    try raw.exec(#"UPDATE "syncState" SET "lastDeviceSeq" = \#(lastDeviceSeq) WHERE "id" = 1"#)
    if let outboxSeq {
      try raw.exec(
        #"INSERT INTO "outbox" ("deviceSeq", "hlc", "table", "rowId", "op", "column", "value") "#
          + #"VALUES (\#(outboxSeq), '019a396c76e8-0000-phone-1', 'threads', 'thread-1', 'update', 'title', '"x"')"#
      )
    }
    try raw.exec("PRAGMA user_version = \(MirrorSchema.version + 1)")
  }

  /// The first local write after a rebuild, on the fixture's thread.
  private func firstWrite(_ store: MirrorStore) throws -> SyncChange {
    _ = try store.apply(Array(try fixtureAsStored().prefix(2)))
    _ = try store.updateThread(id: "thread-1", title: "After rebuild", pinned: nil, archived: nil)
    return try #require(try store.outbox(limit: 10).first)
  }

  /// The link and the sequence counter survive a rebuild together: reusing a `deviceSeq` under the
  /// same device id would make the hub drop the new edit as one it already accepted.
  @Test(arguments: [(7, nil, 8), (7, 9, 10), (12, 9, 13)])
  func rebuildKeepsTheLinkAndTheSequenceCounter(lastDeviceSeq: Int, outboxSeq: Int?, next: Int) throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeNewerFile(path, lastDeviceSeq: lastDeviceSeq, outboxSeq: outboxSeq)
    #expect(throws: MirrorStoreError.self) { try MirrorStore(path: path) }

    let store = try MirrorStore.rebuild(path: path)
    #expect(try store.link() == phoneLink)
    #expect(store.outboxCount == 0)
    let write = try firstWrite(store)
    #expect(write.deviceSeq == next)
    #expect(HLC(rawValue: write.hlc ?? "")?.deviceId == phoneLink.deviceId)
    // And it is stored, not only held in memory.
    let reopened = try MirrorStore(path: path)
    #expect(try reopened.link() == phoneLink)
  }

  @Test func rebuildingAVersion1FileKeepsItsLinkAndCountsFromOne() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeVersion1File(path)
    let store = try MirrorStore.rebuild(path: path)
    #expect(try store.link() == phoneLink)
    #expect(store.cursor == 0)
    #expect(try firstWrite(store).deviceSeq == 1)
  }

  @Test func rebuildDropsTheLinkWhenTheCounterCannotBeRead() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      let link = String(decoding: try JSONCoding.encoder.encode(phoneLink), as: UTF8.self)
        .replacingOccurrences(of: "'", with: "''")
      try raw.exec(#"CREATE TABLE "syncState" ("id" INTEGER PRIMARY KEY, "link" TEXT, "lastDeviceSeq")"#)
      try raw.exec(#"INSERT INTO "syncState" VALUES (1, '\#(link)', 'seven')"#)
      try raw.exec("PRAGMA user_version = \(MirrorSchema.version + 1)")
    }
    let store = try MirrorStore.rebuild(path: path)
    #expect(try store.link() == nil)
    #expect(try firstWrite(store).deviceSeq == 1)
  }

  @Test func rebuildDropsTheLinkWhenTheOutboxHasNoSequenceColumn() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    try writeNewerFile(path, lastDeviceSeq: 3)
    do {
      let raw = try RawSQLite(path: path)
      defer { raw.close() }
      try raw.exec(#"DROP TABLE "outbox""#)
      try raw.exec(#"CREATE TABLE "outbox" ("seq" INTEGER PRIMARY KEY, "change" TEXT)"#)
    }
    let store = try MirrorStore.rebuild(path: path)
    #expect(try store.link() == nil)
  }

  @Test func rebuildReplacesTheFileWithAFreshOne() throws {
    let path = temporaryPath()
    defer { MirrorStoreTests.remove(path) }
    do {
      let raw = try RawSQLite(path: path)
      try raw.exec("PRAGMA journal_mode = WAL")
      try raw.exec(#"CREATE TABLE "something" ("id" TEXT)"#)
      try raw.exec("PRAGMA user_version = \(MirrorSchema.version + 1)")
      raw.close()
    }
    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: true)) { try MirrorStore(path: path) }

    let store = try MirrorStore.rebuild(path: path)
    #expect(store.cursor == 0)
    #expect(try store.link() == nil)
    #expect(store.outboxCount == 0)
    #expect(try store.threads(includeArchived: true, connectionId: nil, query: nil).isEmpty)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    #expect(try raw.integer("SELECT count(*) FROM sqlite_master WHERE name = 'something'") == 0)
  }
}
