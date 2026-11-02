import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// The packaged app's LaunchAgent (M6, D-038). `SMAppService` registers it from the app; both the
/// app and the CLI use `launchctl` to restart or query it, since the framework has no start call.
public enum LaunchAgentControl {
  public static let label = "com.cacheplane.b4app\(Flavor.current.idSuffix).coordinator"
  public static let plistName = "\(label).plist"

  public static var domain: String { "gui/\(getuid())" }

  /// True when launchd knows the agent in this user's session (registered and approved).
  public static func isLoaded() async -> Bool {
    (try? await CommandRunner.run(
      "/bin/launchctl", ["print", "\(domain)/\(label)"], options: CommandOptions(timeout: .seconds(5))))?
      .exitCode == 0
  }

  /// Start the agent, killing a running instance first (`kickstart -k`). The coordinator's lock makes a
  /// restart safe: the new process waits for nothing and simply acquires the released lock.
  public static func kickstart() async throws {
    let result = try await CommandRunner.run(
      "/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"],
      options: CommandOptions(timeout: .seconds(10)))
    guard result.exitCode == 0 else {
      throw WorkspaceError(
        .endpointUnavailable,
        "launchctl kickstart failed (\(result.exitCode ?? -1)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }

  // MARK: - The per-user agent (D-042)

  /// `~/Library/LaunchAgents/<label>.plist`: a classic user agent with an absolute program path. It
  /// replaced the `SMAppService` bundle agent because launchd pins a code requirement to a managed
  /// program and an ad hoc build changes its hash on every rebuild, after which the managed job sits
  /// in "spawn scheduled, EX_CONFIG" and nothing short of a signing identity refreshes it.
  public static func userPlistPath(home: String = NSHomeDirectory()) -> String {
    "\(home)/Library/LaunchAgents/\(plistName)"
  }

  /// The property list for the user agent: the bundled coordinator by absolute path, started at
  /// load, restarted only after a failure, in the Aqua session so Keychain and runtimes behave as
  /// they do for the user's shell.
  public static func userPlist(programPath: String) -> String {
    let escaped = programPath.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
      of: "<", with: "&lt;")
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array><string>\(escaped)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        <key>LimitLoadToSessionType</key><string>Aqua</string>
        <key>ProcessType</key><string>Interactive</string>
      </dict>
      </plist>

      """
  }

  /// The program the installed user agent points at, if the plist exists.
  public static func installedProgramPath(home: String = NSHomeDirectory()) -> String? {
    guard let data = FileManager.default.contents(atPath: userPlistPath(home: home)),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let arguments = plist["ProgramArguments"] as? [String]
    else { return nil }
    return arguments.first
  }

  /// Write the plist for `programPath` (replacing any other) and bootstrap it. A loaded job is
  /// booted out first so launchd reads the new file. Returns true when launchd accepted it.
  @discardableResult
  public static func install(programPath: String, home: String = NSHomeDirectory()) async throws -> Bool {
    let path = userPlistPath(home: home)
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try userPlist(programPath: programPath).write(toFile: path, atomically: true, encoding: .utf8)
    if await isLoaded() {
      _ = try? await CommandRunner.run(
        "/bin/launchctl", ["bootout", "\(domain)/\(label)"], options: CommandOptions(timeout: .seconds(90)))
    }
    let result = try await CommandRunner.run(
      "/bin/launchctl", ["bootstrap", domain, path], options: CommandOptions(timeout: .seconds(30)))
    guard result.exitCode == 0 else {
      throw WorkspaceError(
        .endpointUnavailable,
        "launchctl bootstrap failed (\(result.exitCode ?? -1)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    return true
  }

  /// Boot the user agent out (its coordinator exits in order) and delete the plist.
  public static func remove(home: String = NSHomeDirectory()) async {
    if await isLoaded() {
      _ = try? await CommandRunner.run(
        "/bin/launchctl", ["bootout", "\(domain)/\(label)"], options: CommandOptions(timeout: .seconds(90)))
    }
    try? FileManager.default.removeItem(atPath: userPlistPath(home: home))
  }

  /// launchd's view of the job: its state line and last exit code, for status output. A job that
  /// is loaded but "spawn failed" (exit 78, EX_CONFIG) is the sign of a bundle replaced under a
  /// registration launchd no longer trusts; the app re-registers it on its next launch.
  public struct JobState: Sendable, Equatable {
    public var state: String
    public var lastExitCode: String?
    public var runs: Int?
    /// The pid of the process launchd is running for the job, nil when it is not running.
    public var pid: Int32?
  }

  public static func jobState() async -> JobState? {
    guard
      let result = try? await CommandRunner.run(
        "/bin/launchctl", ["print", "\(domain)/\(label)"], options: CommandOptions(timeout: .seconds(5))),
      result.exitCode == 0
    else { return nil }
    return parseJobState(result.stdout)
  }

  /// Read `launchctl print` output. Nested sections repeat `state =`, so the first one wins.
  static func parseJobState(_ output: String) -> JobState {
    var job = JobState(state: "unknown")
    for raw in output.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("state = "), job.state == "unknown" {
        job.state = String(line.dropFirst("state = ".count))
      }
      if line.hasPrefix("last exit code = ") {
        job.lastExitCode = String(line.dropFirst("last exit code = ".count))
      }
      if line.hasPrefix("runs = ") { job.runs = Int(line.dropFirst("runs = ".count)) }
      if line.hasPrefix("pid = "), job.pid == nil { job.pid = Int32(line.dropFirst("pid = ".count)) }
    }
    return job
  }

  /// True when a coordinator holds the lock but is not launchd's instance of the job (the app or
  /// the CLI started it). `kickstart -k` cannot replace it: launchd's new process finds the lock
  /// held and exits 0, and the old one keeps serving, possibly from a deleted binary.
  public static func mustStopBeforeKickstart(running: LockRecord?, job: JobState?) -> Bool {
    guard let running else { return false }
    return running.pid != job?.pid
  }

  /// The property list the package script writes into `Contents/Library/LaunchAgents`. Without a
  /// log path the coordinator's stdout is dropped; its os_log output stays in Console.
  public static func plist(logPath: String? = nil) -> String {
    let log =
      logPath.map {
        "  <key>StandardOutPath</key><string>\($0)</string>\n  <key>StandardErrorPath</key><string>\($0)</string>\n"
      } ?? ""
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key><string>\(label)</string>
        <key>BundleProgram</key><string>\(CoordinatorLauncher.helperInBundle)</string>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        <key>LimitLoadToSessionType</key><string>Aqua</string>
        <key>ProcessType</key><string>Interactive</string>
      \(log)</dict>
      </plist>

      """
  }
}
