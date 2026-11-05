import Foundation
import Synchronization
import Testing
import WorkspaceProtocol

@testable import WorkspaceStorage

private func visibilityDatabase() throws -> WorkspaceDatabase {
  let database = try WorkspaceDatabase.temporary()
  _ = try database.insertConnection(Connection(id: "c", kind: .b4, label: "c", target: "http://localhost"))
  _ = try database.insertThread(
    ConversationThread(id: "t", connectionId: "c", nativeThreadId: "native", title: "t", context: "/tmp"))
  return database
}

private func waitForPublisher(_ stream: AsyncStream<Void>) async throws {
  try await withThrowingTaskGroup(of: Bool.self) { group in
    group.addTask {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    group.addTask {
      try await Task.sleep(for: .seconds(60))
      return false
    }
    let ready = try await group.next() == true
    group.cancelAll()
    guard ready else { throw WorkspaceError(.internalError, "publisher did not acquire visibility lease") }
  }
}

/// The callback deliberately blocks while holding the lease; keep that wait off Swift's
/// cooperative executor, particularly on the small hosted runner.
private func onDedicatedThread<T: Sendable>(
  _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
  try await withCheckedThrowingContinuation { continuation in
    Thread {
      do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
    }.start()
  }
}

@Suite struct ThreadEventVisibilityTests {
  @Test func deletedAndMissingThreadsCannotPublish() throws {
    let database = try visibilityDatabase()
    defer { try? database.close() }
    let count = Mutex(0)
    let before = try database.changes(after: 0).count
    #expect(try database.withVisibleThread(id: "t") { count.withLock { $0 += 1 } })
    #expect(try database.changes(after: 0).count == before)
    _ = try database.markThreadDeleted(id: "t", at: Timestamp.now())
    #expect(try !database.withVisibleThread(id: "t") { count.withLock { $0 += 1 } })
    #expect(try !database.withVisibleThread(id: "missing") { count.withLock { $0 += 1 } })
    try database.close()
    do {
      _ = try database.withVisibleThread(id: "t") { count.withLock { $0 += 1 } }
      Issue.record("closed storage must reject publication")
    } catch {}
    #expect(count.withLock { $0 } == 1)
  }

  @Test(arguments: [false, true])
  func publicationFinishesBeforeConcurrentDeletion(remote: Bool) async throws {
    let database = try visibilityDatabase()
    defer { try? database.close() }
    let (ready, entered) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { entered.finish(); release.signal() }
    let publication = Task {
      try await onDedicatedThread {
        try database.withVisibleThread(id: "t") {
          entered.yield()
          #expect(release.wait(timeout: .now() + 120) == .success)
        }
      }
    }
    var deletion: Task<Void, any Error>?
    do {
      try await waitForPublisher(ready)
      deletion = Task {
        try await onDedicatedThread {
          if remote {
            let change = RemoteChange(
              deviceId: "phone",
              hlc: HLC(millis: epochMillis() + 60_000, counter: 0, deviceId: "phone").rawValue,
              table: "threads", rowId: "t", op: "update", column: "userDeletedAt",
              value: .string(Timestamp.now()))
            _ = try database.applyRemote([change], ownDeviceId: "mac", macDeviceIds: ["mac"], cursor: 1)
          } else {
            _ = try database.markThreadDeleted(id: "t", at: Timestamp.now())
          }
        }
      }
      let statement = remote ? "pg_advisory_xact_lock(" : #"UPDATE "threads" SET "userDeletedAt""#
      let deadline = ContinuousClock.now + .seconds(60)
      var blocked = false
      while !blocked, ContinuousClock.now < deadline {
        blocked = try database.read {
          try !$0.execute(
            "SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE $1",
            ["%" + statement + "%"]
          ).rows.isEmpty
        }
        if !blocked { try await Task.sleep(for: .milliseconds(10)) }
      }
      #expect(blocked, "the actual local/pulled deletion must wait for the publisher's lease")
      #expect(try database.thread(id: "t")?.userDeletedAt == nil)
      release.signal()
      #expect(try await publication.value)
      try await deletion?.value
      #expect(try database.thread(id: "t")?.userDeletedAt != nil)
      #expect(try !database.withVisibleThread(id: "t") { Issue.record("deleted thread published") })
    } catch {
      release.signal()
      _ = try? await publication.value
      try? await deletion?.value
      throw error
    }
  }
}
