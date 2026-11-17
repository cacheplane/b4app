import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

@testable import Coordinator

/// Earlier durable facts, never admission or a simulated successful legacy run.
/// Callers own the isolated coordinator/database and retain their normal shutdown.
enum HistoricalCoordinatorFixture {
  static func seedEarlierConnection(
    _ db: WorkspaceDatabase, id: String = "historical", label: String = "Cached B4",
    mode: B4Mode = .attachedLocal, serverId: String? = nil, authReference: String? = nil,
    environmentId: String? = nil, enabled: Bool = true
  ) throws -> Connection {
    let target = mode == .remote ? "https://history.example.invalid" : "http://127.0.0.1:9"
    return try db.insertConnection(
      Connection(
        id: id, kind: .b4, label: label, enabled: enabled,
        target: target, routeKey: "/chat#agent", b4Mode: mode,
        localServerId: serverId, authReference: authReference,
        nativeScope: target, environmentId: environmentId,
        status: .ready, authStatus: .notRequired))
  }

  static func seedDormantConnection(_ db: WorkspaceDatabase) throws -> Connection {
    try db.insertConnection(
      Connection(
        id: "dormant", kind: .agentProtocol, label: "Dormant canonical profile",
        target: "https://example.invalid/prefix",
        nativeScope: #"["agent-protocol-v1","agentProtocol","https://example.invalid/prefix"]"#,
        peerProfile: .agentProtocol, agentId: "fixture-agent", authMode: ConnectionAuthMode.none,
        status: .ready, authStatus: .notRequired))
  }

  /// Resolve the environment using the real actor before insertion, as older admission did.
  static func seedEarlierManagedConnection(
    _ h: ServerHarness, server: LocalServer, id: String = "historical"
  ) async throws -> Connection {
    var connection = Connection(
      id: id, kind: .b4, label: "Cached managed B4",
      target: "http://127.0.0.1:\(server.actualPort ?? server.requestedPort ?? 0)",
      routeKey: "/chat#agent", b4Mode: .managedLocal, localServerId: server.id,
      nativeScope: "historical-managed-scope", status: .ready, authStatus: .notRequired)
    connection.environmentId = try await h.coordinator.environments.environmentId(forConnection: connection)
    return try h.coordinator.database.insertConnection(connection)
  }

  struct Snapshot: Equatable, Sendable {
    let connection: Connection
    let thread: ConversationThread
    let turns: [Turn]
    let items: [DisplayItem]
    let requests: [RuntimeRequest]
    let draft: Draft?
  }

  static func snapshot(_ db: WorkspaceDatabase, threadId: String) throws -> Snapshot {
    let thread = try #require(try db.thread(id: threadId))
    return try Snapshot(
      connection: #require(try db.connection(id: thread.connectionId)), thread: thread,
      turns: db.turns(threadId: threadId), items: db.displayItems(threadId: threadId),
      requests: db.pendingRuntimeRequests(threadId: threadId), draft: db.draft(threadId: threadId))
  }

  static func seedEarlierConversation(
    _ db: WorkspaceDatabase, connection: Connection, id: String = "historical-thread",
    status: TurnStatus = .reconciling, pending: Bool = true
  ) throws -> Snapshot {
    let thread = try db.insertThread(
      ConversationThread(
        id: id, connectionId: connection.id, nativeThreadId: "thr_1",
        nativeScope: connection.nativeScope ?? connection.target,
        title: "Cached chat", context: connection.routeKey, environmentId: connection.environmentId))
    let turn = try db.insertTurn(
      Turn(
        id: "\(id)-turn", threadId: id, operationId: "\(id)-operation", nativeTurnId: "turn-1",
        status: status, submission: .unknown))
    _ = try db.upsertDisplayItem(
      threadId: id, turnId: turn.id, nativeItemId: "opaque-user", role: .user,
      type: "userMessage", payload: ["text": "Earlier prompt"], provenance: .cache)
    _ = try db.upsertDisplayItem(
      threadId: id, turnId: turn.id, nativeItemId: "opaque-partial", role: .assistant,
      type: "agentMessage", payload: ["text": "Available cached text"], provenance: .cache)
    if pending {
      _ = try db.insertRuntimeRequest(
        RuntimeRequest(
          id: "\(id)-request", nativeRequestId: "opaque-request-7", threadId: id, turnId: turn.id,
          adapterGeneration: 7, kind: .commandApproval,
          payload: ["request": ["command": "rm -rf tmp"]]))
    }
    _ = try db.saveDraft(threadId: thread.id, text: "Unsent historical draft")
    return try snapshot(db, threadId: id)
  }

  static func expectCutover(_ body: () async throws -> Void) async throws {
    do {
      try await body()
      Issue.record("Historical execution must refuse before side effects.")
    } catch let error as WorkspaceError {
      #expect(error.code == .unsupportedCapability)
      #expect(error.details?["reason"]?.stringValue == "agent_protocol_cutover")
    }
  }
}

/// Counts forbidden factory entry without affecting the production factory's current-kind behavior.
final class HistoricalFactoryWitness: Sendable {
  private let calls = Mutex(0)
  var count: Int { calls.withLock { $0 } }
  func makeFactory(
    base: @escaping SessionService.AdapterFactory = SessionService.defaultAdapterFactory
  ) -> SessionService.AdapterFactory {
    { connection, environment, version, secrets in
      if connection.kind == .b4 || connection.kind == .agentProtocol {
        self.calls.withLock { $0 += 1 }
        throw WorkspaceError(.internalError, "Unavailable fixture reached the factory.")
      }
      return try base(connection, environment, version, secrets)
    }
  }
}

actor FixtureCredentialStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  private(set) var reads = 0
  private(set) var removals = 0
  func put(_ ref: SecretRef, value: String) { values[ref] = value }
  func read(_ ref: SecretRef) -> String? { reads += 1; return values[ref] }
  func remove(_ ref: SecretRef) -> Bool { removals += 1; return values.removeValue(forKey: ref) != nil }
  func value(_ ref: SecretRef) -> String? { values[ref] }
}

/// Controlled current-kind adapter: only inspection/reconciliation paths are authorized by its tests.
/// Its state survives coordinator replacement; no production endpoint or protocol adapter is involved.
actor CurrentCoordinatorFixtureState {
  private(set) var inspections = 0
  private(set) var submissions: [TurnInput] = []
  private(set) var reconciled: [String] = []
  var completed = false
  let incompatible: Bool
  init(incompatible: Bool = false) { self.incompatible = incompatible }
  func inspect() -> ConnectionInspection {
    inspections += 1
    return ConnectionInspection(
      status: incompatible ? .incompatible : .offline,
      error: WorkspaceError(
        incompatible ? .unsupportedCapability : .endpointUnavailable, "Fixture inspection"))
  }
  func submit(_ input: TurnInput) -> SubmissionReceipt {
    submissions.append(input)
    return SubmissionReceipt(nativeTurnId: "controlled-turn-1", acknowledged: true)
  }
  func finish() { completed = true }
  func reconcile(_ turn: ActiveTurnRef?) -> ActiveTurnOutcome {
    if let turn { reconciled.append(turn.nativeTurnId) }
    return completed && turn?.nativeTurnId == "controlled-turn-1" ? .known(.completed) : .unknown
  }
}

struct CurrentCoordinatorFixtureAdapter: AgentAdapter {
  let state: CurrentCoordinatorFixtureState
  var kind: ConnectionKind { .codex }
  func inspectConnection() async throws -> ConnectionInspection { await state.inspect() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    NativeSessionRef(nativeSessionId: "controlled-thread", nativeScope: "fixture-current")
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    SessionSnapshot(ref: ref, title: nil, items: [], activeTurn: nil, pendingRequests: [], truncated: false)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    await state.submit(input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    StopReceipt(confirmed: false, outcome: nil)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    throw WorkspaceError(.unsupportedCapability, "This fixture has no approval requests.")
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    ReconcileResult(snapshot: nil, activeTurnOutcome: await state.reconcile(turn))
  }
  func events() -> AsyncStream<AdapterEvent> { AsyncStream { $0.finish() } }
  func dispose() async {}
}
