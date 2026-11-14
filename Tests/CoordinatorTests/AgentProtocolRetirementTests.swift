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
@Suite(.serialized) struct AgentProtocolRetirementTests {
  private func setup(
    kind: ConnectionKind = .b4, cachedItem: Bool = true
  ) throws -> (
    WorkspaceDatabase, SessionService, RetirementFactoryCalls
  ) {
    let db = try AgentProtocolResourceFixture.database()
    var complete = false
    defer { if !complete { try? db.close() } }
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
    if cachedItem {
      _ = try db.upsertDisplayItem(
        threadId: "history", turnId: "unknown-turn", nativeItemId: "partial", role: .assistant,
        type: "agentMessage", payload: ["text": "Available cached text"], provenance: .cache)
    }
    let calls = RetirementFactoryCalls()
    let eventLog = EventLog()
    let secrets = MemorySecretStore()
    let root = AgentProtocolResourceFixture.temporaryDirectory + "a3-retirement-\(UUID())"
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
    complete = true
    return (db, service, calls)
  }

  private func withFixture(
    kind: ConnectionKind = .b4, cachedItem: Bool = true,
    _ body: @Sendable (WorkspaceDatabase, SessionService, RetirementFactoryCalls) async throws -> Void
  ) async throws {
    let (db, service, calls) = try setup(kind: kind, cachedItem: cachedItem)
    var failure: (any Error)?
    do { try await body(db, service, calls) } catch { failure = error }
    let closed = await Bounded.run(within: .seconds(5)) { await service.shutdown() }
    #expect(closed, "A3 SessionService fixture shutdown exceeded its bound.")
    do { try db.close() } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
  }

  @Test func cachedReadAndExplicitReconcileNeverReachALegacyAdapter() async throws {
    try await withFixture { (db, service, calls) async throws in
      let result = try await service.threadRead(.init(threadId: "history"))
      #expect(result.items.first?.payload["text"]?.stringValue == "Available cached text")
      _ = try? await service.threadReconcile(.init(threadId: "history"))
      #expect(calls.value == 0)
      #expect(try db.turn(id: "unknown-turn")?.outcome == nil)
      #expect(try db.connection(id: "legacy")?.authReference == "secret:unchanged")
    }
  }

  @Test func missingCacheDoesNotProbeAnOldServer() async throws {
    try await withFixture(cachedItem: false) { (_, service, calls) async throws in
      let result = try await service.threadRead(.init(threadId: "history"))
      #expect(result.items.isEmpty)
      #expect(calls.value == 0)
      #expect(result.turns.first?.submission == .unknown)
    }
  }

  @Test func startupKeepsLegacyPendingPresentationAndUnknownOutcome() async throws {
    try await withFixture { (db, service, calls) async throws in
      await service.start()
      #expect(try db.runtimeRequest(id: "old-request")?.state == .pending)
      #expect(try db.turn(id: "unknown-turn")?.outcome == nil)
      #expect(try db.turn(id: "unknown-turn")?.submission == .unknown)
      #expect(calls.value == 0)
    }
  }

  @Test func oldAnswerAndSendCannotCreateAnAdapterOrNewTurn() async throws {
    try await withFixture { (db, service, calls) async throws in
      _ = try? await service.requestRespond(.init(requestId: "old-request", decline: true))
      _ = try? await service.turnSend(.init(threadId: "history", text: "never dispatch"), operationId: "new")
      _ = try? await service.turnInterrupt(.init(threadId: "history"))
      #expect(calls.value == 0)
      #expect(try db.turns(threadId: "history").map(\.id) == ["unknown-turn"])
      #expect(try db.runtimeRequest(id: "old-request")?.state == .pending)
    }
  }

  @Test func localDeleteDoesNotFabricateCancellationOrRetryTheOldNativeIdentity() async throws {
    try await withFixture { (db, service, calls) async throws in
      _ = try db.markThreadDeleted(id: "history", at: "deleted")
      await service.sweepThreadDeletes()
      await service.sweepThreadDeletes()
      #expect(calls.value == 0)
      // An explicit historical delete may legitimately purge local rows. Retained facts must remain
      // unknown/pending; this oracle forbids fabricated settlement, not physical retention forever.
      if let turn = try db.turn(id: "unknown-turn") {
        #expect(turn.status == .reconciling)
        #expect(turn.outcome == nil)
      }
      if let request = try db.runtimeRequest(id: "old-request") { #expect(request.state == .pending) }
      #expect(try db.threadDeleteAttempts(threadId: "history") <= 1)
    }
  }

  @Test func codexStartupStillExpiresItsProcessBoundRequests() async throws {
    try await withFixture(kind: .codex) { (db, service, calls) async throws in
      await service.start()
      #expect(try db.runtimeRequest(id: "old-request")?.state == .expired)
      #expect(try db.turn(id: "unknown-turn")?.outcome == nil)
      #expect(calls.value == 0)
    }
  }

  @Test func legacyAbandonKeepsUnknownHistoricalFacts() async throws {
    try await withFixture { (db, service, calls) async throws in
      let turn = try #require(try db.turn(id: "unknown-turn"))
      let request = try #require(try db.runtimeRequest(id: "old-request"))
      _ = try? await service.turnAbandon(.init(threadId: "history"))
      #expect(try db.turn(id: "unknown-turn") == turn)
      #expect(try db.runtimeRequest(id: "old-request") == request)
      #expect(calls.value == 0)
    }
  }

  @Test func retiredConnectionLabelEditKeepsItsCredentialAndHistory() async throws {
    try await withFixture { (db, service, calls) async throws in
      let before = try #require(try db.connection(id: "legacy"))
      let turn = try #require(try db.turn(id: "unknown-turn"))
      let request = try #require(try db.runtimeRequest(id: "old-request"))
      let result = try await service.connectionUpdate(
        .init(connectionId: "legacy", label: "  Renamed cached connection  "))
      #expect(result.connection.label == "Renamed cached connection")
      #expect(result.connection.authReference == before.authReference)
      #expect(result.connection.profileRevision == before.profileRevision + 1)
      #expect(try db.turn(id: "unknown-turn") == turn)
      #expect(try db.runtimeRequest(id: "old-request") == request)
      #expect(calls.value == 0)
    }
  }

  @Test func credentialEditRefusesBeforeChangingARetiredConnection() async throws {
    try await withFixture { (db, service, calls) async throws in
      _ = try db.updateTurn(id: "unknown-turn") { $0.status = .terminal }
      let before = try #require(try db.connection(id: "legacy"))
      let old = try #require(before.authReference.flatMap(SecretRef.init(rawValue:)))
      let replacement = SecretRef.make()
      let secrets = await service.context.secretStore
      try await secrets.put(old, value: "original fixture value")
      try await secrets.put(replacement, value: "replacement fixture value")
      do {
        _ = try await service.connectionUpdate(
          .init(connectionId: "legacy", label: "Replacement label", authReference: replacement.rawValue))
        Issue.record("A retired connection accepted a credential edit.")
      } catch let error as WorkspaceError {
        #expect(error.code == .unsupportedCapability)
        #expect(error.details?["reason"]?.stringValue == "agent_protocol_cutover")
      }
      #expect(try db.connection(id: "legacy") == before)
      #expect(try await secrets.read(old) == "original fixture value")
      #expect(try await secrets.read(replacement) == "replacement fixture value")
      #expect(calls.value == 0)
    }
  }

  @Test func clearCredentialRefusesBeforeChangingARetiredConnection() async throws {
    try await withFixture { (db, service, calls) async throws in
      _ = try db.updateTurn(id: "unknown-turn") { $0.status = .terminal }
      let before = try #require(try db.connection(id: "legacy"))
      let turn = try #require(try db.turn(id: "unknown-turn"))
      let request = try #require(try db.runtimeRequest(id: "old-request"))
      let old = try #require(before.authReference.flatMap(SecretRef.init(rawValue:)))
      let secrets = await service.context.secretStore
      try await secrets.put(old, value: "retained fixture value")
      do {
        _ = try await service.connectionUpdate(
          .init(connectionId: "legacy", label: "Must stay unchanged", clearAuth: true))
        Issue.record("A retired connection accepted credential removal.")
      } catch let error as WorkspaceError {
        #expect(error.code == .unsupportedCapability)
        #expect(error.details?["reason"]?.stringValue == "agent_protocol_cutover")
      }
      #expect(try db.connection(id: "legacy") == before)
      #expect(try db.turn(id: "unknown-turn") == turn)
      #expect(try db.runtimeRequest(id: "old-request") == request)
      #expect(try await secrets.read(old) == "retained fixture value")
      #expect(calls.value == 0)
    }
  }

  @Test func otherKindsRefuseCredentialChangesWithoutChangingFacts() async throws {
    for kind in [ConnectionKind.codex, .claude, .agentProtocol] {
      try await withFixture(kind: kind) { (db, service, calls) async throws in
        let before = try #require(try db.connection(id: "legacy"))
        let turn = try #require(try db.turn(id: "unknown-turn"))
        let request = try #require(try db.runtimeRequest(id: "old-request"))
        let old = try #require(before.authReference.flatMap(SecretRef.init(rawValue:)))
        let replacement = SecretRef.make()
        let secrets = await service.context.secretStore
        try await secrets.put(old, value: "retained other-kind fixture")
        try await secrets.put(replacement, value: "unused replacement fixture")
        for replace in [true, false] {
          let params: ConnectionUpdate.Params =
            replace
            ? .init(connectionId: "legacy", label: "Must stay unchanged", authReference: replacement.rawValue)
            : .init(connectionId: "legacy", label: "Must stay unchanged", clearAuth: true)
          do {
            _ = try await service.connectionUpdate(params)
            Issue.record("A connection without reference-based auth accepted credential input.")
          } catch let error as WorkspaceError {
            #expect(error.code == .protocolInvalid)
          }
          #expect(try db.connection(id: "legacy") == before)
          #expect(try db.turn(id: "unknown-turn") == turn)
          #expect(try db.runtimeRequest(id: "old-request") == request)
          #expect(try await secrets.read(old) == "retained other-kind fixture")
          #expect(try await secrets.read(replacement) == "unused replacement fixture")
          #expect(calls.value == 0)
        }
      }
    }
  }

  @Test func legacyConnectionEventKeepsHistoricalFacts() async throws {
    try await withFixture { (db, service, calls) async throws in
      let turn = try #require(try db.turn(id: "unknown-turn"))
      let request = try #require(try db.runtimeRequest(id: "old-request"))
      let connection = try #require(try db.connection(id: "legacy"))
      await service.environment(
        .connectionChanged(
          connectionId: "legacy", status: .offline, authStatus: .authenticated,
          transport: .disconnected, message: "Fixture managed-server disconnect"))
      #expect(try db.turn(id: "unknown-turn") == turn)
      #expect(try db.runtimeRequest(id: "old-request") == request)
      #expect(try db.connection(id: "legacy") == connection)
      #expect(calls.value == 0)
    }
  }

  @Test(arguments: [ConnectionKind.b4, .agentProtocol])
  func noFolderAdmissionRefusesBeforeAdaptersOrAppFolders(kind: ConnectionKind) async throws {
    try await withFixture(kind: kind) { (db, service, calls) async throws in
      let connection = try #require(try db.connection(id: "legacy"))
      let threads = try db.listThreads()
      let turn = try #require(try db.turn(id: "unknown-turn"))
      let request = try #require(try db.runtimeRequest(id: "old-request"))
      let environments = try db.listEnvironments()
      let folders = try db.listAppFolders()
      let environmentService = await service.context.environments
      let root = await environmentService.threadFoldersDir
      try #require(!FileManager.default.fileExists(atPath: root))

      func refused(_ body: () async throws -> Void) async throws {
        do {
          try await body()
          Issue.record("A historical or unavailable runtime admitted a no-folder conversation.")
        } catch let error as WorkspaceError {
          #expect(error.code == .unsupportedCapability)
          if kind == .b4 {
            #expect(error.details?["reason"]?.stringValue == "agent_protocol_cutover")
          } else {
            #expect(error.message == "Agent Protocol execution is not available in this build.")
          }
        }
      }

      try await refused {
        _ = try await service.threadCreate(.init(connectionId: "legacy"))
      }
      for fromAnotherDevice in [false, true] {
        try await refused {
          _ = try await service.threadStart(
            .init(
              threadId: UUID().uuidString.lowercased(), connectionId: "legacy", text: "never dispatch"),
            operationId: UUID().uuidString, fromAnotherDevice: fromAnotherDevice)
        }
      }
      #expect(calls.value == 0)
      #expect(!FileManager.default.fileExists(atPath: root))
      #expect(try db.listAppFolders() == folders)
      #expect(try db.listEnvironments() == environments)
      #expect(try db.listThreads() == threads)
      #expect(try db.connection(id: "legacy") == connection)
      #expect(try db.turn(id: "unknown-turn") == turn)
      #expect(try db.runtimeRequest(id: "old-request") == request)
    }
  }

  @Test func unavailableProtocolDeleteDoesNotInventASettledOutcome() async throws {
    try await withFixture(kind: .agentProtocol) { (db, service, calls) async throws in
      _ = try db.markThreadDeleted(id: "history", at: "deleted")
      await service.sweepThreadDeletes()
      await service.sweepThreadDeletes()
      #expect(calls.value == 0)
      if let turn = try db.turn(id: "unknown-turn") {
        #expect(turn.status == .reconciling)
        #expect(turn.outcome == nil)
      }
      if let request = try db.runtimeRequest(id: "old-request") {
        #expect(request.state == .pending)
      }
      #expect(try db.threadDeleteAttempts(threadId: "history") <= 1)
    }
  }
}
