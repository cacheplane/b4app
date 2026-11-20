import Dispatch
import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

/// Finite test-fixture observation only. Parent markers are neither actor entry nor child joins.
/// Try-lock failures lose observations; even a false advisory drop flag cannot prove coverage/order.
final class InspectionObservation: Sendable {
  enum Phase: String, Sendable {
    case requestIssued, requestReturned, factoryEntered, factoryReturned
    case inspectionIssued, inspectionReturned, usageIssued, usageReturned
    case disposeIssued, disposeReturned
  }
  /// Labels the factory INPUT request; it does not inspect the returned adapter's kind.
  enum Kind: String, Sendable {
    case codex, claude, b4, agentProtocol
    init(_ kind: ConnectionKind) {
      switch kind {
      case .codex: self = .codex
      case .claude: self = .claude
      case .b4: self = .b4
      case .agentProtocol: self = .agentProtocol
      }
    }
  }
  enum ReturnShape: String, Sendable { case notSampled, returned, nilValue, threw }
  enum ErrorShape: String, Sendable { case notSampled, none, workspace, other }
  struct Record: Sendable {
    let phase: Phase
    let kind: Kind
    let harnessOrdinal: UInt16
    let adapterOrdinal: UInt16?
    let callOrdinal: UInt16?
    let elapsedNanoseconds: UInt64
    let threw: Bool
    let returnShape: ReturnShape
    let status: ConnectionStatus?
    let authStatus: AuthStatus?
    let errorShape: ErrorShape
    let errorCode: ErrorCode?
    let hasFiveHour: Bool?
    let hasWeekly: Bool?
    let hasPlanType: Bool?
  }
  enum Availability: String, Sendable { case available, lockUnavailable, alreadyAttempted }
  struct Snapshot: Sendable {
    let availability: Availability
    let records: [Record]
    /// Nil means the protected overflow flag could not be observed.
    let overflow: Bool?
    let contentionDropAdvisory: Bool
    let partial = true
    let joined = false

    /// Runs after copying and unlocking. Every interpolated value is a closed label or primitive.
    func formatted() -> String {
      let known = availability == .available
      let count = known ? String(records.count) : "unknown"
      let overflowLabel = overflow.map { String($0) } ?? "unknown"
      let unavailable = known ? "none" : availability.rawValue
      var lines = [
        "partial=true joined=false lateCallbacks=unknown unavailable=\(unavailable) recordCount=\(count) overflow=\(overflowLabel) contentionDropAdvisory=\(contentionDropAdvisory)"
      ]
      for record in records {
        let adapter = record.adapterOrdinal.map { String($0) } ?? "unavailable"
        let call = record.callOrdinal.map { String($0) } ?? "unavailable"
        let status = record.status?.rawValue ?? "unavailable"
        let auth = record.authStatus?.rawValue ?? "unavailable"
        let code = record.errorCode?.rawValue ?? "unavailable"
        let fiveHour = record.hasFiveHour.map { String($0) } ?? "unavailable"
        let weekly = record.hasWeekly.map { String($0) } ?? "unavailable"
        let plan = record.hasPlanType.map { String($0) } ?? "unavailable"
        lines.append(
          "phase=\(record.phase.rawValue) kind=\(record.kind.rawValue) harness=\(record.harnessOrdinal) adapter=\(adapter) call=\(call) elapsedNanoseconds=\(record.elapsedNanoseconds) threw=\(record.threw) returnShape=\(record.returnShape.rawValue) status=\(status) authStatus=\(auth) errorShape=\(record.errorShape.rawValue) errorCode=\(code) hasFiveHour=\(fiveHour) hasWeekly=\(weekly) hasPlanType=\(plan)"
        )
      }
      return lines.joined(separator: "\n")
    }
  }

  // Independent of parent records, ordinals, and the parent one-shot snapshot.
  let commandTiming = NarrowTimingObservation(.inspectionCommands)

  private static let capacity = 128
  private struct State: Sendable {
    var slots = [Record?](repeating: nil, count: InspectionObservation.capacity)
    var count = 0
    var overflow = false
    // 129 is the exhausted sentinel; neither allocator ever increments it or wraps.
    var nextAdapter: UInt16 = 1
    var nextCall: UInt16 = 1
  }
  private struct CopiedScalars: Sendable { let count: Int; let overflow: Bool }
  private let state = Mutex(State())
  private let contentionDrop = Atomic<Bool>(false)
  private let snapshotAttempted = Atomic<Bool>(false)
  private let clock: ContinuousClock
  private let origin: ContinuousClock.Instant

  init() {
    let clock = ContinuousClock()
    self.clock = clock
    origin = clock.now
  }

  func nextAdapterOrdinal() -> UInt16? {
    guard
      let ordinal = state.withLockIfAvailable({ protected -> UInt16? in
        guard protected.nextAdapter <= UInt16(Self.capacity) else {
          protected.overflow = true
          return nil
        }
        let ordinal = protected.nextAdapter
        protected.nextAdapter += 1
        return ordinal
      })
    else {
      contentionDrop.store(true, ordering: .relaxed)
      return nil
    }
    return ordinal
  }

  func nextCallOrdinal() -> UInt16? {
    guard
      let ordinal = state.withLockIfAvailable({ protected -> UInt16? in
        guard protected.nextCall <= UInt16(Self.capacity) else {
          protected.overflow = true
          return nil
        }
        let ordinal = protected.nextCall
        protected.nextCall += 1
        return ordinal
      })
    else {
      contentionDrop.store(true, ordering: .relaxed)
      return nil
    }
    return ordinal
  }

  func record(
    _ phase: Phase, kind: Kind, adapterOrdinal: UInt16? = nil, callOrdinal: UInt16? = nil,
    threw: Bool = false, returnShape: ReturnShape = .notSampled,
    status: ConnectionStatus? = nil, authStatus: AuthStatus? = nil,
    errorShape: ErrorShape = .notSampled, errorCode: ErrorCode? = nil,
    hasFiveHour: Bool? = nil, hasWeekly: Bool? = nil, hasPlanType: Bool? = nil
  ) {
    let record = Record(
      phase: phase, kind: kind, harnessOrdinal: 1,
      adapterOrdinal: Self.bounded(adapterOrdinal), callOrdinal: Self.bounded(callOrdinal),
      elapsedNanoseconds: Self.elapsedNanoseconds(origin.duration(to: clock.now)), threw: threw,
      returnShape: returnShape, status: status, authStatus: authStatus, errorShape: errorShape,
      errorCode: errorCode, hasFiveHour: hasFiveHour, hasWeekly: hasWeekly, hasPlanType: hasPlanType)
    let acquired =
      state.withLockIfAvailable { protected in
        if protected.count < Self.capacity {
          protected.slots[protected.count] = record
          protected.count += 1
        } else {
          protected.overflow = true
        }
        return true
      } ?? false
    if !acquired { contentionDrop.store(true, ordering: .relaxed) }
  }

  /// One API attempt per collector, no grace period, retries, cancellation, or join assumption.
  func snapshot() -> Snapshot {
    guard !snapshotAttempted.exchange(true, ordering: .relaxed) else {
      return unavailable(.alreadyAttempted)
    }
    // This distinct destination is allocated BEFORE trying the lock; live slots never escape.
    var destination = [Record?](repeating: nil, count: Self.capacity)
    let copied = state.withLockIfAvailable { protected in
      for index in 0..<protected.count { destination[index] = protected.slots[index] }
      return CopiedScalars(count: protected.count, overflow: protected.overflow)
    }
    guard let copied else {
      contentionDrop.store(true, ordering: .relaxed)
      return unavailable(.lockUnavailable)
    }
    // Compaction/allocation and all formatting happen outside the protected callback.
    let records = destination.prefix(copied.count).compactMap { $0 }
    return Snapshot(
      availability: .available, records: records, overflow: copied.overflow,
      contentionDropAdvisory: contentionDrop.load(ordering: .relaxed))
  }

  private func unavailable(_ availability: Availability) -> Snapshot {
    Snapshot(
      availability: availability, records: [], overflow: nil,
      contentionDropAdvisory: contentionDrop.load(ordering: .relaxed))
  }

  private static func bounded(_ ordinal: UInt16?) -> UInt16? {
    guard let ordinal, ordinal >= 1, ordinal <= UInt16(capacity) else { return nil }
    return ordinal
  }

  /// Parent elapsed time only: no child duration, timer-winner, or scheduling inference.
  static func elapsedNanoseconds(_ duration: Duration) -> UInt64 {
    guard duration > .zero else { return 0 }
    let components = duration.components
    var seconds = components.seconds
    var attoseconds = components.attoseconds
    if attoseconds < 0 {
      seconds -= 1
      attoseconds += 1_000_000_000_000_000_000
    }
    let (whole, multiplyOverflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
    if multiplyOverflow { return .max }
    let (total, addOverflow) = whole.addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
    return addOverflow ? .max : total
  }

  func makeObservedFactory(base: @escaping SessionService.AdapterFactory) -> SessionService.AdapterFactory {
    { connection, environment, version, secrets in
      let kind = Kind(connection.kind)
      let adapter = self.nextAdapterOrdinal()
      let call = self.nextCallOrdinal()
      self.record(.factoryEntered, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
      let inner: any AgentAdapter
      do {
        inner = try base(connection, environment, version, secrets)
      } catch {
        self.record(.factoryReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call, threw: true)
        throw error
      }
      self.record(.factoryReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
      let forwarding = InspectionForwarding(inner: inner, observation: self, kind: kind, adapter: adapter)
      // All optional references come from this exact result, independently of runtime kind.
      let login = inner as? any LoginCapable
      let usage = inner as? any UsageReporting
      let commands = inner as? any CommandListing
      switch (login, usage, commands) {
      case (nil, nil, nil): return InspectionPlainAdapter(forwarding: forwarding)
      case (let login?, nil, nil): return InspectionLoginAdapter(forwarding: forwarding, login: login)
      case (nil, let usage?, nil): return InspectionUsageAdapter(forwarding: forwarding, usage: usage)
      case (let login?, let usage?, nil):
        return InspectionBothAdapter(forwarding: forwarding, login: login, usage: usage)
      case (nil, nil, let commands?):
        return InspectionCommandsAdapter(forwarding: forwarding, commands: commands)
      case (let login?, nil, let commands?):
        return InspectionLoginCommandsAdapter(forwarding: forwarding, login: login, commands: commands)
      case (nil, let usage?, let commands?):
        return InspectionUsageCommandsAdapter(forwarding: forwarding, usage: usage, commands: commands)
      case (let login?, let usage?, let commands?):
        return InspectionAllAdapter(
          forwarding: forwarding, login: login, usage: usage, commands: commands)
      }
    }
  }
}

private struct InspectionForwarding: Sendable {
  let inner: any AgentAdapter
  let observation: InspectionObservation
  let kind: InspectionObservation.Kind
  let adapter: UInt16?

  func inspectConnection() async throws -> ConnectionInspection {
    let call = observation.nextCallOrdinal()
    observation.record(.inspectionIssued, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
    do {
      let scope = observation.commandTiming.nextScopeOrdinal(
        adapterOrdinal: adapter, inspectionCallOrdinal: call)
      let core = scope.map { observation.commandTiming.commandObservation(scope: $0) }
      let result = try await CommandRunner.$coreObservation.withValue(core) {
        try await inner.inspectConnection()
      }
      observation.record(
        .inspectionReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call,
        returnShape: .returned, status: result.status, authStatus: result.authStatus,
        errorShape: result.error == nil ? .none : .workspace, errorCode: result.error?.code)
      return result
    } catch {
      observation.record(
        .inspectionReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call, threw: true,
        returnShape: .threw, errorShape: error is WorkspaceError ? .workspace : .other,
        errorCode: (error as? WorkspaceError)?.code)
      throw error
    }
  }
  func readUsage(_ usage: any UsageReporting) async throws -> UsageReading? {
    let call = observation.nextCallOrdinal()
    observation.record(.usageIssued, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
    do {
      let result = try await usage.readUsage()
      observation.record(
        .usageReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call,
        returnShape: result == nil ? .nilValue : .returned, errorShape: .none,
        hasFiveHour: result.map { $0.fiveHour != nil }, hasWeekly: result.map { $0.weekly != nil },
        hasPlanType: result.map { $0.planType != nil })
      return result
    } catch {
      observation.record(
        .usageReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call, threw: true,
        returnShape: .threw, errorShape: error is WorkspaceError ? .workspace : .other,
        errorCode: (error as? WorkspaceError)?.code)
      throw error
    }
  }
  func dispose() async {
    let call = observation.nextCallOrdinal()
    observation.record(.disposeIssued, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
    await inner.dispose()
    observation.record(.disposeReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
  }
}

private protocol InspectionAdapterForwarding: AgentAdapter {
  var forwarding: InspectionForwarding { get }
}
extension InspectionAdapterForwarding {
  var kind: ConnectionKind { forwarding.inner.kind }
  func inspectConnection() async throws -> ConnectionInspection { try await forwarding.inspectConnection() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef {
    try await forwarding.inner.createSession(input)
  }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot {
    try await forwarding.inner.loadSession(ref)
  }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    try await forwarding.inner.sendTurn(ref, input: input)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    try await forwarding.inner.interrupt(ref, turn: turn)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws {
    try await forwarding.inner.respond(ref, response: response)
  }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    try await forwarding.inner.reconcile(ref, turn: turn)
  }
  func events() -> AsyncStream<AdapterEvent> { forwarding.inner.events() }
  func dispose() async { await forwarding.dispose() }
  func deleteSession(_ ref: NativeSessionRef) async throws -> SessionDeletion {
    try await forwarding.inner.deleteSession(ref)
  }
}
private struct InspectionPlainAdapter: InspectionAdapterForwarding {
  let forwarding: InspectionForwarding
}
private struct InspectionLoginAdapter: InspectionAdapterForwarding, LoginCapable {
  let forwarding: InspectionForwarding
  let login: any LoginCapable
  func startLogin() async throws -> LoginStart { try await login.startLogin() }
}
private struct InspectionUsageAdapter: InspectionAdapterForwarding, UsageReporting {
  let forwarding: InspectionForwarding
  let usage: any UsageReporting
  func readUsage() async throws -> UsageReading? { try await forwarding.readUsage(usage) }
}
private struct InspectionBothAdapter: InspectionAdapterForwarding, LoginCapable, UsageReporting {
  let forwarding: InspectionForwarding
  let login: any LoginCapable
  let usage: any UsageReporting
  func startLogin() async throws -> LoginStart { try await login.startLogin() }
  func readUsage() async throws -> UsageReading? { try await forwarding.readUsage(usage) }
}

private struct InspectionCommandsAdapter: InspectionAdapterForwarding, CommandListing {
  let forwarding: InspectionForwarding
  let commands: any CommandListing
  func readCommands() async throws -> [RuntimeCommand] { try await commands.readCommands() }
}
private struct InspectionLoginCommandsAdapter: InspectionAdapterForwarding, LoginCapable, CommandListing {
  let forwarding: InspectionForwarding
  let login: any LoginCapable
  let commands: any CommandListing
  func startLogin() async throws -> LoginStart { try await login.startLogin() }
  func readCommands() async throws -> [RuntimeCommand] { try await commands.readCommands() }
}
private struct InspectionUsageCommandsAdapter: InspectionAdapterForwarding, UsageReporting, CommandListing {
  let forwarding: InspectionForwarding
  let usage: any UsageReporting
  let commands: any CommandListing
  func readUsage() async throws -> UsageReading? { try await forwarding.readUsage(usage) }
  func readCommands() async throws -> [RuntimeCommand] { try await commands.readCommands() }
}
private struct InspectionAllAdapter:
  InspectionAdapterForwarding, LoginCapable, UsageReporting, CommandListing
{
  let forwarding: InspectionForwarding
  let login: any LoginCapable
  let usage: any UsageReporting
  let commands: any CommandListing
  func startLogin() async throws -> LoginStart { try await login.startLogin() }
  func readUsage() async throws -> UsageReading? { try await forwarding.readUsage(usage) }
  func readCommands() async throws -> [RuntimeCommand] { try await commands.readCommands() }
}

/// Test-only first-observed boundaries, never evidence that every child reached that stage.
/// A missing sample is unknown, never proof of missing work.
/// Diagnostic state never waits for its lock; loss is advisory and never retried.
/// Finite synchronous reporting runs after unlocking and may perturb scheduling.
final class NativeTimingBoundary: Sendable {
  enum Role: String, Sendable {
    case a3CurrentFirstSignIn, mainTen, bufferedChildren, transportClosers, serverClosers, preservedTurn
  }
  enum CaseOrdinal: UInt8, Sendable { case first = 1, second = 2, third = 3 }
  enum Stage: String, CaseIterable, Hashable, Sendable {
    case issued, taskEntered, operationReturned, finished, observerEntered, observerReturned
    case clusterInitIssued, clusterInitReturned, clusterStatusIssued, clusterStatusReturned
    case clusterStartIssued, clusterStartReturned, clusterReadyReturned, bodyEntered, bodyReturned
    case fixtureIssued, fixtureReturned, signInIssued, signInTaskEntered, signInReturned
    case secretGateWaitIssued, secretGateWaitReturned, admissionChecksIssued, admissionChecksReturned
    case secretGateReleased, signInJoinIssued, signInJoinReturned
    case pushIssued, pushTaskEntered, pushReturned, pushGateWaitIssued, pushGateWaitReturned
    case claimChecksIssued, claimChecksReturned, pushGateReleased, pushJoinIssued, pushJoinReturned
    case acknowledgementChecksReturned, firstShutdownIssued, firstShutdownReturned
    case firstDrainReturned, reopenIssued, reopenStartIssued, reopenStartReturned
    case reopenChecksIssued, reopenChecksReturned, secondShutdownIssued, secondShutdownReturned
    case secondDrainReturned, bodyThrew, cleanupIssued, cleanupReturned, clusterFinishIssued
    case clusterFinishReturned, clusterFinishThrew
    case cleanupSignInJoinIssued, cleanupSignInJoinReturned, cleanupPushJoinIssued, cleanupPushJoinReturned
    case finishStatusIssued, finishStatusRunning, clientsDrainIssued, clientsDrainReturned
    case clientsDrainThrew, ownedStopIssued, ownedStopReturned, pathsRemoveIssued, pathsRemoveReturned
    case harnessIssued, harnessReturned, serverStartIssued, serverStartReturned
    case connectIssued, connectReturned, secondConnectIssued, secondConnectReturned
    case acceptIssued, acceptReturned, readerFinished, acceptFinished, existingCompletion
    case cleanupStarted, cleanupFinished, groupShutdownStarted, sourceFinished, listenerClosed
    case initialized, connectionDequeued, connectionFinished, handlerAdmitted, handlerFinished
    case gateWaitIssued, gateWaitReturned, secondGateWaitIssued, secondGateWaitReturned
    case closeIssued, closeTaskEntered, closeReturned, secondCloseIssued, secondCloseTaskEntered
    case secondCloseReturned, firstCancelled, gateReleased, closeJoinIssued, closeJoinReturned
    case secondCloseJoinIssued, secondCloseJoinReturned, finalCloseIssued, finalCloseReturned
    case cleanupGateReleased, cleanupCloseIssued, cleanupCloseReturned, peersCloseIssued
    case peersCloseReturned, harnessStopIssued, harnessStopReturned
    case connectionAddIssued, connectionAddReturned, threadIssued, threadReturned
    case requestIssued, requestTaskEntered, requestReturned, acceptanceWaitIssued, acceptanceWaitReturned
    case admissionWaitIssued, admissionWaitReturned, acknowledgementReleased
    case requestJoinIssued, requestJoinReturned, handlerWaitIssued, handlerWaitReturned
    case viewerCloseIssued, viewerCloseReturned, connectionWaitIssued, connectionWaitReturned
    case readIssued, readReturned, retryIssued, retryReturned, completeIssued, completeReturned
    case eventWaitIssued, eventWaitReturned, cleanupRequestJoinIssued, cleanupRequestJoinReturned
    case cleanupViewerCloseIssued, cleanupViewerCloseReturned
    case cleanupServerCloseIssued, cleanupServerCloseReturned
  }
  private let role: Role
  private let ordinal: CaseOrdinal
  private let origin = ContinuousClock.now
  private let seen = Mutex<Set<Stage>>([])
  private let contentionDrop = Atomic<Bool>(false)

  init(_ role: Role, caseOrdinal: CaseOrdinal = .first) {
    self.role = role
    ordinal = caseOrdinal
  }

  func record(_ stage: Stage, flag: Bool? = nil) {
    // Sample before acquiring diagnostic state. Printing occurs after unlocking.
    let elapsed = InspectionObservation.elapsedNanoseconds(origin.duration(to: ContinuousClock.now))
    guard let inserted = seen.withLockIfAvailable({ $0.insert(stage).inserted }) else {
      contentionDrop.store(true, ordering: .relaxed)
      return
    }
    guard inserted else { return }
    let flagLabel = flag.map { String($0) } ?? "unavailable"
    let drop = contentionDrop.load(ordering: .relaxed)
    print(
      "NATIVE_TIMING role=\(role.rawValue) caseOrdinal=\(ordinal.rawValue) stage=\(stage.rawValue) elapsedNanoseconds=\(elapsed) flag=\(flagLabel) partial=true joined=false lateCallbacks=unknown contentionDropAdvisory=\(drop)"
    )
  }
}

/// Value-typed optional test witness keeps existing trailing-closure predicates unambiguous.
struct NarrowTimingWitness: Sendable {
  let record: @Sendable (NarrowTimingObservation.Stage, Bool?) -> Void
  init(_ record: @escaping @Sendable (NarrowTimingObservation.Stage, Bool?) -> Void) {
    self.record = record
  }
}

/// Independent, preallocated diagnostic storage. No callback prints, waits, or observes an owner.
/// First samples only: contention, overflow, and inherited late work leave coverage unknown.
/// Enabling callbacks can perturb scheduling; callback entry is not physical thread quiescence.
final class NarrowTimingObservation: Sendable {
  enum Role: String, Sendable {
    case inspectionCommands, bufferedChildren, serverClosers, transportClosers
    case l2SecondFixture, peerBeforeAckCleanup
  }
  enum Stage: Int, Sendable {
    case commandCoreEntered, commandCoreExited
    case groupShutdownInvoked, groupShutdownCallbackEntered, groupShutdownAwaitReturned
    case clientCloseIssued, clientCloseReturned, coordinatorCloseIssued, coordinatorCloseReturned
    case actorSignInEntered, transitionAcquired, preflightEntered, preflightReturned
    case scopeDrainEntered, scopeDrainReturned, scopeCloseAwaitEntered
    case scopeCloseWorkEntered, scopeCloseWorkReturned, scopeCloseAwaitReturned
    case issued, taskEntered, operationReturned, finished
    case observationDeadline, resultBool, callerCancelled, normalReturn, sleepThrew, atDeadline
    // Append to preserve all legacy raw values used by the other fixed-capacity roles.
    case commandWorkEntered, commandWorkExited, commandTimerEntered, commandTimerExited
    case commandSelectedFinished, commandSelectedTimerReturned, commandSelectedWorkCancellationCaught
    case commandSelectedDefensiveNoOutcome
  }
  enum Availability: String, Sendable { case available, notArmed, lockUnavailable, alreadyAttempted }
  struct Scope: Sendable {
    let ordinal: UInt8
    let adapterOrdinal: UInt16?
    let inspectionCallOrdinal: UInt16?
  }
  struct Record: Sendable {
    let stage: Stage
    let scope: UInt8?
    let command: UInt8?
    let adapterOrdinal: UInt16?
    let inspectionCallOrdinal: UInt16?
    let elapsedNanoseconds: UInt64
    let flag: Bool?
  }
  struct Snapshot: Sendable {
    let role: Role
    let availability: Availability
    let scopes: [Scope]
    let records: [Record]
    let overflow: Bool?
    let contentionDropAdvisory: Bool

    func formatted() -> String {
      let count = availability == .available ? String(records.count) : "unknown"
      let scopeCount = availability == .available ? String(scopes.count) : "unknown"
      let overflowLabel = overflow.map { String($0) } ?? "unknown"
      var lines = [
        "NARROW_TIMING role=\(role.rawValue) partial=true joined=false lateCallbacks=unknown unavailable=\(availability.rawValue) recordCount=\(count) scopeCount=\(scopeCount) overflow=\(overflowLabel) contentionDropAdvisory=\(contentionDropAdvisory)"
      ]
      for scope in scopes {
        let adapter = scope.adapterOrdinal.map { String($0) } ?? "unavailable"
        let call = scope.inspectionCallOrdinal.map { String($0) } ?? "unavailable"
        lines.append(
          "scope=\(scope.ordinal) adapterOrdinal=\(adapter) inspectionCallOrdinal=\(call)")
      }
      for record in records {
        let scope = record.scope.map { String($0) } ?? "unavailable"
        let command = record.command.map { String($0) } ?? "unavailable"
        let adapter = record.adapterOrdinal.map { String($0) } ?? "unavailable"
        let call = record.inspectionCallOrdinal.map { String($0) } ?? "unavailable"
        let flag = record.flag.map { String($0) } ?? "unavailable"
        lines.append(
          "stage=\(record.stage.label) scope=\(scope) command=\(command) adapterOrdinal=\(adapter) inspectionCallOrdinal=\(call) elapsedNanoseconds=\(record.elapsedNanoseconds) flag=\(flag)"
        )
      }
      return lines.joined(separator: "\n")
    }
  }
  private struct State: Sendable {
    var slots: [Record?]
    var nextScope: UInt8 = 1
    var scopes = [Scope?](repeating: nil, count: 16)
    var nextCommand = [UInt8](repeating: 1, count: 16)
    var overflow = false
    init(capacity: Int) { slots = [Record?](repeating: nil, count: capacity) }
  }
  private static let commandStageCount = 10
  private let role: Role
  private let capacity: Int
  private let state: Mutex<State>
  private let origin = ContinuousClock.now
  private let armed: Atomic<Bool>
  private let armAttempted = Atomic<Bool>(false)
  private let contentionDrop = Atomic<Bool>(false)
  private let snapshotAttempted = Atomic<Bool>(false)

  init(_ role: Role) {
    self.role = role
    switch role {
    case .inspectionCommands: capacity = 16 * 8 * Self.commandStageCount
    case .bufferedChildren, .serverClosers, .transportClosers: capacity = 3
    case .l2SecondFixture: capacity = 32
    case .peerBeforeAckCleanup: capacity = 4
    }
    state = Mutex(State(capacity: capacity))
    armed = Atomic(role != .l2SecondFixture)
  }

  /// Used once immediately before the selected second-fixture begin; setup stays disarmed.
  @discardableResult func arm() -> Bool {
    guard role == .l2SecondFixture, !armAttempted.exchange(true, ordering: .relaxed) else {
      return false
    }
    guard
      let result = state.withLockIfAvailable({ _ in
        armed.store(true, ordering: .relaxed)
        return true
      })
    else {
      contentionDrop.store(true, ordering: .relaxed)
      return false
    }
    return result
  }

  func nextScopeOrdinal(
    adapterOrdinal: UInt16? = nil, inspectionCallOrdinal: UInt16? = nil
  ) -> UInt8? {
    guard role == .inspectionCommands else { return nil }
    guard
      let result = state.withLockIfAvailable({ protected -> UInt8? in
        guard protected.nextScope <= 16 else { protected.overflow = true; return nil }
        let value = protected.nextScope
        // Copy existing parent metadata once; this never consumes either parent allocator.
        protected.scopes[Int(value) - 1] = Scope(
          ordinal: value, adapterOrdinal: Self.boundedParent(adapterOrdinal),
          inspectionCallOrdinal: Self.boundedParent(inspectionCallOrdinal))
        protected.nextScope += 1  // 17 is a permanent exhausted sentinel.
        return value
      })
    else {
      contentionDrop.store(true, ordering: .relaxed)
      return nil
    }
    return result
  }

  private static func boundedParent(_ ordinal: UInt16?) -> UInt16? {
    guard let ordinal, ordinal >= 1, ordinal <= 128 else { return nil }
    return ordinal
  }

  private func nextCommandOrdinal(scope: UInt8) -> UInt8? {
    guard scope >= 1, scope <= 16 else { return nil }
    guard
      let result = state.withLockIfAvailable({ protected -> UInt8? in
        let index = Int(scope) - 1
        guard protected.nextCommand[index] <= 8 else { protected.overflow = true; return nil }
        let value = protected.nextCommand[index]
        protected.nextCommand[index] += 1  // 9 is permanent; scopes/ordinals are never reused.
        return value
      })
    else {
      contentionDrop.store(true, ordering: .relaxed)
      return nil
    }
    return result
  }

  func commandObservation(scope: UInt8) -> CommandRunner.CoreObservation {
    CommandRunner.CoreObservation(
      reserve: { self.nextCommandOrdinal(scope: scope) },
      record: { ordinal, stage in
        switch stage {
        case .commandCoreEntered: self.record(.commandCoreEntered, scope: scope, command: ordinal)
        case .commandCoreExited: self.record(.commandCoreExited, scope: scope, command: ordinal)
        case .commandWorkEntered: self.record(.commandWorkEntered, scope: scope, command: ordinal)
        case .commandWorkExited: self.record(.commandWorkExited, scope: scope, command: ordinal)
        case .commandTimerEntered: self.record(.commandTimerEntered, scope: scope, command: ordinal)
        case .commandTimerExited: self.record(.commandTimerExited, scope: scope, command: ordinal)
        case .commandSelectedFinished: self.record(.commandSelectedFinished, scope: scope, command: ordinal)
        case .commandSelectedTimerReturned:
          self.record(.commandSelectedTimerReturned, scope: scope, command: ordinal)
        case .commandSelectedWorkCancellationCaught:
          self.record(.commandSelectedWorkCancellationCaught, scope: scope, command: ordinal)
        case .commandSelectedDefensiveNoOutcome:
          self.record(.commandSelectedDefensiveNoOutcome, scope: scope, command: ordinal)
        }
      })
  }

  func record(_ stage: Stage, flag: Bool? = nil, scope: UInt8? = nil, command: UInt8? = nil) {
    guard armed.load(ordering: .relaxed) else { return }
    let elapsed = InspectionObservation.elapsedNanoseconds(origin.duration(to: ContinuousClock.now))
    let slot: Int?
    switch role {
    case .inspectionCommands:
      if let scope, let command, scope >= 1, scope <= 16, command >= 1, command <= 8,
        let commandSlot = stage.commandSlot
      {
        slot = ((Int(scope) - 1) * 8 + Int(command) - 1) * Self.commandStageCount + commandSlot
      } else {
        slot = nil
      }
    case .bufferedChildren, .serverClosers, .transportClosers:
      slot = (2...4).contains(stage.rawValue) ? stage.rawValue - 2 : nil
    case .peerBeforeAckCleanup:
      slot = (5...8).contains(stage.rawValue) ? stage.rawValue - 5 : nil
    case .l2SecondFixture:
      slot = (9...28).contains(stage.rawValue) ? stage.rawValue - 9 : nil
    }
    let acquired = state.withLockIfAvailable { protected in
      guard let slot else { protected.overflow = true; return }
      if protected.slots[slot] == nil {
        let parent: Scope?
        if role == .inspectionCommands, let scope, scope >= 1, scope <= 16 {
          parent = protected.scopes[Int(scope) - 1]
        } else {
          parent = nil
        }
        protected.slots[slot] = Record(
          stage: stage, scope: role == .inspectionCommands ? scope : nil,
          command: role == .inspectionCommands ? command : nil,
          adapterOrdinal: parent?.adapterOrdinal, inspectionCallOrdinal: parent?.inspectionCallOrdinal,
          elapsedNanoseconds: elapsed, flag: flag)
      }
    }
    if acquired == nil { contentionDrop.store(true, ordering: .relaxed) }
  }

  /// Maps only the ten admitted migration boundaries; all other phases are ignored.
  func recordMigration(_ phase: AccountMigrationPhase, flag: Bool?) {
    switch phase {
    case .actorSignInEntered: record(.actorSignInEntered, flag: flag)
    case .transitionAcquired: record(.transitionAcquired, flag: flag)
    case .preflightEntered: record(.preflightEntered, flag: flag)
    case .preflightReturned: record(.preflightReturned, flag: flag)
    case .scopeDrainEntered: record(.scopeDrainEntered, flag: flag)
    case .scopeDrainReturned: record(.scopeDrainReturned, flag: flag)
    case .scopeCloseAwaitEntered: record(.scopeCloseAwaitEntered, flag: flag)
    case .scopeCloseWorkEntered: record(.scopeCloseWorkEntered, flag: flag)
    case .scopeCloseWorkReturned: record(.scopeCloseWorkReturned, flag: flag)
    case .scopeCloseAwaitReturned: record(.scopeCloseAwaitReturned, flag: flag)
    case .poolDrainEntered, .poolDrainReturned, .targetOpenEntered, .targetOpenReturned: break
    }
  }

  func snapshot() -> Snapshot {
    guard !snapshotAttempted.exchange(true, ordering: .relaxed) else {
      return unavailable(.alreadyAttempted)
    }
    guard role != .l2SecondFixture || armed.load(ordering: .relaxed) else {
      return unavailable(.notArmed)
    }
    var destination = [Record?](repeating: nil, count: capacity)
    var scopeDestination = [Scope?](repeating: nil, count: 16)
    let overflow = state.withLockIfAvailable { protected in
      for index in 0..<capacity { destination[index] = protected.slots[index] }
      for index in 0..<16 { scopeDestination[index] = protected.scopes[index] }
      return protected.overflow
    }
    guard let overflow else {
      contentionDrop.store(true, ordering: .relaxed)
      return unavailable(.lockUnavailable)
    }
    return Snapshot(
      role: role, availability: .available, scopes: scopeDestination.compactMap { $0 },
      records: destination.compactMap { $0 }, overflow: overflow,
      contentionDropAdvisory: contentionDrop.load(ordering: .relaxed))
  }
  private func unavailable(_ availability: Availability) -> Snapshot {
    Snapshot(
      role: role, availability: availability, scopes: [], records: [], overflow: nil,
      contentionDropAdvisory: contentionDrop.load(ordering: .relaxed))
  }
  func emitAfterCleanup() { print(snapshot().formatted()) }

  /// Inert self-contention control only; does not block or create concurrent work.
  func exerciseContentionDropForTest() {
    state.withLock { _ in record(.commandCoreEntered, scope: 1, command: 1) }
  }

  /// Inert failed-arm control: one nonblocking arm attempt while diagnostic storage is held.
  func exerciseArmContentionForTest() -> Bool {
    state.withLock { _ in arm() }
  }
}

extension NarrowTimingObservation.Stage {
  fileprivate var commandSlot: Int? {
    switch self {
    case .commandCoreEntered: return 0
    case .commandCoreExited: return 1
    case .commandWorkEntered: return 2
    case .commandWorkExited: return 3
    case .commandTimerEntered: return 4
    case .commandTimerExited: return 5
    case .commandSelectedFinished: return 6
    case .commandSelectedTimerReturned: return 7
    case .commandSelectedWorkCancellationCaught: return 8
    case .commandSelectedDefensiveNoOutcome: return 9
    default: return nil
    }
  }

  fileprivate var label: String {
    switch self {
    case .commandCoreEntered: return "commandCoreEntered"
    case .commandCoreExited: return "commandCoreExited"
    case .commandWorkEntered: return "commandWorkEntered"
    case .commandWorkExited: return "commandWorkExited"
    case .commandTimerEntered: return "commandTimerEntered"
    case .commandTimerExited: return "commandTimerExited"
    case .commandSelectedFinished: return "commandSelectedFinished"
    case .commandSelectedTimerReturned: return "commandSelectedTimerReturned"
    case .commandSelectedWorkCancellationCaught: return "commandSelectedWorkCancellationCaught"
    case .commandSelectedDefensiveNoOutcome: return "commandSelectedDefensiveNoOutcome"
    case .groupShutdownInvoked: return "groupShutdownInvoked"
    case .groupShutdownCallbackEntered: return "groupShutdownCallbackEntered"
    case .groupShutdownAwaitReturned: return "groupShutdownAwaitReturned"
    case .clientCloseIssued: return "clientCloseIssued"
    case .clientCloseReturned: return "clientCloseReturned"
    case .coordinatorCloseIssued: return "coordinatorCloseIssued"
    case .coordinatorCloseReturned: return "coordinatorCloseReturned"
    case .actorSignInEntered: return "actorSignInEntered"
    case .transitionAcquired: return "transitionAcquired"
    case .preflightEntered: return "preflightEntered"
    case .preflightReturned: return "preflightReturned"
    case .scopeDrainEntered: return "scopeDrainEntered"
    case .scopeDrainReturned: return "scopeDrainReturned"
    case .scopeCloseAwaitEntered: return "scopeCloseAwaitEntered"
    case .scopeCloseWorkEntered: return "scopeCloseWorkEntered"
    case .scopeCloseWorkReturned: return "scopeCloseWorkReturned"
    case .scopeCloseAwaitReturned: return "scopeCloseAwaitReturned"
    case .issued: return "issued"
    case .taskEntered: return "taskEntered"
    case .operationReturned: return "operationReturned"
    case .finished: return "finished"
    case .observationDeadline: return "observationDeadline"
    case .resultBool: return "resultBool"
    case .callerCancelled: return "callerCancelled"
    case .normalReturn: return "normalReturn"
    case .sleepThrew: return "sleepThrew"
    case .atDeadline: return "atDeadline"
    }
  }
}

/// Closed primitive observation of this preference queue only, not a thread or operation identity.
enum NativeDBCaseQueueWait: Equatable, Sendable {
  case none, overflow
  case value(Int64)

  static func classify(_ elapsed: Duration?) -> Self {
    guard let elapsed else { return .none }
    let components = elapsed.components
    guard components.seconds >= 0, components.attoseconds >= 0 else { return .none }
    let (whole, multiplyOverflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000)
    guard !multiplyOverflow else { return .overflow }
    let fraction = components.attoseconds / 1_000_000_000_000
    let (microseconds, addOverflow) = whole.addingReportingOverflow(fraction)
    guard !addOverflow else { return .overflow }
    return .value(microseconds)
  }

  static func maximum(_ lhs: Self, _ rhs: Self) -> Self {
    switch (lhs, rhs) {
    case (.overflow, _), (_, .overflow): return .overflow
    case (.value(let a), .value(let b)): return .value(max(a, b))
    case (.none, _): return rhs
    case (_, .none): return lhs
    }
  }

  var fieldValue: String {
    switch self {
    case .none: return "none"
    case .overflow: return "overflow"
    case .value(let microseconds): return String(microseconds)
    }
  }
}

struct NativeDBCaseQueueSnapshot: Sendable {
  enum Availability: String, Sendable { case unavailable, available }
  let availability: Availability
  let enqueueCount: UInt32
  let enqueueOverflow: Bool
  let firstWait: NativeDBCaseQueueWait
  let maxWait: NativeDBCaseQueueWait

  static let unavailable = Self(
    availability: .unavailable, enqueueCount: 0, enqueueOverflow: false,
    firstWait: .none, maxWait: .none)

  var enqueueCountField: String {
    availability == .available ? String(enqueueCount) : "none"
  }

  var enqueueOverflowField: String {
    availability == .available ? String(enqueueOverflow) : "none"
  }
}

enum NativeDBCaseExecutorScope {
  @TaskLocal static var current: NativeDBCaseExecutor? = nil
}

/// One concurrent resource per executing test case; actor isolation and runner ownership remain intact.
/// This is an executor preference, not a deadline or a join of unstructured descendants.
final class NativeDBCaseExecutor: TaskExecutor {
  private struct QueueState: Sendable {
    var enqueueCount: UInt32 = 0
    var enqueueOverflow = false
    var observedEntry = false
    var firstWait: NativeDBCaseQueueWait = .none
    var maxWait: NativeDBCaseQueueWait = .none
  }

  private let stats = Mutex(QueueState())
  private let queue = DispatchQueue(
    label: "b4app.tests.native-db-case", attributes: .concurrent)

  func snapshot() -> NativeDBCaseQueueSnapshot {
    stats.withLock {
      NativeDBCaseQueueSnapshot(
        availability: .available, enqueueCount: $0.enqueueCount,
        enqueueOverflow: $0.enqueueOverflow, firstWait: $0.firstWait, maxWait: $0.maxWait)
    }
  }

  func enqueue(_ job: consuming ExecutorJob) {
    stats.withLock {
      if $0.enqueueCount == UInt32.max {
        $0.enqueueOverflow = true
      } else {
        $0.enqueueCount += 1
      }
    }
    let job = UnownedJob(job)
    let enqueuedAt = ContinuousClock.now
    queue.async { [self] in
      let wait = NativeDBCaseQueueWait.classify(enqueuedAt.duration(to: ContinuousClock.now))
      stats.withLock {
        if !$0.observedEntry {
          $0.observedEntry = true
          $0.firstWait = wait
        }
        $0.maxWait = NativeDBCaseQueueWait.maximum($0.maxWait, wait)
      }
      // The statistics lock is released before the original job runs; no native work is enclosed.
      job.runSynchronously(on: asUnownedTaskExecutor())
    }
  }
}

struct NativeDBResources: TestTrait, SuiteTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @concurrent @Sendable () async throws -> Void
  ) async throws {
    // Everyday tests use Swift Testing's executor. Qualification observes native queue scheduling.
    guard ProcessInfo.processInfo.environment["B4APP_PROTOCOL_FULL_MATRIX"] == "1" else {
      try await function()
      return
    }
    let executor = NativeDBCaseExecutor()
    defer { withExtendedLifetime(executor) {} }
    try await withTaskExecutorPreference(executor) {
      try await NativeDBCaseExecutorScope.$current.withValue(executor) {
        try await function()
      }
    }
  }
}
