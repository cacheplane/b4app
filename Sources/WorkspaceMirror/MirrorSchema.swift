import Foundation

/// The mirror's SQLite schema: the Mac's six synced tables (`Sources/WorkspaceStorage/SQL/0001_init.sql`)
/// with the same quoted camelCase column names, as `STRICT` tables. JSON columns are `TEXT` holding
/// JSON; booleans are `INTEGER` 0 or 1. `localServers` is never synced, so `connections` has no
/// reference to it. `syncState` holds the feed cursor and the hub link in one row.
enum MirrorSchema {
  /// `PRAGMA user_version` once `ddl` has run.
  static let version = 1

  /// Run on every open, before anything else.
  static let pragmas = [
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = FULL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA busy_timeout = 5000",
  ]

  /// The synced tables in dependency order, with their key column (as `WorkspaceDatabase.syncedTables`).
  static let syncedTables: [(table: String, key: String)] = [
    ("connections", "id"), ("threads", "id"), ("turns", "id"), ("displayItems", "id"),
    ("runtimeRequests", "id"), ("drafts", "threadId"),
  ]

  /// Columns whose `INTEGER` holds a boolean (0 or 1); they read back as JSON `true`/`false`.
  static let booleanColumns: [String: Set<String>] = [
    "connections": ["enabled"], "threads": ["pinned", "archived"],
  ]

  /// Columns whose `TEXT` holds a JSON document; they read back inline.
  static let jsonColumns: [String: Set<String>] = [
    "connections": ["capabilities"], "displayItems": ["payload"], "runtimeRequests": ["payload"],
  ]

  static let ddl = [
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
  ]
}
