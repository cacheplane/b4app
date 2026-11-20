import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

// These are dormant memory controls. Real scope construction opens native stores; the counted
// fake API is not authenticated transport evidence. A local attachment is not a native lease.
@Suite(NativeDBResources(), .serialized, .timeLimit(.minutes(1))) struct ScopeOwnerPublicationTests {
  @Test func p2aA01OldOwnerSurvivesReservation() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      let ordinary = try await f.ordinary()
      let child = try ordinary.registerChild()
      let baseline = await f.effects()
      let window = try await f.manager.beginDormantScopePreparation()
      let prepared = try await f.reserve(window, scope: f.candidate)
      let attach = try f.held {
        try await f.attach(prepared, scope: f.candidate)
      }
      await attach.entered.wait()
      let oldVisible = f.slot.get() === f.scope
      #expect(oldVisible)
      try ordinary.requireOrdinaryMemory()
      try child.requireOrdinaryMemory()
      try prepared.carrier.requireReservedScopeOwnerMemory()
      scopeOwnerRefusal { try prepared.carrier.requireInstalledScopeOwnerMemory() }
      try await f.rejectNetworkRoles(prepared.carrier)
      attach.release.open()
      let attachment = try await attach.task.value
      let publish = try f.held {
        try await f.manager.publishDormantReservedScope(
          expectedScope: f.candidate, prepared: prepared, attachment: attachment)
      }
      await publish.entered.wait()
      try ordinary.requireOrdinaryMemory()
      try child.requireOrdinaryMemory()
      let stillOld = f.slot.get() === f.scope
      #expect(stillOld)
      publish.release.open()
      let result = try await publish.task.value
      scopeOwnerPair(f.slot, scope: f.candidate, key: result.key)
      let displaced = result.displacedScope === f.scope
      #expect(displaced)
      try prepared.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      scopeOwnerRefusal { try child.requireOrdinaryMemory() }
      scopeOwnerPrivacy(window, name: "ScopePreparation")
      scopeOwnerPrivacy(prepared, name: "PreparedScopeOwner")
      scopeOwnerPrivacy(prepared.reservation, name: "ScopeOwnerReservation")
      scopeOwnerPrivacy(prepared.reservation.key, name: "ScopeOwnerKey")
      scopeOwnerPrivacy(prepared.reservation.key.closed, name: "ClosedScopeKey")
      scopeOwnerPrivacy(attachment, name: "ScopeOwnerAttachment")
      scopeOwnerPrivacy(attachment.identity, name: "ScopeAttachmentIdentity")
      scopeOwnerPrivacy(result, name: "ScopePublication")
      scopeOwnerPrivacy(prepared.carrier, name: "HubOwnerCarrier")
      await f.expectEffects(baseline)
    }
  }

  @Test func p2aA02NilPublicationHasNoGap() async throws {
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      f.slot.set(nil)
      let baseline = await f.effects()
      let window = try await f.manager.beginDormantScopePreparation()
      scopeOwnerPair(f.slot, scope: nil, key: nil)
      let prepared = try await f.reserve(window, scope: f.candidate)
      try prepared.carrier.requireReservedScopeOwnerMemory()
      scopeOwnerRefusal { try prepared.carrier.requireInstalledScopeOwnerMemory() }
      scopeOwnerPair(f.slot, scope: nil, key: nil)
      let attachment = try await f.attach(prepared, scope: f.candidate)
      scopeOwnerPair(f.slot, scope: nil, key: nil)
      let result = try await f.publish(prepared, attachment, scope: f.candidate)
      let noDisplaced = result.displacedScope == nil
      #expect(noDisplaced)
      scopeOwnerPair(f.slot, scope: f.candidate, key: result.key)
      try prepared.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerRefusal { try prepared.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync {
        _ = try await f.publish(prepared, attachment, scope: f.candidate)
      }
      scopeOwnerPair(f.slot, scope: f.candidate, key: result.key)
      await f.expectEffects(baseline)
    }
  }

  @Test func p2aA03LocalOwnerHasNoOriginOrEffects() async throws {
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      let baseline = await f.effects()
      let window = try await f.manager.beginDormantScopePreparation()
      let prepared = try await f.reserve(window, scope: f.candidate)
      try prepared.carrier.requireReservedScopeOwnerMemory()
      try await f.rejectNetworkRoles(prepared.carrier)
      let attachment = try await f.attach(prepared, scope: f.candidate)
      let noOriginAtAttachment = attachment.identity.configuredOrigin == nil
      #expect(noOriginAtAttachment)
      let result = try await f.publish(prepared, attachment, scope: f.candidate)
      try prepared.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerPair(f.slot, scope: f.candidate, key: result.key)
      try await f.rejectNetworkRoles(prepared.carrier)
      await f.expectEffects(baseline)
      let noFactoryOrSecret = f.probe.counts.factory == 0 && f.probe.counts.secretReads == 0
      #expect(noFactoryOrSecret)
    }
  }

  @Test func p2aA04AttachmentIsExact() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      try await ScopeOwnerFixture.withFixture(linked: false) { foreign in
        let origin = try await f.scope.hub.captureConfiguredClientOrigin()
        let window = try await f.manager.beginDormantScopePreparation()
        let prepared = try await f.reserve(window, scope: f.scope)
        let foreignWindow = try await foreign.manager.beginDormantScopePreparation()
        let foreignPrepared = try await foreign.reserve(foreignWindow, scope: foreign.candidate)
        let foreignAttachment = try await foreign.attach(foreignPrepared, scope: foreign.candidate)
        let baseline = await f.effects()
        await scopeOwnerRefusalAsync {
          _ = try await f.attach(prepared, scope: f.candidate)
        }
        let attachment = try await f.attach(prepared, scope: f.scope)
        let exact =
          attachment.identity.owner == prepared.reservation.key
          && attachment.identity.hub == ObjectIdentifier(f.scope.hub)
          && attachment.identity.database == ObjectIdentifier(f.scope.database)
          && attachment.identity.configuredOrigin == origin.identity
        #expect(exact)
        let repeated = try await f.scope.hub.attachReservedScopeOwner(prepared.carrier)
        let idempotent = repeated.identity == attachment.identity
        #expect(idempotent)
        await scopeOwnerRefusalAsync {
          _ = try await f.publish(prepared, attachment, scope: f.candidate)
        }
        await scopeOwnerRefusalAsync {
          _ = try await f.publish(prepared, foreignAttachment, scope: f.scope)
        }
        await scopeOwnerRefusalAsync {
          _ = try await f.manager.publishDormantReservedScope(
            expectedScope: f.scope, prepared: foreignPrepared, attachment: attachment)
        }
        try prepared.carrier.requireReservedScopeOwnerMemory()
        try foreignPrepared.carrier.requireReservedScopeOwnerMemory()
        scopeOwnerPair(foreign.slot, scope: foreign.scope, key: nil)
        scopeOwnerPair(f.slot, scope: f.scope, key: nil)
        let result = try await f.publish(prepared, attachment, scope: f.scope)
        scopeOwnerPair(f.slot, scope: f.scope, key: result.key)
        await f.expectEffects(baseline)
        // Retiring the actual source origin changes network admission, not the local Slot pair.
        await f.scope.hub.close()
        scopeOwnerRefusal { try origin.requireInstalledMemory() }
        try prepared.carrier.requireInstalledScopeOwnerMemory()
        try await f.rejectNetworkRoles(prepared.carrier)
        await f.expectEffects(baseline)
      }
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA05SameSetPreservesInstalled() async throws {
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      let installed = try await f.install(f.scope)
      let baseline = await f.effects()
      let window = try await f.manager.beginDormantScopePreparation()
      let pending = try await f.reserve(window, scope: f.candidate)
      f.slot.set(f.scope)
      try installed.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerPair(f.slot, scope: f.scope, key: installed.reservation.key)
      scopeOwnerRefusal { try pending.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.reserve(window, scope: f.candidate) }
      f.slot.set(nil)
      let nilWindow = try await f.manager.beginDormantScopePreparation()
      let nilPending = try await f.reserve(nilWindow, scope: f.candidate)
      f.slot.set(nil)
      scopeOwnerPair(f.slot, scope: nil, key: nil)
      scopeOwnerRefusal { try nilPending.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.reserve(nilWindow, scope: f.candidate) }
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA06ABAInvalidatesWindow() async throws {
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      let baseline = await f.effects()
      // A -> other -> A, A -> nil -> A, and nil -> A -> nil each invalidate both values.
      for route in 0..<3 {
        let initial: AccountScope? = route == 2 ? nil : f.scope
        f.slot.set(initial)
        let window = try await f.manager.beginDormantScopePreparation()
        let prepared = try await f.reserve(window, scope: f.candidate)
        let attachment = try await f.attach(prepared, scope: f.candidate)
        f.slot.set(route == 0 ? f.candidate : (route == 1 ? nil : f.scope))
        f.slot.set(initial)
        scopeOwnerRefusal { try prepared.carrier.requireReservedScopeOwnerMemory() }
        await scopeOwnerRefusalAsync { _ = try await f.reserve(window, scope: f.candidate) }
        await scopeOwnerRefusalAsync {
          _ = try await f.publish(prepared, attachment, scope: f.candidate)
        }
        scopeOwnerPair(f.slot, scope: initial, key: nil)
      }
      await f.expectEffects(baseline)
    }
  }

  @Test func p2aA07SupersessionAndExactCancel() async throws {
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      let third = try await f.makeCandidate()
      let baseline = await f.effects()
      let firstWindow = try await f.manager.beginDormantScopePreparation()
      let secondWindow = try await f.manager.beginDormantScopePreparation()
      let first = try await f.reserve(firstWindow, scope: f.candidate)
      let firstAttachment = try await f.attach(first, scope: f.candidate)
      let second = try await f.reserve(secondWindow, scope: third)
      let staleCancel = f.slot.cancelScopeOwnerReservation(first.reservation)
      #expect(!staleCancel)
      scopeOwnerRefusal { try first.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.publish(first, firstAttachment, scope: f.candidate) }
      try second.carrier.requireReservedScopeOwnerMemory()
      let secondAttachment = try await f.attach(second, scope: third)
      let result = try await f.publish(second, secondAttachment, scope: third)
      scopeOwnerPair(f.slot, scope: third, key: result.key)
      await scopeOwnerRefusalAsync { _ = try await f.publish(second, secondAttachment, scope: third) }
      let window = try await f.manager.beginDormantScopePreparation()
      let canceled = try await f.reserve(window, scope: f.candidate)
      let canceledAttachment = try await f.attach(canceled, scope: f.candidate)
      let exactCancel = f.slot.cancelScopeOwnerReservation(canceled.reservation)
      let repeatedCancel = f.slot.cancelScopeOwnerReservation(canceled.reservation)
      #expect(exactCancel && !repeatedCancel)
      await scopeOwnerRefusalAsync {
        _ = try await f.publish(canceled, canceledAttachment, scope: f.candidate)
      }
      try second.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerPair(f.slot, scope: third, key: result.key)
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA08TentativeVersusAccepted() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      let ordinary = try await f.ordinary()
      let baseline = await f.effects()
      let window = try await f.manager.beginDormantScopePreparation()
      let pending = try await f.reserve(window, scope: f.candidate)
      f.scope.refuseNewWork()
      scopeOwnerCode(.signedOut) { try f.scope.enter() }
      try ordinary.requireOrdinaryMemory()
      try pending.carrier.requireReservedScopeOwnerMemory()
      f.scope.admitWorkAgain()
      try f.scope.enter()
      f.scope.leave()
      let late = try f.held { () async throws -> Bool in
        do {
          _ = try await f.reserve(window, scope: f.candidate)
          return false
        } catch { return scopeOwnerFixedFailure(error) }
      }
      await late.entered.wait()
      let accepted = f.slot.acceptScopeTransition(expectedPreparation: window)
      #expect(accepted)
      scopeOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      scopeOwnerRefusal { try pending.carrier.requireReservedScopeOwnerMemory() }
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
      late.release.open()
      let staleContinuationRefused = try await late.task.value
      #expect(staleContinuationRefused)
      let repeated = f.slot.acceptScopeTransition(expectedPreparation: window)
      #expect(!repeated)
      // Local installed identity also survives a tentative runtime gate, then retires on acceptance.
      let installed = try await f.install(f.scope)
      f.scope.refuseNewWork()
      try installed.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerCode(.signedOut) { try f.scope.enter() }
      f.scope.admitWorkAgain()
      let acceptedWindow = try await f.manager.beginDormantScopePreparation()
      let localRetired = f.slot.acceptScopeTransition(expectedPreparation: acceptedWindow)
      #expect(localRetired)
      scopeOwnerRefusal { try installed.carrier.requireInstalledScopeOwnerMemory() }
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA09LegacyBoundariesInvalidate() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      let baseline = await f.effects()
      let root = try await f.ordinary()
      let owner = try root.originalOwnerKey(for: f.manager)
      let retireWindow = try await f.manager.beginDormantScopePreparation()
      let retired = try await f.reserve(retireWindow, scope: f.candidate)
      let exactRetirement = f.slot.retireOrdinary(owner)
      #expect(exactRetirement)
      scopeOwnerRefusal { try retired.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.reserve(retireWindow, scope: f.candidate) }
      let newerRoot = try await f.ordinary()
      let registerWindow = try await f.manager.beginDormantScopePreparation()
      let registered = try await f.reserve(registerWindow, scope: f.candidate)
      let newestRoot = try await f.ordinary()
      scopeOwnerRefusal { try newerRoot.requireOrdinaryMemory() }
      scopeOwnerRefusal { try registered.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.reserve(registerWindow, scope: f.candidate) }
      let cleanupWindow = try await f.manager.beginDormantScopePreparation()
      let cleanupPending = try await f.reserve(cleanupWindow, scope: f.candidate)
      let final = try await f.manager.beginDormantHubCleanup(original: newestRoot)
      try final.requireFinalPushMemory()
      scopeOwnerRefusal { try cleanupPending.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.reserve(cleanupWindow, scope: f.candidate) }
      let window = try await f.manager.beginDormantScopePreparation()
      let preserved = try await f.reserve(window, scope: f.candidate)
      let staleRetirement = f.slot.retireOrdinary(owner)
      #expect(!staleRetirement)
      scopeOwnerRefusal { _ = try f.slot.acceptCleanup(owner, manager: f.manager, scope: f.scope) }
      await scopeOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.candidate, originalSnapshot: f.capture())
      }
      try preserved.carrier.requireReservedScopeOwnerMemory()
      let attachment = try await f.attach(preserved, scope: f.candidate)
      _ = try await f.publish(preserved, attachment, scope: f.candidate)
      let localSurvivesStaleRetirement = !f.slot.retireOrdinary(owner)
      #expect(localSurvivesStaleRetirement)
      scopeOwnerRefusal { _ = try f.slot.acceptCleanup(owner, manager: f.manager, scope: f.scope) }
      try preserved.carrier.requireInstalledScopeOwnerMemory()
      // A valid legacy registration on the exact active/current A replaces installed local mode.
      let localOnActive = try await f.install(f.scope)
      try localOnActive.carrier.requireInstalledScopeOwnerMemory()
      let legacyReplacementWindow = try await f.manager.beginDormantScopePreparation()
      let pendingBeforeLegacy = try await f.reserve(legacyReplacementWindow, scope: f.candidate)
      try pendingBeforeLegacy.carrier.requireReservedScopeOwnerMemory()
      let replacementOrdinary = try await f.ordinary()
      scopeOwnerRefusal { try localOnActive.carrier.requireInstalledScopeOwnerMemory() }
      scopeOwnerRefusal { try pendingBeforeLegacy.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync {
        _ = try await f.reserve(legacyReplacementWindow, scope: f.candidate)
      }
      try replacementOrdinary.requireOrdinaryMemory()
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA10NilCleanupCompatibility() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      let ordinary = try await f.ordinary()
      let final = try await f.manager.beginDormantHubCleanup(original: ordinary)
      let baseline = await f.effects()
      f.slot.set(nil)
      try final.requireFinalPushMemory()
      scopeOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      let disposal = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
        original: ordinary, finalPush: final)
      scopeOwnerRefusal { try final.requireFinalPushMemory() }
      try disposal.requireSessionDisposalMemory()
      await scopeOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: disposal, finalPush: final)
      }
      try disposal.requireSessionDisposalMemory()
      let revoked = await f.manager.revokeDormantHubCleanupPhase(disposal)
      let revokedTwice = await f.manager.revokeDormantHubCleanupPhase(disposal)
      let finished = await f.manager.finishDormantHubCleanup(disposal)
      let finishedTwice = await f.manager.finishDormantHubCleanup(disposal)
      #expect(revoked && !revokedTwice && finished && !finishedTwice)
      scopeOwnerRefusal { try disposal.requireSessionDisposalMemory() }
      f.slot.set(f.scope)
      let nextRoot = try await f.ordinary()
      let nextFinal = try await f.manager.beginDormantHubCleanup(original: nextRoot)
      f.slot.set(nil)
      try nextFinal.requireFinalPushMemory()
      f.slot.set(f.candidate)
      f.slot.set(nil)
      scopeOwnerRefusal { try nextFinal.requireFinalPushMemory() }
      await scopeOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: nextRoot, finalPush: nextFinal)
      }
      let local = try await f.install(f.candidate)
      try await f.rejectNetworkRoles(local.carrier)
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA11OwnerCounterExhaustion() async throws {
    try await ScopeOwnerFixture.withFixture(ownerRevision: UInt64.max - 1, linked: false) { f in
      let baseline = await f.effects()
      let installed = try await f.install(f.scope)
      let maximumOwnerRevision = installed.reservation.key.revision == UInt64.max
      #expect(maximumOwnerRevision)
      let window = try await f.manager.beginDormantScopePreparation()
      await scopeOwnerRefusalAsync { _ = try await f.reserve(window, scope: f.candidate) }
      try installed.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerPair(f.slot, scope: f.scope, key: installed.reservation.key)
      try await ScopeOwnerFixture.withFixture(linked: false) { foreign in
        let foreignInstalled = try await foreign.install(foreign.scope)
        let foreignWindow = try await foreign.manager.beginDormantScopePreparation()
        let foreignPending = try await foreign.reserve(foreignWindow, scope: foreign.candidate)
        let foreignCancelRefused = !foreign.slot.cancelScopeOwnerReservation(installed.reservation)
        #expect(foreignCancelRefused)
        try foreignPending.carrier.requireReservedScopeOwnerMemory()
        try foreignInstalled.carrier.requireInstalledScopeOwnerMemory()
        scopeOwnerPair(foreign.slot, scope: foreign.scope, key: foreignInstalled.reservation.key)
      }
      await f.expectEffects(baseline)
    }
    try await ScopeOwnerFixture.withFixture(ownerRevision: UInt64.max - 1, linked: true) { f in
      let root = try await f.ordinary()
      let key = try root.originalOwnerKey(for: f.manager)
      let maximumLegacyRevision = key.revision == UInt64.max
      #expect(maximumLegacyRevision)
      let baseline = await f.effects()
      await scopeOwnerRefusalAsync { _ = try await f.ordinary() }
      scopeOwnerRefusal { try root.requireOrdinaryMemory() }
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
      await f.expectEffects(baseline)
    }
    try await ScopeOwnerFixture.withFixture(ownerRevision: UInt64.max - 2, linked: true) { f in
      let third = try await f.makeCandidate()
      let ordinary = try await f.ordinary()
      let legacyKey = try ordinary.originalOwnerKey(for: f.manager)
      let rootUsesPenultimateRevision = legacyKey.revision == UInt64.max - 1
      #expect(rootUsesPenultimateRevision)
      let baseline = await f.effects()
      let firstWindow = try await f.manager.beginDormantScopePreparation()
      let secondWindow = try await f.manager.beginDormantScopePreparation()
      let pending = try await f.reserve(firstWindow, scope: f.candidate)
      let attachment = try await f.attach(pending, scope: f.candidate)
      let pendingUsesMaximum = pending.reservation.key.revision == UInt64.max
      #expect(pendingUsesMaximum)
      try pending.carrier.requireReservedScopeOwnerMemory()
      // This valid request supersedes B before refusing allocation at max. It must preserve A.
      await scopeOwnerRefusalAsync { _ = try await f.reserve(secondWindow, scope: third) }
      scopeOwnerRefusal { try pending.carrier.requireReservedScopeOwnerMemory() }
      await scopeOwnerRefusalAsync { _ = try await f.publish(pending, attachment, scope: f.candidate) }
      let staleCancel = f.slot.cancelScopeOwnerReservation(pending.reservation)
      #expect(!staleCancel)
      try ordinary.requireOrdinaryMemory()
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA12LifecycleCounterExhaustion() async throws {
    try await ScopeOwnerFixture.withFixture(lifecycleSerial: UInt64.max - 2, linked: false) { f in
      let baseline = await f.effects()
      scopeOwnerRefusal { try f.slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      let window = try await f.manager.beginDormantScopePreparation()
      let prepared = try await f.reserve(window, scope: f.scope)
      let attachment = try await f.attach(prepared, scope: f.scope)
      let result = try await f.publish(prepared, attachment, scope: f.scope)
      try prepared.carrier.requireInstalledScopeOwnerMemory()
      await scopeOwnerRefusalAsync { _ = try await f.manager.beginDormantScopePreparation() }
      await scopeOwnerRefusalAsync { _ = try await f.reserve(window, scope: f.candidate) }
      await scopeOwnerRefusalAsync { _ = try await f.publish(prepared, attachment, scope: f.scope) }
      let saturatedAcceptanceRefused = !f.slot.acceptScopeTransition(expectedPreparation: window)
      #expect(saturatedAcceptanceRefused)
      f.slot.set(f.scope)
      try prepared.carrier.requireInstalledScopeOwnerMemory()
      scopeOwnerPair(f.slot, scope: f.scope, key: result.key)
      f.slot.set(nil)
      scopeOwnerRefusal { try prepared.carrier.requireInstalledScopeOwnerMemory() }
      scopeOwnerPair(f.slot, scope: nil, key: nil)
      await f.expectEffects(baseline)
    }
    try await ScopeOwnerFixture.withFixture(
      lifecycleSerial: UInt64.max,
      beforeStart: { _, slot in
        scopeOwnerRefusal { try slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      }, linked: false
    ) { f in
      let baseline = await f.effects()
      await scopeOwnerRefusalAsync { _ = try await f.manager.beginDormantScopePreparation() }
      scopeOwnerRefusal { try f.slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
      await f.expectEffects(baseline)
    }
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      // A used actual manager Slot cannot be reset, even once current has become nil.
      f.slot.set(nil)
      scopeOwnerRefusal { try f.slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      let window = try await f.manager.beginDormantScopePreparation()
      scopeOwnerRefusal { try f.slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      let pending = try await f.reserve(window, scope: f.candidate)
      try pending.carrier.requireReservedScopeOwnerMemory()
      f.slot.set(nil)
      scopeOwnerRefusal { try f.slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      scopeOwnerRefusal { try pending.carrier.requireReservedScopeOwnerMemory() }
    }
    try await ScopeOwnerFixture.withFixture(
      beforeStart: { manager, slot in
        _ = try await manager.beginDormantScopePreparation()
        scopeOwnerPair(slot, scope: nil, key: nil)
        scopeOwnerRefusal { try slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      }, linked: false
    ) { f in
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
    }
    try await ScopeOwnerFixture.withFixture(
      ownerRevision: 0, lifecycleSerial: 0,
      beforeStart: { _, slot in
        // An all-zero first seed leaves every counter pristine. Only its one-use record differs.
        scopeOwnerRefusal { try slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      }, linked: false
    ) { f in
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
    }
    try await ScopeOwnerFixture.withFixture(
      beforeStart: { _, slot in
        slot.set(nil)
        scopeOwnerRefusal { try slot.seedScopeOwnerCountersForTesting(ownerRevision: 0, lifecycleSerial: 0) }
      }, linked: false
    ) { f in
      scopeOwnerPair(f.slot, scope: f.scope, key: nil)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA13ExpiredWeakOwners() async throws {
    let expired = try await makeExpiredScopeOwnerCarrier()
    defer { expired.resources.removeRootIfDrained() }
    let expiredOwners =
      expired.manager.value == nil && expired.scope.value == nil
      && expired.slot.value == nil && expired.api.value == nil
    #expect(expiredOwners)
    let reentered = expired.probe.counts.reentries == 1 && expired.probe.counts.reentrySawNil == 1
    #expect(reentered)
    scopeOwnerRefusal { try expired.carrier.requireReservedScopeOwnerMemory() }
    scopeOwnerRefusal { try expired.carrier.requireInstalledScopeOwnerMemory() }
    scopeOwnerRefusal { try expired.carrier.requireOrdinaryMemory() }
    scopeOwnerRefusal { try expired.carrier.requireFinalPushMemory() }
    scopeOwnerRefusal { try expired.carrier.requireSessionDisposalMemory() }
    // Its retained, drained database is intentional; it cannot replace any expired weak owner.
    let retainedDatabaseDrained = expired.database.closeForMigration(timeout: .seconds(2))
    #expect(retainedDatabaseDrained)
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA14DestructorReentersSlot() async throws {
    let lifetime = try await makeScopeOwnerLifetimeFixture()
    defer { lifetime.resources.removeRootIfDrained() }
    let soleSlotOwner =
      lifetime.manager.value == nil && lifetime.scope.value != nil
      && lifetime.api.value != nil && lifetime.probe.counts.reentries == 0
    #expect(soleSlotOwner)
    scopeOwnerRefusal { try lifetime.carrier.requireInstalledScopeOwnerMemory() }
    lifetime.slot.set(nil)
    let reentered = await lifetime.probe.signal.until(timeout: .seconds(10)) {
      lifetime.probe.counts.reentries == 1 && lifetime.probe.counts.reentrySawNil == 1
    }
    let released = lifetime.scope.value == nil && lifetime.api.value == nil
    #expect(reentered && released)
    let exactlyOneDestruction = lifetime.probe.counts.destructions == 1
    #expect(exactlyOneDestruction)
    scopeOwnerPair(lifetime.slot, scope: nil, key: nil)
    scopeOwnerRefusal { try lifetime.carrier.requireInstalledScopeOwnerMemory() }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA15SameCellPairObservation() async throws {
    try await ScopeOwnerFixture.withFixture(linked: false) { f in
      let baseline = await f.effects()
      let window = try await f.manager.beginDormantScopePreparation()
      let prepared = try await f.reserve(window, scope: f.candidate)
      let attachment = try await f.attach(prepared, scope: f.candidate)
      let samples = ScopeOwnerSamples()
      let sawBefore = Gate()
      let publish = Gate()
      f.cleanup.hold(sawBefore)
      f.cleanup.hold(publish)
      let reader = Task {
        for _ in 0..<64 {
          samples.observe(f.slot, old: f.scope, candidate: f.candidate, key: prepared.reservation.key)
          await Task.yield()
        }
        sawBefore.open()
        await publish.wait()
        while !Task.isCancelled {
          let isNew = samples.observe(
            f.slot, old: f.scope, candidate: f.candidate, key: prepared.reservation.key)
          if isNew { break }
          await Task.yield()
        }
      }
      f.cleanup.task {
        reader.cancel(); publish.open(); await reader.value
      }
      await sawBefore.wait()
      let observedOld = samples.counts.before > 0 && samples.counts.after == 0 && samples.counts.invalid == 0
      #expect(observedOld)
      publish.open()
      _ = try await f.publish(prepared, attachment, scope: f.candidate)
      let sawAfter = await samples.signal.until(timeout: .seconds(10)) {
        samples.counts.after > 0 || samples.counts.invalid > 0
      }
      reader.cancel()
      await reader.value
      #expect(sawAfter)
      let observedAtomicTransition =
        samples.counts.before > 0 && samples.counts.after > 0
        && samples.counts.invalid == 0
      #expect(observedAtomicTransition)
      let acceptedWindow = try await f.manager.beginDormantScopePreparation()
      let acceptedRetirement = f.slot.acceptScopeTransition(expectedPreparation: acceptedWindow)
      #expect(acceptedRetirement)
      scopeOwnerPair(f.slot, scope: f.candidate, key: nil)
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA16DormantNetworkContracts() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      let snapshot = try f.capture()
      let origin = try await f.scope.hub.captureConfiguredClientOrigin()
      let ordinary = try await f.manager.prepareDormantHubOwner(
        expectedScope: f.scope, originalSnapshot: snapshot)
      let baseline = await f.effects()
      try ordinary.requireOrdinaryMemory()
      try origin.requireInstalledMemory()
      let window = try await f.manager.beginDormantScopePreparation()
      let local = try await f.reserve(window, scope: f.candidate)
      try await f.rejectNetworkRoles(local.carrier)
      try ordinary.requireOrdinaryMemory()
      let final = try await f.manager.beginDormantHubCleanup(original: ordinary)
      scopeOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      try final.requireFinalPushMemory()
      await scopeOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: final, finalPush: final)
      }
      try final.requireFinalPushMemory()
      let disposal = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
        original: ordinary, finalPush: final)
      try disposal.requireSessionDisposalMemory()
      scopeOwnerRefusal { try final.requireFinalPushMemory() }
      let revoked = await f.manager.revokeDormantHubCleanupPhase(disposal)
      let finished = await f.manager.finishDormantHubCleanup(disposal)
      #expect(revoked && finished)
      scopeOwnerRefusal { try disposal.requireSessionDisposalMemory() }
      // The untouched HubOwnerCarrierTests companion supplies modern/native negative coverage.
      await f.expectEffects(baseline)
    }
  }

  @Test(.enabled(if: protocolFullMatrixEnabled))
  func p2aA17CancellationAndForeignDetach() async throws {
    try await ScopeOwnerFixture.withFixture(linked: true) { f in
      try await ScopeOwnerFixture.withFixture(linked: false) { foreign in
        let ordinary = try await f.ordinary()
        let baseline = await f.effects()
        let firstWindow = try await f.manager.beginDormantScopePreparation()
        let first = try await f.reserve(firstWindow, scope: f.candidate)
        let firstAttachment = try await f.attach(first, scope: f.candidate)
        let canceled = f.slot.cancelScopeOwnerReservation(first.reservation)
        #expect(canceled)
        scopeOwnerRefusal {
          _ = try HubOwnerCarrier.makeScopeOwner(
            reservation: first.reservation, manager: f.manager, scope: f.candidate)
        }
        try ordinary.requireOrdinaryMemory()
        let newer = try await f.reserve(firstWindow, scope: f.candidate)
        let newerAttachment = try await f.attach(newer, scope: f.candidate)
        let foreignWindow = try await foreign.manager.beginDormantScopePreparation()
        let foreignPrepared = try await foreign.reserve(foreignWindow, scope: foreign.candidate)
        let foreignAttachment = try await foreign.attach(foreignPrepared, scope: foreign.candidate)
        let staleDetach = await f.candidate.hub.detachDormantScopeOwner(firstAttachment)
        let foreignDetach = await f.candidate.hub.detachDormantScopeOwner(foreignAttachment)
        #expect(!staleDetach && !foreignDetach)
        scopeOwnerRefusal {
          _ = try HubOwnerCarrier.makeScopeOwner(
            reservation: newer.reservation, manager: foreign.manager, scope: f.candidate)
        }
        scopeOwnerRefusal {
          _ = try HubOwnerCarrier.makeScopeOwner(
            reservation: newer.reservation, manager: f.manager, scope: f.scope)
        }
        await scopeOwnerRefusalAsync { _ = try await f.publish(first, firstAttachment, scope: f.candidate) }
        try newer.carrier.requireReservedScopeOwnerMemory()
        try ordinary.requireOrdinaryMemory()
        let sameHolder = try await f.candidate.hub.attachReservedScopeOwner(newer.carrier)
        let exactHolder = sameHolder.identity == newerAttachment.identity
        #expect(exactHolder)
        let result = try await f.publish(newer, newerAttachment, scope: f.candidate)
        let staleCancelRefused = !f.slot.cancelScopeOwnerReservation(first.reservation)
        let staleDetachRefused = await !f.candidate.hub.detachDormantScopeOwner(firstAttachment)
        #expect(staleCancelRefused && staleDetachRefused)
        try newer.carrier.requireInstalledScopeOwnerMemory()
        scopeOwnerPair(f.slot, scope: f.candidate, key: result.key)
        let detached = await f.candidate.hub.detachDormantScopeOwner(newerAttachment)
        let repeated = await f.candidate.hub.detachDormantScopeOwner(newerAttachment)
        #expect(detached && !repeated)
        try newer.carrier.requireInstalledScopeOwnerMemory()
        let noClose = !f.candidate.isClosing
        #expect(noClose)
        await scopeOwnerRefusalAsync { _ = try await f.publish(newer, newerAttachment, scope: f.candidate) }
        await f.expectEffects(baseline)
      }
    }
  }
}

private enum ScopeOwnerFixtureFailure: Error { case incomplete }

private func scopeOwnerRequire<T>(_ value: T?) throws -> T {
  guard let value else {
    Issue.record("The scope-owner fixture was incomplete; private details were suppressed.")
    throw ScopeOwnerFixtureFailure.incomplete
  }
  return value
}

private func scopeOwnerFixedFailure(_ error: any Error) -> Bool {
  guard let value = error as? WorkspaceError else { return false }
  return value.code == .internalError
    && value.message == "The protocol verification comparison could not be completed."
    && value.details == nil && (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
}

private func scopeOwnerRefusal(_ body: () throws -> Void) {
  do {
    try body()
    Issue.record("The scope-owner comparison unexpectedly admitted the operation.")
  } catch {
    let fixed = scopeOwnerFixedFailure(error)
    #expect(fixed)
  }
}

private func scopeOwnerRefusalAsync(_ body: () async throws -> Void) async {
  do {
    try await body()
    Issue.record("The scope-owner comparison unexpectedly admitted the operation.")
  } catch {
    let fixed = scopeOwnerFixedFailure(error)
    #expect(fixed)
  }
}

private func scopeOwnerCode(_ code: ErrorCode, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("The runtime gate unexpectedly admitted the operation.")
  } catch {
    let expected = (error as? WorkspaceError)?.code == code
    #expect(expected)
  }
}

private func scopeOwnerPrivacy<T>(_ value: T, name: String) {
  let redacted =
    String(describing: value) == name + "(redacted)"
    && String(reflecting: value) == name + "(redacted)"
  let empty = Mirror(reflecting: value).children.isEmpty
  let notCodable = !(value is any Encodable) && !(T.self is any Decodable.Type)
  #expect(redacted && empty && notCodable)
}

private func scopeOwnerPair(
  _ slot: AccountManager.Slot, scope: AccountScope?, key: AccountManager.Slot.ScopeOwnerKey?
) {
  let sample = slot.scopeOwnershipObservation()
  let exact = sample.scope === scope && sample.owner == key
  #expect(exact)
}

private struct ScopeOwnerWeak<T: AnyObject & Sendable>: Sendable {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}

private final class ScopeOwnerWeakSlot: Sendable {
  private let cell = Mutex(ScopeOwnerWeak<AccountManager.Slot>(nil))
  func bind(_ slot: AccountManager.Slot) { cell.withLock { $0 = ScopeOwnerWeak(slot) } }
  func get() -> AccountManager.Slot? { cell.withLock { $0 }.value }
}

private final class ScopeOwnerProbe: Sendable {
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
  private let apiCell = Mutex(ScopeOwnerWeak<ScopeOwnerAPIProbe>(nil))
  let slot = ScopeOwnerWeakSlot()
  let signal = SyncSignal()
  var counts: Counts { cell.withLock { $0 } }
  var weakAPI: ScopeOwnerWeak<ScopeOwnerAPIProbe> { apiCell.withLock { $0 } }
  func recordSecret() { cell.withLock { $0.secretReads += 1 } }
  func recordAdapter() { cell.withLock { $0.adapter += 1 } }
  func recordCall(_ index: Int) { cell.withLock { $0.calls[index] += 1 } }
  func makeAPI() -> ScopeOwnerAPIProbe {
    let api = ScopeOwnerAPIProbe(self)
    cell.withLock { $0.factory += 1 }
    apiCell.withLock { $0 = ScopeOwnerWeak(api) }
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

private actor ScopeOwnerSecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  private let probe: ScopeOwnerProbe
  init(_ probe: ScopeOwnerProbe) { self.probe = probe }
  nonisolated var backend: String { "scope-owner-fixture" }
  func put(_ ref: SecretRef, value: String) { values[ref] = value }
  func read(_ ref: SecretRef) -> String? { probe.recordSecret(); return values[ref] }
  func remove(_ ref: SecretRef) -> Bool { values.removeValue(forKey: ref) != nil }
}

private final class ScopeOwnerAPIProbe: HubAPI {
  private let probe: ScopeOwnerProbe
  init(_ probe: ScopeOwnerProbe) { self.probe = probe }
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

private struct ScopeOwnerEffects: Sendable, Equatable {
  let factory: Int
  let secretReads: Int
  let requests: [Int]
  let adapter: Int
  let linkOpens: Int
  let eventSequence: Int
  let takes: Int
  let drops: Int
}

private struct ScopeOwnerHeld<T: Sendable>: Sendable {
  let entered: Gate
  let release: Gate
  let task: Task<T, any Error>
}

private final class ScopeOwnerCleanup: Sendable {
  private struct State {
    var scopes: [AccountScope] = []
    var databases: [WorkspaceDatabase] = []
    var pending: [AccountManager.Slot.ScopeOwnerReservation] = []
    var attachments: [(HubSync, HubSync.ScopeOwnerAttachment)] = []
    var holds: [Gate] = []
    var tasks: [@Sendable () async -> Void] = []
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
  func hold(_ gate: Gate) { cell.withLock { $0.holds.append(gate) } }
  func task(_ join: @escaping @Sendable () async -> Void) { cell.withLock { $0.tasks.append(join) } }
  func finish(manager: AccountManager?, slot: AccountManager.Slot?) async -> Bool {
    let state = cell.withLock { value in
      let previous = value
      value = State()
      return previous
    }
    for hold in state.holds { hold.open() }
    for join in state.tasks { await join() }
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
    for hold in state.holds { hold.open() }
    for join in state.tasks { await join() }
    for reservation in state.pending { _ = slot.cancelScopeOwnerReservation(reservation) }
    for (hub, attachment) in state.attachments { _ = await hub.detachDormantScopeOwner(attachment) }
  }
}

private struct ScopeOwnerFixture: Sendable {
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
  let probe: ScopeOwnerProbe
  let secrets: ScopeOwnerSecretStore
  let links: FakeHubLinkConnection
  let power: FakePowerAssertions
  let cleanup: ScopeOwnerCleanup

  static func withFixture(
    ownerRevision: UInt64? = nil, lifecycleSerial: UInt64? = nil,
    beforeStart: @Sendable (AccountManager, AccountManager.Slot) async throws -> Void = { _, _ in },
    linked: Bool,
    body: @Sendable (ScopeOwnerFixture) async throws -> Void
  ) async throws {
    let f = try await make(
      ownerRevision: ownerRevision, lifecycleSerial: lifecycleSerial,
      beforeStart: beforeStart, linked: linked)
    do {
      let baseline = await f.effects()
      try await body(f)
      await f.expectEffects(baseline)
      await f.finish()
    } catch {
      await f.finish()
      // Never let arbitrary resource errors render private rows or references in a test terminal.
      Issue.record("The scope-owner control failed; private details were suppressed.")
      throw ScopeOwnerFixtureFailure.incomplete
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
      throw ScopeOwnerFixtureFailure.incomplete
    }
  }

  static func make(
    ownerRevision: UInt64? = nil, lifecycleSerial: UInt64? = nil,
    beforeStart: @Sendable (AccountManager, AccountManager.Slot) async throws -> Void = { _, _ in },
    linked: Bool
  ) async throws -> Self {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let binDir = try scopeOwnerRequire(endpoint.binDir)
    let root =
      try AgentProtocolResourceFixture.physicalTemporaryDirectory()
      + "scope-owner-" + UUID().uuidString.lowercased()
    let cleanup = ScopeOwnerCleanup()
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
      let seed = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir)
      cleanup.database(seed)
      try empty(seed)
      try seed.close()
      let probe = ScopeOwnerProbe()
      let secrets = ScopeOwnerSecretStore(probe)
      let links = FakeHubLinkConnection()
      let power = FakePowerAssertions()
      let actualRegistry = try AccountRegistry(
        endpoint: endpoint, binDir: binDir,
        databaseName: AccountManager.registryDatabaseName(for: endpoint))
      registry = actualRegistry
      let reference = SecretRef.make()
      let account = row(endpoint: endpoint, reference: reference)
      try actualRegistry.insert(account)
      try actualRegistry.activate(id: account.id, tokenRef: reference.rawValue)
      await secrets.put(reference, value: "fixture-scope-owner-value")
      let diagnostics = DiagnosticsService(
        context: DiagnosticsService.Context(
          paths: paths, startedAt: joinedAt, environment: environment,
          secretStore: secrets, eventLog: events))
      let context = AccountScope.Context(
        paths: paths, environment: environment, secretStore: secrets, eventLog: events,
        diagnostics: diagnostics,
        adapterFactory: { _, _, _, _ in
          probe.recordAdapter()
          throw ScopeOwnerFixtureFailure.incomplete
        }, hubAPIFactory: { _, _ in probe.makeAPI() }, hubLinkConnection: links,
        powerAssertions: power, checkRetryDelays: [], threadDeleteSweep: .zero)
      let actualManager = AccountManager(
        context: AccountManager.Context(
          cluster: StoreCluster(endpoint: endpoint, binDir: binDir, ownedServer: nil),
          registry: actualRegistry, scope: context, flavor: .local))
      manager = actualManager
      let actualSlot = await actualManager.slot
      slot = actualSlot
      probe.slot.bind(actualSlot)
      if ownerRevision != nil || lifecycleSerial != nil {
        try actualSlot.seedScopeOwnerCountersForTesting(
          ownerRevision: ownerRevision ?? 0, lifecycleSerial: lifecycleSerial ?? 0)
      }
      try await beforeStart(actualManager, actualSlot)
      await actualManager.start()
      let scope = try scopeOwnerRequire(actualManager.current)
      cleanup.scope(scope)
      cleanup.database(scope.database)
      let exact =
        scope.account.id == account.id && scope.account.database == endpoint.database
        && actualSlot.get() === scope
      #expect(exact)
      guard exact else { throw ScopeOwnerFixtureFailure.incomplete }
      // The original unjoined /me throws WorkspaceError before reaching our fake API.
      if let refresh = await actualManager.refresh { await refresh.value }
      let unjoinedFactoryAndSecret = probe.counts.factory == 0 && probe.counts.secretReads == 0
      let unjoinedAPIAndAdapter = probe.counts.calls.allSatisfy { $0 == 0 } && probe.counts.adapter == 0
      let unjoinedLink = links.openCount == 0
      #expect(unjoinedFactoryAndSecret && unjoinedAPIAndAdapter && unjoinedLink)
      if linked {
        try scope.database.saveHubLink(
          WorkspaceDatabase.HubLink(
            url: account.hubURL, deviceId: account.deviceId, deviceName: "Fixture Mac",
            tokenRef: reference.rawValue, orgSlug: "fixture-org", username: "fixture-user",
            joinedAt: joinedAt))
        // Do not stop first: real start installs the origin, then its nonnil nudge guard returns.
        await scope.hub.start()
      }
      await scope.hub.stop()
      let emptyPush = try await scope.hub.pushNow()
      #expect(emptyPush == 0)
      await events.finish()
      let candidateEndpoint = try AgentProtocolResourceFixture.endpoint()
      let candidateBin = try scopeOwnerRequire(candidateEndpoint.binDir)
      let candidateDatabase = try WorkspaceDatabase(endpoint: candidateEndpoint, binDir: candidateBin)
      cleanup.database(candidateDatabase)
      try empty(candidateDatabase)
      let candidate = await AccountScope.open(
        row: row(endpoint: candidateEndpoint, reference: SecretRef.make()), database: candidateDatabase,
        context: context, instance: UUID(), onUnauthorized: {})
      cleanup.scope(candidate)
      await candidate.hub.stop()
      let candidatePush = try await candidate.hub.pushNow()
      #expect(candidatePush == 0)
      await events.finish()
      let f = Self(
        root: root, registry: actualRegistry, manager: actualManager, slot: actualSlot, scope: scope,
        candidate: candidate, context: context, events: events, probe: probe, secrets: secrets,
        links: links, power: power, cleanup: cleanup)
      let initial = await f.effects()
      let quiet =
        initial.factory == (linked ? 1 : 0) && initial.secretReads == 0
        && initial.requests.allSatisfy { $0 == 0 } && initial.adapter == 0
        && initial.linkOpens == 0 && initial.eventSequence == 0 && initial.takes == 0 && initial.drops == 0
      #expect(quiet)
      guard quiet else { throw ScopeOwnerFixtureFailure.incomplete }
      return f
    } catch {
      await events.finish()
      let drained = await cleanup.finish(manager: manager, slot: slot)
      registry?.close()
      if drained { try? FileManager.default.removeItem(atPath: root) }
      Issue.record("The scope-owner fixture could not be constructed; private details were suppressed.")
      throw ScopeOwnerFixtureFailure.incomplete
    }
  }

  func makeCandidate() async throws -> AccountScope {
    let endpoint = try AgentProtocolResourceFixture.endpoint()
    let binDir = try scopeOwnerRequire(endpoint.binDir)
    let database = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir)
    cleanup.database(database)
    try Self.empty(database)
    let candidate = await AccountScope.open(
      row: Self.row(endpoint: endpoint, reference: SecretRef.make()), database: database,
      context: context, instance: UUID(), onUnauthorized: {})
    cleanup.scope(candidate)
    await candidate.hub.stop()
    let emptyPush = try await candidate.hub.pushNow()
    #expect(emptyPush == 0)
    await events.finish()
    return candidate
  }

  func capture() throws -> ProtocolVerificationSnapshot {
    let link = try scopeOwnerRequire(scope.database.hubLink())
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
    scopeOwnerPair(slot, scope: scope, key: publication.key)
    return prepared
  }

  func rejectNetworkRoles(_ local: HubOwnerCarrier) async throws {
    scopeOwnerRefusal { try local.requireOrdinaryMemory() }
    scopeOwnerRefusal { try local.requireFinalPushMemory() }
    scopeOwnerRefusal { try local.requireSessionDisposalMemory() }
    scopeOwnerRefusal { _ = try local.registerChild() }
    scopeOwnerRefusal { _ = try local.originalScope(for: manager) }
    scopeOwnerRefusal { _ = try local.originalOwnerKey(for: manager) }
    scopeOwnerRefusal { _ = try local.cleanupKey(for: manager) }
    await scopeOwnerRefusalAsync { _ = try await manager.beginDormantHubCleanup(original: local) }
    await scopeOwnerRefusalAsync {
      _ = try await manager.advanceDormantHubCleanupToSessionDisposal(original: local, finalPush: local)
    }
    let noRevoke = await manager.revokeDormantHubCleanupPhase(local)
    let noFinish = await manager.finishDormantHubCleanup(local)
    #expect(!noRevoke && !noFinish)
  }

  func held<T: Sendable>(_ action: @escaping @Sendable () async throws -> T) throws -> ScopeOwnerHeld<T> {
    guard !Task.isCancelled else { throw ScopeOwnerFixtureFailure.incomplete }
    let entered = Gate()
    let release = Gate()
    cleanup.hold(entered)
    cleanup.hold(release)
    let task = Task {
      entered.open()
      await release.wait()
      try Task.checkCancellation()
      return try await action()
    }
    cleanup.task {
      task.cancel(); release.open(); _ = await task.result
    }
    return ScopeOwnerHeld(entered: entered, release: release, task: task)
  }

  func effects() async -> ScopeOwnerEffects {
    let counts = probe.counts
    return ScopeOwnerEffects(
      factory: counts.factory, secretReads: counts.secretReads, requests: counts.calls,
      adapter: counts.adapter, linkOpens: links.openCount, eventSequence: await events.sequence,
      takes: power.takes, drops: power.drops)
  }

  func expectEffects(_ before: ScopeOwnerEffects) async {
    let unchanged = await effects() == before
    #expect(unchanged)
  }

  func finish() async {
    await events.finish()
    let drained = await cleanup.finish(manager: manager, slot: slot)
    registry.close()
    if drained {
      do { try FileManager.default.removeItem(atPath: root) } catch {
        Issue.record("The drained scope-owner private root could not be removed.")
      }
    } else {
      Issue.record("The scope-owner private root was retained because its leases did not drain.")
    }
  }
}

private final class ScopeOwnerSamples: Sendable {
  struct Counts: Sendable { var before = 0; var after = 0; var invalid = 0 }
  private let cell = Mutex(Counts())
  let signal = SyncSignal()
  var counts: Counts { cell.withLock { $0 } }
  @discardableResult
  func observe(
    _ slot: AccountManager.Slot, old: AccountScope, candidate: AccountScope,
    key: AccountManager.Slot.ScopeOwnerKey
  ) -> Bool {
    let pair = slot.scopeOwnershipObservation()
    let before = pair.scope === old && pair.owner == nil
    let after = pair.scope === candidate && pair.owner == key
    cell.withLock {
      if before { $0.before += 1 } else if after { $0.after += 1 } else { $0.invalid += 1 }
    }
    signal.fire()
    return after
  }
}

// This type cannot retain a manager, scope, hub, origin or API, including through a cleanup closure.
private struct ScopeOwnerLifetimeResources: Sendable {
  let root: String
  let registry: AccountRegistry
  let events: EventLog
  let databases: [WorkspaceDatabase]
  func removeRootIfDrained() {
    registry.close()
    var drained = true
    for database in databases {
      let closed = database.closeForMigration(timeout: .seconds(2))
      #expect(closed)
      drained = closed && drained
    }
    if drained {
      do { try FileManager.default.removeItem(atPath: root) } catch {
        Issue.record("The lifetime fixture private root could not be removed.")
      }
    } else {
      Issue.record("The lifetime fixture private root was retained because its leases did not drain.")
    }
  }
}

private struct ScopeOwnerLifetimeFixture: Sendable {
  let slot: AccountManager.Slot
  let manager: ScopeOwnerWeak<AccountManager>
  let scope: ScopeOwnerWeak<AccountScope>
  let api: ScopeOwnerWeak<ScopeOwnerAPIProbe>
  let probe: ScopeOwnerProbe
  let carrier: HubOwnerCarrier
  let database: WorkspaceDatabase
  let resources: ScopeOwnerLifetimeResources
}

private struct ExpiredScopeOwnerCarrier: Sendable {
  let manager: ScopeOwnerWeak<AccountManager>
  let scope: ScopeOwnerWeak<AccountScope>
  let slot: ScopeOwnerWeak<AccountManager.Slot>
  let api: ScopeOwnerWeak<ScopeOwnerAPIProbe>
  let probe: ScopeOwnerProbe
  let carrier: HubOwnerCarrier
  let database: WorkspaceDatabase
  let resources: ScopeOwnerLifetimeResources
}

private func makeScopeOwnerLifetimeFixture() async throws -> ScopeOwnerLifetimeFixture {
  let f = try await ScopeOwnerFixture.make(linked: true)
  do {
    let baseline = await f.effects()
    let local = try await f.install(f.scope)
    await f.events.finish()
    await f.scope.hub.stop()  // Preserve the actual configured origin for API.deinit.
    if let refresh = await f.manager.refresh { refresh.cancel(); await refresh.value }
    await f.scope.sessions.shutdown()
    await f.scope.servers.shutdown()
    await f.candidate.close(stoppingServers: false, drainTimeout: .zero)
    let currentDrained = f.scope.database.closeForMigration(timeout: .seconds(2))
    let candidateDrained = f.candidate.database.closeForMigration(timeout: .seconds(2))
    #expect(currentDrained && candidateDrained)
    guard currentDrained && candidateDrained else { throw ScopeOwnerFixtureFailure.incomplete }
    await f.cleanup.releaseLifetimeOwnership(slot: f.slot)
    await f.expectEffects(baseline)
    let resources = ScopeOwnerLifetimeResources(
      root: f.root, registry: f.registry, events: f.events,
      databases: [f.scope.database, f.candidate.database])
    return ScopeOwnerLifetimeFixture(
      slot: f.slot, manager: ScopeOwnerWeak(f.manager), scope: ScopeOwnerWeak(f.scope),
      api: f.probe.weakAPI, probe: f.probe, carrier: local.carrier, database: f.scope.database,
      resources: resources)
  } catch {
    await f.finish()
    Issue.record("The scope-owner lifetime fixture failed; private details were suppressed.")
    throw ScopeOwnerFixtureFailure.incomplete
  }
}

private func makeExpiredScopeOwnerCarrier() async throws -> ExpiredScopeOwnerCarrier {
  let lifetime = try await makeScopeOwnerLifetimeFixture()
  lifetime.slot.set(nil)
  // Keep the genuine Slot alive until the actual API destructor has reentered it. Stopped source
  // tasks may briefly retain their hub; this condition is a witness, not a quiescence assumption.
  let settled = await lifetime.probe.signal.until(timeout: .seconds(10)) {
    lifetime.scope.value == nil && lifetime.api.value == nil
      && lifetime.probe.counts.reentries == 1 && lifetime.probe.counts.reentrySawNil == 1
  }
  #expect(settled)
  guard settled else {
    lifetime.resources.removeRootIfDrained()
    Issue.record("The expired scope-owner fixture did not observe actual destructor reentry.")
    throw ScopeOwnerFixtureFailure.incomplete
  }
  let expired = ExpiredScopeOwnerCarrier(
    manager: lifetime.manager, scope: lifetime.scope, slot: ScopeOwnerWeak(lifetime.slot),
    api: lifetime.api, probe: lifetime.probe, carrier: lifetime.carrier,
    database: lifetime.database, resources: lifetime.resources)
  return expired
}
