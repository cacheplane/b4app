import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Owns local B4 project registrations and their servers (spec 9.4, 9.5, 10.3): one row per project,
/// one owned instance per row, verified identity before every signal, readiness through `/healthz`,
/// logs on disk. Attached endpoints are never touched here.
public actor LocalServerService {
  public struct Context: Sendable {
    public var database: WorkspaceDatabase
    public var eventLog: EventLog
    public var environment: [String: String]
    public var paths: PlatformPaths

    public init(
      database: WorkspaceDatabase, eventLog: EventLog, environment: [String: String], paths: PlatformPaths
    ) {
      self.database = database
      self.eventLog = eventLog
      self.environment = environment
      self.paths = paths
    }
  }

  private let context: Context
  private let logger = Log.logger("servers")
  private var db: WorkspaceDatabase { context.database }

  public init(context: Context) {
    self.context = context
  }

  // MARK: - Registry

  public func add(_ params: ServerAdd.Params) async throws -> ServerAdd.Result {
    let project = try B4ProjectInspector.locate(projectPath: params.projectPath)
    guard let node = await NodeLocator.resolve(environment: context.environment) else {
      throw WorkspaceError(
        .missingExecutable,
        "No Node \(NodeLocator.minimumMajor)+ executable was found. Install Node 24 or set B4APP_NODE_PATH.")
    }
    let mode = params.launchMode ?? .source
    let envFilePath = try resolveEnvFile(params.envFilePath, root: project.root)
    if let existing = try db.localServer(projectPath: project.root) {
      let sameProfile =
        existing.launchMode == mode && existing.envFilePath == envFilePath
        && (params.port == nil || params.port == existing.requestedPort)
      if sameProfile { return ServerAdd.Result(server: existing) }
      if existing.pid != nil {
        throw WorkspaceError(
          .ownedProcessConflict,
          "Server \(existing.name) is running with a different launch profile; stop it before changing the mode, env file, or port.",
          details: ["serverId": .string(existing.id)])
      }
      if let port = params.port, port != existing.requestedPort,
        !(try db.connections(localServerId: existing.id)).isEmpty
      {
        throw WorkspaceError(
          .protocolInvalid,
          "Server \(existing.name) already has route connections on port \(existing.requestedPort ?? 0); the port cannot change. Register a new project directory or remove the connections first.",
          details: ["serverId": .string(existing.id)])
      }
      let updated =
        try db.updateLocalServer(id: existing.id) {
          $0.launchMode = mode
          $0.envFilePath = envFilePath
          if let port = params.port { $0.requestedPort = port }
          $0.nodePath = node.path
          $0.cliPath = project.cliPath
          $0.cliVersion = project.cliVersion
        } ?? existing
      await publish(updated)
      return ServerAdd.Result(server: updated)
    }
    let name = try uniqueName(params.name ?? (project.root as NSString).lastPathComponent)
    let port = try params.port ?? Ports.allocate()
    let environment = try B4ProjectInspector.childEnvironment(
      node: node.path, envFilePath: envFilePath, base: context.environment)
    let routes = try await B4ProjectInspector.routes(
      project: project, node: node.path, environment: environment)
    let logDir = context.paths.logDir + "/servers"
    try PrivateFiles.ensurePrivateDirectory(logDir)
    let server = try db.insertLocalServer(
      LocalServer(
        id: UUID().uuidString.lowercased(), name: name, projectPath: project.root, nodePath: node.path,
        cliPath: project.cliPath, cliVersion: project.cliVersion, launchMode: mode, envFilePath: envFilePath,
        requestedPort: port, routes: routes, logPath: "\(logDir)/\(name).log"))
    await publish(server)
    return ServerAdd.Result(server: server)
  }

  public func list() throws -> ServerList.Result {
    ServerList.Result(servers: try db.listLocalServers())
  }

  public func status(id: String) throws -> ServerAdd.Result {
    ServerAdd.Result(server: try require(id))
  }

  /// Re-run route discovery for a registered project.
  public func inspect(id: String) async throws -> ServerAdd.Result {
    let server = try require(id)
    let project = try B4ProjectInspector.locate(projectPath: server.projectPath)
    let environment = try B4ProjectInspector.childEnvironment(
      node: server.nodePath, envFilePath: server.envFilePath, base: context.environment)
    let routes = try await B4ProjectInspector.routes(
      project: project, node: server.nodePath, environment: environment)
    let updated =
      try db.updateLocalServer(id: server.id) {
        $0.routes = routes
        $0.cliVersion = project.cliVersion
      } ?? server
    await publish(updated)
    return ServerAdd.Result(server: updated)
  }

  /// Resolve a CLI handle: id or name.
  public func resolve(_ nameOrId: String) throws -> LocalServer {
    if let byId = try db.localServer(id: nameOrId) { return byId }
    if let byName = try db.localServer(name: nameOrId) { return byName }
    throw WorkspaceError(
      .notFound, "No managed server named \(nameOrId).", details: ["server": .string(nameOrId)])
  }

  // MARK: - Lifecycle (task 5)

  public func start(id: String) async throws -> ServerAdd.Result {
    throw WorkspaceError(.notImplemented, "server.start is wired in M4 task 5.")
  }

  public func stop(id: String, force: Bool) async throws -> ServerAdd.Result {
    throw WorkspaceError(.notImplemented, "server.stop is wired in M4 task 5.")
  }

  public func restart(id: String, force: Bool) async throws -> ServerAdd.Result {
    throw WorkspaceError(.notImplemented, "server.restart is wired in M4 task 5.")
  }

  public func logs(_ params: ServerLogs.Params) throws -> ServerLogs.Result {
    throw WorkspaceError(.notImplemented, "server.logs is wired in M4 task 6.")
  }

  public func isReady(id: String) -> Bool {
    (try? db.localServer(id: id))?.health == .ready
  }

  public func startAll() async {}

  public func shutdown() async {}

  // MARK: - Helpers

  private func require(_ id: String) throws -> LocalServer {
    guard let server = try db.localServer(id: id) else {
      throw WorkspaceError(
        .notFound, "Managed server \(id) does not exist.", details: ["serverId": .string(id)])
    }
    return server
  }

  private func resolveEnvFile(_ requested: String?, root: String) throws -> String? {
    if let requested, !requested.isEmpty {
      let path = ((requested as NSString).expandingTildeInPath as NSString).standardizingPath
      guard FileManager.default.isReadableFile(atPath: path) else {
        throw WorkspaceError(
          .protocolInvalid, "Env file \(requested) does not exist.",
          details: ["envFilePath": .string(requested)])
      }
      return path
    }
    let fallback = root + "/.env"
    return FileManager.default.isReadableFile(atPath: fallback) ? fallback : nil
  }

  private func uniqueName(_ requested: String) throws -> String {
    let sanitized = requested.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
    let name = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !name.isEmpty else { throw WorkspaceError(.protocolInvalid, "A server needs a name.") }
    if let clash = try db.localServer(name: name) {
      throw WorkspaceError(
        .protocolInvalid, "The name \(name) is already used by \(clash.projectPath); pass --name.",
        details: ["name": .string(name)])
    }
    return name
  }

  private func publish(_ server: LocalServer) async {
    if let event = try? AdapterEvent.serverChanged(server) { await context.eventLog.publish(event) }
  }
}
