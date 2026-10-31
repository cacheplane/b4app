import Foundation
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol

/// One private cluster per test process, started on first use from the fetched binaries and stopped
/// at exit; every caller gets its own fresh database. Production code never calls this.
public enum EphemeralPostgres {
  private static let state = Mutex<Shared?>(nil)
  /// Suites run in parallel; the one-time initdb and start happen under this lock.
  private static let startLock = NSLock()

  struct Shared {
    var cluster: PostgresCluster
  }

  /// A `PlatformPaths` for `base` whose store is a fresh database on the shared cluster.
  public static func paths(runtimeDir: String, dataDir: String) throws -> PlatformPaths {
    var paths = PlatformPaths(runtimeDir: runtimeDir, dataDir: dataDir)
    paths.postgres = try endpoint()
    return paths
  }

  /// A fresh database on the shared cluster.
  public static func endpoint() throws -> PostgresEndpoint {
    let shared = try ensureStarted()
    let name = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
    let lib = try LibPQ.load(binDir: shared.cluster.binDir)
    let admin = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(shared.cluster.socketDir) port=\(shared.cluster.port) dbname=postgres user=\(shared.cluster.user)"
    )
    try admin.execute("CREATE DATABASE \(Rows.quote(String(name)))")
    return PostgresEndpoint(
      socketDir: shared.cluster.socketDir, port: shared.cluster.port, database: String(name), dataDir: nil,
      logPath: shared.cluster.logPath, binDir: shared.cluster.binDir)
  }

  private static func ensureStarted() throws -> Shared {
    startLock.lock()
    defer { startLock.unlock() }
    if let existing = state.withLock({ $0 }) { return existing }
    guard let binDir = PostgresLocator.binDir(anchors: [Bundle.module.bundleURL]) else {
      throw WorkspaceError(
        .missingExecutable,
        "No PostgreSQL binaries: run ./Scripts/fetch-postgres.sh (or set \(PostgresLocator.environmentVariable))."
      )
    }
    let short = String(ProcessInfo.processInfo.processIdentifier)
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    let cluster = PostgresCluster(
      binDir: binDir, dataDir: NSTemporaryDirectory() + "b4pg-shared-\(short)/data",
      socketDir: (tmp as NSString).appendingPathComponent("b4pgs-\(short)"),
      logPath: NSTemporaryDirectory() + "b4pg-shared-\(short)/postgres.log", maxConnections: 300)
    try run(
      cluster, "initdb",
      [
        "-D", cluster.dataDir, "-U", cluster.user, "--auth=trust", "--encoding=UTF8", "--locale=C",
        "--no-instructions",
      ])
    try PrivateFiles.ensurePrivateDirectory(cluster.socketDir)
    try run(
      cluster, "pg_ctl",
      [
        "-D", cluster.dataDir, "-l", cluster.logPath, "-w", "-t", "60", "-o",
        cluster.serverOptions.joined(separator: " "), "start",
      ])
    atexit {
      // Best effort: stop the shared cluster when the test process exits.
      if let shared = EphemeralPostgres.state.withLock({ $0 }) {
        try? EphemeralPostgres.run(
          shared.cluster, "pg_ctl", ["-D", shared.cluster.dataDir, "-m", "immediate", "stop"])
      }
    }
    let shared = Shared(cluster: cluster)
    state.withLock { $0 = shared }
    return shared
  }

  /// Synchronous Foundation `Process`, since this runs from synchronous test code.
  private static func run(_ cluster: PostgresCluster, _ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cluster.binDir).appendingPathComponent(tool)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw WorkspaceError(
        .internalError,
        "\(tool) failed (\(process.terminationStatus)): \(String(decoding: output, as: UTF8.self).suffix(400))"
      )
    }
  }
}
