import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

private typealias H = AgentProtocolAccountMigrationTests

private final class L2Observation: Sendable {
  enum Case: String { case explicitRetry, retainedCurrent, oldCallbacks }
  enum Stage: String {
    case retryLeaseReady, retryFirstSignInCompletion, retrySecondSignInCompletion
    case retryReleasedSignInCompletion, currentLeaseReady, currentFirstSignInCompletion
    case currentAfterUpgradeSignInCompletion, currentReleasedSignInCompletion
    case callbacksMigrationLockObservation, callbacksReplacementSignInCompletion
    case callbacksDisposeEnteredObservation, callbacksNilSlotProfileObservation
    case callbacksDisposalSignInCompletion, callbacksDisposeCompletedObservation
  }
  private enum Outcome: String { case returned, observationTimeout, threw, returnedTrue, returnedFalse }
  private struct Record: Sendable {
    let stage: Stage
    let outcome: Outcome
  }
  private struct State: Sendable {
    var count = 0
    var overflow = false
    var first: Record?, second: Record?, third: Record?, fourth: Record?
    var fifth: Record?, sixth: Record?, seventh: Record?, eighth: Record?
  }
  private let testCase: Case
  private let state = Mutex(State())
  private let dropped = Atomic<Bool>(false)

  init(_ testCase: Case) { self.testCase = testCase }

  func call<T: Sendable>(
    _ stage: Stage, _ operation: () async throws -> T
  ) async rethrows -> T {
    do {
      let result = try await operation()
      capture(stage, .returned)
      return result
    } catch {
      if let failure = error as? H.SetupFailure, case .observationTimeout = failure {
        capture(stage, .observationTimeout)
      } else {
        capture(stage, .threw)
      }
      throw error
    }
  }

  func observed(_ stage: Stage, _ operation: () async -> Bool) async -> Bool {
    let result = await operation()
    capture(stage, result ? .returnedTrue : .returnedFalse)
    return result
  }

  private func capture(_ stage: Stage, _ outcome: Outcome) {
    let captured = state.withLockIfAvailable { state in
      guard state.count < 8 else {
        state.overflow = true
        return true
      }
      let record = Record(stage: stage, outcome: outcome)
      switch state.count {
      case 0: state.first = record
      case 1: state.second = record
      case 2: state.third = record
      case 3: state.fourth = record
      case 4: state.fifth = record
      case 5: state.sixth = record
      case 6: state.seventh = record
      default: state.eighth = record
      }
      state.count += 1
      return true
    }
    if captured == nil { dropped.store(true, ordering: .relaxed) }
  }

  func emitAfterFixtureCleanup(to sink: (String) -> Void = { print($0) }) {
    // Copy bounded primitive state out of the single try-lock before formatting or invoking a sink.
    let snapshot = state.withLockIfAvailable { $0 }
    let drop = dropped.load(ordering: .relaxed)
    let unavailable = snapshot == nil
    let overflow = snapshot?.overflow ?? false
    let partial = unavailable || overflow || drop
    if let snapshot {
      let records = [
        snapshot.first, snapshot.second, snapshot.third, snapshot.fourth,
        snapshot.fifth, snapshot.sixth, snapshot.seventh, snapshot.eighth,
      ]
      for record in records {
        if let record {
          sink(
            "A3_NATIVE_OBSERVATION case=\(testCase.rawValue) stage=\(record.stage.rawValue) outcome=\(record.outcome.rawValue)"
          )
        }
      }
    }
    sink(
      "A3_NATIVE_OBSERVATION case=\(testCase.rawValue) partial=\(partial) unavailable=\(unavailable) overflow=\(overflow) drop=\(drop)"
    )
  }
}

private final class L2RetryTiming: Sendable {
  enum Stage: String, Sendable {
    case leaseGuardDeadlineConstructed, leaseWaitReturned, leaseReadUnwound
    case firstRunIssued, firstCompletion, secondRunIssued, secondCompletion
  }
  enum Kind: String, Sendable {
    case none, released, timedOut, returned, threw
    case returnedSuccess, returnedFailure, observationTimeout
  }
  private struct Record: Sendable {
    let stage: Stage
    let kind: Kind
    let elapsedMilliseconds: Int64
  }
  private struct State: Sendable {
    var count = 0
    var overflow = false
    var first: Record?, second: Record?, third: Record?, fourth: Record?
    var fifth: Record?, sixth: Record?, seventh: Record?, eighth: Record?
  }
  private let start = ContinuousClock.now
  private let state = Mutex(State())
  private let dropped = Atomic<Bool>(false)

  private func elapsedMilliseconds() -> Int64 {
    let elapsed = start.duration(to: ContinuousClock.now)
    guard elapsed > .zero else { return 0 }
    let components = elapsed.components
    let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
    guard !seconds.overflow else { return .max }
    let milliseconds = seconds.partialValue.addingReportingOverflow(
      components.attoseconds / 1_000_000_000_000_000)
    guard !milliseconds.overflow else { return .max }
    return max(0, milliseconds.partialValue)
  }

  func record(_ stage: Stage, _ kind: Kind = .none) {
    // Sample before the single try-lock; insertion order need not be sample order.
    let elapsed = elapsedMilliseconds()
    let captured = state.withLockIfAvailable { state in
      guard state.count < 8 else {
        state.overflow = true
        return true
      }
      let record = Record(stage: stage, kind: kind, elapsedMilliseconds: elapsed)
      switch state.count {
      case 0: state.first = record
      case 1: state.second = record
      case 2: state.third = record
      case 3: state.fourth = record
      case 4: state.fifth = record
      case 5: state.sixth = record
      case 6: state.seventh = record
      default: state.eighth = record
      }
      state.count += 1
      return true
    }
    if captured == nil { dropped.store(true, ordering: .relaxed) }
  }

  func returned(_ stage: Stage, _ result: Result<AccountStatus.Result, any Error>) {
    switch result {
    case .success: record(stage, .returnedSuccess)
    case .failure: record(stage, .returnedFailure)
    }
  }

  func failed(_ stage: Stage, _ error: any Error) {
    if let failure = error as? H.SetupFailure, case .observationTimeout = failure {
      record(stage, .observationTimeout)
    } else {
      record(stage, .threw)
    }
  }

  func emitAfterFixtureCleanup(to sink: (String) -> Void = { print($0) }) {
    // Copy fixed primitive state, then release the try-lock before formatting or output.
    let snapshot = state.withLockIfAvailable { $0 }
    let drop = dropped.load(ordering: .relaxed)
    let unavailable = snapshot == nil
    let overflow = snapshot?.overflow ?? false
    if let snapshot {
      let records = [
        snapshot.first, snapshot.second, snapshot.third, snapshot.fourth,
        snapshot.fifth, snapshot.sixth, snapshot.seventh, snapshot.eighth,
      ]
      for record in records {
        if let record {
          sink(
            "A3_RETRY_TIMING stage=\(record.stage.rawValue) resultKind=\(record.kind.rawValue) elapsedMilliseconds=\(record.elapsedMilliseconds)"
          )
        }
      }
    }
    sink(
      "A3_RETRY_TIMING partialSnapshot=true unavailable=\(unavailable) overflow=\(overflow) drop=\(drop)"
    )
  }
}

/// Test continuation deliberately ignores cancellation. Every caller is released and actually joined.
private final class L2Delay: Sendable {
  private struct State {
    var entered = false
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())
  var entered: Bool { state.withLock { $0.entered } }
  func wait() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        state.entered = true
        if !state.released { state.waiters.append(continuation) }
        return state.released
      }
      if ready { continuation.resume() }
    }
  }
  func release() {
    let waiters = state.withLock { state in
      state.released = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}

private final class L2Factory: Sendable {
  let old = CommandHub()
  let fresh = CommandHub()
  private let calls = Mutex(0)
  var count: Int { calls.withLock { $0 } }
  func api(_ url: URL, token: @escaping @Sendable () async throws -> String?) -> any HubAPI {
    let first = calls.withLock { value in
      defer { value += 1 }; return value == 0
    }
    return (first ? old : fresh).api(url, token)
  }
  func configure() async throws {
    for hub in [old, fresh] {
      let session = H.session()
      await hub.fake.setSession(session)
      _ = try await hub.fake.passkeyFinish(
        .init(
          ceremonyId: "setup", assertion: nil, attestation: nil,
          device: .init(deviceName: "Fixture Mac", platform: "macos", deviceId: session.deviceId)))
    }
  }
}

private struct L2Lease: Sendable {
  let task: Task<Void, any Error>
  let entered: L1RunState
  let release: L1Release

  static func hold(
    _ database: WorkspaceDatabase, cleanup: L1Cleanup, seconds: Int = 60,
    retryTiming: L2RetryTiming? = nil
  ) -> Self {
    let semaphore = DispatchSemaphore(value: 0)
    let release = cleanup.release { semaphore.signal() }
    let entered = L1RunState()
    let task = Task.detached { [database] in
      try await H.onDedicatedLeaseThread {
        do {
          try database.read { _ in
            entered.finished.withLock { $0 = true }
            let deadline = DispatchTime.now() + .seconds(seconds)
            retryTiming?.record(.leaseGuardDeadlineConstructed)
            let released = semaphore.wait(timeout: deadline) == .success
            retryTiming?.record(.leaseWaitReturned, released ? .released : .timedOut)
            guard released else { throw H.SetupFailure.leaseGuardTimeout }
          }
          // The synchronous read has unwound; this does not mark native Thread exit.
          retryTiming?.record(.leaseReadUnwound, .returned)
        } catch {
          retryTiming?.record(.leaseReadUnwound, .threw)
          throw error
        }
      }
    }
    cleanup.join { _ = await task.result }
    return Self(task: task, entered: entered, release: release)
  }
  func ready() async throws {
    guard await H.observed({ entered.finished.withLock { $0 } }) else {
      throw H.SetupFailure.observationTimeout
    }
  }
  func finish() async throws { release.run(); try await task.value }
}

private enum L2 {
  static func signIn(
    _ manager: AccountManager, hubURL: String, session: AuthSession? = nil
  ) async
    -> Result<AccountStatus.Result, any Error>
  {
    do { return .success(try await manager.signIn(session: session ?? H.session(), hubURL: hubURL)) } catch {
      return .failure(error)
    }
  }
  static func joinedSignIn(
    _ manager: AccountManager, hubURL: String
  ) async throws
    -> Result<AccountStatus.Result, any Error>
  {
    let state = L1RunState()
    let task = Task { [manager] in
      defer { state.finished.withLock { $0 = true } }
      return await signIn(manager, hubURL: hubURL)
    }
    var observationFailure: (any Error)?
    do { _ = try await H.completed(.init(task: task, state: state)) } catch { observationFailure = error }
    let result = await task.value  // An expired observation is never treated as a join.
    if let observationFailure { throw observationFailure }
    return result
  }
  static func snapshotUnchanged(
    _ fixture: H.Fixture, expected: H.Snapshot? = nil, comment: Comment? = nil
  ) async throws {
    #expect(try H.snapshot(fixture.raw) == (expected ?? fixture.before), comment)
    #expect(try H.snapshot(fixture.registryRaw) == fixture.registryBefore, comment)
    #expect(await fixture.secrets.operations() == fixture.secretBefore, comment)
    #expect(try await fixture.secrets.read(fixture.accountRef) == H.accountValue, comment)
    #expect(try await fixture.secrets.read(fixture.endpointRef) == H.endpointValue, comment)
    #expect(!FileManager.default.fileExists(atPath: H.directory(fixture)), comment)
  }
  static func poolClosed(_ scope: AccountScope) -> Bool {
    H.refused(Result { try scope.database.read { try $0.execute("SELECT 1") } }, code: .endpointUnavailable)
  }
  static func noAutomaticOpen(
    _ fixture: H.Fixture, expected: H.Snapshot, registry: H.Snapshot,
    operations: L1Secrets.Operations
  ) async throws {
    // An actual owner roundtrip after joined work, followed by an explicitly finite quiet window.
    _ = await fixture.manager.status()
    let deadline = ContinuousClock.now + .seconds(1)
    var stayedClosed = true
    repeat {
      let noBackends = try fixture.raw.execute(
        "SELECT 1 FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
        [fixture.endpoint.database]
      ).rows.isEmpty
      if fixture.manager.current != nil || FileManager.default.fileExists(atPath: H.directory(fixture))
        || !noBackends
      {
        stayedClosed = false; break
      }
      try await Task.sleep(for: .milliseconds(50))
    } while ContinuousClock.now < deadline
    #expect(stayedClosed)
    #expect(try H.snapshot(fixture.raw) == expected)
    #expect(try H.snapshot(fixture.registryRaw) == registry)
    #expect(await fixture.secrets.operations() == operations)
  }
  static func rawCurrent(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    let c = try H.connection(endpoint)
    try Migrator.ensureLedger(c, table: Migrator.table)
    for file in try Migrator.files() {
      try c.execute(file.sql)
      try c.execute(
        #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,'fixture')"#, [file.name])
    }
    return c
  }
  static func externalUpgrade(_ fixture: H.Fixture) throws -> H.Snapshot {
    let files = try AgentProtocolFoundationFixture.knownFiles().filter {
      $0.name >= "0009_thread_runtime_choice"
    }
    try fixture.raw.execute("BEGIN")
    do {
      try fixture.raw.execute(
        "SELECT pg_advisory_xact_lock($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
      for file in files {
        try fixture.raw.execute(file.sql)
        try fixture.raw.execute(
          #"INSERT INTO "schemaMigrations" ("name","appliedAt") VALUES ($1,'external-fixture')"#, [file.name])
      }
      try fixture.raw.execute("COMMIT")
    } catch { _ = try? fixture.raw.execute("ROLLBACK"); throw error }
    guard
      try WorkspaceDatabase.preflightMigration(
        endpoint: fixture.endpoint, binDir: fixture.endpoint.binDir!) == .current
    else { throw H.SetupFailure.canonicalMismatch }
    return try H.snapshot(fixture.raw)
  }
}

/// Per-token in-memory actors prevent a legitimate B logout from revoking A's fake actor.
private final class L2Accounts: Sendable {
  private let fakes = Mutex<[String: FakeHubAPI]>([:])
  func add(_ session: AuthSession) async throws {
    let fake = FakeHubAPI()
    await fake.setSession(session)
    await fake.setUserId(session.userId)
    _ = try await fake.passkeyFinish(
      .init(
        ceremonyId: "fixture", assertion: nil, attestation: nil,
        device: .init(deviceName: "Fixture Mac", platform: "macos", deviceId: session.deviceId)))
    fakes.withLock { $0[session.token] = fake }
  }
  func fake(_ token: String?) throws -> FakeHubAPI {
    guard let token, let found = fakes.withLock({ $0[token] }) else {
      throw HubError(
        kind: "request_error", code: "unauthorized", message: "Fixture unauthorized.", status: 401)
    }
    return found
  }
  func api(_ token: @escaping @Sendable () async throws -> String?) -> any HubAPI {
    L2AccountAPI(owner: self, token: token)
  }
}
private struct L2AccountAPI: HubAPI {
  let owner: L2Accounts
  let token: @Sendable () async throws -> String?
  func fake() async throws -> FakeHubAPI { try owner.fake(try await token()) }
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    throw HubError(
      kind: "execution_error", code: "unsupported", message: "Fixture enroll is unsupported.", status: 0)
  }
  func me() async throws -> MeResponse { try await fake().me() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try await fake().push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await fake().pull(after: after, limit: limit, wait: wait)
  }
  func snapshot() async throws -> SnapshotResponse { try await fake().snapshot() }
  func devices() async throws -> [DeviceInfo] { try await fake().devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { try await fake().mintPairingCode() }
  func revokeSelf() async throws { try await fake().revokeSelf() }
  func endSession() async throws { try await fake().endSession() }
}

@Suite(.serialized) struct AgentProtocolAccountMigrationRetentionTests {
  @Test func explicitRetryMustRedrainHeldIdentity() async throws {
    let observation = L2Observation(.explicitRetry)
    let retryTiming = L2RetryTiming()
    defer {
      observation.emitAfterFixtureCleanup()
      retryTiming.emitAfterFixtureCleanup()
    }
    try await H.withFixture { fixture, cleanup in
      let lease = L2Lease.hold(fixture.scope.database, cleanup: cleanup, retryTiming: retryTiming)
      try await observation.call(.retryLeaseReady) { try await lease.ready() }
      #expect(
        H.refused(
          (try await observation.call(.retryFirstSignInCompletion) {
            retryTiming.record(.firstRunIssued)
            do {
              let result = try await H.completed(H.begin(fixture, cleanup))
              retryTiming.returned(.firstCompletion, result)
              return result
            } catch {
              retryTiming.failed(.firstCompletion, error)
              throw error
            }
          }), code: .endpointUnavailable))
      try await L2.snapshotUnchanged(fixture, comment: Comment(rawValue: "retrySnapshotFirst"))
      #expect(fixture.manager.current == nil)
      #expect(
        H.refused(
          (try await observation.call(.retrySecondSignInCompletion) {
            retryTiming.record(.secondRunIssued)
            do {
              let result = try await H.completed(H.begin(fixture, cleanup))
              retryTiming.returned(.secondCompletion, result)
              return result
            } catch {
              retryTiming.failed(.secondCompletion, error)
              throw error
            }
          }), code: .endpointUnavailable))
      try await L2.snapshotUnchanged(fixture, comment: Comment(rawValue: "retrySnapshotSecond"))
      try await lease.finish()
      try await L2.noAutomaticOpen(
        fixture, expected: fixture.before, registry: fixture.registryBefore, operations: fixture.secretBefore)
      _ = try
        (await observation.call(.retryReleasedSignInCompletion) {
          try await H.completed(H.begin(fixture, cleanup))
        }).get()
      try H.assertArchive(fixture, expected: fixture.before)
      try H.assertHistory(fixture.before, after: H.snapshot(fixture.raw))
      #expect(fixture.manager.current != nil)
    }
  }

  @Test func retainedDrainStillRequiredWhenPreflightCurrent() async throws {
    let observation = L2Observation(.retainedCurrent)
    defer { observation.emitAfterFixtureCleanup() }
    try await H.withFixture { fixture, cleanup in
      let lease = L2Lease.hold(fixture.scope.database, cleanup: cleanup)
      try await observation.call(.currentLeaseReady) { try await lease.ready() }
      #expect(
        H.refused(
          (try await observation.call(.currentFirstSignInCompletion) {
            try await H.completed(H.begin(fixture, cleanup))
          }), code: .endpointUnavailable))
      try await L2.snapshotUnchanged(fixture)
      let current = try L2.externalUpgrade(fixture)
      #expect(
        H.refused(
          (try await observation.call(.currentAfterUpgradeSignInCompletion) {
            try await H.completed(H.begin(fixture, cleanup))
          }), code: .endpointUnavailable))
      try await L2.snapshotUnchanged(fixture, expected: current)
      try await lease.finish()
      try await L2.noAutomaticOpen(
        fixture, expected: current, registry: fixture.registryBefore, operations: fixture.secretBefore)
      _ = try
        (await observation.call(.currentReleasedSignInCompletion) {
          try await H.completed(H.begin(fixture, cleanup))
        }).get()
      #expect(fixture.manager.current != nil)
      #expect(!FileManager.default.fileExists(atPath: H.directory(fixture)))
      try H.assertHistory(current, after: H.snapshot(fixture.raw))
    }
  }

  @Test func anotherIdentityCannotConsumeRetention() async throws {
    for sameAccount in [false, true] {
      let accounts = L2Accounts()
      try await accounts.add(H.session())
      try await accounts.add(H.session(other: true))
      try await H.withFixture(apiFactory: { _, token in accounts.api(token) }) { fixture, cleanup in
        let lease = L2Lease.hold(fixture.scope.database, cleanup: cleanup)
        try await lease.ready()
        #expect(H.refused(try await H.completed(H.begin(fixture, cleanup)), code: .endpointUnavailable))
        try await L2.snapshotUnchanged(fixture)
        let otherEndpoint = try AgentProtocolResourceFixture.endpoint()
        let otherRaw = try L2.rawCurrent(otherEndpoint)
        cleanup.auditBackend(otherEndpoint, inspector: otherRaw)
        let originalRow = try #require(try fixture.registry.active())
        if sameAccount {
          try fixture.registryRaw.execute(
            #"UPDATE "accounts" SET "database"=$1 WHERE "id"=$2"#, [otherEndpoint.database, originalRow.id])
        } else {
          let bob = H.session(other: true)
          try fixture.registry.insert(
            AccountRow(
              id: AccountRegistry.newId(), hubURL: fixture.hubURL, hubUserId: bob.userId!,
              deviceId: bob.deviceId,
              database: otherEndpoint.database, displayName: bob.user.displayName, orgName: bob.org.name))
        }
        _ = try await H.completed(H.begin(fixture, cleanup, session: H.session(other: !sameAccount))).get()
        let otherScope = try #require(fixture.manager.current)
        #expect(otherScope.account.database == otherEndpoint.database)
        #expect(try H.snapshot(fixture.raw) == fixture.before)
        #expect(!FileManager.default.fileExists(atPath: H.directory(fixture)))
        if sameAccount {
          try fixture.registryRaw.execute(
            #"UPDATE "accounts" SET "database"=$1 WHERE "id"=$2"#,
            [fixture.endpoint.database, originalRow.id])
        }
        _ = try await otherScope.hub.pushNow()
        await otherScope.hub.stop()
        let registryBefore = try H.snapshot(fixture.registryRaw), otherBefore = try H.snapshot(otherRaw)
        let operations = await fixture.secrets.operations()
        #expect(H.refused(try await H.completed(H.begin(fixture, cleanup)), code: .endpointUnavailable))
        #expect(fixture.manager.current?.instance == otherScope.instance)
        #expect(!otherScope.isClosing)
        var admitted = false
        do {
          try otherScope.enter()
          defer { otherScope.leave() }
          _ = try otherScope.database.read { try $0.execute("SELECT 1") }
          admitted = true
        } catch {}
        #expect(admitted)
        #expect(try H.snapshot(fixture.raw) == fixture.before)
        #expect(try H.snapshot(otherRaw) == otherBefore)
        #expect(try H.snapshot(fixture.registryRaw) == registryBefore)
        #expect(await fixture.secrets.operations() == operations)
        #expect(try await fixture.secrets.read(fixture.endpointRef) == H.endpointValue)
        #expect(!FileManager.default.fileExists(atPath: H.directory(fixture)))
        try await lease.finish()
        _ = try await H.completed(H.begin(fixture, cleanup)).get()
        #expect(fixture.manager.current?.account.database == fixture.endpoint.database)
        try H.assertArchive(fixture, expected: fixture.before)
        try H.assertHistory(fixture.before, after: H.snapshot(fixture.raw))
        cleanup.own(otherScope)
      }
    }
  }

  @Test func retentionOwnsOnlyClosedDatabaseUntilSuccessfulInstall() async throws {
    let owner = L2LifetimeOwner()
    var failure: (any Error)?
    do {
      // The async preparation function returns before weak ownership is inspected.
      let prepared = try await owner.prepare()
      guard await H.observed({ !prepared.weak.scopeAlive }) else {
        throw L2LifetimeFailure.unresolvedScopeOwner
      }
      #expect(prepared.weak.databaseAlive)
      _ = await prepared.manager.status()
      #expect(prepared.manager.current == nil)
      #expect(try H.snapshot(prepared.raw) == prepared.before)
      #expect(!FileManager.default.fileExists(atPath: prepared.directory))
      let deadline = ContinuousClock.now + .seconds(1)
      var stayedUnavailable = true
      repeat {
        if prepared.manager.current != nil || FileManager.default.fileExists(atPath: prepared.directory) {
          stayedUnavailable = false; break
        }
        try await Task.sleep(for: .milliseconds(50))
      } while ContinuousClock.now < deadline
      #expect(stayedUnavailable)
      #expect(try H.snapshot(prepared.raw) == prepared.before)
      let result = try await L2.joinedSignIn(prepared.manager, hubURL: H.hubURL)
      _ = try result.get()
      #expect(prepared.manager.current != nil)
      #expect(await H.observed({ !prepared.weak.databaseAlive }))
      // Keep the SAME manager alive across the weak-nil check; manager deinit cannot pass it.
      #expect(await prepared.manager.status().state == .signedIn)
      #expect(prepared.manager.current?.account.database == prepared.endpoint.database)
      #expect(!prepared.weak.scopeAlive)
    } catch { failure = error }
    await owner.finish()
    if let failure { throw failure }
  }
}

private enum L2LifetimeFailure: Error { case unresolvedScopeOwner }

private final class L2WeakReferences: Sendable {
  private struct References: Sendable {
    weak var database: WorkspaceDatabase?
    weak var scope: AccountScope?
  }
  private let references: Mutex<References>
  init(database: WorkspaceDatabase, scope: AccountScope) {
    references = Mutex(References(database: database, scope: scope))
  }
  var databaseAlive: Bool { references.withLock { $0.database != nil } }
  var scopeAlive: Bool { references.withLock { $0.scope != nil } }
}

/// This owner NEVER stores an old scope/DB, cleanup closure or Task. Raw libpq does not own a DB object.
private final class L2LifetimeOwner: Sendable {
  private struct State {
    var manager: AccountManager?
    var registry: AccountRegistry?
    var root: String?
    var endpoint: PostgresEndpoint?
    var raw: PostgresConnection?
  }
  struct Prepared: Sendable {
    let manager: AccountManager
    let endpoint: PostgresEndpoint
    let raw: PostgresConnection
    let before: H.Snapshot
    let directory: String
    let weak: L2WeakReferences
  }
  private let state = Mutex(State())

  func prepare() async throws -> Prepared {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let root = try AgentProtocolResourceFixture.physicalTemporaryDirectory() + "a3-l2-lifetime-\(UUID())"
    state.withLock {
      $0.root = root; $0.endpoint = endpoint
    }
    var paths = PlatformPaths(runtimeDir: root + "/rt", dataDir: root + "/flavor-local")
    paths.postgres = endpoint
    try FileManager.default.createDirectory(
      atPath: paths.dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // The initial constructor's DB is a different, immediately closed lexical object.
    do {
      let initial = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!); try initial.close()
    }
    let registry = try AccountRegistry(
      endpoint: endpoint, binDir: endpoint.binDir!,
      databaseName: AccountManager.registryDatabaseName(for: endpoint))
    state.withLock { $0.registry = registry }
    let secrets = L1Secrets()
    let accountRef = SecretRef.make(), endpointRef = SecretRef.make()
    try await secrets.put(accountRef, value: H.accountValue)
    try await secrets.put(endpointRef, value: H.endpointValue)
    let session = H.session()
    let row = AccountRow(
      id: AccountRegistry.newId(), hubURL: H.hubURL, hubUserId: session.userId!, deviceId: session.deviceId,
      database: endpoint.database, displayName: session.user.displayName, orgName: session.org.name)
    try registry.insert(row); try registry.activate(id: row.id, tokenRef: accountRef.rawValue)
    let events = EventLog(), fake = FakeHubAPI()
    await fake.setSession(session)
    _ = try await fake.passkeyFinish(
      .init(
        ceremonyId: "fixture", assertion: nil, attestation: nil,
        device: .init(deviceName: "Fixture Mac", platform: "macos", deviceId: session.deviceId)))
    let calls = L1FactoryCalls()
    let diagnostics = DiagnosticsService(
      context: .init(
        paths: paths, startedAt: "fixture", environment: [:], secretStore: secrets, eventLog: events))
    let manager = AccountManager(
      context: .init(
        cluster: StoreCluster(endpoint: endpoint, binDir: endpoint.binDir!), registry: registry,
        scope: .init(
          paths: paths, environment: ["PATH": "/nonexistent", "HOME": root], secretStore: secrets,
          eventLog: events, diagnostics: diagnostics,
          adapterFactory: { _, _, _, _ in
            calls.record(); throw WorkspaceError(.internalError, "Unexpected lifetime runtime.")
          },
          hubAPIFactory: { _, _ in fake }, hubLinkConnection: FakeHubLinkConnection(),
          powerAssertions: FakePowerAssertions(), checkRetryDelays: [], threadDeleteSweep: .zero),
        flavor: .local))
    state.withLock { $0.manager = manager }
    await manager.start()
    // Actual refresh and pump handles are joined/dropped BEFORE returning, never saved in owner.
    var bootRefresh = await manager.refresh
    await bootRefresh?.value
    bootRefresh = nil
    let scope = try #require(manager.current)
    let database = scope.database
    let weak = L2WeakReferences(database: database, scope: scope)
    var pumps = Array((await scope.sessions.pumps).values)
    do {
      let raw = try H.connection(endpoint)
      state.withLock { $0.raw = raw }
      scope.refuseNewWork()
      guard await scope.drain(timeout: .seconds(2)) else {
        scope.admitWorkAgain(); throw H.SetupFailure.setupGateTimeout
      }
      do {
        let files = try AgentProtocolFoundationFixture.knownFiles()
        try H.reconstructOldStore(raw, files: files)
        try H.seedHistory(raw, accountRef: accountRef, endpointRef: endpointRef)
      } catch { scope.admitWorkAgain(); throw error }
      scope.admitWorkAgain()  // No persistent reopen closure captures scope.
      let before = try H.snapshot(raw)
      let semaphore = DispatchSemaphore(value: 0), entered = L1RunState()
      var borrower: Task<Void, any Error>? = Task.detached { [database] in
        try await H.onDedicatedLeaseThread {
          try database.read { _ in
            entered.finished.withLock { $0 = true }
            guard semaphore.wait(timeout: .now() + .seconds(60)) == .success else {
              throw H.SetupFailure.leaseGuardTimeout
            }
          }
        }
      }
      var failure: (any Error)?
      var signIn: Task<Result<AccountStatus.Result, any Error>, Never>?
      let signInState = L1RunState()
      do {
        guard await H.observed({ entered.finished.withLock { $0 } }) else {
          throw H.SetupFailure.observationTimeout
        }
        let registryBefore = try registry.all(), operations = await secrets.operations()
        // Actual child task holds ONLY manager+session; never scope/database/Fixture.
        signIn = Task { [manager, session] in
          defer { signInState.finished.withLock { $0 = true } }
          return await L2.signIn(manager, hubURL: H.hubURL, session: session)
        }
        let result = try await H.completed(.init(task: signIn!, state: signInState))
        #expect(H.refused(result, code: .endpointUnavailable))
        #expect(manager.current == nil)
        #expect(try H.snapshot(raw) == before)
        #expect(try registry.all() == registryBefore)
        #expect(await secrets.operations() == operations)
      } catch { failure = error }
      semaphore.signal()
      if let task = borrower {
        do { try await task.value } catch { if failure == nil { failure = error } }
      }
      borrower = nil
      if let task = signIn { _ = await task.value }
      signIn = nil
      if failure != nil { await scope.close(stoppingServers: false, drainTimeout: .zero) }
      for task in pumps { await task.value }
      pumps = []
      #expect(calls.value == 0)
      if let failure { throw failure }
      let component = try #require(
        endpoint.database.addingPercentEncoding(
          withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))))
      let directory = paths.dataDir + "/backups/" + component
      // After this function RETURNS, ALL lexical strong old scope/DB/service refs have disappeared.
      return Prepared(
        manager: manager, endpoint: endpoint, raw: raw, before: before, directory: directory, weak: weak)
    } catch {
      // Setup can throw before the lease exists. Known startup tasks still get actual joins.
      await scope.close(stoppingServers: false, drainTimeout: .zero)
      for task in pumps { await task.value }
      pumps = []
      throw error
    }
  }

  func finish() async {
    let owned = state.withLock { value in
      defer { value = State() }; return value
    }
    await owned.manager?.shutdown()
    owned.registry?.close()
    if let raw = owned.raw, let endpoint = owned.endpoint {
      #expect(
        await H.observed {
          (try? raw.execute(
            "SELECT 1 FROM pg_stat_activity WHERE application_name='b4app' AND datname IN ($1,$2)",
            [endpoint.database, AccountManager.registryDatabaseName(for: endpoint)]
          ).rows.isEmpty) == true
        })
    }
    if let root = owned.root {
      try? FileManager.default.removeItem(atPath: root);
      #expect(!FileManager.default.fileExists(atPath: root))
    }
  }
}

@Suite(.serialized) struct AgentProtocolAccountMigrationControlTests {
  @Test func authHandlerVerifiesBeforeQuiescence() async throws {
    for rejects in [true, false] {
      let hub = CommandHub()
      await hub.fake.setSession(H.session())
      if rejects {
        hub.fail(
          "passkeyFinish",
          with: HubError(
            kind: "request_error", code: "credential_rejected", message: "Fixture rejected.", status: 401))
      }
      hub.stick()
      try await H.withFixture(
        hubURL: Flavor.local.hubURL.absoluteString, apiFactory: { hub.api($0, $1) }
      ) { fixture, cleanup in
        cleanup.release { hub.unstick() }
        let state = L1RunState()
        let task = Task {
          defer { state.finished.withLock { $0 = true } }
          do {
            return Result<AccountStatus.Result, any Error>.success(
              try await fixture.manager.passkeyFinish(
                .init(ceremonyId: "held-auth", assertion: ["id": "fixture"], attestation: nil)))
          } catch { return .failure(error) }
        }
        cleanup.join { _ = await task.value }
        guard await H.observed({ hub.calls.contains("passkeyFinish") }) else {
          throw H.SetupFailure.observationTimeout
        }
        #expect(fixture.manager.current?.instance == fixture.scope.instance)
        #expect(!fixture.scope.isClosing)
        try fixture.scope.enter()
        do {
          defer { fixture.scope.leave() }; _ = try fixture.scope.database.read { try $0.execute("SELECT 1") }
        }
        try await H.unchanged(fixture)
        hub.unstick()
        let result = try await H.completed(.init(task: task, state: state))
        if rejects {
          #expect(H.refused(result, code: .credentialRejected))
          #expect(fixture.manager.current?.instance == fixture.scope.instance)
          try await H.unchanged(fixture)
        } else {
          _ = try result.get()
          try H.assertArchive(fixture, expected: fixture.before)
          try H.assertHistory(fixture.before, after: H.snapshot(fixture.raw))
          #expect(fixture.manager.current?.instance != fixture.scope.instance)
        }
      }
    }
  }

  @Test func oldInstanceCallbacksCannotMutateReplacement() async throws {
    let observation = L2Observation(.oldCallbacks)
    defer { observation.emitAfterFixtureCleanup() }
    try await H.withFixture { fixture, cleanup in
      let writer = try H.connection(fixture.endpoint)
      let pid = try #require(writer.execute("SELECT pg_backend_pid() AS pid").rows.first?.text("pid"))
      try writer.execute("BEGIN")
      let rollback = cleanup.release { _ = try? writer.execute("ROLLBACK") }
      try writer.execute(
        "SELECT pg_advisory_xact_lock_shared($1::bigint)", [String(WorkspaceDatabase.remoteApplyLockKey)])
      let run = H.begin(fixture, cleanup)
      guard
        await observation.observed(
          .callbacksMigrationLockObservation,
          {
            await H.observed({
              (try? fixture.raw.execute(
                "SELECT 1 FROM pg_stat_activity a JOIN pg_locks l ON a.pid=l.pid WHERE a.datname=$1 AND l.locktype='advisory' AND l.mode='ExclusiveLock' AND NOT l.granted AND $2::int=ANY(pg_blocking_pids(a.pid))",
                [fixture.endpoint.database, pid]
              ).rows.count == 1) == true
            })
          })
      else { throw H.SetupFailure.observationTimeout }
      #expect(fixture.manager.current == nil && L2.poolClosed(fixture.scope))
      let oldInstance = fixture.scope.instance
      let me = MeResponse(
        deviceId: "stale-device", deviceName: "Stale", platform: "macos",
        org: .init(slug: "stale", name: "Stale Org"), user: .init(username: "stale", displayName: "Stale"),
        createdAt: "fixture", onboarded: false, userId: "stale-user")
      let profileDelay = L2Delay(), rejectionDelay = L2Delay()
      cleanup.release {
        profileDelay.release(); rejectionDelay.release()
      }
      let profile = Task {
        await profileDelay.wait(); await fixture.manager.profileArrived(me, instance: oldInstance)
      }
      let rejected = Task {
        await rejectionDelay.wait(); await fixture.manager.hubRejected(instance: oldInstance)
      }
      cleanup.join {
        await profile.value; await rejected.value
      }
      profile.cancel(); rejected.cancel()
      // Enqueue while the slot is nil. The actor is blocked in synchronous SQL open;
      // both real callback handlers can execute only after writer COMMIT/install here.
      profileDelay.release()
      #expect(try H.snapshot(fixture.registryRaw) == fixture.registryBefore)
      #expect(await fixture.secrets.operations() == fixture.secretBefore)
      rejectionDelay.release()  // It waits on transitions; join ONLY after migration is released.
      try writer.execute("COMMIT"); rollback.run()
      _ = try (await observation.call(.callbacksReplacementSignInCompletion) { try await H.completed(run) })
        .get()
      await profile.value; await rejected.value
      #expect(fixture.manager.current != nil)
      let currentScope = try #require(fixture.manager.current)
      _ = try await currentScope.hub.pushNow()
      await currentScope.hub.stop()
      let installed = currentScope.instance
      let before = try H.snapshot(fixture.raw), registry = try H.snapshot(fixture.registryRaw)
      let operations = await fixture.secrets.operations()
      let secondProfile = Task { await fixture.manager.profileArrived(me, instance: oldInstance) }
      let secondRejected = Task { await fixture.manager.hubRejected(instance: oldInstance) }
      cleanup.join {
        await secondProfile.value; await secondRejected.value
      }
      await secondProfile.value; await secondRejected.value
      #expect(fixture.manager.current?.instance == installed)
      #expect(try H.snapshot(fixture.raw) == before)
      #expect(try H.snapshot(fixture.registryRaw) == registry)
      #expect(await fixture.secrets.operations() == operations)
      #expect(try fixture.registry.active()?.displayName == H.session().user.displayName)
      let tokenRef = try #require(try fixture.registry.active()?.tokenRef.flatMap(SecretRef.init(rawValue:)))
      #expect(try await fixture.secrets.read(tokenRef) == H.session().token)
    }
    // Separate REAL async-close boundary: in-flight push is NOT such a barrier, because
    // HubSync.close cancels it without joining. Hold actual fake adapter disposal instead.
    let adapters = StubbornAdapters()
    try await H.withFixture(
      adapterFactory: { _, _, _, _ in adapters.make() }, expectedAdapterFactoryCalls: 1
    ) { fixture, cleanup in
      cleanup.release { adapters.release() }
      _ = try await fixture.scope.sessions.adapter(
        for: Connection(
          id: "nil-slot-disposal", kind: .claude, label: "Fake disposal", target: "/nonexistent/claude"))
      let pumps = Array((await fixture.scope.sessions.pumps).values)
      cleanup.release { for pump in pumps { pump.cancel() } }
      cleanup.join { for pump in pumps { await pump.value } }
      let run = H.begin(fixture, cleanup)
      guard
        await observation.observed(
          .callbacksDisposeEnteredObservation, { await H.observed({ adapters.disposes == 1 }) })
      else { throw H.SetupFailure.observationTimeout }
      // AccountManager is suspended in bounded Self.close while disposal is held, so its actor
      // can actually run profileArrived with slot nil BEFORE any storage admission/capture.
      #expect(fixture.manager.current == nil && fixture.scope.isClosing)
      #expect(adapters.completedDisposes == 0)
      let instance = fixture.scope.instance
      let me = MeResponse(
        deviceId: "stale-device", deviceName: "Stale", platform: "macos",
        org: .init(slug: "stale", name: "Stale Org"), user: .init(username: "stale", displayName: "Stale"),
        createdAt: "fixture", onboarded: false, userId: "stale-user")
      let finished = L1RunState()
      let profile = Task {
        defer { finished.finished.withLock { $0 = true } }
        await fixture.manager.profileArrived(me, instance: instance)
      }
      cleanup.join { await profile.value }
      guard
        await observation.observed(
          .callbacksNilSlotProfileObservation, { await H.observed({ finished.finished.withLock { $0 } }) })
      else {
        throw H.SetupFailure.observationTimeout
      }
      await profile.value
      #expect(fixture.manager.current == nil)
      #expect(adapters.completedDisposes == 0)  // Genuine held close, not a raced after-install check.
      try await H.unchanged(fixture)
      adapters.release()
      _ = try (await observation.call(.callbacksDisposalSignInCompletion) { try await H.completed(run) })
        .get()
      guard
        await observation.observed(
          .callbacksDisposeCompletedObservation, { await H.observed({ adapters.completedDisposes == 1 }) })
      else {
        throw H.SetupFailure.observationTimeout
      }
      for pump in pumps { await pump.value }
      try H.assertArchive(fixture, expected: fixture.before)
      try H.assertHistory(fixture.before, after: H.snapshot(fixture.raw))
      #expect(fixture.manager.current?.instance != instance)
    }
  }

  @Test func oldWriterCompletionsUseClosedOrDrainedPool() async throws {
    let factory = L2Factory()
    try await factory.configure()
    try await H.withFixture(apiFactory: { factory.api($0, token: $1) }, isolatedDiagnostics: true) {
      fixture, cleanup in
      cleanup.release {
        factory.old.unstick(); factory.fresh.unstick()
      }
      let server = LocalServer(
        id: "late-server", name: "Late fixture", projectPath: "/fixture/late-server",
        nodePath: "/nonexistent/node", cliPath: "/nonexistent/cli", launchMode: .source,
        health: .ready, createdAt: "created", updatedAt: "updated")
      // Raw test rows have no pid/port/log. startAll cannot launch or inspect a process.
      try fixture.raw.execute(
        """
        INSERT INTO "localServers" ("id","name","projectPath","nodePath","cliPath","launchMode","health","createdAt","updatedAt")
          VALUES ('late-server','Late fixture','/fixture/late-server','/nonexistent/node','/nonexistent/cli','source','ready','created','updated');
        INSERT INTO "connections" ("id","kind","label","target","nativeScope","capabilities","status","authStatus","projectId","createdAt","updatedAt")
          VALUES ('late-codex','codex','Late fixture','/nonexistent/codex','late-scope','{}','ready','authenticated','old-project','created','updated');
        INSERT INTO "threads" ("id","connectionId","nativeThreadId","nativeScope","projectId","createdAt","updatedAt")
          VALUES ('late-thread','late-codex','late-native-thread','late-scope','old-project','created','updated');
        INSERT INTO "turns" ("id","threadId","nativeTurnId","operationId","status","submission","outcome","createdAt","updatedAt")
          VALUES ('late-turn','late-thread','late-native-turn','late-operation','reconciling','unknown',NULL,'created','updated');
        """)
      await fixture.scope.hub.start()  // Reloads link before existing nudge-task guard; no second lifecycle.
      #expect(factory.count == 1)
      factory.old.stick()
      let push = Task { try await fixture.scope.hub.pushNow() }
      cleanup.join { _ = await push.result }
      guard await H.observed({ factory.old.calls.contains("push") }) else {
        throw H.SetupFailure.observationTimeout
      }
      let delay = L2Delay()
      cleanup.release { delay.release() }
      let stopped = Task {
        await delay.wait()
        do {
          return Result<LocalServer, any Error>.success(
            try await fixture.scope.servers.markStopped(server, message: "late fixture exit"))
        } catch { return .failure(error) }
      }
      stopped.cancel()
      cleanup.join { _ = await stopped.value }
      let session = Task {
        await delay.wait()
        await fixture.scope.sessions.environment(
          AdapterEvent(
            kind: .turnFinished, connectionId: "late-codex",
            nativeIds: ["threadId": "late-native-thread", "turnId": "late-native-turn"],
            payload: ["outcome": "completed"]))
      }
      cleanup.join { await session.value }
      session.cancel()
      let beforeMigration = try H.snapshot(fixture.raw)
      _ = try await H.completed(H.begin(fixture, cleanup)).get()
      let current = try #require(fixture.manager.current)
      _ = try await current.hub.pushNow()  // Join existing new push and finish an empty drain.
      await current.hub.stop()
      let beforeLate = try H.snapshot(fixture.raw)
      factory.old.unstick(); delay.release()
      let pushResult = await push.result
      #expect(H.refused(pushResult, code: .endpointUnavailable))
      let stoppedResult = await stopped.value
      #expect(H.refused(stoppedResult, code: .endpointUnavailable))
      await session.value
      #expect(L2.poolClosed(fixture.scope))
      #expect(try H.snapshot(fixture.raw) == beforeLate)
      let diagnostics = try await fixture.diagnostics.read()
      #expect(
        diagnostics.recentErrors.contains {
          $0.scope == "projection" && $0.message.contains("store is closed")
        })
      try H.assertArchive(fixture, expected: beforeMigration)
      try H.assertHistory(beforeMigration, after: H.snapshot(fixture.raw))
    }
    try await H.withFixture { fixture, cleanup in
      let semaphore = DispatchSemaphore(value: 0)
      let release = cleanup.release { semaphore.signal() }
      let entered = L1RunState()
      let committed = Mutex<H.Snapshot?>(nil)
      let worker = Task.detached {
        try await H.onDedicatedLeaseThread {
          try fixture.scope.database.write { c in
            try c.execute(#"UPDATE "connections" SET "label"='counted-before-capture' WHERE "id"='old-b4'"#)
            let expected = try H.snapshot(c)
            committed.withLock { $0 = expected }
            entered.finished.withLock { $0 = true }
            guard semaphore.wait(timeout: .now() + .seconds(25)) == .success else {
              throw H.SetupFailure.leaseGuardTimeout
            }
          }
        }
      }
      cleanup.join { _ = await worker.result }
      guard await H.observed({ entered.finished.withLock { $0 } }) else {
        throw H.SetupFailure.observationTimeout
      }
      let run = H.begin(fixture, cleanup)
      guard await H.observed({ L2.poolClosed(fixture.scope) }) else {
        throw H.SetupFailure.observationTimeout
      }
      #expect(!FileManager.default.fileExists(atPath: H.directory(fixture)))
      // The worker stored this post-UPDATE snapshot before publishing its entered flag.
      let expected = try #require(committed.withLock { $0 })
      let counterPrefix = "sequence:changes_seq_seq:"
      let baselineCounter = fixture.before.catalog.filter { $0.hasPrefix(counterPrefix) }
      let writerCounter = expected.catalog.filter { $0.hasPrefix(counterPrefix) }
      let baselineOtherCatalog = fixture.before.catalog.filter { !$0.hasPrefix(counterPrefix) }
      let writerOtherCatalog = expected.catalog.filter { !$0.hasPrefix(counterPrefix) }
      guard baselineCounter.count == 1, writerCounter.count == 1,
        writerOtherCatalog == baselineOtherCatalog
      else { throw H.SetupFailure.canonicalMismatch }
      var expectedBeforeCommit = fixture.before
      expectedBeforeCommit.catalog = fixture.before.catalog.map { fact in
        fact.hasPrefix(counterPrefix) ? writerCounter[0] : fact
      }
      #expect(try H.snapshot(fixture.raw) == expectedBeforeCommit)
      release.run(); try await worker.value
      _ = try await H.completed(run).get()
      try H.assertArchive(fixture, expected: expected)
    }
  }
}

private final class L2ObservationSentinel: Error {}

@Suite private struct AgentProtocolL2ObservationMechanicalTests {
  @Test func forwardingPreservesValuesErrorsAndDefersBoundedReporting() async throws {
    let sentinel = L2ObservationSentinel()
    let observation = L2Observation(.explicitRetry)
    var calls = 0
    var reports: [String] = []
    var cleanupFinished = false
    let result: Result<Int, any Error> = await observation.call(.retryFirstSignInCompletion) {
      calls += 1
      return .failure(sentinel)
    }
    #expect(calls == 1)
    // Result.failure is a returned VALUE. Its domain error is unwrapped outside call.
    do {
      _ = try result.get()
      Issue.record("Expected the identical returned domain sentinel.")
    } catch {
      #expect((error as? L2ObservationSentinel) === sentinel)
    }
    do {
      let _: Int = try await observation.call(.retryLeaseReady) {
        calls += 1
        throw H.SetupFailure.observationTimeout
      }
      Issue.record("Expected the genuine observation timeout enum.")
    } catch {
      guard let failure = error as? H.SetupFailure,
        case .observationTimeout = failure
      else {
        Issue.record("Expected the genuine observation timeout enum.")
        return
      }
    }
    #expect(calls == 2)
    do {
      let _: Int = try await observation.call(.retrySecondSignInCompletion) {
        calls += 1
        throw sentinel
      }
      Issue.record("Expected the identical observation sentinel.")
    } catch {
      #expect((error as? L2ObservationSentinel) === sentinel)
    }
    #expect(calls == 3)
    let returnedFalse = await observation.observed(.callbacksDisposeEnteredObservation) {
      calls += 1
      return false
    }
    let returnedTrue = await observation.observed(.callbacksDisposeCompletedObservation) {
      calls += 1
      return true
    }
    #expect(!returnedFalse)
    #expect(returnedTrue)
    #expect(calls == 5)
    #expect(reports.isEmpty)
    cleanupFinished = true
    observation.emitAfterFixtureCleanup { line in
      #expect(cleanupFinished)
      reports.append(line)
    }
    #expect(reports.contains { $0.contains("stage=retryFirstSignInCompletion outcome=returned") })
    #expect(reports.contains { $0.contains("stage=retryLeaseReady outcome=observationTimeout") })
    #expect(reports.contains { $0.contains("stage=retrySecondSignInCompletion outcome=threw") })
    #expect(
      reports.contains { $0.contains("stage=callbacksDisposeEnteredObservation outcome=returnedFalse") })
    #expect(
      reports.contains { $0.contains("stage=callbacksDisposeCompletedObservation outcome=returnedTrue") })

    // Capacity is eight. Exercise overflow sequentially, without manufacturing lock contention.
    let bounded = L2Observation(.retainedCurrent)
    var boundedReports: [String] = []
    var boundedCalls = 0
    for value in 0..<9 {
      let returned = await bounded.call(.currentFirstSignInCompletion) {
        boundedCalls += 1
        return value
      }
      #expect(returned == value)
    }
    #expect(boundedCalls == 9)
    #expect(boundedReports.isEmpty)
    bounded.emitAfterFixtureCleanup { boundedReports.append($0) }
    let records = boundedReports.filter { $0.contains("stage=") }
    #expect(records.count == 8)
    #expect(records.allSatisfy { $0.contains("outcome=returned") })
    #expect(boundedReports.contains { $0.contains("partial=true") && $0.contains("overflow=true") })
    #expect(boundedReports.count <= 9)
  }
}
