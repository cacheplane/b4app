import Foundation
import Testing
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceUI

/// A notification tap or a widget row asks the model to open a thread (M8f), possibly before it has
/// connected on a cold launch.
@Suite(.serialized) @MainActor struct ThreadOpenRequestTests {
  /// The shared wire fixture's connection and thread (`thread-1`), as the hub serves them.
  private func mirroredTransport() throws -> MirrorTransport {
    let url = URL(fileURLWithPath: "\(#filePath)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/changes.json")
    let wire = try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
    let stored = wire.prefix(2).enumerated().map { index, change in
      StoredChange(
        hubSeq: index + 1, deviceId: "mac-1", deviceSeq: change.deviceSeq, wall: change.wall,
        table: change.table, rowId: change.rowId, op: change.op, column: change.column, value: change.value)
    }
    let store = try MirrorStore.inMemory()
    _ = try store.apply(stored)
    return MirrorTransport(store: store, version: "0.2.0")
  }

  @Test func requested_thread_opens_after_connect() async throws {
    let transport = try mirroredTransport()
    let model = WorkspaceModel(transportProvider: { transport })
    model.requestOpenThread("thread-1")
    #expect(model.pendingThreadOpen == "thread-1")
    #expect(model.selectedThreadId == nil)

    model.connect()
    try #require(await model.settledLink() == .ready, "\(model.linkMessage ?? "no message")")
    try await waitUntil("detail") { model.detail?.thread.id == "thread-1" }
    #expect(model.selectedThreadId == "thread-1")
    #expect(model.pendingThreadOpen == nil)
    await model.disconnect()
  }

  @Test func requested_thread_opens_at_once_when_ready() async throws {
    let transport = try mirroredTransport()
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try #require(await model.settledLink() == .ready, "\(model.linkMessage ?? "no message")")
    #expect(model.selectedThreadId == nil)

    model.requestOpenThread("thread-1")
    #expect(model.pendingThreadOpen == nil)
    try await waitUntil("detail") { model.detail?.thread.id == "thread-1" }
    #expect(model.selectedThreadId == "thread-1")
    await model.disconnect()
  }

  @Test func detail_request_counts_each_request() async throws {
    let transport = try mirroredTransport()
    let model = WorkspaceModel(transportProvider: { transport })
    #expect(model.detailRequest == 0)
    model.requestOpenThread("thread-1")
    model.requestOpenThread("thread-1")
    #expect(model.detailRequest == 2)
  }

  @Test func a_later_pending_request_replaces_an_earlier_one() async throws {
    let transport = try mirroredTransport()
    let model = WorkspaceModel(transportProvider: { transport })
    model.requestOpenThread("thread-9")
    model.requestOpenThread("thread-1")
    #expect(model.pendingThreadOpen == "thread-1")
    model.connect()
    try #require(await model.settledLink() == .ready, "\(model.linkMessage ?? "no message")")
    try await waitUntil("detail") { model.detail?.thread.id == "thread-1" }
    await model.disconnect()
  }

  @Test func pending_request_survives_an_unavailable_link() async throws {
    let model = WorkspaceModel(transportProvider: { throw WorkspaceError(.internalError, "no coordinator") })
    model.requestOpenThread("thread-1")
    model.connect()
    #expect(await model.settledLink() == .unavailable)
    #expect(model.pendingThreadOpen == "thread-1")
  }
}
