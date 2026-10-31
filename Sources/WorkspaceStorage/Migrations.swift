import Foundation
import GRDB

/// Logical schema from spec section 5.1. Native identities are namespaced by
/// (connectionId, nativeScope) so identical native ids from different endpoints never collide.
enum Migrations {
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "localServers") { t in
        t.primaryKey("id", .text)
        t.column("projectPath", .text).notNull().unique()
        t.column("nodePath", .text).notNull()
        t.column("cliPath", .text).notNull()
        t.column("launchMode", .text).notNull().check { ["development", "source"].contains($0) }
        t.column("envFilePath", .text)
        t.column("requestedPort", .integer)
        t.column("actualPort", .integer)
        t.column("generation", .integer).notNull().defaults(to: 0)
        t.column("ownershipVerified", .boolean).notNull().defaults(to: false)
        t.column("health", .text).notNull()
        t.column("logPath", .text)
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
      }
      try db.create(table: "connections") { t in
        t.primaryKey("id", .text)
        t.column("kind", .text).notNull().check { ["codex", "claude", "b4"].contains($0) }
        t.column("label", .text).notNull()
        t.column("enabled", .boolean).notNull().defaults(to: true)
        t.column("profileRevision", .integer).notNull().defaults(to: 0)
        t.column("target", .text).notNull()
        t.column("routeKey", .text)
        t.column("b4Mode", .text)
        t.column("localServerId", .text).references("localServers", onDelete: .setNull)
        t.column("authReference", .text)
        t.column("capabilities", .text).notNull()
        t.column("status", .text).notNull()
        t.column("authStatus", .text).notNull()
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
      }
      try db.create(table: "threads") { t in
        t.primaryKey("id", .text)
        t.column("connectionId", .text).notNull().references("connections", onDelete: .restrict)
        t.column("nativeThreadId", .text).notNull()
        t.column("nativeScope", .text).notNull().defaults(to: "")
        t.column("title", .text).notNull().defaults(to: "")
        t.column("context", .text)
        t.column("pinned", .boolean).notNull().defaults(to: false)
        t.column("archived", .boolean).notNull().defaults(to: false)
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
        t.uniqueKey(["connectionId", "nativeScope", "nativeThreadId"])
      }
      try db.create(index: "threadsByConnection", on: "threads", columns: ["connectionId", "updatedAt"])
      try db.create(table: "turns") { t in
        t.primaryKey("id", .text)
        t.column("threadId", .text).notNull().references("threads", onDelete: .cascade)
        t.column("operationId", .text).notNull().unique()
        t.column("nativeTurnId", .text)
        t.column("inputRef", .text)
        t.column("status", .text).notNull()
        t.column("submission", .text).notNull()
        t.column("outcome", .text)
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
      }
      try db.create(table: "displayItems") { t in
        t.primaryKey("id", .text)
        t.column("threadId", .text).notNull().references("threads", onDelete: .cascade)
        t.column("turnId", .text).references("turns", onDelete: .setNull)
        t.column("nativeItemId", .text)
        t.column("role", .text).notNull()
        t.column("type", .text).notNull()
        t.column("payload", .text).notNull()
        t.column("sequence", .integer).notNull()
        t.column("provenance", .text).notNull().check { ["live", "snapshot", "cache"].contains($0) }
        t.column("createdAt", .text).notNull()
        t.uniqueKey(["threadId", "sequence"])
      }
      try db.create(table: "runtimeRequests") { t in
        t.primaryKey("id", .text)
        t.column("nativeRequestId", .text).notNull()
        t.column("threadId", .text).notNull().references("threads", onDelete: .cascade)
        t.column("turnId", .text).references("turns", onDelete: .setNull)
        t.column("adapterGeneration", .integer).notNull()
        t.column("kind", .text).notNull()
        t.column("state", .text).notNull().check { ["pending", "resolved", "expired"].contains($0) }
        t.column("payload", .text).notNull()
        t.column("createdAt", .text).notNull()
        t.column("updatedAt", .text).notNull()
        t.uniqueKey(["threadId", "adapterGeneration", "nativeRequestId"])
      }
      try db.create(table: "drafts") { t in
        t.primaryKey("threadId", .text).references("threads", onDelete: .cascade)
        t.column("text", .text).notNull()
        t.column("updatedAt", .text).notNull()
      }
    }
    return migrator
  }
}
