import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let deleteLink = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Test Phone", tokenRef: "secret:t",
  orgSlug: "o", username: "u")

@Suite(.timeLimit(.minutes(1))) struct MirrorDeleteTests {
  @Test func deletingOnThePhoneHidesTheThreadAndQueuesTheMark() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(deleteLink)
    _ = try store.apply(try fixtureAsStored())
    let transport = MirrorTransport(store: store, version: "0.2.0", onLocalWrite: {})
    let client = WorkspaceClient(transport: transport)
    _ = try await client.ready()
    let events = await client.events()

    let deleted = try await client.request(
      ThreadDelete.self, .init(threadId: "thread-1"), options: RequestOptions(operationId: "op-1")
    ).thread
    let stamp = try #require(deleted.userDeletedAt)
    #expect(try await client.request(ThreadList.self, .init(includeArchived: true)).threads.isEmpty)
    let unread = await #expect(throws: WorkspaceError.self) {
      try await client.request(ThreadRead.self, .init(threadId: "thread-1"))
    }
    #expect(unread?.code == .notFound)

    let queued = try store.outbox(limit: 10)
    #expect(queued.count == 1)
    #expect(queued.first?.table == "threads" && queued.first?.rowId == "thread-1")
    #expect(queued.first?.op == "update" && queued.first?.column == "userDeletedAt")
    #expect(queued.first?.value == .string(stamp))

    // Deleting it again keeps the first time and queues nothing more.
    let again = try await client.request(
      ThreadDelete.self, .init(threadId: "thread-1"), options: RequestOptions(operationId: "op-2")
    ).thread
    #expect(again.userDeletedAt == stamp)
    #expect(store.outboxCount == 1)

    for await envelope in events where envelope.event.kind == .threadUpdated {
      #expect(envelope.event.payload["thread"]?["userDeletedAt"]?.stringValue == stamp)
      break
    }
    await client.close()
  }

  @Test func aDeletePulledFromTheMacHidesItToo() throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    _ = try store.apply([
      change("threads", "thread-1", "update", column: "userDeletedAt", value: "2026-11-02T12:00:00.000Z")
    ])
    #expect(try store.threads(includeArchived: true, connectionId: nil, query: nil).isEmpty)
    #expect(try store.thread(id: "thread-1")?.userDeletedAt == "2026-11-02T12:00:00.000Z")
  }
}
