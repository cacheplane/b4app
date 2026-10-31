import Darwin
import Foundation
import Synchronization
import WorkspaceProtocol

/// A server child spawned to outlive the coordinator (D-024): `posix_spawn` into its own process
/// group, stdin from `/dev/null`, stdout and stderr appended to a log file, the working directory set
/// explicitly, the environment exactly what the caller passes. Arguments are an array, never a shell
/// string. The identity is captured right after the spawn so later signals can be verified.
public final class ManagedProcess: Sendable {
  public let pid: Int32
  public let identity: ProcessIdentity
  private let exit = Mutex<ExitStatus?>(nil)

  private init(pid: Int32, identity: ProcessIdentity) {
    self.pid = pid
    self.identity = identity
  }

  public static func spawn(
    executable: String, arguments: [String], environment: [String: String], workingDirectory: String,
    outputPath: String
  ) throws -> ManagedProcess {
    let logFd = open(outputPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    guard logFd >= 0 else {
      throw WorkspaceError(.internalError, "Could not open the log file \(outputPath): \(errnoText())")
    }
    defer { close(logFd) }
    fchmod(logFd, 0o600)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO)
    posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    guard status == 0 else {
      throw WorkspaceError(
        .missingExecutable, "Could not start \(executable): \(String(cString: strerror(status)))")
    }
    let identity =
      ProcessInspector.identity(pid: pid)
      ?? ProcessIdentity(
        pid: pid, startedAt: Date().timeIntervalSince1970, arguments: [executable] + arguments)
    return ManagedProcess(pid: pid, identity: identity)
  }

  /// Non-blocking reap of this coordinator's own child; nil while it runs. Cached once known.
  public func exitStatus() -> ExitStatus? {
    exit.withLock { cached in
      if let cached { return cached }
      var status: Int32 = 0
      let reaped = waitpid(pid, &status, WNOHANG)
      guard reaped == pid else { return nil }
      let result: ExitStatus
      if (status & 0x7f) == 0 {
        result = .exited((status >> 8) & 0xff)
      } else {
        result = .signaled(status & 0x7f)
      }
      cached = result
      return result
    }
  }

  /// SIGTERM to the process group, wait up to `gracePeriod`, then SIGKILL to the group. Returns
  /// whether the leader is gone. The caller verifies ownership before calling this (D-025).
  public static func terminateGroup(pid: Int32, gracePeriod: Duration) async -> Bool {
    guard pid > 1 else { return true }
    kill(-pid, SIGTERM)
    let deadline = ContinuousClock.now + gracePeriod
    while ContinuousClock.now < deadline {
      reap(pid)
      if !ProcessInspector.isAlive(pid: pid) { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    kill(-pid, SIGKILL)
    for _ in 0..<20 {
      reap(pid)
      if !ProcessInspector.isAlive(pid: pid) { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return !ProcessInspector.isAlive(pid: pid)
  }

  /// Collect the exit of a child of this process so it does not linger as a zombie; harmless for a
  /// process that is not our child.
  private static func reap(_ pid: Int32) {
    var status: Int32 = 0
    _ = waitpid(pid, &status, WNOHANG)
  }

  private static func errnoText() -> String { String(cString: strerror(errno)) }
}
