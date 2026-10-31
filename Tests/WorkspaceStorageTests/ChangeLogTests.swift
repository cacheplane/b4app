import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func seed(_ db: WorkspaceDatabase) throws -> (thread: ConversationThread, turn: Turn) {
  _ = try db.insertConnection(
    Connection(id: "c1", kind: .codex, label: "Codex", target: "/usr/local/bin/codex"))
  let thread = try db.insertThread(
    ConversationThread(
      id: "t1", connectionId: "c1", nativeThreadId: "thr_1", nativeScope: "acct", title: "First",
      context: "/tmp/p"))
  let turn = try db.insertTurn(Turn(id: "u1", threadId: "t1", operationId: "op1"))
  _ = try db.upsertDisplayItem(
    threadId: "t1", turnId: "u1", nativeItemId: nil, role: .user, type: "userMessage",
    payload: ["text": "hello"],
    provenance: .live)
  _ = try db.upsertDisplayItem(
    threadId: "t1", turnId: "u1", nativeItemId: "a1", role: .assistant, type: "agentMessage",
    payload: ["text": "hi", "nested": ["ok": true, "n": 2]], provenance: .live)
  _ = try db.saveDraft(threadId: "t1", text: "unsent")
  return (thread, turn)
}

@Suite struct ChangeLogTests {
  @Test func everyWriteLeavesChangesAndTheLogReplaysIntoAnEqualStore() throws {
    let source = try WorkspaceDatabase.temporary()
    let (thread, turn) = try seed(source)
    _ = try source.updateThread(id: thread.id) {
      $0.title = "Renamed"
      $0.pinned = true
    }
    _ = try source.updateTurn(id: turn.id) {
      $0.status = .terminal
      $0.outcome = .completed
    }
    try source.deleteDraft(threadId: thread.id)

    let changes = try source.changes(after: 0)
    #expect(
      changes.filter { $0.op == "insert" }.map(\.table).sorted() == [
        "connections", "displayItems", "displayItems", "drafts", "threads", "turns",
      ])
    let titleUpdates = changes.filter { $0.op == "update" && $0.table == "threads" && $0.column == "title" }
    #expect(titleUpdates.map { $0.value?.stringValue } == ["Renamed"])
    #expect(
      changes.contains {
        $0.op == "update" && $0.table == "turns" && $0.column == "status"
          && $0.value?.stringValue == "terminal"
      })
    #expect(changes.contains { $0.op == "delete" && $0.table == "drafts" && $0.rowId == thread.id })
    #expect(changes.allSatisfy { $0.deviceId == "local" && !$0.synced && $0.wall > 1_700_000_000_000 })
    #expect(try source.unsyncedChangeCount() == changes.count)

    let target = try WorkspaceDatabase.temporary()
    #expect(try target.replay(changes) == changes.count)
    #expect(try target.listConnections() == source.listConnections())
    #expect(
      try target.listThreads(ThreadFilter(includeArchived: true))
        == source.listThreads(ThreadFilter(includeArchived: true)))
    #expect(try target.turns(threadId: thread.id) == source.turns(threadId: thread.id))
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
    #expect(try target.draft(threadId: thread.id) == nil)
    // A replay records nothing of its own, and replaying twice changes nothing.
    #expect(try target.changes(after: 0).isEmpty)
    #expect(try target.replay(changes) == changes.count)
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
  }

  @Test func exportAndRestoreRoundTrip() throws {
    let source = try WorkspaceDatabase.temporary()
    let (thread, _) = try seed(source)
    let path = NSTemporaryDirectory() + "b4export-\(UUID().uuidString.prefix(6)).jsonl"
    let summary = try source.export(to: path)
    #expect(summary.rows > 6)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    let target = try WorkspaceDatabase.temporary()
    #expect(try target.restore(from: path).rows == summary.rows)
    #expect(try target.listThreads() == source.listThreads())
    #expect(try target.displayItems(threadId: thread.id) == source.displayItems(threadId: thread.id))
    #expect(try target.draft(threadId: thread.id)?.text == "unsent")
    #expect(try target.changes(after: 0).count == source.changes(after: 0).count)
    // Not empty any more: refused without --replace, accepted with it.
    #expect(throws: (any Error).self) { try target.restore(from: path) }
    #expect(try target.restore(from: path, replace: true).rows == summary.rows)
    #expect(try target.tableCounts()["threads"] == 1)
    // Clearing and reloading record nothing: the log is exactly the archive's.
    #expect(try target.changes(after: 0).count == source.changes(after: 0).count)
  }
}
