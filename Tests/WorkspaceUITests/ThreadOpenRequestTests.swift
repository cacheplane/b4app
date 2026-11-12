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

  private func mirrored(
    seedThread: Bool = true
  ) throws -> (transport: MirrorTransport, store: MirrorStore, fixture: [StoredChange]) {
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
    _ = try store.apply(Array(all.prefix(seedThread ? 2 : 1)))
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
    try await waitUntil("detail") { model.detail?.thread.id == "thread-1" }
    try await waitUntil("open completed") { model.pendingThreadOpen == nil }
    #expect(model.selectedThreadId == "thread-1")
    await model.disconnect()
  }

  /// The alert can arrive while the phone is suspended, before its mirror has pulled the thread.
  /// Opening it must keep the intent until that row arrives, rather than declare it deleted.
  @Test(arguments: [false, true])
  func requested_thread_waits_for_its_first_sync(coldLaunch: Bool) async throws {
    let (transport, store, fixture) = try mirrored(seedThread: false)
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    if coldLaunch { model.requestOpenThread("thread-1") }
    model.connect()
    try #require(await model.settledLink() == .ready)
    if !coldLaunch { model.requestOpenThread("thread-1") }
    try await waitUntil("open retained or lookup finished") {
      model.pendingThreadOpen == "thread-1" || model.lastError != nil
    }
    #expect(model.lastError == nil, "A thread missing from a stale mirror is not known to be deleted")
    #expect(model.pendingThreadOpen == "thread-1")

    transport.publish(try store.apply(Array(fixture.dropFirst())))
    try await waitUntil("thread appears in list") { model.threads.contains { $0.id == "thread-1" } }
    try await waitUntil("notification opens the newly synced thread") {
      model.detail?.thread.id == "thread-1"
    }
    #expect(model.pendingThreadOpen == nil)
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  @Test func a_missing_notification_thread_has_a_bounded_honest_failure() async throws {
    let transport = try mirroredTransport()
    let clock = TestClock()
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.clock = clock
    model.connect()
    try #require(await model.settledLink() == .ready)
    model.requestOpenThread("not-synced")
    try await waitUntil("first missing read finished") {
      model.selectedThreadId == "not-synced" && !model.detailLoading
    }
    #expect(model.lastError == nil)
    // loadDetail clears its loading flag before the retry sleep is registered. Advancing before
    // registration would put that sleep after the new clock time and leave it asleep indefinitely.
    try await waitUntil("missing-thread retry scheduled") { clock.sleepingCount > 0 }
    clock.advance(by: WorkspaceModel.threadOpenWait)
    try await waitUntil("open timeout") { model.pendingThreadOpen == nil }
    #expect(model.selectedThreadId == nil)
    #expect(model.lastError == "This thread is unavailable. Check your connection and try again.")
    await model.disconnect()
  }

  @Test func a_retry_sleep_does_not_extend_the_notification_open_deadline() async throws {
    let transport = try mirroredTransport()
    let clock = DeadlineJumpClock(jump: WorkspaceModel.threadOpenWait)
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.clock = clock
    model.connect()
    try #require(await model.settledLink() == .ready)
    model.requestOpenThread("not-synced")
    try await waitUntil("retry sleep registered") { clock.firstSleep != nil }
    let retry = try #require(clock.firstSleep)
    #expect(retry <= TestClock.Instant(offset: WorkspaceModel.threadOpenWait))
    await model.disconnect()
  }

  @Test func back_cancels_an_open_waiting_for_sync() async throws {
    let (transport, store, fixture) = try mirrored(seedThread: false)
    let clock = TestClock()
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.clock = clock
    model.connect()
    try #require(await model.settledLink() == .ready)
    model.requestOpenThread("thread-1")
    try await waitUntil("first missing read finished") {
      model.selectedThreadId == "thread-1" && !model.detailLoading
    }
    model.cancelThreadOpen()
    transport.publish(try store.apply(Array(fixture.dropFirst())))
    clock.advance(by: WorkspaceModel.threadOpenWait)
    try await model.refreshSnapshot()
    #expect(model.pendingThreadOpen == nil)
    #expect(model.selectedThreadId == nil)
    #expect(model.detail == nil)
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  @Test func starting_a_new_thread_cancels_the_notification_open() async throws {
    let (transport, store, fixture) = try mirrored(seedThread: false)
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.connect()
    try #require(await model.settledLink() == .ready)
    model.requestOpenThread("thread-1")
    try await waitUntil("notification selected") { model.selectedThreadId == "thread-1" }
    await model.openNewThread()
    transport.publish(try store.apply(Array(fixture.dropFirst())))
    try await model.refreshSnapshot()
    #expect(model.pendingThreadOpen == nil)
    #expect(model.selectedThreadId == nil)
    #expect(model.detail == nil)
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  @Test func a_late_missing_read_cannot_replace_a_newer_open() async throws {
    let mirror = try mirroredTransport()
    let held = HeldReads(mirror)
    let model = WorkspaceModel(transportProvider: { held }, accountSource: .host)
    model.connect()
    try #require(await model.settledLink() == .ready)
    model.requestOpenThread("not-synced")
    try await waitUntil("old read held") { held.heldCount == 1 }
    model.requestOpenThread("thread-1")
    try await waitUntil("new read held") { held.heldCount == 2 }
    held.release()
    try await waitUntil("new request opens") { model.detail?.thread.id == "thread-1" }
    #expect(model.selectedThreadId == "thread-1")
    #expect(model.pendingThreadOpen == nil)
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  @Test func a_snapshot_during_a_notification_open_does_not_restore_not_found() async throws {
    let (transport, store, fixture) = try mirrored()
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.connect()
    try #require(await model.settledLink() == .ready)
    await model.openThread(id: "thread-1")
    try #require(model.detail?.thread.id == "thread-1")
    model.requestOpenThread("thread-2")
    try await waitUntil("missing second thread read finished") {
      model.selectedThreadId == "thread-2" && !model.detailLoading
    }
    try await model.refreshSnapshot()
    #expect(model.lastError == nil)
    #expect(model.pendingThreadOpen == "thread-2")
    #expect(model.selectedThreadId == "thread-2")

    var value = try #require(fixture[1].value?.objectValue)
    value["id"] = "thread-2"
    value["nativeThreadId"] = "native-2"
    transport.publish(
      try store.apply([
        StoredChange(
          hubSeq: 100, deviceId: "mac-1", deviceSeq: 100, wall: fixture[1].wall,
          table: "threads", rowId: "thread-2", op: "insert", column: nil, value: .object(value))
      ]))
    // The open re-reads every 250 ms until it finds the thread or its own 15 s run out, so wait for it
    // to end either way rather than for a fixed time a loaded machine can miss (3 s was).
    try await waitUntil("the open finishes") { model.pendingThreadOpen == nil }
    #expect(model.detail?.thread.id == "thread-2")
    #expect(model.lastError == nil)
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

  /// A sign-out forgets an open request, so the next sign-in's root view (which acts on a nonzero
  /// `detailRequest` when it mounts) does not move the iPhone to an empty thread column.
  @Test func sign_out_clears_the_open_request() async throws {
    let transport = try mirroredTransport()
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    model.requestOpenThread("thread-1")
    #expect(model.detailRequest == 1)
    #expect(model.pendingThreadOpen == "thread-1")

    model.applyAccountStatus(AccountStatus.Result(state: .signedOut), loadStore: false)
    #expect(model.detailRequest == 0)
    #expect(model.pendingThreadOpen == nil)
    // And asks for the list, since nothing is open.
    #expect(model.sidebarRequest == 1)
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

/// Advances between the expiry check and scheduling the retry, reproducing the CI clock race
/// without waiting for a wall-clock timeout. A retry must still be bounded by the original deadline.
private final class DeadlineJumpClock: Clock, @unchecked Sendable {
  typealias Instant = TestClock.Instant
  private let base = TestClock()
  private let jump: Duration
  private let state = Mutex<(reads: Int, firstSleep: Instant?)>((0, nil))

  init(jump: Duration) { self.jump = jump }

  var minimumResolution: Duration { base.minimumResolution }
  var now: Instant {
    let shouldJump = state.withLock { state in
      state.reads += 1
      return state.reads == 3
    }
    if shouldJump { base.advance(by: jump) }
    return base.now
  }

  var firstSleep: Instant? { state.withLock { $0.firstSleep } }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    state.withLock { if $0.firstSleep == nil { $0.firstSleep = deadline } }
    ConditionNudge.post()
    try await base.sleep(until: deadline, tolerance: tolerance)
  }
}
