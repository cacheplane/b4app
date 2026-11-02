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
  /// Overrides the relay link's WebSocket (tests inject a `FakeHubLinkConnection`); nil uses
  /// `URLSessionHubLinkConnection`.
  public var hubLinkConnection: (any HubLinkConnection)?

  public init(
    paths: PlatformPaths? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
    secretStore: (any SecretStore)? = nil, adapterFactory: SessionService.AdapterFactory? = nil,
    hubAPIFactory: HubSync.APIFactory? = nil, hubLinkConnection: (any HubLinkConnection)? = nil
  ) {
    self.environment = environment
    self.paths = paths ?? PlatformPaths.resolve(environment: environment)
    self.secretStore = secretStore ?? KeychainSecretStore.forCurrentProcess()
    self.adapterFactory = adapterFactory
    self.hubAPIFactory = hubAPIFactory
    self.hubLinkConnection = hubLinkConnection
  }
}

public enum StartOutcome: Sendable {
  case running(RunningCoordinator)
  case alreadyRunning(LockRecord?, paths: PlatformPaths)
}

/// A started coordinator: lock, database, event log, diagnostics, router, socket server.
public final class RunningCoordinator: Sendable {
  public let paths: PlatformPaths
  public let startedAt: String
  public let database: WorkspaceDatabase
  public let eventLog: EventLog
  public let diagnostics: DiagnosticsService
  public let sessions: SessionService
  public let servers: LocalServerService
  public let hub: HubSync
  public let projects: ProjectService
  public let router: Router
  public let server: SocketServer
  public let sleepWatcher: SleepWatcher
  /// The PostgreSQL cluster this coordinator started (nil when it adopted a running one).
  public let postgres: PostgresServer?
  private let lock: SingletonLock
  private let closed = Flag()

  public var epoch: String { eventLog.epoch }

  init(
    paths: PlatformPaths, startedAt: String, database: WorkspaceDatabase, eventLog: EventLog,
    diagnostics: DiagnosticsService, sessions: SessionService, servers: LocalServerService, hub: HubSync,
    projects: ProjectService, router: Router, server: SocketServer, sleepWatcher: SleepWatcher,
    postgres: PostgresServer?,
    lock: SingletonLock
  ) {
    self.paths = paths
    self.startedAt = startedAt
    self.database = database
    self.eventLog = eventLog
    self.diagnostics = diagnostics
    self.sessions = sessions
    self.servers = servers
    self.hub = hub
    self.projects = projects
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

  public func close() async {
    guard await closed.setIfClear() else { return }
    await sleepWatcher.stop()
    await hub.stop()
    await server.close()
    await sessions.shutdown()
    await servers.shutdown()
    await eventLog.finish()
    try? database.close()
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
  /// Start the coordinator: private dirs, singleton lock, database, event log, socket server.
  /// If a live coordinator already holds the lock, returns `.alreadyRunning` so the caller connects
  /// to it instead. Never kills another process or removes a live lock.
  public static func start(options: CoordinatorOptions = CoordinatorOptions()) async throws -> StartOutcome {
    let logger = Log.logger("coordinator")
    let paths = options.paths
    try PrivateFiles.ensurePrivateDirectory(paths.runtimeDir)
    try PrivateFiles.ensurePrivateDirectory(paths.dataDir)
    try PrivateFiles.ensurePrivateDirectory(paths.logDir)

    let lock: SingletonLock
    switch try SingletonLock.acquire(path: paths.lockPath, socketPath: paths.socketPath) {
    case .held(let record):
      logger.info("already running: pid \(record?.pid ?? -1, privacy: .public)")
      return .alreadyRunning(record, paths: paths)
    case .acquired(let acquired):
      lock = acquired
    }

    let startedAt = Timestamp.now()
    let store: StoreBoot
    do {
      store = try await StoreBoot.open(paths: paths, environment: options.environment)
    } catch {
      lock.release()
      throw error
    }
    let database = store.database
    let eventLog = EventLog()
    let diagnostics = DiagnosticsService(
      context: DiagnosticsService.Context(
        paths: paths, startedAt: startedAt, environment: options.environment, database: database,
        secretStore: options.secretStore, eventLog: eventLog))
    let servers = LocalServerService(
      context: LocalServerService.Context(
        database: database, eventLog: eventLog, environment: options.environment, paths: paths))
    let projects = ProjectService(database: database, eventLog: eventLog)
    // Migrations have run; give every existing thread without a project the project of its folder. A
    // failure here must not keep the coordinator from starting: the next start tries again.
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
        database: database, eventLog: eventLog, diagnostics: diagnostics, environment: options.environment,
        clientVersion: CoordinatorVersion.current, secretStore: options.secretStore,
        projects: projects, adapterFactory: options.adapterFactory, servers: servers))
    await sessions.start()
    await servers.startAll()
    let relay = RelayExecutor(
      sessions: sessions, projects: projects, database: database, diagnostics: diagnostics)
    let linkConnection = options.hubLinkConnection ?? URLSessionHubLinkConnection()
    let makeLink: HubSync.LinkFactory = { url, token in
      HubLink(
        url: url, token: token, executor: relay, eventLog: eventLog, connection: linkConnection,
        pathMonitor: NWPathMonitorSignal())
    }
    let hub =
      options.hubAPIFactory.map {
        HubSync(
          database: database, secretStore: options.secretStore, eventLog: eventLog, makeAPI: $0,
          makeLink: makeLink)
      }
      ?? HubSync(database: database, secretStore: options.secretStore, eventLog: eventLog, makeLink: makeLink)
    let router = Router(
      context: Router.Context(
        database: database, eventLog: eventLog, diagnostics: diagnostics, sessions: sessions,
        servers: servers, hub: hub, projects: projects,
        startedAt: startedAt, paths: paths))
    await hub.start()
    let server: SocketServer
    do {
      server = try await SocketServer.start(socketPath: paths.socketPath, router: router, eventLog: eventLog)
    } catch {
      try? database.close()
      lock.release()
      throw error
    }
    // Spec 10.3 sleep/wake: a CLI-spawned coordinator has no app to tell it the Mac woke up. The relay
    // link is reopened first, so the phone sees the Mac again without waiting out a backoff (M8c).
    let sleepWatcher = SleepWatcher { [sessions, hub] _ in
      await hub.reconnectLink()
      _ = await sessions.reconcileAll(reason: "wake")
      _ = try? await hub.pushNow()
    }
    await sleepWatcher.start()
    logger.info(
      "started pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public) epoch \(eventLog.epoch, privacy: .public)"
    )
    return .running(
      RunningCoordinator(
        paths: paths, startedAt: startedAt, database: database, eventLog: eventLog, diagnostics: diagnostics,
        sessions: sessions, servers: servers, hub: hub, projects: projects, router: router,
        server: server,
        sleepWatcher: sleepWatcher,
        postgres: store.ownedServer, lock: lock))
  }
}
