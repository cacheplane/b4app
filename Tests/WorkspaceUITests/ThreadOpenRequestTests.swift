import Foundation
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceMirror
import WorkspaceProtocol
import WorkspaceSync

@testable import WorkspaceUI

/// A notification tap or a widget row asks the model to open a thread (M8f), possibly before it has
/// connected on a cold launch.
@Suite(.serialized) @MainActor struct ThreadOpenRequestTests {
  /// The shared wire fixture's connection and thread (`thread-1`), as the hub serves them.
  private func mirroredTransport() throws -> MirrorTransport {
    try mirrored().transport
  }

  private func mirrored() throws -> (transport: MirrorTransport, store: MirrorStore, fixture: [StoredChange])
  {
    let url = URL(fileURLWithPath: "\(#filePath)")
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/sync/changes.json")
    let wire = try JSONCoding.decoder.decode([SyncChange].self, from: Data(contentsOf: url))
    let all = wire.enumerated().map { index, change in
      StoredChange(
        hubSeq: index + 1, deviceId: "mac-1", deviceSeq: change.deviceSeq, wall: change.wall,
        table: change.table, rowId: change.rowId, op: change.op, column: change.column, value: change.value)
    }
    let store = try MirrorStore.inMemory()
    _ = try store.apply(Array(all.prefix(2)))
    return (MirrorTransport(store: store, version: "0.2.0"), store, all)
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

  /// A cold-launch open whose `thread.read` is slow must not hold up the event stream: an event the
  /// transport emits after connect is applied while the read is still outstanding.
  @Test func events_apply_while_the_requested_open_is_outstanding() async throws {
    let (mirror, store, fixture) = try mirrored()
    let held = HeldReads(mirror)
    let model = WorkspaceModel(transportProvider: { held })
    model.requestOpenThread("thread-1")
    model.connect()
    try #require(await model.settledLink() == .ready, "\(model.linkMessage ?? "no message")")
    try await waitUntil("the open's read is held") { held.heldCount > 0 }
    #expect(model.detail == nil)

    mirror.publish(try store.apply([fixture[9]]))  // the title update
    try await waitUntil("renamed", timeout: .seconds(10)) { model.threads.first?.title == "Renamed" }
    #expect(model.detail == nil, "the open had not finished when the event was applied")

    held.release()
    do {
      try await waitUntil("detail after release", timeout: .seconds(20)) {
        model.detail?.thread.id == "thread-1"
      }
    } catch {
      Issue.record("no detail after release; lastError: \(model.lastError ?? "none")")
      throw error
    }
    await model.disconnect()
  }
}

/// Wraps a transport and holds every `thread.read` request until `release()`.
private final class HeldReads: WorkspaceTransport {
  private let inner: MirrorTransport
  private let state = Mutex<(released: Bool, held: [CheckedContinuation<Void, Never>])>((false, []))

  init(_ inner: MirrorTransport) { self.inner = inner }

  var incoming: AsyncStream<Data> { inner.incoming }

  /// `heldCount` is not observable state, so `waitUntil` is nudged when a read is held.
  @MainActor var heldCount: Int { state.withLock { $0.held.count } }

  func send(_ line: Data) async throws {
    if String(decoding: line, as: UTF8.self).contains("\"thread.read\"") {
      await withCheckedContinuation { continuation in
        let resumeNow = state.withLock { state -> Bool in
          if state.released { return true }
          state.held.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() } else { ConditionNudge.post() }
      }
    }
    try await inner.send(line)
  }

  func close() async { await inner.close() }

  func release() {
    let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released = true
      defer { state.held = [] }
      return state.held
    }
    for continuation in waiting { continuation.resume() }
  }
}
