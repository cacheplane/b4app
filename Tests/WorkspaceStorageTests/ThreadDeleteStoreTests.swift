import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func seed(_ db: WorkspaceDatabase, kind: ConnectionKind = .claude) throws {
  _ = try db.insertConnection(Connection(id: "c1", kind: kind, label: "c1", target: "/x"))
  for id in ["t1", "t2"] {
    _ = try db.insertThread(
      ConversationThread(id: id, connectionId: "c1", nativeThreadId: "n-\(id)", title: id, context: "/tmp"))
  }
}

@Suite struct ThreadDeleteStoreTests {
  @Test func aDeletedThreadLeavesEveryList() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    _ = try db.markThreadDeleted(id: "t1", at: "2026-11-02T12:00:00.000Z")
    #expect(try db.listThreads().map(\.id) == ["t2"])
    #expect(try db.listThreads(ThreadFilter(includeArchived: true)).map(\.id) == ["t2"])
    #expect(try db.thread(id: "t1")?.userDeletedAt == "2026-11-02T12:00:00.000Z")
  }

  @Test func markingKeepsTheFirstTimeAndIsLogged() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let before = try db.changes(after: 0).count
    _ = try db.markThreadDeleted(id: "t1", at: "2026-11-02T12:00:00.000Z")
    let logged = try db.changes(after: 0).dropFirst(before)
    #expect(logged.contains { $0.table == "threads" && $0.column == "userDeletedAt" })
    _ = try db.markThreadDeleted(id: "t1", at: "2026-11-03T12:00:00.000Z")
    #expect(try db.thread(id: "t1")?.userDeletedAt == "2026-11-02T12:00:00.000Z")
  }

  @Test func awaitingFollowsTheRecordAndItsBackoff() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    _ = try db.markThreadDeleted(id: "t1", at: "2026-11-02T12:00:00.000Z")
    let now = "2026-11-02T12:00:01.000Z"
    #expect(try db.threadsAwaitingRuntimeDelete(now: now).map(\.id) == ["t1"])
    try db.recordThreadDelete(
      threadId: "t1", outcome: .waiting, error: "offline", nextAttemptAt: "2026-11-02T12:00:31.000Z")
    #expect(try db.threadsAwaitingRuntimeDelete(now: now).isEmpty)
    #expect(try db.threadsAwaitingRuntimeDelete(now: "2026-11-02T12:00:31.000Z").map(\.id) == ["t1"])
    try db.recordThreadDelete(threadId: "t1", outcome: .done, error: nil, nextAttemptAt: nil)
    #expect(try db.threadsAwaitingRuntimeDelete(now: "2026-11-09T00:00:00.000Z").isEmpty)
    #expect(try db.threadDeleteAttempts(threadId: "t1") == 2)
    _ = try db.markThreadDeleted(id: "t2", at: "2026-11-02T12:00:00.000Z")
    try db.recordThreadDelete(threadId: "t2", outcome: .unsupported, error: nil, nextAttemptAt: nil)
    #expect(try db.threadsAwaitingRuntimeDelete(now: "2026-11-09T00:00:00.000Z").isEmpty)
  }

  @Test func summaryCountsWaitingAndUnsupportedByKind() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    _ = try db.markThreadDeleted(id: "t1", at: "2026-11-02T12:00:00.000Z")
    _ = try db.markThreadDeleted(id: "t2", at: "2026-11-02T12:00:00.000Z")
    try db.recordThreadDelete(threadId: "t2", outcome: .unsupported, error: nil, nextAttemptAt: nil)
    #expect(try db.threadDeleteSummary() == [ThreadDeleteSummary(kind: .claude, waiting: 1, unsupported: 1)])
    try db.recordThreadDelete(threadId: "t1", outcome: .done, error: nil, nextAttemptAt: nil)
    #expect(try db.threadDeleteSummary() == [ThreadDeleteSummary(kind: .claude, waiting: 0, unsupported: 1)])
  }
}
