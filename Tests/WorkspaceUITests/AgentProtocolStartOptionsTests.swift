import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// Pure model/transport fixtures: no store, filesystem, provider or network connection.
@MainActor @Suite struct AgentProtocolStartOptionsTests {
  private func withModel(
    phone: Bool, _ body: (WorkspaceModel, WorkEnvironment) throws -> Void
  ) async throws {
    let environment = WorkEnvironment(
      id: "work", name: "Work",
      folders: [EnvironmentFolder(id: "folder", environmentId: "work", path: "/fixture/work")],
      ownerDeviceId: "mac-1")
    let connections = [
      Connection(
        id: "codex", kind: .codex, label: "Codex", target: "", ownerDeviceId: "mac-1", status: .ready),
      Connection(
        id: "claude", kind: .claude, label: "Claude", target: "", ownerDeviceId: "mac-1", status: .ready),
      Connection(
        id: "other-mac", kind: .codex, label: "Other", target: "", ownerDeviceId: "mac-2", status: .ready),
      Connection(
        id: "historical-local", kind: .b4, label: "Historical local", target: "", b4Mode: .managedLocal,
        environmentId: "work", ownerDeviceId: "mac-1", status: .ready),
      Connection(
        id: "historical-remote", kind: .b4, label: "Historical remote", target: "", b4Mode: .remote,
        ownerDeviceId: "mac-1", status: .ready),
      Connection(
        id: "staged-protocol", kind: .agentProtocol, label: "Staged", target: "https://example.invalid",
        peerProfile: .agentProtocol, agentId: "fixture", authMode: ConnectionAuthMode.none,
        ownerDeviceId: "mac-1", status: .ready),
    ]
    let transport = ScriptedTransport()
    transport.set(connections: connections, threads: [PhoneFixture.thread()], environments: [environment])
    let model = WorkspaceModel(transportProvider: { transport })
    if phone { model.accountSource = .host }
    model.connect()
    var failure: (any Error)?
    do {
      try #require(await model.settledLink() == .ready)
      try body(model, environment)
    } catch { failure = error }
    await model.disconnect()
    if let failure { throw failure }
  }

  @Test func noFolderKeepsThePrimaryMacHarnessesAndExcludesUnavailableKinds() async throws {
    try await withModel(phone: true) { model, environment in
      #expect(model.primaryHostId == "mac-1")
      #expect(model.startConnectionsWithoutEnvironment.map(\.id) == ["codex", "claude"])
      #expect(model.startConnections(for: environment).map(\.id) == ["codex", "claude"])
      #expect(model.remoteB4Connections.isEmpty)
      for connection in model.connections {
        let folders = model.startFolders(for: environment, connection: connection)
        #expect(folders.count == (connection.kind == .codex || connection.kind == .claude ? 1 : 0))
      }
    }
    try await withModel(phone: false) { model, environment in
      #expect(model.startConnectionsWithoutEnvironment.map(\.id) == ["codex", "claude", "other-mac"])
      #expect(model.startConnections(for: environment).map(\.id) == ["codex", "claude", "other-mac"])
      #expect(model.remoteB4Connections.isEmpty)
    }
  }

  @Test func historicalDeleteCopyDoesNotPromiseUpstreamDeletionOrInterruption() async throws {
    try await withModel(phone: false) { model, _ in
      for id in ["historical-local", "historical-remote", "staged-protocol"] {
        let thread = ConversationThread(
          id: "history-\(id)", connectionId: id, nativeThreadId: "old-id", title: "Cached")
        let turn = Turn(
          id: "unknown-\(id)", threadId: thread.id, operationId: "old-\(id)", status: .reconciling,
          submission: .unknown)
        model.apply(
          AdapterEvent(
            kind: .turnStateChanged, connectionId: id, threadId: thread.id, turnId: turn.id,
            payload: ["turn": try JSONValue(encoding: turn)]))
        #expect(model.activeTurns[thread.id]?.outcome == nil)
        let message = model.deleteConfirmation(for: thread).message
        #expect(message == "It's removed from this app. You can't undo this.")
      }
    }
  }
}
