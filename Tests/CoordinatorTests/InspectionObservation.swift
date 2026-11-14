import Coordinator
import Synchronization
import WorkspaceProtocol

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
  struct Record: Sendable {
    let phase: Phase
    let kind: Kind
    let harnessOrdinal: UInt16
    let adapterOrdinal: UInt16?
    let callOrdinal: UInt16?
    let elapsedNanoseconds: UInt64
    let threw: Bool
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
        lines.append(
          "phase=\(record.phase.rawValue) kind=\(record.kind.rawValue) harness=\(record.harnessOrdinal) adapter=\(adapter) call=\(call) elapsedNanoseconds=\(record.elapsedNanoseconds) threw=\(record.threw)"
        )
      }
      return lines.joined(separator: "\n")
    }
  }

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
    threw: Bool = false
  ) {
    let record = Record(
      phase: phase, kind: kind, harnessOrdinal: 1,
      adapterOrdinal: Self.bounded(adapterOrdinal), callOrdinal: Self.bounded(callOrdinal),
      elapsedNanoseconds: Self.elapsedNanoseconds(origin.duration(to: clock.now)), threw: threw)
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
      // Both optional references come from this exact result, independently of runtime kind.
      let login = inner as? any LoginCapable
      let usage = inner as? any UsageReporting
      switch (login, usage) {
      case (nil, nil): return InspectionPlainAdapter(forwarding: forwarding)
      case (let login?, nil): return InspectionLoginAdapter(forwarding: forwarding, login: login)
      case (nil, let usage?): return InspectionUsageAdapter(forwarding: forwarding, usage: usage)
      case (let login?, let usage?):
        return InspectionBothAdapter(forwarding: forwarding, login: login, usage: usage)
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
      let result = try await inner.inspectConnection()
      observation.record(.inspectionReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
      return result
    } catch {
      observation.record(
        .inspectionReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call, threw: true)
      throw error
    }
  }
  func readUsage(_ usage: any UsageReporting) async throws -> UsageReading? {
    let call = observation.nextCallOrdinal()
    observation.record(.usageIssued, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
    do {
      let result = try await usage.readUsage()
      observation.record(.usageReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call)
      return result
    } catch {
      observation.record(.usageReturned, kind: kind, adapterOrdinal: adapter, callOrdinal: call, threw: true)
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
