import Foundation
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

/// What reached the runtimes, in order: `interrupt:<native thread>` and `delete:<native thread>`.
actor RuntimeCalls {
  private(set) var calls: [String] = []
  /// A delete of one of these native threads takes this long instead of the adapter's `deleteDelay`.
  private var delays: [String: Duration] = [:]
  func record(_ call: String) { calls.append(call) }
  var deletes: [String] { calls.filter { $0.hasPrefix("delete:") } }
  func slowDelete(of nativeThreadId: String, by delay: Duration) { delays[nativeThreadId] = delay }
  func deleteDelay(of nativeThreadId: String) -> Duration? { delays[nativeThreadId] }
}

/// Inject only a retryable adapter failure; reachable attempts still call the real Codex adapter.
private actor DeleteReachability {
  private var reachable = true
  func setReachable(_ value: Bool) { reachable = value }
  func requireReachable() throws {
    guard reachable else {
      throw WorkspaceError(.endpointUnavailable, "Controlled test runtime is unreachable.")
    }
  }
}

/// Own one real held-turn interrupt; clear the stored callback before awaiting it.
private actor LateCompletion {
  private var completion: (@Sendable () async throws -> StopReceipt)?
  func install(_ value: @escaping @Sendable () async throws -> StopReceipt) {
    precondition(completion == nil)
    completion = value
  }
  func finish() async throws -> StopReceipt {
    guard let value = completion else {
      throw WorkspaceError(.internalError, "No held native turn was installed.")
    }
    completion = nil
    return try await value()
  }
}

/// A real adapter (the fake runtimes) that records interrupts and deletes on their way through.
private struct RecordingAdapter: AgentAdapter {
  let inner: any AgentAdapter
  let calls: RuntimeCalls
  var deleteDelay: Duration = .zero
  var deleteReachability: DeleteReachability?
  var lateCompletion: LateCompletion?
  var kind: ConnectionKind { inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await inner.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    let receipt = try await inner.sendTurn(ref, input: input)
    if let lateCompletion {
      guard let nativeTurnId = receipt.nativeTurnId else {
        throw WorkspaceError(.internalError, "Expected an acknowledged native turn.")
      }
      await lateCompletion.install { [inner] in
        try await inner.interrupt(ref, turn: ActiveTurnRef(nativeTurnId: nativeTurnId))
      }
    }
    return receipt
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
    try await Task.sleep(for: await calls.deleteDelay(of: ref.nativeSessionId) ?? deleteDelay)
    if let deleteReachability { try await deleteReachability.requireReachable() }
    return try await inner.deleteSession(ref)
  }
  func events() -> AsyncStream<AdapterEvent> { inner.events() }
  func dispose() async { await inner.dispose() }
}

private func recording(
  _ calls: RuntimeCalls, deleteDelay: Duration = .zero,
  deleteReachability: DeleteReachability? = nil, lateCompletion: LateCompletion? = nil
) -> SessionService.AdapterFactory {
  { connection, environment, version, secrets in
    RecordingAdapter(
      inner: try SessionService.defaultAdapterFactory(connection, environment, version, secrets),
      calls: calls,
      deleteDelay: deleteDelay, deleteReachability: deleteReachability, lateCompletion: lateCompletion)
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

/// Order the deletion and cursor against publication in one event-log actor turn.
private func markDeletedAndCaptureCursor(
  threadId: String, database: WorkspaceDatabase, eventLog: isolated EventLog
) throws -> Int {
  let cursor = eventLog.sequence
  _ = try database.markThreadDeleted(id: threadId, at: Timestamp.now())
  return cursor
}

@Suite(.serialized) struct ThreadDeleteTests {
  @Test func deletingAThreadHidesItAndDeletesItInCodex() async throws {
    let calls = RuntimeCalls()
    let h = try await Harness.start(
      adapterFactory: recording(calls),
      inspectionObservation: InspectionRequestObservation(caseID: .deleteCodex))
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
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    let turn = try await h.send(thread, "hang around")
    _ = try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    _ = try await h.delete(thread)
    try await eventually("tried in Codex") {
      try h.coordinator.database.threadDeleteAttempts(threadId: thread.id) == 1
    }
    #expect(await calls.calls == ["interrupt:\(thread.nativeThreadId)", "delete:\(thread.nativeThreadId)"])
    #expect(try h.coordinator.database.activeTurn(threadId: thread.id) == nil)
    #expect(try h.coordinator.database.threadDeleteAttempts(threadId: thread.id) == 1)
    #expect(try await h.deleteSummary().isEmpty)
    await h.stop()
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
    let reachability = DeleteReachability()
    let calls = RuntimeCalls()
    let h = try await Harness.start(
      adapterFactory: recording(calls, deleteReachability: reachability))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    await reachability.setReachable(false)
    _ = try await h.delete(thread)
    #expect(try await h.listedIds().isEmpty)
    try await eventually("tried once") {
      try h.coordinator.database.threadDeleteAttempts(threadId: thread.id) == 1
    }
    // The try has failed by now; the retry waits 30 seconds from then. The sweeps below are timed
    // from this moment, not the wall clock, so a slow restart of the fixture can't make it due.
    let failed = Date()
    #expect(try await h.deleteSummary() == [ThreadDeleteSummary(kind: .codex, waiting: 1, unsupported: 0)])
    await reachability.setReachable(true)
    await h.coordinator.sessions.sweepThreadDeletes(now: failed)
    #expect(await calls.deletes.count == 1)
    await h.coordinator.sessions.sweepThreadDeletes(now: failed.addingTimeInterval(31))
    #expect(await calls.deletes.count == 2)
    #expect(try await h.deleteSummary().isEmpty)
    await h.stop()
  }

  /// The wait counts from when the try failed, not from when the sweep began: a slow failure (a request
  /// that hangs until its timeout) is not due again the moment it ends.
  @Test func aRetryWaitsFromTheFailedTry() async throws {
    let reachability = DeleteReachability()
    let calls = RuntimeCalls()
    let h = try await Harness.start(
      adapterFactory: recording(calls, deleteReachability: reachability))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    await reachability.setReachable(false)
    _ = try h.coordinator.database.markThreadDeleted(id: thread.id, at: Timestamp.now())
    // A sweep that began an hour before its try failed.
    await h.coordinator.sessions.sweepThreadDeletes(now: Date().addingTimeInterval(-3600))
    #expect(await calls.deletes.count == 1)
    await h.coordinator.sessions.sweepThreadDeletes(now: Date())
    #expect(await calls.deletes.count == 1)
    await h.stop()
  }

  @Test func anUnsupportedRuntimeIsFinal() async throws {
    let calls = RuntimeCalls()
    let h = try await Harness.start(
      extraEnvironment: ["FAKE_CODEX_NO_DELETE": "1"], adapterFactory: recording(calls))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    _ = try await h.delete(thread)
    try await eventually("unsupported") {
      try await h.deleteSummary() == [ThreadDeleteSummary(kind: .codex, waiting: 0, unsupported: 1)]
    }
    await h.coordinator.sessions.sweepThreadDeletes(now: Date().addingTimeInterval(86_400))
    #expect(await calls.deletes.count == 1)
    await h.stop()
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
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
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

  /// A sweep that read its due list before another sweep finished a thread does not try it again.
  @Test func aSweepSkipsAThreadAnotherSweepFinished() async throws {
    let calls = RuntimeCalls()
    let h = try await Harness.start(adapterFactory: recording(calls))
    let codex = try await h.addCodex()
    let first = try await h.newThread(codex)
    let second = try await h.newThread(codex)
    _ = try h.coordinator.database.markThreadDeleted(id: first.id, at: "2026-11-02T12:00:00.000Z")
    _ = try h.coordinator.database.markThreadDeleted(id: second.id, at: "2026-11-02T12:00:01.000Z")
    await calls.slowDelete(of: first.nativeThreadId, by: .seconds(3))
    // This sweep reads both as due, then spends three seconds on the first.
    let slow = Task { await h.coordinator.sessions.sweepThreadDeletes() }
    try await eventually("the first delete started") { await !calls.deletes.isEmpty }
    // Meanwhile the second is deleted by a sweep of its own.
    await h.coordinator.sessions.sweepThreadDeletes(only: second.id)
    await slow.value
    #expect(await calls.deletes == ["delete:\(first.nativeThreadId)", "delete:\(second.nativeThreadId)"])
    await h.stop()
  }

  @Test func theBackoffDoublesFromThirtySecondsAndCapsAtAnHour() {
    let waits = (0...8).map { SessionService.threadDeleteBackoff(attempts: $0) }
    #expect(waits == [30, 60, 120, 240, 480, 960, 1920, 3600, 3600])
    #expect(SessionService.threadDeleteBackoff(attempts: 10_000) == 3600)
  }

  /// A delete marked on the phone reaches the Mac by pull, and the sweep then deletes the runtime's copy.
  @Test func aPulledPhoneDeleteIsSweptToTheRuntime() async throws {
    let base = AgentProtocolResourceFixture.temporaryDirectory + "b4td-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(
      "DLTE2345",
      EnrollResponse(
        deviceId: "dev-mac", token: "tok-delete", org: OrgInfo(slug: "acme", name: "Acme"),
        user: UserInfo(username: "brian", displayName: "Brian")))
    await fake.setDevices([
      DeviceInfo(id: "dev-mac", name: "Mac", platform: "macos"),
      DeviceInfo(id: "dev-phone", name: "Phone", platform: "ios"),
    ])
    let calls = RuntimeCalls()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: MemorySecretStore(), adapterFactory: recording(calls),
        hubAPIFactory: { _, _ in fake }, hubLinkConnection: FakeHubLinkConnection()))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    _ = try await coordinator.accounts.join(url: "http://localhost:8080", code: "DLTE2345", deviceName: "Mac")
    let codex = try await coordinator.sessions.connectionAdd(
      ConnectionAdd.Params(kind: .codex, label: "Fake Codex", executablePath: fakeCodex)
    ).connection
    let thread = try await coordinator.sessions.threadCreate(
      ThreadCreate.Params(connectionId: codex.id, workingDirectory: base + "/work")
    ).thread

    let mark = "2026-11-02T12:00:00.000Z"
    let next = (await fake.stored.last?.hubSeq ?? 0) + 1
    await fake.append([
      StoredChange(
        hubSeq: next, deviceId: "dev-phone", deviceSeq: 1, wall: Int(epochMillis()), table: "threads",
        rowId: thread.id, op: "update", column: "userDeletedAt", value: .string(mark),
        hlc: HLC(millis: epochMillis() + 60_000, counter: 0, deviceId: "dev-phone").rawValue)
    ])
    try await eventually("the phone's mark pulled") {
      try coordinator.database.thread(id: thread.id)?.userDeletedAt == mark
    }
    #expect(await calls.deletes.isEmpty)
    await coordinator.sessions.sweepThreadDeletes()
    #expect(await calls.deletes == ["delete:\(thread.nativeThreadId)"])
    #expect(try coordinator.database.threadDeleteSummary().isEmpty)
    await coordinator.close()
  }

  @Test func aLateEventDoesNotBringTheThreadBack() async throws {
    let completion = LateCompletion()
    let calls = RuntimeCalls()
    let h = try await Harness.start(
      adapterFactory: recording(calls, lateCompletion: completion))
    let codex = try await h.addCodex()
    let thread = try await h.newThread(codex)
    let turn = try await h.send(thread, "hang around")
    _ = try await h.events.waitFor {
      $0.kind == .turnStateChanged && $0.turnId == turn.id && $0.payload["status"]?.stringValue == "running"
    }
    // A phone's delete, pulled while the turn is still streaming.
    // A client may still be collecting older events. Mark deletion and capture the producer
    // cursor in one actor turn, so a publication after deletion cannot enter the cutoff.
    let before = try await markDeletedAndCaptureCursor(
      threadId: thread.id, database: h.coordinator.database, eventLog: h.coordinator.eventLog)
    let stop = try await completion.finish()
    #expect(stop.confirmed)
    try await h.settled(thread)
    let late = await h.events.events.filter { $0.sequence > before }
    #expect(!late.contains { $0.event.threadId == thread.id })
    // Check the producer too, so slow client delivery cannot hide a newly published event.
    let published = try #require(
      await h.coordinator.eventLog.replay(epoch: h.coordinator.eventLog.epoch, afterSequence: before))
    #expect(!published.contains { $0.event.threadId == thread.id })
    #expect(try await h.listedIds().isEmpty)
    await h.stop()
  }
}
