import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

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
    #expect(((inner as? any CommandListing) != nil) == mask.commands)
    #expect(((proxy as? any CommandListing) != nil) == mask.commands)
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

  @Test(
    arguments: ObservationMask.allCases.filter(\.commands), ObservationCommandMode.allCases)
  func commandsPreserveResultsOriginalErrorAndObservation(
    _ mask: ObservationMask, _ mode: ObservationCommandMode
  ) async throws {
    let facts = ObservationFacts()
    let failure = ObservationCommandError()
    let inner = mask.adapter(
      ObservationFakeCore(facts: facts), commandMode: mode, commandError: failure)
    let original = try #require(inner as? any ObservationCommandFake)
    let observation = InspectionObservation()
    let secrets = MemorySecretStore()
    let factory = observation.makeObservedFactory { connection, environment, version, suppliedSecrets in
      facts.record(
        .factory(connection, environment, version, (suppliedSecrets as? MemorySecretStore) === secrets))
      return inner
    }
    let connection = syntheticConnection()
    let proxy = try factory(connection, ["synthetic": "commands"], "commands-version", secrets)
    let commands = try #require(proxy as? any CommandListing)

    // The baseline is copied before the command call. Each collector is snapshotted only once.
    let baseline = InspectionObservation()
    let baselineFactory = baseline.makeObservedFactory { _, _, _, _ in
      ObservationFakeCore(facts: ObservationFacts())
    }
    let baselineProxy = try baselineFactory(connection, [:], "synthetic", secrets)
    #expect(try await baselineProxy.inspectConnection() == ConnectionInspection(status: .ready))
    let before = baseline.snapshot()

    switch mode {
    case .value:
      #expect(try await commands.readCommands() == ObservationCommandControl.values)
    case .empty:
      #expect(try await commands.readCommands() == [])
    case .failure:
      do {
        _ = try await commands.readCommands()
        Issue.record("Expected the original command error")
      } catch {
        #expect((error as? ObservationCommandError) === failure)
      }
    }
    // A later observed call exposes any command-side ordinal allocation.
    #expect(try await proxy.inspectConnection() == ConnectionInspection(status: .ready))
    #expect(
      facts.snapshot() == [
        .factory(connection, ["synthetic": "commands"], "commands-version", true),
        .commands(ObjectIdentifier(original)), .inspection,
      ])
    let after = observation.snapshot()
    #expect(before.availability == .available && after.availability == .available)
    #expect(before.partial && !before.joined && after.partial && !after.joined)
    #expect(before.overflow == false && after.overflow == false)
    #expect(!before.contentionDropAdvisory && !after.contentionDropAdvisory)
    #expect(
      before.records.map(\.phase) == [
        .factoryEntered, .factoryReturned, .inspectionIssued, .inspectionReturned,
      ])
    #expect(after.records.map(\.phase) == before.records.map(\.phase))
    #expect(after.records.map(\.callOrdinal) == before.records.map(\.callOrdinal))
    #expect(after.records.map(\.callOrdinal) == [1, 1, 2, 2])
    #expect(after.records.map(\.adapterOrdinal) == before.records.map(\.adapterOrdinal))
    #expect(after.records.map(\.harnessOrdinal) == before.records.map(\.harnessOrdinal))
    #expect(after.records.map(\.kind) == before.records.map(\.kind))
    #expect(after.records.map(\.threw) == before.records.map(\.threw))
    #expect(after.records.map(\.returnShape) == before.records.map(\.returnShape))
    #expect(after.records.map(\.status) == before.records.map(\.status))
    #expect(after.records.map(\.authStatus) == before.records.map(\.authStatus))
    #expect(after.records.map(\.errorShape) == before.records.map(\.errorShape))
    #expect(after.records.map(\.errorCode) == before.records.map(\.errorCode))
    #expect(after.records.map(\.hasFiveHour) == before.records.map(\.hasFiveHour))
    #expect(after.records.map(\.hasWeekly) == before.records.map(\.hasWeekly))
    #expect(after.records.map(\.hasPlanType) == before.records.map(\.hasPlanType))
    // Elapsed parent time is intentionally not an equality oracle.
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
  case commandsOnly, loginAndCommands, usageAndCommands, all
  var login: Bool { self == .loginOnly || self == .both || self == .loginAndCommands || self == .all }
  var usage: Bool { self == .usageOnly || self == .both || self == .usageAndCommands || self == .all }
  var commands: Bool {
    self == .commandsOnly || self == .loginAndCommands || self == .usageAndCommands || self == .all
  }
  fileprivate func adapter(
    _ core: ObservationFakeCore, commandMode: ObservationCommandMode = .value,
    commandError: ObservationCommandError = ObservationCommandError()
  ) -> any AgentAdapter {
    let commands = ObservationCommandControl(facts: core.facts, mode: commandMode, failure: commandError)
    switch self {
    case .neither: return core
    case .loginOnly: return ObservationLoginFake(core: core)
    case .usageOnly: return ObservationUsageFake(core: core)
    case .both: return ObservationBothFake(core: core)
    case .commandsOnly: return ObservationCommandsOnlyFake(core: core, commands: commands)
    case .loginAndCommands: return ObservationLoginCommandsFake(core: core, commands: commands)
    case .usageAndCommands: return ObservationUsageCommandsFake(core: core, commands: commands)
    case .all: return ObservationAllFake(core: core, commands: commands)
    }
  }
}

private enum ObservationFact: Equatable, Sendable {
  case factory(Connection, [String: String], String, Bool)
  case kind, inspection, events, dispose, login, usage
  case commands(ObjectIdentifier)
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

enum ObservationCommandMode: CaseIterable, Sendable { case value, empty, failure }
private final class ObservationCommandError: Error {}

private struct ObservationCommandControl: Sendable {
  let facts: ObservationFacts
  let mode: ObservationCommandMode
  let failure: ObservationCommandError
  static let values = [
    RuntimeCommand(
      name: "synthetic-second", description: "Second sentinel", argumentHint: "<second>",
      aliases: ["second-alias", "s2"]),
    RuntimeCommand(name: "synthetic-first", description: "First sentinel"),
  ]
  func result(from original: any ObservationCommandFake) throws -> [RuntimeCommand] {
    facts.record(.commands(ObjectIdentifier(original)))
    switch mode {
    case .value: return Self.values
    case .empty: return []
    case .failure: throw failure
    }
  }
}

private protocol ObservationCommandFake: AnyObject, ObservationFakeForwarding, CommandListing {
  var commands: ObservationCommandControl { get }
}
extension ObservationCommandFake {
  func readCommands() async throws -> [RuntimeCommand] { try commands.result(from: self) }
}
private final class ObservationCommandsOnlyFake: ObservationCommandFake {
  let core: ObservationFakeCore
  let commands: ObservationCommandControl
  init(core: ObservationFakeCore, commands: ObservationCommandControl) {
    self.core = core
    self.commands = commands
  }
}
private final class ObservationLoginCommandsFake: ObservationCommandFake, LoginCapable {
  let core: ObservationFakeCore
  let commands: ObservationCommandControl
  init(core: ObservationFakeCore, commands: ObservationCommandControl) {
    self.core = core
    self.commands = commands
  }
  func startLogin() async throws -> LoginStart { try core.loginResult() }
}
private final class ObservationUsageCommandsFake: ObservationCommandFake, UsageReporting {
  let core: ObservationFakeCore
  let commands: ObservationCommandControl
  init(core: ObservationFakeCore, commands: ObservationCommandControl) {
    self.core = core
    self.commands = commands
  }
  func readUsage() async throws -> UsageReading? { try core.usageResult() }
}
private final class ObservationAllFake: ObservationCommandFake, LoginCapable, UsageReporting {
  let core: ObservationFakeCore
  let commands: ObservationCommandControl
  init(core: ObservationFakeCore, commands: ObservationCommandControl) {
    self.core = core
    self.commands = commands
  }
  func startLogin() async throws -> LoginStart { try core.loginResult() }
  func readUsage() async throws -> UsageReading? { try core.usageResult() }
}

/// Inert diagnostic controls only. They exercise no process, socket, account, or native fixture.
struct NarrowTimingObservationTests {
  @Test func commandBoundsSaturateWithoutReusingSlotsAndSnapshotIsOneShot() throws {
    let collector = NarrowTimingObservation(.inspectionCommands)
    for scope in UInt8(1)...16 {
      #expect(collector.nextScopeOrdinal() == scope)
      let observation = collector.commandObservation(scope: scope)
      for command in UInt8(1)...8 {
        #expect(observation.reserve() == command)
        observation.record(command, .commandCoreEntered)
        observation.record(command, .commandCoreExited)
      }
      #expect(observation.reserve() == nil)
      #expect(observation.reserve() == nil)
    }
    #expect(collector.nextScopeOrdinal() == nil)
    #expect(collector.nextScopeOrdinal() == nil)
    let first = collector.snapshot()
    #expect(first.availability == .available)
    #expect(first.overflow == true)
    #expect(first.records.count == 256)
    #expect(
      first.records.allSatisfy {
        ($0.scope.map { (1...16).contains($0) } ?? false)
          && ($0.command.map { (1...8).contains($0) } ?? false)
      })
    collector.record(.commandCoreEntered, scope: 1, command: 1)
    #expect(first.records.count == 256)
    let second = collector.snapshot()
    #expect(second.availability == .alreadyAttempted)
    #expect(second.records.isEmpty && second.overflow == nil)
  }

  @Test func firstStageSlotsRemainIndependentOfParentAndDropIsAdvisory() {
    let parent = InspectionObservation()
    parent.record(.requestIssued, kind: .codex)
    let collector = parent.commandTiming
    collector.exerciseContentionDropForTest()
    let scope = collector.nextScopeOrdinal()
    #expect(scope == 1)
    collector.record(.commandCoreEntered, flag: true, scope: 1, command: 1)
    collector.record(.commandCoreEntered, flag: false, scope: 1, command: 1)
    let snapshot = collector.snapshot()
    #expect(snapshot.records.count == 1 && snapshot.records.first?.flag == true)
    #expect(snapshot.contentionDropAdvisory)
    #expect(snapshot.overflow == false)
    #expect(parent.nextCallOrdinal() == 1 && parent.nextAdapterOrdinal() == 1)
    #expect(parent.snapshot().records.count == 1)
    let text = snapshot.formatted()
    #expect(text.contains("partial=true joined=false lateCallbacks=unknown"))
    #expect(text.contains("stage=commandCoreEntered scope=1 command=1"))
    let allowedKeys: Set<String> = [
      "role", "partial", "joined", "lateCallbacks", "unavailable", "recordCount", "overflow",
      "contentionDropAdvisory", "stage", "scope", "command", "elapsedNanoseconds", "flag",
      "scopeCount", "adapterOrdinal", "inspectionCallOrdinal",
    ]
    for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) where token.contains("=") {
      #expect(allowedKeys.contains(String(token.prefix { $0 != "=" })))
    }
  }

  @Test func overlappingCommandScopesKeepCopiedParentCorrelationWithoutParentAllocation() throws {
    let parent = InspectionObservation()
    let firstAdapter = try #require(parent.nextAdapterOrdinal())
    let firstCall = try #require(parent.nextCallOrdinal())
    let secondAdapter = try #require(parent.nextAdapterOrdinal())
    let secondCall = try #require(parent.nextCallOrdinal())
    let collector = parent.commandTiming
    let first = try #require(
      collector.nextScopeOrdinal(
        adapterOrdinal: firstAdapter, inspectionCallOrdinal: firstCall))
    let firstCore = collector.commandObservation(scope: first)
    let firstCommand = try #require(firstCore.reserve())
    firstCore.record(firstCommand, .commandCoreEntered)
    let second = try #require(
      collector.nextScopeOrdinal(
        adapterOrdinal: secondAdapter, inspectionCallOrdinal: secondCall))
    let secondCore = collector.commandObservation(scope: second)
    let secondCommand = try #require(secondCore.reserve())
    secondCore.record(secondCommand, .commandCoreEntered)
    // Later scope reservations cannot retarget either in-flight command's parent metadata.
    let missingAdapter = try #require(
      collector.nextScopeOrdinal(
        inspectionCallOrdinal: firstCall))
    let missingCall = try #require(collector.nextScopeOrdinal(adapterOrdinal: secondAdapter))
    let outOfRange = try #require(
      collector.nextScopeOrdinal(
        adapterOrdinal: 0, inspectionCallOrdinal: 129))
    firstCore.record(firstCommand, .commandCoreExited)
    secondCore.record(secondCommand, .commandCoreExited)
    for scope in [missingAdapter, missingCall, outOfRange] {
      let core = collector.commandObservation(scope: scope)
      let command = try #require(core.reserve())
      core.record(command, .commandCoreEntered)
      core.record(command, .commandCoreExited)
    }
    let snapshot = collector.snapshot()
    #expect(snapshot.scopes.count == 5 && snapshot.records.count == 10)
    #expect(snapshot.overflow == false)
    for record in snapshot.records {
      let scope = try #require(record.scope)
      switch scope {
      case first:
        #expect(record.adapterOrdinal == firstAdapter && record.inspectionCallOrdinal == firstCall)
      case second:
        #expect(record.adapterOrdinal == secondAdapter && record.inspectionCallOrdinal == secondCall)
      case missingAdapter:
        #expect(record.adapterOrdinal == nil && record.inspectionCallOrdinal == firstCall)
      case missingCall:
        #expect(record.adapterOrdinal == secondAdapter && record.inspectionCallOrdinal == nil)
      case outOfRange:
        #expect(record.adapterOrdinal == nil && record.inspectionCallOrdinal == nil)
      default: Issue.record("Unexpected bounded command scope")
      }
    }
    #expect(snapshot.scopes.map(\.ordinal) == [first, second, missingAdapter, missingCall, outOfRange])
    #expect(snapshot.scopes.map(\.adapterOrdinal) == [firstAdapter, secondAdapter, nil, secondAdapter, nil])
    #expect(snapshot.scopes.map(\.inspectionCallOrdinal) == [firstCall, secondCall, firstCall, nil, nil])
    let text = snapshot.formatted()
    #expect(text.contains("scope=1 adapterOrdinal=1 inspectionCallOrdinal=1"))
    #expect(text.contains("scope=2 adapterOrdinal=2 inspectionCallOrdinal=2"))
    #expect(text.contains("scope=3 adapterOrdinal=unavailable inspectionCallOrdinal=1"))
    #expect(text.contains("scope=4 adapterOrdinal=2 inspectionCallOrdinal=unavailable"))
    #expect(text.contains("scope=5 adapterOrdinal=unavailable inspectionCallOrdinal=unavailable"))
    #expect(parent.nextAdapterOrdinal() == 3 && parent.nextCallOrdinal() == 3)
    #expect(parent.snapshot().records.isEmpty)
  }

  @Test func unarmedOrFailedArmIsUnavailableAndCannotRetryArming() {
    let neverArmed = NarrowTimingObservation(.l2SecondFixture)
    neverArmed.record(.issued)
    let never = neverArmed.snapshot()
    #expect(never.availability == .notArmed)
    #expect(never.records.isEmpty && never.scopes.isEmpty && never.overflow == nil)
    #expect(!never.contentionDropAdvisory)
    #expect(never.formatted().contains("unavailable=notArmed recordCount=unknown scopeCount=unknown"))
    #expect(never.formatted().contains("partial=true joined=false lateCallbacks=unknown"))
    #expect(neverArmed.snapshot().availability == .alreadyAttempted)

    let failedArm = NarrowTimingObservation(.l2SecondFixture)
    #expect(!failedArm.exerciseArmContentionForTest())
    #expect(!failedArm.arm())
    #expect(!failedArm.arm())
    failedArm.record(.issued)
    let failed = failedArm.snapshot()
    #expect(failed.availability == .notArmed)
    #expect(failed.records.isEmpty && failed.scopes.isEmpty && failed.overflow == nil)
    #expect(failed.contentionDropAdvisory)
    #expect(failed.formatted().contains("unavailable=notArmed recordCount=unknown scopeCount=unknown"))
    #expect(failed.formatted().contains("partial=true joined=false lateCallbacks=unknown"))
    #expect(failedArm.snapshot().availability == .alreadyAttempted)
  }

  @Test func l2IgnoresSetupAndUnselectedMigrationPhasesThenArmsOnlyOnce() {
    let collector = NarrowTimingObservation(.l2SecondFixture)
    collector.recordMigration(.actorSignInEntered, flag: false)
    #expect(collector.arm())
    #expect(!collector.arm())
    collector.recordMigration(.poolDrainEntered, flag: true)
    collector.recordMigration(.actorSignInEntered, flag: true)
    collector.record(.issued)
    let snapshot = collector.snapshot()
    #expect(snapshot.records.map(\.stage) == [.actorSignInEntered, .issued])
    #expect(snapshot.records.first?.flag == true)
    #expect(snapshot.records.allSatisfy { $0.scope == nil && $0.command == nil })
    #expect(snapshot.overflow == false)
  }

  @Test func fixedSocketAndPeerRolesRetainOnlyTheirFirstFiniteStages() {
    for role in [
      NarrowTimingObservation.Role.bufferedChildren, .serverClosers, .transportClosers,
    ] {
      let collector = NarrowTimingObservation(role)
      collector.record(.groupShutdownInvoked, flag: true)
      collector.record(.groupShutdownInvoked, flag: false)
      collector.record(.groupShutdownCallbackEntered)
      collector.record(.groupShutdownAwaitReturned)
      let snapshot = collector.snapshot()
      #expect(snapshot.records.count == 3 && snapshot.records.first?.flag == true)
      #expect(snapshot.overflow == false)
      #expect(snapshot.records.allSatisfy { $0.scope == nil && $0.command == nil })
    }
    let peer = NarrowTimingObservation(.peerBeforeAckCleanup)
    peer.record(.clientCloseIssued)
    peer.record(.clientCloseReturned)
    peer.record(.coordinatorCloseIssued)
    peer.record(.coordinatorCloseReturned)
    peer.record(.commandCoreEntered, scope: 255, command: 255)
    let snapshot = peer.snapshot()
    #expect(snapshot.records.count == 4 && snapshot.overflow == true)
    #expect(snapshot.records.allSatisfy { $0.scope == nil && $0.command == nil })
  }

  @Test func observedPreservesPredicateEvaluationCountWithNilAndPrimitiveCallback() async {
    var nilCalls = 0
    let plain = await AgentProtocolAccountMigrationTests.observed {
      nilCalls += 1
      return true
    }
    let collector = NarrowTimingObservation(.l2SecondFixture)
    collector.arm()
    var observedCalls = 0
    let observed = await AgentProtocolAccountMigrationTests.observed(
      observation: NarrowTimingWitness { collector.record($0, flag: $1) },
      {
        observedCalls += 1
        return true
      })
    #expect(plain && observed && nilCalls == 2 && observedCalls == 2)
    let snapshot = collector.snapshot()
    #expect(
      snapshot.records.map(\.stage) == [
        .observationDeadline, .resultBool, .callerCancelled, .normalReturn, .atDeadline,
      ])
    #expect(snapshot.records.first { $0.stage == .resultBool }?.flag == true)
    #expect(!snapshot.records.contains { $0.stage == .sleepThrew })
  }

  @Test func taskLocalScopesOnlyActualInspectionAndRestoresNil() async throws {
    #expect(CommandRunner.coreObservation == nil)
    let checks = NarrowScopeChecks()
    let parent = InspectionObservation()
    let factory = parent.makeObservedFactory { _, _, _, _ in
      checks.record(CommandRunner.coreObservation != nil)
      return NarrowScopeAdapter(checks: checks)
    }
    let proxy = try factory(syntheticConnection(), [:], "inert", MemorySecretStore())
    #expect(try await proxy.inspectConnection() == ConnectionInspection(status: .ready))
    let usage = try #require(proxy as? any UsageReporting)
    let commands = try #require(proxy as? any CommandListing)
    _ = try await usage.readUsage()
    _ = try await commands.readCommands()
    await proxy.dispose()
    #expect(checks.snapshot() == [false, true, false, false, false])
    #expect(CommandRunner.coreObservation == nil)
    let snapshot = parent.commandTiming.snapshot()
    #expect(snapshot.records.map(\.stage) == [.commandCoreEntered, .commandCoreExited])
    #expect(
      snapshot.records.allSatisfy {
        $0.scope == 1 && $0.command == 1 && $0.adapterOrdinal == 1 && $0.inspectionCallOrdinal == 2
      })
    #expect(snapshot.scopes.count == 1)
    #expect(snapshot.scopes.first?.adapterOrdinal == 1 && snapshot.scopes.first?.inspectionCallOrdinal == 2)
    #expect(parent.nextCallOrdinal() == 5 && parent.nextAdapterOrdinal() == 2)
  }
}

private final class NarrowScopeChecks: Sendable {
  private struct State: Sendable {
    var slots = [Bool?](repeating: nil, count: 5)
    var next = 0
  }
  private let state = Mutex(State())
  func record(_ value: Bool) {
    state.withLock {
      guard $0.next < 5 else { return }
      $0.slots[$0.next] = value
      $0.next += 1
    }
  }
  func snapshot() -> [Bool] {
    let slots = state.withLock { $0.slots }
    return slots.compactMap { $0 }
  }
}

/// Synthetic scope witness; production CommandRunner and all real integration controls stay intact.
private struct NarrowScopeAdapter: AgentAdapter, UsageReporting, CommandListing {
  let checks: NarrowScopeChecks
  var kind: ConnectionKind { .codex }
  func inspectConnection() async throws -> ConnectionInspection {
    let observation = CommandRunner.coreObservation
    checks.record(observation != nil)
    if let observation, let ordinal = observation.reserve() {
      observation.record(ordinal, .commandCoreEntered)
      observation.record(ordinal, .commandCoreExited)
    }
    return ConnectionInspection(status: .ready)
  }
  func readUsage() async throws -> UsageReading? {
    checks.record(CommandRunner.coreObservation != nil)
    return nil
  }
  func readCommands() async throws -> [RuntimeCommand] {
    checks.record(CommandRunner.coreObservation != nil)
    return []
  }
  func dispose() async { checks.record(CommandRunner.coreObservation != nil) }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    throw ObservationControlError.forwarded
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    throw ObservationControlError.forwarded
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    throw ObservationControlError.forwarded
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    throw ObservationControlError.forwarded
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    throw ObservationControlError.forwarded
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    throw ObservationControlError.forwarded
  }
  func events() -> AsyncStream<AdapterEvent> { AsyncStream { $0.finish() } }
  func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion { .deleted }
}
