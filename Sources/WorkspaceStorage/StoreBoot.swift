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
  /// What the one-time import of the pre-0.2 SQLite file copied, when such a file was found at
  /// `paths.databasePath` (it is renamed `.imported` afterwards); nil when there was none.
  public var imported: SQLiteImporter.Summary?

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
    do {
      let database = try WorkspaceDatabase(endpoint: paths.postgres, binDir: binDir)
      var imported: SQLiteImporter.Summary?
      if FileManager.default.fileExists(atPath: paths.databasePath) {
        do {
          imported = try SQLiteImporter.importFile(at: paths.databasePath, into: database)
          try SQLiteImporter.retire(fileAt: paths.databasePath)
        } catch {
          try? database.close()
          throw WorkspaceError(
            .internalError,
            "Importing \(paths.databasePath) into the PostgreSQL store failed: \(error). Nothing was imported; fix the file or move it aside and start again."
          )
        }
      }
      return StoreBoot(database: database, ownedServer: owned, binDir: binDir, imported: imported)
    } catch {
      // A cluster this start brought up must not outlive the failed start.
      if let owned { try? await owned.stop() }
      throw error
    }
  }
}
