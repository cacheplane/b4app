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

/// Retains native operation handles and acknowledges the actual API result, not kernel thread exit.
private final class VisibilityNativeWork<Value: Sendable>: @unchecked Sendable {
  private struct Storage {
    var result: Result<Value, any Error>?
    var continuation: CheckedContinuation<Result<Value, any Error>, Never>?
  }
  private final class State: Sendable {
    let storage = Mutex(Storage())
    let completed = DispatchSemaphore(value: 0)
  }
  private let state: State
  private let thread: Thread

  init(_ operation: @escaping @Sendable () throws -> Value) {
    let state = State()
    self.state = state
    thread = Thread {
      let result = Result(catching: operation)
      let continuation = state.storage.withLock {
        $0.result = result
        let continuation = $0.continuation
        $0.continuation = nil
        return continuation
      }
      state.completed.signal()
      continuation?.resume(returning: result)
    }
    thread.start()
  }

  func outcome() -> Result<Value, any Error> {
    state.completed.wait()
    defer { state.completed.signal() }
    return state.storage.withLock { $0.result! }
  }

  func value() async -> Result<Value, any Error> {
    await withCheckedContinuation { continuation in
      let result: Result<Value, any Error>? = state.storage.withLock {
        if let result = $0.result { return result }
        $0.continuation = continuation
        return nil
      }
      if let result { continuation.resume(returning: result) }
    }
  }
}

private struct VisibilityFacts: Sendable {
  var ready = false
  var deletionIssued = false
  var publisherReleaseSucceeded: Bool?
  var blocked: Bool?
  var beforeDeletion: Bool?
  var publication: Result<Bool, any Error>?
  var deletion: Result<Void, any Error>?
  var published: Bool?
  var afterDeletion: Bool?
  var finalRefused: Bool?
  var finalCallbackCount = 0
  var primaryError: (any Error)?
}

/// Only this native controller advances lease release and operation acknowledgments. Its workers
/// record facts only; all Testing evaluations belong to the suspended owning test Task.
private func visibilityObservation(_ database: WorkspaceDatabase, remote: Bool) -> VisibilityFacts {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let deletionIssued = DispatchSemaphore(value: 0)
  let publisherWait = Mutex<Bool?>(nil)
  let publication = VisibilityNativeWork {
    try database.withVisibleThread(id: "t") {
      entered.signal()
      let succeeded = release.wait(timeout: .now() + 120) == .success
      publisherWait.withLock { $0 = succeeded }
    }
  }
  var deletion: VisibilityNativeWork<Void>?
  var facts = VisibilityFacts()
  let finalCallbacks = Mutex(0)
  do {
    facts.ready = entered.wait(timeout: .now() + 60) == .success
    guard facts.ready else {
      throw WorkspaceError(.internalError, "publisher did not acquire visibility lease")
    }
    deletion = VisibilityNativeWork {
      if remote {
        let change = RemoteChange(
          deviceId: "phone",
          hlc: HLC(millis: epochMillis() + 60_000, counter: 0, deviceId: "phone").rawValue,
          table: "threads", rowId: "t", op: "update", column: "userDeletedAt",
          value: .string(Timestamp.now()))
        deletionIssued.signal()
        _ = try database.applyRemote([change], ownDeviceId: "mac", macDeviceIds: ["mac"], cursor: 1)
      } else {
        deletionIssued.signal()
        _ = try database.markThreadDeleted(id: "t", at: Timestamp.now())
      }
    }
    let statement = remote ? "pg_advisory_xact_lock(" : #"UPDATE "threads" SET "userDeletedAt""#
    let deadline = ContinuousClock.now + .seconds(60)
    // Worker-entry acknowledgment consumes the same observation window as the SQL below.
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let nanoseconds = max(0, remaining.seconds * 1_000_000_000 + remaining.attoseconds / 1_000_000_000)
    facts.deletionIssued = deletionIssued.wait(timeout: .now() + .nanoseconds(Int(nanoseconds))) == .success
    var blocked = false
    while facts.deletionIssued, !blocked, ContinuousClock.now < deadline {
      blocked = try database.read {
        try !$0.execute(
          "SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE $1",
          ["%" + statement + "%"]
        ).rows.isEmpty
      }
      if !blocked { Thread.sleep(forTimeInterval: 0.01) }
    }
    facts.blocked = blocked
    facts.beforeDeletion = try database.thread(id: "t")?.userDeletedAt == nil
    release.signal()
    let publicationResult = publication.outcome()
    facts.publication = publicationResult
    facts.published = try publicationResult.get()
    if let deletion {
      let deletionResult = deletion.outcome()
      facts.deletion = deletionResult
      try deletionResult.get()
    }
    facts.afterDeletion = try database.thread(id: "t")?.userDeletedAt != nil
    facts.finalRefused = try !database.withVisibleThread(id: "t") { finalCallbacks.withLock { $0 += 1 } }
  } catch {
    facts.primaryError = error
  }
  // Every path releases and acknowledges ALL started operations before returning to the test.
  release.signal()
  facts.publication = publication.outcome()
  if let deletion { facts.deletion = deletion.outcome() }
  facts.publisherReleaseSucceeded = publisherWait.withLock { $0 }
  facts.finalCallbackCount = finalCallbacks.withLock { $0 }
  return facts
}

@Suite(NativeDBResources()) struct ThreadEventVisibilityTests {
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
    let controller = VisibilityNativeWork { visibilityObservation(database, remote: remote) }
    let facts = try await controller.value().get()
    withExtendedLifetime(controller) {}
    if let succeeded = facts.publisherReleaseSucceeded { #expect(succeeded) }
    if let blocked = facts.blocked {
      #expect(blocked, "the actual local/pulled deletion must wait for the publisher's lease")
    }
    if let before = facts.beforeDeletion { #expect(before) }
    if let published = facts.published { #expect(published) }
    if let after = facts.afterDeletion { #expect(after) }
    if facts.finalCallbackCount > 0 { Issue.record("deleted thread published") }
    if let refused = facts.finalRefused { #expect(refused) }
    if let error = facts.primaryError { throw error }
  }
}
