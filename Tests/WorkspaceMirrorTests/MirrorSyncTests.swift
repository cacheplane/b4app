import Foundation
import Synchronization
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

/// Polls for up to 30 s (these wait on real tasks and flake under a loaded machine), then checks once
/// more after the deadline so a condition that became true during the last sleep still passes.
func eventually(
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

/// `POST /v1/changes`'s body, to measure what a push sent.
private struct Body: Encodable { var changes: [SyncChange] }

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

  @Test func resyncUsesTheSnapshot() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    var stale = try #require(try fixtureAsStored()[1].value?.objectValue)
    stale["id"] = "thread-gone"
    stale["nativeThreadId"] = "native-gone"
    _ = try store.apply([change("threads", "thread-gone", "insert", value: .object(stale))])
    try store.setCursor(500)
    let fixture = try fixtureAsStored()
    let fake = FakeHubAPI(stored: fixture)
    await fake.setSnapshot(SnapshotResponse(changes: fixture, clocks: [], next: 12))
    let hub = PrunedHub(base: fake, tip: 12)
    let recorder = BatchRecorder()
    let sync = MirrorSync(store: store, api: hub, onBatch: { await recorder.record($0) })
    let running = Task { await sync.run() }

    try await eventually("snapshot applied") { store.cursor == 12 }
    #expect(try store.thread(id: "thread-gone") == nil)
    #expect(try store.items(threadId: "thread-1").count == 4)
    #expect(hub.snapshotCalls == 1)
    try await eventually("snapshot batch") {
      await recorder.batches.contains { !$0.touchedThreadIds.isEmpty }
    }
    await sync.stop()
    await running.value
  }

  @Test func aRebuiltMirrorStartsFromTheSnapshotNotFromZero() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    let fixture = try fixtureAsStored()
    let hub = FakeHubAPI(stored: fixture)
    // The snapshot holds less than the feed, so which one was used shows in the rows.
    await hub.setSnapshot(SnapshotResponse(changes: Array(fixture.prefix(2)), clocks: [], next: 12))
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in }, startFromSnapshot: true)
    let running = Task { await sync.run() }

    try await eventually("snapshot applied") { store.cursor == 12 }
    #expect(try store.thread(id: "thread-1") != nil)
    #expect(try store.turns(threadId: "thread-1").isEmpty)
    await sync.stop()
    await running.value
  }

  @Test func outboxIsPushedThenPulledBack() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    try store.setCursor(12)
    _ = try store.updateThread(id: "thread-1", title: "From phone", pinned: true, archived: nil)
    #expect(store.outboxCount == 2)
    let hub = FakeHubAPI(stored: try fixtureAsStored())
    await hub.setPlatform("ios")
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }

    try await eventually("outbox drained") { store.outboxCount == 0 }
    // The hub echoes the phone's own changes back; they apply as no-ops and the cursor moves past them.
    try await eventually("pulled back") { store.cursor == 14 }
    let sent = await hub.pushed.flatMap { $0 }
    #expect(sent.map(\.deviceSeq) == [1, 2])
    #expect(sent.map(\.column) == ["title", "pinned"])
    let stored = await hub.stored.suffix(2)
    #expect(stored.map(\.deviceSeq) == [1, 2])
    let thread = try #require(try store.thread(id: "thread-1"))
    #expect(thread.title == "From phone" && thread.pinned)
    #expect(try store.refusedUploads == 0)
    await sync.stop()
    await running.value
  }

  @Test func theHubRefusalsAreCountedAndRemovedWithTheirBatch() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    try store.setCursor(12)
    _ = try store.updateThread(id: "thread-1", title: "From phone", pinned: nil, archived: nil)
    // `threads.projectId` is the Mac's: an ios device's update of it is refused and covered.
    try store.queueRaw(
      deviceSeq: 2, table: "threads", rowId: "thread-1", column: "projectId", value: "\"p9\"")
    let hub = FakeHubAPI(stored: try fixtureAsStored())
    await hub.setPlatform("ios")
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }

    try await eventually("outbox drained") { store.outboxCount == 0 }
    #expect(try store.refusedUploads == 1)
    let sent = await hub.pushed.flatMap { $0 }
    #expect(sent.map(\.deviceSeq) == [1, 2])
    await sync.stop()
    await running.value
  }

  @Test func offlineEditsWaitAndDrainWhenTheHubReturns() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    try store.setCursor(12)
    _ = try store.updateThread(id: "thread-1", title: "Offline edit", pinned: nil, archived: nil)
    _ = try store.saveDraft(threadId: "thread-1", text: "half a thought")
    let queued = store.outboxCount
    #expect(queued == 2)  // a title, and a new draft row

    let hub = FakeHubAPI(stored: try fixtureAsStored())
    await hub.setPlatform("ios")
    let offline = HubError(kind: "transport", code: "transport", message: "offline", status: 0)
    await hub.setFailNext(offline)
    let sync = MirrorSync(
      store: store, api: hub, onBatch: { _ in }, initialBackoff: .milliseconds(50),
      maxBackoff: .milliseconds(200))
    let running = Task { await sync.run() }

    try await eventually("first failure") { await hub.failNext == nil }
    #expect(store.outboxCount == queued)
    #expect(await hub.pushed.flatMap { $0 }.isEmpty)
    await hub.setFailNext(offline)
    try await eventually("second failure") { await hub.failNext == nil }
    try await eventually("drained") { store.outboxCount == 0 }
    #expect(await hub.pushed.flatMap { $0 }.count == queued)
    #expect(try store.link()?.lastError == nil)
    #expect(try store.thread(id: "thread-1")?.title == "Offline edit")
    await sync.stop()
    await running.value
  }

  @Test func pushesGoInBatchesOfAtMost500() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    try store.setCursor(12)
    for seq in 1...1100 {
      try store.queueRaw(
        deviceSeq: seq, table: "threads", rowId: "thread-1", column: "title", value: "\"t\(seq)\"")
    }
    let hub = FakeHubAPI(stored: try fixtureAsStored())
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }

    try await eventually("outbox drained") { store.outboxCount == 0 }
    // The first request is the empty sequence check.
    #expect(await hub.pushed.map(\.count) == [0, 500, 500, 100])
    await sync.stop()
    await running.value
  }

  @Test func aBacklogLargerThan8MiBDrainsInSeveralPushes() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    try store.setCursor(12)
    // Seven 1.5 MiB titles: 10.5 MiB, each change under the hub's 2 MiB value limit.
    let big = String(repeating: "x", count: 1_572_864)
    for seq in 1...7 {
      try store.queueRaw(
        deviceSeq: seq, table: "threads", rowId: "thread-1", column: "title", value: "\"\(seq)\(big)\"")
    }
    let hub = FakeHubAPI(stored: try fixtureAsStored())
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }

    try await eventually("outbox drained") { store.outboxCount == 0 }
    let pushed = await hub.pushed
    // The first request is the empty sequence check; then five changes (7.5 MiB) and two.
    #expect(pushed.map(\.count) == [0, 5, 2])
    for batch in pushed {
      let body = try JSONCoding.encoder.encode(Body(changes: batch))
      #expect(body.count <= MirrorSync.pushBytes)
    }
    #expect(pushed.flatMap { $0 }.map(\.deviceSeq) == Array(1...7))
    await sync.stop()
    await running.value
  }

  @Test func aPushAlwaysCarriesAtLeastOneChange() throws {
    let change = SyncChange(
      deviceSeq: 1, wall: 1, table: "threads", rowId: "t", op: "update", column: "title", value: "long",
      hlc: macClock.next().rawValue)
    var second = change
    second.deviceSeq = 2
    #expect(MirrorStore.uploadPrefix([change, second], rows: 500, bytes: 1).map(\.deviceSeq) == [1])
    #expect(MirrorStore.uploadPrefix([change, second], rows: 1, bytes: .max).map(\.deviceSeq) == [1])
    #expect(MirrorStore.uploadPrefix([change, second], rows: 500, bytes: .max).count == 2)
    #expect(MirrorStore.uploadPrefix([], rows: 500, bytes: 1).isEmpty)
  }

  @Test func theRefusedCountSurvivesReopeningTheFile() throws {
    let path = NSTemporaryDirectory() + "mirror-\(UUID().uuidString.prefix(8)).sqlite"
    defer { MirrorStoreTests.remove(path) }
    do {
      let store = try MirrorStore(path: path)
      try store.queueRaw(deviceSeq: 1, table: "threads", rowId: "t", column: "title", value: "\"x\"")
      try store.completeUpload(through: 1, refused: 2)
      #expect(store.outboxCount == 0)
      #expect(try store.refusedUploads == 2)
    }
    let reopened = try MirrorStore(path: path)
    #expect(try reopened.refusedUploads == 2)
    #expect(try reopened.lastDeviceSeq == 1)
  }

  @Test func theSequenceCounterIsRaisedToTheHubsRecordBeforeAnyPush() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    let hub = FakeHubAPI()
    await hub.setPlatform("ios")
    // The hub has recorded sequence 40 for this device (a restored backup lost the phone's counter).
    _ = try await hub.push([
      SyncChange(
        deviceSeq: 40, wall: 1, table: "drafts", rowId: "x", op: "insert", column: nil, value: nil,
        hlc: macClock.next().rawValue)
    ])
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }

    try await eventually("counter raised") { try store.lastDeviceSeq == 40 }
    await sync.stop()
    await running.value
  }

  @Test func aNudgeWakesALongPollSoALocalWriteGoesOutAtOnce() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(link)
    _ = try store.apply(try fixtureAsStored())
    try store.setCursor(12)
    let hub = FakeHubAPI(stored: try fixtureAsStored())
    await hub.setPlatform("ios")
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }
    try await Task.sleep(for: .milliseconds(200))  // the loop is parked in its 25 s long poll

    _ = try store.updateThread(id: "thread-1", title: "Nudged", pinned: nil, archived: nil)
    await sync.nudge()
    try await eventually("pushed without waiting out the poll", timeout: .seconds(5)) {
      store.outboxCount == 0
    }
    #expect(await hub.stored.last?.value == "Nudged")
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

/// A hub that has pruned its feed: it answers `resync_required` to a pull from past its `tip`, and
/// counts the snapshots asked for. Everything else is the fake's.
final class PrunedHub: HubAPI {
  let base: FakeHubAPI
  let tip: Int
  private let snapshots = Mutex(0)
  var snapshotCalls: Int { snapshots.withLock { $0 } }

  init(base: FakeHubAPI, tip: Int) {
    self.base = base
    self.tip = tip
  }

  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try await base.enroll(request) }
  func me() async throws -> MeResponse { try await base.me() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try await base.push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    if after > tip {
      throw HubError(kind: "request_error", code: "resync_required", message: "Start over.", status: 410)
    }
    return try await base.pull(after: after, limit: limit, wait: wait)
  }
  func snapshot() async throws -> SnapshotResponse {
    snapshots.withLock { $0 += 1 }
    return try await base.snapshot()
  }
  func devices() async throws -> [DeviceInfo] { try await base.devices() }
  func revokeSelf() async throws { try await base.revokeSelf() }
}

extension MirrorStore {
  /// Puts an edit in the outbox as an older build or a hand-edited file might have left it.
  func queueRaw(deviceSeq: Int, table: String, rowId: String, column: String, value: String) throws {
    try locked {
      try run(
        #"INSERT INTO "outbox" ("deviceSeq", "hlc", "table", "rowId", "op", "column", "value") VALUES (?, ?, ?, ?, 'update', ?, ?)"#,
        [
          .integer(Int64(deviceSeq)), .text(clock.next().rawValue), .text(table), .text(rowId), .text(column),
          .text(value),
        ])
      try run(#"UPDATE "syncState" SET "lastDeviceSeq" = ? WHERE "id" = 1"#, [.integer(Int64(deviceSeq))])
    }
  }
}
