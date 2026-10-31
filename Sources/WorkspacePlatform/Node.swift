import Foundation

public struct NodeExecutable: Sendable, Equatable {
  public var path: String
  public var version: String
  public var source: String
}

/// Resolves a Node >= 24 executable for managed B4 servers. Order: B4APP_NODE_PATH, PATH, fallback
/// directories, then version-manager installs. Never a shell lookup.
public enum NodeLocator {
  public static let minimumMajor = 24

  static func major(of version: String) -> Int {
    let digits = version.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
    return Int(digits) ?? 0
  }

  static func version(of path: String) async -> String? {
    guard
      let result = try? await CommandRunner.run(
        path, ["--version"], options: CommandOptions(timeout: .seconds(5))),
      result.succeeded
    else { return nil }
    let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return version.hasPrefix("v") ? version : nil
  }

  static func versionManagerCandidates(home: String) -> [String] {
    let roots = [
      "\(home)/.nvm/versions/node",
      "\(home)/.local/share/fnm/node-versions",
      "\(home)/.local/share/mise/installs/node",
      "\(home)/.asdf/installs/nodejs",
    ]
    var candidates: [(String, Int)] = []
    for root in roots {
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
      for entry in entries where major(of: entry) >= minimumMajor {
        candidates.append(("\(root)/\(entry)/bin/node", major(of: entry)))
        candidates.append(("\(root)/\(entry)/installation/bin/node", major(of: entry)))
      }
    }
    return candidates.sorted { $0.1 > $1.1 }.map(\.0)
  }

  public static func resolve(
    environment env: [String: String] = ProcessInfo.processInfo.environment
  ) async -> NodeExecutable? {
    if let explicit = env["B4APP_NODE_PATH"] {
      if let version = await version(of: explicit), major(of: version) >= minimumMajor {
        return NodeExecutable(path: explicit, version: version, source: "explicit")
      }
      return nil
    }
    if let found = ExecutableLocator.find("node", environment: env),
      let version = await version(of: found.path), major(of: version) >= minimumMajor
    {
      return NodeExecutable(path: found.path, version: version, source: found.source.rawValue)
    }
    let home = env["HOME"] ?? NSHomeDirectory()
    for candidate in versionManagerCandidates(home: home) {
      if let version = await version(of: candidate), major(of: version) >= minimumMajor {
        return NodeExecutable(path: candidate, version: version, source: "version-manager")
      }
    }
    return nil
  }
}
