import Foundation
import NIOTransport
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol

/// Connects to the running coordinator or starts the standalone executable and waits for readiness.
/// Concurrent callers converge: a second coordinator sees the lock, exits 0, and both callers connect.
public enum CoordinatorLauncher {
  public struct Result: Sendable {
    public var client: WorkspaceClient
    public var spawned: Bool
  }

  /// Locate the `b4app-coordinator` executable: B4APP_COORDINATOR_PATH, beside the current
  /// executable (CLI and coordinator share a build directory), then PATH.
  public static func executablePath(
    environment env: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    if let explicit = env["B4APP_COORDINATOR_PATH"], FileManager.default.isExecutableFile(atPath: explicit) {
      return explicit
    }
    let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
      "b4app-coordinator"
    ).path
    if let sibling, FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
    return ExecutableLocator.find("b4app-coordinator", environment: env)?.path
  }

  public static func tryConnect(socketPath: String) async -> WorkspaceClient? {
    try? await UnixSocketTransport.client(path: socketPath, timeout: .seconds(2))
  }

  public static func ensure(
    paths: PlatformPaths? = nil, environment env: [String: String] = ProcessInfo.processInfo.environment,
    executablePath: String? = nil, connectOnly: Bool = false, readyTimeout: Duration = .seconds(15)
  ) async throws -> Result {
    let paths = paths ?? PlatformPaths.resolve(environment: env)
    if let client = await tryConnect(socketPath: paths.socketPath) {
      return Result(client: client, spawned: false)
    }
    if connectOnly {
      throw WorkspaceError(.endpointUnavailable, "No coordinator is listening at \(paths.socketPath).")
    }
    guard let executable = executablePath ?? self.executablePath(environment: env) else {
      throw WorkspaceError(
        .missingExecutable,
        "Cannot find the b4app-coordinator executable. Build the package or set B4APP_COORDINATOR_PATH.")
    }
    try PrivateFiles.ensurePrivateDirectory(paths.logDir)
    let logPath = (paths.logDir as NSString).appendingPathComponent("coordinator.stdout.log")
    if !FileManager.default.fileExists(atPath: logPath) {
      FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    // Bounded like the server logs (D-029): keep the last 1 MiB once the file passes 4 MiB.
    try? LogRedactor.bound(path: logPath)
    let logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
    logHandle.seekToEndOfFile()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    var childEnv = env
    childEnv["B4APP_RUNTIME_DIR"] = paths.runtimeDir
    childEnv["B4APP_DATA_DIR"] = paths.dataDir
    process.environment = childEnv
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = logHandle
    process.standardError = logHandle
    do {
      try process.run()
    } catch {
      throw WorkspaceError(.missingExecutable, "Could not start \(executable): \(error.localizedDescription)")
    }
    let deadline = ContinuousClock.now + readyTimeout
    while ContinuousClock.now < deadline {
      if let client = await tryConnect(socketPath: paths.socketPath) {
        return Result(client: client, spawned: true)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WorkspaceError(
      .endpointUnavailable, "Coordinator did not become ready at \(paths.socketPath). See \(logPath).")
  }
}
