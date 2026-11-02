import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

/// What reached the runtimes, in order: `interrupt:<native thread>` and `delete:<native thread>`.
actor RuntimeCalls {
  private(set) var calls: [String] = []
  func record(_ call: String) { calls.append(call) }
  var deletes: [String] { calls.filter { $0.hasPrefix("delete:") } }
}

/// A real adapter (the fake runtimes) that records interrupts and deletes on their way through.
private struct RecordingAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let calls: RuntimeCalls
  var deleteDelay: Duration = .zero
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    try await inner.sendTurn(ref, input: input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    await calls.record("interrupt:\(ref.nativeSessionId)")
    return try await inner.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    try await inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await inner.reconcile(ref, turn: turn)
  }
  func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion {
    await calls.record("delete:\(ref.nativeSessionId)")
    try await Task.sleep(for: deleteDelay)
    return try await inner.deleteSession(ref)
  }
  func events() -> AsyncStream<AdapterEvent> { inner.events() }
  func dispose() async { await inner.dispose() }
}

private func recording(_ calls: RuntimeCalls, deleteDelay: Duration = .zero) -> SessionService.AdapterFactory
{
  { connection, environment, version, secrets in
    RecordingAdapter(
      inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
      calls: calls,
      deleteDelay: deleteDelay)
  }
}

/// Waits until `condition` holds: the runtime delete runs after `thread.delete` answers.
private func eventually(
  _ what: String, timeout: Duration = .seconds(30), _ condition: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while try await !condition() {
    guard ContinuousClock.now < deadline else { throw WorkspaceError(.internalError, "never: \(what)") }
    try await Task.sleep(for: .milliseconds(50))
  }
}

extension Harness {
  func delete(_ thread: ConversationThread) async throws -> ConversationThread {
    try await client.request(
      ThreadDelete.self, ThreadDelete.Params(threadId: thread.id),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30))
    ).thread
  }

  func listedIds(includeArchived: Bool = true) async throws -> [String] {
    try await client.request(ThreadList.self, ThreadList.Params(includeArchived: includeArchived)).threads
      .map(
        \.id)
  }

  func deleteSummary() async throws -> [ThreadDeleteSummary] {
    try await coordinator.diagnostics.read().threadDeletes ?? []
  }

  /// Waits until the thread has no unresolved turn.
  func settled(_ thread: ConversationThread) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while try coordinator.database.activeTurn(threadId: thread.id) != nil {
      guard ContinuousClock.now < deadline else { throw WorkspaceError(.internalError, "turn never settled") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}

@Suite(.serialized) struct ThreadDeleteTests {
  @Test func deletingAThreadHidesItAndDeletesItInCodex() async throws {
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    let kept = try await h.newThread(codex)
    let deleted = try await h.delete(thread)
    #expect(deleted.userDeletedAt != nil)
    _ = try await h.events.waitFor {
      $0.kind == .threadUpdated && $0.threadId == thread.id
        && $0.payload["thread"]?["userDeletedAt"]?.stringValue == deleted.userDeletedAt
    }
    #expect(try await h.listedIds() == [kept.id])
    do {
      _ = try await h.read(thread)
      Issue.record("a deleted thread must not be readable")
    } catch let error as WorkspaceError {
      #expect(error.code == .notFound)
    }
    try await eventually("deleted in Codex") {
      let tried = await !calls.deletes.isEmpty
      let settled = try await h.deleteSummary().isEmpty
      return tried && settled
    }
    #expect(await calls.deletes == ["delete:\(thread.nativeThreadId)"])
    await h.stop()
  }

  @Test func deletingStopsARunningTurnFirst() async throws {
    let server = try await FakeB4.start()
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "hang around")
    _ = try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    _ = try await h.delete(thread)
    try await eventually("tried in B4") {
      try h.coordinator.database.threadDeleteAttempts(threadId: thread.id) == 1
    }
    #expect(await calls.calls == ["interrupt:\(thread.nativeThreadId)", "delete:\(thread.nativeThreadId)"])
    #expect(try h.coordinator.database.activeTurn(threadId: thread.id) == nil)
    #expect(try h.coordinator.database.threadDeleteAttempts(threadId: thread.id) == 1)
    #expect(try await h.deleteSummary().isEmpty)
    await h.stop()
    await server.stop()
  }

  @Test func aPhonesDeleteIsSweptLater() async throws {
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    _ = try h.coordinator.database.markThreadDeleted(id: thread.id, at: Timestamp.now())
    #expect(await calls.deletes.isEmpty)
    #expect(try await h.deleteSummary() == [ThreadDeleteSummary(kind: .codex, waiting: 1, unsupported: 0)])
    await h.coordinator.sessions.sweepThreadDeletes()
    #expect(await calls.deletes == ["delete:\(thread.nativeThreadId)"])
    #expect(try await h.deleteSummary().isEmpty)
    await h.stop()
  }

  @Test func anUnreachableRuntimeIsRetried() async throws {
    let server = try await FakeB4.start()
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    await server.stop()
    _ = try await h.delete(thread)
    #expect(try await h.listedIds().isEmpty)
    try await eventually("tried once") {
      try h.coordinator.database.threadDeleteAttempts(threadId: thread.id) == 1
    }
    // The try has failed by now; the retry waits 30 seconds from then. The sweeps below are timed
    // from this moment, not the wall clock, so a slow restart of the fixture can't make it due.
    let failed = Date()
    #expect(try await h.deleteSummary() == [ThreadDeleteSummary(kind: .b4, waiting: 1, unsupported: 0)])
    let restarted = try await FakeB4.start(port: server.port)
    await h.coordinator.sessions.sweepThreadDeletes(now: failed)
    #expect(await calls.deletes.count == 1)
    await h.coordinator.sessions.sweepThreadDeletes(now: failed.addingTimeInterval(31))
    #expect(await calls.deletes.count == 2)
    #expect(try await h.deleteSummary().isEmpty)
    await h.stop()
    await restarted.stop()
  }

  /// The wait counts from when the try failed, not from when the sweep began: a slow failure (a request
  /// that hangs until its timeout) is not due again the moment it ends.
  @Test func aRetryWaitsFromTheFailedTry() async throws {
    let server = try await FakeB4.start()
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    await server.stop()
    _ = try h.coordinator.database.markThreadDeleted(id: thread.id, at: Timestamp.now())
    // A sweep that began an hour before its try failed.
    await h.coordinator.sessions.sweepThreadDeletes(now: Date().addingTimeInterval(-3600))
    #expect(await calls.deletes.count == 1)
    await h.coordinator.sessions.sweepThreadDeletes(now: Date())
    #expect(await calls.deletes.count == 1)
    await h.stop()
  }

  @Test func anUnsupportedRuntimeIsFinal() async throws {
    let server = try await FakeB4.start(environment: ["FAKE_B4_NO_DELETE": "1"])
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    _ = try await h.delete(thread)
    try await eventually("unsupported") {
      try await h.deleteSummary() == [ThreadDeleteSummary(kind: .b4, waiting: 0, unsupported: 1)]
    }
    await h.coordinator.sessions.sweepThreadDeletes(now: Date().addingTimeInterval(86_400))
    #expect(await calls.deletes.count == 1)
    await h.stop()
    await server.stop()
  }

  @Test func deletingAnswersBeforeASlowRuntimeDelete() async throws {
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls, deleteDelay: .seconds(5)))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    let started = ContinuousClock.now
    _ = try await h.delete(thread)
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(try await h.listedIds().isEmpty)
    try await eventually("deleted in Codex") {
      let tried = await !calls.deletes.isEmpty
      let settled = try await h.deleteSummary().isEmpty
      return tried && settled
    }
    await h.stop()
  }

  @Test func aPhonesDeleteStopsTheRunningTurn() async throws {
    let server = try await FakeB4.start()
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "hang around")
    _ = try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    // A phone's delete, pulled while the turn runs.
    _ = try h.coordinator.database.markThreadDeleted(id: thread.id, at: Timestamp.now())
    await h.coordinator.sessions.sweepThreadDeletes()
    #expect(await calls.calls == ["interrupt:\(thread.nativeThreadId)", "delete:\(thread.nativeThreadId)"])
    #expect(try h.coordinator.database.activeTurn(threadId: thread.id) == nil)
    #expect(try await h.client.request(WorkspaceActiveWork.self, EmptyParams()).turns.isEmpty)
    await h.stop()
    await server.stop()
  }

  @Test func aReconcilingTurnOfADeletedThreadIsEnded() async throws {
    let h = try await Harness.start()
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    var turn = Turn(id: "stuck", threadId: thread.id, operationId: "op-stuck")
    turn.status = .reconciling
    _ = try h.coordinator.database.insertTurn(turn)
    _ = try h.coordinator.database.markThreadDeleted(id: thread.id, at: Timestamp.now())
    await h.coordinator.sessions.sweepThreadDeletes()
    #expect(try h.coordinator.database.activeTurn(threadId: thread.id) == nil)
    #expect(try h.coordinator.database.turn(id: "stuck")?.outcome == .cancelled)
    await h.stop()
  }

  @Test func aLateEventDoesNotBringTheThreadBack() async throws {
    let server = try await FakeB4.start()
    let h = try await Harness.start()
    let b4 = try await h.addB4(server).connection
    let thread = try await h.newB4Thread(b4)
    let turn = try await h.send(thread, "slow")
    _ = try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    // A phone's delete, pulled while the turn is still streaming.
    _ = try h.coordinator.database.markThreadDeleted(id: thread.id, at: Timestamp.now())
    let before = await h.events.events.count
    try await server.waitForRunToEnd(nativeThreadId: thread.nativeThreadId)
    try await h.settled(thread)
    let late = await h.events.events.dropFirst(before)
    #expect(!late.contains { $0.event.threadId == thread.id })
    #expect(try await h.listedIds().isEmpty)
    await h.stop()
    await server.stop()
  }
}
