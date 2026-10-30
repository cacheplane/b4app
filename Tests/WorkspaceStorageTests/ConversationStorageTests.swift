import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func seeded() throws -> WorkspaceDatabase {
  let db = try WorkspaceDatabase.temporary()
  _ = try db.insertConnection(Connection(id: "c1", kind: .codex, label: "Codex", target: "/opt/codex"))
  _ = try db.insertThread(
    ConversationThread(id: "t1", connectionId: "c1", nativeThreadId: "thr_1", nativeScope: "me", title: "One")
  )
  return db
}

@Suite struct ConversationStorageTests {
  @Test func upsertReplacesByNativeIdAndKeepsSequence() throws {
    let db = try seeded()
    _ = try db.insertTurn(Turn(id: "turn_a", threadId: "t1", operationId: "op-a"))
    let started = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: "item_1", role: .assistant, type: "agentMessage",
      payload: ["text": ""], provenance: .live)
    let user = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": "hi"],
      provenance: .live)
    let completed = try db.upsertDisplayItem(
      threadId: "t1", turnId: "turn_a", nativeItemId: "item_1", role: .assistant, type: "agentMessage",
      payload: ["text": "Hello"], provenance: .live)
    #expect(completed.id == started.id)
    #expect(completed.sequence == 0)
    #expect(completed.turnId == "turn_a")
    #expect(user.sequence == 1)
    let items = try db.displayItems(threadId: "t1")
    #expect(items.count == 2)
    #expect(items[0].payload["text"]?.stringValue == "Hello")
    try db.close()
  }

  @Test func activeTurnIsTheNonTerminalOne() throws {
    let db = try seeded()
    let turn = try db.insertTurn(Turn(id: "u1", threadId: "t1", operationId: "op1"))
    #expect(try db.activeTurn(threadId: "t1")?.id == turn.id)
    _ = try db.updateTurn(id: "u1") {
      $0.status = .terminal
      $0.outcome = .completed
    }
    #expect(try db.activeTurn(threadId: "t1") == nil)
    #expect(try db.turns(threadId: "t1").count == 1)
    try db.close()
  }

  @Test func expiresPendingRequestsAcrossAConnection() throws {
    let db = try seeded()
    _ = try db.insertThread(
      ConversationThread(
        id: "t2", connectionId: "c1", nativeThreadId: "thr_2", nativeScope: "me", title: "Two"))
    for (id, thread) in [("q1", "t1"), ("q2", "t2")] {
      _ = try db.insertRuntimeRequest(
        RuntimeRequest(
          id: id, nativeRequestId: "7", threadId: thread, adapterGeneration: 1, kind: .commandApproval,
          payload: [:]))
    }
    #expect(try db.runtimeRequest(threadId: "t2", nativeRequestId: "7", adapterGeneration: 1)?.id == "q2")
    #expect(try db.expireRuntimeRequests(connectionId: "c1") == 2)
    #expect(try db.runtimeRequest(id: "q1")?.state == .expired)
    #expect(try db.pendingRuntimeRequests(threadId: "t2").isEmpty)
    try db.close()
  }

  @Test func snapshotReplacementKeepsLiveItems() throws {
    let db = try seeded()
    _ = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: "old", role: .assistant, type: "agentMessage",
      payload: ["text": "cached"], provenance: .snapshot)
    let live = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: "live_1", role: .user, type: "userMessage",
      payload: ["text": "now"], provenance: .live)
    let replacement = DisplayItem(
      id: "s1", threadId: "t1", nativeItemId: "new", role: .assistant, type: "agentMessage",
      payload: ["text": "fresh"], sequence: 100, provenance: .snapshot)
    try db.replaceSnapshotItems(threadId: "t1", with: [replacement])
    let ids = try db.displayItems(threadId: "t1").map(\.id)
    #expect(ids == [live.id, "s1"])
    try db.close()
  }
}
