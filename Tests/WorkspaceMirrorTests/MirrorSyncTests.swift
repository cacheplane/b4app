import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

/// Collects what `MirrorSync` hands to `onBatch`.
actor BatchRecorder {
  private(set) var batches: [AppliedBatch] = []
  func record(_ batch: AppliedBatch) { batches.append(batch) }
}

/// Collects what `MirrorSync` hands to `onStatus`.
actor StatusRecorder {
  private(set) var all: [MirrorSyncStatus] = []
  func record(_ status: MirrorSyncStatus) { all.append(status) }
}

/// The deadline is generous and the condition is checked once more after it passes, because a CI
/// runner can stall every test for longer than the old 10 s (seen on main, 2026-11-01).
private func eventually(
  _ what: String, timeout: Duration = .seconds(30), _ condition: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  if try await condition() { return }
  throw WorkspaceError(.internalError, "timed out waiting for \(what)")
}

private let link = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Test Phone", tokenRef: "secret:t",
  orgSlug: "o", username: "u")

@Suite struct MirrorSyncTests {
  @Test func pullsAppliesAdvancesTheCursorAndReportsEachBatch() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    let hub = FakeHubAPI(stored: Array(try fixtureAsStored().prefix(8)))
    let recorder = BatchRecorder()
    let sync = MirrorSync(store: store, api: hub, onBatch: { await recorder.record($0) })
    let running = Task { await sync.run() }

    try await eventually("first page") { store.cursor == 8 }
    #expect(try store.items(threadId: "thread-1").count == 4)
    await hub.append(Array(try fixtureAsStored()[8...]))
    try await eventually("second page") { store.cursor == 12 }
    #expect(try store.thread(id: "thread-1")?.title == "Renamed")
    try await eventually("batches") { await recorder.batches.count >= 2 }
    let batches = await recorder.batches
    #expect(batches.first?.touchedThreadIds == ["thread-1"])
    #expect(batches.first?.touchedItems.count == 4)
    #expect(batches.allSatisfy { $0.skipped == 0 && $0.undecodableRows == 0 })
    #expect(try store.link()?.lastSyncAt != nil)
    #expect(try store.link()?.lastError == nil)

    await sync.stop()
    await running.value
  }

  @Test func resyncRequiredClearsTheMirrorAndStartsFromZero() async throws {
    let store = try MirrorStore.inMemory()
    _ = try store.apply(try fixtureAsStored())
    var stale = try #require(try fixtureAsStored()[1].value?.objectValue)
    stale["id"] = "thread-gone"
    stale["nativeThreadId"] = "native-gone"
    _ = try store.apply([change("threads", "thread-gone", "insert", value: .object(stale))])
    try store.setCursor(500)
    let hub = FakeHubAPI(stored: try fixtureAsStored())
    await hub.setFailNext(
      HubError(kind: "request_error", code: "resync_required", message: "Start over.", status: 410))
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }

    try await eventually("re-pulled") { store.cursor == 12 }
    #expect(try store.thread(id: "thread-gone") == nil)
    #expect(try store.items(threadId: "thread-1").count == 4)
    await sync.stop()
    await running.value
  }

  @Test func failuresAreRecordedAndRetriedWithBackoff() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    let hub = FakeHubAPI(stored: Array(try fixtureAsStored().prefix(2)))
    await hub.setFailNext(HubError(kind: "transport", code: "transport", message: "offline", status: 0))
    let sync = MirrorSync(
      store: store, api: hub, onBatch: { _ in }, initialBackoff: .milliseconds(300), maxBackoff: .seconds(1))
    let running = Task { await sync.run() }

    try await eventually("error recorded") { try store.link()?.lastError != nil }
    #expect(try store.link()?.lastError?.contains("offline") == true)
    #expect(store.cursor == 0)
    #expect(await sync.lastError?.contains("offline") == true)
    try await eventually("recovered") { store.cursor == 2 }
    #expect(try store.link()?.lastError == nil)
    #expect(await sync.lastError == nil)
    await sync.stop()
    await running.value
  }

  @Test func statusCallbackReportsAFailureAndClearsItOnSuccess() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    let hub = FakeHubAPI(stored: Array(try fixtureAsStored().prefix(2)))
    await hub.setFailNext(HubError(kind: "transport", code: "transport", message: "offline", status: 0))
    let statuses = StatusRecorder()
    let sync = MirrorSync(
      store: store, api: hub, onBatch: { _ in }, onStatus: { await statuses.record($0) },
      initialBackoff: .milliseconds(300), maxBackoff: .seconds(1))
    let running = Task { await sync.run() }

    try await eventually("failure reported") { await statuses.all.first != nil }
    let failure = try #require(await statuses.all.first)
    #expect(failure.lastError?.contains("offline") == true)
    #expect(failure.lastSyncAt == nil)
    try await eventually("success reported") { await statuses.all.contains { $0.lastError == nil } }
    let success = try #require(await statuses.all.first { $0.lastError == nil })
    #expect(success.lastSyncAt != nil)
    #expect(await sync.lastSyncAt != nil)
    await sync.stop()
    await running.value
  }

  @Test func stopEndsALongPoll() async throws {
    let store = try MirrorStore.inMemory()
    let sync = MirrorSync(store: store, api: FakeHubAPI(), onBatch: { _ in })
    let running = Task { await sync.run() }
    try await Task.sleep(for: .milliseconds(100))
    let started = ContinuousClock.now
    await sync.stop()
    await running.value
    #expect(ContinuousClock.now - started < .seconds(5))
  }
}
