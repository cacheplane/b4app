import Foundation
import WorkspacePlatform
import WorkspaceProtocol

public enum CodexInspector {
  /// Oldest Codex CLI line whose app-server surface matches the research baseline (0.166.0, 2026-10-29).
  public static let minimumVersion = "0.166.0"

  public static let installGuidance =
    "Install the Codex CLI with `npm install -g @openai/codex` or `brew install --cask codex`, or set an explicit executable path."

  /// Inspect the Codex executable without starting the app server or issuing inference.
  /// Account status (`account/read`) needs the app-server handshake and lands in M1.
  public static func inspect(
    explicitPath: String? = nil, environment env: [String: String] = ProcessInfo.processInfo.environment
  ) async -> ConnectionInspection {
    guard let found = ExecutableLocator.find("codex", explicitPath: explicitPath, environment: env) else {
      let message =
        explicitPath.map { "No executable at \($0). \(installGuidance)" }
        ?? "Codex CLI not found. \(installGuidance)"
      return ConnectionInspection(
        status: .error, message: message,
        error: WorkspaceError(.missingExecutable, "Codex executable not found."))
    }
    let result: CommandResult
    do {
      result = try await CommandRunner.run(
        found.path, ["--version"], options: CommandOptions(timeout: .seconds(8), environment: env))
    } catch {
      return ConnectionInspection(
        status: .error, executablePath: found.path,
        message: "Could not run \(found.path): \(WorkspaceError.from(error).message)",
        error: WorkspaceError(.missingExecutable, "Codex executable failed to launch."))
    }
    guard result.succeeded, let version = Versions.parse(result.stdout) ?? Versions.parse(result.stderr)
    else {
      return ConnectionInspection(
        status: .incompatible, executablePath: found.path,
        message:
          "Unexpected output from `codex --version` (exit \(result.exitCode.map(String.init) ?? "none")).",
        error: WorkspaceError(.incompatibleVersion, "Could not determine Codex version."))
    }
    if Versions.compare(version, minimumVersion) < 0 {
      return ConnectionInspection(
        status: .incompatible, executablePath: found.path, version: version,
        message: "Codex \(version) is older than the tested minimum \(minimumVersion). Update the CLI.",
        error: WorkspaceError(.incompatibleVersion, "Codex \(version) < \(minimumVersion)"))
    }
    return ConnectionInspection(
      status: .ready, authStatus: .unknown, executablePath: found.path, version: version,
      message: "Executable available. Account status is checked through the app server (M1).")
  }
}
