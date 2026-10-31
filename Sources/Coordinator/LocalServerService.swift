import B4Adapter
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

  // MARK: - Lifecycle

  /// A live owned instance: our own child, or one adopted after a coordinator restart (D-025).
  private struct Running {
    var process: ManagedProcess?
    var identity: ProcessIdentity
    var monitor: Task<Void, Never>?
  }

  private var running: [String: Running] = [:]
  private var startTasks: [String: Task<ServerAdd.Result, any Error>] = [:]
  private static let readinessTimeout: Duration = .seconds(90)
  private static let stopGracePeriod: Duration = .seconds(10)

  /// Idempotent: a ready server returns its row; a start in flight is joined.
  public func start(id: String) async throws -> ServerAdd.Result {
    let server = try require(id)
    if server.health == .ready, running[id] != nil { return ServerAdd.Result(server: server) }
    if let inFlight = startTasks[id] { return try await inFlight.value }
    let task = Task { try await self.launch(server) }
    startTasks[id] = task
    defer { startTasks[id] = nil }
    return try await task.value
  }

  private func launch(_ server: LocalServer) async throws -> ServerAdd.Result {
    guard let port = server.requestedPort, let logPath = server.logPath else {
      throw WorkspaceError(.internalError, "Server \(server.name) has no port or log path.")
    }
    if let stale = running[server.id] {
      stale.monitor?.cancel()
      running[server.id] = nil
    }
    guard Ports.isFree(port) else {
      throw WorkspaceError(
        .ownedProcessConflict,
        "Port \(port) is in use by another process; nothing was stopped. Stop it, or register the project with --port.",
        details: ["port": .number(Double(port)), "serverId": .string(server.id)])
    }
    let environment = try B4ProjectInspector.childEnvironment(
      node: server.nodePath, envFilePath: server.envFilePath, base: context.environment)
    var arguments = [server.cliPath]
    switch server.launchMode {
    case .development:
      arguments += ["dev", "--port", String(port)]
      if let envFile = server.envFilePath { arguments += ["--env-file", envFile] }
    case .source:
      arguments += ["start", "--host", "127.0.0.1", "--port", String(port)]
    }
    try PrivateFiles.ensurePrivateDirectory((logPath as NSString).deletingLastPathComponent)
    let process = try ManagedProcess.spawn(
      executable: server.nodePath, arguments: arguments, environment: environment,
      workingDirectory: server.projectPath, outputPath: logPath)
    logger.info(
      "started \(server.name, privacy: .public) pid \(process.pid, privacy: .public) on port \(port, privacy: .public)"
    )
    var row =
      try db.updateLocalServer(id: server.id) {
        $0.generation += 1
        $0.pid = process.pid
        $0.processStartedAt = process.identity.startedAt
        $0.actualPort = nil
        $0.health = .starting
        $0.ownershipVerified = false
        $0.statusMessage = "starting (pid \(process.pid))"
      } ?? server
    running[server.id] = Running(process: process, identity: process.identity, monitor: nil)
    await publish(row)

    let client = try B4HTTPClient(baseURL: "http://127.0.0.1:\(port)", timeout: 2)
    let deadline = ContinuousClock.now + Self.readinessTimeout
    var ready = false
    var exit: ExitStatus?
    while ContinuousClock.now < deadline {
      if let status = process.exitStatus() {
        exit = status
        break
      }
      if (try? await client.health())?.status == "ready" {
        ready = true
        break
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    guard ready else {
      running[server.id] = nil
      let reason: String
      if let exit {
        reason = "Server \(server.name) exited with status \(Self.describe(exit)) before it was ready"
      } else {
        _ = await ManagedProcess.terminateGroup(pid: process.pid, gracePeriod: .seconds(3), process: process)
        reason = "Server \(server.name) did not answer /healthz within \(Self.readinessTimeout)"
      }
      let tail = (try? LogRedactor.tail(path: logPath, lines: 20, afterOffset: nil).lines) ?? []
      row =
        try db.updateLocalServer(id: server.id) {
          $0.pid = nil
          $0.processStartedAt = nil
          $0.health = .stopped
          $0.ownershipVerified = false
          $0.statusMessage = reason
        } ?? row
      await publish(row)
      throw WorkspaceError(
        .endpointUnavailable, "\(reason); see \(logPath).",
        details: ["serverId": .string(server.id), "logTail": .array(tail.map(JSONValue.string))])
    }
    row =
      try db.updateLocalServer(id: server.id) {
        $0.actualPort = port
        $0.health = .ready
        $0.ownershipVerified = true
        $0.statusMessage = "ready on http://127.0.0.1:\(port) (pid \(process.pid))"
      } ?? row
    running[server.id]?.monitor = monitor(server.id)
    await publish(row)
    await notifyConnections(serverId: server.id, ready: true)
    return ServerAdd.Result(server: row)
  }

  /// Stop a verified owned instance. Refused while a route connection has a running turn unless
  /// forced (D-030); never signals a process whose identity does not match (D-025).
  public func stop(id: String, force: Bool) async throws -> ServerAdd.Result {
    if let inFlight = startTasks[id] { _ = try? await inFlight.value }
    var server = try require(id)
    if !force, server.pid != nil {
      let active = try activeThreadIds(serverId: id)
      if !active.isEmpty {
        throw WorkspaceError(
          .ownedProcessConflict,
          "Server \(server.name) has \(active.count) running turn(s); stopping would lose them. Pass --force to stop anyway.",
          details: ["reason": "turn_active", "threadIds": .array(active.map(JSONValue.string))])
      }
    }
    let instance = running[id]
    instance?.monitor?.cancel()
    running[id] = nil
    guard let pid = server.pid else {
      if server.health != .stopped {
        server = try markStopped(server, message: "stopped")
      }
      return ServerAdd.Result(server: server)
    }
    guard verifyOwnership(server) else {
      server = try markStopped(
        server,
        message:
          "pid \(pid) is not the server started on \(Self.started(server)); left untouched. Stop it yourself if it is yours."
      )
      await notifyConnections(serverId: id, ready: false)
      return ServerAdd.Result(server: server)
    }
    let gone = await ManagedProcess.terminateGroup(
      pid: pid, gracePeriod: Self.stopGracePeriod, process: instance?.process)
    guard gone else {
      throw WorkspaceError(
        .ownedProcessConflict, "Server \(server.name) (pid \(pid)) did not exit after SIGKILL.",
        details: ["serverId": .string(id), "pid": .number(Double(pid))])
    }
    server = try markStopped(server, message: "stopped")
    await notifyConnections(serverId: id, ready: false)
    if let port = server.requestedPort, !Ports.isFree(port) {
      throw WorkspaceError(
        .ownedProcessConflict,
        "Server \(server.name) stopped but port \(port) is still in use by another process; nothing else was stopped.",
        details: ["serverId": .string(id), "port": .number(Double(port))])
    }
    return ServerAdd.Result(server: server)
  }

  public func restart(id: String, force: Bool) async throws -> ServerAdd.Result {
    _ = try await stop(id: id, force: force)
    return try await start(id: id)
  }

  /// A redacted tail of the log file the child writes (D-029); the file is bounded first.
  public func logs(_ params: ServerLogs.Params) throws -> ServerLogs.Result {
    let server = try require(params.serverId)
    guard let logPath = server.logPath else {
      return ServerLogs.Result(lines: [], offset: 0, truncated: false, logPath: "")
    }
    try LogRedactor.bound(path: logPath)
    let tail = try LogRedactor.tail(
      path: logPath, lines: params.lines ?? 200, afterOffset: params.afterOffset)
    return ServerLogs.Result(
      lines: tail.lines, offset: tail.offset, truncated: tail.truncated, logPath: logPath)
  }

  public func isReady(id: String) -> Bool {
    running[id] != nil && (try? db.localServer(id: id))?.health == .ready
  }

  /// Coordinator start: re-verify every remembered pid. A match is adopted; anything else is left
  /// alone and the row is marked stopped (spec 10.3).
  public func startAll() async {
    for server in (try? db.listLocalServers()) ?? [] where server.pid != nil {
      let pid = server.pid!
      if verifyOwnership(server), let identity = ProcessInspector.identity(pid: pid) {
        let healthy = await isHealthy(server)
        running[server.id] = Running(process: nil, identity: identity, monitor: nil)
        let row =
          try? db.updateLocalServer(id: server.id) {
            $0.health = healthy ? .ready : .unhealthy
            $0.ownershipVerified = true
            $0.statusMessage =
              healthy
              ? "ready on http://127.0.0.1:\(server.requestedPort ?? 0) (pid \(pid), adopted)"
              : "pid \(pid) is alive but /healthz is not answering (adopted)"
          }
        running[server.id]?.monitor = monitor(server.id)
        if let row { await publish(row) }
        await notifyConnections(serverId: server.id, ready: healthy)
        logger.info("adopted \(server.name, privacy: .public) pid \(pid, privacy: .public)")
      } else {
        let message =
          ProcessInspector.isAlive(pid: pid)
          ? "pid \(pid) is not the server started on \(Self.started(server)); left untouched"
          : "process \(pid) started on \(Self.started(server)) is gone"
        if let row = try? markStopped(server, message: message) { await publish(row) }
        await notifyConnections(serverId: server.id, ready: false)
      }
    }
  }

  /// Monitors stop; servers keep running across a coordinator exit.
  public func shutdown() async {
    for (id, instance) in running {
      instance.monitor?.cancel()
      running[id]?.monitor = nil
    }
  }

  // MARK: - Ownership and health

  private func verifyOwnership(_ server: LocalServer) -> Bool {
    guard let pid = server.pid, let startedAt = server.processStartedAt, let port = server.requestedPort,
      let identity = ProcessInspector.identity(pid: pid)
    else { return false }
    return identity.matches(
      pid: pid, startedAt: startedAt, requiredArguments: [server.cliPath, String(port)])
  }

  private func isHealthy(_ server: LocalServer) async -> Bool {
    guard let port = server.requestedPort,
      let client = try? B4HTTPClient(baseURL: "http://127.0.0.1:\(port)", timeout: 2)
    else { return false }
    return (try? await client.health())?.status == "ready"
  }

  private func monitor(_ id: String) -> Task<Void, Never> {
    Task { [weak self] in
      var failures = 0
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        if await self.checkProcess(id) { return }
        tick += 1
        if tick % 10 == 0 {
          if let server = try? await self.require(id), await self.isHealthy(server) {
            failures = 0
            if server.health == .unhealthy { await self.markHealth(id, .ready, "ready again") }
          } else {
            failures += 1
            if failures >= 3 { await self.markHealth(id, .unhealthy, "/healthz failed \(failures) times") }
          }
        }
      }
    }
  }

  /// True when the instance is gone (and the row has been marked stopped).
  private func checkProcess(_ id: String) async -> Bool {
    guard let instance = running[id], let server = try? require(id) else { return true }
    let gone: String?
    if let process = instance.process, let exit = process.exitStatus() {
      gone = "exited with status \(Self.describe(exit))"
    } else if instance.process == nil, !verifyOwnership(server) {
      gone = "process \(server.pid ?? 0) exited"
    } else {
      gone = nil
    }
    guard let gone else { return false }
    running[id]?.monitor = nil
    running[id] = nil
    logger.warning("\(server.name, privacy: .public) \(gone, privacy: .public)")
    if let row = try? markStopped(server, message: gone) { await publish(row) }
    await notifyConnections(serverId: id, ready: false)
    return true
  }

  private func markHealth(_ id: String, _ health: LocalServerHealth, _ message: String) async {
    guard
      let row = try? db.updateLocalServer(
        id: id,
        {
          $0.health = health
          $0.statusMessage = message
        })
    else { return }
    await publish(row)
    await notifyConnections(serverId: id, ready: health == .ready)
  }

  private func markStopped(_ server: LocalServer, message: String) throws -> LocalServer {
    try db.updateLocalServer(id: server.id) {
      $0.pid = nil
      $0.processStartedAt = nil
      $0.actualPort = nil
      $0.health = .stopped
      $0.ownershipVerified = false
      $0.statusMessage = message
    } ?? server
  }

  /// Threads on this server's route connections with a turn that stopping would lose. A parked
  /// (`waiting_for_user`) turn is durable in `.b4`, and a `reconciling` one is already lost; neither
  /// counts.
  private func activeThreadIds(serverId: String) throws -> [String] {
    var ids: [String] = []
    for connection in try db.connections(localServerId: serverId) {
      for thread in try db.listThreads(ThreadFilter(connectionId: connection.id, includeArchived: true)) {
        if let turn = try db.activeTurn(threadId: thread.id),
          [.submitting, .running, .stopping].contains(turn.status)
        {
          ids.append(thread.id)
        }
      }
    }
    return ids
  }

  /// Route connections follow their server: `ready` while it answers, `offline` otherwise.
  private func notifyConnections(serverId: String, ready: Bool) async {
    for connection in (try? db.connections(localServerId: serverId)) ?? [] {
      let status: ConnectionStatus = ready ? .ready : .offline
      guard connection.status != status || !ready else { continue }
      _ = try? db.updateConnection(id: connection.id) { $0.status = status }
      await context.eventLog.publish(
        AdapterEvent.connectionChanged(
          connectionId: connection.id, status: status, authStatus: connection.authStatus,
          transport: ready ? .connected : .disconnected,
          message: ready ? "Managed server is ready." : "Managed server is not running."))
    }
  }

  private static func describe(_ exit: ExitStatus) -> String {
    switch exit {
    case .exited(let code): return String(code)
    case .signaled(let signal): return "signal \(signal)"
    }
  }

  private static func started(_ server: LocalServer) -> String {
    guard let at = server.processStartedAt else { return "an unknown date" }
    return Timestamp.string(from: Date(timeIntervalSince1970: at))
  }

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
