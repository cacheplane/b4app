import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

/// A model with no coordinator behind it: the tests feed it state and events directly.
@MainActor
private func offlineModel() -> WorkspaceModel {
  WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "offline") })
}

private func thread(
  _ id: String = "t1", connectionId: String = "c1", title: String = "Trip notes"
)
  -> ConversationThread
{
  ConversationThread(
    id: id, connectionId: connectionId, nativeThreadId: "n-\(id)", title: title, context: "/tmp")
}

private func runningTurn(threadId: String) -> Turn {
  var turn = Turn(id: "u1", threadId: threadId, operationId: "op1")
  turn.status = .running
  return turn
}

@MainActor
@Suite struct ThreadDeleteModelTests {
  @Test func deletingTheOpenThreadClosesIt() async throws {
    let h = try await ModelHarness.start()
    let model = h.model
    let connection = try #require(
      await model.addConnection(kind: .codex, label: "Fake Codex", executablePath: fakeCodex))
    await model.createThread(connectionId: connection.id, directory: h.workDir, title: "private")
    let opened = try #require(model.threads.first)
    #expect(model.detail?.thread.id == opened.id)
    model.composerText = "never sent"
    #expect(await model.deleteThread(id: opened.id))
    #expect(model.detail == nil)
    #expect(model.selectedThreadId == nil)
    #expect(!model.threads.contains { $0.id == opened.id })
    // The refetch an earlier event scheduled finds nothing and brings nothing back.
    try await Task.sleep(for: .milliseconds(600))
    #expect(!model.threads.contains { $0.id == opened.id })
    #expect(model.lastError == nil)
    await h.stop()
  }

  @Test func confirmationCopyNamesTheRuntime() {
    let model = offlineModel()
    model.merge(Connection(id: "c1", kind: .codex, label: "Codex", target: "/x"))
    model.merge(Connection(id: "c2", kind: .claude, label: "Claude", target: "/x"))
    model.merge(Connection(id: "c3", kind: .b4, label: "B4", target: "http://127.0.0.1:1"))
    var disabled = Connection(id: "c4", kind: .codex, label: "Off", target: "/x")
    disabled.enabled = false
    model.merge(disabled)

    let codex = model.deleteConfirmation(for: thread())
    #expect(codex.title == "Delete \"Trip notes\"?")
    #expect(codex.message == "It's removed from this app and from Codex. You can't undo this.")
    #expect(
      model.deleteConfirmation(for: thread(connectionId: "c2")).message
        == "It's removed from this app and from Claude Code. You can't undo this.")
    #expect(
      model.deleteConfirmation(for: thread(connectionId: "c3")).message
        == "It's removed from this app and from the B4 server. You can't undo this.")
    #expect(
      model.deleteConfirmation(for: thread(connectionId: "c4")).message
        == "It's removed from this app. You can't undo this.")

    model.apply(
      AdapterEvent(
        kind: .turnStateChanged, connectionId: "c1", threadId: "t1", turnId: "u1",
        payload: ["turn": try! JSONValue(encoding: runningTurn(threadId: "t1"))]))
    #expect(
      model.deleteConfirmation(for: thread()).message
        == "It's removed from this app and from Codex. You can't undo this. Its running turn will be stopped."
    )
  }

  @Test func aLateTurnEventForADeletedThreadKeepsItGone() throws {
    let model = offlineModel()
    model.store(thread())
    var deleted = thread()
    deleted.userDeletedAt = "2026-11-02T12:00:00.000Z"
    model.apply(try AdapterEvent.threadUpdated(deleted))
    #expect(model.threads.isEmpty)

    model.apply(
      AdapterEvent(
        kind: .turnStateChanged, connectionId: "c1", threadId: "t1", turnId: "u1",
        payload: ["turn": try JSONValue(encoding: runningTurn(threadId: "t1"))]))
    #expect(model.activeTurns["t1"] == nil)
    // A stale copy of the row without the mark does not restore it either.
    model.apply(try AdapterEvent.threadUpdated(thread()))
    #expect(model.threads.isEmpty)
  }
}
