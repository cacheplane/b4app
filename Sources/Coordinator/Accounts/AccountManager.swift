import Foundation
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// Which account this Mac is signed in as, and the only owner of its `AccountScope` (sign-in plan,
/// Task 9). One account is signed in at a time; nobody may be.
///
/// - **Start** restores the registry's active account: its database is opened and its `HubSync`
///   started. With an empty registry, a `workspace` database that has joined a hub is adopted as an
///   account from its link (device and token reference), with no network call, so a joined Mac never
///   shows the sign-in screen because the hub is down; until the first successful `/v1/me` names the
///   user, the row's hub user is the placeholder `device:<deviceId>` and its names are empty. While
///   starting, the status is the account being restored (or, with none, signed out), so nothing ever
///   says "signed out" for an account that comes back.
/// - **Sign-in** finds or creates the registry row by `(hub URL, hub user id)`, claiming a placeholder
///   row whose device is the one the hub answered with, opens and migrates its
///   database before anything else changes (a database that cannot be opened refuses the sign-in and
///   leaves the previous account active and open), stores the token, writes the database's hub link,
///   activates the row, then closes the previous account and starts the new one. The first account
///   gets `workspace` unless it has joined a hub of its own; later ones get `workspace_<id>`.
/// - **Sign-out** closes the scope, forgets the token (secret store and registry), and publishes
///   `account.changed`. A 401 from the hub (push, pull, relay link, or `/v1/me`) to the current scope
///   signs out with `rejectedByHub`, after which nothing sends another request for that account.
/// - **`hub join`** (an enrollment code) works only while signed out, and signs in as a sign-in does;
///   **`hub leave`** revokes this device and signs out (even when the revoke or the cleanup fails).
/// - **The `account.*` commands** (`AccountCommands.swift`, Task 10) run the sign-in ceremonies' hub
///   calls against the flavour's hub, offering the hub every device this Mac has there; onboarding;
///   the sign-in methods; log-out in four bounded steps; and deletion. The onboarding state is kept in
///   the registry so a restart restores it before `/v1/me` answers.
///
/// An account's hub user is the hub's `users.id`, which never changes and is never reused.
///
/// Transitions run one at a time. A token never appears in a log line, an error, an event, or a status.
public actor AccountManager {
  public static let signedOutMessage = "Nobody is signed in. Sign in from the Agent Workspace app."
  /// What a sign-out reason names when the account's org name was never learned (an adopted account
  /// whose first hub call was refused): never the org slug, which is not for showing.
  public static let unnamedOrg = "your account"

  public struct Context: Sendable {
    public var cluster: StoreCluster
    public var registry: AccountRegistry
    public var scope: AccountScope.Context
    /// Which hub a sign-in goes to (`Flavor.hubURL`), the Apple callback's scheme, and whether Sign in
    /// with Apple is offered at all.
    public var flavor: Flavor

    public init(
      cluster: StoreCluster, registry: AccountRegistry, scope: AccountScope.Context, flavor: Flavor = .current
    ) {
      self.cluster = cluster
      self.registry = registry
      self.scope = scope
      self.flavor = flavor
    }
  }

  /// The current scope, readable without waiting for the actor (the router, diagnostics, and the sleep
  /// watcher read it on every call).
  final class Slot: Sendable {
    private let value = Mutex<AccountScope?>(nil)
    func get() -> AccountScope? { value.withLock { $0 } }
    func set(_ scope: AccountScope?) { value.withLock { $0 = scope } }
  }

  let registry: AccountRegistry
  let cluster: StoreCluster
  let scopeContext: AccountScope.Context
  let flavor: Flavor
  let slot = Slot()
  let logger = Log.logger("accounts")

  /// The active account, set before its scope is open so the status during a restore is that account.
  var active: AccountRow?
  var needsOnboarding = false
  /// Why the last sign-out happened without being asked for; cleared by a sign-in.
  var reason: SignOutReason?
  /// The `/v1/me` refresh of the active account's names.
  var refresh: Task<Void, Never>?
  /// The Sign in with Apple web ceremony in flight, with the verifier only this coordinator knows.
  var appleCeremony: AppleCeremony?
  /// The Connect Apple ID web ceremony in flight (Task 14), for the account that began it.
  var appleLinkCeremony: AppleLinkCeremony?
  /// Log-out's bounds; tests shorten them.
  var logoutTimeouts = LogoutTimeouts.standard
  /// One transition at a time (`acquire`/`release`).
  private let transitions = AsyncLock()
  /// One `account.appleStart` at a time, so the verifier kept is always the last answer's.
  let appleStarts = AsyncLock()

  public init(context: Context) {
    registry = context.registry
    cluster = context.cluster
    scopeContext = context.scope
    flavor = context.flavor
  }

  /// The registry's database on the cluster whose default database is `endpoint.database`: `registry`
  /// beside `workspace`, `<name>_registry` beside any other (a test's, or `B4APP_POSTGRES_DATABASE`'s).
  public static func registryDatabaseName(for endpoint: PostgresEndpoint) -> String {
    endpoint.database == "workspace" ? "registry" : endpoint.database + "_registry"
  }

  /// The hub user of a row whose user id is not known yet: an adopted `workspace`, or a hub too old to
  /// say. The first `/v1/me` that names the user replaces it, and a sign-in that the hub answers with
  /// the same device claims the row.
  static func placeholderUserId(deviceId: String) -> String { "device:" + deviceId }

  static func isPlaceholder(_ hubUserId: String) -> Bool { hubUserId.hasPrefix("device:") }

  // MARK: - Reading

  /// The signed-in account's scope, or nil while nobody is signed in.
  public nonisolated var current: AccountScope? { slot.get() }

  /// The signed-in account's scope; throws `signed_out` while nobody is signed in.
  public nonisolated func scope() throws -> AccountScope {
    guard let scope = slot.get() else { throw WorkspaceError(.signedOut, Self.signedOutMessage) }
    return scope
  }

  public func status() -> AccountStatus.Result {
    let known = ((try? registry.all()) ?? [])
      .sorted { ($0.lastSignedInAt ?? "") > ($1.lastSignedInAt ?? "") }
      .map {
        AccountStatus.Known(
          id: $0.id, displayName: $0.displayName, orgName: $0.orgName, lastSignedInAt: $0.lastSignedInAt)
      }
    guard let active else { return AccountStatus.Result(state: .signedOut, known: known, reason: reason) }
    return AccountStatus.Result(
      state: needsOnboarding ? .needsOnboarding : .signedIn,
      account: AccountStatus.Account(
        id: active.id, displayName: active.displayName, orgName: active.orgName, hubURL: active.hubURL),
      known: known, notice: active.hubSessionLeftOpen ? Self.sessionLeftOpenNotice : nil)
  }

  // MARK: - Lifecycle

  /// Restore the active account, or adopt a joined `workspace` database when the registry is empty.
  public func start() async {
    await acquire()
    defer { release() }
    do {
      if let row = try registry.active() {
        await restore(row)
      } else if try registry.all().isEmpty {
        try await adoptJoinedWorkspace()
      }
    } catch {
      logger.error("could not restore an account: \(WorkspaceError.from(error).message, privacy: .public)")
      active = nil
    }
    // Nothing is published: no client is connected before the socket opens, and the first one asks.
  }

  /// Close the scope as the coordinator stops. The account stays signed in, and the managed servers
  /// keep running for the next start to adopt.
  public func shutdown() async {
    await acquire()
    defer { release() }
    refresh?.cancel()
    refresh = nil
    if let scope = slot.get() {
      slot.set(nil)
      await scope.close(stoppingServers: false)
    }
    registry.close()
  }

  private func restore(_ row: AccountRow) async {
    active = row
    // The last word on onboarding until `/v1/me` answers (the refresh below asks).
    needsOnboarding = row.needsOnboarding
    do {
      let database = try AccountScope.openDatabase(row: row, cluster: cluster, createIfMissing: false)
      await install(row: row, database: database)
    } catch {
      logger.error(
        "could not open account \(row.id, privacy: .public): \(WorkspaceError.from(error).message, privacy: .public)"
      )
      active = nil
    }
  }

  /// A build before sign-in kept one database, `workspace`; when it has joined a hub, it becomes the
  /// first account. Everything needed is in its link, so this asks the hub nothing.
  private func adoptJoinedWorkspace() async throws {
    guard try WorkspaceDatabase.linkedHubURL(endpoint: cluster.endpoint, binDir: cluster.binDir) != nil
    else { return }
    let database = try WorkspaceDatabase(
      endpoint: cluster.endpoint, binDir: cluster.binDir, createIfMissing: false)
    let row: AccountRow
    do {
      guard let link = try database.hubLink() else {
        try? database.close()
        return
      }
      // The names stay empty until `/v1/me` answers: the link holds only the org slug and the username,
      // which are not for showing.
      let adopted = AccountRow(
        id: AccountRegistry.newId(), hubURL: link.url,
        hubUserId: Self.placeholderUserId(deviceId: link.deviceId), deviceId: link.deviceId,
        database: cluster.endpoint.database, displayName: "", orgName: "")
      try registry.insert(adopted)
      try registry.activate(id: adopted.id, tokenRef: link.tokenRef)
      row = try registry.active() ?? adopted
    } catch {
      try? database.close()
      throw error
    }
    logger.notice("adopted the joined workspace database as account \(row.id, privacy: .public)")
    active = row
    await install(row: row, database: database)
  }

  // MARK: - Signing in and out

  /// Sign in as `session`'s account on `hubURL` (the hub call has already run). `deviceName` names this
  /// Mac in the account's hub link; nil keeps the link's name or uses the Mac's.
  public func signIn(
    session: AuthSession, hubURL: String, deviceName: String? = nil
  ) async throws -> AccountStatus.Result {
    await acquire()
    defer { release() }
    let base = try HubURL.canonical(hubURL)
    let placeholder = Self.placeholderUserId(deviceId: session.deviceId)
    let hubUserId = session.userId ?? placeholder
    // A row registered before its user id was known is this account's when the hub answered with its
    // device: claim it.
    let existing =
      try findRow(hubURL: base, hubUserId: hubUserId)
      ?? (hubUserId == placeholder ? nil : try findRow(hubURL: base, hubUserId: placeholder))
    var row: AccountRow
    if let existing {
      row = existing
      row.hubUserId = hubUserId
    } else {
      let id = AccountRegistry.newId()
      row = AccountRow(
        id: id, hubURL: base, hubUserId: hubUserId, deviceId: session.deviceId,
        database: try newDatabaseName(id: id), displayName: session.user.displayName,
        orgName: session.org.name)
    }
    // The database first: one that cannot be opened or migrated refuses the sign-in before anything
    // else changes. A registered account's database must already exist.
    let database = try AccountScope.openDatabase(
      row: row, cluster: cluster, createIfMissing: existing == nil)

    // Signing in again as the active account replaces its scope: it is closed now, so its `HubSync`
    // cannot write the link below, and its servers stay running for the new scope to adopt.
    let previous = slot.get()
    let reopening = previous?.account.id == row.id
    if reopening, let previous {
      refresh?.cancel()
      slot.set(nil)
      await previous.close(stoppingServers: false)
    }

    let ref = SecretRef.make()
    let link = try? database.hubLink()
    var inserted = false
    do {
      try await scopeContext.secretStore.put(ref, value: session.token)
      let name = deviceName ?? link?.deviceName ?? HubSync.defaultDeviceName()
      try database.saveHubLink(
        WorkspaceDatabase.HubLink(
          url: base, deviceId: session.deviceId, deviceName: name, tokenRef: ref.rawValue,
          orgSlug: session.org.slug, username: session.user.username, lastPushAt: link?.lastPushAt,
          joinedAt: link?.joinedAt ?? Timestamp.now()))
      try database.saveDevice(id: session.deviceId, name: name)
      if existing == nil {
        try registry.insert(row)
        inserted = true
      }
      try registry.updateProfile(
        id: row.id, hubUserId: hubUserId, deviceId: session.deviceId,
        displayName: session.user.displayName, orgName: session.org.name)
      try registry.setNeedsOnboarding(id: row.id, session.needsOnboarding)
      try registry.activate(id: row.id, tokenRef: ref.rawValue)
      row = try findRow(hubURL: base, hubUserId: hubUserId) ?? row
    } catch {
      // Put back what this sign-in wrote; the previous account (when it was another) is still open.
      if inserted {
        try? registry.remove(id: row.id)
      } else if let existing {
        try? registry.updateProfile(
          id: existing.id, hubUserId: existing.hubUserId, deviceId: existing.deviceId,
          displayName: existing.displayName, orgName: existing.orgName)
        try? registry.setNeedsOnboarding(id: existing.id, existing.needsOnboarding)
      }
      if let link { try? database.saveHubLink(link) } else { try? database.clearHubLink() }
      _ = try? await scopeContext.secretStore.remove(ref)
      try? database.close()
      if reopening {
        // The account's old scope is already closed: open it again from its unchanged row.
        active = nil
        if let restored = try? registry.active(), restored.id == row.id { await restore(restored) }
        await publish()
      }
      throw error
    }

    // Committed. The previous account, if it was another, is signed out: its hub session is ended
    // (briefly; a hub that does not answer leaves it open, which its next sign-in reports), its scope
    // closes (servers included), and its token is forgotten.
    if let previous, !reopening {
      refresh?.cancel()
      slot.set(nil)
      let ended = await Self.endHubSession(of: previous, within: .seconds(3))
      await forgetToken(of: previous.account, deactivate: true, hubSessionLeftOpen: !ended)
      await Self.close(previous, within: Self.switchCloseBudget)
    }
    // The secret the link named before (an earlier session's) is no longer anyone's.
    if let old = link?.tokenRef, old != ref.rawValue, let oldRef = SecretRef(rawValue: old) {
      _ = try? await scopeContext.secretStore.remove(oldRef)
    }
    active = row
    needsOnboarding = session.needsOnboarding
    reason = nil
    // A hub that did not say who the user is gets asked, so the placeholder is replaced.
    let scope = await install(row: row, database: database, refreshNames: Self.isPlaceholder(hubUserId))
    logger.info("signed in as account \(row.id, privacy: .public)")
    // Upload whatever the database holds now (a backlog from before sign-in, or from the last session).
    Task { await scope.hub.backgroundPush(reason: "sign-in") }
    await publish()
    return status()
  }

  /// `hub join` with an enrollment code, the operator path for a hub with sign-up closed: it enrolls
  /// and signs in as that account, exactly as a sign-in would, asking `/v1/me` for the user's id (a
  /// `/v1/me` that fails leaves the placeholder, which the next one replaces). Refused while signed in:
  /// joining would bind the signed-in account's threads to another hub user.
  public func join(url: String, code: String, deviceName: String) async throws -> HubStatus.Result {
    if let scope = slot.get() {
      let org = scope.account.orgName.isEmpty ? "an account" : scope.account.orgName
      throw WorkspaceError(
        .protocolInvalid,
        "This Mac is signed in to \(org). Log out first, then join a hub with an enrollment code.")
    }
    let base = try HubURL.validate(url)
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw WorkspaceError(.protocolInvalid, "The device name is empty.") }
    let enrolled: EnrollResponse
    do {
      enrolled = try await scopeContext.makeAPI(base, { nil }).enroll(
        EnrollRequest(code: code, deviceName: name, platform: "macos"))
    } catch let error as HubError {
      throw HubSync.workspaceError(error, doing: "join the hub")
    }
    let token = enrolled.token
    let me = try? await scopeContext.makeAPI(base, { token }).me()
    _ = try await signIn(
      session: AuthSession(
        deviceId: enrolled.deviceId, token: enrolled.token, org: enrolled.org, user: enrolled.user,
        needsOnboarding: !(me?.onboarded ?? true), userId: me?.userId),
      hubURL: base.absoluteString, deviceName: name)
    let joined = try self.scope()
    _ = try? await joined.hub.pushNow()
    return try await joined.hub.status()
  }

  /// Sign out of the current account: close its scope, forget its token, and publish `account.changed`
  /// with `reason` (nil when the person asked). Nothing happens while nobody is signed in.
  ///
  /// Logging out (`logout(stopWork:)`) adds its own steps before this one: interrupt the running turns
  /// and stop the servers, push once, and end the hub session.
  public func signOut(reason: SignOutReason?) async {
    await acquire()
    defer { release() }
    await performSignOut(reason: reason)
  }

  /// `hub leave`: revoke this device at the hub (best effort), forget its token and the database's
  /// link, and sign out.
  public func leave() async throws -> HubStatus.Result {
    await acquire()
    defer { release() }
    guard let scope = slot.get() else { throw WorkspaceError(.signedOut, Self.signedOutMessage) }
    // Signed out whatever the leave did: once it has begun, the pull and the link are stopped and the
    // client may be gone, so staying signed in would leave the account without sync.
    var failure: (any Error)?
    do {
      try await scope.hub.leave()
    } catch {
      failure = error
      logger.warning(
        "hub leave failed; signing out anyway: \(WorkspaceError.from(error).message, privacy: .public)")
    }
    let unsynced = (try? scope.database.unsyncedChangeCount()) ?? 0
    await performSignOut(reason: nil)
    if let failure { throw failure }
    return HubStatus.Result(joined: false, unsyncedChanges: unsynced, keepAwakeHeld: false)
  }

  /// The hub refused the token of the scope `instance`. Ignored unless that scope is still the current
  /// one: a late report from a scope that has since closed must not sign out a newer session, even of
  /// the same account.
  func hubRejected(instance: UUID) async {
    await acquire()
    defer { release() }
    guard let scope = slot.get(), scope.instance == instance else { return }
    let account = scope.account
    logger.warning("the hub refused account \(account.id, privacy: .public)'s token; signing out")
    await performSignOut(reason: .rejectedByHub(account.orgName.isEmpty ? Self.unnamedOrg : account.orgName))
  }

  /// `hubSessionLeftOpen` records that the hub still holds the token (a log-out that could not reach
  /// it). `drainTimeout` and `serverBudget` bound parts of the scope's close (log-out has already waited
  /// for both), and `closeBudget` the whole of it: what has not finished by then goes on in the
  /// background. `publishing` false leaves the event to the caller (deletion publishes once, after it
  /// drops the account).
  ///
  /// The token is forgotten and the registry row written first, so a close that never ends still
  /// leaves the account signed out.
  func performSignOut(
    reason: SignOutReason?, hubSessionLeftOpen: Bool = false,
    drainTimeout: Duration = AccountScope.drainTimeout, serverBudget: Duration = .seconds(10),
    stoppingServers: Bool = true, closeBudget: Duration? = nil, publishing: Bool = true
  ) async {
    guard let scope = slot.get() else { return }
    refresh?.cancel()
    refresh = nil
    // Commands see "signed out" from here on, not a closing store; the status says so once the scope
    // is closed and the token forgotten.
    slot.set(nil)
    await forgetToken(of: scope.account, deactivate: true, hubSessionLeftOpen: hubSessionLeftOpen)
    await Self.close(
      scope, stoppingServers: stoppingServers, drainTimeout: drainTimeout, serverBudget: serverBudget,
      within: closeBudget)
    active = nil
    needsOnboarding = false
    self.reason = reason
    await scopeContext.diagnostics.invalidate()
    logger.info("signed out of account \(scope.account.id, privacy: .public)")
    if publishing { await publish() }
  }

  // MARK: - Helpers

  /// The row of `hubUserId` on the hub `hubURL` (canonical), however the row spells that hub: one made
  /// by `hub join http://localhost:8080/` is the same hub as the local flavour's.
  func findRow(hubURL: String, hubUserId: String) throws -> AccountRow? {
    try registry.all().first { $0.hubUserId == hubUserId && Self.sameHub($0.hubURL, hubURL) }
  }

  /// Whether two hub URLs name the same hub once canonical.
  static func sameHub(_ a: String, _ b: String) -> Bool {
    (try? HubURL.canonical(a)) == (try? HubURL.canonical(b)) && (try? HubURL.canonical(a)) != nil
  }

  /// How long an account switch waits for the previous account's scope to close.
  static let switchCloseBudget: Duration = .seconds(12)

  /// Close `scope`, waiting at most `budget` (nil: as long as it takes); the rest of the close goes on
  /// in the background.
  static func close(
    _ scope: AccountScope, stoppingServers: Bool = true, drainTimeout: Duration = AccountScope.drainTimeout,
    serverBudget: Duration = .seconds(10), within budget: Duration?
  ) async {
    let close: @Sendable () async -> Void = {
      await scope.close(
        stoppingServers: stoppingServers, drainTimeout: drainTimeout, serverBudget: serverBudget)
    }
    guard let budget else { return await close() }
    if await !Bounded.run(within: budget, close) {
      Log.logger("accounts").warning(
        "account \(scope.account.id, privacy: .public)'s scope was still closing when its time ran out")
    }
  }

  /// Start `row`'s scope on its opened database and make it current.
  @discardableResult
  private func install(
    row: AccountRow, database: WorkspaceDatabase, refreshNames: Bool = true
  ) async -> AccountScope {
    let instance = UUID()
    let scope = await AccountScope.open(
      row: row, database: database, context: scopeContext, instance: instance,
      onUnauthorized: { [weak self] in await self?.hubRejected(instance: instance) })
    slot.set(scope)
    await scopeContext.diagnostics.invalidate()
    if refreshNames { refreshProfile(scope) }
    return scope
  }

  /// Ask `/v1/me` for the account's user id (replacing a placeholder), current names, and whether it
  /// has onboarded, retrying with a backoff while the hub is unreachable. A 401 signs out. An account
  /// that has not joined a hub has nobody to ask.
  private func refreshProfile(_ scope: AccountScope) {
    refresh?.cancel()
    let id = scope.instance
    refresh = Task { [weak self] in
      var backoff: Duration = .seconds(2)
      while !Task.isCancelled {
        do {
          let me = try await scope.hub.me()
          await self?.profileArrived(me, instance: id)
          return
        } catch let error as HubError where error.code == "unauthorized" {
          await self?.hubRejected(instance: id)
          return
        } catch is HubError {
          try? await Task.sleep(for: backoff)
          backoff = min(backoff * 2, .seconds(60))
        } catch {
          return
        }
      }
    }
  }

  func profileArrived(_ me: MeResponse, instance: UUID) async {
    guard let scope = slot.get(), scope.instance == instance, var row = active, row.id == scope.account.id
    else { return }
    let onboarding = !me.onboarded
    let hubUserId = Self.isPlaceholder(row.hubUserId) ? (me.userId ?? row.hubUserId) : row.hubUserId
    guard
      row.displayName != me.user.displayName || row.orgName != me.org.name || row.deviceId != me.deviceId
        || row.hubUserId != hubUserId || needsOnboarding != onboarding
    else { return }
    var updated = row
    updated.displayName = me.user.displayName
    updated.orgName = me.org.name
    updated.deviceId = me.deviceId
    updated.hubUserId = hubUserId
    do {
      try registry.updateProfile(
        id: updated.id, hubUserId: updated.hubUserId, deviceId: updated.deviceId,
        displayName: updated.displayName, orgName: updated.orgName)
      if needsOnboarding != onboarding { try registry.setNeedsOnboarding(id: updated.id, onboarding) }
      row = updated
    } catch {
      // Another row already names this user (it signed in on its own since): keep the placeholder.
      logger.warning(
        "could not record the account's names: \(WorkspaceError.from(error).message, privacy: .public)")
      return
    }
    active = row
    needsOnboarding = onboarding
    scope.update(account: row)
    await publish()
  }

  /// `workspace` for the first account when it is nobody's yet and has not joined a hub (its threads
  /// from before sign-in go to that account); `workspace_<id>` otherwise.
  private func newDatabaseName(id: String) throws -> String {
    let shared = cluster.endpoint.database
    let taken =
      try registry.all().contains { $0.database == shared }
      || slot.get()?.account.database == shared
      || WorkspaceDatabase.linkedHubURL(endpoint: cluster.endpoint, binDir: cluster.binDir) != nil
    return taken ? AccountRegistry.databaseName(id: id) : shared
  }

  /// Remove the account's token from the secret store and its reference from the registry (which also
  /// deactivates the row when `deactivate`, recording `hubSessionLeftOpen`).
  private func forgetToken(of row: AccountRow, deactivate: Bool, hubSessionLeftOpen: Bool = false) async {
    if let ref = row.tokenRef.flatMap(SecretRef.init(rawValue:)) {
      do {
        _ = try await scopeContext.secretStore.remove(ref)
      } catch {
        logger.warning("could not remove account \(row.id, privacy: .public)'s token from the secret store")
      }
    }
    guard deactivate else { return }
    do {
      try registry.signOut(id: row.id, hubSessionLeftOpen: hubSessionLeftOpen)
    } catch {
      logger.warning(
        "could not record account \(row.id, privacy: .public)'s sign-out: \(WorkspaceError.from(error).message, privacy: .public)"
      )
    }
  }

  func publish() async {
    guard let event = try? AdapterEvent.accountChanged(status()) else { return }
    await scopeContext.eventLog.publish(event)
  }

  // MARK: - One transition at a time

  /// The actor is reentrant across each `await`; transitions (start, sign-in, sign-out, a 401) must not
  /// interleave, so each holds this until it ends. Waiters are resumed in order, the lock passing
  /// straight to the next.
  func acquire() async { await transitions.lock() }

  /// `acquire()`, waiting at most `timeout`: a log-out or a deletion that finds another transition
  /// running (an account switch, a sign-in) answers instead of waiting it out.
  func acquire(within timeout: Duration) async throws {
    guard await transitions.lock(within: timeout) else {
      throw WorkspaceError(
        .endpointUnavailable, "This Mac is still signing in or out of an account. Try again in a moment.")
    }
  }

  func release() { transitions.unlock() }
}
