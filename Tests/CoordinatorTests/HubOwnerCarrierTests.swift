import Foundation
import Synchronization
import Testing
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

// Dormant component controls. Scripted HubAPI responses do not authenticate a request, and
// cancellation/status receipts are not joins of production tasks whose handles are unavailable.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AgentProtocolHubOwnerCarrierTests {
  @Test func actualCurrentLinkedScopeIssuesRedactedOriginalCarrier() async throws {
    try await OwnerFixture.withLinked { f in
      let origin = try await f.scope.hub.captureConfiguredClientOrigin()
      let carrier = try await f.makeOrdinary()
      let originalScope = try carrier.originalScope(for: f.manager) === f.scope
      let actualDatabase = origin.database === f.database
      let actualHub = origin.hubIdentity == ObjectIdentifier(f.scope.hub)
      let actualCurrent = f.slot.get()?.instance == f.scope.instance
      #expect(originalScope && actualDatabase && actualHub && actualCurrent)
      let callback = OwnerCounter()
      try carrier.requireOrdinaryMemory()
      callback.increment()
      #expect(callback.value == 1)
      let carrierRedacted =
        String(describing: carrier) == "HubOwnerCarrier(redacted)"
        && String(reflecting: carrier) == "HubOwnerCarrier(redacted)"
      let originRedacted =
        String(describing: origin) == "ConfiguredClientOrigin(redacted)"
        && String(reflecting: origin) == "ConfiguredClientOrigin(redacted)"
      #expect(carrierRedacted && originRedacted)
      #expect(Mirror(reflecting: carrier).children.isEmpty)
      #expect(Mirror(reflecting: origin).children.isEmpty)
      try f.expectBaseline()
    }
  }

  @Test func hiddenAbsentAndUncapturedSnapshotsCannotRedeemLinkedRoles() async throws {
    try await OwnerFixture.withUnjoined { f in
      let absent = try f.database.captureProtocolVerification(
        accountID: f.scope.account.id, expectedMembership: nil)
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: absent, accountID: f.scope.account.id,
          databaseName: f.scope.account.database, hubBase: OwnerFixture.base)
      }
      // Restore the real link after taking the absent capture. It cannot change hidden context.
      try await f.secrets.put(f.reference, value: OwnerFixture.secretValue)
      try f.database.saveHubLink(f.link)
      await f.scope.hub.start()
      try await f.settleRestart()
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: absent)
      }
      let binding = try f.binding()
      let uncaptured = try f.database.prepareProtocolVerification(expectedBinding: binding)
      let read = try ownerRequire(try f.database.readProtocolFact(expectedBinding: binding))
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: uncaptured, accountID: f.scope.account.id,
          databaseName: f.scope.account.database, hubBase: OwnerFixture.base)
      }
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: read, accountID: f.scope.account.id,
          databaseName: f.scope.account.database, hubBase: OwnerFixture.base)
      }
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: uncaptured)
      }
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: read)
      }
      // No ordinary ancestor exists: final-push/disposal factories are deliberately unreachable.
      // Neither a caller membership tuple nor a fabricated role registration is supplied.
    }
  }

  @Test func capturedOwnerAccountBaseAndActualDatabaseMustMatch() async throws {
    try await OwnerFixture.withLinked { f in
      let snapshot = try f.capture()
      let origin = try await f.scope.hub.captureConfiguredClientOrigin()
      try f.database.compareOriginalLinkedCaptureOwner(
        expectedSnapshot: snapshot, accountID: f.scope.account.id,
        databaseName: f.scope.account.database, hubBase: f.scope.account.hubURL)
      try f.database.compareOriginalLinkedCaptureOwner(
        expectedSnapshot: snapshot, accountID: f.scope.account.id,
        databaseName: f.scope.account.database, hubBase: origin.baseURL.absoluteString)
      _ = try await f.makeOrdinary(snapshot)
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: snapshot, accountID: "different-owner",
          databaseName: f.scope.account.database, hubBase: OwnerFixture.base)
      }
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: snapshot, accountID: f.scope.account.id,
          databaseName: "different-database", hubBase: OwnerFixture.base)
      }
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: snapshot, accountID: f.scope.account.id,
          databaseName: f.scope.account.database, hubBase: OwnerFixture.base + "/other")
      }
      let reopened = try WorkspaceDatabase(
        endpoint: f.endpoint, binDir: f.binDir, createIfMissing: false)
      defer { try? reopened.close() }
      expectOwnerRefusal {
        try reopened.compareOriginalLinkedCaptureOwner(
          expectedSnapshot: snapshot, accountID: f.scope.account.id,
          databaseName: f.scope.account.database, hubBase: OwnerFixture.base)
      }
      let foreignCapture = try reopened.captureProtocolVerification(
        accountID: f.scope.account.id, expectedMembership: f.membership())
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: foreignCapture)
      }
      var changed = f.scope.account
      changed.id = "different-owner"
      let original = f.scope.account
      f.scope.update(account: changed)
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: snapshot)
      }
      f.scope.update(account: original)
      changed = original
      changed.hubURL = OwnerFixture.base + "/other"
      f.scope.update(account: changed)
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: snapshot)
      }
      f.scope.update(account: original)
    }
  }

  @Test func actualPendingJoinAndFailedJoinNeverInstallOrigin() async throws {
    try await OwnerFixture.withUnjoined { f in
      let before = try f.registry.active()
      let secretWrites = f.secrets.counts.puts
      await expectOwnerRefusalAsync { _ = try await f.scope.hub.captureConfiguredClientOrigin() }
      f.api.armEnroll(failing: true)
      try ownerUncancelled()
      let task = Task { () -> Bool in
        do {
          _ = try await f.scope.hub.join(
            url: OwnerFixture.base, code: "fixture-enrollment", deviceName: "Fixture Mac")
          return false
        } catch { return (error as? WorkspaceError)?.code == .protocolInvalid }
      }
      f.cleanup.own { _ = await task.value }
      try await ownerWait("pending enrollment entry") { f.api.counts.enroll == 1 }
      await expectOwnerRefusalAsync { _ = try await f.scope.hub.captureConfiguredClientOrigin() }
      let noPendingLink = try f.database.hubLink() == nil
      #expect(noPendingLink)
      f.api.releaseEnroll()
      #expect(await task.value)
      let unchanged = try f.registry.active() == before
      let noLink = try f.database.hubLink() == nil
      #expect(unchanged && noLink)
      #expect(f.secrets.counts.puts == secretWrites)
      #expect(f.api.counts.factory == 1 && f.api.counts.enroll == 1)
      await expectOwnerRefusalAsync { _ = try await f.scope.hub.captureConfiguredClientOrigin() }
    }
  }

  @Test func sameLookingActualSourceReplacementRetiresOldOrigin() async throws {
    try await OwnerFixture.withLinked(sameAPI: true) { f in
      let oldOrigin = try await f.scope.hub.captureConfiguredClientOrigin()
      let old = try await f.makeOrdinary()
      // This is the actual source start factory, not a test-created configured bundle.
      await f.scope.hub.start()
      try await f.settleRestart()
      let freshOrigin = try await f.scope.hub.captureConfiguredClientOrigin()
      let sameAPI = (oldOrigin.api as? OwnerControlledAPI) === (freshOrigin.api as? OwnerControlledAPI)
      let sameBase = oldOrigin.baseURL == freshOrigin.baseURL
      let sameReference = oldOrigin.rawReference.utf8.elementsEqual(freshOrigin.rawReference.utf8)
      let freshIdentity =
        oldOrigin.identity != freshOrigin.identity
        && oldOrigin.token !== freshOrigin.token
      #expect(sameAPI && sameBase && sameReference && freshIdentity)
      expectOwnerRefusal { try oldOrigin.requireInstalledMemory() }
      expectOwnerRefusal { try old.requireOrdinaryMemory() }
      let fresh = try await f.makeOrdinary()
      try fresh.requireOrdinaryMemory()
      let callbacks = OwnerCounter()
      callbacks.increment()
      #expect(callbacks.value == 1 && f.api.counts.factory == 2)
    }
  }

  @Test func terminalCloseRetiresBeforeHeldStopAndRetainsOriginalPayload() async throws {
    try await OwnerFixture.withLinked(heldSecret: true) { f in
      let origin = try await f.scope.hub.captureConfiguredClientOrigin()
      let ordinary = try await f.makeOrdinary()
      try ownerUncancelled()
      let exactToken = origin.token
      let receipts = f.access.receipts
      let waiter = Task {
        receipts.markTokenStarted()
        do {
          let value = try await exactToken.value()
          receipts.markTokenReturned(success: true)
          return value
        } catch {
          receipts.markTokenReturned(success: false)
          throw OwnerFixtureFailure.failed
        }
      }
      f.access.ownToken(waiter)
      try await ownerWait("shared explicit token waiter") { receipts.counts.tokenStarted == 1 }
      #expect(f.secrets.counts.readEntered == 1 && f.secrets.counts.readSettled == 0)
      #expect(receipts.counts.tokenReturned == 0 && receipts.counts.collectorReturned == 0)
      #expect(f.links.openCount == 0)
      f.api.armWatcher()
      _ = try await f.scope.hub.pair()
      try await ownerWait("actual pairing watcher entry") { f.api.counts.watcherEntered == 1 }
      try ownerUncancelled()
      let hub = f.scope.hub
      let close = Task {
        receipts.markCloseStarted()
        await hub.close()
        receipts.markCloseReturned()
      }
      f.access.ownClose(close)
      try await ownerWait("actual watcher cancellation") { f.api.counts.watcherCancelled == 1 }
      let decisive = f.api.counts
      #expect(receipts.counts.closeReturned == 0 && decisive.watcherSettled == 0)
      #expect(decisive.factory == 1 && decisive.me == 2 && decisive.devices == 3)
      #expect(decisive.pull == 1 && decisive.pullSettled == 1 && decisive.mint == 1)
      #expect(decisive.active == 1 && decisive.enroll == 0 && decisive.push == 0)
      #expect(f.secrets.counts.readEntered == 1 && f.secrets.counts.readSettled == 0)
      #expect(receipts.counts.tokenReturned == 0 && receipts.counts.collectorReturned == 0)
      #expect(f.links.openCount == 0)
      expectOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      expectOwnerRefusal { try origin.requireInstalledMemory() }
      await expectOwnerRefusalAsync { _ = try await hub.captureConfiguredClientOrigin() }
      await expectOwnerCode(.signedOut) { _ = try await hub.client() }
      let retainedWaitingBranch = try await hub.status().lastError?.hasPrefix("Waiting since ") == true
      #expect(retainedWaitingBranch)
      // Watcher release and the REAL close join precede secret release.
      f.api.releaseWatcher()
      try await ownerWait("held close returned") { receipts.counts.closeReturned == 1 }
      await close.value
      #expect(f.api.counts.watcherSettled == 1 && f.api.counts.active == 0)
      #expect(f.links.openCount == 0 && f.secrets.counts.readSettled == 0)
      #expect(receipts.counts.tokenReturned == 0 && receipts.counts.collectorReturned == 0)
      let clearedWaitingBranch = try await hub.status().lastError?.hasPrefix("Waiting since ") != true
      #expect(clearedWaitingBranch)
      let originalTokenStillWaiting = exactToken.waitingSince != nil
      #expect(originalTokenStillWaiting)
      // One shared deadline covers token, pre-existing collector and source close1000.
      let deadline = ContinuousClock.now + .seconds(10)
      f.secrets.release()
      try await ownerWait("released token returned", until: deadline) { receipts.counts.tokenReturned == 1 }
      let value = try await waiter.value
      let sameNonemptyValue = value.map { !$0.isEmpty && $0 == OwnerFixture.secretValue } == true
      #expect(sameNonemptyValue)
      try await f.access.observeSourceSocket(links: f.links, until: deadline)
      #expect(f.secrets.counts.readEntered == 1 && f.secrets.counts.readSettled == 1)
      #expect(f.secrets.counts.activeRead == 0 && receipts.counts.tokenSucceeded == 1)
      #expect(receipts.counts.collectorSucceeded == 1 && f.links.openCount == 1)
      // The production relay run is canceled/unjoined; this is its actual late socket close witness.
    }
  }

  @Test func childIsRegisteredBeforeLaunchAndCannotAdoptReplacement() async throws {
    try await OwnerFixture.withLinked { f in
      let parent = try await f.makeOrdinary()
      let child = try parent.registerChild()
      // Synchronous exact registration must already admit before any Task is made.
      try child.requireOrdinaryMemory()
      let callbacks = OwnerCounter()
      let firstChildCallback = OwnerCounter()
      let staleChildCallback = OwnerCounter()
      let gate = OwnerLatch()
      f.cleanup.release { gate.release() }
      try ownerUncancelled()
      let task = Task {
        do { try child.requireOrdinaryMemory(); firstChildCallback.increment() } catch {}
        await gate.wait()
        do { try child.requireOrdinaryMemory(); staleChildCallback.increment() } catch {}
      }
      f.cleanup.own { await task.value }
      try await ownerWait("registered child first callback") { firstChildCallback.value == 1 }
      f.slot.set(nil)
      f.slot.set(f.scope)
      let replacement = try await f.makeOrdinary()
      expectOwnerRefusal { _ = try parent.registerChild() }
      expectOwnerRefusal { try child.requireOrdinaryMemory() }
      gate.release()
      await task.value
      #expect(firstChildCallback.value == 1 && staleChildCallback.value == 0)
      try replacement.requireOrdinaryMemory()
      callbacks.increment()
      #expect(callbacks.value == 1)
    }
  }

  @Test func oldCompletionCannotRetireOrEraseReplacementOwner() async throws {
    try await OwnerFixture.withLinked { f in
      let old = try await f.makeOrdinary()
      let oldOwner = try old.originalOwnerKey(for: f.manager)
      let oldPhase = try await f.manager.beginDormantHubCleanup(original: old)
      let staleCleanup = try oldPhase.cleanupKey(for: f.manager)
      f.slot.set(nil)
      f.slot.set(f.scope)
      let replacement = try await f.makeOrdinary()
      #expect(!f.slot.retireOrdinary(oldOwner))
      #expect(!f.slot.finishCleanup(staleCleanup))
      #expect(await !f.manager.finishDormantHubCleanup(oldPhase))
      expectOwnerRefusal { try old.requireOrdinaryMemory() }
      expectOwnerRefusal { try oldPhase.requireFinalPushMemory() }
      let callbacks = OwnerCounter()
      try replacement.requireOrdinaryMemory()
      callbacks.increment()
      #expect(callbacks.value == 1)
      let sameCurrent = f.slot.get()?.instance == f.scope.instance
      #expect(sameCurrent)
      // unregisterProducer's sealed OrdinaryKey has no test bridge; its exact-key source audit is separate.
    }
  }

  @Test func tentativeScopeGateRefusalReopenPreservesOrdinaryRegistration() async throws {
    try await OwnerFixture.withLinked { f in
      let original = try await f.makeOrdinary()
      let child = try original.registerChild()
      f.scope.refuseNewWork()
      #expect(f.scope.isClosing)
      expectOwnerCode(.signedOut) { try f.scope.enter() }
      try original.requireOrdinaryMemory()
      try child.requireOrdinaryMemory()
      f.scope.admitWorkAgain()
      try f.scope.enter()
      f.scope.leave()
      #expect(!f.scope.isClosing)
      try original.requireOrdinaryMemory()
      try child.requireOrdinaryMemory()
      let accepted = try await f.manager.beginDormantHubCleanup(original: original)
      expectOwnerRefusal { try original.requireOrdinaryMemory() }
      expectOwnerRefusal { try child.requireOrdinaryMemory() }
      try accepted.requireFinalPushMemory()
    }
  }

  @Test func nilOrdinaryCurrentAdmitsOnlyExactOldCleanupPhase() async throws {
    try await OwnerFixture.withLinked { f in
      let ordinary = try await f.makeOrdinary()
      let phase = try await f.manager.beginDormantHubCleanup(original: ordinary)
      f.slot.set(nil)
      expectOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      try phase.requireFinalPushMemory()
      expectOwnerRefusal { try phase.requireOrdinaryMemory() }
      expectOwnerRefusal { try phase.requireSessionDisposalMemory() }
      try await OwnerFixture.withLinked { other in
        expectOwnerRefusal { _ = try phase.cleanupKey(for: other.manager) }
        await expectOwnerRefusalAsync {
          _ = try await other.manager.advanceDormantHubCleanupToSessionDisposal(
            original: ordinary, finalPush: phase)
        }
        f.slot.set(other.scope)
        expectOwnerRefusal { try phase.requireFinalPushMemory() }
        f.slot.set(nil)
        expectOwnerRefusal { try phase.requireFinalPushMemory() }
      }
    }
    let escaped = try await OwnerFixture.expiredCarrier()
    let weakOwnersGone =
      escaped.scope.value == nil && escaped.manager.value == nil && escaped.slot.value == nil
    #expect(weakOwnersGone)
    expectOwnerRefusal { try escaped.finalPush.requireFinalPushMemory() }
  }

  @Test func cleanupPhasesAreExclusiveMonotoneAndRegisterBeforeLaunch() async throws {
    try await OwnerFixture.withLinked { f in
      let ordinary = try await f.makeOrdinary()
      let finalPush = try await f.manager.beginDormantHubCleanup(original: ordinary)
      // Registration is complete before the controlled callback is launched.
      try finalPush.requireFinalPushMemory()
      expectOwnerRefusal { _ = try finalPush.registerChild() }
      let finalCallback = OwnerCounter()
      try ownerUncancelled()
      let task = Task { () -> Void in
        do { try finalPush.requireFinalPushMemory(); finalCallback.increment() } catch {}
      }
      f.cleanup.own { await task.value }
      await task.value
      #expect(finalCallback.value == 1)
      let disposal = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
        original: ordinary, finalPush: finalPush)
      expectOwnerRefusal { try ordinary.requireOrdinaryMemory() }
      expectOwnerRefusal { try finalPush.requireFinalPushMemory() }
      try disposal.requireSessionDisposalMemory()
      expectOwnerRefusal { try disposal.requireFinalPushMemory() }
      expectOwnerRefusal { _ = try disposal.registerChild() }
      await expectOwnerRefusalAsync { _ = try await f.manager.beginDormantHubCleanup(original: ordinary) }
      await expectOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: ordinary, finalPush: finalPush)
      }
      await expectOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: ordinary, finalPush: disposal)
      }
      #expect(await f.manager.revokeDormantHubCleanupPhase(disposal))
      expectOwnerRefusal { try disposal.requireSessionDisposalMemory() }
      let localCleanup = OwnerCounter()
      localCleanup.increment()  // Deliberately only a controlled receipt, no credential/native effect.
      #expect(localCleanup.value == 1)
      #expect(await !f.manager.revokeDormantHubCleanupPhase(disposal))
      #expect(await f.manager.finishDormantHubCleanup(disposal))
      #expect(await !f.manager.finishDormantHubCleanup(disposal))
      await expectOwnerRefusalAsync { _ = try await f.manager.beginDormantHubCleanup(original: ordinary) }
      #expect(f.api.counts.revoke == 0 && f.api.counts.endSession == 0)
    }
  }

  @Test func blockedActualNativeComparisonRefusesAfterRetirementWithPositiveCompanion() async throws {
    // Two explicit causal cases: unchanged blocked positive, then retirement WHILE SELECT waits.
    try await OwnerFixture.withLinked { f in try await f.blockedConstruction(retire: false) }
    try await OwnerFixture.withLinked { f in try await f.blockedConstruction(retire: true) }
  }

  @Test func carrierRetainsOriginalResourcesAfterWeakOwnersExpire() async throws {
    var escaped: OwnerExpiredCarrier? = try await OwnerFixture.expiredCarrier()
    let ownersExpired =
      escaped.map {
        $0.manager.value == nil && $0.scope.value == nil && $0.slot.value == nil
      } == true
    #expect(ownersExpired)
    let resourcesRetained =
      escaped?.database.value != nil && escaped?.token.value != nil && escaped?.api.value != nil
    #expect(resourcesRetained)
    let alreadyClosed = escaped?.database.value?.closeForMigration(timeout: .seconds(2)) == true
    #expect(alreadyClosed)
    if let ordinary = escaped?.ordinary { expectOwnerRefusal { try ordinary.requireOrdinaryMemory() } }
    if let phase = escaped?.finalPush { expectOwnerRefusal { try phase.requireFinalPushMemory() } }
    let observer = try ownerRequire(escaped?.observer)
    let database = try ownerRequire(escaped?.database)
    let token = try ownerRequire(escaped?.token)
    let api = try ownerRequire(escaped?.api)
    let before = observer.counts.deinitReturned
    escaped = nil
    try await ownerWait("final carrier resources released") {
      database.value == nil && token.value == nil && api.value == nil
        && observer.counts.deinitReturned == before + 1
    }
    // Explicit shutdown/drain preceded weak expiry. No destructor is credited as close.
  }

  @Test func slotLastScopeReleaseRunsApiDestructorOutsideMutex() async throws {
    let lifetime = try await OwnerFixture.slotLifetime()
    let retainedBySlot = lifetime.scope.value != nil && lifetime.api.value != nil
    #expect(retainedBySlot)
    let before = lifetime.observer.counts.deinitReturned
    // A destructor that reenters get() under Slot's mutex deadlocks this exact synchronous call.
    // The managed test cap may fail it; no timeout worker manufactures a setter result.
    lifetime.slot.set(nil)
    let setterReturned = true
    do {
      try await ownerWait("scope destructor returned from slot read") {
        lifetime.scope.value == nil && lifetime.api.value == nil
          && lifetime.observer.counts.deinitReturned == before + 1
      }
      #expect(setterReturned && lifetime.observer.counts.deinitReentered == 1)
    } catch {
      await lifetime.finish()
      throw OwnerFixtureFailure.failed
    }
    await lifetime.finish()
  }

  @Test func disposalOmitsOnlyHealthyTwoEligibilityAndKeepsStrictReference() async throws {
    try await OwnerFixture.withLinked { f in
      let snapshot = try f.capture()
      try f.database.compareOriginalLinkedCredentialReference(
        expectedSnapshot: snapshot, expectedTokenRef: f.reference.rawValue)
      try f.database.compareOriginalLinkedSyncCredentialReference(
        expectedSnapshot: snapshot, expectedTokenRef: f.reference.rawValue)
      let ordinary = try await f.makeOrdinary(snapshot)
      let finalPush = try await f.manager.beginDormantHubCleanup(original: ordinary)
      let originalControl = try OwnerMetadata.controlBytes(f.endpoint)
      try f.insertModernHistoryWitness()
      let modern = try f.database.protocolSyncRequirement() == .protocolTwo
      let unchangedControl = try OwnerMetadata.controlBytes(f.endpoint) == originalControl
      #expect(modern && unchangedControl)
      try finalPush.requireFinalPushMemory()
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedSyncCredentialReference(
          expectedSnapshot: snapshot, expectedTokenRef: f.reference.rawValue)
      }
      await expectOwnerRefusalAsync {
        _ = try await f.manager.prepareDormantHubOwner(
          expectedScope: f.scope, originalSnapshot: snapshot)
      }
      let disposal = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
        original: ordinary, finalPush: finalPush)
      try disposal.requireSessionDisposalMemory()
      expectOwnerRefusal { try finalPush.requireFinalPushMemory() }
      try f.database.compareOriginalLinkedCredentialReference(
        expectedSnapshot: snapshot, expectedTokenRef: f.reference.rawValue)
      var replacement = try ownerRequire(try f.database.hubLink())
      replacement.tokenRef = SecretRef.make().rawValue
      try f.database.saveHubLink(replacement)
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCredentialReference(
          expectedSnapshot: snapshot, expectedTokenRef: f.reference.rawValue)
      }
      // A new strict disposal factory must compare the OLD ref; stale DATA never authorizes revokeSelf.
      #expect(await f.manager.revokeDormantHubCleanupPhase(disposal))
      await expectOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: ordinary, finalPush: finalPush)
      }
      #expect(f.api.counts.revoke == 0 && f.api.counts.endSession == 0)
    }
    try await OwnerFixture.withLinked { f in
      let ordinary = try await f.makeOrdinary()
      try f.insertModernHistoryWitness()
      await expectOwnerRefusalAsync { _ = try await f.manager.beginDormantHubCleanup(original: ordinary) }
      expectOwnerRefusal { try ordinary.requireOrdinaryMemory() }
    }
    try await OwnerFixture.withLinked { f in
      let snapshot = try f.capture()
      let ordinary = try await f.makeOrdinary(snapshot)
      let finalPush = try await f.manager.beginDormantHubCleanup(original: ordinary)
      let originalControl = try OwnerMetadata.controlBytes(f.endpoint)
      var replacement = try ownerRequire(try f.database.hubLink())
      replacement.tokenRef = SecretRef.make().rawValue
      try f.database.saveHubLink(replacement)
      let sameRecord = try OwnerMetadata.controlBytes(f.endpoint) == originalControl
      let sameMembership =
        try f.membership()
        == ProtocolNativeMembership(
          canonicalHubBase: replacement.url, deviceID: replacement.deviceId,
          linkJoinedAt: replacement.joinedAt)
      #expect(sameRecord && sameMembership)
      try f.database.compareOriginalLinkedCredentialReference(
        expectedSnapshot: snapshot, expectedTokenRef: replacement.tokenRef)
      expectOwnerRefusal {
        try f.database.compareOriginalLinkedCredentialReference(
          expectedSnapshot: snapshot, expectedTokenRef: f.reference.rawValue)
      }
      try finalPush.requireFinalPushMemory()
      // This still-live original phase reaches the strict disposal constructor with the old ref.
      await expectOwnerRefusalAsync {
        _ = try await f.manager.advanceDormantHubCleanupToSessionDisposal(
          original: ordinary, finalPush: finalPush)
      }
      expectOwnerRefusal { try finalPush.requireFinalPushMemory() }
      #expect(f.api.counts.revoke == 0 && f.api.counts.endSession == 0)
    }
  }

  @Test func sourceStartJoinLeaveKeepLegacyFactoryAndRetainedRevokeBehavior() async throws {
    try await OwnerFixture.withLinked { f in
      let retained = try await f.scope.hub.captureConfiguredClientOrigin()
      try f.expectBaseline()
      try await f.scope.hub.leave()
      expectOwnerRefusal { try retained.requireInstalledMemory() }
      await expectOwnerRefusalAsync { _ = try await f.scope.hub.captureConfiguredClientOrigin() }
      let originalUsed =
        f.api.counts.revoke == 1 && f.api.counts.factory == 1
        && f.api.counts.endSession == 0 && f.api.counts.revokeOnRetiredOrigin == 1
      #expect(originalUsed)
      let unlinked = try f.database.hubLink() == nil
      #expect(unlinked && f.secrets.counts.removes == 1)
    }
    try await OwnerFixture.withUnjoined { f in
      f.api.armEnroll(failing: true)
      f.api.releaseEnroll()
      await expectOwnerCode(.protocolInvalid) {
        _ = try await f.scope.hub.join(
          url: OwnerFixture.base, code: "fixture-enrollment", deviceName: "Fixture Mac")
      }
      // One actual public owned row makes the successful join's API push a positive canary.
      _ = try f.database.insertEnvironment(
        WorkEnvironment(id: OwnerFixture.joinCanaryID, name: "Fixture upload canary"), folders: [])
      let nativeCanary = try f.database.environment(id: OwnerFixture.joinCanaryID)
      let pending = try f.database.unsyncedChanges(limit: HubSync.batchRows)
      let canaryRecords = pending.filter {
        $0.table == "environments" && $0.rowId == OwnerFixture.joinCanaryID && $0.op == "insert"
      }
      let outbound = pending.compactMap { SyncFilter.outbound($0) }
      let canaryReady =
        nativeCanary?.id == OwnerFixture.joinCanaryID
        && nativeCanary?.folders.isEmpty == true && canaryRecords.count == 1
        && outbound.count == 1 && outbound.first?.table == "environments"
        && outbound.first?.rowId == OwnerFixture.joinCanaryID
      #expect(canaryReady)
      let canarySequence = try ownerRequire(canaryRecords.first?.seq)
      guard canarySequence > 0 else { throw OwnerFixtureFailure.failed }
      f.api.armEnroll(failing: false)
      f.api.releaseEnroll()
      f.api.allowJoinPush()
      _ = try await f.scope.hub.join(
        url: OwnerFixture.base, code: "fixture-enrollment", deviceName: "Fixture Mac")
      let installed = try await f.scope.hub.captureConfiguredClientOrigin()
      f.api.observeOrigin(installed)
      try installed.requireInstalledMemory()
      #expect(f.api.counts.factory == 2 && f.api.counts.enroll == 2)
      #expect(f.api.counts.push == 1 && f.secrets.counts.puts == 1)
      #expect(f.api.counts.joinCanaryReceived == 1 && f.api.counts.joinCanaryAccepted == 1)
      let acceptedCanary = try f.database.changes(after: canarySequence - 1, limit: 1).first
      let nativeCanarySynced =
        acceptedCanary?.seq == canarySequence
        && acceptedCanary?.table == "environments" && acceptedCanary?.rowId == OwnerFixture.joinCanaryID
        && acceptedCanary?.synced == true
      let nativeCanaryRetained = try f.database.environment(id: OwnerFixture.joinCanaryID) != nil
      #expect(nativeCanarySynced && nativeCanaryRetained)
      #expect(f.secrets.counts.readEntered == 0)  // Actual join remember() avoids a read.
      try await f.scope.hub.leave()
      expectOwnerRefusal { try installed.requireInstalledMemory() }
      #expect(f.api.counts.revoke == 1 && f.api.counts.revokeOnRetiredOrigin == 1)
      #expect(f.api.counts.endSession == 0)
    }
  }
}

private enum OwnerFixtureFailure: Error { case failed }
private let ownerRefusalMessage = "The protocol verification comparison could not be completed."

private func ownerRequire<T>(_ value: T?) throws -> T {
  guard let value else {
    Issue.record("The owner-carrier fixture was incomplete; private details were suppressed.")
    throw OwnerFixtureFailure.failed
  }
  return value
}

private func ownerUncancelled() throws {
  guard !Task.isCancelled else {
    Issue.record("The owner-carrier control was canceled before task registration.")
    throw OwnerFixtureFailure.failed
  }
}

private func ownerWait(
  _ stage: StaticString, until deadline: ContinuousClock.Instant = ContinuousClock.now + .seconds(10),
  _ predicate: () async throws -> Bool
) async throws {
  // This loop also works in failure cleanup after parent cancellation. Deadlines are failures.
  while try await !predicate() {
    guard ContinuousClock.now < deadline else {
      Issue.record("The owner-carrier control timed out at a fixed stage: \(stage).")
      throw OwnerFixtureFailure.failed
    }
    await Task.yield()
  }
}

private func ownerFixedRefusal(_ error: any Error) -> Bool {
  guard let value = error as? WorkspaceError else { return false }
  return value.code == .internalError && value.message == ownerRefusalMessage && value.details == nil
    && (error as NSError).userInfo[NSUnderlyingErrorKey] == nil
}

private func expectOwnerRefusal(_ body: () throws -> Void) {
  do {
    try body()
    Issue.record("The original owner comparison unexpectedly admitted the operation.")
  } catch {
    let fixed = ownerFixedRefusal(error)
    #expect(fixed)
  }
}

private func expectOwnerRefusalAsync(_ body: () async throws -> Void) async {
  do {
    try await body()
    Issue.record("The original owner comparison unexpectedly admitted the operation.")
  } catch {
    let fixed = ownerFixedRefusal(error)
    #expect(fixed)
  }
}

private func expectOwnerCode(_ code: ErrorCode, _ body: () throws -> Void) {
  do {
    try body()
    Issue.record("The owner-carrier control expected a closed source refusal.")
  } catch {
    let expected = (error as? WorkspaceError)?.code == code
    #expect(expected)
  }
}

private func expectOwnerCode(_ code: ErrorCode, _ body: () async throws -> Void) async {
  do {
    try await body()
    Issue.record("The owner-carrier control expected a closed source refusal.")
  } catch {
    let expected = (error as? WorkspaceError)?.code == code
    #expect(expected)
  }
}

private enum OwnerDiagnosticBounds {
  static func count(_ value: Int) -> Int { min(max(value, 0), 10_000) }
  static func bytes(_ value: Int) -> Int { min(max(value, 0), 1_048_576) }
  static func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    let whole = min(max(parts.seconds, 0), 60) * 1000
    let fraction = parts.attoseconds / 1_000_000_000_000_000
    return Int(min(max(whole + fraction, 0), 60_000))
  }
}

private final class OwnerStartupDiagnostics: Sendable {
  enum Stage: String, Hashable, Sendable { case collectorArmed, managerStartReturned, refreshJoined, failed }
  private struct State {
    var deadline: ContinuousClock.Instant?
    var emitted: Set<Stage> = []
  }
  private let state = Mutex(State())

  func arm(deadline: ContinuousClock.Instant) { state.withLock { $0.deadline = deadline } }
  func emit(
    _ stage: Stage, secrets: OwnerSecrets, links: FakeHubLinkConnection, access: OwnerAccessLedger
  ) {
    let observation = state.withLock { state -> (Bool, ContinuousClock.Instant?) in
      (state.emitted.insert(stage).inserted, state.deadline)
    }
    guard observation.0 else { return }  // At most four fixed records per fixture, never per poll.
    let now = ContinuousClock.now
    let armed = observation.1 != nil
    let elapsed =
      observation.1.map {
        OwnerDiagnosticBounds.milliseconds(($0 - .seconds(10)).duration(to: now))
      } ?? 0
    let remaining =
      observation.1.map {
        OwnerDiagnosticBounds.milliseconds(now.duration(to: $0))
      } ?? 0
    let expired = observation.1.map { now >= $0 } ?? false
    let secret = secrets.counts
    let collector = access.receipts.counts
    let readEntered = OwnerDiagnosticBounds.count(secret.readEntered)
    let readSettled = OwnerDiagnosticBounds.count(secret.readSettled)
    let activeRead = OwnerDiagnosticBounds.count(secret.activeRead)
    let opens = OwnerDiagnosticBounds.count(links.openCount)
    let collectorStarted = OwnerDiagnosticBounds.count(collector.collectorStarted)
    let collectorReturned = OwnerDiagnosticBounds.count(collector.collectorReturned)
    let collectorSucceeded = OwnerDiagnosticBounds.count(collector.collectorSucceeded)
    let parentCancelled = Task.isCancelled
    let collectorCancelled = access.collectorCancelled
    print(
      "A5_STARTUP stage=\(stage.rawValue) armed=\(armed) elapsedMillis=\(elapsed) remainingMillis=\(remaining) expired=\(expired) parentCancelled=\(parentCancelled) collectorCancelled=\(collectorCancelled) readEntered=\(readEntered) readSettled=\(readSettled) activeRead=\(activeRead) opens=\(opens) collectorStarted=\(collectorStarted) collectorReturned=\(collectorReturned) collectorSucceeded=\(collectorSucceeded)"
    )
  }
}

private enum OwnerNativeDiagnostics {
  enum Stage: String, Sendable { case beforeRollback, afterJoin }
  enum Exit: String, Equatable, Sendable {
    case polling, matched, sampleLimit, deadline, multipleWaiters, metadataFailed, memoryRefused
  }
  enum ResultKind: String, Sendable { case notJoined, success, fixedRefusal, other }
  struct Metadata: Sendable {
    var readOK = false
    var capacityKnown = false
    var capacityBytes = 0
    var baseWaiters = 0
    var earlyMatches = 0
    var referenceMatches = 0
    var lateMatches = 0
    var maxQueryBytes = 0
  }
  static func emit(
    _ stage: Stage, retire: Bool, exit: Exit, samples: Int, elapsedMillis: Int,
    started: Int, returned: Int, issued: Int, result: ResultKind, metadata: Metadata
  ) {
    // Exactly two callsites per construction case; never called from the5000-sample loop.
    let sampleCount = min(max(samples, 0), 5000)
    let elapsed = min(max(elapsedMillis, 0), 60_000)
    let startCount = OwnerDiagnosticBounds.count(started)
    let returnCount = OwnerDiagnosticBounds.count(returned)
    let issueCount = OwnerDiagnosticBounds.count(issued)
    let capacity = OwnerDiagnosticBounds.bytes(metadata.capacityBytes)
    let base = OwnerDiagnosticBounds.count(metadata.baseWaiters)
    let early = OwnerDiagnosticBounds.count(metadata.earlyMatches)
    let reference = OwnerDiagnosticBounds.count(metadata.referenceMatches)
    let late = OwnerDiagnosticBounds.count(metadata.lateMatches)
    let queryBytes = OwnerDiagnosticBounds.bytes(metadata.maxQueryBytes)
    let cancelled = Task.isCancelled
    print(
      "A5_NATIVE stage=\(stage.rawValue) retire=\(retire) exit=\(exit.rawValue) samples=\(sampleCount) elapsedMillis=\(elapsed) started=\(startCount) returned=\(returnCount) issued=\(issueCount) result=\(result.rawValue) readOK=\(metadata.readOK) capacityKnown=\(metadata.capacityKnown) capacityBytes=\(capacity) baseWaiters=\(base) earlyMatches=\(early) referenceMatches=\(reference) lateMatches=\(late) maxQueryBytes=\(queryBytes) cancelled=\(cancelled)"
    )
  }
}

private final class OwnerCounter: Sendable {
  private let storage = Mutex(0)
  var value: Int { storage.withLock { $0 } }
  func increment() { storage.withLock { $0 += 1 } }
}

// Weak boxes carry no lifecycle authority. Test access occurs outside every product/controller lock.
private struct OwnerWeak<T: AnyObject & Sendable>: Sendable {
  private(set) weak var value: T?
  init(_ value: T?) { self.value = value }
}

/// Idempotent terminal-open gate. Cancellation before continuation installation is remembered.
/// Continuations and arbitrary observer code are resumed/invoked only after unlocking.
private final class OwnerLatch: Sendable {
  private struct State {
    var open = false
    var canceled: Set<UUID> = []
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  }
  private let state = Mutex(State())

  func wait(
    ignoringCancellation: Bool = true, onCancel: @escaping @Sendable () -> Void = {}
  ) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let resume = state.withLock { state -> Bool in
          if state.open || (!ignoringCancellation && state.canceled.contains(id)) { return true }
          state.waiters[id] = continuation
          return false
        }
        if resume { continuation.resume() }
      }
    } onCancel: {
      let continuation = self.state.withLock { state -> CheckedContinuation<Void, Never>? in
        state.canceled.insert(id)
        return ignoringCancellation ? nil : state.waiters.removeValue(forKey: id)
      }
      onCancel()
      continuation?.resume()
    }
  }

  func release() {
    let displaced = state.withLock { state -> State in
      let old = state
      state = State(open: true)
      return old
    }
    for continuation in displaced.waiters.values { continuation.resume() }
  }
}

private final class OwnerSecrets: SecretStore, Sendable {
  struct Counts: Sendable {
    var puts = 0
    var removes = 0
    var readEntered = 0
    var readSettled = 0
    var activeRead = 0
  }
  private struct State {
    var values: [SecretRef: String] = [:]
    var counts = Counts()
  }
  private let state = Mutex(State())
  private let gate = OwnerLatch()
  var backend: String { "owner-carrier-fixture" }
  var counts: Counts { state.withLock { $0.counts } }

  init(reference: SecretRef, held: Bool, seeded: Bool) {
    if seeded { state.withLock { $0.values[reference] = OwnerFixture.secretValue } }
    if !held { gate.release() }
  }
  func release() { gate.release() }
  func put(_ ref: SecretRef, value: String) async throws {
    let displaced = state.withLock { state -> String? in
      state.counts.puts += 1
      return state.values.updateValue(value, forKey: ref)
    }
    withExtendedLifetime(displaced) {}
  }
  func read(_ ref: SecretRef) async throws -> String? {
    state.withLock {
      $0.counts.readEntered += 1; $0.counts.activeRead += 1
    }
    // Shared HubToken detached read must survive caller cancellation and return the same value.
    await gate.wait()
    return state.withLock {
      $0.counts.readSettled += 1
      $0.counts.activeRead -= 1
      return $0.values[ref]
    }
  }
  func remove(_ ref: SecretRef) async throws -> Bool {
    let removed = state.withLock { state -> String? in
      state.counts.removes += 1
      return state.values.removeValue(forKey: ref)
    }
    return removed != nil
  }
}

private final class OwnerAPIController: Sendable {
  struct Counts: Sendable {
    var factory = 0
    var me = 0
    var devices = 0
    var pull = 0
    var pullSettled = 0
    var push = 0
    var joinCanaryReceived = 0
    var joinCanaryAccepted = 0
    var enroll = 0
    var mint = 0
    var revoke = 0
    var endSession = 0
    var readiness = 0
    var unexpected = 0
    var active = 0
    var watcherEntered = 0
    var watcherCancelled = 0
    var watcherSettled = 0
    var deinitReentered = 0
    var deinitReturned = 0
    var revokeOnRetiredOrigin = 0
    var adapter = 0
  }
  private struct State {
    var counts = Counts()
    var weakAPI = OwnerWeak<OwnerControlledAPI>(nil)
    var weakSlot = OwnerWeak<AccountManager.Slot>(nil)
    var weakOrigin = OwnerWeak<HubSync.ConfiguredClientOrigin>(nil)
    var watcherArmed = false
    var pairingInitialDevicesReturned = false
    var enrollFails = true
    var allowPush = false
    var enrollGate = OwnerLatch()
    var pullGate = OwnerLatch()
    var watcherGate = OwnerLatch()
  }
  private let state = Mutex(State())
  private let sameAPI: Bool
  init(sameAPI: Bool) { self.sameAPI = sameAPI }
  var counts: Counts { state.withLock { $0.counts } }
  var weakAPI: OwnerWeak<OwnerControlledAPI> { state.withLock { $0.weakAPI } }

  func bind(slot: AccountManager.Slot) {
    let box = OwnerWeak(slot)
    let old = state.withLock { state -> OwnerWeak<AccountManager.Slot> in
      let old = state.weakSlot; state.weakSlot = box; return old
    }
    withExtendedLifetime(old) {}
  }
  func observeOrigin(_ origin: HubSync.ConfiguredClientOrigin) {
    let box = OwnerWeak(origin)
    let old = state.withLock { state -> OwnerWeak<HubSync.ConfiguredClientOrigin> in
      let old = state.weakOrigin; state.weakOrigin = box; return old
    }
    withExtendedLifetime(old) {}
  }
  func make(
    _ base: URL, _ token: @escaping @Sendable () async throws -> String?
  ) -> any HubAPI {
    let box = state.withLock { state -> OwnerWeak<OwnerControlledAPI> in
      state.counts.factory += 1
      return state.weakAPI
    }
    if sameAPI, let old = box.value { return old }
    let api = OwnerControlledAPI(controller: self, token: token)
    let fresh = OwnerWeak(api)
    let old = state.withLock { state -> OwnerWeak<OwnerControlledAPI> in
      let old = state.weakAPI; state.weakAPI = fresh; return old
    }
    withExtendedLifetime(old) {}
    return api
  }
  func apiDestroyed() {
    let box = state.withLock { $0.weakSlot }
    if let slot = box.value {
      // No controller lock is held during weak upgrade, Slot.get or the returned scope's release.
      let current = slot.get()
      withExtendedLifetime(current) {}
      state.withLock { $0.counts.deinitReentered += 1 }
    }
    state.withLock { $0.counts.deinitReturned += 1 }
  }
  func adapterWasRequested() { state.withLock { $0.counts.adapter += 1 } }
  func beginMe() {
    state.withLock {
      $0.counts.me += 1; $0.counts.active += 1
    }
  }
  func endCall() { state.withLock { $0.counts.active -= 1 } }

  func devices() async -> [DeviceInfo] {
    let gate = state.withLock { state -> OwnerLatch? in
      state.counts.devices += 1
      state.counts.active += 1
      guard state.watcherArmed else { return nil }
      if !state.pairingInitialDevicesReturned {
        state.pairingInitialDevicesReturned = true
        return nil
      }
      state.counts.watcherEntered += 1
      return state.watcherGate
    }
    defer { endCall() }
    if let gate {
      await gate.wait(onCancel: { self.state.withLock { $0.counts.watcherCancelled += 1 } })
      state.withLock { $0.counts.watcherSettled += 1 }
    }
    return []
  }
  func pull() async throws -> PullResponse {
    let gate = state.withLock { state -> OwnerLatch in
      state.counts.pull += 1
      state.counts.active += 1
      return state.pullGate
    }
    defer {
      state.withLock {
        $0.counts.pullSettled += 1; $0.counts.active -= 1
      }
    }
    await gate.wait(ignoringCancellation: false)
    try Task.checkCancellation()
    return PullResponse(changes: [], next: 0, more: false)
  }
  func armWatcher() { state.withLock { $0.watcherArmed = true } }
  func releaseWatcher() { state.withLock { $0.watcherGate }.release() }
  func armEnroll(failing: Bool) {
    let fresh = OwnerLatch()
    let displaced = state.withLock { state -> OwnerLatch in
      state.enrollFails = failing
      let old = state.enrollGate; state.enrollGate = fresh; return old
    }
    displaced.release()
  }
  func releaseEnroll() { state.withLock { $0.enrollGate }.release() }
  func allowJoinPush() { state.withLock { $0.allowPush = true } }
  func enroll() async throws -> EnrollResponse {
    let (gate, fail) = state.withLock { state -> (OwnerLatch, Bool) in
      state.counts.enroll += 1; state.counts.active += 1
      return (state.enrollGate, state.enrollFails)
    }
    defer { endCall() }
    await gate.wait()
    if fail {
      throw HubError(
        kind: "request_error", code: "invalid_code", message: "Fixture enrollment refused.", status: 400)
    }
    return EnrollResponse(
      deviceId: OwnerFixture.device, token: OwnerFixture.secretValue,
      org: OrgInfo(slug: "fixture-org", name: "Fixture Org"),
      user: UserInfo(username: "fixture-user", displayName: "Fixture User"))
  }
  func push(_ changes: [SyncChange]) throws -> PushResponse {
    let permitted = state.withLock { state -> Bool in
      state.counts.push += 1
      if !state.allowPush { state.counts.unexpected += 1 }
      return state.allowPush
    }
    guard permitted else { throw OwnerFixtureFailure.failed }
    let acceptedThrough = changes.map(\.deviceSeq).max() ?? 0
    let canary = changes.filter {
      $0.table == "environments" && $0.rowId == OwnerFixture.joinCanaryID && $0.op == "insert"
    }
    let received = canary.count == 1
    let accepted = received && canary.first.map { $0.deviceSeq <= acceptedThrough } == true
    state.withLock {
      if received { $0.counts.joinCanaryReceived += 1 }
      if accepted { $0.counts.joinCanaryAccepted += 1 }
    }
    return PushResponse(acceptedThrough: acceptedThrough, rejected: [])
  }
  func mint() -> PairingCodeResponse {
    state.withLock { $0.counts.mint += 1 }
    return PairingCodeResponse(code: "fixture-pairing", expiresAt: "2099-01-01T00:00:00.000Z")
  }
  func revoke() {
    let box = state.withLock { state -> OwnerWeak<HubSync.ConfiguredClientOrigin> in
      state.counts.revoke += 1
      return state.weakOrigin
    }
    if let origin = box.value {
      do { try origin.requireInstalledMemory() } catch {
        state.withLock { $0.counts.revokeOnRetiredOrigin += 1 }
      }
    }
  }
  func endSession() { state.withLock { $0.counts.endSession += 1 } }
  func readiness() throws -> HubReadiness {
    state.withLock {
      $0.counts.readiness += 1; $0.counts.unexpected += 1
    }
    throw OwnerFixtureFailure.failed
  }
  func unexpected() { state.withLock { $0.counts.unexpected += 1 } }
  func releaseAll() {
    let gates = state.withLock { ($0.enrollGate, $0.pullGate, $0.watcherGate) }
    gates.0.release(); gates.1.release(); gates.2.release()
  }
}

private final class OwnerControlledAPI: HubAPI, Sendable {
  private let controller: OwnerAPIController
  // Exact callback supplied by the real source factory. Controlled me/devices/mint DO NOT read it.
  private let token: @Sendable () async throws -> String?
  init(controller: OwnerAPIController, token: @escaping @Sendable () async throws -> String?) {
    self.controller = controller
    self.token = token
  }
  deinit { controller.apiDestroyed() }
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try await controller.enroll() }
  func me() async throws -> MeResponse {
    controller.beginMe()
    defer { controller.endCall() }
    return MeResponse(
      deviceId: OwnerFixture.device, deviceName: "Fixture Mac", platform: "macos",
      org: OrgInfo(slug: "fixture-org", name: "Fixture Org"),
      user: UserInfo(username: "fixture-user", displayName: "Fixture User"),
      createdAt: OwnerFixture.stamp, userId: OwnerFixture.user)
  }
  func devices() async throws -> [DeviceInfo] { await controller.devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { controller.mint() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try controller.push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse { try await controller.pull() }
  func snapshot() async throws -> SnapshotResponse {
    controller.unexpected()
    throw OwnerFixtureFailure.failed
  }
  func revokeSelf() async throws { controller.revoke() }
  func endSession() async throws { controller.endSession() }
  func readiness() async throws -> HubReadiness { try controller.readiness() }
}

/// Bookkeeping contains only test-owned handles and release/cleanup jobs. Exchanges transfer old
/// arrays out before invocation or payload destruction. ARC tests disarm this object lexically.
private final class OwnerCleanup: Sendable {
  typealias Join = @Sendable () async -> Void
  private struct State {
    var releases: [@Sendable () -> Void] = []
    var joins: [Join] = []
    var resources: [Join] = []
  }
  private let state = Mutex(State())
  func release(_ body: @escaping @Sendable () -> Void) { state.withLock { $0.releases.append(body) } }
  func own(_ body: @escaping Join) { state.withLock { $0.joins.append(body) } }
  func resource(_ body: @escaping Join) { state.withLock { $0.resources.append(body) } }
  func releaseHolds() {
    let releases = state.withLock { state -> [@Sendable () -> Void] in
      let old = state.releases; state.releases = []; return old
    }
    for release in releases { release() }
  }
  func joinAll() async {
    let joins = state.withLock { state -> [Join] in
      let old = state.joins; state.joins = []; return old
    }
    for join in joins { await join() }
  }
  func closeResources() async {
    let jobs = state.withLock { state -> [Join] in
      let old = state.resources; state.resources = []; return old
    }
    for job in jobs.reversed() { await job() }
  }
  func disarmResources() {
    let jobs = state.withLock { state -> [Join] in
      let old = state.resources; state.resources = []; return old
    }
    withExtendedLifetime(jobs) {}
  }
}

private final class OwnerAccessReceipts: Sendable {
  struct Counts: Sendable {
    var collectorStarted = 0
    var collectorReturned = 0
    var collectorSucceeded = 0
    var tokenStarted = 0
    var tokenReturned = 0
    var tokenSucceeded = 0
    var closeStarted = 0
    var closeReturned = 0
  }
  private let state = Mutex(Counts())
  var counts: Counts { state.withLock { $0 } }
  func markCollectorStarted() { state.withLock { $0.collectorStarted += 1 } }
  func markCollectorReturned(success: Bool) {
    state.withLock {
      $0.collectorReturned += 1; if success { $0.collectorSucceeded += 1 }
    }
  }
  func markTokenStarted() { state.withLock { $0.tokenStarted += 1 } }
  func markTokenReturned(success: Bool) {
    state.withLock {
      $0.tokenReturned += 1; if success { $0.tokenSucceeded += 1 }
    }
  }
  func markCloseStarted() { state.withLock { $0.closeStarted += 1 } }
  func markCloseReturned() { state.withLock { $0.closeReturned += 1 } }
}

private final class OwnerAccessLedger: Sendable {
  private struct Handles {
    var collector: Task<FakeHubLinkSocket, any Error>?
    var token: Task<String?, any Error>?
    var close: Task<Void, Never>?
    var sockets: [FakeHubLinkSocket] = []
    var lateOpenExpected = false
  }
  private let state = Mutex(Handles())
  let receipts = OwnerAccessReceipts()
  var collectorCancelled: Bool {
    let collector = state.withLock { $0.collector }
    return collector?.isCancelled ?? false
  }

  func ownCollector(_ task: Task<FakeHubLinkSocket, any Error>) {
    let duplicate = state.withLock { state -> Bool in
      guard state.collector == nil else { return true }
      state.collector = task; return false
    }
    if duplicate { Issue.record("Duplicate owner-carrier collector registration.") }
  }
  func ownToken(_ task: Task<String?, any Error>) {
    let duplicate = state.withLock { state -> Bool in
      guard state.token == nil else { return true }
      state.token = task; return false
    }
    if duplicate { Issue.record("Duplicate owner-carrier token registration.") }
  }
  func ownClose(_ task: Task<Void, Never>) {
    let duplicate = state.withLock { state -> Bool in
      guard state.close == nil else { return true }
      state.close = task; return false
    }
    if duplicate { Issue.record("Duplicate owner-carrier close registration.") }
  }
  func expectLateOpen() { state.withLock { $0.lateOpenExpected = true } }
  func joinInitialCollector() async throws -> FakeHubLinkSocket {
    try await ownerWait("initial source collector returned") { self.receipts.counts.collectorReturned == 1 }
    let task = try ownerRequire(state.withLock { $0.collector })
    let socket = try await task.value
    remember(socket)
    return socket
  }
  func remember(_ socket: FakeHubLinkSocket) {
    state.withLock { $0.sockets.append(socket) }
  }
  func observeSourceSocket(
    links: FakeHubLinkConnection, until deadline: ContinuousClock.Instant
  ) async throws {
    try await ownerWait("source socket collector returned", until: deadline) {
      self.receipts.counts.collectorReturned == 1
    }
    let task = try ownerRequire(state.withLock { $0.collector })
    let socket = try await task.value
    remember(socket)
    try await ownerWait("source socket closed", until: deadline) { socket.deviceClosedCode == 1000 }
    let exact = receipts.counts.collectorSucceeded == 1 && links.openCount == 1
    guard exact else {
      Issue.record("The late source socket receipt did not match the exact control.")
      throw OwnerFixtureFailure.failed
    }
  }
  func finish(
    hub: HubSync?, api: OwnerAPIController, secrets: OwnerSecrets, links: FakeHubLinkConnection,
    heldSecret: Bool
  ) async {
    let handles = state.withLock { state -> Handles in
      let old = state; state = Handles(); return old
    }
    // Release-before-entry is terminal. Watcher always opens BEFORE real close join/stop.
    api.releaseWatcher()
    if let close = handles.close {
      do { try await ownerWait("cleanup close returned") { self.receipts.counts.closeReturned == 1 } } catch {
        Issue.record("The registered close failed its cleanup completion deadline.")
      }
      await close.value
    } else if let hub {
      await hub.stop()
    }
    // Never await the explicit waiter or cancel the original collector while secret is held.
    secrets.release()
    let deadline = ContinuousClock.now + .seconds(10)
    if let token = handles.token {
      do {
        try await ownerWait("cleanup token returned", until: deadline) {
          self.receipts.counts.tokenReturned == 1
        }
      } catch { Issue.record("The registered token failed its cleanup completion deadline.") }
      _ = await token.result
    }
    var sockets = handles.sockets
    if let collector = handles.collector {
      if handles.lateOpenExpected {
        do {
          try await ownerWait("cleanup late source socket", until: deadline) {
            self.receipts.counts.collectorReturned == 1
          }
          let socket = try await collector.value
          sockets.append(socket)
          try await ownerWait("cleanup late source close", until: deadline) {
            socket.deviceClosedCode == 1000
          }
          let exact = links.openCount == 1 && self.receipts.counts.collectorSucceeded == 1
          if !exact { Issue.record("The expected late source socket count was not exact.") }
        } catch {
          // Failure is recorded before cancellation/manual fake cleanup can happen.
          Issue.record("The expected late source socket event failed; cleanup cannot qualify it.")
          collector.cancel()
          if case .success(let socket) = await collector.result { sockets.append(socket) }
        }
      } else {
        if heldSecret {
          Issue.record("The held-secret source read entry was unproven; this control is incomplete.")
        }
        if let hub { await hub.close() }
        if receipts.counts.collectorReturned == 0 { collector.cancel() }
        if case .success(let socket) = await collector.result { sockets.append(socket) }
      }
    }
    for socket in sockets {
      if socket.deviceClosedCode != 1000 {
        Issue.record(
          "A known fake socket lacked the source close witness; closing it for failed cleanup only.")
        socket.close(code: 1000)
      }
    }
    api.releaseAll()
  }
}

private struct OwnerFixture: Sendable {
  static let base = "https://owner-fixture.invalid/Deployment"
  static let stamp = "2026-11-12T00:00:00.000Z"
  static let device = "owner-fixture-device"
  static let user = "0197aaaa-0000-7000-8000-00000000a505"
  static let joinCanaryID = "owner-fixture-public-upload-canary"
  static let secretValue = "owner-fixture-nonempty-secret"

  let manager: AccountManager
  let scope: AccountScope
  let slot: AccountManager.Slot
  let database: WorkspaceDatabase
  let registry: AccountRegistry
  let events: EventLog
  let endpoint: PostgresEndpoint
  let root: String
  let reference: SecretRef
  let link: WorkspaceDatabase.HubLink
  let api: OwnerAPIController
  let secrets: OwnerSecrets
  let links: FakeHubLinkConnection
  let cleanup: OwnerCleanup
  let access: OwnerAccessLedger
  let heldSecret: Bool
  var binDir: String { endpoint.binDir! }

  static func withLinked(
    heldSecret: Bool = false, sameAPI: Bool = false,
    _ body: @Sendable (OwnerFixture) async throws -> Void
  ) async throws {
    try await withFixture(linked: true, heldSecret: heldSecret, sameAPI: sameAPI, body)
  }
  static func withUnjoined(_ body: @Sendable (OwnerFixture) async throws -> Void) async throws {
    try await withFixture(linked: false, heldSecret: false, sameAPI: false, body)
  }
  private static func withFixture(
    linked: Bool, heldSecret: Bool, sameAPI: Bool,
    _ body: @Sendable (OwnerFixture) async throws -> Void
  ) async throws {
    let f = try await start(linked: linked, heldSecret: heldSecret, sameAPI: sameAPI)
    var failed = false
    do { try await body(f) } catch {
      failed = true
      Issue.record("The owner-carrier control failed; private operation details were suppressed.")
    }
    await f.finish()
    if failed { throw OwnerFixtureFailure.failed }
  }

  private static func start(linked: Bool, heldSecret: Bool, sameAPI: Bool) async throws -> OwnerFixture {
    let cleanup = OwnerCleanup()
    let access = OwnerAccessLedger()
    let api = OwnerAPIController(sameAPI: sameAPI)
    let reference = SecretRef.make()
    let secrets = OwnerSecrets(reference: reference, held: heldSecret, seeded: linked)
    let links = FakeHubLinkConnection()
    let startupDiagnostics = OwnerStartupDiagnostics()
    var actualManager: AccountManager?
    do {
      let endpoint = try AgentProtocolResourceFixture.endpoint()
      let binDir = try ownerRequire(endpoint.binDir)
      let root =
        try AgentProtocolResourceFixture.physicalTemporaryDirectory()
        + "owner-carrier-" + UUID().uuidString.lowercased()
      try FileManager.default.createDirectory(
        atPath: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let safeRoot = OwnerSafetyReceipt()
      cleanup.resource {
        guard safeRoot.canRemove else {
          Issue.record("The private fixture root was retained after incomplete lease/backend cleanup.")
          return
        }
        do {
          try FileManager.default.removeItem(atPath: root)
          let absent = !FileManager.default.fileExists(atPath: root)
          #expect(absent)
        } catch { Issue.record("The exact private fixture root could not be removed.") }
      }
      // Registered before any owning pool; reverse cleanup inspects AFTER every own close/drain.
      cleanup.resource {
        do {
          try await OwnerMetadata.requireNoAppBackends(endpoint)
          safeRoot.markBackendsClosed()
        } catch { Issue.record("The exact fixture database still had an app backend or metadata failed.") }
      }
      var paths = PlatformPaths(runtimeDir: root + "/rt", dataDir: root + "/data")
      paths.postgres = endpoint
      try PrivateFiles.ensurePrivateDirectory(paths.runtimeDir)
      try PrivateFiles.ensurePrivateDirectory(paths.dataDir)
      let environment = [
        "PATH": "/nonexistent", "HOME": paths.dataDir, "TMPDIR": root,
        "B4APP_RUNTIME_DIR": paths.runtimeDir, "B4APP_DATA_DIR": paths.dataDir,
        "B4APP_NODE_PATH": "/nonexistent/node", ExecutableLocator.fallbackOverrideVariable: "",
      ]
      let link = WorkspaceDatabase.HubLink(
        url: base, deviceId: device, deviceName: "Fixture Mac", tokenRef: reference.rawValue,
        orgSlug: "fixture-org", username: "fixture-user", joinedAt: stamp)
      do {
        let seed = try WorkspaceDatabase(endpoint: endpoint, binDir: binDir)
        defer { try? seed.close() }
        if linked { try seed.saveHubLink(link) }
        let empty =
          try seed.listConnections(includeDisabled: true).isEmpty
          && seed.listThreads(ThreadFilter(includeArchived: true)).isEmpty
          && seed.listLocalServers().isEmpty
        guard empty else { throw OwnerFixtureFailure.failed }
        let raw = try OwnerMetadata.connection(endpoint)
        let noPrivateRows = try OwnerMetadata.noProtocolRows(raw)
        guard noPrivateRows else { throw OwnerFixtureFailure.failed }
      }  // Seed pool is CLOSED; no seed-object snapshot is reused by the actual restored scope.
      let events = EventLog()
      cleanup.resource { await events.finish() }
      let registry = try AccountRegistry(
        endpoint: endpoint, binDir: binDir,
        databaseName: AccountManager.registryDatabaseName(for: endpoint))
      cleanup.resource { registry.close() }
      let row = AccountRow(
        id: "owner-fixture-account", hubURL: base, hubUserId: user, deviceId: device,
        database: endpoint.database, displayName: "Fixture User", orgName: "Fixture Org",
        tokenRef: reference.rawValue)
      try registry.insert(row)
      try registry.activate(id: row.id, tokenRef: reference.rawValue)
      let diagnostics = DiagnosticsService(
        context: DiagnosticsService.Context(
          paths: paths, startedAt: stamp, environment: environment, secretStore: secrets, eventLog: events))
      let context = AccountScope.Context(
        paths: paths, environment: environment, secretStore: secrets, eventLog: events,
        diagnostics: diagnostics,
        adapterFactory: { _, _, _, _ in
          api.adapterWasRequested()
          throw WorkspaceError(.unsupportedCapability, "The owner fixture cannot start an adapter.")
        },
        hubAPIFactory: { api.make($0, $1) }, hubLinkConnection: links,
        powerAssertions: FakePowerAssertions(), checkRetryDelays: [], threadDeleteSweep: .zero)
      let manager = AccountManager(
        context: AccountManager.Context(
          cluster: StoreCluster(endpoint: endpoint, binDir: binDir, ownedServer: nil),
          registry: registry, scope: context, flavor: .local))
      actualManager = manager
      cleanup.resource { await manager.shutdown() }
      let slot = await manager.slot
      api.bind(slot: slot)
      // Only this collector is made before actual startup. Registration is synchronous/nonthrowing.
      try ownerUncancelled()
      let receipts = access.receipts
      let collector = Task {
        receipts.markCollectorStarted()
        do {
          let socket = try await links.nextSocket()
          receipts.markCollectorReturned(success: true)
          return socket
        } catch {
          receipts.markCollectorReturned(success: false)
          throw OwnerFixtureFailure.failed
        }
      }
      access.ownCollector(collector)
      let setupDeadline = ContinuousClock.now + .seconds(10)
      startupDiagnostics.arm(deadline: setupDeadline)
      try await ownerWait("startup collector armed", until: setupDeadline) {
        receipts.counts.collectorStarted == 1
      }
      startupDiagnostics.emit(.collectorArmed, secrets: secrets, links: links, access: access)
      await manager.start()
      startupDiagnostics.emit(.managerStartReturned, secrets: secrets, links: links, access: access)
      let scope = try ownerRequire(manager.current)
      safeRoot.requireScopeDrain()
      cleanup.resource {
        await scope.close(stoppingServers: false, drainTimeout: .zero)
        let drained = scope.database.closeForMigration(timeout: .seconds(2))
        #expect(drained)
        if drained { safeRoot.markScopeDrained() }
      }
      let refresh = await manager.refresh
      if let refresh {
        cleanup.own { await refresh.value }
        await refresh.value
      }
      startupDiagnostics.emit(.refreshJoined, secrets: secrets, links: links, access: access)
      let f = OwnerFixture(
        manager: manager, scope: scope, slot: slot, database: scope.database, registry: registry,
        events: events, endpoint: endpoint, root: root, reference: reference, link: link,
        api: api, secrets: secrets, links: links, cleanup: cleanup, access: access, heldSecret: heldSecret)
      let actualCurrent =
        scope.account.id == row.id && scope.account.database == endpoint.database
        && manager.current?.instance == scope.instance
      guard actualCurrent else { throw OwnerFixtureFailure.failed }
      if linked {
        try await ownerWait("startup pull entry", until: setupDeadline) { api.counts.pull == 1 }
        try await ownerWait("startup source secret read", until: setupDeadline) {
          secrets.counts.readEntered == 1
        }
        if heldSecret { access.expectLateOpen() }
        try await ownerWait("startup display name", until: setupDeadline) {
          try await scope.hub.status().displayName == "Fixture User"
        }
        if !heldSecret {
          try await ownerWait("startup collector returned", until: setupDeadline) {
            receipts.counts.collectorReturned == 1
          }
          let socket = try await collector.value
          access.remember(socket)
        }
        await scope.hub.stop()
        try await ownerWait("startup pull settled", until: setupDeadline) {
          api.counts.pullSettled == 1 && api.counts.active == 0
        }
        if heldSecret {
          let exact =
            secrets.counts.readEntered == 1 && secrets.counts.readSettled == 0
            && links.openCount == 0 && receipts.counts.collectorReturned == 0
          guard exact else { throw OwnerFixtureFailure.failed }
        } else {
          let socket = try await collector.value
          try await ownerWait("startup source socket closed", until: setupDeadline) {
            socket.deviceClosedCode == 1000
          }
        }
        let emptyDrain = try await scope.hub.pushNow()
        #expect(emptyDrain == 0 && api.counts.push == 0)
        let origin = try await scope.hub.captureConfiguredClientOrigin()
        api.observeOrigin(origin)
        try f.expectBaseline()
      } else {
        await scope.hub.stop()
        let emptyDrain = try await scope.hub.pushNow()
        #expect(emptyDrain == 0 && api.counts.factory == 0 && api.counts.active == 0)
      }
      return f
    } catch {
      startupDiagnostics.emit(.failed, secrets: secrets, links: links, access: access)
      Issue.record("The direct owner-carrier fixture setup failed; private details were suppressed.")
      await access.finish(
        hub: actualManager?.current?.hub, api: api, secrets: secrets, links: links, heldSecret: heldSecret)
      cleanup.releaseHolds()
      await cleanup.joinAll()
      await cleanup.closeResources()
      throw OwnerFixtureFailure.failed
    }
  }

  func finish() async {
    await access.finish(hub: scope.hub, api: api, secrets: secrets, links: links, heldSecret: heldSecret)
    cleanup.releaseHolds()
    await cleanup.joinAll()
    await cleanup.closeResources()
    #expect(api.counts.active == 0 && api.counts.adapter == 0)
  }
  func membership() throws -> ProtocolNativeMembership {
    try ProtocolNativeMembership(
      canonicalHubBase: link.url, deviceID: link.deviceId, linkJoinedAt: link.joinedAt)
  }
  func capture() throws -> ProtocolVerificationSnapshot {
    try database.captureProtocolVerification(accountID: scope.account.id, expectedMembership: membership())
  }
  func binding() throws -> ProtocolMembershipBinding {
    try ProtocolMembershipBinding(
      accountID: scope.account.id, canonicalHubBase: link.url,
      hubUserID: Self.user, hubOrgID: "fixture-org-identity", deviceID: link.deviceId,
      databaseName: endpoint.database, linkJoinedAt: link.joinedAt)
  }
  func makeOrdinary(_ snapshot: ProtocolVerificationSnapshot? = nil) async throws -> HubOwnerCarrier {
    try await manager.prepareDormantHubOwner(
      expectedScope: scope, originalSnapshot: snapshot ?? capture())
  }
  func expectBaseline() throws {
    let c = api.counts
    let exact =
      c.factory == 1 && c.me == 2 && c.devices == 1 && c.pull == 1
      && c.pullSettled == 1 && c.active == 0 && c.push == 0 && c.enroll == 0 && c.mint == 0
      && c.endSession == 0 && c.revoke == 0 && c.readiness == 0 && c.unexpected == 0 && c.adapter == 0
    #expect(exact)
    let empty =
      try database.listConnections(includeDisabled: true).isEmpty
      && database.listThreads(ThreadFilter(includeArchived: true)).isEmpty
      && database.listLocalServers().isEmpty
    #expect(empty)
    let secret = secrets.counts
    #expect(secret.readEntered == 1)
    if heldSecret {
      #expect(
        secret.readSettled == 0 && links.openCount == 0 && access.receipts.counts.collectorReturned == 0)
    } else {
      #expect(
        secret.readSettled == 1 && links.openCount == 1 && access.receipts.counts.collectorSucceeded == 1)
    }
  }
  func settleRestart() async throws {
    let target = api.counts.factory
    try await ownerWait("restarted pull entry") { api.counts.pull >= target }
    try await ownerWait("restarted source socket") { links.openCount >= target }
    let socket: FakeHubLinkSocket
    if target == 1 {
      // Unjoined restore already owns the first collector; never compete for its queued socket.
      socket = try await access.joinInitialCollector()
    } else {
      socket = try await links.nextSocket()
      access.remember(socket)
    }
    await scope.hub.stop()
    try await ownerWait("restarted pull settled") { api.counts.pull == api.counts.pullSettled }
    try await ownerWait("restarted source socket closed") { socket.deviceClosedCode == 1000 }
    let drain = try await scope.hub.pushNow()
    #expect(drain == 0 && api.counts.push == 0)
  }
  func insertModernHistoryWitness() throws {
    let raw = try OwnerMetadata.connection(endpoint)
    try raw.execute(
      """
      INSERT INTO public.changes("deviceId",wall,"table","rowId",op,"column",value,hlc,synced)
      VALUES('local',0,'protocolOperations','owner-retained-witness','delete',NULL,NULL,
        '000000000000-0000-local',true)
      """)
  }

  func blockedConstruction(retire: Bool) async throws {
    let snapshot = try capture()
    let original = try await makeOrdinary(snapshot)
    let originalSlot = slot  // No actor lookup while the actor is blocked in native SQL.
    try database.compareOriginalLinkedSyncCredentialReference(
      expectedSnapshot: snapshot, expectedTokenRef: reference.rawValue)
    let inspector = try OwnerMetadata.connection(endpoint)
    try inspector.execute("SET statement_timeout='2s'")
    let before = try OwnerMetadata.image(inspector)
    let hold = try OwnerNativeHold(endpoint)
    cleanup.release { hold.rollbackForCleanup() }
    try hold.acquire()
    let started = OwnerCounter()
    let receipt = OwnerCounter()
    let issued = OwnerCounter()
    try ownerUncancelled()
    let task = Task { () -> Result<HubOwnerCarrier, any Error> in
      started.increment()
      defer { receipt.increment() }
      do {
        let carrier = try await manager.prepareDormantHubOwner(
          expectedScope: scope, originalSnapshot: snapshot)
        issued.increment()
        return .success(carrier)
      } catch { return .failure(error) }
    }
    cleanup.own { _ = await task.value }
    var observationFailed = false
    var samples = 0
    var elapsedMillis = 0
    var diagnosticExit = OwnerNativeDiagnostics.Exit.polling
    do {
      let deadline = ContinuousClock.now + .seconds(5)
      defer {
        elapsedMillis = OwnerDiagnosticBounds.milliseconds(
          (deadline - .seconds(5)).duration(to: .now))
      }
      var blocked = false
      while samples < 5000 && ContinuousClock.now < deadline {
        samples += 1
        let waiters = try OwnerMetadata.comparisonWaiters(
          inspector, database: endpoint.database, blocker: hold.backend)
        guard waiters <= 1 else {
          diagnosticExit = .multipleWaiters
          throw OwnerFixtureFailure.failed
        }
        if waiters == 1 { blocked = true; break }
        await Task.yield()
      }
      guard blocked else {
        diagnosticExit = samples >= 5000 ? .sampleLimit : .deadline
        Issue.record("The actual native comparison wait predicate was not established.")
        throw OwnerFixtureFailure.failed
      }
      diagnosticExit = .matched
      #expect(receipt.value == 0 && issued.value == 0)
      if retire {
        originalSlot.set(nil)
        expectOwnerRefusal { try original.requireOrdinaryMemory() }
      } else {
        try original.requireOrdinaryMemory()
      }
    } catch {
      observationFailed = true
      if diagnosticExit == .polling {
        diagnosticExit = .metadataFailed
      } else if diagnosticExit == .matched {
        diagnosticExit = .memoryRefused
      }
    }
    // One separate metadata read, bounded by the inspector's existing statement_timeout2s.
    // It diagnoses the exact selector without changing its query,5s/5000samples or outcome.
    var diagnosticMetadata = OwnerNativeDiagnostics.Metadata()
    do {
      diagnosticMetadata = try OwnerMetadata.comparisonWaiterDiagnostics(
        inspector, database: endpoint.database, blocker: hold.backend)
    } catch {}  // Diagnostic failure is a redacted readOK=false, not a new positive-path Issue.
    OwnerNativeDiagnostics.emit(
      .beforeRollback, retire: retire, exit: diagnosticExit, samples: samples,
      elapsedMillis: elapsedMillis, started: started.value, returned: receipt.value, issued: issued.value,
      result: .notJoined, metadata: diagnosticMetadata)
    // Mandatory release BEFORE awaiting the actual construction Task, even on metadata failure.
    do { try hold.rollback() } catch {
      // rollback() has returned from its synchronous writer-transfer helper: all failed-writer
      // aliases were destroyed outside the bookkeeping lock before this actual Task join.
      Issue.record("The native blocker rollback failed; the comparison control is incomplete.")
      observationFailed = true
    }
    let result = await task.value
    let diagnosticResult: OwnerNativeDiagnostics.ResultKind
    switch result {
    case .success: diagnosticResult = .success
    case .failure(let error): diagnosticResult = ownerFixedRefusal(error) ? .fixedRefusal : .other
    }
    OwnerNativeDiagnostics.emit(
      .afterJoin, retire: retire, exit: diagnosticExit, samples: samples,
      elapsedMillis: elapsedMillis, started: started.value, returned: receipt.value, issued: issued.value,
      result: diagnosticResult, metadata: diagnosticMetadata)
    #expect(receipt.value == 1)
    if observationFailed { throw OwnerFixtureFailure.failed }
    switch result {
    case .success(let carrier):
      #expect(!retire && issued.value == 1)
      if !retire { try carrier.requireOrdinaryMemory() }
    case .failure(let error):
      let correct = retire && issued.value == 0 && ownerFixedRefusal(error)
      #expect(correct)
    }
    try database.compareOriginalLinkedSyncCredentialReference(
      expectedSnapshot: snapshot, expectedTokenRef: reference.rawValue)
    let unchanged = try OwnerMetadata.image(inspector) == before
    #expect(unchanged)
    // This is retirement DURING the native SELECT wait, not an after-native-return seam.
    // The positive path literally performs pre-registration and factory native SELECTs.
  }

  static func expiredCarrier() async throws -> OwnerExpiredCarrier {
    let f = try await start(linked: true, heldSecret: false, sameAPI: false)
    do {
      let origin = try await f.scope.hub.captureConfiguredClientOrigin()
      let ordinary = try await f.makeOrdinary()
      let finalPush = try await f.manager.beginDormantHubCleanup(original: ordinary)
      let result = OwnerExpiredCarrier(
        ordinary: ordinary, finalPush: finalPush, manager: OwnerWeak(f.manager), scope: OwnerWeak(f.scope),
        slot: OwnerWeak(f.slot), database: OwnerWeak(f.database), token: OwnerWeak(origin.token),
        api: f.api.weakAPI, observer: f.api)
      await f.finish()
      return result
    } catch {
      await f.finish()
      Issue.record("The retained-carrier lexical fixture failed; private details were suppressed.")
      throw OwnerFixtureFailure.failed
    }
  }

  static func slotLifetime() async throws -> OwnerSlotLifetime {
    let f = try await start(linked: true, heldSecret: false, sameAPI: false)
    // No Active/OwnerFixture/cleanup-array/scope/origin/carrier leaves this helper.
    await f.scope.sessions.shutdown()
    await f.scope.servers.shutdown()
    await f.access.finishStoppedNormal()
    f.cleanup.releaseHolds()
    await f.cleanup.joinAll()
    f.cleanup.disarmResources()
    return OwnerSlotLifetime(
      manager: f.manager, slot: f.slot, database: f.database, registry: f.registry,
      events: f.events, endpoint: f.endpoint, root: f.root,
      scope: OwnerWeak(f.scope), api: f.api.weakAPI, observer: f.api)
  }
}

private final class OwnerSafetyReceipt: Sendable {
  private struct State { var drained = true; var backendsClosed = false }
  private let state = Mutex(State())
  var canRemove: Bool { state.withLock { $0.drained && $0.backendsClosed } }
  func requireScopeDrain() { state.withLock { $0.drained = false } }
  func markScopeDrained() { state.withLock { $0.drained = true } }
  func markBackendsClosed() { state.withLock { $0.backendsClosed = true } }
}

private struct OwnerExpiredCarrier: Sendable {
  let ordinary: HubOwnerCarrier
  let finalPush: HubOwnerCarrier
  let manager: OwnerWeak<AccountManager>
  let scope: OwnerWeak<AccountScope>
  let slot: OwnerWeak<AccountManager.Slot>
  let database: OwnerWeak<WorkspaceDatabase>
  let token: OwnerWeak<HubToken>
  let api: OwnerWeak<OwnerControlledAPI>
  let observer: OwnerAPIController
}

private struct OwnerSlotLifetime: Sendable {
  let manager: AccountManager
  let slot: AccountManager.Slot
  let database: WorkspaceDatabase
  let registry: AccountRegistry
  let events: EventLog
  let endpoint: PostgresEndpoint
  let root: String
  let scope: OwnerWeak<AccountScope>
  let api: OwnerWeak<OwnerControlledAPI>
  let observer: OwnerAPIController

  func finish() async {
    await manager.shutdown()
    if let remaining = scope.value {
      // Failure cleanup only; the successful destructor oracle above requires this weak box nil.
      await remaining.close(stoppingServers: false, drainTimeout: .zero)
    }
    let drained = database.closeForMigration(timeout: .seconds(2))
    #expect(drained)
    registry.close()
    await events.finish()
    do {
      try await OwnerMetadata.requireNoAppBackends(endpoint)
      if drained {
        try FileManager.default.removeItem(atPath: root)
        let absent = !FileManager.default.fileExists(atPath: root)
        #expect(absent)
      }
    } catch { Issue.record("The lexical Slot-only fixture cleanup was incomplete.") }
  }
}

extension OwnerAccessLedger {
  fileprivate func finishStoppedNormal() async {
    let handles = state.withLock { state -> Handles in
      let old = state; state = Handles(); return old
    }
    // This deliberately DOES NOT call hub.close: Slot must own the API until last scope release.
    if let collector = handles.collector {
      if case .success(let socket) = await collector.result {
        let sourceClosed = socket.deviceClosedCode == 1000
        #expect(sourceClosed)
      } else {
        Issue.record("The Slot-only fixture collector had not completed successfully.")
      }
    }
    let noOtherTasks = handles.close == nil && handles.token == nil && !handles.lateOpenExpected
    #expect(noOtherTasks)
  }
}

private final class OwnerNativeHold: Sendable {
  private enum Phase: Sendable { case idle, active, rollbackFailed }
  private struct State: Sendable {
    var writer: PostgresConnection?
    var phase: Phase = .idle
  }
  private enum RollbackTransfer: Sendable {
    case idle, failed
    case active(PostgresConnection)
  }
  private let state: Mutex<State>
  let backend: String

  init(_ endpoint: PostgresEndpoint) throws {
    let writer = try OwnerMetadata.connection(endpoint)
    try writer.execute("SET lock_timeout='2s'")
    try writer.execute("SET idle_in_transaction_session_timeout='15s'")
    backend = try ownerRequire(
      try writer.execute("SELECT pg_backend_pid()::text AS blocker").rows.first?.text("blocker"))
    state = Mutex(State(writer: writer))
  }
  func acquire() throws {
    let writer = try ownerRequire(state.withLock { $0.writer })
    try writer.execute("BEGIN")
    state.withLock { $0.phase = .active }
    try writer.execute("LOCK TABLE public.settings IN ACCESS EXCLUSIVE MODE")
  }
  func rollback() throws {
    // A Bool alone leaves the helper. On failure its sole owning transfer and borrowed aliases
    // have all left scope before this method throws or any caller can await the constructor.
    guard rollbackOwnedWriterOutsideLock() else { throw OwnerFixtureFailure.failed }
  }
  private func rollbackOwnedWriterOutsideLock() -> Bool {
    let transfer = state.withLock { state -> RollbackTransfer in
      switch state.phase {
      case .idle: return .idle
      case .rollbackFailed: return .failed
      case .active:
        guard let writer = state.writer else {
          state.phase = .rollbackFailed
          return .failed
        }
        // Preserve the displaced owner in the returned transfer before clearing the cell.
        state.writer = nil
        return .active(writer)
      }
    }
    switch transfer {
    case .idle: return true
    case .failed: return false  // Failed rollback never becomes an idempotent-success claim.
    case .active(let writer):
      do {
        try writer.execute("ROLLBACK")
        state.withLock {
          $0.writer = writer
          $0.phase = .idle
        }
        return true
      } catch {
        state.withLock { $0.phase = .rollbackFailed }
        // The cell owns no writer. transfer/writer are local to this synchronous helper;
        // returning false destroys both aliases OUTSIDE the mutex. PostgresConnection.deinit
        // calls lib.finish before rollback() returns failure and before the actual Task join.
        // Connection disposal is failure cleanup, never evidence of a successful ROLLBACK.
        return false
      }
    }
  }
  func rollbackForCleanup() {
    do { try rollback() } catch { Issue.record("The registered native lock rollback failed during cleanup.") }
  }
}

private enum OwnerMetadata {
  struct Image: Equatable {
    let rows: [String: [Data]]
    let sequence: Data
  }
  static func connection(_ endpoint: PostgresEndpoint) throws -> PostgresConnection {
    // Observer/locker omit application_name=b4app. No connection is shared by concurrent tasks.
    try PostgresConnection(
      lib: LibPQ.load(binDir: try ownerRequire(endpoint.binDir)),
      connectionString:
        "host=\(endpoint.socketDir) port=\(endpoint.port) user=\(NSUserName()) dbname=\(endpoint.database)")
  }
  static func noProtocolRows(_ c: PostgresConnection) throws -> Bool {
    let rows = try c.execute(
      """
      SELECT NOT (
        EXISTS(SELECT 1 FROM public."protocolSubscriptions") OR
        EXISTS(SELECT 1 FROM public."protocolRunSegments") OR
        EXISTS(SELECT 1 FROM public."protocolOperations") OR
        EXISTS(SELECT 1 FROM public."protocolGrantSecrets") OR
        EXISTS(SELECT 1 FROM public."protocolGrants") OR
        EXISTS(SELECT 1 FROM public."protocolPromptAnswers") OR
        EXISTS(SELECT 1 FROM public."protocolHistoryAnchors")
      ) AS empty
      """
    ).rows
    return rows.count == 1 && rows.first?.text("empty") == "t"
  }
  static func comparisonWaiters(_ c: PostgresConnection, database: String, blocker: String) throws -> Int {
    try c.execute(
      """
      SELECT a.pid::text AS comparator
      FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
      WHERE a.datname=$1 AND a.application_name='b4app'
        AND a.state='active' AND a.wait_event_type='Lock'
        AND l.locktype='relation' AND l.relation='public.settings'::regclass
        AND l.mode='AccessShareLock' AND NOT l.granted
        AND $2::int=ANY(pg_blocking_pids(a.pid))
        AND position('SELECT current_database() AS database' IN a.query)>0
        AND position('AS native_token_ref' IN a.query)>0
        AND position('AS requires_two' IN a.query)>0
      """, [database, blocker]
    ).rows.count
  }
  static func comparisonWaiterDiagnostics(
    _ c: PostgresConnection, database: String, blocker: String
  ) throws -> OwnerNativeDiagnostics.Metadata {
    let rows = try c.execute(
      """
      WITH capacity AS (
        SELECT CASE WHEN unit='B' AND setting ~ '^[0-9]+$' THEN setting::bigint ELSE 0 END AS bytes,
          (unit='B' AND setting ~ '^[0-9]+$') AS known
        FROM pg_settings WHERE name='track_activity_query_size'
      ), waiting AS (
        SELECT a.query
        FROM pg_stat_activity a JOIN pg_locks l ON l.pid=a.pid
        WHERE a.datname=$1 AND a.application_name='b4app'
          AND a.state='active' AND a.wait_event_type='Lock'
          AND l.locktype='relation' AND l.relation='public.settings'::regclass
          AND l.mode='AccessShareLock' AND NOT l.granted
          AND $2::int=ANY(pg_blocking_pids(a.pid))
      )
      SELECT COALESCE((SELECT bytes FROM capacity),0)::text AS capacity_bytes,
        COALESCE((SELECT known FROM capacity),false)::text AS capacity_known,
        count(*)::text AS base_waiters,
        count(*) FILTER (WHERE position('SELECT current_database() AS database' IN query)>0)::text AS early_matches,
        count(*) FILTER (WHERE position('AS native_token_ref' IN query)>0)::text AS reference_matches,
        count(*) FILTER (WHERE position('AS requires_two' IN query)>0)::text AS late_matches,
        COALESCE(max(octet_length(query)),0)::text AS max_query_bytes
      FROM waiting
      """, [database, blocker]
    ).rows
    guard rows.count == 1, let row = rows.first,
      let capacity = row.int("capacity_bytes"), let base = row.int("base_waiters"),
      let early = row.int("early_matches"), let reference = row.int("reference_matches"),
      let late = row.int("late_matches"), let queryBytes = row.int("max_query_bytes"),
      let known = row.text("capacity_known"), known == "true" || known == "false"
    else { throw OwnerFixtureFailure.failed }
    return OwnerNativeDiagnostics.Metadata(
      readOK: true, capacityKnown: known == "true", capacityBytes: OwnerDiagnosticBounds.bytes(capacity),
      baseWaiters: OwnerDiagnosticBounds.count(base), earlyMatches: OwnerDiagnosticBounds.count(early),
      referenceMatches: OwnerDiagnosticBounds.count(reference),
      lateMatches: OwnerDiagnosticBounds.count(late),
      maxQueryBytes: OwnerDiagnosticBounds.bytes(queryBytes))
  }
  static func requireNoAppBackends(_ endpoint: PostgresEndpoint) async throws {
    let c = try connection(endpoint)
    try c.execute("SET statement_timeout='2s'")
    let registry = AccountManager.registryDatabaseName(for: endpoint)
    try await ownerWait("exact database backend absence") {
      let rows = try c.execute(
        """
        SELECT count(*)::text AS remaining FROM pg_stat_activity
        WHERE application_name='b4app' AND datname IN ($1,$2)
        """, [endpoint.database, registry]
      ).rows
      return rows.count == 1 && rows.first?.text("remaining") == "0"
    }
  }
  static func controlBytes(_ endpoint: PostgresEndpoint) throws -> Data {
    let c = try connection(endpoint)
    let value = try ownerRequire(
      try c.execute(
        "SELECT value::text AS value FROM public.settings WHERE key=$1",
        ["__b4app_agent_protocol_activation_v1"]
      ).rows.first?.text("value"))
    return Data(value.utf8)
  }
  static func image(_ c: PostgresConnection) throws -> Image {
    var rows: [String: [Data]] = [:]
    for row in try c.execute(
      "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public' ORDER BY tablename"
    ).rows {
      let table = try ownerRequire(row.text("tablename"))
      rows[table] = try c.execute("SELECT to_jsonb(t)::text AS value FROM \(Rows.quote(table)) t").rows.map {
        Data(try ownerRequire($0.text("value")).utf8)
      }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    let sequence = try ownerRequire(
      try c.execute(
        """
        SELECT jsonb_build_object('last_value',last_value,'log_cnt',log_cnt,'is_called',is_called)::text AS value
        FROM public.changes_seq_seq
        """
      ).rows.first?.text("value"))
    return Image(rows: rows, sequence: Data(sequence.utf8))
  }
}
