import Foundation
import Synchronization
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let refreshLink = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Test Phone",
  tokenRef: "secret:test", orgSlug: "o", username: "u")

/// Splits a feed after its first row, as the hub's byte cap can do even below the row limit.
/// The following page has network latency so first-batch completion cannot accidentally drain it.
private final class SplitRefreshHub: HubAPI {
  let base: FakeHubAPI
  let waits = Mutex<[(after: Int, wait: Int)]>([])
  let firstResponseGate: Gate?
  let signal = SyncSignal()
  let captured = Mutex(false)
  let cancelled = Mutex(false)
  init(_ changes: [StoredChange], firstResponseGate: Gate? = nil) {
    base = FakeHubAPI(stored: changes)
    self.firstResponseGate = firstResponseGate
  }
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try await base.enroll(request) }
  func me() async throws -> MeResponse { try await base.me() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try await base.push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    waits.withLock { $0.append((after, wait)) }
    let isFirst = waits.withLock { $0.count == 1 }
    if isFirst, let firstResponseGate {
      // A response already won the network race: cancellation is observed but cannot retract it.
      let page = try await base.pull(after: after, limit: limit, wait: 0)
      captured.withLock { $0 = true }
      signal.fire()
      await withTaskCancellationHandler {
        await firstResponseGate.wait()
      } onCancel: {
        self.cancelled.withLock { $0 = true }
        self.signal.fire()
      }
      return page
    }
    if after > 0 { try await Task.sleep(for: .milliseconds(50)) }
    return try await base.pull(after: after, limit: after == 0 ? 1 : limit, wait: wait)
  }
  func snapshot() async throws -> SnapshotResponse { try await base.snapshot() }
  func devices() async throws -> [DeviceInfo] { try await base.devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { try await base.mintPairingCode() }
  func revokeSelf() async throws { try await base.revokeSelf() }
}

@Suite struct MirrorSyncRefreshTests {
  @Test func backgroundCatchUpIncludesANewThreadBeyondTheFirstPageBeforeParking() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-\(UUID()).sqlite").path
    defer {
      for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    let store = try MirrorStore(path: path)
    try store.saveLink(refreshLink)
    let hub = SplitRefreshHub(try fixtureAsStored())
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in }, startSuspended: true)
    let running = Task { await sync.run() }
    await sync.resume()
    let caughtUp = await sync.refresh(waitingAtMost: .seconds(120))
    await sync.suspend()
    // Read through the widget's real read-only connection, after the wake has parked the writer.
    let glance = MirrorGlance.load(path: path)
    #expect(caughtUp)
    #expect(store.cursor == 15)
    #expect(glance.rows.map(\.threadId) == ["thread-1"])
    #expect(glance.rows.first?.state == .approve)
    #expect(hub.waits.withLock { $0.filter { $0.after == 1 }.allSatisfy { $0.wait == 0 } })
    await sync.stop()
    await running.value
  }

  @Test func anEmptyFeedCompletesWithoutWaitingForALongPollOrABatch() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(refreshLink)
    let signal = SyncSignal()
    let hub = ProbedHub(FakeHubAPI(), signal)
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in }, startSuspended: true)
    let running = Task { await sync.run() }
    // Coordinate registration explicitly. Full-suite UI rendering can occupy the executor for
    // seconds; assert the requested poll mode rather than imposing a subsecond performance limit.
    let refresh = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    let deadline = ContinuousClock.now + .seconds(120)
    while await sync.refreshGeneration == 0, ContinuousClock.now < deadline { await Task.yield() }
    try #require(await sync.refreshGeneration == 1)
    await sync.resume()
    #expect(await refresh.value)
    #expect(hub.pullWaits.first == 0)
    await sync.stop()
    await running.value
  }

  @Test func anOlderResponseCannotCompleteARefreshThatStartedAfterItsRead() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(refreshLink)
    let release = Gate()
    defer { release.open() }
    let hub = SplitRefreshHub([], firstResponseGate: release)
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }
    try await hub.signal.until("old empty response captured") { hub.captured.withLock { $0 } }
    await hub.base.append(try fixtureAsStored())
    let refresh = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    try await hub.signal.until("refresh cancelled the older pull") { hub.cancelled.withLock { $0 } }
    release.open()
    #expect(await refresh.value)
    await sync.suspend()
    #expect(store.cursor == 15)
    #expect(try MirrorGlance.load(store: store).rows.first?.state == .approve)
    await sync.stop()
    await running.value
  }

  @Test func snapshotRecoveryStillPullsToTheEndBeforeCompleting() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(refreshLink)
    let fixture = try fixtureAsStored()
    let hub = FakeHubAPI(stored: fixture)
    await hub.setSnapshot(SnapshotResponse(changes: Array(fixture.prefix(1)), clocks: [], next: 1))
    let sync = MirrorSync(
      store: store, api: hub, onBatch: { _ in }, startFromSnapshot: true, startSuspended: true)
    let running = Task { await sync.run() }
    let refresh = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    await sync.resume()
    #expect(await refresh.value)
    await sync.suspend()
    #expect(store.cursor == 15)
    #expect(try MirrorGlance.load(store: store).rows.first?.state == .approve)
    await sync.stop()
    await running.value
  }

  @Test func cancellingOneOverlappingRefreshDoesNotCancelTheOther() async throws {
    let store = try MirrorStore.inMemory()
    try store.saveLink(refreshLink)
    let release = Gate()
    defer { release.open() }
    let hub = SplitRefreshHub([], firstResponseGate: release)
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }
    try await hub.signal.until("old response captured") { hub.captured.withLock { $0 } }
    let first = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    try await hub.signal.until("first refresh registered") { hub.cancelled.withLock { $0 } }
    let second = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    first.cancel()
    #expect(await first.value == false)
    await hub.base.append(try fixtureAsStored())
    release.open()
    #expect(await second.value)
    #expect(store.cursor == 15)
    await sync.stop()
    await running.value
  }

  @Test func aTimedOutRefreshDoesNotClaimCatchUpAndCanBeRetried() async throws {
    let store = try MirrorStore.inMemory()
    let sync = MirrorSync(store: store, api: FakeHubAPI(), onBatch: { _ in }, startSuspended: true)
    let running = Task { await sync.run() }
    #expect(await sync.refresh(waitingAtMost: .milliseconds(20)) == false)
    let retry = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    await sync.resume()
    #expect(await retry.value)
    await sync.stop()
    await running.value
  }

  @Test func stoppingReleasesPendingRefreshesAndRefusesNewOnes() async throws {
    let store = try MirrorStore.inMemory()
    let release = Gate()
    defer { release.open() }
    let hub = SplitRefreshHub([], firstResponseGate: release)
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in })
    let running = Task { await sync.run() }
    try await hub.signal.until("old response captured") { hub.captured.withLock { $0 } }
    let refresh = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    try await hub.signal.until("refresh registered") { hub.cancelled.withLock { $0 } }
    await sync.stop()
    #expect(await refresh.value == false)
    #expect(await sync.refresh(waitingAtMost: .seconds(120)) == false)
    release.open()
    await running.value
  }

  @Test func authorizationFailureReleasesRefreshWithoutWaitingForItsTimeout() async throws {
    let store = try MirrorStore.inMemory()
    let hub = FakeHubAPI()
    try await hub.revokeSelf()
    let sync = MirrorSync(store: store, api: hub, onBatch: { _ in }, startSuspended: true)
    let running = Task { await sync.run() }
    let refresh = Task { await sync.refresh(waitingAtMost: .seconds(120)) }
    await sync.resume()
    #expect(await refresh.value == false)
    await running.value
  }

}
