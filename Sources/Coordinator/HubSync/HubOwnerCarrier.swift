import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Dormant local admission for original resources. This value performs no request, publication,
/// native write or producer launch. Admission never recalls work already inside a native pool.
struct HubOwnerCarrier: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  static let comparisonFailure = WorkspaceError(
    .internalError, "The protocol verification comparison could not be completed.")

  private enum Purpose: Sendable {
    case ordinary(AccountManager.Slot.OrdinaryKey)
    case finalPush(AccountManager.Slot.CleanupKey)
    case sessionDisposal(AccountManager.Slot.CleanupKey)
  }

  private struct Owners: Sendable {
    let manager: AccountManager.Slot.WeakOwner<AccountManager>
    let scope: AccountManager.Slot.WeakOwner<AccountScope>
    let slot: AccountManager.Slot.WeakOwner<AccountManager.Slot>
    let database: WorkspaceDatabase
  }

  private struct ScopePayload: Sendable {
    let owners: Owners
    let reservation: AccountManager.Slot.ScopeOwnerReservation
  }

  private struct NetworkPayload: Sendable {
    let owners: Owners
    let originalSnapshot: ProtocolVerificationSnapshot
    let origin: HubSync.ConfiguredClientOrigin
    let purpose: Purpose
  }

  private enum Payload: Sendable {
    case scopeOwner(ScopePayload)
    case network(NetworkPayload)
  }

  private let payload: Payload

  private init(scopeOwner: ScopePayload) { payload = .scopeOwner(scopeOwner) }

  private init(
    manager: AccountManager.Slot.WeakOwner<AccountManager>,
    scope: AccountManager.Slot.WeakOwner<AccountScope>,
    slot: AccountManager.Slot.WeakOwner<AccountManager.Slot>, database: WorkspaceDatabase,
    originalSnapshot: ProtocolVerificationSnapshot, origin: HubSync.ConfiguredClientOrigin,
    purpose: Purpose
  ) {
    payload = .network(
      NetworkPayload(
        owners: Owners(manager: manager, scope: scope, slot: slot, database: database),
        originalSnapshot: originalSnapshot, origin: origin, purpose: purpose))
  }

  private func networkPayload() throws -> NetworkPayload {
    guard case .network(let network) = payload else { throw Self.comparisonFailure }
    return network
  }

  var description: String { "HubOwnerCarrier(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

  private func ownerKey(in network: NetworkPayload) -> AccountManager.Slot.OwnerKey {
    switch network.purpose {
    case .ordinary(let key): key.owner
    case .finalPush(let key), .sessionDisposal(let key): key.owner
    }
  }

  /// Upgrade only outside all memory cells, then keep these exact owners alive past every unlock.
  private func liveOwners() throws -> (
    manager: AccountManager, scope: AccountScope, slot: AccountManager.Slot
  ) {
    let network = try networkPayload()
    let database = network.owners.database
    let origin = network.origin
    guard let manager = network.owners.manager.value, let scope = network.owners.scope.value,
      let slot = network.owners.slot.value
    else {
      throw Self.comparisonFailure
    }
    let closed = ownerKey(in: network).closed
    guard closed.manager == ObjectIdentifier(manager), closed.slot == ObjectIdentifier(slot),
      manager.slot === slot, closed.scope == ObjectIdentifier(scope),
      closed.scopeInstance == scope.instance, closed.hub == ObjectIdentifier(scope.hub),
      closed.database == ObjectIdentifier(scope.database), scope.database === database,
      origin.database === database, closed.hub == origin.hubIdentity, closed.origin == origin.identity
    else { throw Self.comparisonFailure }
    return (manager, scope, slot)
  }

  /// A local owner retains only its original database and weak lifecycle owners.
  private func liveScopeOwners(
    _ local: ScopePayload
  ) throws -> (
    manager: AccountManager, scope: AccountScope, slot: AccountManager.Slot
  ) {
    guard let manager = local.owners.manager.value, let scope = local.owners.scope.value,
      let slot = local.owners.slot.value
    else { throw Self.comparisonFailure }
    let closed = local.reservation.key.closed
    guard closed.manager == ObjectIdentifier(manager), closed.slot == ObjectIdentifier(slot),
      manager.slot === slot, closed.scope == ObjectIdentifier(scope),
      closed.scopeInstance == scope.instance, closed.hub == ObjectIdentifier(scope.hub),
      closed.database == ObjectIdentifier(scope.database), scope.database === local.owners.database,
      local.reservation.manager.value === manager, local.reservation.scope.value === scope,
      local.reservation.slot.value === slot
    else { throw Self.comparisonFailure }
    return (manager, scope, slot)
  }

  static func makeScopeOwner(
    reservation: AccountManager.Slot.ScopeOwnerReservation,
    manager: AccountManager, scope: AccountScope
  ) throws -> Self {
    do {
      guard reservation.manager.value === manager, reservation.scope.value === scope,
        reservation.slot.value === manager.slot
      else { throw comparisonFailure }
      defer { withExtendedLifetime((manager, scope)) {} }
      let carrier = Self(
        scopeOwner: ScopePayload(
          owners: Owners(
            manager: reservation.manager, scope: reservation.scope, slot: reservation.slot,
            database: scope.database), reservation: reservation))
      try carrier.requireReservedScopeOwnerMemory()
      return carrier
    } catch { throw comparisonFailure }
  }

  func requireReservedScopeOwnerMemory() throws {
    guard case .scopeOwner(let local) = payload else { throw Self.comparisonFailure }
    let owners = try liveScopeOwners(local)
    defer { withExtendedLifetime(owners) {} }
    try owners.slot.requireReservedScopeOwner(local.reservation)
  }

  func requireInstalledScopeOwnerMemory() throws {
    guard case .scopeOwner(let local) = payload else { throw Self.comparisonFailure }
    let owners = try liveScopeOwners(local)
    defer { withExtendedLifetime(owners) {} }
    try owners.slot.requireInstalledScopeOwner(local.reservation.key)
  }

  func reservedScopeAttachmentKey(
    for hub: HubSync, database: WorkspaceDatabase
  ) throws -> AccountManager.Slot.ScopeOwnerKey {
    guard case .scopeOwner(let local) = payload else { throw Self.comparisonFailure }
    let owners = try liveScopeOwners(local)
    defer { withExtendedLifetime((owners, hub, database)) {} }
    guard owners.scope.hub === hub, owners.scope.database === database,
      local.owners.database === database
    else { throw Self.comparisonFailure }
    try requireReservedScopeOwnerMemory()
    return local.reservation.key
  }

  static func makeOrdinary(
    registration: AccountManager.Slot.RootRegistration, manager: AccountManager,
    scope: AccountScope, origin: HubSync.ConfiguredClientOrigin,
    originalSnapshot: ProtocolVerificationSnapshot
  ) throws -> Self {
    do {
      guard registration.manager.value === manager, registration.scope.value === scope,
        registration.slot.value === manager.slot
      else { throw comparisonFailure }
      let carrier = Self(
        manager: registration.manager, scope: registration.scope, slot: registration.slot,
        database: scope.database, originalSnapshot: originalSnapshot, origin: origin,
        purpose: .ordinary(registration.key))
      try carrier.requireOrdinaryMemory()
      try carrier.compareOriginalCaptureAndReference(sessionDisposal: false)
      try carrier.requireOrdinaryMemory()
      withExtendedLifetime((manager, scope)) {}
      return carrier
    } catch { throw comparisonFailure }
  }

  static func makeFinalPush(
    phase: AccountManager.Slot.FinalPushRegistration, original: Self
  ) throws -> Self {
    do {
      let network = try original.networkPayload()
      guard case .ordinary(let ordinary) = network.purpose,
        phase.key.owner == ordinary.owner, phase.key.phase == .finalPush
      else { throw comparisonFailure }
      let owners = try original.liveOwners()
      defer { withExtendedLifetime(owners) {} }
      guard phase.manager.value === owners.manager, phase.scope.value === owners.scope,
        phase.slot.value === owners.slot
      else { throw comparisonFailure }
      let carrier = original.replacingPurpose(.finalPush(phase.key), network: network)
      try carrier.requireFinalPushMemory()
      try carrier.compareOriginalCaptureAndReference(sessionDisposal: false)
      try carrier.requireFinalPushMemory()
      return carrier
    } catch { throw comparisonFailure }
  }

  /// This role omits only whole-store healthy-2 eligibility. It retains the strict original linked
  /// record/reference comparison and is reserved for future DELETE sessions/self admission.
  static func makeSessionDisposal(
    phase: AccountManager.Slot.SessionDisposalRegistration, original: Self
  ) throws -> Self {
    do {
      let network = try original.networkPayload()
      guard case .ordinary(let ordinary) = network.purpose,
        phase.key.owner == ordinary.owner, phase.key.phase == .sessionDisposal
      else { throw comparisonFailure }
      let owners = try original.liveOwners()
      defer { withExtendedLifetime(owners) {} }
      guard phase.manager.value === owners.manager, phase.scope.value === owners.scope,
        phase.slot.value === owners.slot
      else { throw comparisonFailure }
      let carrier = original.replacingPurpose(.sessionDisposal(phase.key), network: network)
      try carrier.requireSessionDisposalMemory()
      try carrier.compareOriginalCaptureAndReference(sessionDisposal: true)
      try carrier.requireSessionDisposalMemory()
      return carrier
    } catch { throw comparisonFailure }
  }

  private func replacingPurpose(_ purpose: Purpose, network: NetworkPayload) -> Self {
    Self(
      manager: network.owners.manager, scope: network.owners.scope, slot: network.owners.slot,
      database: network.owners.database, originalSnapshot: network.originalSnapshot,
      origin: network.origin, purpose: purpose)
  }

  private func compareOriginalCaptureAndReference(sessionDisposal: Bool) throws {
    do {
      let network = try networkPayload()
      let database = network.owners.database
      let originalSnapshot = network.originalSnapshot
      let origin = network.origin
      let owners = try liveOwners()
      defer { withExtendedLifetime(owners) {} }
      let account = owners.scope.account
      try database.compareOriginalLinkedCaptureOwner(
        expectedSnapshot: originalSnapshot, accountID: account.id,
        databaseName: account.database, hubBase: account.hubURL)
      try database.compareOriginalLinkedCaptureOwner(
        expectedSnapshot: originalSnapshot, accountID: account.id,
        databaseName: account.database, hubBase: origin.baseURL.absoluteString)
      let raw = origin.rawReference
      guard raw.hasPrefix("secret:"), raw.count > 7, !raw.utf8.contains(0),
        let reference = SecretRef(rawValue: raw), reference.rawValue.utf8.elementsEqual(raw.utf8)
      else { throw Self.comparisonFailure }
      // Exactly one original-reference native DATA view here. The actor's independent ordinary
      // pre-registration comparison is deliberately not cached or substituted for this one.
      if sessionDisposal {
        try database.compareOriginalLinkedCredentialReference(
          expectedSnapshot: originalSnapshot, expectedTokenRef: raw)
      } else {
        try database.compareOriginalLinkedSyncCredentialReference(
          expectedSnapshot: originalSnapshot, expectedTokenRef: raw)
      }
    } catch { throw Self.comparisonFailure }
  }

  func registerChild() throws -> Self {
    let network = try networkPayload()
    guard case .ordinary(let parent) = network.purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try requireOrdinaryMemory()
    let registration = try owners.slot.registerChild(
      parent: parent, manager: owners.manager, scope: owners.scope)
    do {
      let child = replacingPurpose(.ordinary(registration.key), network: network)
      try child.requireOrdinaryMemory()
      return child
    } catch {
      owners.slot.unregisterProducer(registration.key)
      throw Self.comparisonFailure
    }
  }

  func requireOrdinaryMemory() throws {
    let network = try networkPayload()
    let origin = network.origin
    guard case .ordinary(let key) = network.purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try origin.requireInstalledMemory()
    try owners.slot.requireOrdinary(key)
    try origin.requireInstalledMemory()
  }

  func requireFinalPushMemory() throws {
    let network = try networkPayload()
    let origin = network.origin
    guard case .finalPush(let key) = network.purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try origin.requireInstalledMemory()
    try owners.slot.requireFinalPush(key)
    try origin.requireInstalledMemory()
  }

  func requireSessionDisposalMemory() throws {
    let network = try networkPayload()
    let origin = network.origin
    guard case .sessionDisposal(let key) = network.purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try origin.requireInstalledMemory()
    try owners.slot.requireSessionDisposal(key)
    try origin.requireInstalledMemory()
  }

  // These three bridges reveal only the sealed original owner. In particular they do not require
  // obsolete ordinary admission after cleanup acceptance, and cannot mint or retag any key.
  func originalScope(for manager: AccountManager) throws -> AccountScope {
    let network = try networkPayload()
    guard case .ordinary = network.purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    guard owners.manager === manager else { throw Self.comparisonFailure }
    return owners.scope
  }

  func originalOwnerKey(for manager: AccountManager) throws -> AccountManager.Slot.OwnerKey {
    let network = try networkPayload()
    guard case .ordinary(let key) = network.purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    guard owners.manager === manager else { throw Self.comparisonFailure }
    return key.owner
  }

  func cleanupKey(for manager: AccountManager) throws -> AccountManager.Slot.CleanupKey {
    let network = try networkPayload()
    let key: AccountManager.Slot.CleanupKey
    switch network.purpose {
    case .ordinary: throw Self.comparisonFailure
    case .finalPush(let original), .sessionDisposal(let original): key = original
    }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    guard owners.manager === manager else { throw Self.comparisonFailure }
    return key
  }
}
