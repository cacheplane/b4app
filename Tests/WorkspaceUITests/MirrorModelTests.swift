import Foundation
import Testing
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceUI

/// The shared wire fixture as the hub serves it (`hubSeq = index + 1`, from `mac-1`), read in place.
private func fixtureAsStored(file: StaticString = #filePath) throws -> [StoredChange] {
  let url = URL(fileURLWithPath: "\(file)")
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/sync/changes.json")
  let wire = try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
  return wire.enumerated().map { index, change in
    StoredChange(
      hubSeq: index + 1, deviceId: "mac-1", deviceSeq: change.deviceSeq, wall: change.wall,
      table: change.table, rowId: change.rowId, op: change.op, column: change.column, value: change.value)
  }
}

/// The real `WorkspaceModel` over a `MirrorTransport`: no coordinator, no socket.
@Suite(.serialized) @MainActor struct MirrorModelTests {
  @Test func modelShowsMirroredThreadsAndLiveItems() async throws {
    let store = try MirrorStore.inMemory()
    let transport = MirrorTransport(store: store, version: "0.2.0")
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try await waitUntil("ready") { model.link == .ready }
    let fixture = try fixtureAsStored()

    transport.publish(try store.apply(Array(fixture.prefix(2))))  // connection + thread
    try await waitUntil("thread listed") { model.threads.count == 1 }
    try await waitUntil("connection listed") { model.connections.count == 1 }

    await model.openThread(id: "thread-1")
    try await waitUntil("detail") { model.detail != nil }
    #expect(model.detail?.items.isEmpty == true)

    transport.publish(try store.apply(Array(fixture[2..<8])))  // turns + items
    try await waitUntil("items") { model.detail?.items.count == 4 }
    #expect(model.detail?.items.map(\.id) == ["item-1", "item-2", "item-3", "item-4"])

    transport.publish(try store.apply([fixture[9]]))  // the title update
    try await waitUntil("renamed") { model.threads.first?.title == "Renamed" }
    #expect(model.detail?.thread.title == "Renamed")
    #expect(model.connections.first?.target == "")
    #expect(model.connections.first?.authReference == nil)

    await model.refreshDiagnostics()
    #expect(model.diagnostics?.coordinator.socketPath == "mirror")
    await model.disconnect()
  }
}
