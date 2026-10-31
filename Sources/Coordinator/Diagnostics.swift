import B4Adapter
import ClaudeAdapter
import CodexAdapter
import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Executable paths, versions, auth modes, endpoint compatibility, and recent errors; never secret values.
public actor DiagnosticsService {
  public struct Context: Sendable {
    public var paths: PlatformPaths
    public var startedAt: String
    public var environment: [String: String]
    public var database: WorkspaceDatabase
    public var secretStore: any SecretStore
    public var eventLog: EventLog
  }

  private let context: Context
  private var cached: (at: Date, runtimes: [RuntimeDiagnostic])?
  private var recentErrors: [RecentError] = []
  private let cacheInterval: TimeInterval = 30

  public init(context: Context) {
    self.context = context
  }

  /// Recent errors are shown to the user and copied into bug reports: known secret shapes are
  /// masked here, whatever the caller passed (D-035).
  public func recordError(scope: String, code: String, message: String) {
    recentErrors.append(RecentError(scope: scope, code: code, message: LogRedactor.redact(message)))
    if recentErrors.count > 100 { recentErrors.removeFirst(recentErrors.count - 100) }
  }

  public func read(refresh: Bool = false) async throws -> DiagnosticsReport {
    if refresh || cached == nil || Date().timeIntervalSince(cached!.at) > cacheInterval {
      cached = (Date(), try await inspectRuntimes())
    }
    let sequence = await context.eventLog.sequence
    return DiagnosticsReport(
      coordinator: CoordinatorInfo(
        version: CoordinatorVersion.current, pid: ProcessInfo.processInfo.processIdentifier,
        startedAt: context.startedAt,
        epoch: context.eventLog.epoch, sequence: sequence, runtimeDir: context.paths.runtimeDir,
        dataDir: context.paths.dataDir, socketPath: context.paths.socketPath,
        databasePath: context.paths.databasePath,
        host: ProcessInfo.processInfo.hostName),
      host: HostInfo(
        platform: "darwin", arch: Self.architecture,
        release: ProcessInfo.processInfo.operatingSystemVersionString),
      runtimes: cached?.runtimes ?? [], recentErrors: Array(recentErrors.suffix(20)))
  }

  private static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }

  private func inspectRuntimes() async throws -> [RuntimeDiagnostic] {
    let env = context.environment
    let node = await NodeLocator.resolve(environment: env)
    let codex = await CodexInspector.inspect(environment: env)
    let claude = await ClaudeInspector.inspect(environment: env)
    var runtimes = [
      RuntimeDiagnostic(
        kind: .node, executablePath: node?.path, source: node == nil ? .missing : .path,
        version: node?.version,
        status: node == nil ? .error : .ready, authStatus: .notRequired,
        message: node.map { "Node \($0.version) (\($0.source))" }
          ?? "No Node 24+ executable found; managed B4 servers cannot start."),
      RuntimeDiagnostic(
        kind: .codex, executablePath: codex.executablePath,
        source: codex.executablePath == nil ? .missing : .path,
        version: codex.version, status: codex.status, authStatus: codex.authStatus, message: codex.message),
      RuntimeDiagnostic(
        kind: .claude, executablePath: claude.executablePath,
        source: claude.executablePath == nil ? .missing : .path,
        version: claude.version, status: claude.status, authStatus: claude.authStatus, message: claude.message
      ),
    ]
    for server in try context.database.listLocalServers() {
      let status: ConnectionStatus
      switch server.health {
      case .ready: status = .ready
      case .stopped: status = .offline
      case .starting: status = .connecting
      case .unhealthy, .unknown: status = .error
      }
      runtimes.append(
        RuntimeDiagnostic(
          kind: .b4, executablePath: server.cliPath, source: .explicit, version: server.cliVersion,
          status: status,
          authStatus: .notRequired,
          message:
            "\(server.name): \(server.health.rawValue) on port \(server.requestedPort ?? 0) (\(server.launchMode.rawValue), \(server.projectPath))"
        ))
    }
    for connection in try context.database.listConnections()
    where connection.kind == .b4 && connection.b4Mode != .managedLocal {
      var authorization: String?
      if let reference = connection.authReference, let ref = SecretRef(rawValue: reference) {
        authorization = (try? await context.secretStore.read(ref)).map(
          B4HTTPClient.authorizationHeader(secret:))
      }
      let result = await B4Inspector.inspect(baseURL: connection.target, authorization: authorization)
      runtimes.append(
        RuntimeDiagnostic(
          kind: .b4, executablePath: nil, source: .explicit, version: nil, status: result.status,
          authStatus: result.authStatus, message: "\(connection.label): \(result.message ?? "")"))
    }
    return runtimes
  }
}
