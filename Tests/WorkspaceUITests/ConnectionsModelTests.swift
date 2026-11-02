import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceUI

/// A memory secret store that says how many values it holds.
actor CountingSecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  var count: Int { values.count }
  func put(_ ref: SecretRef, value: String) async throws { values[ref] = value }
  func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  func remove(_ ref: SecretRef) async throws -> Bool { values.removeValue(forKey: ref) != nil }
}

@Suite(.serialized) @MainActor struct ConnectionsModelTests {
  @Test func usageArrivesAfterACheck() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    let codex = try #require(
      await model.addConnection(kind: .codex, label: "Codex", executablePath: fakeCodex))
    try await waitUntil("usage") { model.usage[codex.id]?.reading?.fiveHour?.usedPercent == 62 }
    #expect(model.usage[codex.id]?.reading?.weekly?.usedPercent == 31)
    #expect(model.checks[codex.id] == nil)
  }

  @Test func addingB4WithAKeyStoresOnlyAReference() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    // Nothing listens on port 9: the connection is stored offline, which is enough to see what it keeps.
    let added = try #require(
      await model.addB4Connection(
        label: "Remote", url: "http://127.0.0.1:9", route: "/chat#agent", apiKey: "s3cret-value"))
    #expect(added.authReference?.hasPrefix("secret:") == true)
    #expect(!String(describing: model.connections).contains("s3cret-value"))
    #expect(model.connections.contains { $0.id == added.id })
  }

  @Test func renameUpdatesTheList() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    let codex = try #require(
      await model.addConnection(kind: .codex, label: "Codex", executablePath: fakeCodex))
    #expect(await model.updateConnection(id: codex.id, label: "Work Codex", apiKey: nil, clearKey: false))
    #expect(model.connections.first { $0.id == codex.id }?.label == "Work Codex")
  }

  @Test func checkProgressFollowsTheAttemptEvents() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    let event = AdapterEvent.connectionChanged(
      connectionId: "c", status: .connecting, authStatus: .unknown, transport: .disconnected, attempt: 2,
      attempts: 3)
    model.apply(event)
    #expect(model.checks["c"] == ConnectionCheck(attempt: 2, attempts: 3))
    model.apply(
      AdapterEvent.connectionChanged(
        connectionId: "c", status: .ready, authStatus: .authenticated, transport: .connected))
    #expect(model.checks["c"] == nil)
  }

  @Test func aBackgroundCheckLeavesTheModelFreeAndSkipsARecentOne() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    let codex = try #require(
      await model.addConnection(kind: .codex, label: "Codex", executablePath: fakeCodex))
    #expect(await model.checkInBackground(id: codex.id))
    #expect(model.busy == false)
    #expect(await model.checkInBackground(id: codex.id) == false)
  }

  @Test func aSnapshotClearsCheckProgress() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    model.apply(
      AdapterEvent.connectionChanged(
        connectionId: "c", status: .connecting, authStatus: .unknown, transport: .disconnected, attempt: 2,
        attempts: 3))
    #expect(model.checks["c"] != nil)
    try await model.refreshSnapshot()
    #expect(model.checks.isEmpty)
  }

  @Test func aFailedAddLeavesNoKeyBehind() async throws {
    let secrets = CountingSecretStore()
    let h = try await ModelHarness.start(secretStore: secrets)
    defer { Task { await h.stop() } }
    let model = h.model
    // "chat" is not a route key, so the add is refused after the key was stored.
    let added = await model.addB4Connection(
      label: "Bad", url: "http://127.0.0.1:9", route: "chat", apiKey: "k")
    #expect(added == nil)
    #expect(await secrets.count == 0)
  }

  @Test func aConnectionChangeWithTheConnectionUpdatesTheList() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    let codex = try #require(
      await model.addConnection(kind: .codex, label: "Codex", executablePath: fakeCodex))
    var renamed = codex
    renamed.label = "Renamed elsewhere"
    var event = AdapterEvent.connectionChanged(
      connectionId: codex.id, status: .ready, authStatus: .authenticated, transport: .disconnected)
    event.payload = .object(
      (event.payload.objectValue ?? [:]).merging(["connection": try JSONValue(encoding: renamed)]) { _, new in
        new
      })
    model.apply(event)
    #expect(model.connections.first { $0.id == codex.id }?.label == "Renamed elsewhere")
  }
}
