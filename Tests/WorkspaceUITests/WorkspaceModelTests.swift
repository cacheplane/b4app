import Foundation
import NIOTransport
import Observation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator
@testable import WorkspaceUI

/// The fake Codex runtime shipped with the adapter tests.
let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

/// A real coordinator on temporary directories with the model connected over its socket, so model
/// tests exercise the same snapshot, event, and command paths the apps use.
@MainActor
struct ModelHarness {
  let coordinator: RunningCoordinator
  let model: WorkspaceModel
  let workDir: String

  static func start() async throws -> ModelHarness {
    let base = NSTemporaryDirectory() + "b4ui-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    env["ANTHROPIC_API_KEY"] = nil
    guard
      case .running(let coordinator) = try await Coordinator.start(
        options: CoordinatorOptions(paths: paths, environment: env, secretStore: MemorySecretStore()))
    else { throw WorkspaceError(.internalError, "expected running") }
    let socketPath = paths.socketPath
    let model = WorkspaceModel(transportProvider: {
      try await UnixSocketTransport.connect(path: socketPath, timeout: .seconds(5))
    })
    model.connect()
    guard await model.settledLink() == .ready else {
      throw WorkspaceError(.internalError, "the model did not connect: \(model.linkMessage ?? "no message")")
    }
    return ModelHarness(coordinator: coordinator, model: model, workDir: base + "/work")
  }

  func stop() async {
    await model.disconnect()
    await coordinator.close()
  }
}

/// One wake-up of `waitUntil`: fired by a change to observed state the condition read, by a
/// `ConditionNudge`, or by the deadline, whichever comes first.
nonisolated final class Wakeup: Sendable {
  private let state = Mutex<(fired: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))

  func fire() {
    let continuation = state.withLock { state in
      state.fired = true
      defer { state.continuation = nil }
      return state.continuation
    }
    continuation?.resume()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let fired = state.withLock { state in
        if !state.fired { state.continuation = continuation }
        return state.fired
      }
      if fired { continuation.resume() }
    }
  }
}

/// Wakes every pending `waitUntil` to check again, for state the observation system cannot see:
/// `ScriptedTransport` posts one with each command it records and each event it emits. A wake-up
/// whose condition still fails costs one more check.
nonisolated enum ConditionNudge {
  private static let pending = Mutex<[ObjectIdentifier: Wakeup]>([:])

  static func post() {
    for wakeup in pending.withLock({ Array($0.values) }) { wakeup.fire() }
  }

  fileprivate static func register(_ wakeup: Wakeup) {
    pending.withLock { $0[ObjectIdentifier(wakeup)] = wakeup }
  }

  fileprivate static func unregister(_ wakeup: Wakeup) {
    _ = pending.withLock { $0.removeValue(forKey: ObjectIdentifier(wakeup)) }
  }
}

/// Returns once `condition` holds. It is checked now and again after each change to an observed
/// property it read (the model is `@Observable`) or a `ConditionNudge`, never on a clock. `onChange`
/// fires as a property is about to change; the check runs on the main actor's next turn, after the
/// write. The timeout only ends a test that would otherwise hang; the expected path never waits on it.
@MainActor
func waitUntil(
  _ what: String, timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while true {
    let wakeup = Wakeup()
    ConditionNudge.register(wakeup)
    defer { ConditionNudge.unregister(wakeup) }
    let met = withObservationTracking {
      condition()
    } onChange: {
      wakeup.fire()
    }
    if met { return }
    guard ContinuousClock.now < deadline else {
      throw WorkspaceError(.internalError, "timed out waiting for \(what)")
    }
    let alarm = Task {
      guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
      wakeup.fire()
    }
    await wakeup.wait()
    alarm.cancel()
  }
}

@Suite(.serialized) @MainActor struct WorkspaceModelTests {
  @Test func settledLinkReturnsWhenTheConnectionFails() async {
    let model = WorkspaceModel(transportProvider: {
      throw WorkspaceError(.endpointUnavailable, "no coordinator")
    })
    model.connect()
    #expect(await model.settledLink() == .unavailable)
    #expect(model.linkMessage?.contains("no coordinator") == true)
    // Already settled: returns at once.
    #expect(await model.settledLink() == .unavailable)
  }

  @Test func sidebarStateFollowsTurnEventsAndArchivedThreadsHideUntilAsked() async throws {
    let h = try await ModelHarness.start()
    let model = h.model
    let connection = try #require(
      await model.addConnection(kind: .codex, label: "Fake Codex", executablePath: fakeCodex))
    #expect(connection.status == .ready)
    await model.createThread(connectionId: connection.id, directory: h.workDir, title: "first")
    let thread = try #require(model.threads.first)
    #expect(model.threadState(thread) == .idle)

    model.composerText = "hang around"
    await model.send()
    try await waitUntil("running") { model.threadState(thread) == .running }
    await model.stop()
    try await waitUntil("idle again") { model.threadState(thread) == .idle && model.activeTurns.isEmpty }

    await model.updateThread(id: thread.id, archived: true)
    try await waitUntil("archived") { model.threads.first?.archived == true }
    #expect(model.visibleThreads.isEmpty)
    #expect(model.archivedThreads.map(\.id) == [thread.id])
    model.showArchived = true
    #expect(model.archivedThreads.count == 1)
    await model.updateThread(id: thread.id, archived: false)
    try await waitUntil("unarchived") { model.visibleThreads.map(\.id) == [thread.id] }
    await model.updateThread(id: thread.id, title: "renamed")
    try await waitUntil("renamed") { model.threads.first?.title == "renamed" }
    await h.stop()
  }

  @Test func draftsAreSavedAfterTypingStopsAndFlushedOnDemand() async throws {
    let h = try await ModelHarness.start()
    let model = h.model
    model.draftSaveDelay = .milliseconds(150)
    let connection = try #require(
      await model.addConnection(kind: .codex, label: "Fake Codex", executablePath: fakeCodex))
    await model.createThread(connectionId: connection.id, directory: h.workDir, title: "drafty")
    let thread = try #require(model.threads.first)
    try await waitUntil("detail loaded") { model.detail?.thread.id == thread.id }

    model.composerText = "half a"
    model.composerText = "half a thought"
    #expect(model.draftSaveTask != nil)
    try await waitUntil("debounced save") { model.draftSaveTask == nil }
    let saved = try h.coordinator.database.draft(threadId: thread.id)
    #expect(saved?.text == "half a thought")

    model.composerText = "half a thought, then quit"
    await model.persistDraftNow()
    #expect(try h.coordinator.database.draft(threadId: thread.id)?.text == "half a thought, then quit")

    // Reopening restores the draft without scheduling another write.
    model.selectedThreadId = nil
    await model.openThread(id: thread.id)
    #expect(model.composerText == "half a thought, then quit")
    #expect(model.draftSaveTask == nil)
    await h.stop()
  }
}
