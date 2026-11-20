import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

let protocolFullMatrixEnabled = ProcessInfo.processInfo.environment["B4APP_PROTOCOL_FULL_MATRIX"] == "1"

// Real native stores and genuine dormant P2a owners; counted fake requests are not HTTP proof.
@Suite(NativeDBResources(runBlockingCaseInOrdinarySuite: true), .serialized, .timeLimit(.minutes(1)))
struct AccountSessionComparisonOwnerTests {
  @Test func p2bB16InstalledOwnerOnlyAndZeroNewEffects() async throws {
    for linked in [false, true] {
      try await P2BOwnerFixture.withFixture(linked: linked) { f in
        let window = try await f.manager.beginDormantScopePreparation()
        let prepared = try await f.reserve(window, scope: f.scope)
        p2bOwnerRefusal { _ = try prepared.carrier.captureInstalledAccountSessionComparison() }
        let attachment = try await f.attach(prepared, scope: f.scope)
        _ = try await f.publish(prepared, attachment, scope: f.scope)
        let before = await f.effects()
        let image = try f.native.image(f.scope.database)
        let comparison = try prepared.carrier.captureInstalledAccountSessionComparison()
        let presence = p2bOwnerIsLinked(comparison.presence) == linked
        #expect(presence)
        try comparison.requireOriginalNativeSession()
        p2bOwnerPrivacy(comparison, name: "AccountSessionComparison")
        try await f.rejectNetworkRoles(prepared.carrier)
        let unchanged = try f.native.image(f.scope.database) == image
        #expect(unchanged)
        await f.expectEffects(before)
      }
    }
    try await P2BOwnerFixture.withFixture(linked: true) { f in
      let ordinary = try await f.ordinary()
      let before = await f.effects()
      p2bOwnerRefusal { _ = try ordinary.captureInstalledAccountSessionComparison() }
      let final = try await f.manager.beginDormantHubCleanup(original: ordinary)
      p2bOwnerRefusal { _ = try final.captureInstalledAccountSessionComparison() }
      let disposal = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
        original: ordinary, finalPush: final)
      p2bOwnerRefusal { _ = try disposal.captureInstalledAccountSessionComparison() }
      let revoked = await f.manager.revokeDormantHubCleanupPhase(disposal)
      #expect(revoked)
      let finished = await f.manager.finishDormantHubCleanup(disposal)
      #expect(finished)
      await f.expectEffects(before)
    }
  }

  @Test func p2bB17PoolSlotWaitSameOwnerAllows() async throws {
    try await p2bOwnerB17PoolSlotWait(retired: false, observationIndex: 1)
  }

  @Test func p2bB17PoolSlotWaitRetiredOwnerRefuses() async throws {
    try await p2bOwnerB17PoolSlotWait(retired: true, observationIndex: 2)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterConnectBeforeG3SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterConnectBeforeG3, refused: 4, normal: 0,
      retired: false, observationIndex: 3)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterConnectBeforeG3RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterConnectBeforeG3, refused: 4, normal: 0,
      retired: true, observationIndex: 4)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterStatementBudgetBeforeG6SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterStatementBudgetBeforeG6, refused: 32, normal: 3,
      retired: false, observationIndex: 5)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterStatementBudgetBeforeG6RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterStatementBudgetBeforeG6, refused: 32, normal: 3,
      retired: true, observationIndex: 6)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterFactsBeforeG7SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterFactsBeforeG7, refused: 64, normal: 4,
      retired: false, observationIndex: 7)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterFactsBeforeG7RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterFactsBeforeG7, refused: 64, normal: 4,
      retired: true, observationIndex: 8)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterRollbackBeforeG8SameOwnerAllows() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterRollbackBeforeG8, refused: 128, normal: 4,
      retired: false, observationIndex: 9)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17AfterRollbackBeforeG8RetiredOwnerRefuses() async throws {
    try await p2bOwnerB17ControlledWait(
      phase: .afterRollbackBeforeG8, refused: 128, normal: 4,
      retired: true, observationIndex: 10)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17RealRelationLockWaitSameOwnerAllows() async throws {
    try await p2bOwnerB17RelationLockWait(retired: false, observationIndex: 11)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB17RealRelationLockWaitRetiredOwnerRefuses() async throws {
    try await p2bOwnerB17RelationLockWait(retired: true, observationIndex: 12)
  }

  @Test func p2bB18AccountIDChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 0, observationIndex: 1)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18DatabaseChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 1, observationIndex: 2)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18HubURLSpellingChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 2, observationIndex: 3)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18DeviceIDChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 3, observationIndex: 4)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18TokenRefChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 4, observationIndex: 5)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18TokenRefRemovedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 5, observationIndex: 6)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18UnicodeDeviceIDBytesChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 6, observationIndex: 7)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18UnicodeTokenRefBytesChangedRefuses() async throws {
    try await p2bOwnerB18ContextMutation(mutation: 7, observationIndex: 8)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18NativeAbsentTokenNonNilToNilRefuses() async throws {
    try await p2bOwnerB18NativeAbsentContext(
      initiallyNil: false, observationIndex: 9)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB18NativeAbsentTokenNilToNewRefuses() async throws {
    try await p2bOwnerB18NativeAbsentContext(
      initiallyNil: true, observationIndex: 10)
  }

  @Test func p2bB18MetadataAllowedThenGateAndOwnerReplacementNeverRetargets() async throws {
    try await p2bOwnerB18MetadataGateAndReplacement(observationIndex: 11)
  }

  private func p2bOwnerB17PoolSlotWait(retired: Bool, observationIndex: Int) async throws {
    try await P2BOwnerFixture.withFixture(
      linked: true, observation: P2BOwnerObservation(testCase: .b17, fixtureIndex: observationIndex)
    ) { f in
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let database = f.scope.database
      let holds = (0..<4).map { _ in f.native.hold() }
      for hold in holds {
        _ = f.native.worker { [database, hold] in
          try database.read { c in
            try p2bOwnerOne(c); return hold.wait()
          }
        }
      }
      try p2bOwnerRequire(p2bOwnerPoll { holds.allSatisfy { $0.entered } })
      let probe = try f.native.probe(database)
      let worker = f.native.worker { [comparison] in
        if retired { return p2bOwnerRejected { try comparison.requireOriginalNativeSession() } }
        try comparison.requireOriginalNativeSession(); return true
      }
      let actuallyQueued = p2bOwnerPoll { probe.snapshot().waitStart != nil }
      #expect(actuallyQueued)
      if retired { try await f.retire() }
      for hold in holds { hold.release() }
      let terminal = worker.join()
      #expect(terminal)
      let sample = probe.snapshot()
      if retired {
        let stoppedAtG1 =
          sample.refusedGuards == 1 && sample.commandStarts.allSatisfy { $0 == 0 }
          && sample.leaseLeft && sample.slotSignalled
        #expect(stoppedAtG1)
      } else {
        p2bOwnerSuccessful(sample)
      }
    }
  }

  private func p2bOwnerB17ControlledWait(
    phase: AccountSessionComparisonPhase, refused: UInt, normal: UInt, retired: Bool,
    observationIndex: Int
  ) async throws {
    try await P2BOwnerFixture.withFixture(
      linked: true, observation: P2BOwnerObservation(testCase: .b17, fixtureIndex: observationIndex)
    ) { f in
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let probe = try f.native.probe(f.scope.database, phase: phase)
      let worker = f.native.worker { [comparison] in
        if retired { return p2bOwnerRejected { try comparison.requireOriginalNativeSession() } }
        try comparison.requireOriginalNativeSession(); return true
      }
      try p2bOwnerRequire(p2bOwnerPoll { probe.snapshot().holdEntered })
      if retired { try await f.retire() }
      probe.releaseHold()
      let terminal = worker.join()
      #expect(terminal)
      let sample = probe.snapshot()
      if retired {
        let stopped =
          sample.refusedGuards == refused
          && sample.commandStarts[0...3].reduce(0, +) == normal
          && sample.rollbackAttempts == (phase == .afterConnectBeforeG3 ? 0 : 1)
        #expect(stopped)
        p2bOwnerCleanup(sample)
      } else {
        p2bOwnerSuccessful(sample)
      }
    }
  }

  private func p2bOwnerB17RelationLockWait(retired: Bool, observationIndex: Int) async throws {
    try await P2BOwnerFixture.withFixture(
      linked: true, observation: P2BOwnerObservation(testCase: .b17, fixtureIndex: observationIndex)
    ) { f in
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let inspector = try f.native.inspector(f.scope.database)
      try inspector.execute("BEGIN; LOCK TABLE public.\"hubLink\" IN ACCESS EXCLUSIVE MODE")
      defer { _ = try? inspector.execute("ROLLBACK") }
      let probe = try f.native.probe(f.scope.database)
      let worker = f.native.worker { [comparison] in
        if retired { return p2bOwnerRejected { try comparison.requireOriginalNativeSession() } }
        try comparison.requireOriginalNativeSession(); return true
      }
      let realWait = p2bOwnerPoll { (try? f.native.relationWait(f.scope.database)) == true }
      #expect(realWait)
      if retired { try await f.retire() }
      try inspector.execute("ROLLBACK")
      let terminal = worker.join()
      #expect(terminal)
      let sample = probe.snapshot()
      if retired {
        let decodedThenRefused =
          sample.factsDecoded == 1 && sample.refusedGuards == 64
          && sample.rollbackAttempts == 1 && sample.rollbackAcknowledgements == 1
        #expect(decodedThenRefused)
        p2bOwnerCleanup(sample)
      } else {
        p2bOwnerSuccessful(sample)
      }
    }
  }

  private func p2bOwnerB18ContextMutation(mutation: Int, observationIndex: Int) async throws {
    try await P2BOwnerFixture.withFixture(
      linked: true, observation: P2BOwnerObservation(testCase: .b18, fixtureIndex: observationIndex)
    ) { f in
      if mutation >= 6 {
        var unicode = f.scope.account
        if mutation == 6 { unicode.deviceId = "d\u{00e9}" } else { unicode.tokenRef = "secret:r\u{00e9}" }
        f.scope.update(account: unicode)
        let inspector = try f.native.inspector(f.scope.database)
        try inspector.execute(
          "UPDATE public.\"hubLink\" SET \"deviceId\"=$1, \"tokenRef\"=$2",
          [unicode.deviceId, unicode.tokenRef])
      }
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let original = f.scope.account
      let probe = try f.native.probe(f.scope.database, phase: .afterFactsBeforeG7)
      let worker = f.native.worker { [comparison] in
        p2bOwnerRejected { try comparison.requireOriginalNativeSession() }
      }
      try p2bOwnerRequire(p2bOwnerPoll { probe.snapshot().holdEntered })
      var changed = original
      switch mutation {
      case 0: changed.id += "other"
      case 1: changed.database += "other"
      case 2: changed.hubURL = "HTTPS://SCOPE-OWNER.INVALID/Deployment/"
      case 3: changed.deviceId += "other"
      case 4: changed.tokenRef = "secret:other"
      case 5: changed.tokenRef = nil
      case 6: changed.deviceId = "de\u{0301}"
      default: changed.tokenRef = "secret:re\u{0301}"
      }
      f.scope.update(account: changed)
      probe.releaseHold()
      let refused = worker.join()
      #expect(refused)
      p2bOwnerCleanup(probe.snapshot())
      f.scope.update(account: original)
      try comparison.requireOriginalNativeSession()
    }
  }

  private func p2bOwnerB18NativeAbsentContext(initiallyNil: Bool, observationIndex: Int) async throws {
    try await P2BOwnerFixture.withFixture(
      linked: false, observation: P2BOwnerObservation(testCase: .b18, fixtureIndex: observationIndex)
    ) { f in
      var original = f.scope.account
      if initiallyNil { original.tokenRef = nil; f.scope.update(account: original) }
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let probe = try f.native.probe(f.scope.database, phase: .afterConnectBeforeG3)
      let worker = f.native.worker { [comparison] in
        p2bOwnerRejected { try comparison.requireOriginalNativeSession() }
      }
      try p2bOwnerRequire(p2bOwnerPoll { probe.snapshot().holdEntered })
      var changed = original
      changed.tokenRef = initiallyNil ? "secret:new" : nil
      f.scope.update(account: changed)
      probe.releaseHold()
      let refused = worker.join()
      #expect(refused)
      p2bOwnerCleanup(probe.snapshot())
    }
  }

  private func p2bOwnerB18MetadataGateAndReplacement(observationIndex: Int) async throws {
    try await P2BOwnerFixture.withFixture(
      linked: true, observation: P2BOwnerObservation(testCase: .b18, fixtureIndex: observationIndex)
    ) { f in
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let probe = try f.native.probe(f.scope.database, phase: .afterFactsBeforeG7)
      let worker = f.native.worker { [comparison] in
        try comparison.requireOriginalNativeSession(); return true
      }
      try p2bOwnerRequire(p2bOwnerPoll { probe.snapshot().holdEntered })
      var metadata = f.scope.account
      metadata.displayName = "changed"; metadata.orgName = "changed"; metadata.hubUserId = "changed"
      metadata.active = false; metadata.needsOnboarding = true; metadata.lastSignedInAt = "changed"
      f.scope.update(account: metadata)
      probe.releaseHold()
      let allowed = worker.join()
      #expect(allowed)
      f.scope.refuseNewWork()
      p2bOwnerCode(.signedOut) { try f.scope.enter() }
      try comparison.requireOriginalNativeSession()
      f.scope.admitWorkAgain()
      try f.scope.enter(); f.scope.leave()
      f.slot.set(f.scope)
      try comparison.requireOriginalNativeSession()
      f.slot.set(f.candidate)
      p2bOwnerRefusal { try comparison.requireOriginalNativeSession() }
      f.slot.set(f.scope)
      p2bOwnerRefusal { try comparison.requireOriginalNativeSession() }
      let replacement = try await f.install(f.scope)
      let newComparison = try replacement.carrier.captureInstalledAccountSessionComparison()
      try newComparison.requireOriginalNativeSession()
      p2bOwnerRefusal { try comparison.requireOriginalNativeSession() }
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB19NativeABALimitAndAcceptedOwnerABA() async throws {
    try await P2BOwnerFixture.withFixture(linked: true) { f in
      let installed = try await f.install(f.scope)
      let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
      let inspector = try f.native.inspector(f.scope.database)
      let account = f.scope.account
      try inspector.execute(
        "UPDATE public.\"hubLink\" SET url='https://other.invalid', \"deviceId\"='other', \"joinedAt\"='other', \"tokenRef\"='secret:other'"
      )
      try inspector.execute(
        "UPDATE public.\"hubLink\" SET url=$1, \"deviceId\"=$2, \"joinedAt\"=$3, \"tokenRef\"=$4",
        [account.hubURL, account.deviceId, P2BOwnerFixture.joinedAt, account.tokenRef])
      try comparison.requireOriginalNativeSession()  // Native A -> B -> A has no accepted owner boundary.
      try await f.retire()
      let probe = try f.native.probe(f.scope.database)
      p2bOwnerRefusal { try comparison.requireOriginalNativeSession() }
      let noCheckout = probe.snapshot().waitStart == nil
      #expect(noCheckout)
      let replacement = try await f.install(f.scope)
      let newComparison = try replacement.carrier.captureInstalledAccountSessionComparison()
      try newComparison.requireOriginalNativeSession()
      p2bOwnerRefusal { try comparison.requireOriginalNativeSession() }
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2bB20TransientOwnerLifetimeAndNoStrongerAuthority() async throws {
    let lifetime = try await makeP2BComparisonLifetime()
    do {
      // Only the actual in-flight comparison retains these original lifecycle objects now.
      let aliveDuringCleanup =
        lifetime.manager.value != nil && lifetime.scope.value != nil
        && lifetime.api.value != nil && !lifetime.nativeProbe.snapshot().freshFinishReturned
      #expect(aliveDuringCleanup)
      let retired = lifetime.slot.acceptScopeTransition(expectedPreparation: lifetime.retirement)
      #expect(retired)
      lifetime.slot.set(nil)
      let stillAlive =
        lifetime.manager.value != nil && lifetime.scope.value != nil && lifetime.api.value != nil
      #expect(stillAlive)
      lifetime.nativeProbe.releaseHold()
      let terminal = lifetime.worker.join()
      #expect(terminal)
      try p2bOwnerRequire(terminal)
      p2bOwnerCleanup(lifetime.nativeProbe.snapshot())
      let finiteSessionAbsent = p2bOwnerPoll {
        (try? lifetime.resources.native.sessionAbsent(lifetime.resources.databases[0])) == true
      }
      #expect(finiteSessionAbsent)
      let expired = await lifetime.effects.signal.until(timeout: .seconds(10)) {
        lifetime.manager.value == nil && lifetime.scope.value == nil && lifetime.api.value == nil
          && lifetime.effects.counts.destructions == 1 && lifetime.effects.counts.reentries == 1
          && lifetime.effects.counts.reentrySawNil == 1
      }
      #expect(expired)
      try p2bOwnerRequire(expired && finiteSessionAbsent)
      let before = lifetime.nativeProbe.snapshot().sequence
      p2bOwnerRefusal { try lifetime.comparison.requireOriginalNativeSession() }
      p2bOwnerRefusal { _ = try lifetime.carrier.captureInstalledAccountSessionComparison() }
      p2bOwnerRefusal { try lifetime.carrier.requireOrdinaryMemory() }
      p2bOwnerRefusal { try lifetime.carrier.requireFinalPushMemory() }
      p2bOwnerRefusal { try lifetime.carrier.requireSessionDisposalMemory() }
      let noNewNative = lifetime.nativeProbe.snapshot().sequence == before
      #expect(noNewNative)
      lifetime.resources.finish()
    } catch {
      lifetime.nativeProbe.releaseHold()
      _ = lifetime.worker.join()
      lifetime.resources.finish()
      throw P2BOwnerFixtureFailure.incomplete
    }
  }
}

private enum P2BOwnerFixtureFailure: Error { case incomplete }

private func p2bOwnerIsLinked(_ presence: AccountSessionPresence) -> Bool {
  switch presence {
  case .nativeAbsent: false
  case .nativeLinked: true
  }
}

private func p2bOwnerPoll(seconds: Int = 2, _ condition: () -> Bool) -> Bool {
  let expiry = DispatchTime.now() + .seconds(seconds)
  while !condition(), DispatchTime.now() < expiry { Thread.sleep(forTimeInterval: 0.005) }
  return condition()
}

private func p2bOwnerOne(_ connection: PostgresConnection) throws {
  guard try connection.execute("SELECT 1 AS n").rows.first?.int("n") == 1 else {
    throw P2BOwnerFixtureFailure.incomplete
  }
}

private func p2bOwnerCleanup(_ sample: AccountSessionComparisonTestSample) {
  let finish = sample.phaseSequence[AccountSessionComparisonPhase.afterFreshFinishBeforeLeaseLeave.rawValue]
  let leave = sample.phaseSequence[AccountSessionComparisonPhase.afterLeaseLeave.rawValue]
  let signal = sample.phaseSequence[AccountSessionComparisonPhase.afterSlotSignal.rawValue]
  let ordered =
    sample.freshFinishReturned && sample.leaseEntered && sample.leaseLeft
    && sample.slotSignalled && finish > 0 && leave > finish && signal > leave
  let exactlyOnce =
    sample.phaseCounts[AccountSessionComparisonPhase.afterFreshFinishBeforeLeaseLeave.rawValue] == 1
    && sample.phaseCounts[AccountSessionComparisonPhase.afterLeaseLeave.rawValue] == 1
    && sample.phaseCounts[AccountSessionComparisonPhase.afterSlotSignal.rawValue] == 1
  #expect(ordered && exactlyOnce)
}

private func p2bOwnerSuccessful(_ sample: AccountSessionComparisonTestSample) {
  p2bOwnerCleanup(sample)
  let actualChecksAndCommands =
    sample.acceptedGuards == 255 && sample.refusedGuards == 0
    && sample.phaseCounts == Array(repeating: UInt(1), count: 13)
    && sample.commandStarts == [1, 1, 1, 1, 1]
    && sample.commandAcknowledgements == [1, 1, 1, 1, 1]
    && sample.resultClears == [1, 1, 1, 1, 1]
    && sample.factsDecoded == 1 && sample.selectReturns == 1
    && sample.rollbackAttempts == 1 && sample.rollbackAcknowledgements == 1
  #expect(actualChecksAndCommands)
}

private struct P2BOwnerObservation: Sendable {
  enum TestCase: Int, Sendable { case b17 = 17; case b18 = 18 }
  enum Boundary: String, Sendable {
    case setupEntered, setupReturned, baselineEffectsEntered, bodyEntered, bodyReturned, bodyThrew
    case effectsCheckEntered, effectsCheckReturned, nativeCleanupEntered, nativeCleanupReturned
    case nativeCleanupUnsettled, eventCleanupEntered, eventCleanupReturned
    case lifecycleCleanupEntered, lifecycleCleanupReturned, cleanupReturned, fixtureReturned
    case firstEndpointEntered, firstEndpointReturned
    case temporaryStateEntered, temporaryStateReturned
    case seedDatabaseEntered, seedDatabaseReturned
    case registryEntered, registryReturned
    case secretStoreEntered, secretStoreReturned
    case managerSlotEntered, managerSlotReturned
    case beforeStartEntered, beforeStartReturned
    case managerStartEntered, managerStartReturned
    case refreshJoinEntered, refreshJoinReturned
    case refreshTaskJoinEntered, refreshTaskJoinReturned
    case liveLinkSaveEntered, liveLinkSaveReturned
    case liveStartEntered, liveStartReturned
    case liveStopEntered, liveStopReturned
    case livePushEntered, livePushReturned
    case liveEventsEntered, liveEventsReturned
    case candidateStopEntered, candidateStopReturned
    case candidatePushEntered, candidatePushReturned
    case candidateEventsEntered, candidateEventsReturned
    case liveHubEntered, liveHubReturned
    case secondEndpointEntered, secondEndpointReturned
    case candidateDatabaseEntered, candidateDatabaseReturned
    case candidateOpenEntered, candidateOpenReturned
    case candidateHubEntered, candidateHubReturned
    case quietEffectsEntered, quietEffectsReturned
  }
  let testCase: TestCase
  let fixtureIndex: Int
  private let started: UInt64
  init(testCase: TestCase, fixtureIndex: Int) {
    self.testCase = testCase
    self.fixtureIndex = fixtureIndex
    self.started = DispatchTime.now().uptimeNanoseconds
  }
  func record(_ boundary: Boundary) {
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed = now >= started ? now - started : 0
    print(
      "p2b_owner_boundary test=\(testCase.rawValue) fixture=\(fixtureIndex) phase=\(boundary.rawValue) elapsed_ns=\(elapsed)"
    )
  }
}

private final class P2BOwnerNativeHold: Sendable {
  private struct State { var entered = false; var released = false; var expired = false }
  private let cell = Mutex(State())
  private let semaphore = DispatchSemaphore(value: 0)
  private let expiry = DispatchTime.now() + .seconds(10)
  var entered: Bool { cell.withLock { $0.entered } }
  func wait() -> Bool {
    let released = cell.withLock {
      $0.entered = true; return $0.released
    }
    if released { return true }
    let returned = semaphore.wait(timeout: expiry) == .success
    if !returned { cell.withLock { $0.expired = true } }
    return returned
  }
  func release() {
    let first = cell.withLock {
      if $0.released { return false }; $0.released = true; return true
    }
    if first { semaphore.signal() }
  }
}

private final class P2BOwnerNativeWorker: Sendable {
  private let operation: Mutex<(@Sendable () throws -> Bool)?>
  private let result = Mutex<Bool?>(nil)
  private let joined = Mutex<Bool?>(nil)
  private let terminal = DispatchGroup()
  init(_ body: @escaping @Sendable () throws -> Bool) { operation = Mutex(body) }
  func start() {
    terminal.enter()
    Thread.detachNewThread { [self] in
      let body = operation.withLock {
        let previous = $0; $0 = nil; return previous
      }
      let outcome: Bool
      do { outcome = try body?() ?? false } catch { outcome = false }
      result.withLock { $0 = outcome }
      terminal.leave()
    }
  }
  // Finite driver terminal marker; this is never called a physical native-quiescence theorem.
  func settle() -> Bool {
    if let previous = joined.withLock({ $0 }) { return previous }
    let returned = terminal.wait(timeout: .now() + .seconds(12)) == .success
    joined.withLock { $0 = returned }
    return returned
  }
  func join() -> Bool { settle() && result.withLock { $0 == true } }
}

private final class P2BOwnerNativeResources: Sendable {
  private struct State {
    var holds: [P2BOwnerNativeHold] = []
    var workers: [P2BOwnerNativeWorker] = []
    var probes: [(WorkspaceDatabase, AccountSessionComparisonTestProbe)] = []
    var inspectors: [(ObjectIdentifier, Bool, PostgresConnection)] = []
  }
  private let cell = Mutex(State())
  func hold() -> P2BOwnerNativeHold {
    let hold = P2BOwnerNativeHold()
    cell.withLock { $0.holds.append(hold) }
    return hold
  }
  func worker(_ body: @escaping @Sendable () throws -> Bool) -> P2BOwnerNativeWorker {
    let worker = P2BOwnerNativeWorker(body)
    cell.withLock { $0.workers.append(worker) }
    worker.start()
    return worker
  }
  func probe(
    _ database: WorkspaceDatabase, phase: AccountSessionComparisonPhase? = nil
  ) throws -> AccountSessionComparisonTestProbe {
    let probe = AccountSessionComparisonTestProbe(
      hold: phase.map { AccountSessionComparisonTestHold(phase: $0, expiry: .now() + .seconds(10)) })
    let installed = database.installAccountSessionComparisonTestProbe(probe)
    #expect(installed)
    guard installed else { throw P2BOwnerFixtureFailure.incomplete }
    cell.withLock { $0.probes.append((database, probe)) }
    return probe
  }
  func inspector(_ database: WorkspaceDatabase, observer: Bool = false) throws -> PostgresConnection {
    let identity = ObjectIdentifier(database)
    if let cached = cell.withLock({ $0.inspectors.first { $0.0 == identity && $0.1 == observer }?.2 }) {
      return cached
    }
    let endpoint = database.endpoint
    guard let bin = endpoint.binDir else { throw P2BOwnerFixtureFailure.incomplete }
    let connection = try PostgresConnection(
      lib: LibPQ.load(binDir: bin),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database) application_name=p2b_owner_inspector"
    )
    cell.withLock { $0.inspectors.append((identity, observer, connection)) }
    return connection
  }
  func relationWait(_ database: WorkspaceDatabase) throws -> Bool {
    let connection = try inspector(database, observer: true)
    return try connection.execute(
      "SELECT count(*) AS n FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE a.datname=$1 AND a.application_name='b4app' AND l.relation='public.\"hubLink\"'::regclass AND l.mode='AccessShareLock' AND NOT l.granted",
      [database.endpoint.database]
    ).rows.first?.int("n") == 1
  }
  func sessionAbsent(_ database: WorkspaceDatabase) throws -> Bool {
    let connection = try inspector(database, observer: true)
    return try connection.execute(
      "SELECT count(*) AS n FROM pg_stat_activity WHERE datname=$1 AND application_name='b4app'",
      [database.endpoint.database]
    ).rows.first?.int("n") == 0
  }
  func image(_ database: WorkspaceDatabase) throws -> [String: [Data]] {
    let connection = try inspector(database)
    var result: [String: [Data]] = [:]
    for row in try connection.execute(
      "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows {
      guard let table = row.text("tablename") else { throw P2BOwnerFixtureFailure.incomplete }
      result[table] = try connection.execute(
        "SELECT to_jsonb(t)::text AS value FROM public.\(Rows.quote(table)) t"
      ).rows.map {
        guard let text = $0.text("value") else { throw P2BOwnerFixtureFailure.incomplete }
        return Data(text.utf8)
      }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    for row in try connection.execute("SELECT sequencename FROM pg_sequences WHERE schemaname='public'").rows
    {
      guard let sequence = row.text("sequencename"),
        let text = try connection.execute(
          "SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value FROM public.\(Rows.quote(sequence))"
        ).rows.first?.text("value")
      else { throw P2BOwnerFixtureFailure.incomplete }
      result["sequence:" + sequence] = [Data(text.utf8)]
    }
    return result
  }
  @discardableResult func finish() -> Bool {
    let snapshot = cell.withLock { $0 }
    // Release ALL registered holds first, on every success/error path, before any worker join.
    for hold in snapshot.holds { hold.release() }
    for (_, probe) in snapshot.probes { probe.releaseHold() }
    var settled = true
    for worker in snapshot.workers {
      let joined = worker.settle()
      if joined { let outcome = worker.join(); #expect(outcome) }
      settled = joined && settled
    }
    guard settled else { return false }
    for (database, probe) in snapshot.probes { _ = database.clearAccountSessionComparisonTestProbe(probe) }
    // Transfer resource references out of the short cell before releasing any connection.
    let previous = cell.withLock {
      let previous = $0; $0 = State(); return previous
    }
    withExtendedLifetime(previous) {}
    return true
  }
}

extension P2BOwnerFixture {
  func retire() async throws {
    let preparation = try await manager.beginDormantScopePreparation()
    let retired = slot.acceptScopeTransition(expectedPreparation: preparation)
    #expect(retired)
    guard retired else { throw P2BOwnerFixtureFailure.incomplete }
  }
}

// This result has NO manager/scope/hub/origin/API or closure that could retain one.
private struct P2BComparisonLifetimeResources: Sendable {
  let root: String
  let registry: AccountRegistry
  let events: EventLog
  let databases: [WorkspaceDatabase]
  let native: P2BOwnerNativeResources
  func finish() {
    let joined = native.finish()
    #expect(joined)
    guard joined else { return }
    registry.close()
    var drained = true
    for database in databases {
      let result = database.closeForMigration(timeout: .seconds(2))
      #expect(result)
      drained = result && drained
    }
    if drained {
      do { try FileManager.default.removeItem(atPath: root) } catch {
        Issue.record("The drained comparison lifetime root could not be removed.")
      }
    } else {
      Issue.record("The comparison lifetime root was retained because leases did not drain.")
    }
  }
}

private struct P2BComparisonLifetime: Sendable {
  let slot: AccountManager.Slot
  let retirement: AccountManager.Slot.ScopePreparation
  let manager: P2BOwnerWeak<AccountManager>
  let scope: P2BOwnerWeak<AccountScope>
  let api: P2BOwnerWeak<P2BOwnerAPIProbe>
  let effects: P2BOwnerProbe
  let carrier: HubOwnerCarrier
  let comparison: HubOwnerCarrier.AccountSessionComparison
  let nativeProbe: AccountSessionComparisonTestProbe
  let worker: P2BOwnerNativeWorker
  let resources: P2BComparisonLifetimeResources
}

private func makeP2BComparisonLifetime() async throws -> P2BComparisonLifetime {
  let f = try await P2BOwnerFixture.make(linked: true)
  do {
    let installed = try await f.install(f.scope)
    let comparison = try installed.carrier.captureInstalledAccountSessionComparison()
    // Settle known producers while the native DB stays OPEN for the actual comparison.
    await f.events.finish()
    await f.scope.hub.stop()
    if let refresh = await f.manager.refresh { refresh.cancel(); await refresh.value }
    await f.scope.sessions.shutdown()
    await f.scope.servers.shutdown()
    await f.candidate.close(stoppingServers: false, drainTimeout: .zero)
    let candidateDrained = f.candidate.database.closeForMigration(timeout: .seconds(2))
    #expect(candidateDrained)
    guard candidateDrained else { throw P2BOwnerFixtureFailure.incomplete }
    // Empty every cleanup array that owned scopes/attachments; no fixture cleanup escapes.
    await f.cleanup.releaseLifetimeOwnership(slot: f.slot)
    let nativeProbe = try f.native.probe(f.scope.database, phase: .beforeFreshFinish)
    // Explicit capture list: comparison contains weak lifecycle originals + DB/data only.
    let worker = f.native.worker { [comparison] in
      p2bOwnerRejected { try comparison.requireOriginalNativeSession() }
    }
    try p2bOwnerRequire(p2bOwnerPoll { nativeProbe.snapshot().holdEntered })
    let retirement = try await f.manager.beginDormantScopePreparation()
    let resources = P2BComparisonLifetimeResources(
      root: f.root, registry: f.registry, events: f.events,
      databases: [f.scope.database, f.candidate.database], native: f.native)
    return P2BComparisonLifetime(
      slot: f.slot, retirement: retirement,
      manager: P2BOwnerWeak(f.manager), scope: P2BOwnerWeak(f.scope), api: f.probe.weakAPI,
      effects: f.probe, carrier: installed.carrier, comparison: comparison, nativeProbe: nativeProbe,
      worker: worker, resources: resources)
    // f, installed and all actual publication/displacedScope locals end here before retirement.
  } catch {
    await f.finish()
    Issue.record("The comparison lifetime fixture failed; private details were suppressed.")
    throw P2BOwnerFixtureFailure.incomplete
  }
}

private func p2bOwnerRequire(_ value: Bool) throws -> Void {
  #expect(value)
  guard value else { throw P2BOwnerFixtureFailure.incomplete }
}

private func p2bOwnerRequire<T>(_ value: T?) throws -> T {
  guard let value else {
    Issue.record("The scope-owner fixture was incomplete; private details were suppressed.")
    throw P2BOwnerFixtureFailure.incomplete
  }
  return value
}

private func p2bOwnerFixedFailure(_ error: any Error) -> Bool {
  guard let value = error as? WorkspaceError else { return false }
  return value.code == .internalError
    && value.message == "The protocol verification comparison could not be completed."
    && value.details == nil && (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
}

private func p2bOwnerRejected(_ body: () throws -> Void) -> Bool {
  do { try body(); return false } catch { return p2bOwnerFixedFailure(error) }
}

private func p2bOwnerRefusal(_ body: () throws -> Void) {
  do {
    try body()
    Issue.record("The scope-owner comparison unexpectedly admitted the operation.")
  } catch {
    let fixed = p2bOwnerFixedFailure(error)
    #expect(fixed)
  }
}

private func p2bOwnerRefusalAsync(_ body: () async throws -> Void) async {
  do {
    try await body()
    Issue.record("The scope-owner comparison unexpectedly admitted the operation.")
  } catch {
    let fixed = p2bOwnerFixedFailure(error)
    #expect(fixed)
  }
}

private func p2bOwnerCode(_ code: ErrorCode, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("The runtime gate unexpectedly admitted the operation.")
  } catch {
    let expected = (error as? WorkspaceError)?.code == code
    #expect(expected)
  }
}

private func p2bOwnerPrivacy<T>(_ value: T, name: String) {
  let redacted =
    String(describing: value) == name + "(redacted)"
    && String(reflecting: value) == name + "(redacted)"
  let empty = Mirror(reflecting: value).children.isEmpty
  let notCodable = !(value is any Encodable) && !(T.self is any Decodable.Type)
  #expect(redacted && empty && notCodable)
}

private func p2bOwnerPair(
  _ slot: AccountManager.Slot, scope: AccountScope?, key: AccountManager.Slot.ScopeOwnerKey?
) {
  let sample = slot.scopeOwnershipObservation()
  let exact = sample.scope === scope && sample.owner == key
  #expect(exact)
}

private struct P2BOwnerWeak<T: AnyObject & Sendable>: Sendable {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}

private final class P2BOwnerWeakSlot: Sendable {
  private let cell = Mutex(P2BOwnerWeak<AccountManager.Slot>(nil))
  func bind(_ slot: AccountManager.Slot) { cell.withLock { $0 = P2BOwnerWeak(slot) } }
  func get() -> AccountManager.Slot? { cell.withLock { $0 }.value }
}

private final class P2BOwnerProbe: Sendable {
  struct Counts: Sendable {
    var factory = 0
    var secretReads = 0
    var adapter = 0
    var calls = Array(repeating: 0, count: 11)
    var destructions = 0
    var reentries = 0
    var reentrySawNil = 0
  }
  private let cell = Mutex(Counts())
  private let apiCell = Mutex(P2BOwnerWeak<P2BOwnerAPIProbe>(nil))
  let slot = P2BOwnerWeakSlot()
  let signal = SyncSignal()
  var counts: Counts { cell.withLock { $0 } }
  var weakAPI: P2BOwnerWeak<P2BOwnerAPIProbe> { apiCell.withLock { $0 } }
  func recordSecret() { cell.withLock { $0.secretReads += 1 } }
  func recordAdapter() { cell.withLock { $0.adapter += 1 } }
  func recordCall(_ index: Int) { cell.withLock { $0.calls[index] += 1 } }
  func makeAPI() -> P2BOwnerAPIProbe {
    let api = P2BOwnerAPIProbe(self)
    cell.withLock { $0.factory += 1 }
    apiCell.withLock { $0 = P2BOwnerWeak(api) }
    return api
  }
  func destroyed(reentered: Bool, sawNil: Bool) {
    cell.withLock {
      $0.destructions += 1
      if reentered { $0.reentries += 1 }
      if sawNil { $0.reentrySawNil += 1 }
    }
    signal.fire()
  }
}

private actor P2BOwnerSecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  private let probe: P2BOwnerProbe
  init(_ probe: P2BOwnerProbe) { self.probe = probe }
  nonisolated var backend: String { "scope-owner-fixture" }
  func put(_ ref: SecretRef, value: String) { values[ref] = value }
  func read(_ ref: SecretRef) -> String? { probe.recordSecret(); return values[ref] }
  func remove(_ ref: SecretRef) -> Bool { values.removeValue(forKey: ref) != nil }
}

private final class P2BOwnerAPIProbe: HubAPI {
  private let probe: P2BOwnerProbe
  init(_ probe: P2BOwnerProbe) { self.probe = probe }
  deinit {
    // The weak box is copied out of its cell before upgrading, entering Slot, or firing a signal.
    let slot = probe.slot.get()
    let sawNil = slot.map { $0.get() == nil } ?? false
    probe.destroyed(reentered: slot != nil, sawNil: sawNil)
  }
  private func refuse<T>(_ index: Int) throws -> T {
    probe.recordCall(index)
    throw WorkspaceError(.protocolInvalid, "The scope-owner fixture does not serve requests.")
  }
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try refuse(0) }
  func me() async throws -> MeResponse { try refuse(1) }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try refuse(2) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse { try refuse(3) }
  func snapshot() async throws -> SnapshotResponse { try refuse(4) }
  func devices() async throws -> [DeviceInfo] { try refuse(5) }
  func mintPairingCode() async throws -> PairingCodeResponse { try refuse(6) }
  func revokeSelf() async throws { let _: Void = try refuse(7) }
  func readiness() async throws -> HubReadiness { try refuse(8) }
  func endSession() async throws { let _: Void = try refuse(9) }
  func enroll(_ request: EnrollRequest, replacingToken token: String?) async throws -> EnrollResponse {
    try refuse(10)
  }
}

private struct P2BOwnerEffects: Sendable, Equatable {
  let factory: Int
  let secretReads: Int
  let requests: [Int]
  let adapter: Int
  let linkOpens: Int
  let eventSequence: Int
  let takes: Int
  let drops: Int
}

private final class P2BOwnerCleanup: Sendable {
  private struct State {
    var scopes: [AccountScope] = []
    var databases: [WorkspaceDatabase] = []
    var pending: [AccountManager.Slot.ScopeOwnerReservation] = []
    var attachments: [(HubSync, HubSync.ScopeOwnerAttachment)] = []
  }
  private let cell = Mutex(State())
  func scope(_ scope: AccountScope) { cell.withLock { $0.scopes.append(scope) } }
  func database(_ database: WorkspaceDatabase) { cell.withLock { $0.databases.append(database) } }
  func pending(_ value: AccountManager.Slot.ScopeOwnerReservation) {
    cell.withLock { $0.pending.append(value) }
  }
  func attachment(_ value: HubSync.ScopeOwnerAttachment, hub: HubSync) {
    cell.withLock { $0.attachments.append((hub, value)) }
  }
  func finish(manager: AccountManager?, slot: AccountManager.Slot?) async -> Bool {
    let state = cell.withLock { value in
      let previous = value
      value = State()
      return previous
    }
    if let slot {
      for reservation in state.pending { _ = slot.cancelScopeOwnerReservation(reservation) }
    }
    for (hub, attachment) in state.attachments { _ = await hub.detachDormantScopeOwner(attachment) }
    if let manager, let refresh = await manager.refresh { refresh.cancel(); await refresh.value }
    for scope in state.scopes { await scope.close(stoppingServers: false, drainTimeout: .zero) }
    if let manager { await manager.shutdown() }
    var drained = true
    for database in state.databases {
      let closed = database.closeForMigration(timeout: .seconds(2))
      #expect(closed)
      drained = closed && drained
    }
    return drained
  }
  // Transfer only already-drained, non-scope resources into the lexical lifetime result.
  func releaseLifetimeOwnership(slot: AccountManager.Slot) async {
    let state = cell.withLock { value in
      let previous = value
      value = State()
      return previous
    }
    for reservation in state.pending { _ = slot.cancelScopeOwnerReservation(reservation) }
    for (hub, attachment) in state.attachments { _ = await hub.detachDormantScopeOwner(attachment) }
  }
}

private struct P2BOwnerFixture: Sendable {
  static let base = "https://scope-owner.invalid/Deployment"
  static let joinedAt = "2026-11-15T00:00:00.000Z"
  let root: String
  let registry: AccountRegistry
  let manager: AccountManager
  let slot: AccountManager.Slot
  let scope: AccountScope
  let candidate: AccountScope
  let context: AccountScope.Context
  let events: EventLog
  let probe: P2BOwnerProbe
  let secrets: P2BOwnerSecretStore
  let links: FakeHubLinkConnection
  let power: FakePowerAssertions
  let cleanup: P2BOwnerCleanup
  let native = P2BOwnerNativeResources()

  static func withFixture(
    ownerRevision: UInt64? = nil, lifecycleSerial: UInt64? = nil,
    beforeStart: @Sendable (AccountManager, AccountManager.Slot) async throws -> Void = { _, _ in },
    linked: Bool, observation: P2BOwnerObservation? = nil,
    body: @Sendable (P2BOwnerFixture) async throws -> Void
  ) async throws {
    observation?.record(.setupEntered)
    let f = try await make(
      ownerRevision: ownerRevision, lifecycleSerial: lifecycleSerial,
      beforeStart: beforeStart, linked: linked, observation: observation)
    observation?.record(.setupReturned)
    do {
      observation?.record(.baselineEffectsEntered)
      let baseline = await f.effects()
      observation?.record(.bodyEntered)
      try await body(f)
      observation?.record(.bodyReturned)
      observation?.record(.effectsCheckEntered)
      await f.expectEffects(baseline)
      observation?.record(.effectsCheckReturned)
      await f.finish(observation: observation)
      observation?.record(.fixtureReturned)
    } catch {
      observation?.record(.bodyThrew)
      await f.finish(observation: observation)
      // Never let arbitrary resource errors render private rows or references in a test terminal.
      Issue.record("The scope-owner control failed; private details were suppressed.")
      throw P2BOwnerFixtureFailure.incomplete
    }
  }

  static func row(endpoint: PostgresEndpoint, reference: SecretRef) -> AccountRow {
    let id = AccountRegistry.newId()
    return AccountRow(
      id: id, hubURL: base, hubUserId: "scope-user-" + id, deviceId: "scope-device-" + id,
      database: endpoint.database, displayName: "Fixture User", orgName: "Fixture Org",
      tokenRef: reference.rawValue)
  }

  static func empty(_ database: WorkspaceDatabase) throws {
    let noConnections = try database.listConnections(includeDisabled: true).isEmpty
    let noThreads = try database.listThreads().isEmpty
    let noServers = try database.listLocalServers().isEmpty
    let noLink = try database.hubLink() == nil
    let noChanges = try database.unsyncedChanges(limit: 1).isEmpty
    #expect(noConnections && noThreads && noServers && noLink && noChanges)
    guard noConnections && noThreads && noServers && noLink && noChanges else {
      throw P2BOwnerFixtureFailure.incomplete
    }
  }

  static func make(
    ownerRevision: UInt64? = nil, lifecycleSerial: UInt64? = nil,
    beforeStart: @Sendable (AccountManager, AccountManager.Slot) async throws -> Void = { _, _ in },
    linked: Bool, observation: P2BOwnerObservation? = nil
  ) async throws -> Self {
    observation?.record(.firstEndpointEntered)
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    observation?.record(.firstEndpointReturned)
    let binDir = try p2bOwnerRequire(endpoint.binDir)
    observation?.record(.temporaryStateEntered)
    let root =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory()
      + "scope-owner-" + UUID().uuidString.lowercased()
    let cleanup = P2BOwnerCleanup()
    var registry: AccountRegistry?
    var manager: AccountManager?
    var slot: AccountManager.Slot?
    let events = EventLog()
    do {
      try PrivateFiles.ensurePrivateDirectory(root)
      try PrivateFiles.ensurePrivateDirectory(root + "/rt")
      try PrivateFiles.ensurePrivateDirectory(root + "/data")
      var paths = PlatformPaths(runtimeDir: root + "/rt", dataDir: root + "/data")
      paths.postgres = endpoint
      let environment = [
        "PATH": "/nonexistent", "HOME": paths.dataDir, "TMPDIR": root,
        "B4APP_RUNTIME_DIR": paths.runtimeDir, "B4APP_DATA_DIR": paths.dataDir,
        "B4APP_NODE_PATH": "/nonexistent/node", ExecutableLocator.fallbackOverrideVariable: "",
      ]
      observation?.record(.temporaryStateReturned)
      observation?.record(.seedDatabaseEntered)
      let seed = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir)
      cleanup.database(seed)
      try empty(seed)
      try seed.close()
      observation?.record(.seedDatabaseReturned)
      let probe = P2BOwnerProbe()
      let secrets = P2BOwnerSecretStore(probe)
      let links = FakeHubLinkConnection()
      let power = FakePowerAssertions()
      observation?.record(.registryEntered)
      let actualRegistry = try AccountRegistry(
        endpoint: endpoint, binDir: binDir,
        databaseName: AccountManager.registryDatabaseName(for: endpoint))
      registry = actualRegistry
      let reference = SecretRef.make()
      let account = row(endpoint: endpoint, reference: reference)
      try actualRegistry.insert(account)
      try actualRegistry.activate(id: account.id, tokenRef: reference.rawValue)
      observation?.record(.registryReturned)
      observation?.record(.secretStoreEntered)
      await secrets.put(reference, value: "fixture-scope-owner-value")
      observation?.record(.secretStoreReturned)
      let diagnostics = DiagnosticsService(
        context: DiagnosticsService.Context(
          paths: paths, startedAt: joinedAt, environment: environment,
          secretStore: secrets, eventLog: events))
      let context = AccountScope.Context(
        paths: paths, environment: environment, secretStore: secrets, eventLog: events,
        diagnostics: diagnostics,
        adapterFactory: { _, _, _, _ in
          probe.recordAdapter()
          throw P2BOwnerFixtureFailure.incomplete
        }, hubAPIFactory: { _, _ in probe.makeAPI() }, hubLinkConnection: links,
        powerAssertions: power, checkRetryDelays: [], threadDeleteSweep: .zero)
      let actualManager = AccountManager(
        context: AccountManager.Context(
          cluster: StoreCluster(endpoint: endpoint, binDir: binDir, ownedServer: nil),
          registry: actualRegistry, scope: context, flavor: .local))
      manager = actualManager
      observation?.record(.managerSlotEntered)
      let actualSlot = await actualManager.slot
      observation?.record(.managerSlotReturned)
      slot = actualSlot
      probe.slot.bind(actualSlot)
      if ownerRevision != nil || lifecycleSerial != nil {
        try actualSlot.seedScopeOwnerCountersForTesting(
          ownerRevision: ownerRevision ?? 0, lifecycleSerial: lifecycleSerial ?? 0)
      }
      observation?.record(.beforeStartEntered)
      try await beforeStart(actualManager, actualSlot)
      observation?.record(.beforeStartReturned)
      observation?.record(.managerStartEntered)
      await actualManager.start()
      observation?.record(.managerStartReturned)
      let scope = try p2bOwnerRequire(actualManager.current)
      cleanup.scope(scope)
      cleanup.database(scope.database)
      let exact =
        scope.account.id == account.id && scope.account.database == endpoint.database
        && actualSlot.get() === scope
      #expect(exact)
      guard exact else { throw P2BOwnerFixtureFailure.incomplete }
      // The original unjoined /me throws WorkspaceError before reaching our fake API.
      observation?.record(.refreshJoinEntered)
      if let refresh = await actualManager.refresh {
        observation?.record(.refreshTaskJoinEntered)
        await refresh.value
        observation?.record(.refreshTaskJoinReturned)
      }
      observation?.record(.refreshJoinReturned)
      let unjoinedFactoryAndSecret = probe.counts.factory == 0 && probe.counts.secretReads == 0
      let unjoinedAPIAndAdapter = probe.counts.calls.allSatisfy { $0 == 0 } && probe.counts.adapter == 0
      let unjoinedLink = links.openCount == 0
      #expect(unjoinedFactoryAndSecret && unjoinedAPIAndAdapter && unjoinedLink)
      observation?.record(.liveHubEntered)
      if linked {
        observation?.record(.liveLinkSaveEntered)
        try scope.database.saveHubLink(
          WorkspaceDatabase.HubLink(
            url: account.hubURL, deviceId: account.deviceId, deviceName: "Fixture Mac",
            tokenRef: reference.rawValue, orgSlug: "fixture-org", username: "fixture-user",
            joinedAt: joinedAt))
        observation?.record(.liveLinkSaveReturned)
        // Do not stop first: real start installs the origin, then its nonnil nudge guard returns.
        observation?.record(.liveStartEntered)
        await scope.hub.start()
        observation?.record(.liveStartReturned)
      }
      observation?.record(.liveStopEntered)
      await scope.hub.stop()
      observation?.record(.liveStopReturned)
      observation?.record(.livePushEntered)
      let emptyPush = try await scope.hub.pushNow()
      observation?.record(.livePushReturned)
      #expect(emptyPush == 0)
      observation?.record(.liveEventsEntered)
      await events.finish()
      observation?.record(.liveEventsReturned)
      observation?.record(.liveHubReturned)
      observation?.record(.secondEndpointEntered)
      let candidateEndpoint = try AgentProtocolResourceFixture.endpoint()
      observation?.record(.secondEndpointReturned)
      let candidateBin = try p2bOwnerRequire(candidateEndpoint.binDir)
      observation?.record(.candidateDatabaseEntered)
      let candidateDatabase = try WorkspaceDatabase(endpoint: candidateEndpoint, binDir: candidateBin)
      cleanup.database(candidateDatabase)
      try empty(candidateDatabase)
      observation?.record(.candidateDatabaseReturned)
      observation?.record(.candidateOpenEntered)
      let candidate = await AccountScope.open(
        row: row(endpoint: candidateEndpoint, reference: SecretRef.make()), database: candidateDatabase,
        context: context, instance: UUID(), onUnauthorized: {})
      observation?.record(.candidateOpenReturned)
      cleanup.scope(candidate)
      observation?.record(.candidateHubEntered)
      observation?.record(.candidateStopEntered)
      await candidate.hub.stop()
      observation?.record(.candidateStopReturned)
      observation?.record(.candidatePushEntered)
      let candidatePush = try await candidate.hub.pushNow()
      observation?.record(.candidatePushReturned)
      #expect(candidatePush == 0)
      observation?.record(.candidateEventsEntered)
      await events.finish()
      observation?.record(.candidateEventsReturned)
      observation?.record(.candidateHubReturned)
      let f = Self(
        root: root, registry: actualRegistry, manager: actualManager, slot: actualSlot, scope: scope,
        candidate: candidate, context: context, events: events, probe: probe, secrets: secrets,
        links: links, power: power, cleanup: cleanup)
      observation?.record(.quietEffectsEntered)
      let initial = await f.effects()
      observation?.record(.quietEffectsReturned)
      let quiet =
        initial.factory == (linked ? 1 : 0) && initial.secretReads == 0
        && initial.requests.allSatisfy { $0 == 0 } && initial.adapter == 0
        && initial.linkOpens == 0 && initial.eventSequence == 0 && initial.takes == 0 && initial.drops == 0
      #expect(quiet)
      guard quiet else { throw P2BOwnerFixtureFailure.incomplete }
      return f
    } catch {
      await events.finish()
      let drained = await cleanup.finish(manager: manager, slot: slot)
      registry?.close()
      if drained { try? FileManager.default.removeItem(atPath: root) }
      Issue.record("The scope-owner fixture could not be constructed; private details were suppressed.")
      throw P2BOwnerFixtureFailure.incomplete
    }
  }

  func capture() throws -> ProtocolVerificationSnapshot {
    let link = try p2bOwnerRequire(scope.database.hubLink())
    return try scope.database.captureProtocolVerification(
      accountID: scope.account.id,
      expectedMembership: ProtocolNativeMembership(
        canonicalHubBase: link.url, deviceID: link.deviceId, linkJoinedAt: link.joinedAt))
  }

  func ordinary() async throws -> HubOwnerCarrier {
    try await manager.prepareDormantHubOwner(expectedScope: scope, originalSnapshot: capture())
  }

  func reserve(
    _ window: AccountManager.Slot.ScopePreparation, scope: AccountScope
  ) async throws
    -> AccountManager.PreparedScopeOwner
  {
    let prepared = try await manager.reserveDormantScopeOwner(preparation: window, expectedScope: scope)
    cleanup.pending(prepared.reservation)
    return prepared
  }

  func attach(
    _ prepared: AccountManager.PreparedScopeOwner, scope: AccountScope
  ) async throws
    -> HubSync.ScopeOwnerAttachment
  {
    let attachment = try await scope.hub.attachReservedScopeOwner(prepared.carrier)
    cleanup.attachment(attachment, hub: scope.hub)
    return attachment
  }

  func publish(
    _ prepared: AccountManager.PreparedScopeOwner, _ attachment: HubSync.ScopeOwnerAttachment,
    scope: AccountScope
  ) async throws -> AccountManager.Slot.ScopePublication {
    try await manager.publishDormantReservedScope(
      expectedScope: scope, prepared: prepared, attachment: attachment)
  }

  func install(_ scope: AccountScope) async throws -> AccountManager.PreparedScopeOwner {
    let window = try await manager.beginDormantScopePreparation()
    let prepared = try await reserve(window, scope: scope)
    let attachment = try await attach(prepared, scope: scope)
    let publication = try await publish(prepared, attachment, scope: scope)
    p2bOwnerPair(slot, scope: scope, key: publication.key)
    return prepared
  }

  func rejectNetworkRoles(_ local: HubOwnerCarrier) async throws {
    p2bOwnerRefusal { try local.requireOrdinaryMemory() }
    p2bOwnerRefusal { try local.requireFinalPushMemory() }
    p2bOwnerRefusal { try local.requireSessionDisposalMemory() }
    p2bOwnerRefusal { _ = try local.registerChild() }
    p2bOwnerRefusal { _ = try local.originalScope(for: manager) }
    p2bOwnerRefusal { _ = try local.originalOwnerKey(for: manager) }
    p2bOwnerRefusal { _ = try local.cleanupKey(for: manager) }
    await p2bOwnerRefusalAsync { _ = try await manager.beginDormantHubCleanup(original: local) }
    await p2bOwnerRefusalAsync {
      _ = try await manager.advanceDormantHubCleanupToSessionDisposal(original: local, finalPush: local)
    }
    let noRevoke = await manager.revokeDormantHubCleanupPhase(local)
    let noFinish = await manager.finishDormantHubCleanup(local)
    #expect(!noRevoke && !noFinish)
  }

  func effects() async -> P2BOwnerEffects {
    let counts = probe.counts
    return P2BOwnerEffects(
      factory: counts.factory, secretReads: counts.secretReads, requests: counts.calls,
      adapter: counts.adapter, linkOpens: links.openCount, eventSequence: await events.sequence,
      takes: power.takes, drops: power.drops)
  }

  func expectEffects(_ before: P2BOwnerEffects) async {
    let unchanged = await effects() == before
    #expect(unchanged)
  }

  func finish(observation: P2BOwnerObservation? = nil) async {
    observation?.record(.nativeCleanupEntered)
    let nativeSettled = native.finish()
    observation?.record(.nativeCleanupReturned)
    #expect(nativeSettled)
    guard nativeSettled else {
      observation?.record(.nativeCleanupUnsettled)
      return
    }
    observation?.record(.eventCleanupEntered)
    await events.finish()
    observation?.record(.eventCleanupReturned)
    observation?.record(.lifecycleCleanupEntered)
    let drained = await cleanup.finish(manager: manager, slot: slot)
    observation?.record(.lifecycleCleanupReturned)
    registry.close()
    if drained {
      do { try FileManager.default.removeItem(atPath: root) } catch {
        Issue.record("The drained scope-owner private root could not be removed.")
      }
    } else {
      Issue.record("The scope-owner private root was retained because its leases did not drain.")
    }
    observation?.record(.cleanupReturned)
  }
}
