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

@Suite(.serialized) struct ConversationStorageTests {
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

@Suite(.serialized) struct SnapshotMergeTests {
  @Test func canonicalHistoryIdsReuseMessagesWithinAcknowledgedNativeTurns() throws {
    let db = try seeded()
    defer { try? db.close() }
    var live: [DisplayItem] = []
    for index in 1...2 {
      let turnId = "local-\(index)"
      _ = try db.insertTurn(
        Turn(
          id: turnId, threadId: "t1", operationId: "op-\(index)", nativeTurnId: "turn-\(index)",
          status: .terminal, submission: .acknowledged, outcome: .completed))
      for role in [DisplayItemRole.user, .assistant] {
        live.append(
          try db.upsertDisplayItem(
            threadId: "t1", turnId: turnId,
            nativeItemId: role == .user ? nil : "turn-\(index):m1", role: role,
            type: role == .user ? "userMessage" : "agentMessage",
            payload: ["text": role == .user ? "same question" : "same answer"], provenance: .live))
      }
    }
    // A refused attempt with the same text is not part of native history.
    _ = try db.insertTurn(
      Turn(id: "refused", threadId: "t1", operationId: "refused", status: .terminal, outcome: .failed))
    let refused = try db.upsertDisplayItem(
      threadId: "t1", turnId: "refused", nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": "same question"], provenance: .live)
    let history = try (1...2).flatMap { index in
      try ["user", "assistant"].map { role in
        // Decode the additive adapter field as a real snapshot payload, including on the old code
        // which ignores it. The pre-fix merge inserts duplicate rows instead of preserving identity.
        try JSONValue.object([
          "nativeItemId": .string("history-\(index)-\(role)"), "nativeTurnId": .string("turn-\(index)"),
          "role": .string(role), "type": .string(role == "user" ? "userMessage" : "agentMessage"),
          "payload": ["text": role == "user" ? "same question" : "same answer"],
        ]).decode(SnapshotItem.self)
      }
    }
    for _ in 0..<2 {
      _ = try db.mergeSnapshotItems(threadId: "t1", items: history)
      let rows = try db.displayItems(threadId: "t1")
      #expect(rows.map(\.id) == live.map(\.id) + [refused.id])
      #expect(rows.map(\.turnId) == ["local-1", "local-1", "local-2", "local-2", "refused"])
      #expect(rows.map(\.nativeItemId) == history.map(\.nativeItemId) + [nil])
      #expect(rows.allSatisfy { $0.provenance == .live })
    }
  }

  @Test func scopedFallbackReservesLaterExactMatches() throws {
    let db = try seeded()
    defer { try? db.close() }
    _ = try db.insertTurn(
      Turn(
        id: "local", threadId: "t1", operationId: "op", nativeTurnId: "turn-1", status: .terminal,
        submission: .acknowledged, outcome: .completed))
    var live: [DisplayItem] = []
    for nativeId in ["canonical-second", "turn-1:m2"] {
      live.append(
        try db.upsertDisplayItem(
          threadId: "t1", turnId: "local", nativeItemId: nativeId, role: .assistant, type: "agentMessage",
          payload: ["text": "same answer"], provenance: .live))
    }
    let history = ["canonical-first", "canonical-second"].map {
      SnapshotItem(
        nativeItemId: $0, role: "assistant", type: "agentMessage", payload: ["text": "same answer"],
        nativeTurnId: "turn-1")
    }
    _ = try db.mergeSnapshotItems(threadId: "t1", items: history)
    #expect(try db.displayItems(threadId: "t1").map(\.id) == [live[1].id, live[0].id])
  }

  @Test(arguments: ["ambiguous", "prepared", "unknown", "running", "wrong-turn", "wrong-text", "wrong-type"])
  func scopedFallbackDoesNotGuessAcrossUnconfirmedIdentities(_ scenario: String) throws {
    let db = try seeded()
    defer { try? db.close() }
    let turn = Turn(
      id: "local", threadId: "t1", operationId: "op", nativeTurnId: "turn-1",
      status: scenario == "running" ? .running : .terminal,
      submission: scenario == "prepared" ? .prepared : scenario == "unknown" ? .unknown : .acknowledged,
      outcome: scenario == "running" ? nil : .completed)
    _ = try db.insertTurn(turn)
    if scenario == "ambiguous" {
      var other = turn
      other.id = "other"
      other.operationId = "other"
      _ = try db.insertTurn(other)
    }
    let live = try db.upsertDisplayItem(
      threadId: "t1", turnId: turn.id, nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": "question"], provenance: .live)
    let item = SnapshotItem(
      nativeItemId: nil, role: "user", type: scenario == "wrong-type" ? "other" : "userMessage",
      payload: ["text": scenario == "wrong-text" ? "other question" : "question"],
      nativeTurnId: scenario == "wrong-turn" ? "turn-2" : "turn-1")
    _ = try db.mergeSnapshotItems(threadId: "t1", items: [item])
    let rows = try db.displayItems(threadId: "t1")
    #expect(rows.count == 2)
    #expect(rows.last?.id == live.id)
    #expect(rows.first?.turnId == nil)
  }

  private func snapshot(_ id: String?, _ role: String, _ text: String) -> SnapshotItem {
    SnapshotItem(
      nativeItemId: id, role: role, type: role == "user" ? "userMessage" : "agentMessage",
      payload: ["text": .string(text)])
  }

  @Test func emptyCacheTakesTheSnapshotInOrderAndASecondMergeChangesNothing() throws {
    let db = try seeded()
    let first = try db.mergeSnapshotItems(
      threadId: "t1",
      items: [snapshot("u1", "user", "earlier question"), snapshot("a1", "assistant", "answer")])
    #expect(first == .init(inserted: 2))
    let items = try db.displayItems(threadId: "t1")
    #expect(items.map(\.nativeItemId) == ["u1", "a1"])
    #expect(items.map(\.sequence) == [0, 1])
    #expect(items.allSatisfy { $0.provenance == .snapshot })
    let second = try db.mergeSnapshotItems(
      threadId: "t1",
      items: [snapshot("u1", "user", "earlier question"), snapshot("a1", "assistant", "answer (edited)")])
    #expect(second == .init(updated: 2))
    let after = try db.displayItems(threadId: "t1")
    #expect(after.map(\.id) == items.map(\.id))
    #expect(after[1].payload["text"]?.stringValue == "answer (edited)")
    try db.close()
  }

  @Test func liveItemsAreKeptMatchedByIdOrTextAndNeverDuplicated() throws {
    let db = try seeded()
    let liveUser = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": "hello there"], provenance: .live)
    let liveReply = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: "a2", role: .assistant, type: "agentMessage",
      payload: ["text": "live reply"], provenance: .live)
    let inFlight = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: nil, role: .user, type: "userMessage",
      payload: ["text": "still running"], provenance: .live)
    let stale = try db.upsertDisplayItem(
      threadId: "t1", turnId: nil, nativeItemId: "gone", role: .assistant, type: "agentMessage",
      payload: ["text": "no longer in history"], provenance: .snapshot)
    let summary = try db.mergeSnapshotItems(
      threadId: "t1",
      items: [
        snapshot("u0", "user", "earlier question"), snapshot("a0", "assistant", "earlier answer"),
        snapshot(nil, "user", "hello there"), snapshot("a2", "assistant", "live reply (native copy)"),
      ])
    #expect(summary == .init(inserted: 2, updated: 0, skipped: 2, removed: 1))
    let items = try db.displayItems(threadId: "t1")
    #expect(items.map(\.nativeItemId) == ["u0", "a0", nil, "a2", nil])
    #expect(items.map(\.id)[2...] == [liveUser.id, liveReply.id, inFlight.id][...])
    #expect(items[3].payload["text"]?.stringValue == "live reply")
    #expect(items.map(\.sequence) == [0, 1, 2, 3, 4])
    #expect(!items.contains { $0.id == stale.id })
    #expect(items.filter { Self.text($0) == "hello there" }.count == 1)
    try db.close()
  }

  private static func text(_ item: DisplayItem) -> String? { item.payload["text"]?.stringValue }
}
