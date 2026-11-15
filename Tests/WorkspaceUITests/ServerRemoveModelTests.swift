import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// Removing a B4 project from Settings (D-231).
@MainActor @Suite struct ServerRemoveModelTests {
  private static let server = LocalServer(
    id: "s1", name: "research", projectPath: "/p/research", nodePath: "/n", cliPath: "/c",
    launchMode: .source)

  private static func connected(_ transport: ScriptedTransport) async throws -> WorkspaceModel {
    transport.script(.serverList, [.result(try JSONValue(encoding: ServerList.Result(servers: [server])))])
    let model = WorkspaceModel(transportProvider: { transport }, accountSource: .coordinator)
    model.connect()
    let link = await model.settledLink()
    try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
    try #require(model.servers.map(\.id) == ["s1"])
    return model
  }

  @Test func removingIsForcedAndDropsTheProject() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(
      .serverRemove, [.result(try JSONValue(encoding: ServerRemove.Result(serverId: "s1")))])
    await model.removeServer(id: "s1")
    let call = try #require(transport.recorded(.serverRemove).first)
    #expect(call.params == ["serverId": "s1", "force": true])
    #expect(call.operationId != nil)
    #expect(model.servers.isEmpty)
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  @Test func aRefusedRemovalKeepsTheProjectAndSaysWhy() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.script(.serverRemove, [.failure(WorkspaceError(.ownedProcessConflict, "did not exit"))])
    await model.removeServer(id: "s1")
    #expect(model.servers.map(\.id) == ["s1"])
    #expect(model.lastError != nil)
    await model.disconnect()
  }

  @Test func aRemovalMadeElsewhereDropsTheProject() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    transport.emit(.serverRemoved(serverId: "s1"))
    try await waitUntil("the project goes") { model.servers.isEmpty }
    await model.disconnect()
  }

  @Test func theConfirmationSaysWhatStaysAndNamesARunningTurnOnlyWhenThereIsOne() async throws {
    let transport = ScriptedTransport()
    let model = try await Self.connected(transport)
    let asked = model.removeConfirmation(for: Self.server)
    #expect(asked.title == "Remove \"research\"?")
    #expect(asked.message.contains("Their threads stay"))
    #expect(!asked.message.contains("running turn"))
    await model.disconnect()
  }

  @Test func settingsListsOnlyEnabledConnections() async throws {
    let transport = ScriptedTransport()
    transport.set(connections: [
      Connection(id: "c1", kind: .codex, label: "Codex", target: ""),
      Connection(id: "c2", kind: .b4, label: "Chat @ research", enabled: false, target: ""),
    ])
    let model = try await Self.connected(transport)
    #expect(model.connections.count == 2)
    #expect(model.enabledConnections.map(\.id) == ["c1"])
    await model.disconnect()
  }
}
