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
///
/// Version 3 (M8c) adds `connections.projectId`, the project a local B4 connection serves (a Mac-only
/// column the phone reads to offer B4 connections when starting a thread), and an index on
/// `displayItems ("threadId", "nativeItemId")` for the relay's lookup on every streamed delta.
///
/// Version 7 renames the project to the environment: `projects` and `projectFolders` become
/// `environments` and `environmentFolders`, and the three `projectId` columns become `environmentId`.
/// The table and column names the mirror also stores as data (the outbox, `columnClocks`, and
/// `undecodableRows`) are rewritten with them.
///
/// Version 8 adds `viewSettings`, the account's one row of view settings (id `view`).
///
/// Version 10 adds `viewSettings.density` and converts the stored row's old sidebar values, as the Mac's
/// `0015_density.sql`.
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
    ("connections", "id"), ("environments", "id"), ("environmentFolders", "id"), ("threads", "id"),
    ("turns", "id"),
    ("displayItems", "id"), ("runtimeRequests", "id"), ("drafts", "threadId"),
    ("connectionUsage", "connectionId"), ("viewSettings", "id"),
  ]

  /// Tables whose rows record the device that inserted them in `ownerDeviceId`.
  static let ownedTables: Set<String> = ["connections", "threads", "environments"]

  /// Tables whose insert carries only the key and the columns it sets (the Mac's migration 0013): a
  /// null or absent column in one is "not set", so it never overwrites a stored value or claims a clock.
  /// Any device may create such a row before it has seen another device's.
  static let partialInsertTables: Set<String> = ["viewSettings"]

  /// Columns of synced tables that only the mirror writes: a change never sets them.
  static let localColumns: Set<String> = ["ownerDeviceId"]

  /// Columns whose `INTEGER` holds a boolean (0 or 1); they read back as JSON `true`/`false`.
  static let booleanColumns: [String: Set<String>] = [
    "connections": ["enabled"], "threads": ["pinned", "archived"], "environments": ["manual"],
    "viewSettings": ["showArchived"],
  ]

  /// Columns whose `TEXT` holds a JSON document; they read back inline.
  static let jsonColumns: [String: Set<String>] = [
    "connections": ["capabilities", "models", "commands"], "displayItems": ["payload"],
    "runtimeRequests": ["payload"],
    "connectionUsage": ["reading", "tokens"],
  ]

  /// Computed read columns holding JSON (`threads.activity`); never stored.
  static let computedJSONColumns: Set<String> = ["activity"]

  /// Ordered migrations keyed by the `user_version` each leaves behind. A file at version `n` runs
  /// every migration after `n`, all in one transaction.
  static let migrations: [(version: Int, statements: [String])] = [
    (1, version1), (2, version2), (3, version3), (4, version4), (5, version5), (6, version6),
    (7, version7), (8, version8), (9, version9), (10, version10),
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

  /// M8c: the project a local B4 connection serves, and an index for the relay's per-delta lookup of
  /// an item by its native id.
  static let version3 = [
    #"ALTER TABLE "connections" ADD COLUMN "projectId" TEXT"#,
    #"CREATE INDEX IF NOT EXISTS "displayItemsByNativeId" ON "displayItems" ("threadId", "nativeItemId")"#,
  ]

  /// Usage on the phone: each connection's latest plan reading and B4 token totals, as the Mac writes
  /// them (`reading` and `tokens` hold JSON documents).
  static let version4 = [
    """
    CREATE TABLE "connectionUsage" (
      "connectionId" TEXT PRIMARY KEY REFERENCES "connections" ("id") ON DELETE CASCADE,
      "reading" TEXT,
      "tokens" TEXT,
      "updatedAt" TEXT
    ) STRICT
    """
  ]

  /// Deleting threads: a deleted thread keeps its row, marked by `userDeletedAt`, and is never listed.
  static let version5 = [
    #"ALTER TABLE "threads" ADD COLUMN "userDeletedAt" TEXT"#
  ]

  /// The new-thread composer: a thread's chosen model and permission mode, and the models a
  /// connection offers (a JSON list).
  static let version6 = [
    #"ALTER TABLE "threads" ADD COLUMN "model" TEXT"#,
    #"ALTER TABLE "threads" ADD COLUMN "permission" TEXT"#,
    #"ALTER TABLE "connections" ADD COLUMN "models" TEXT"#,
  ]

  /// Environments: the project renamed. Tables, columns and indexes are renamed in place (SQLite
  /// rewrites the foreign key and any index on a renamed column; the two indexes are dropped first and
  /// created again under their new names). The names stored as data follow: each outbox row's table and
  /// column, the keys of an unsent insert's row, `columnClocks`, and `undecodableRows`. Without that an
  /// unsent edit would name a table the hub no longer knows and a column's clock would be lost.
  static let version7 =
    [
      #"DROP INDEX "projectFoldersByProject""#,
      #"DROP INDEX "threadsByProject""#,
      #"ALTER TABLE "projects" RENAME TO "environments""#,
      #"ALTER TABLE "projectFolders" RENAME TO "environmentFolders""#,
      #"ALTER TABLE "environmentFolders" RENAME COLUMN "projectId" TO "environmentId""#,
      #"ALTER TABLE "threads" RENAME COLUMN "projectId" TO "environmentId""#,
      #"ALTER TABLE "connections" RENAME COLUMN "projectId" TO "environmentId""#,
      #"CREATE INDEX "environmentFoldersByEnvironment" ON "environmentFolders" ("environmentId", "createdAt")"#,
      #"CREATE INDEX "threadsByEnvironment" ON "threads" ("environmentId")"#,
    ]
    + ["outbox", "columnClocks", "undecodableRows"].flatMap { stored in
      [
        #"UPDATE "\#(stored)" SET "table" = 'environments' WHERE "table" = 'projects'"#,
        #"UPDATE "\#(stored)" SET "table" = 'environmentFolders' WHERE "table" = 'projectFolders'"#,
      ]
    } + [
      #"UPDATE "outbox" SET "column" = 'environmentId' WHERE "column" = 'projectId'"#,
      #"UPDATE "columnClocks" SET "column" = 'environmentId' WHERE "column" = 'projectId'"#,
      """
      UPDATE "outbox"
        SET "value" = json_set(json_remove("value", '$.projectId'), '$.environmentId', json_extract("value", '$.projectId'))
        WHERE "op" = 'insert' AND "table" IN ('environments', 'environmentFolders', 'threads', 'connections')
          AND CASE WHEN json_valid("value") THEN json_type("value", '$.projectId') END IS NOT NULL
      """,
    ]

  /// View settings: one synced row whose id is always `view`, as the Mac's `0013_view_settings.sql`.
  /// Every column but the key is nullable, and the text columns take any value, so one this build does
  /// not know is kept (and reads as the default).
  static let version8 = [
    """
    CREATE TABLE "viewSettings" (
      "id" TEXT PRIMARY KEY,
      "arrangement" TEXT,
      "quietThreads" TEXT,
      "showArchived" INTEGER CHECK ("showArchived" IN (0, 1)),
      "updatedAt" TEXT
    ) STRICT
    """
  ]

  /// Runtime commands: the commands a connection's runtime runs from a message (a JSON list).
  static let version9 = [
    #"ALTER TABLE "connections" ADD COLUMN "commands" TEXT"#
  ]

  /// Density: how tall the thread list's rows are (`normal`, `dense`), split out of `quietThreads`,
  /// which now holds only where the quiet threads go (`shown`, `collapsed`, `hidden`). Nullable and any
  /// text, like the row's other columns. The stored row's old values are converted: `small` is shown at
  /// normal density, `tiny` shown and dense, `collapsed` and `hidden` keep their place at normal
  /// density; a density already stored is kept, and a null or unknown value, or no row, is left alone.
  /// The conversion queues nothing and claims no clock (every device converts its own copy, and the hub
  /// its own); an unsent outbox entry carrying an old value is pushed as it is.
  static let version10 = [
    #"ALTER TABLE "viewSettings" ADD COLUMN "density" TEXT"#,
    """
    UPDATE "viewSettings" SET
      "density" = coalesce("density", CASE "quietThreads" WHEN 'tiny' THEN 'dense' ELSE 'normal' END),
      "quietThreads" = CASE "quietThreads" WHEN 'small' THEN 'shown' WHEN 'tiny' THEN 'shown' ELSE "quietThreads" END
    WHERE "quietThreads" IN ('small', 'tiny', 'collapsed', 'hidden')
    """,
  ]
}
