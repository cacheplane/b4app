import Foundation
import WorkspaceProtocol

public struct ExecutableMatch: Sendable, Equatable {
  public var path: String
  public var source: ExecutableSource
}

/// Finds executables without a shell. A Finder launch does not inherit the interactive shell's
/// PATH, so common user-level install locations are checked after PATH.
public enum ExecutableLocator {
  static func fallbackDirectories(home: String) -> [String] {
    [
      "\(home)/.local/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.npm-global/bin",
      "\(home)/.volta/bin",
      "\(home)/.bun/bin",
      "/usr/bin",
    ]
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
    for dir in fallbackDirectories(home: home) {
      let candidate = (dir as NSString).appendingPathComponent(name)
      if isExecutableFile(candidate) { return ExecutableMatch(path: candidate, source: .fallback) }
    }
    return nil
  }
}
