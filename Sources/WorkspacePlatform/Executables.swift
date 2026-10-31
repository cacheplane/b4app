import Foundation
import WorkspaceProtocol

public struct ExecutableMatch: Sendable, Equatable {
  public var path: String
  public var source: ExecutableSource
}

/// Finds executables without a shell. A Finder launch does not inherit the interactive shell's
/// PATH, so common user-level install locations are checked after PATH.
public enum ExecutableLocator {
  /// Colon-separated override of the fallback directories. Set (even empty) it replaces the defaults;
  /// tests use an empty value to stay isolated from whatever is installed on the machine.
  public static let fallbackOverrideVariable = "B4APP_EXECUTABLE_FALLBACK_DIRS"

  /// Directories a Finder- or launchd-started process should still search. Version managers that
  /// rely on shell hooks (nvm, fnm) are covered by their on-disk layouts: nvm's newest installed
  /// version first, fnm's `default` alias. `launchctl` gives agents only `/usr/bin:/bin:/usr/sbin:/sbin`.
  static func fallbackDirectories(home: String, environment env: [String: String] = [:]) -> [String] {
    if let override = env[fallbackOverrideVariable] {
      return override.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }
    return [
      "\(home)/.local/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.npm-global/bin",
      "\(home)/.volta/bin",
      "\(home)/.bun/bin",
    ] + nvmDirectories(home: home) + [
      "\(home)/.local/share/fnm/aliases/default/bin",
      "\(home)/Library/Application Support/fnm/aliases/default/bin",
      "/opt/homebrew/opt/node/bin",
      "/usr/local/opt/node/bin",
      "/usr/bin",
    ]
  }

  /// `~/.nvm/versions/node/v*/bin`, newest version first, so a packaged app picks the Node a shell would.
  static func nvmDirectories(home: String) -> [String] {
    let root = "\(home)/.nvm/versions/node"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    func parts(_ name: String) -> [Int] {
      name.drop(while: { $0 == "v" }).split(separator: ".").map { Int($0) ?? 0 }
    }
    return names.filter { $0.hasPrefix("v") }
      .sorted { parts($0).lexicographicallyPrecedes(parts($1)) == false && parts($0) != parts($1) }
      .map { "\(root)/\($0)/bin" }
  }

  static func isExecutableFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue
    else {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: path)
  }

  /// Resolve an executable. An explicit path is validated and returned, or nil if unusable.
  /// Otherwise PATH is searched, then known user-level install directories.
  public static func find(
    _ name: String, explicitPath: String? = nil,
    environment env: [String: String] = ProcessInfo.processInfo.environment
  ) -> ExecutableMatch? {
    if let explicitPath, !explicitPath.isEmpty {
      return isExecutableFile(explicitPath) ? ExecutableMatch(path: explicitPath, source: .explicit) : nil
    }
    for dir in (env["PATH"] ?? "").split(separator: ":").map(String.init) where !dir.isEmpty {
      let candidate = (dir as NSString).appendingPathComponent(name)
      if isExecutableFile(candidate) { return ExecutableMatch(path: candidate, source: .path) }
    }
    let home = env["HOME"] ?? NSHomeDirectory()
    for dir in fallbackDirectories(home: home, environment: env) {
      let candidate = (dir as NSString).appendingPathComponent(name)
      if isExecutableFile(candidate) { return ExecutableMatch(path: candidate, source: .fallback) }
    }
    return nil
  }
}
