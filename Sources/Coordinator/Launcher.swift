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

  /// The coordinator inside the app bundle (D-051): a minimal app-like bundle in `Contents/Helpers`,
  /// so a Developer ID build can embed the provisioning profile that authorises its keychain access
  /// group. The packaged CLI stays a bare tool in `Contents/Helpers`.
  public static let helperWrapper = "B4AppCoordinator.app/Contents/MacOS/b4app-coordinator"
  public static let helperInBundle = "Contents/Helpers/\(helperWrapper)"
  public static let bundledHelperPath = "Agent Workspace.app/\(helperInBundle)"

  /// Locate the `b4app-coordinator` executable: B4APP_COORDINATOR_PATH, beside the current
  /// executable with symlinks resolved (the wrapper in the app's `Contents/Helpers`, or the bare
  /// tool in a SwiftPM build directory), the installed app in `/Applications` or `~/Applications`,
  /// then PATH and the fallback directories.
  public static func executablePath(
    environment env: [String: String] = ProcessInfo.processInfo.environment,
    executableURL: URL? = Bundle.main.executableURL
  ) -> String? {
    for candidate in candidatePaths(environment: env, executableURL: executableURL)
    where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    return ExecutableLocator.find("b4app-coordinator", environment: env)?.path
  }

  static func candidatePaths(environment env: [String: String], executableURL: URL?) -> [String] {
    var candidates: [String] = []
    if let explicit = env["B4APP_COORDINATOR_PATH"], !explicit.isEmpty { candidates.append(explicit) }
    if let executableURL {
      let resolved = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
      candidates.append(resolved.appendingPathComponent(helperWrapper).path)
      candidates.append(resolved.appendingPathComponent("b4app-coordinator").path)
    }
    let home = env["HOME"] ?? NSHomeDirectory()
    candidates.append("/Applications/\(bundledHelperPath)")
    candidates.append("\(home)/Applications/\(bundledHelperPath)")
    return candidates
  }

  /// The live holder of the coordinator lock, or nil when no coordinator is running.
  public static func runningRecord(paths: PlatformPaths? = nil) -> LockRecord? {
    SingletonLock.peek(path: (paths ?? PlatformPaths.resolve()).lockPath)
  }

  /// Ask the running coordinator to exit (SIGTERM, which it treats as an orderly close) and wait for
  /// the lock to clear. Returns the record that was stopped, or nil when nothing was running. Never
  /// escalates to SIGKILL: an owned runtime process must get its orderly shutdown.
  @discardableResult public static func stop(
    paths: PlatformPaths? = nil, timeout: Duration = .seconds(10)
  ) async throws -> LockRecord? {
    let paths = paths ?? PlatformPaths.resolve()
    guard let record = runningRecord(paths: paths) else { return nil }
    if kill(record.pid, SIGTERM) != 0, errno != ESRCH {
      throw WorkspaceError(
        .endpointUnavailable,
        "Could not signal coordinator pid \(record.pid): \(String(cString: strerror(errno)))")
    }
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if SingletonLock.peek(path: paths.lockPath) == nil { return record }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw WorkspaceError(
      .endpointUnavailable, "Coordinator pid \(record.pid) did not exit within \(timeout); it was not killed."
    )
  }

  /// Wait for a coordinator other than `previous` to hold the lock (launchd starts it
  /// asynchronously after a kickstart). Returns nil when none appeared within `timeout`.
  public static func waitForReplacement(
    of previous: LockRecord?, paths: PlatformPaths? = nil, timeout: Duration = .seconds(15)
  ) async throws -> LockRecord? {
    let paths = paths ?? PlatformPaths.resolve()
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let record = runningRecord(paths: paths), record.pid != previous?.pid { return record }
      try await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  /// Fail when a restart left the same process holding the lock.
  public static func confirmReplaced(previous: LockRecord?, current: LockRecord?) throws {
    guard let previous, let current, current.pid == previous.pid else { return }
    throw WorkspaceError(
      .endpointUnavailable,
      "Coordinator pid \(previous.pid) is still running after the restart; run `coordinator stop` and retry.")
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
