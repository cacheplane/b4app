import Foundation
import Synchronization
import Testing
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceMirror

private let link = MirrorLink(
  hubURL: "http://localhost:8080", deviceId: "phone-1", deviceName: "Brian's iPhone",
  tokenRef: "secret:hub-token", orgSlug: "cacheplane", username: "blove")

/// A linked mirror with rows, an unsent edit in the outbox, and a devices list.
private func populated() throws -> MirrorStore {
  let store = try MirrorStore.inMemory()
  try store.saveLink(link)
  _ = try store.apply(Array(try fixtureAsStored().prefix(4)))
  _ = try store.updateThread(id: "thread-1", title: "Unsent phone title", pinned: nil, archived: nil)
  try store.saveDevices([DeviceInfo(id: "mac-1", name: "Mac", platform: "macos")])
  return store
}

@Suite struct MirrorLogOutTests {
  private func expectEmptied(_ store: MirrorStore) throws {
    #expect(try store.link() == nil)
    #expect(try store.thread(id: "thread-1") == nil)
    // Nothing of the account stays: an unsent edit must not upload under a later link.
    #expect(try store.outbox(limit: 10).isEmpty)
    #expect(try store.devices().isEmpty)
  }

  /// Task 14: log-out ends the session at the hub and keeps the device (`DELETE /v1/sessions/self`),
  /// so signing back in reuses it.
  @Test func logOutEndsTheSessionForgetsTheTokenAndEmptiesTheMirror() async throws {
    let store = try populated()
    #expect(try store.outbox(limit: 10).count == 1)
    let fake = FakeHubAPI()
    let forgotten = Mutex(false)
    let ended = await MirrorLogOut.run(store: store, api: fake) { forgotten.withLock { $0 = true } }
    #expect(ended)
    #expect(await fake.endSessionCalls == 1)
    #expect(forgotten.withLock { $0 })
    try expectEmptied(store)
  }

  @Test func logOutStillUnlinksWhenTheHubIsDown() async throws {
    let store = try populated()
    let fake = FakeHubAPI()
    await fake.setFailNext(HubError(kind: "transport", code: "unreachable", message: "offline", status: 0))
    let forgotten = Mutex(false)
    let ended = await MirrorLogOut.run(store: store, api: fake) { forgotten.withLock { $0 = true } }
    #expect(!ended)
    #expect(await fake.endSessionCalls == 0)
    #expect(forgotten.withLock { $0 })
    try expectEmptied(store)
  }

  @Test func logOutWaitsForTheHubOnlySoLong() async throws {
    let store = try populated()
    let forgotten = Mutex(false)
    let started = ContinuousClock.now
    let ended = await MirrorLogOut.run(store: store, api: SilentHub(), timeout: .milliseconds(100)) {
      forgotten.withLock { $0 = true }
    }
    // The hub would answer only after a minute; the log-out is long done (generous for a loaded run).
    #expect(ContinuousClock.now - started < .seconds(30))
    #expect(!ended)
    #expect(forgotten.withLock { $0 })
    try expectEmptied(store)
  }

  @Test func theStandardWaitIsTenSeconds() {
    #expect(MirrorLogOut.standardTimeout == .seconds(10))
  }
}

/// A hub whose `endSession` never answers, cancelled or not.
private struct SilentHub: HubAPI {
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { throw CancellationError() }
  func me() async throws -> MeResponse { throw CancellationError() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { throw CancellationError() }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse { throw CancellationError() }
  func snapshot() async throws -> SnapshotResponse { throw CancellationError() }
  func devices() async throws -> [DeviceInfo] { [] }
  func mintPairingCode() async throws -> PairingCodeResponse { throw CancellationError() }
  func revokeSelf() async throws {}
  func endSession() async throws {
    // Answers only after a while, whether or not the call was cancelled.
    await withCheckedContinuation { (answer: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().asyncAfter(deadline: .now() + 60) { answer.resume() }
    }
  }
}
