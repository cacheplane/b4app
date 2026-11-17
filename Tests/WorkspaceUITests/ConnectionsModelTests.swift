import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import WorkspaceUI

/// A memory secret store that says how many values it holds.
actor CountingSecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  var count: Int { values.count }
  private(set) var putCount = 0
  private(set) var removeCount = 0
  func put(_ ref: SecretRef, value: String) async throws {
    putCount += 1
    values[ref] = value
  }
  func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  func remove(_ ref: SecretRef) async throws -> Bool {
    removeCount += 1
    return values.removeValue(forKey: ref) != nil
  }
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

  @Test func addingHistoricalB4RefusesAndRemovesTheTemporaryKey() async throws {
    let secrets = CountingSecretStore()
    let h = try await ModelHarness.start(secretStore: secrets)
    var failure: (any Error)?
    do {
      let model = h.model
      let before = model.connections
      let added = await model.addB4Connection(
        label: "Remote", url: "https://example.invalid", route: "/chat#agent", apiKey: "fixture-only-key")
      let refused = added == nil
      #expect(refused)
      let connectionsRetained = model.connections == before
      #expect(connectionsRetained)
      #expect(model.lastFailure?.code == .unsupportedCapability)
      #expect(model.lastFailure?.details?["reason"] == "agent_protocol_cutover")
      #expect(model.lastError?.isEmpty == false)
      let retainsRawKey =
        String(describing: model.connections).contains("fixture-only-key")
        || (model.lastError?.contains("fixture-only-key") == true)
        || String(describing: model.lastFailure).contains("fixture-only-key")
      #expect(!retainsRawKey)
      #expect(await secrets.count == 0)
      #expect(await secrets.putCount == 1)
      #expect(await secrets.removeCount == 1)
      try await model.refreshSnapshot()
      let refreshedConnectionsRetained = model.connections == before
      #expect(refreshedConnectionsRetained)
    } catch { failure = error }
    await h.stop()
    if let failure { throw failure }
  }

  /// This witnesses only the model's credential/reference boundary. The stub refuses legacy admission.
  @Test func historicalAddSendsOnlyTheOpaqueReferenceAndKeepsTheCutoverFailure() async throws {
    let transport = ScriptedTransport()
    let model = try await Phone.macModel(transport)
    var failure: (any Error)?
    do {
      let reference = "secret:fixture-opaque-reference"
      transport.script(
        .credentialAdd,
        [
          .result(
            try JSONValue(
              encoding: CredentialAdd.Result(reference: reference, label: "Remote")))
        ])
      transport.script(.connectionAdd, [.failure(HistoricalActionFixture.cutover)])
      transport.script(
        .credentialRemove,
        [
          .result(
            try JSONValue(
              encoding: CredentialRemove.Result(removed: true)))
        ])
      let before = model.connections
      let added = await model.addB4Connection(
        label: "Remote", url: "https://example.invalid", route: "/chat#agent", apiKey: "fixture-only-key")
      let refused = added == nil
      #expect(refused)
      let connectionsRetained = model.connections == before
      #expect(connectionsRetained)
      #expect(transport.recorded(.credentialAdd).count == 1)
      let call = try #require(transport.recorded(.connectionAdd).first)
      let usesOpaqueReference = call.params["authReference"] == .string(reference)
      #expect(usesOpaqueReference)
      let referenceOnly = !String(describing: call.params).contains("fixture-only-key")
      #expect(referenceOnly)
      #expect(transport.recorded(.credentialRemove).count == 1)
      let removesTemporaryReference =
        transport.recorded(.credentialRemove).first?.params["reference"] == .string(reference)
      #expect(removesTemporaryReference)
      #expect(model.lastFailure?.code == .unsupportedCapability)
      #expect(model.lastFailure?.details?["reason"] == "agent_protocol_cutover")
    } catch { failure = error }
    await model.disconnect()
    if let failure { throw failure }
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
    // Cutover refusal precedes legacy route validation; the temporary key is still removed.
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

  @Test func aUsageEventWithTheWholeUsageReplacesIt() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    let usage = ConnectionUsage(connectionId: "c", tokens: TokenTotals(today: 7, week: 22))
    model.apply(
      AdapterEvent(kind: .usageChanged, connectionId: "c", payload: ["usage": try JSONValue(encoding: usage)])
    )
    #expect(model.usage["c"] == usage)
  }
}
