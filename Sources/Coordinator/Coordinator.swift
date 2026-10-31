import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

public struct CoordinatorOptions: Sendable {
  public var paths: PlatformPaths
  public var environment: [String: String]
  public var secretStore: any SecretStore

  public init(
    paths: PlatformPaths? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
    secretStore: (any SecretStore)? = nil
  ) {
    self.environment = environment
    self.paths = paths ?? PlatformPaths.resolve(environment: environment)
    self.secretStore = secretStore ?? KeychainSecretStore()
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
  public let router: Router
  public let server: SocketServer
  private let lock: SingletonLock
  private let closed = Flag()

  public var epoch: String { eventLog.epoch }

  init(
    paths: PlatformPaths, startedAt: String, database: WorkspaceDatabase, eventLog: EventLog,
    diagnostics: DiagnosticsService,
    router: Router, server: SocketServer, lock: SingletonLock
  ) {
    self.paths = paths
    self.startedAt = startedAt
    self.database = database
    self.eventLog = eventLog
    self.diagnostics = diagnostics
    self.router = router
    self.server = server
    self.lock = lock
  }

  @discardableResult
  public func publish(_ event: AdapterEvent) async -> EventEnvelope {
    await eventLog.publish(event)
  }

  public func close() async {
    guard await closed.setIfClear() else { return }
    await server.close()
    await eventLog.finish()
    try? database.close()
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
    let database: WorkspaceDatabase
    do {
      database = try WorkspaceDatabase(path: paths.databasePath)
    } catch {
      lock.release()
      throw error
    }
    let eventLog = EventLog()
    let diagnostics = DiagnosticsService(
      context: DiagnosticsService.Context(
        paths: paths, startedAt: startedAt, environment: options.environment, database: database,
        secretStore: options.secretStore, eventLog: eventLog))
    let router = Router(
      context: Router.Context(
        database: database, eventLog: eventLog, diagnostics: diagnostics, startedAt: startedAt))
    let server: SocketServer
    do {
      server = try await SocketServer.start(socketPath: paths.socketPath, router: router, eventLog: eventLog)
    } catch {
      try? database.close()
      lock.release()
      throw error
    }
    logger.info(
      "started pid \(ProcessInfo.processInfo.processIdentifier, privacy: .public) epoch \(eventLog.epoch, privacy: .public)"
    )
    return .running(
      RunningCoordinator(
        paths: paths, startedAt: startedAt, database: database, eventLog: eventLog, diagnostics: diagnostics,
        router: router, server: server, lock: lock))
  }
}
