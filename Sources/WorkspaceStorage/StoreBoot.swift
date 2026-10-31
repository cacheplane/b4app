import Foundation
import WorkspacePlatform
import WorkspaceProtocol

/// What the coordinator needs at start: the store open and migrated, and the cluster it may have
/// started (to stop again on close). A cluster that was already running, launchd's or another
/// process's, is adopted and left running (D-041, D-025).
public struct StoreBoot: Sendable {
  public var database: WorkspaceDatabase
  public var ownedServer: PostgresServer?
  public var binDir: String

  public static func open(paths: PlatformPaths, environment: [String: String]) async throws -> StoreBoot {
    guard
      let binDir = paths.postgres.binDir
        ?? PostgresLocator.binDir(environment: environment, anchors: [Bundle.module.bundleURL])
        ?? PostgresLocator.binDir(anchors: [Bundle.module.bundleURL])
    else {
      throw WorkspaceError(
        .missingExecutable,
        "PostgreSQL binaries not found. Run ./Scripts/fetch-postgres.sh, or set \(PostgresLocator.environmentVariable)."
      )
    }
    var owned: PostgresServer?
    if let dataDir = paths.postgres.dataDir {
      let server = PostgresServer(
        cluster: PostgresCluster(
          binDir: binDir, dataDir: dataDir, socketDir: paths.postgres.socketDir,
          logPath: paths.postgres.logPath,
          port: paths.postgres.port))
      let before = try await server.status()
      try await server.start()
      if case .running = before {} else { owned = server }
    }
    let database = try WorkspaceDatabase(endpoint: paths.postgres, binDir: binDir)
    return StoreBoot(database: database, ownedServer: owned, binDir: binDir)
  }
}
