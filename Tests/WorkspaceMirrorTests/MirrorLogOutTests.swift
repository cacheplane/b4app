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

  @Test func logOutRevokesForgetsTheTokenAndEmptiesTheMirror() async throws {
    let store = try populated()
    #expect(try store.outbox(limit: 10).count == 1)
    let fake = FakeHubAPI()
    let forgotten = Mutex(false)
    let revoked = await MirrorLogOut.run(store: store, api: fake) { forgotten.withLock { $0 = true } }
    #expect(revoked)
    #expect(await fake.revoked)
    #expect(forgotten.withLock { $0 })
    try expectEmptied(store)
  }

  @Test func logOutStillUnlinksWhenTheRevokeFails() async throws {
    let store = try populated()
    let fake = FakeHubAPI()
    await fake.setFailNext(HubError(kind: "transport", code: "unreachable", message: "offline", status: 0))
    let forgotten = Mutex(false)
    let revoked = await MirrorLogOut.run(store: store, api: fake) { forgotten.withLock { $0 = true } }
    #expect(!revoked)
    #expect(await fake.revoked == false)
    #expect(forgotten.withLock { $0 })
    try expectEmptied(store)
  }
}
