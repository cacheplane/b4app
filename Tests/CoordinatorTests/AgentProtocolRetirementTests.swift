import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

private final class RetirementFactoryCalls: Sendable {
  private let count = Mutex(0)
  func record() { count.withLock { $0 += 1 } }
  var value: Int { count.withLock { $0 } }
}

/// A throwing factory counts admission without opening any upstream socket or starting a runtime.
/// The assertions concern which business actions are allowed, rather than a particular guard method.
@Suite struct AgentProtocolRetirementTests {
  private func setup(
    kind: ConnectionKind
  ) throws -> (
    WorkspaceDatabase, SessionService, RetirementFactoryCalls
  ) {
    let db = try WorkspaceDatabase.temporary()
    let nativeScope =
      kind == .agentProtocol
      ? #"["agent-protocol-v1","agentProtocol","https://example.invalid/prefix"]"#
      : "https://example.invalid"
    _ = try db.insertConnection(
      Connection(
        id: "legacy", kind: kind, label: "Historical", target: "https://example.invalid/prefix",
        routeKey: kind == .agentProtocol ? nil : "/chat#agent",
        b4Mode: kind == .agentProtocol ? nil : .remote, authReference: "secret:unchanged",
        nativeScope: nativeScope, peerProfile: kind == .agentProtocol ? .agentProtocol : nil,
        agentId: kind == .agentProtocol ? "fixture-agent" : nil,
        authMode: kind == .agentProtocol ? .bearer : nil, status: .ready, authStatus: .authenticated))
    _ = try db.insertThread(
      ConversationThread(
        id: "history", connectionId: "legacy", nativeThreadId: "possibly-reused-thread",
        nativeScope: nativeScope, title: "Cached history"))
    _ = try db.insertTurn(
      Turn(
        id: "unknown-turn", threadId: "history", operationId: "old-operation", nativeTurnId: "1",
        status: .reconciling, submission: .unknown))
    _ = try db.insertRuntimeRequest(
      RuntimeRequest(
        id: "old-request", nativeRequestId: "7", threadId: "history", turnId: "unknown-turn",
        adapterGeneration: 1, kind: .commandApproval, payload: ["command": "fixture-only"]))
    let calls = RetirementFactoryCalls()
    let eventLog = EventLog()
    let secrets = MemorySecretStore()
    let root = NSTemporaryDirectory() + "retirement-\(UUID())"
    let paths = PlatformPaths(runtimeDir: root + "/rt", dataDir: root + "/data")
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: paths, startedAt: "fixture", environment: [:], secretStore: secrets, eventLog: eventLog))
    let service = SessionService(
      context: .init(
        database: db, eventLog: eventLog, diagnostics: diagnostics, environment: [:],
        clientVersion: "fixture", secretStore: secrets,
        environments: EnvironmentService(
          database: db, eventLog: eventLog, threadFoldersDir: paths.threadFoldersDir),
        adapterFactory: { _, _, _, _ in
          calls.record()
          throw WorkspaceError(.internalError, "A retired profile reached the adapter factory")
        }, checkRetryDelays: [], threadDeleteSweep: .zero))
    return (db, service, calls)
  }

  private func withFixture(
    kind: ConnectionKind,
    _ body: @Sendable (WorkspaceDatabase, SessionService, RetirementFactoryCalls) async throws -> Void
  ) async throws {
    let (db, service, calls) = try setup(kind: kind)
    var failure: (any Error)?
    do { try await body(db, service, calls) } catch { failure = error }
    await service.shutdown()
    do { try db.close() } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
  }

  @Test(arguments: [ConnectionKind.b4, .agentProtocol])
  func startupAndLateRuntimeEventsPreserveHistoricalOpenWork(kind: ConnectionKind) async throws {
    try await withFixture(kind: kind) { (db, service, calls) async throws in
      let turn = try #require(try db.updateTurn(id: "unknown-turn") { $0.openWork = 1 })
      let item = try db.upsertDisplayItem(
        threadId: "history", turnId: turn.id, nativeItemId: "old-agent", role: .tool,
        type: "toolUse", payload: ["agent": true, "title": "Earlier agent", "status": "inProgress"],
        provenance: .cache)
      let before = try HistoricalCoordinatorFixture.snapshot(db, threadId: "history")
      #expect(before.turns == [turn])
      #expect(turn.openWork == 1 && turn.outcome == nil && turn.submission == .unknown)
      #expect(before.items.contains(item))
      #expect(item.payload["agent"]?.boolValue == true && item.payload["status"]?.stringValue == "inProgress")
      #expect(before.requests.map(\.id) == ["old-request"] && before.requests.first?.state == .pending)

      await service.start()
      let startupClose = await service.pumps["open-work-close"]
      await startupClose?.value
      #expect(try HistoricalCoordinatorFixture.snapshot(db, threadId: "history") == before)

      await service.environment(
        AdapterEvent(
          kind: .toolCompleted, connectionId: "legacy",
          nativeIds: ["threadId": "possibly-reused-thread", "turnId": "1", "itemId": "old-agent"],
          payload: ["type": "toolUse", "role": "tool", "item": ["agent": true, "status": "completed"]]))
      #expect(try HistoricalCoordinatorFixture.snapshot(db, threadId: "history") == before)
      await service.environment(
        AdapterEvent(
          kind: .connectionChanged, connectionId: "legacy", nativeIds: ["threadId": "possibly-reused-thread"],
          payload: ["transport": "disconnected"]))
      #expect(try HistoricalCoordinatorFixture.snapshot(db, threadId: "history") == before)
      #expect(calls.value == 0)
    }
  }
}
