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
    #expect(MirrorSchema.version == 6)
    #expect(MirrorSchema.migrations.map(\.version) == [1, 2, 3, 4, 5, 6])
    for table in ["projects", "projectFolders", "devices", "outbox", "columnClocks"] {
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
    #expect(thread.projectId == nil && thread.readTurnId == nil)
    #expect(thread.activity?.latestTurnId == "turn-1")
    #expect(try store.draft(threadId: "thread-1")?.text == "unsent")
    #expect(try store.connections().map(\.id) == ["conn-1"])
    #expect(try store.projects().isEmpty)
    #expect(store.outboxCount == 0)

    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    for (table, column) in [
      ("threads", "projectId"), ("threads", "readTurnId"), ("threads", "ownerDeviceId"),
      ("connections", "ownerDeviceId"), ("projects", "ownerDeviceId"), ("connections", "projectId"),
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
  /// M8b's file gains `connections.projectId` in place, keeping its rows, cursor, link, and outbox.
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
    #expect(connection.id == "conn-1" && connection.projectId == nil)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == MirrorSchema.version)
    #expect(
      try raw.integer(#"SELECT count(*) FROM pragma_table_info('connections') WHERE name = 'projectId'"#) == 1
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
      #expect(try raw.integer("PRAGMA user_version") == 6)
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

  /// The Mac's `projectId` (a local B4 connection's project) arrives in the change log and is kept.
  @Test func connectionProjectIdIsStored() throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(Array(try fixtureAsStored().prefix(1)))
    #expect(try store.connections().first?.projectId == "project-1")
    _ = try store.apply([change("connections", "conn-1", "update", column: "projectId", value: "project-2")])
    #expect(try store.connections().first?.projectId == "project-2")
    _ = try store.apply([change("connections", "conn-1", "update", column: "projectId", value: .null)])
    #expect(try store.connections().first?.projectId == nil)
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
      try raw.exec("PRAGMA user_version = 7")
      raw.close()
    }
    let before = bytes(path)
    #expect(!before.isEmpty)

    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: false)) { try MirrorStore(path: path) }
    #expect(bytes(path) == before)
    let raw = try RawSQLite(path: path)
    defer { raw.close() }
    #expect(try raw.integer("PRAGMA user_version") == 7)
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
      try raw.exec("PRAGMA user_version = 9")
      raw.close()
    }
    #expect(throws: MirrorStoreError.needsRebuild(outboxEmpty: true)) { try MirrorStore(path: path) }
  }

  /// A file a newer build left: a current store with the link saved, then marked version 7, with the
  /// sequence counter and outbox as given.
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
    try raw.exec("PRAGMA user_version = 7")
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
      try raw.exec("PRAGMA user_version = 7")
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
      try raw.exec("PRAGMA user_version = 7")
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
