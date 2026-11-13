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

  private let manager: AccountManager.Slot.WeakOwner<AccountManager>
  private let scope: AccountManager.Slot.WeakOwner<AccountScope>
  private let slot: AccountManager.Slot.WeakOwner<AccountManager.Slot>
  private let database: WorkspaceDatabase
  private let originalSnapshot: ProtocolVerificationSnapshot
  private let origin: HubSync.ConfiguredClientOrigin
  private let purpose: Purpose

  private init(
    manager: AccountManager.Slot.WeakOwner<AccountManager>,
    scope: AccountManager.Slot.WeakOwner<AccountScope>,
    slot: AccountManager.Slot.WeakOwner<AccountManager.Slot>, database: WorkspaceDatabase,
    originalSnapshot: ProtocolVerificationSnapshot, origin: HubSync.ConfiguredClientOrigin,
    purpose: Purpose
  ) {
    self.manager = manager
    self.scope = scope
    self.slot = slot
    self.database = database
    self.originalSnapshot = originalSnapshot
    self.origin = origin
    self.purpose = purpose
  }

  var description: String { "HubOwnerCarrier(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

  private var ownerKey: AccountManager.Slot.OwnerKey {
    switch purpose {
    case .ordinary(let key): key.owner
    case .finalPush(let key), .sessionDisposal(let key): key.owner
    }
  }

  /// Upgrade only outside all memory cells, then keep these exact owners alive past every unlock.
  private func liveOwners() throws -> (
    manager: AccountManager, scope: AccountScope, slot: AccountManager.Slot
  ) {
    guard let manager = manager.value, let scope = scope.value, let slot = slot.value else {
      throw Self.comparisonFailure
    }
    let closed = ownerKey.closed
    guard closed.manager == ObjectIdentifier(manager), closed.slot == ObjectIdentifier(slot),
      manager.slot === slot, closed.scope == ObjectIdentifier(scope),
      closed.scopeInstance == scope.instance, closed.hub == ObjectIdentifier(scope.hub),
      closed.database == ObjectIdentifier(scope.database), scope.database === database,
      origin.database === database, closed.hub == origin.hubIdentity, closed.origin == origin.identity
    else { throw Self.comparisonFailure }
    return (manager, scope, slot)
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
      guard case .ordinary(let ordinary) = original.purpose,
        phase.key.owner == ordinary.owner, phase.key.phase == .finalPush
      else { throw comparisonFailure }
      let owners = try original.liveOwners()
      defer { withExtendedLifetime(owners) {} }
      guard phase.manager.value === owners.manager, phase.scope.value === owners.scope,
        phase.slot.value === owners.slot
      else { throw comparisonFailure }
      let carrier = original.replacingPurpose(.finalPush(phase.key))
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
      guard case .ordinary(let ordinary) = original.purpose,
        phase.key.owner == ordinary.owner, phase.key.phase == .sessionDisposal
      else { throw comparisonFailure }
      let owners = try original.liveOwners()
      defer { withExtendedLifetime(owners) {} }
      guard phase.manager.value === owners.manager, phase.scope.value === owners.scope,
        phase.slot.value === owners.slot
      else { throw comparisonFailure }
      let carrier = original.replacingPurpose(.sessionDisposal(phase.key))
      try carrier.requireSessionDisposalMemory()
      try carrier.compareOriginalCaptureAndReference(sessionDisposal: true)
      try carrier.requireSessionDisposalMemory()
      return carrier
    } catch { throw comparisonFailure }
  }

  private func replacingPurpose(_ purpose: Purpose) -> Self {
    Self(
      manager: manager, scope: scope, slot: slot, database: database,
      originalSnapshot: originalSnapshot, origin: origin, purpose: purpose)
  }

  private func compareOriginalCaptureAndReference(sessionDisposal: Bool) throws {
    do {
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
    guard case .ordinary(let parent) = purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try requireOrdinaryMemory()
    let registration = try owners.slot.registerChild(
      parent: parent, manager: owners.manager, scope: owners.scope)
    do {
      let child = replacingPurpose(.ordinary(registration.key))
      try child.requireOrdinaryMemory()
      return child
    } catch {
      owners.slot.unregisterProducer(registration.key)
      throw Self.comparisonFailure
    }
  }

  func requireOrdinaryMemory() throws {
    guard case .ordinary(let key) = purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try origin.requireInstalledMemory()
    try owners.slot.requireOrdinary(key)
    try origin.requireInstalledMemory()
  }

  func requireFinalPushMemory() throws {
    guard case .finalPush(let key) = purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try origin.requireInstalledMemory()
    try owners.slot.requireFinalPush(key)
    try origin.requireInstalledMemory()
  }

  func requireSessionDisposalMemory() throws {
    guard case .sessionDisposal(let key) = purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    try origin.requireInstalledMemory()
    try owners.slot.requireSessionDisposal(key)
    try origin.requireInstalledMemory()
  }

  // These three bridges reveal only the sealed original owner. In particular they do not require
  // obsolete ordinary admission after cleanup acceptance, and cannot mint or retag any key.
  func originalScope(for manager: AccountManager) throws -> AccountScope {
    guard case .ordinary = purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    guard owners.manager === manager else { throw Self.comparisonFailure }
    return owners.scope
  }

  func originalOwnerKey(for manager: AccountManager) throws -> AccountManager.Slot.OwnerKey {
    guard case .ordinary(let key) = purpose else { throw Self.comparisonFailure }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    guard owners.manager === manager else { throw Self.comparisonFailure }
    return key.owner
  }

  func cleanupKey(for manager: AccountManager) throws -> AccountManager.Slot.CleanupKey {
    let key: AccountManager.Slot.CleanupKey
    switch purpose {
    case .ordinary: throw Self.comparisonFailure
    case .finalPush(let original), .sessionDisposal(let original): key = original
    }
    let owners = try liveOwners()
    defer { withExtendedLifetime(owners) {} }
    guard owners.manager === manager else { throw Self.comparisonFailure }
    return key
  }
}
