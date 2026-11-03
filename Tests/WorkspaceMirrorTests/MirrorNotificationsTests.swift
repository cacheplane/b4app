import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private func turnRow(_ id: String, thread: String, created: String) throws -> JSONValue {
  try JSONValue(
    encoding: Turn(
      id: id, threadId: thread, operationId: "op-\(id)", status: .terminal, outcome: .completed,
      createdAt: created, updatedAt: created))
}

@Suite struct MirrorNotificationsTests {
  @Test func outstandingFollowsRequestsAndReads() throws {
    let store = try AttentionFixture.load().store()
    let keys = [
      "request:r-arl1", "request:r-fu1", "turn:u-ua1", "turn:u-ub1", "request:nope", "turn:nope",
      "other:u-ua1", "request:", "u-ua1", "",
    ]
    // r-arl1 is pending; r-fu1 is resolved; u-ua1 and u-ub1 are unread; the rest are not keys.
    #expect(
      try store.stillOutstanding(keys: keys) == ["request:r-arl1", "turn:u-ua1", "turn:u-ub1"])
    #expect(try store.stillOutstanding(keys: []).isEmpty)

    // Answered on the Mac: the request is no longer pending.
    _ = try store.apply([change("runtimeRequests", "r-arl1", "update", column: "state", value: "resolved")])
    #expect(try store.stillOutstanding(keys: ["request:r-arl1"]).isEmpty)

    // Read the same turn: gone.
    _ = try store.apply([change("threads", "t-unread-a", "update", column: "readTurnId", value: "u-ua1")])
    #expect(try store.stillOutstanding(keys: ["turn:u-ua1", "turn:u-ub1"]) == ["turn:u-ub1"])

    // Read a later turn: the earlier turn's notification is gone too.
    _ = try store.apply([
      change(
        "turns", "u-ub2", "insert",
        value: try turnRow("u-ub2", thread: "t-unread-b", created: "2026-10-31T12:00:00Z")),
      change("threads", "t-unread-b", "update", column: "readTurnId", value: "u-ub2"),
    ])
    #expect(try store.stillOutstanding(keys: ["turn:u-ub1", "turn:u-ub2"]).isEmpty)

    // An earlier read leaves a later turn outstanding.
    _ = try store.apply([
      change(
        "turns", "u-ua0", "insert",
        value: try turnRow("u-ua0", thread: "t-unread-a", created: "2026-10-31T11:00:00Z")),
      change(
        "turns", "u-ua2", "insert",
        value: try turnRow("u-ua2", thread: "t-unread-a", created: "2026-10-31T13:00:00Z")),
    ])
    #expect(
      try store.stillOutstanding(keys: ["turn:u-ua0", "turn:u-ua1", "turn:u-ua2"]) == ["turn:u-ua2"])
    _ = try store.apply([change("threads", "t-unread-a", "update", column: "readTurnId", value: "u-ua0")])
    #expect(
      try store.stillOutstanding(keys: ["turn:u-ua0", "turn:u-ua1", "turn:u-ua2"])
        == ["turn:u-ua1", "turn:u-ua2"])
  }

  @Test func turnsWithTheSameCreationTimeCompareById() throws {
    let store = try AttentionFixture.load().store()
    let at = "2026-10-31T14:00:00Z"
    _ = try store.apply([
      change("turns", "u-ua-a", "insert", value: try turnRow("u-ua-a", thread: "t-unread-a", created: at)),
      change("turns", "u-ua-b", "insert", value: try turnRow("u-ua-b", thread: "t-unread-a", created: at)),
      change("threads", "t-unread-a", "update", column: "readTurnId", value: "u-ua-a"),
    ])
    #expect(try store.stillOutstanding(keys: ["turn:u-ua-a", "turn:u-ua-b"]) == ["turn:u-ua-b"])
  }

  @Test func deletedThreadIsNotOutstandingOrCounted() throws {
    let store = try AttentionFixture.load().store()
    let keys = ["request:r-arl1", "turn:u-ua1"]
    #expect(try store.stillOutstanding(keys: keys) == Set(keys))
    let before = try store.needsYouCount()
    _ = try store.apply([
      change(
        "threads", "t-ask-request-late", "update", column: "userDeletedAt", value: "2026-10-31T15:00:00Z"),
      change("threads", "t-unread-a", "update", column: "userDeletedAt", value: "2026-10-31T15:00:00Z"),
    ])
    #expect(try store.stillOutstanding(keys: keys).isEmpty)
    #expect(try store.needsYouCount() == before - 2)
  }

  @Test func archivedThreadIsNotCountedOrOutstandingForItsRequest() throws {
    let store = try AttentionFixture.load().store()
    let before = try store.needsYouCount()
    _ = try store.apply([
      change("threads", "t-ask-request-late", "update", column: "archived", value: true),
      change("threads", "t-unread-a", "update", column: "archived", value: true),
    ])
    #expect(try store.stillOutstanding(keys: ["request:r-arl1"]).isEmpty)
    #expect(try store.needsYouCount() == before - 2)
  }

  @Test func needsYouCountMatchesFixture() throws {
    let fixture = try AttentionFixture.load()
    let store = try fixture.store()
    let expected = fixture.expected.bands.values.filter { $0 == "needsInput" || $0 == "unread" }.count
    #expect(expected == 5)
    #expect(try store.needsYouCount() == expected)
    #expect(try MirrorStore.inMemory().needsYouCount() == 0)
  }
}
