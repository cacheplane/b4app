import Foundation

/// Per-user locations. Environment overrides exist for tests and isolation:
/// B4APP_RUNTIME_DIR (socket and lock) and B4APP_DATA_DIR (database and logs).
public struct PlatformPaths: Sendable, Equatable, Codable {
  public var runtimeDir: String
  public var dataDir: String
  public var socketPath: String
  public var lockPath: String
  public var databasePath: String
  public var logDir: String

  public static let appDirectoryName = "b4app"

  public init(runtimeDir: String, dataDir: String) {
    self.runtimeDir = runtimeDir
    self.dataDir = dataDir
    self.socketPath = (runtimeDir as NSString).appendingPathComponent("coordinator.sock")
    self.lockPath = (runtimeDir as NSString).appendingPathComponent("coordinator.lock")
    self.databasePath = (dataDir as NSString).appendingPathComponent("workspace.sqlite")
    self.logDir = (dataDir as NSString).appendingPathComponent("logs")
  }

  /// Resolve defaults for this platform, honoring environment overrides.
  public static func resolve(
    environment env: [String: String] = ProcessInfo.processInfo.environment
  ) -> PlatformPaths {
    PlatformPaths(
      runtimeDir: env["B4APP_RUNTIME_DIR"] ?? defaultRuntimeDir(env),
      dataDir: env["B4APP_DATA_DIR"] ?? defaultDataDir())
  }

  /// A short per-user path: Unix socket paths are limited to about 104 bytes, and macOS $TMPDIR is
  /// per-user and short (see the design document).
  static func defaultRuntimeDir(_ env: [String: String]) -> String {
    let tmp = env["TMPDIR"] ?? NSTemporaryDirectory()
    return (tmp as NSString).appendingPathComponent(appDirectoryName)
  }

  static func defaultDataDir() -> String {
    #if os(macOS)
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      return support.appendingPathComponent(appDirectoryName).path
    #else
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      return support.appendingPathComponent(appDirectoryName).path
    #endif
  }
}

public enum PrivateFiles {
  /// Create a directory owned by the current user with mode 0700.
  public static func ensurePrivateDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(
      atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  }

  public static func restrictFile(_ path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }
}
