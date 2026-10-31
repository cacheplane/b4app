import Foundation
import WorkspacePlatform
import WorkspaceProtocol

public enum ClaudeInspector {
  /// Oldest Claude Code line verified against the research baseline (2.1.282 installed).
  public static let minimumVersion = "2.1.200"

  public static let installGuidance =
    "Install Claude Code with `curl -fsSL https://claude.ai/install.sh | bash` or `npm install -g @anthropic-ai/claude-code`, or set an explicit executable path."

  /// Inspect the Claude Code executable and its auth status through the same executable and
  /// environment a session will use. Never reads credential files.
  public static func inspect(
    explicitPath: String? = nil, environment env: [String: String] = ProcessInfo.processInfo.environment
  ) async -> ConnectionInspection {
    guard let found = ExecutableLocator.find("claude", explicitPath: explicitPath, environment: env) else {
      let message =
        explicitPath.map { "No executable at \($0). \(installGuidance)" }
        ?? "Claude Code not found. \(installGuidance)"
      return ConnectionInspection(
        status: .error, message: message,
        error: WorkspaceError(.missingExecutable, "Claude Code executable not found."))
    }
    let versionResult: CommandResult
    do {
      versionResult = try await CommandRunner.run(
        found.path, ["--version"], options: CommandOptions(timeout: .seconds(15), environment: env))
    } catch {
      return ConnectionInspection(
        status: .error, executablePath: found.path,
        message: "Could not run \(found.path): \(WorkspaceError.from(error).message)",
        error: WorkspaceError(.missingExecutable, "Claude Code executable failed to launch."))
    }
    guard versionResult.succeeded,
      let version = Versions.parse(versionResult.stdout) ?? Versions.parse(versionResult.stderr)
    else {
      return ConnectionInspection(
        status: .incompatible, executablePath: found.path,
        message:
          "Unexpected output from `claude --version` (exit \(versionResult.exitCode.map(String.init) ?? "none")).",
        error: WorkspaceError(.incompatibleVersion, "Could not determine Claude Code version."))
    }
    if Versions.compare(version, minimumVersion) < 0 {
      return ConnectionInspection(
        status: .incompatible, executablePath: found.path, version: version,
        message:
          "Claude Code \(version) is older than the tested minimum \(minimumVersion). Run `claude update`.",
        error: WorkspaceError(.incompatibleVersion, "Claude Code \(version) < \(minimumVersion)"))
    }
    let auth = await ClaudeAuth.readStatus(executable: found.path, environment: env)
    guard let status = auth.status else {
      return ConnectionInspection(
        status: .incompatible, executablePath: found.path, version: version,
        message: "`claude auth status --json` did not return the expected JSON shape.",
        error: WorkspaceError(.incompatibleVersion, "Unrecognized auth status output."))
    }
    let assessment = ClaudeAuth.assess(status, environment: env)
    return ConnectionInspection(
      status: .ready, authStatus: assessment.authStatus, executablePath: found.path, version: version,
      nativeScope: assessment.nativeScope, message: assessment.message, error: assessment.error)
  }
}
