import B4Adapter
import ClaudeAdapter
import CodexAdapter
import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// Executable paths, versions, auth modes, endpoint compatibility, and recent errors; never secret values.
///
/// Shared by every account (sign-in plan, Task 9): runtime detection belongs to the Mac. The managed
/// servers, the B4 connections, the relay link, and the keep-awake assertion are the signed-in
/// account's, read from its scope when there is one and left out when nobody is signed in.
public actor DiagnosticsService {
  public struct Context: Sendable {
    public var paths: PlatformPaths
    public var startedAt: String
    public var environment: [String: String]
    public var secretStore: any SecretStore
    public var eventLog: EventLog
  }

  private let context: Context
  private var cached: (at: Date, runtimes: [RuntimeDiagnostic])?
  private var recentErrors: [RecentError] = []
  /// The signed-in account's scope, if any (`AccountManager.current`), attached once it exists.
  private var currentScope: (@Sendable () -> AccountScope?)?
  private let cacheInterval: TimeInterval = 30

  public init(context: Context) {
    self.context = context
  }

  /// Where the account's part of the report comes from; the account manager is built after this service.
  public func attachAccounts(_ current: @escaping @Sendable () -> AccountScope?) {
    currentScope = current
  }

  /// Forget the cached runtime list (it holds the account's servers and connections): the account changed.
  public func invalidate() {
    cached = nil
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
    let scope = currentScope?()
    return DiagnosticsReport(
      coordinator: CoordinatorInfo(
        version: CoordinatorVersion.current, pid: ProcessInfo.processInfo.processIdentifier,
        startedAt: context.startedAt,
        epoch: context.eventLog.epoch, sequence: sequence, runtimeDir: context.paths.runtimeDir,
        dataDir: context.paths.dataDir, socketPath: context.paths.socketPath,
        databasePath:
          "postgresql:///\(context.paths.postgres.database)?host=\(context.paths.postgres.socketDir)&port=\(context.paths.postgres.port)",
        host: ProcessInfo.processInfo.hostName, secretStore: context.secretStore.backend),
      host: HostInfo(
        platform: "darwin", arch: Self.architecture,
        release: ProcessInfo.processInfo.operatingSystemVersionString),
      runtimes: cached?.runtimes ?? [], recentErrors: Array(recentErrors.suffix(20)),
      relay: await scope?.hub.linkStatus(), keepAwakeHeld: await scope?.hub.keepAwakeHeld(),
      threadDeletes: try? scope?.database.threadDeleteSummary())
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
    guard let database = currentScope?()?.database else { return runtimes }
    for server in try database.listLocalServers() {
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
    for connection in try database.listConnections()
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
