import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

public struct CoordinatorOptions: Sendable {
  public var paths: PlatformPaths
  public var environment: [String: String]
  public var secretStore: any SecretStore
  /// Overrides the per-connection adapter construction (tests inject a fake runtime).
  public var adapterFactory: SessionService.AdapterFactory?
  /// Overrides the hub client construction (tests inject a `FakeHubAPI`); nil builds `HTTPHubAPI`.
  public var hubAPIFactory: HubSync.APIFactory?
  /// Adopt the pre-flavour install's data directory once this process holds the lock and before it
  /// creates its own data directory (sign-in plan, Task 3). Nil, the default, adopts nothing; the
  /// gate that decides is `LegacyAdoption.planIfExplicitLocal`.
  public var legacyAdoption: LegacyAdoption.Plan?
  /// The waits between tries of a connection check that found its runtime unreachable.
  public var checkRetryDelays: [Duration]
  /// Overrides the relay link's WebSocket (tests inject a `FakeHubLinkConnection`); nil uses
  /// `URLSessionHubLinkConnection`.
  public var hubLinkConnection: (any HubLinkConnection)?
  /// Overrides the power assertion for "keep the Mac awake" (tests inject a `FakePowerAssertions`); nil
  /// uses IOKit.
  public var powerAssertions: (any PowerAssertions)?
  /// Which hub a sign-in goes to and whether Sign in with Apple is offered; tests pick one.
  public var flavor: Flavor

  public init(
    paths: PlatformPaths? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
    secretStore: (any SecretStore)? = nil, adapterFactory: SessionService.AdapterFactory? = nil,
    hubAPIFactory: HubSync.APIFactory? = nil, hubLinkConnection: (any HubLinkConnection)? = nil,
    powerAssertions: (any PowerAssertions)? = nil, legacyAdoption: LegacyAdoption.Plan? = nil,
    flavor: Flavor = .current, checkRetryDelays: [Duration] = [.seconds(1), .seconds(3)]
  ) {
    self.flavor = flavor
    self.environment = environment
    self.paths = paths ?? PlatformPaths.resolve(environment: environment)
    self.secretStore =
      secretStore
      ?? KeychainSecretStore.forCurrentProcess(
        flavorSuffix: Flavor.current.keychainGroupSuffix)
    self.adapterFactory = adapterFactory
    self.hubAPIFactory = hubAPIFactory
    self.legacyAdoption = legacyAdoption
    self.checkRetryDelays = checkRetryDelays
    self.hubLinkConnection = hubLinkConnection
    self.powerAssertions = powerAssertions
  }
}

public enum StartOutcome: Sendable {
  case running(RunningCoordinator)
  case alreadyRunning(LockRecord?, paths: PlatformPaths)
}

/// A started coordinator: lock, cluster, event log, diagnostics, accounts, router, socket server. The
/// signed-in account's services (database, sessions, servers, projects, hub) are its `AccountScope`,
/// `accounts.current`, nil while nobody is signed in (sign-in plan, Task 9).
public final class RunningCoordinator: Sendable {
  public let paths: PlatformPaths
  public let startedAt: String
  public let eventLog: EventLog
  public let diagnostics: DiagnosticsService
  public let accounts: AccountManager
  public let router: Router
  public let server: SocketServer
  public let sleepWatcher: SleepWatcher
  /// The PostgreSQL cluster this coordinator started (nil when it adopted a running one).
  public let postgres: PostgresServer?
  private let lock: SingletonLock
  private let closed = Flag()

  public var epoch: String { eventLog.epoch }

  init(
    paths: PlatformPaths, startedAt: String, eventLog: EventLog, diagnostics: DiagnosticsService,
    accounts: AccountManager, router: Router, server: SocketServer, sleepWatcher: SleepWatcher,
    postgres: PostgresServer?, lock: SingletonLock
  ) {
    self.paths = paths
    self.startedAt = startedAt
    self.eventLog = eventLog
    self.diagnostics = diagnostics
    self.accounts = accounts
    self.router = router
    self.server = server
    self.sleepWatcher = sleepWatcher
    self.postgres = postgres
    self.lock = lock
  }

  @discardableResult
  public func publish(_ event: AdapterEvent) async -> EventEnvelope {
    await eventLog.publish(event)
  }

  /// Stop everything. The signed-in account stays signed in, and its managed servers keep running for
  /// the next start to adopt.
  public func close() async {
    guard await closed.setIfClear() else { return }
    await sleepWatcher.stop()
    await server.close()
    await accounts.shutdown()
    await eventLog.finish()
    if let postgres { try? await postgres.stop() }
    lock.release()
    Log.logger("coordinator").info(
      "stopped pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
  }
}

private actor Flag {
  private var value = false
  func setIfClear() -> Bool {
    if value { return false }
    value = true
    return true
  }
}

public enum Coordinator {
  /// Start the coordinator: private dirs, singleton lock, cluster, event log, accounts, socket server.
  /// If a live coordinator already holds the lock, returns `.alreadyRunning` so the caller connects
  /// to it instead. Never kills another process or removes a live lock.
  public static func start(options: CoordinatorOptions = CoordinatorOptions()) async throws -> StartOutcome {
    let logger = Log.logger("coordinator")
    let paths = options.paths
    // The lock lives in the runtime directory, so that comes first; nothing creates the data
    // directory until the lock is ours, because the adoption below moves a directory into its place.
    try PrivateFiles.ensurePrivateDirectory(paths.runtimeDir)

    let lock: SingletonLock
    switch try SingletonLock.acquire(path: paths.lockPath, socketPath: paths.socketPath) {
    case .held(let record):
      logger.info("already running: pid \(record?.pid ?? -1, privacy: .public)")
      return .alreadyRunning(record, paths: paths)
    case .acquired(let acquired):
      lock = acquired
    }
    do {
      if let adoption = options.legacyAdoption {
        if try await LegacyAdoption.moveDataIfNeeded(
          flavor: .local, home: adoption.home, readHubURL: adoption.readHubURL,
          bootOutLegacy: adoption.bootOutLegacy)
        {
          logger.notice("adopted the previous install's data directory b4app as b4app-local")
        }
      }
      try PrivateFiles.ensurePrivateDirectory(paths.dataDir)
      try PrivateFiles.ensurePrivateDirectory(paths.logDir)
    } catch {
      lock.release()
      throw error
    }

    let startedAt = Timestamp.now()
    // The cluster and the account registry are shared; each account's database is opened by its scope.
    let cluster: StoreCluster
    let registry: AccountRegistry
    do {
      cluster = try await StoreCluster.start(paths: paths, environment: options.environment)
    } catch {
      lock.release()
      throw error
    }
    do {
      try importPre02Store(paths: paths, cluster: cluster)
      registry = try AccountRegistry(
        endpoint: cluster.endpoint, binDir: cluster.binDir,
        databaseName: AccountManager.registryDatabaseName(for: cluster.endpoint))
    } catch {
      await cluster.stopIfOwned()
      lock.release()
      throw error
    }
    let eventLog = EventLog()
    let diagnostics = DiagnosticsService(
      context: DiagnosticsService.Context(
        paths: paths, startedAt: startedAt, environment: options.environment,
        secretStore: options.secretStore, eventLog: eventLog))
    let accounts = AccountManager(
      context: AccountManager.Context(
        cluster: cluster, registry: registry,
        scope: AccountScope.Context(
          paths: paths, environment: options.environment, secretStore: options.secretStore,
          eventLog: eventLog, diagnostics: diagnostics, adapterFactory: options.adapterFactory,
          hubAPIFactory: options.hubAPIFactory, hubLinkConnection: options.hubLinkConnection,
          powerAssertions: options.powerAssertions, checkRetryDelays: options.checkRetryDelays),
        flavor: options.flavor))
    await diagnostics.attachAccounts { [accounts] in accounts.current }
    // Restore the active account (or adopt a joined `workspace`) before the socket opens, so the first
    // client sees it signed in.
    await accounts.start()
    let router = Router(
      context: Router.Context(
        eventLog: eventLog, diagnostics: diagnostics, accounts: accounts, startedAt: startedAt, paths: paths))
    let server: SocketServer
    do {
      server = try await SocketServer.start(socketPath: paths.socketPath, router: router, eventLog: eventLog)
    } catch {
      await accounts.shutdown()
      await cluster.stopIfOwned()
      lock.release()
      throw error
    }
    // Spec 10.3 sleep/wake: a CLI-spawned coordinator has no app to tell it the Mac woke up. The relay
    // link is reopened first, so the phone sees the Mac again without waiting out a backoff (M8c). It acts
    // on whichever account is signed in when the Mac wakes, if any.
    let sleepWatcher = SleepWatcher { [accounts] _ in
      guard let scope = accounts.current, (try? scope.enter()) != nil else { return }
      defer { scope.leave() }
      await scope.hub.reconnectLink()
      _ = await scope.sessions.reconcileAll(reason: "wake")
      _ = try? await scope.hub.pushNow()
    }
    await sleepWatcher.start()
    logger.info(
      "started pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public) epoch \(eventLog.epoch, privacy: .public)"
    )
    return .running(
      RunningCoordinator(
        paths: paths, startedAt: startedAt, eventLog: eventLog, diagnostics: diagnostics, accounts: accounts,
        router: router, server: server, sleepWatcher: sleepWatcher, postgres: cluster.ownedServer,
        lock: lock))
  }

  /// The one-time import of a pre-0.2 SQLite file goes into the store's default database (`workspace`),
  /// which the first account then adopts. Without such a file nothing is opened.
  private static func importPre02Store(paths: PlatformPaths, cluster: StoreCluster) throws {
    guard FileManager.default.fileExists(atPath: paths.databasePath) else { return }
    let database = try WorkspaceDatabase(endpoint: cluster.endpoint, binDir: cluster.binDir)
    defer { try? database.close() }
    if let imported = try StoreBoot.importLegacySQLite(paths: paths, into: database) {
      Log.logger("coordinator").notice(
        "imported \(imported.rows.values.reduce(0, +), privacy: .public) rows from the pre-0.2 store")
    }
  }
}
