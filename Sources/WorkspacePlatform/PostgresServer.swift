import Foundation
import WorkspaceProtocol

/// Where a private PostgreSQL cluster lives (decision D-041): the bundled binaries, a data directory
/// under the app's data directory, and a Unix socket in the runtime directory. Nothing listens on TCP.
public struct PostgresCluster: Sendable, Equatable {
  public var binDir: String
  public var dataDir: String
  public var socketDir: String
  public var logPath: String
  /// Only names the socket file (`.s.PGSQL.<port>`); no TCP port is ever opened.
  public var port: Int
  public var user: String
  /// 20 suits one coordinator; the shared test cluster serves many at once.
  public var maxConnections: Int

  public init(
    binDir: String, dataDir: String, socketDir: String, logPath: String, port: Int = 5432,
    user: String = NSUserName(), maxConnections: Int = 20
  ) {
    self.binDir = binDir
    self.dataDir = dataDir
    self.socketDir = socketDir
    self.logPath = logPath
    self.port = port
    self.user = user
    self.maxConnections = maxConnections
  }

  public var socketPath: String { (socketDir as NSString).appendingPathComponent(".s.PGSQL.\(port)") }
  public var isInitialized: Bool {
    FileManager.default.fileExists(atPath: (dataDir as NSString).appendingPathComponent("PG_VERSION"))
  }
  func binary(_ name: String) -> String { (binDir as NSString).appendingPathComponent(name) }

  /// The server options every start uses: socket directory, no TCP, stderr logging (pg_ctl's `-l`
  /// file receives it), and a conservative footprint for a single-user store.
  public var serverOptions: [String] {
    [
      "-k", socketDir, "-c", "listen_addresses=", "-c", "port=\(port)", "-c", "log_destination=stderr",
      "-c", "logging_collector=off", "-c", "max_connections=\(maxConnections)", "-c", "shared_buffers=32MB",
    ]
  }
}

/// Finds the bundled PostgreSQL binaries: `B4APP_POSTGRES_BIN`, `postgres/bin` beside the current
/// executable (the app's `Contents/Helpers`), `../postgres/bin` (a SwiftPM build directory next to
/// `.build/postgres`), then the installed app.
public enum PostgresLocator {
  public static let environmentVariable = "B4APP_POSTGRES_BIN"
  static let required = ["postgres", "initdb", "pg_ctl"]

  public static func binDir(
    environment env: [String: String] = ProcessInfo.processInfo.environment,
    executableURL: URL? = Bundle.main.executableURL, anchors: [URL] = []
  ) -> String? {
    var candidates: [String] = []
    if let explicit = env[environmentVariable], !explicit.isEmpty { candidates.append(explicit) }
    // `postgres/bin` (or `Helpers/postgres/bin`) beside the executable or a resource bundle, or in
    // any ancestor up to the package's `.build`: covers Contents/Helpers in the app, a SwiftPM build
    // directory, and the test bundle inside it.
    for anchor in ([executableURL].compactMap { $0 } + anchors) {
      var dir = anchor.resolvingSymlinksInPath().deletingLastPathComponent()
      for _ in 0..<8 {
        candidates.append(dir.appendingPathComponent("postgres/bin").path)
        candidates.append(dir.appendingPathComponent("Helpers/postgres/bin").path)
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
      }
    }
    let home = env["HOME"] ?? NSHomeDirectory()
    candidates.append("/Applications/Agent Workspace.app/Contents/Helpers/postgres/bin")
    candidates.append("\(home)/Applications/Agent Workspace.app/Contents/Helpers/postgres/bin")
    return candidates.first(where: complete)
  }

  static func complete(_ dir: String) -> Bool {
    required.allSatisfy {
      FileManager.default.isExecutableFile(atPath: (dir as NSString).appendingPathComponent($0))
    }
  }
}

/// Starts, stops, and inspects the private cluster through `pg_ctl`, which waits for readiness,
/// recovers a stale `postmaster.pid`, and knows the shutdown modes. Before stopping, the postmaster
/// named by the pid file is checked to be a `postgres` serving this data directory (D-025).
public actor PostgresServer {
  public enum Status: Sendable, Equatable {
    case running(pid: Int32)
    case stopped
    case uninitialized
  }

  public nonisolated let cluster: PostgresCluster

  public init(cluster: PostgresCluster) { self.cluster = cluster }

  /// `initdb` once: UTF-8, C locale, trust authentication (the socket directory is 0700 and the
  /// only way in), the current user as the superuser. Returns true when a cluster was created.
  @discardableResult public func initializeIfNeeded() async throws -> Bool {
    if cluster.isInitialized { return false }
    try PrivateFiles.ensurePrivateDirectory((cluster.dataDir as NSString).deletingLastPathComponent)
    try PrivateFiles.ensurePrivateDirectory(cluster.socketDir)
    let result = try await run(
      "initdb",
      [
        "-D", cluster.dataDir, "-U", cluster.user, "--auth=trust", "--encoding=UTF8", "--locale=C",
        "--no-instructions",
      ], timeout: .seconds(120))
    guard result.succeeded else {
      throw WorkspaceError(
        .internalError, "initdb failed (\(result.exitCode ?? -1)): \(tail(result.stderr + result.stdout))")
    }
    return true
  }

  public func status() async throws -> Status {
    guard cluster.isInitialized else { return .uninitialized }
    let result = try await run("pg_ctl", ["-D", cluster.dataDir, "status"], timeout: .seconds(15))
    switch result.exitCode {
    case 0:
      if let pid = postmasterPid(), ProcessInspector.isAlive(pid: pid) { return .running(pid: pid) }
      return .running(pid: 0)
    case 3: return .stopped
    case 4: return .uninitialized
    default:
      throw WorkspaceError(
        .internalError, "pg_ctl status failed (\(result.exitCode ?? -1)): \(tail(result.stderr))")
    }
  }

  /// Start and wait until connections are accepted. A running cluster is adopted, not restarted.
  @discardableResult public func start(timeout: Duration = .seconds(60)) async throws -> Int32 {
    try await initializeIfNeeded()
    try PrivateFiles.ensurePrivateDirectory(cluster.socketDir)
    if case .running(let pid) = try await status(), pid > 0 { return pid }
    try? PrivateFiles.ensurePrivateDirectory((cluster.logPath as NSString).deletingLastPathComponent)
    try? LogRedactor.bound(path: cluster.logPath)
    let seconds = max(1, Int(timeout.components.seconds))
    let result = try await run(
      "pg_ctl",
      [
        "-D", cluster.dataDir, "-l", cluster.logPath, "-w", "-t", "\(seconds)", "-o",
        cluster.serverOptions.map(shellQuote).joined(separator: " "), "start",
      ], timeout: timeout + .seconds(10))
    guard result.succeeded else {
      throw WorkspaceError(
        .endpointUnavailable,
        "PostgreSQL did not start (\(result.exitCode ?? -1)): \(tail(result.stderr + result.stdout)). See \(cluster.logPath)."
      )
    }
    guard let pid = postmasterPid() else {
      throw WorkspaceError(
        .endpointUnavailable, "PostgreSQL started but left no postmaster.pid in \(cluster.dataDir).")
    }
    return pid
  }

  /// Fast shutdown (active transactions roll back, nothing is lost) after confirming the postmaster
  /// in the pid file is ours. A stopped cluster is not an error.
  public func stop(timeout: Duration = .seconds(60)) async throws {
    guard case .running(let pid) = try await status() else { return }
    if pid > 0 {
      guard let identity = ProcessInspector.identity(pid: pid),
        identity.arguments.contains(where: { $0.hasSuffix("/postgres") || $0 == "postgres" }),
        identity.arguments.contains(cluster.dataDir)
      else {
        throw WorkspaceError(
          .ownedProcessConflict,
          "Pid \(pid) in \(cluster.dataDir)/postmaster.pid is not a postgres serving that directory; nothing was stopped."
        )
      }
    }
    let seconds = max(1, Int(timeout.components.seconds))
    let result = try await run(
      "pg_ctl", ["-D", cluster.dataDir, "-w", "-t", "\(seconds)", "-m", "fast", "stop"],
      timeout: timeout + .seconds(10))
    guard result.succeeded else {
      throw WorkspaceError(
        .internalError, "pg_ctl stop failed (\(result.exitCode ?? -1)): \(tail(result.stderr))")
    }
  }

  /// The first line of `postmaster.pid`.
  public nonisolated func postmasterPid() -> Int32? {
    let path = (cluster.dataDir as NSString).appendingPathComponent("postmaster.pid")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
      let first = text.split(separator: "\n").first,
      let pid = Int32(first.trimmingCharacters(in: .whitespaces))
    else { return nil }
    return pid
  }

  private func run(_ tool: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    env["PGDATA"] = nil
    env["PGHOST"] = nil
    env["PGPORT"] = nil
    return try await CommandRunner.run(
      cluster.binary(tool), arguments, options: CommandOptions(timeout: timeout, environment: env))
  }

  private func tail(_ text: String) -> String {
    let lines = text.split(separator: "\n").suffix(5)
    return lines.joined(separator: " | ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
