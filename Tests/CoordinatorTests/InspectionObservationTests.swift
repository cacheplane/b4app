import Coordinator
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

/// Source-only controls: these exercise synthetic adapters, never a coordinator or native runtime.
struct InspectionObservationTests {
  @Test(.timeLimit(.minutes(1)), arguments: ObservationMask.allCases)
  func preservesCapabilitiesAndEveryCoreForward(_ mask: ObservationMask) async throws {
    let facts = ObservationFacts()
    let core = ObservationFakeCore(facts: facts)
    let inner = mask.adapter(core)
    let observation = InspectionObservation()
    let secrets = MemorySecretStore()
    let factory = observation.makeObservedFactory { connection, environment, version, suppliedSecrets in
      facts.record(
        .factory(connection, environment, version, (suppliedSecrets as? MemorySecretStore) === secrets))
      return inner
    }
    let connection = syntheticConnection()
    let proxy = try factory(connection, ["synthetic": "value"], "synthetic-version", secrets)

    #expect(((inner as? any LoginCapable) != nil) == mask.login)
    #expect(((proxy as? any LoginCapable) != nil) == mask.login)
    #expect(((inner as? any UsageReporting) != nil) == mask.usage)
    #expect(((proxy as? any UsageReporting) != nil) == mask.usage)
    #expect(proxy.kind == .codex)  // Deliberately differs from the factory input kind.
    #expect(try await proxy.inspectConnection() == ConnectionInspection(status: .ready))

    let session = NativeSessionRef(nativeSessionId: "synthetic-session", nativeScope: "synthetic-scope")
    let turn = ActiveTurnRef(nativeTurnId: "synthetic-turn")
    let input = NewSessionInput(workingDirectory: "synthetic-directory", routeKey: "synthetic-route")
    let turnInput = TurnInput(operationId: "synthetic-operation", text: "synthetic-text")
    let request = RuntimeRequestRef(
      nativeRequestId: "synthetic-request", kind: .userQuestion, adapterGeneration: 7)
    let response = RuntimeResponse.decline(reason: "synthetic-decline")
    await #expect(throws: ObservationControlError.forwarded) { try await proxy.createSession(input) }
    await #expect(throws: ObservationControlError.forwarded) { try await proxy.loadSession(session) }
    await #expect(throws: ObservationControlError.forwarded) {
      try await proxy.sendTurn(session, input: turnInput)
    }
    await #expect(throws: ObservationControlError.forwarded) {
      try await proxy.interrupt(session, turn: turn)
    }
    await #expect(throws: ObservationControlError.forwarded) {
      try await proxy.respond(request, response: response)
    }
    await #expect(throws: ObservationControlError.forwarded) {
      try await proxy.reconcile(session, turn: turn)
    }
    #expect(try await proxy.deleteSession(session) == .deleted)
    var iterator = proxy.events().makeAsyncIterator()
    #expect(await iterator.next() == ObservationFakeCore.event)
    #expect(await iterator.next() == nil)
    await proxy.dispose()
    if let login = proxy as? any LoginCapable {
      #expect(try await login.startLogin() == ObservationFakeCore.login)
    }
    if let usage = proxy as? any UsageReporting {
      #expect(try await usage.readUsage() == ObservationFakeCore.usage)
    }

    var expected: [ObservationFact] = [
      .factory(connection, ["synthetic": "value"], "synthetic-version", true), .kind, .inspection,
      .create(input), .load(session), .send(session, turnInput), .interrupt(session, turn),
      .respond(request, response), .reconcile(session, turn), .delete(session), .events, .dispose,
    ]
    if mask.login { expected.append(.login) }
    if mask.usage { expected.append(.usage) }
    #expect(facts.snapshot() == expected)
    let snapshot = observation.snapshot()
    #expect(snapshot.availability == .available)
    #expect(snapshot.partial && !snapshot.joined)
    #expect(
      snapshot.records.map(\.phase) == [
        .factoryEntered, .factoryReturned, .inspectionIssued, .inspectionReturned,
        .disposeIssued, .disposeReturned,
      ] + (mask.usage ? [.usageIssued, .usageReturned] : []))
    #expect(snapshot.records.allSatisfy { !$0.threw })
    // Marker kind labels the factory's input request, not a read of the inner adapter's kind.
    #expect(snapshot.records.allSatisfy { $0.kind == .claude })
    let adapterOrdinal = try #require(snapshot.records.first?.adapterOrdinal)
    #expect(snapshot.records.allSatisfy { $0.adapterOrdinal == adapterOrdinal })
    let harnessOrdinal = try #require(snapshot.records.first?.harnessOrdinal)
    #expect(snapshot.records.allSatisfy { $0.harnessOrdinal == harnessOrdinal })
    #expect(harnessOrdinal >= 1 && harnessOrdinal <= 128)
    var callOrdinals: [UInt16] = []
    try #require(snapshot.records.count.isMultiple(of: 2))
    for index in stride(from: 0, to: snapshot.records.count, by: 2) {
      let callOrdinal = try #require(snapshot.records[index].callOrdinal)
      #expect(snapshot.records[index + 1].callOrdinal == callOrdinal)
      callOrdinals.append(callOrdinal)
    }
    #expect(Set(callOrdinals).count == callOrdinals.count)
    // These local pairings do not associate a cached adapter call with an overlapping RPC.
  }

  @Test(arguments: [ObservationUsageMode.none, .failure])
  func optionalUsagePreservesNilAndOriginalError(_ mode: ObservationUsageMode) async throws {
    let facts = ObservationFacts()
    let core = ObservationFakeCore(facts: facts, usageMode: mode)
    let observation = InspectionObservation()
    let factory = observation.makeObservedFactory { _, _, _, _ in ObservationUsageFake(core: core) }
    let proxy = try factory(syntheticConnection(), [:], "synthetic", MemorySecretStore())
    let usage = try #require(proxy as? any UsageReporting)
    if mode == .none {
      #expect(try await usage.readUsage() == nil)
    } else {
      await #expect(throws: ObservationControlError.forwarded) { try await usage.readUsage() }
    }
    #expect(facts.snapshot() == [.usage])
    let snapshot = observation.snapshot()
    #expect(
      snapshot.records.map(\.phase) == [
        .factoryEntered, .factoryReturned, .usageIssued, .usageReturned,
      ])
    #expect(snapshot.records.last?.threw == (mode == .failure))
  }

  @Test func preservesInspectionAndLoginErrors() async throws {
    let facts = ObservationFacts()
    let core = ObservationFakeCore(facts: facts, failsInspectionAndLogin: true)
    let observation = InspectionObservation()
    let factory = observation.makeObservedFactory { _, _, _, _ in ObservationLoginFake(core: core) }
    let proxy = try factory(syntheticConnection(), [:], "synthetic", MemorySecretStore())
    await #expect(throws: ObservationControlError.forwarded) { try await proxy.inspectConnection() }
    let login = try #require(proxy as? any LoginCapable)
    await #expect(throws: ObservationControlError.forwarded) { try await login.startLogin() }
    #expect(facts.snapshot() == [.inspection, .login])
    let snapshot = observation.snapshot()
    #expect(
      snapshot.records.map(\.phase) == [
        .factoryEntered, .factoryReturned, .inspectionIssued, .inspectionReturned,
      ])
    #expect(snapshot.records.last?.threw == true)
  }

  @Test func preservesFactoryErrorWithOneBaseInvocation() {
    let facts = ObservationFacts()
    let observation = InspectionObservation()
    let secrets = MemorySecretStore()
    let factory = observation.makeObservedFactory { connection, environment, version, suppliedSecrets in
      facts.record(
        .factory(connection, environment, version, (suppliedSecrets as? MemorySecretStore) === secrets))
      throw ObservationControlError.forwarded
    }
    let connection = syntheticConnection()
    #expect(throws: ObservationControlError.forwarded) {
      try factory(connection, [:], "synthetic", secrets)
    }
    #expect(facts.snapshot() == [.factory(connection, [:], "synthetic", true)])
    let snapshot = observation.snapshot()
    #expect(snapshot.records.map(\.phase) == [.factoryEntered, .factoryReturned])
    #expect(snapshot.records.last?.threw == true)
  }

  @Test func fixedCapacity128DoesNotOverflow() {
    let observation = InspectionObservation()
    for _ in 0..<128 { observation.record(.requestIssued, kind: .codex) }
    let snapshot = observation.snapshot()
    #expect(snapshot.records.count == 128)
    #expect(snapshot.overflow == false)
  }

  @Test func fixedCapacityRetains128AndFlagsThe129th() {
    let observation = InspectionObservation()
    for _ in 0..<128 { observation.record(.requestIssued, kind: .codex) }
    observation.record(.requestReturned, kind: .claude, threw: true)
    let snapshot = observation.snapshot()
    #expect(snapshot.availability == .available)
    #expect(snapshot.records.count == 128)
    #expect(snapshot.overflow == true)
    #expect(snapshot.records.allSatisfy { $0.phase == .requestIssued && $0.kind == .codex })
    #expect(snapshot.partial && !snapshot.joined)
  }

  @Test func snapshotIsDetachedAndTheSecondAttemptIsUnavailable() {
    let observation = InspectionObservation()
    observation.record(.requestIssued, kind: .codex)
    let first = observation.snapshot()
    observation.record(.requestReturned, kind: .codex)
    #expect(first.records.map(\.phase) == [.requestIssued])
    #expect(first.overflow == false)
    let second = observation.snapshot()
    #expect(second.availability == .alreadyAttempted)
    #expect(second.overflow == nil)
    #expect(second.records.isEmpty)
    #expect(second.partial && !second.joined)
    #expect(second.formatted().contains("unavailable=alreadyAttempted"))
    #expect(second.formatted().contains("overflow=unknown"))
    #expect(second.formatted().contains("recordCount=unknown"))
  }

  @Test func boundedOrdinalsBecomeUnavailableWithoutWrapping() {
    let observation = InspectionObservation()
    for ordinal in UInt16(1)...UInt16(128) {
      #expect(observation.nextAdapterOrdinal() == ordinal)
      #expect(observation.nextCallOrdinal() == ordinal)
    }
    #expect(observation.nextAdapterOrdinal() == nil)
    #expect(observation.nextCallOrdinal() == nil)
    #expect(observation.nextAdapterOrdinal() == nil)
    let snapshot = observation.snapshot()
    #expect(snapshot.overflow == true)
    #expect(snapshot.records.isEmpty)
  }

  @Test func elapsedConversionSaturatesAndUsesPrimitiveUnits() {
    #expect(InspectionObservation.elapsedNanoseconds(.seconds(-1)) == 0)
    #expect(InspectionObservation.elapsedNanoseconds(.nanoseconds(1)) == 1)
    #expect(InspectionObservation.elapsedNanoseconds(.milliseconds(2)) == 2_000_000)
    #expect(InspectionObservation.elapsedNanoseconds(.seconds(Int64.max)) == UInt64.max)
  }

  @Test func formatterOnlyReportsFixedLabelsAndAlwaysUnknownCoverage() {
    let observation = InspectionObservation()
    observation.record(.requestIssued, kind: .agentProtocol)
    let snapshot = observation.snapshot()
    let text = snapshot.formatted()
    #expect(text.contains("partial=true joined=false"))
    #expect(text.contains("lateCallbacks=unknown"))
    #expect(text.contains("contentionDropAdvisory="))
    #expect(text.contains("phase=requestIssued"))
    #expect(text.contains("kind=agentProtocol"))
    #expect(!text.contains("synthetic-session"))
    #expect(!text.contains("synthetic-directory"))
    #expect(!text.contains("synthetic-text"))
    // No contention test seam: false is advisory, never a coverage/order assertion.
  }
}

private func syntheticConnection() -> Connection {
  Connection(
    id: "synthetic-connection", kind: .claude, label: "synthetic-label", target: "synthetic-target",
    createdAt: "synthetic-created", updatedAt: "synthetic-updated")
}

private enum ObservationControlError: Error, Equatable { case forwarded }
enum ObservationUsageMode: Sendable, Equatable { case value, none, failure }
enum ObservationMask: CaseIterable, Sendable, Equatable {
  case neither, loginOnly, usageOnly, both
  var login: Bool { self == .loginOnly || self == .both }
  var usage: Bool { self == .usageOnly || self == .both }
  fileprivate func adapter(_ core: ObservationFakeCore) -> any AgentAdapter {
    switch self {
    case .neither: return core
    case .loginOnly: return ObservationLoginFake(core: core)
    case .usageOnly: return ObservationUsageFake(core: core)
    case .both: return ObservationBothFake(core: core)
    }
  }
}

private enum ObservationFact: Equatable, Sendable {
  case factory(Connection, [String: String], String, Bool)
  case kind, inspection, events, dispose, login, usage
  case create(NewSessionInput), load(NativeSessionRef), send(NativeSessionRef, TurnInput)
  case interrupt(NativeSessionRef, ActiveTurnRef), respond(RuntimeRequestRef, RuntimeResponse)
  case reconcile(NativeSessionRef, ActiveTurnRef?), delete(NativeSessionRef)
}

/// This fake's ordinary mutex may block; it is never called from the collector's lock callback.
private final class ObservationFacts: Sendable {
  private let facts = Mutex<[ObservationFact]>([])
  func record(_ fact: ObservationFact) { facts.withLock { $0.append(fact) } }
  func snapshot() -> [ObservationFact] { facts.withLock { $0 } }
}

private struct ObservationFakeCore: AgentAdapter {
  let facts: ObservationFacts
  let usageMode: ObservationUsageMode
  let failsInspectionAndLogin: Bool
  let stream: AsyncStream<AdapterEvent>
  static let event = AdapterEvent(
    kind: .connectionChanged, connectionId: "synthetic-event", at: "synthetic-time")
  static let login = LoginStart(authUrl: "synthetic-url", loginId: "synthetic-login")
  static let usage = UsageReading(fiveHour: UsageWindow(usedPercent: 17), observedAt: "synthetic-time")

  init(
    facts: ObservationFacts, usageMode: ObservationUsageMode = .value,
    failsInspectionAndLogin: Bool = false
  ) {
    self.facts = facts
    self.usageMode = usageMode
    self.failsInspectionAndLogin = failsInspectionAndLogin
    stream = AsyncStream { continuation in
      continuation.yield(Self.event)
      continuation.finish()
    }
  }
  var kind: ConnectionKind { facts.record(.kind); return .codex }
  func inspectConnection() async throws -> ConnectionInspection {
    facts.record(.inspection)
    if failsInspectionAndLogin { throw ObservationControlError.forwarded }
    return ConnectionInspection(status: .ready)
  }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    facts.record(.create(input)); throw ObservationControlError.forwarded
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    facts.record(.load(ref)); throw ObservationControlError.forwarded
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    facts.record(.send(ref, input)); throw ObservationControlError.forwarded
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    facts.record(.interrupt(ref, turn)); throw ObservationControlError.forwarded
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    facts.record(.respond(ref, response)); throw ObservationControlError.forwarded
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    facts.record(.reconcile(ref, turn)); throw ObservationControlError.forwarded
  }
  func events() -> AsyncStream<AdapterEvent> { facts.record(.events); return stream }
  func dispose() async { facts.record(.dispose) }
  func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion {
    facts.record(.delete(ref)); return .deleted
  }
  func loginResult() throws -> LoginStart {
    facts.record(.login)
    if failsInspectionAndLogin { throw ObservationControlError.forwarded }
    return Self.login
  }
  func usageResult() throws -> UsageReading? {
    facts.record(.usage)
    switch usageMode {
    case .value: return Self.usage
    case .none: return nil
    case .failure: throw ObservationControlError.forwarded
    }
  }
}

private protocol ObservationFakeForwarding: AgentAdapter { var core: ObservationFakeCore { get } }
extension ObservationFakeForwarding {
  var kind: ConnectionKind { core.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await core.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await core.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await core.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    try await core.sendTurn(ref, input: input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    try await core.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    try await core.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await core.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { core.events() }
  func dispose() async { await core.dispose() }
  func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion {
    try await core.deleteSession(ref)
  }
}
private struct ObservationLoginFake: ObservationFakeForwarding, LoginCapable {
  let core: ObservationFakeCore
  func startLogin() async throws -> LoginStart { try core.loginResult() }
}
private struct ObservationUsageFake: ObservationFakeForwarding, UsageReporting {
  let core: ObservationFakeCore
  func readUsage() async throws -> UsageReading? { try core.usageResult() }
}
private struct ObservationBothFake: ObservationFakeForwarding, LoginCapable, UsageReporting {
  let core: ObservationFakeCore
  func startLogin() async throws -> LoginStart { try core.loginResult() }
  func readUsage() async throws -> UsageReading? { try core.usageResult() }
}
