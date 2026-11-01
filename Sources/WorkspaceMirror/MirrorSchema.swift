import Foundation

/// The mirror's SQLite schema: the Mac's synced tables (`Sources/WorkspaceStorage/SQL/0001_init.sql`
/// and `0004_organisation.sql`) with the same quoted camelCase column names, as `STRICT` tables. JSON
/// columns are `TEXT` holding JSON; booleans are `INTEGER` 0 or 1. `localServers` is never synced, so
/// `connections` has no reference to it. `syncState` holds the feed cursor, the hub link, and the
/// highest outbox `deviceSeq` ever issued in one row; `undecodableRows` names the stored rows this
/// build cannot decode, kept current by every write, so diagnostics count them without reading the
/// row tables.
///
/// Version 2 (M8b) adds `projects`, `projectFolders`, `threads.projectId`, `threads.readTurnId`, the
/// mirror's own `ownerDeviceId` on `connections`, `threads`, and `projects` (the device of the row's
/// latest insert), `devices` (the hub's device list), `columnClocks` (the clock of each
/// `SyncColumns.clocked` column's latest write), and `outbox` (the phone's own edits waiting to be
/// pushed). `threads.projectId` has no foreign key, as on the hub: the phone never decides
/// membership, and a thread is never refused because its project row has not arrived.
enum MirrorSchema {
  /// `PRAGMA user_version` once every migration has run.
  static var version: Int { migrations.last?.version ?? 0 }

  /// Run on every open, before anything else.
  static let pragmas = [
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = FULL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA busy_timeout = 5000",
  ]

  /// The synced tables in dependency order, with their key column (as `WorkspaceDatabase.syncedTables`).
  static let syncedTables: [(table: String, key: String)] = [
    ("connections", "id"), ("projects", "id"), ("projectFolders", "id"), ("threads", "id"), ("turns", "id"),
    ("displayItems", "id"), ("runtimeRequests", "id"), ("drafts", "threadId"),
  ]

  /// Tables whose rows record the device that inserted them in `ownerDeviceId`.
  static let ownedTables: Set<String> = ["connections", "threads", "projects"]

  /// Columns of synced tables that only the mirror writes: a change never sets them.
  static let localColumns: Set<String> = ["ownerDeviceId"]

  /// Columns whose `INTEGER` holds a boolean (0 or 1); they read back as JSON `true`/`false`.
  static let booleanColumns: [String: Set<String>] = [
    "connections": ["enabled"], "threads": ["pinned", "archived"], "projects": ["manual"],
  ]

  /// Columns whose `TEXT` holds a JSON document; they read back inline.
  static let jsonColumns: [String: Set<String>] = [
    "connections": ["capabilities"], "displayItems": ["payload"], "runtimeRequests": ["payload"],
  ]

  /// Computed read columns holding JSON (`threads.activity`); never stored.
  static let computedJSONColumns: Set<String> = ["activity"]

  /// Ordered migrations keyed by the `user_version` each leaves behind. A file at version `n` runs
  /// every migration after `n`, all in one transaction.
  static let migrations: [(version: Int, statements: [String])] = [
    (1, version1), (2, version2),
  ]

  /// M8a's schema.
  static let version1 = [
    """
    CREATE TABLE "connections" (
      "id" TEXT PRIMARY KEY,
      "kind" TEXT NOT NULL CHECK ("kind" IN ('codex', 'claude', 'b4')),
      "label" TEXT NOT NULL,
      "enabled" INTEGER NOT NULL DEFAULT 1 CHECK ("enabled" IN (0, 1)),
      "profileRevision" INTEGER NOT NULL DEFAULT 0,
      "target" TEXT NOT NULL,
      "routeKey" TEXT,
      "b4Mode" TEXT,
      "localServerId" TEXT,
      "authReference" TEXT,
      "nativeScope" TEXT,
      "capabilities" TEXT NOT NULL,
      "status" TEXT NOT NULL,
      "authStatus" TEXT NOT NULL,
      "createdAt" TEXT NOT NULL,
      "updatedAt" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "threads" (
      "id" TEXT PRIMARY KEY,
      "connectionId" TEXT NOT NULL REFERENCES "connections" ("id") ON DELETE RESTRICT,
      "nativeThreadId" TEXT NOT NULL,
      "nativeScope" TEXT NOT NULL DEFAULT '',
      "title" TEXT NOT NULL DEFAULT '',
      "context" TEXT,
      "pinned" INTEGER NOT NULL DEFAULT 0 CHECK ("pinned" IN (0, 1)),
      "archived" INTEGER NOT NULL DEFAULT 0 CHECK ("archived" IN (0, 1)),
      "continuity" TEXT NOT NULL DEFAULT 'available'
        CHECK ("continuity" IN ('available', 'missing', 'identity_changed')),
      "createdAt" TEXT NOT NULL,
      "updatedAt" TEXT NOT NULL,
      UNIQUE ("connectionId", "nativeScope", "nativeThreadId")
    ) STRICT
    """,
    #"CREATE INDEX "threadsByConnection" ON "threads" ("connectionId", "updatedAt")"#,
    """
    CREATE TABLE "turns" (
      "id" TEXT PRIMARY KEY,
      "threadId" TEXT NOT NULL REFERENCES "threads" ("id") ON DELETE CASCADE,
      "operationId" TEXT NOT NULL UNIQUE,
      "nativeTurnId" TEXT,
      "inputRef" TEXT,
      "status" TEXT NOT NULL,
      "submission" TEXT NOT NULL,
      "outcome" TEXT,
      "createdAt" TEXT NOT NULL,
      "updatedAt" TEXT NOT NULL
    ) STRICT
    """,
    #"CREATE INDEX "turnsByThread" ON "turns" ("threadId", "createdAt")"#,
    """
    CREATE TABLE "displayItems" (
      "id" TEXT PRIMARY KEY,
      "threadId" TEXT NOT NULL REFERENCES "threads" ("id") ON DELETE CASCADE,
      "turnId" TEXT REFERENCES "turns" ("id") ON DELETE SET NULL,
      "nativeItemId" TEXT,
      "role" TEXT NOT NULL,
      "type" TEXT NOT NULL,
      "payload" TEXT NOT NULL,
      "sequence" INTEGER NOT NULL,
      "provenance" TEXT NOT NULL CHECK ("provenance" IN ('live', 'snapshot', 'cache')),
      "createdAt" TEXT NOT NULL,
      UNIQUE ("threadId", "sequence")
    ) STRICT
    """,
    """
    CREATE TABLE "runtimeRequests" (
      "id" TEXT PRIMARY KEY,
      "nativeRequestId" TEXT NOT NULL,
      "threadId" TEXT NOT NULL REFERENCES "threads" ("id") ON DELETE CASCADE,
      "turnId" TEXT REFERENCES "turns" ("id") ON DELETE SET NULL,
      "adapterGeneration" INTEGER NOT NULL,
      "kind" TEXT NOT NULL,
      "state" TEXT NOT NULL CHECK ("state" IN ('pending', 'resolved', 'expired')),
      "payload" TEXT NOT NULL,
      "createdAt" TEXT NOT NULL,
      "updatedAt" TEXT NOT NULL,
      UNIQUE ("threadId", "adapterGeneration", "nativeRequestId")
    ) STRICT
    """,
    #"CREATE INDEX "runtimeRequestsByThread" ON "runtimeRequests" ("threadId", "createdAt")"#,
    """
    CREATE TABLE "drafts" (
      "threadId" TEXT PRIMARY KEY REFERENCES "threads" ("id") ON DELETE CASCADE,
      "text" TEXT NOT NULL,
      "updatedAt" TEXT NOT NULL
    ) STRICT
    """,
    """
    CREATE TABLE "syncState" (
      "id" INTEGER PRIMARY KEY CHECK ("id" = 1),
      "cursor" INTEGER,
      "link" TEXT
    ) STRICT
    """,
    #"INSERT INTO "syncState" ("id", "cursor", "link") VALUES (1, 0, NULL)"#,
    """
    CREATE TABLE "undecodableRows" (
      "table" TEXT NOT NULL,
      "rowId" TEXT NOT NULL,
      PRIMARY KEY ("table", "rowId")
    ) STRICT
    """,
  ]

  /// M8b: projects, the read marker, owners, devices, clocks, and the outbox.
  static let version2 = [
    """
    CREATE TABLE "projects" (
      "id" TEXT PRIMARY KEY,
      "name" TEXT NOT NULL DEFAULT '',
      "manual" INTEGER NOT NULL DEFAULT 0 CHECK ("manual" IN (0, 1)),
      "createdAt" TEXT NOT NULL,
      "updatedAt" TEXT NOT NULL,
      "ownerDeviceId" TEXT
    ) STRICT
    """,
    """
    CREATE TABLE "projectFolders" (
      "id" TEXT PRIMARY KEY,
      "projectId" TEXT NOT NULL REFERENCES "projects" ("id") ON DELETE CASCADE,
      "path" TEXT NOT NULL,
      "createdAt" TEXT NOT NULL
    ) STRICT
    """,
    #"CREATE INDEX "projectFoldersByProject" ON "projectFolders" ("projectId", "createdAt")"#,
    #"ALTER TABLE "threads" ADD COLUMN "projectId" TEXT"#,
    #"ALTER TABLE "threads" ADD COLUMN "readTurnId" TEXT"#,
    #"ALTER TABLE "threads" ADD COLUMN "ownerDeviceId" TEXT"#,
    #"CREATE INDEX "threadsByProject" ON "threads" ("projectId")"#,
    #"ALTER TABLE "connections" ADD COLUMN "ownerDeviceId" TEXT"#,
    """
    CREATE TABLE "devices" (
      "id" TEXT PRIMARY KEY,
      "name" TEXT NOT NULL,
      "platform" TEXT NOT NULL,
      "lastSeenAt" TEXT,
      "revokedAt" TEXT
    ) STRICT
    """,
    """
    CREATE TABLE "columnClocks" (
      "table" TEXT NOT NULL,
      "rowId" TEXT NOT NULL,
      "column" TEXT NOT NULL,
      "hlc" TEXT NOT NULL,
      PRIMARY KEY ("table", "rowId", "column")
    ) STRICT
    """,
    """
    CREATE TABLE "outbox" (
      "deviceSeq" INTEGER PRIMARY KEY,
      "hlc" TEXT NOT NULL,
      "table" TEXT NOT NULL,
      "rowId" TEXT NOT NULL,
      "op" TEXT NOT NULL CHECK ("op" IN ('insert', 'update')),
      "column" TEXT,
      "value" TEXT
    ) STRICT
    """,
    #"ALTER TABLE "syncState" ADD COLUMN "lastDeviceSeq" INTEGER NOT NULL DEFAULT 0"#,
    #"ALTER TABLE "syncState" ADD COLUMN "refusedUploads" INTEGER NOT NULL DEFAULT 0"#,
  ]
}
