import Foundation

/// Per-user locations. Environment overrides exist for tests and isolation:
/// B4APP_RUNTIME_DIR (socket and lock) and B4APP_DATA_DIR (database and logs).
/// Where the coordinator's PostgreSQL store is (decision D-041). With a `dataDir` the coordinator
/// manages the cluster itself (or adopts the one launchd runs on that directory); without one it
/// connects to an existing cluster through the socket directory (tests, or a cluster run elsewhere).
public struct PostgresEndpoint: Sendable, Equatable, Codable {
  public var socketDir: String
  public var port: Int
  public var database: String
  public var dataDir: String?
  public var logPath: String
  /// The binaries (and `../lib/libpq`); nil means "locate at start".
  public var binDir: String?

  public init(
    socketDir: String, port: Int = 5432, database: String = "workspace", dataDir: String?, logPath: String,
    binDir: String? = nil
  ) {
    self.socketDir = socketDir
    self.port = port
    self.database = database
    self.dataDir = dataDir
    self.logPath = logPath
    self.binDir = binDir
  }

  public var socketPath: String { (socketDir as NSString).appendingPathComponent(".s.PGSQL.\(port)") }
}

public struct PlatformPaths: Sendable, Equatable, Codable {
  public var runtimeDir: String
  public var dataDir: String
  public var socketPath: String
  public var lockPath: String
  /// The SQLite file of versions before 0.2 (imported once, then renamed `.imported`).
  public var databasePath: String
  public var logDir: String
  public var postgres: PostgresEndpoint

  /// The per-user directory name of the running flavour: `b4app`, `b4app-beta`, `b4app-local`.
  public static var appDirectoryName: String { directoryName(for: Flavor.current) }

  public static func directoryName(for flavor: Flavor) -> String { "b4app" + flavor.dirSuffix }

  public init(runtimeDir: String, dataDir: String) {
    self.runtimeDir = runtimeDir
    self.dataDir = dataDir
    self.socketPath = (runtimeDir as NSString).appendingPathComponent("coordinator.sock")
    self.lockPath = (runtimeDir as NSString).appendingPathComponent("coordinator.lock")
    self.databasePath = (dataDir as NSString).appendingPathComponent("workspace.sqlite")
    self.logDir = (dataDir as NSString).appendingPathComponent("logs")
    self.postgres = PostgresEndpoint(
      socketDir: runtimeDir, dataDir: (dataDir as NSString).appendingPathComponent("pg"),
      logPath: (self.logDir as NSString).appendingPathComponent("postgres.log"))
  }

  /// Resolve defaults for this platform, honoring environment overrides.
  public static func resolve(
    environment env: [String: String] = ProcessInfo.processInfo.environment
  ) -> PlatformPaths {
    let flavor = Flavor.resolve(environment: env, executableURL: Bundle.main.executableURL)
    var paths = PlatformPaths(
      runtimeDir: env["B4APP_RUNTIME_DIR"] ?? defaultRuntimeDir(env, flavor: flavor),
      dataDir: env["B4APP_DATA_DIR"] ?? defaultDataDir(flavor: flavor))
    // An external cluster (B4APP_POSTGRES_SOCKET_DIR, optionally B4APP_POSTGRES_PORT and
    // B4APP_POSTGRES_DATABASE) replaces the managed one.
    if let socketDir = env["B4APP_POSTGRES_SOCKET_DIR"], !socketDir.isEmpty {
      paths.postgres.socketDir = socketDir
      paths.postgres.dataDir = nil
      if let port = env["B4APP_POSTGRES_PORT"].flatMap(Int.init) { paths.postgres.port = port }
      if let database = env["B4APP_POSTGRES_DATABASE"], !database.isEmpty {
        paths.postgres.database = database
      }
    }
    return paths
  }

  /// A short per-user path: Unix socket paths are limited to about 104 bytes, and macOS $TMPDIR is
  /// per-user and short (see the design document).
  static func defaultRuntimeDir(_ env: [String: String], flavor: Flavor = .current) -> String {
    let tmp = env["TMPDIR"] ?? NSTemporaryDirectory()
    return (tmp as NSString).appendingPathComponent(directoryName(for: flavor))
  }

  static func defaultDataDir(flavor: Flavor = .current) -> String {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return support.appendingPathComponent(directoryName(for: flavor)).path
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
