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
///   account from its link (device, token reference, org slug, and username), with no network call, so a
///   joined Mac never shows the sign-in screen because the hub is down; `/v1/me` then refreshes the
///   names. While starting, the status is the account being restored (or, with none, signed out), so
///   nothing ever says "signed out" for an account that comes back.
/// - **Sign-in** finds or creates the registry row by `(hub URL, hub user)`, opens and migrates its
///   database before anything else changes (a database that cannot be opened refuses the sign-in and
///   leaves the previous account active and open), stores the token, writes the database's hub link,
///   activates the row, then closes the previous account and starts the new one. The first account
///   gets `workspace` unless it has joined a hub of its own; later ones get `workspace_<id>`.
/// - **Sign-out** closes the scope, forgets the token (secret store and registry), and publishes
///   `account.changed`. A 401 from the hub (push, pull, relay link, or `/v1/me`) signs out with
///   `rejectedByHub`, after which nothing sends another request for that account.
///
/// The hub exposes no user id, so an account's hub user is `<org slug>/<username>`: both are generated
/// once by the hub and never change, and the username is unique within its org.
///
/// Transitions run one at a time. A token never appears in a log line, an error, an event, or a status.
public actor AccountManager {
  public static let signedOutMessage = "Nobody is signed in. Sign in from the Agent Workspace app."

  public struct Context: Sendable {
    public var cluster: StoreCluster
    public var registry: AccountRegistry
    public var scope: AccountScope.Context

    public init(cluster: StoreCluster, registry: AccountRegistry, scope: AccountScope.Context) {
      self.cluster = cluster
      self.registry = registry
      self.scope = scope
    }
  }

  /// The current scope, readable without waiting for the actor (the router, diagnostics, and the sleep
  /// watcher read it on every call).
  private final class Slot: Sendable {
    private let value = Mutex<AccountScope?>(nil)
    func get() -> AccountScope? { value.withLock { $0 } }
    func set(_ scope: AccountScope?) { value.withLock { $0 = scope } }
  }

  let registry: AccountRegistry
  private let cluster: StoreCluster
  private let scopeContext: AccountScope.Context
  private let slot = Slot()
  private let logger = Log.logger("accounts")

  /// The active account, set before its scope is open so the status during a restore is that account.
  private var active: AccountRow?
  private var needsOnboarding = false
  /// Why the last sign-out happened without being asked for; cleared by a sign-in.
  private var reason: SignOutReason?
  /// The `/v1/me` refresh of the active account's names.
  private var refresh: Task<Void, Never>?
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(context: Context) {
    registry = context.registry
    cluster = context.cluster
    scopeContext = context.scope
  }

  /// The registry's database on the cluster whose default database is `endpoint.database`: `registry`
  /// beside `workspace`, `<name>_registry` beside any other (a test's, or `B4APP_POSTGRES_DATABASE`'s).
  public static func registryDatabaseName(for endpoint: PostgresEndpoint) -> String {
    endpoint.database == "workspace" ? "registry" : endpoint.database + "_registry"
  }

  static func hubUserId(orgSlug: String, username: String) -> String { "\(orgSlug)/\(username)" }

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
      known: known)
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
      let adopted = AccountRow(
        id: AccountRegistry.newId(), hubURL: link.url,
        hubUserId: Self.hubUserId(orgSlug: link.orgSlug, username: link.username), deviceId: link.deviceId,
        database: cluster.endpoint.database, displayName: link.username, orgName: link.orgSlug)
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
    let base = try HubURL.validate(hubURL).absoluteString
    let hubUserId = Self.hubUserId(orgSlug: session.org.slug, username: session.user.username)
    let existing = try registry.find(hubURL: base, hubUserId: hubUserId)
    var row: AccountRow
    if let existing {
      row = existing
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
        id: row.id, deviceId: session.deviceId, displayName: session.user.displayName,
        orgName: session.org.name)
      try registry.activate(id: row.id, tokenRef: ref.rawValue)
      row = try registry.find(hubURL: base, hubUserId: hubUserId) ?? row
    } catch {
      // Put back what this sign-in wrote; the previous account (when it was another) is still open.
      if inserted {
        try? registry.remove(id: row.id)
      } else if let existing {
        try? registry.updateProfile(
          id: existing.id, deviceId: existing.deviceId, displayName: existing.displayName,
          orgName: existing.orgName)
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

    // Committed. The previous account, if it was another, is signed out: its scope closes (servers
    // included) and its token is forgotten.
    if let previous, !reopening {
      refresh?.cancel()
      slot.set(nil)
      await previous.close(stoppingServers: true)
      await forgetToken(of: previous.account, deactivate: true)
    }
    // The secret the link named before (an earlier session's) is no longer anyone's.
    if let old = link?.tokenRef, old != ref.rawValue, let oldRef = SecretRef(rawValue: old) {
      _ = try? await scopeContext.secretStore.remove(oldRef)
    }
    active = row
    needsOnboarding = session.needsOnboarding
    reason = nil
    let scope = await install(row: row, database: database, refreshNames: false)
    logger.info("signed in as account \(row.id, privacy: .public)")
    // Upload whatever the database holds now (a backlog from before sign-in, or from the last session).
    Task { await scope.hub.backgroundPush(reason: "sign-in") }
    await publish()
    return status()
  }

  /// `hub join` with an enrollment code, the operator path for a hub with sign-up closed: while signed
  /// out it enrolls and signs in as that account, exactly as a sign-in would. While signed in it joins
  /// from the current account, which refuses when that account has already joined.
  public func join(url: String, code: String, deviceName: String) async throws -> HubStatus.Result {
    if let scope = slot.get() {
      return try await scope.hub.join(url: url, code: code, deviceName: deviceName)
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
    _ = try await signIn(
      session: AuthSession(
        deviceId: enrolled.deviceId, token: enrolled.token, org: enrolled.org, user: enrolled.user,
        needsOnboarding: false),
      hubURL: base.absoluteString, deviceName: name)
    let joined = try self.scope()
    _ = try? await joined.hub.pushNow()
    return try await joined.hub.status()
  }

  /// Sign out of the current account: close its scope, forget its token, and publish `account.changed`
  /// with `reason` (nil when the person asked). Nothing happens while nobody is signed in.
  ///
  /// Logging out (Task 10) adds its own steps before this one: interrupt the running turns, push once,
  /// and end the hub session.
  public func signOut(reason: SignOutReason?) async {
    await acquire()
    defer { release() }
    await performSignOut(reason: reason)
  }

  /// The hub refused `accountId`'s token. Ignored unless that account is still the signed-in one (a
  /// late report from a scope that has since closed).
  func hubRejected(accountId: String) async {
    await acquire()
    defer { release() }
    guard let scope = slot.get(), scope.account.id == accountId else { return }
    logger.warning("the hub refused account \(accountId, privacy: .public)'s token; signing out")
    await performSignOut(reason: .rejectedByHub(scope.account.orgName))
  }

  private func performSignOut(reason: SignOutReason?) async {
    guard let scope = slot.get() else { return }
    refresh?.cancel()
    refresh = nil
    // Commands see "signed out" from here on, not a closing store; the status says so once the scope
    // is closed and the token forgotten.
    slot.set(nil)
    await scope.close(stoppingServers: true)
    await forgetToken(of: scope.account, deactivate: true)
    active = nil
    needsOnboarding = false
    self.reason = reason
    await scopeContext.diagnostics.invalidate()
    logger.info("signed out of account \(scope.account.id, privacy: .public)")
    await publish()
  }

  // MARK: - Helpers

  /// Start `row`'s scope on its opened database and make it current.
  @discardableResult
  private func install(
    row: AccountRow, database: WorkspaceDatabase, refreshNames: Bool = true
  ) async -> AccountScope {
    let id = row.id
    let scope = await AccountScope.open(
      row: row, database: database, context: scopeContext,
      onUnauthorized: { [weak self] in await self?.hubRejected(accountId: id) })
    slot.set(scope)
    await scopeContext.diagnostics.invalidate()
    if refreshNames { refreshProfile(scope) }
    return scope
  }

  /// Ask `/v1/me` for the account's current names (and whether it has onboarded), retrying with a
  /// backoff while the hub is unreachable. A 401 signs out. An account that has not joined a hub has
  /// nobody to ask.
  private func refreshProfile(_ scope: AccountScope) {
    refresh?.cancel()
    let id = scope.account.id
    refresh = Task { [weak self] in
      var backoff: Duration = .seconds(2)
      while !Task.isCancelled {
        do {
          let me = try await scope.hub.me()
          await self?.profileArrived(me, accountId: id)
          return
        } catch let error as HubError where error.code == "unauthorized" {
          await self?.hubRejected(accountId: id)
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

  private func profileArrived(_ me: MeResponse, accountId: String) async {
    guard let scope = slot.get(), scope.account.id == accountId, var row = active, row.id == accountId else {
      return
    }
    let onboarding = !me.onboarded
    guard
      row.displayName != me.user.displayName || row.orgName != me.org.name || row.deviceId != me.deviceId
        || needsOnboarding != onboarding
    else { return }
    row.displayName = me.user.displayName
    row.orgName = me.org.name
    row.deviceId = me.deviceId
    do {
      try registry.updateProfile(
        id: row.id, deviceId: row.deviceId, displayName: row.displayName, orgName: row.orgName)
    } catch {
      logger.warning(
        "could not record the account's names: \(WorkspaceError.from(error).message, privacy: .public)")
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
  /// deactivates the row when `deactivate`).
  private func forgetToken(of row: AccountRow, deactivate: Bool) async {
    if let ref = row.tokenRef.flatMap(SecretRef.init(rawValue:)) {
      do {
        _ = try await scopeContext.secretStore.remove(ref)
      } catch {
        logger.warning("could not remove account \(row.id, privacy: .public)'s token from the secret store")
      }
    }
    guard deactivate else { return }
    do {
      try registry.signOut(id: row.id)
    } catch {
      logger.warning(
        "could not record account \(row.id, privacy: .public)'s sign-out: \(WorkspaceError.from(error).message, privacy: .public)"
      )
    }
  }

  private func publish() async {
    guard let event = try? AdapterEvent.accountChanged(status()) else { return }
    await scopeContext.eventLog.publish(event)
  }

  // MARK: - One transition at a time

  /// The actor is reentrant across each `await`; transitions (start, sign-in, sign-out, a 401) must not
  /// interleave, so each holds this until it ends. Waiters are resumed in order, the lock passing
  /// straight to the next.
  private func acquire() async {
    if busy {
      await withCheckedContinuation { waiters.append($0) }
    } else {
      busy = true
    }
  }

  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}
