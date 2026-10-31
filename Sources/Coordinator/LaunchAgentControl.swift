import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// The packaged app's LaunchAgent (M6, D-038). `SMAppService` registers it from the app; both the
/// app and the CLI use `launchctl` to restart or query it, since the framework has no start call.
public enum LaunchAgentControl {
  public static let label = "com.cacheplane.b4app.coordinator"
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
        <key>BundleProgram</key><string>Contents/Helpers/b4app-coordinator</string>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        <key>LimitLoadToSessionType</key><string>Aqua</string>
        <key>ProcessType</key><string>Interactive</string>
      \(log)</dict>
      </plist>

      """
  }
}
