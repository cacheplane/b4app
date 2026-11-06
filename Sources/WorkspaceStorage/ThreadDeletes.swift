import Foundation
import WorkspaceProtocol

/// Where deleting a thread's runtime copy stands: `waiting` is retried at `nextAttemptAt`; `done` and
/// `unsupported` are final.
public enum ThreadDeleteState: String, Sendable {
  case waiting, done, unsupported
}

/// Deleted threads (migration 0008). The marker is synced; the runtime-delete progress is local to this Mac.
extension WorkspaceDatabase {
  /// Run a brief synchronous publisher only while this thread is visible. The row lease orders
  /// publication against local deletion and pulled updates; the shared advisory lock comes first,
  /// exactly as for local writes. The callback must not suspend or reenter the database.
  @discardableResult
  public func withVisibleThread(id: String, _ publish: () -> Void) throws -> Bool {
    try read { c in
      try c.execute("BEGIN")
      do {
        try c.execute(
          "SELECT pg_advisory_xact_lock_shared($1::bigint)", [String(Self.remoteApplyLockKey)])
        let visible = try !c.execute(
          #"SELECT 1 FROM "threads" WHERE "id" = $1 AND "userDeletedAt" IS NULL FOR SHARE"#, [id]
        ).rows.isEmpty
        if visible { publish() }
        try c.execute("COMMIT")
        return visible
      } catch {
        try? c.execute("ROLLBACK")
        throw error
      }
    }
  }

  /// Mark the thread deleted at `at`. A thread already deleted keeps its first time. Nil when the
  /// thread does not exist.
  public func markThreadDeleted(id: String, at: String) throws -> ConversationThread? {
    try write { c in
      _ = try c.execute(
        """
        UPDATE "threads" SET "userDeletedAt" = $2, "updatedAt" = $2
        WHERE "id" = $1 AND "userDeletedAt" IS NULL
        """, [id, at])
      return try threadWithActivity(c, id: id)
    }
  }

  /// Deleted threads whose runtime copy is due a try: never tried, or waiting with its next attempt at
  /// or before `now`.
  public func threadsAwaitingRuntimeDelete(now: String) throws -> [ConversationThread] {
    try read {
      try all(
        $0, ConversationThread.self,
        Self.threadWithActivity
          + """
           LEFT JOIN "threadDeletes" d ON d."threadId" = t."id"
          WHERE \(Self.runtimeDeleteDue)
          ORDER BY t."userDeletedAt" COLLATE "C", t."id" COLLATE "C"
          """, [now])
    }
  }

  /// The deleted thread `threadId` if its runtime copy is still due a try at `now`, else nil (done,
  /// unsupported, waiting until later, or not deleted). A sweep checks again just before it tries.
  public func threadAwaitingRuntimeDelete(id threadId: String, now: String) throws -> ConversationThread? {
    try read {
      try one(
        $0, ConversationThread.self,
        Self.threadWithActivity
          + """
           LEFT JOIN "threadDeletes" d ON d."threadId" = t."id"
          WHERE t."id" = $2 AND \(Self.runtimeDeleteDue)
          """, [now, threadId])
    }
  }

  /// A deleted thread (`t`) whose runtime delete (`d`) was never tried, or is waiting with its next
  /// attempt at or before `$1`. Timestamps compare byte by byte, as everywhere else.
  private static let runtimeDeleteDue = """
    t."userDeletedAt" IS NOT NULL
      AND (d."threadId" IS NULL
        OR (d."state" = 'waiting'
          AND (d."nextAttemptAt" IS NULL OR d."nextAttemptAt" COLLATE "C" <= $1)))
    """

  /// Record one try at deleting the thread's runtime copy.
  public func recordThreadDelete(
    threadId: String, outcome: ThreadDeleteState, error: String?, nextAttemptAt: String?
  ) throws {
    try write {
      _ = try $0.execute(
        """
        INSERT INTO "threadDeletes" ("threadId", "state", "attempts", "nextAttemptAt", "lastError", "updatedAt")
        VALUES ($1, $2, 1, $3, $4, $5)
        ON CONFLICT ("threadId") DO UPDATE SET "state" = EXCLUDED."state",
          "attempts" = "threadDeletes"."attempts" + 1, "nextAttemptAt" = EXCLUDED."nextAttemptAt",
          "lastError" = EXCLUDED."lastError", "updatedAt" = EXCLUDED."updatedAt"
        """,
        [threadId, outcome.rawValue, nextAttemptAt, error, Timestamp.now()])
    }
  }

  /// How many times deleting the thread's runtime copy has been tried.
  public func threadDeleteAttempts(threadId: String) throws -> Int {
    try read {
      let row = try $0.execute(
        "SELECT \"attempts\"::text AS \"n\" FROM \"threadDeletes\" WHERE \"threadId\" = $1", [threadId]
      ).rows.first
      return row?.text("n").flatMap(Int.init) ?? 0
    }
  }

  /// Runtime deletes still waiting (including deleted threads not tried yet) and those not supported,
  /// by the thread's runtime. Runtimes with neither are left out.
  public func threadDeleteSummary() throws -> [ThreadDeleteSummary] {
    try read {
      try $0.execute(
        """
        SELECT c."kind",
          count(*) FILTER (WHERE d."state" IS NULL OR d."state" = 'waiting')::text AS "waiting",
          count(*) FILTER (WHERE d."state" = 'unsupported')::text AS "unsupported"
        FROM "threads" t
        JOIN "connections" c ON c."id" = t."connectionId"
        LEFT JOIN "threadDeletes" d ON d."threadId" = t."id"
        WHERE t."userDeletedAt" IS NOT NULL AND (d."state" IS NULL OR d."state" <> 'done')
        GROUP BY c."kind" ORDER BY c."kind" COLLATE "C"
        """
      ).rows.compactMap { row in
        guard let kind = row.text("kind").flatMap(ConnectionKind.init(rawValue:)) else { return nil }
        return ThreadDeleteSummary(
          kind: kind, waiting: row.text("waiting").flatMap(Int.init) ?? 0,
          unsupported: row.text("unsupported").flatMap(Int.init) ?? 0)
      }
    }
  }
}
