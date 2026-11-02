import Foundation
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// Everything that belongs to one signed-in account (sign-in plan, Task 9): its database, the session
/// service, the managed local servers, the projects, and `HubSync` (which owns the relay link, the
/// keep-awake assertion, and pairing). The relay link's executor is built from this scope's sessions,
/// projects, and database, so a command from the hub never reaches another account's threads.
///
/// The coordinator shares the rest between accounts: the lock, the cluster, the event log,
/// diagnostics, the socket server, the sleep watcher, runtime detection, and executable lookup.
/// `AccountManager` is the only code that opens or closes a scope.
public final class AccountScope: Sendable {
  /// What a scope needs from the coordinator, the same for every account.
  public struct Context: Sendable {
    public var paths: PlatformPaths
    public var environment: [String: String]
    public var secretStore: any SecretStore
    public var eventLog: EventLog
    public var diagnostics: DiagnosticsService
    public var adapterFactory: SessionService.AdapterFactory?
    public var hubAPIFactory: HubSync.APIFactory?
    public var hubLinkConnection: (any HubLinkConnection)?
    public var powerAssertions: (any PowerAssertions)?

    public init(
      paths: PlatformPaths, environment: [String: String], secretStore: any SecretStore, eventLog: EventLog,
      diagnostics: DiagnosticsService, adapterFactory: SessionService.AdapterFactory? = nil,
      hubAPIFactory: HubSync.APIFactory? = nil, hubLinkConnection: (any HubLinkConnection)? = nil,
      powerAssertions: (any PowerAssertions)? = nil
    ) {
      self.paths = paths
      self.environment = environment
      self.secretStore = secretStore
      self.eventLog = eventLog
      self.diagnostics = diagnostics
      self.adapterFactory = adapterFactory
      self.hubAPIFactory = hubAPIFactory
      self.hubLinkConnection = hubLinkConnection
      self.powerAssertions = powerAssertions
    }

    /// The hub client for `url`, as `HubSync` builds it.
    func makeAPI(_ url: URL, _ token: @escaping @Sendable () async throws -> String?) -> any HubAPI {
      hubAPIFactory?(url, token) ?? HTTPHubAPI(baseURL: url, token: token)
    }
  }

  private let row: Mutex<AccountRow>
  public let database: WorkspaceDatabase
  public let sessions: SessionService
  public let servers: LocalServerService
  public let projects: ProjectService
  public let hub: HubSync
  public let relay: RelayExecutor
  private let closed = Mutex(false)

  /// The registry row this scope was opened for; the account manager refreshes its names.
  public var account: AccountRow { row.withLock { $0 } }

  func update(account: AccountRow) { row.withLock { $0 = account } }

  private init(
    row: AccountRow, database: WorkspaceDatabase, sessions: SessionService, servers: LocalServerService,
    projects: ProjectService, hub: HubSync, relay: RelayExecutor
  ) {
    self.row = Mutex(row)
    self.database = database
    self.sessions = sessions
    self.servers = servers
    self.projects = projects
    self.hub = hub
    self.relay = relay
  }

  /// Open `row`'s database (migrating it) and start everything on it. `onUnauthorized` is called,
  /// unawaited, when the hub refuses the account's token (a push, the pull, or the relay link).
  public static func open(
    row: AccountRow, cluster: StoreCluster, context: Context,
    onUnauthorized: @escaping @Sendable () async -> Void = {}
  ) async throws -> AccountScope {
    let database = try openDatabase(row: row, cluster: cluster, createIfMissing: true)
    return await open(row: row, database: database, context: context, onUnauthorized: onUnauthorized)
  }

  /// Open and migrate the account's database without starting anything on it, so a database that
  /// cannot be opened or migrated is found before anything else changes. `createIfMissing` is false
  /// for a registered account, whose database must already exist.
  static func openDatabase(
    row: AccountRow, cluster: StoreCluster, createIfMissing: Bool
  ) throws -> WorkspaceDatabase {
    try WorkspaceDatabase(
      endpoint: cluster.endpoint(database: row.database), binDir: cluster.binDir,
      createIfMissing: createIfMissing)
  }

  /// Start the account's services on its opened database: the project backfill, sessions, the managed
  /// servers this store remembers, and `HubSync` (with its pull and link when the database has joined).
  /// Nothing here can fail; a failed backfill is logged and tried again at the next open.
  static func open(
    row: AccountRow, database: WorkspaceDatabase, context: Context,
    onUnauthorized: @escaping @Sendable () async -> Void
  ) async -> AccountScope {
    let logger = Log.logger("accounts")
    let eventLog = context.eventLog
    let servers = LocalServerService(
      context: LocalServerService.Context(
        database: database, eventLog: eventLog, environment: context.environment, paths: context.paths))
    let projects = ProjectService(database: database, eventLog: eventLog)
    // Give every existing thread without a project the project of its folder. A failure here must not
    // keep the account from opening: the next open tries again.
    do {
      let assigned = try await projects.backfill()
      if assigned > 0 { logger.info("project backfill assigned \(assigned, privacy: .public) threads") }
      let served = try await projects.backfillConnections()
      if served > 0 { logger.info("project backfill assigned \(served, privacy: .public) connections") }
    } catch {
      logger.error("project backfill failed: \(String(describing: error), privacy: .public)")
    }
    let sessions = SessionService(
      context: SessionService.Context(
        database: database, eventLog: eventLog, diagnostics: context.diagnostics,
        environment: context.environment, clientVersion: CoordinatorVersion.current,
        secretStore: context.secretStore, projects: projects, adapterFactory: context.adapterFactory,
        servers: servers))
    await sessions.start()
    await servers.startAll()
    let relay = RelayExecutor(
      sessions: sessions, projects: projects, database: database, diagnostics: context.diagnostics)
    let linkConnection = context.hubLinkConnection ?? URLSessionHubLinkConnection()
    let makeLink: HubSync.LinkFactory = { url, token in
      HubLink(
        url: url, token: token, executor: relay, eventLog: eventLog, connection: linkConnection,
        pathMonitor: NWPathMonitorSignal(), onUnauthorized: onUnauthorized)
    }
    let hub = HubSync(
      database: database, secretStore: context.secretStore, eventLog: eventLog,
      makeAPI: { context.makeAPI($0, $1) }, makeLink: makeLink,
      powerAssertions: context.powerAssertions ?? IOKitPowerAssertions(), onUnauthorized: onUnauthorized)
    await hub.start()
    return AccountScope(
      row: row, database: database, sessions: sessions, servers: servers, projects: projects, hub: hub,
      relay: relay)
  }

  /// Close the scope, in this order: the hub (link, pull, pushes, pairing, and the keep-awake
  /// assertion; nothing sends another request), the sessions' runtimes, the managed local servers
  /// (stopped through `LocalServerService`'s identity check when `stoppingServers`; a coordinator that
  /// is only restarting leaves them running to adopt again), then the database pool. Nothing here waits
  /// on the network. Closing twice does nothing.
  ///
  /// Logging out (Task 10) runs its own steps first: interrupt the running turns and wait, flush and
  /// push once, and end the hub session; then it calls this.
  public func close(stoppingServers: Bool = true) async {
    let first = closed.withLock { closed -> Bool in
      defer { closed = true }
      return !closed
    }
    guard first else { return }
    await hub.close()
    await sessions.shutdown()
    if stoppingServers { await servers.stopAll() }
    await servers.shutdown()
    try? database.close()
  }
}
