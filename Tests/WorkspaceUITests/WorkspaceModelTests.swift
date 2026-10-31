import Foundation
import NIOTransport
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceUI

/// The fake Codex runtime shipped with the adapter tests.
private let fakeCodex =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("CodexAdapterTests/Fixtures/fake-codex.py").path

/// A real coordinator on temporary directories with the model connected over its socket, so model
/// tests exercise the same snapshot, event, and command paths the apps use.
@MainActor
private struct ModelHarness {
  let coordinator: RunningCoordinator
  let model: WorkspaceModel
  let workDir: String

  static func start() async throws -> ModelHarness {
    let base = NSTemporaryDirectory() + "b4ui-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
    let paths = PlatformPaths(runtimeDir: base + "/rt", dataDir: base + "/data")
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
    try await waitUntil("model ready") { model.link == .ready }
    return ModelHarness(coordinator: coordinator, model: model, workDir: base + "/work")
  }

  func stop() async {
    await model.disconnect()
    await coordinator.close()
  }
}

@MainActor
private func waitUntil(
  _ what: String, timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw WorkspaceError(.internalError, "timed out waiting for \(what)")
}

@Suite(.serialized) @MainActor struct WorkspaceModelTests {
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
    WorkspaceModel.draftSaveDelay = .milliseconds(150)
    defer { WorkspaceModel.draftSaveDelay = .milliseconds(600) }
    let h = try await ModelHarness.start()
    let model = h.model
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
