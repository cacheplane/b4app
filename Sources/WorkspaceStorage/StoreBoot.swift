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
    let cluster = try await StoreCluster.start(paths: paths, environment: environment)
    do {
      let database = try WorkspaceDatabase(
        endpoint: paths.postgres, binDir: cluster.binDir,
        backupDirectory: backupDirectory(paths: paths, database: paths.postgres.database))
      let imported: SQLiteImporter.Summary?
      do {
        imported = try importLegacySQLite(paths: paths, into: database)
      } catch {
        try? database.close()
        throw error
      }
      return StoreBoot(
        database: database, ownedServer: cluster.ownedServer, binDir: cluster.binDir, imported: imported)
    } catch {
      // A cluster this start brought up must not outlive the failed start.
      await cluster.stopIfOwned()
      throw error
    }
  }

  /// Resolve only; directory creation belongs to pending migration admission after future checks.
  private static func backupDirectory(paths: PlatformPaths, database: String) throws -> String {
    guard !database.isEmpty,
      let component = database.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-")))
    else { throw WorkspaceError(.protocolInvalid, "A database name is required for its backup path.") }
    return URL(fileURLWithPath: paths.dataDir).appendingPathComponent("backups")
      .appendingPathComponent(component).path
  }

  /// Import the pre-0.2 SQLite file at `paths.databasePath` into `database` once, then rename it
  /// `.imported`. Nil when there is no such file.
  public static func importLegacySQLite(
    paths: PlatformPaths, into database: WorkspaceDatabase
  ) throws -> SQLiteImporter.Summary? {
    guard FileManager.default.fileExists(atPath: paths.databasePath) else { return nil }
    do {
      let imported = try SQLiteImporter.importFile(at: paths.databasePath, into: database)
      try SQLiteImporter.retire(fileAt: paths.databasePath)
      return imported
    } catch {
      throw WorkspaceError(
        .internalError,
        "Importing \(paths.databasePath) into the PostgreSQL store failed: \(error). Nothing was imported; fix the file or move it aside and start again."
      )
    }
  }
}

/// The coordinator's PostgreSQL cluster, running, with no database opened (sign-in plan, Task 9: each
/// account's database is opened by its `AccountScope`). `endpoint.database` is the store's default
/// database name (`workspace`), which the first account adopts.
public struct StoreCluster: Sendable {
  public var endpoint: PostgresEndpoint
  public var binDir: String
  /// The cluster this start brought up, to stop again on close; nil when it adopted a running one.
  public var ownedServer: PostgresServer?

  public init(endpoint: PostgresEndpoint, binDir: String, ownedServer: PostgresServer? = nil) {
    self.endpoint = endpoint
    self.binDir = binDir
    self.ownedServer = ownedServer
  }

  /// The endpoint of the database `name` on this cluster.
  public func endpoint(database name: String) -> PostgresEndpoint {
    var endpoint = endpoint
    endpoint.database = name
    return endpoint
  }

  /// Locate the binaries and start the cluster at `paths.postgres.dataDir` (or adopt the one already
  /// running there); with no data directory, connect to the external cluster as configured.
  public static func start(paths: PlatformPaths, environment: [String: String]) async throws -> StoreCluster {
    guard
      let binDir = paths.postgres.binDir
        ?? PostgresLocator.binDir(environment: environment, anchors: [StorageResources.bundle.bundleURL])
        ?? PostgresLocator.binDir(anchors: [StorageResources.bundle.bundleURL])
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
    return StoreCluster(endpoint: paths.postgres, binDir: binDir, ownedServer: owned)
  }

  /// Stop the cluster when this process started it; leave an adopted one running.
  public func stopIfOwned() async {
    if let ownedServer { try? await ownedServer.stop() }
  }
}
