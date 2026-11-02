import Darwin
import Foundation
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage

/// The local flavour takes over the owner's pre-flavour install (sign-in plan, Task 3): today's
/// packaged app keeps its data in `~/Library/Application Support/b4app`, runs the LaunchAgent
/// `com.cacheplane.b4app.coordinator`, and has a hub link to `http://localhost:8080`. A local-flavour
/// build moves that directory to `b4app-local` so the owner keeps their threads, and copies the
/// secrets that data references (the hub token, the connections' keys) from the prod keychain group
/// to its own, once (D-091).
///
/// Nothing here moves a directory unless every check passes and the old install has been stopped:
/// a failure at any step leaves `b4app` exactly as it was.
public enum LegacyAdoption {
  /// The label of the pre-flavour LaunchAgent.
  public static let legacyLabel = "com.cacheplane.b4app.coordinator"

  // MARK: - The move

  /// Move `b4app` to `b4app-local` when this is the local flavour, `b4app` is a directory, its hub
  /// link points at this Mac, and `b4app-local` does not hold a cluster. Returns true when it moved.
  ///
  /// `b4app-local` that is absent, or a directory without `pg/PG_VERSION`, counts as not yet adopted:
  /// the CLI launcher or an early start can leave `logs/` there. An empty one (directories and
  /// zero-byte files only) is removed to make room; one holding anything else is renamed aside
  /// (`b4app-local.aside-<time>`), never deleted, and renamed back if the move fails. Anything else at
  /// that path (a file, a symbolic link, a directory with a cluster) stops the adoption.
  ///
  /// `home` is the user's home directory; both data directories live under
  /// `Library/Application Support`. `readHubURL` is given the legacy data directory and returns the
  /// URL of its hub link (nil when it has none); it must leave the legacy install as it found it.
  /// `bootOutLegacy` stops the old install's LaunchAgent and cluster; it runs only after the link
  /// has been read and found local, and the directory is moved only after it returns. Any throw from
  /// either closure leaves the data in place and propagates. The caller holds the coordinator's
  /// singleton lock, which keeps two coordinators from adopting at once.
  public static func moveDataIfNeeded(
    flavor: Flavor, home: URL, readHubURL: (URL) async throws -> String?,
    bootOutLegacy: () async throws -> Void
  ) async throws -> Bool {
    guard flavor == .local else { return false }
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    let legacy = support.appendingPathComponent(PlatformPaths.directoryName(for: .prod), isDirectory: true)
    let target = support.appendingPathComponent(PlatformPaths.directoryName(for: .local), isDirectory: true)
    guard isRealDirectory(legacy), targetIsFree(target) else { return false }
    guard let link = try await readHubURL(legacy), pointsAtThisMac(link) else { return false }
    try await bootOutLegacy()
    try moveIntoPlace(legacy, to: target)
    return true
  }

  /// True when nothing is at `target`, or a real directory that holds no cluster.
  private static func targetIsFree(_ target: URL) -> Bool {
    guard existsAtAll(target) else { return true }
    return isRealDirectory(target)
      && !FileManager.default.fileExists(atPath: target.appendingPathComponent("pg/PG_VERSION").path)
  }

  private static func moveIntoPlace(_ legacy: URL, to target: URL) throws {
    let fileManager = FileManager.default
    var aside: URL?
    if existsAtAll(target) {
      if holdsNoData(target) {
        try fileManager.removeItem(at: target)
      } else {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(target.lastPathComponent).aside-\(stamp)-\(UUID().uuidString.prefix(6))"
        let destination = target.deletingLastPathComponent().appendingPathComponent(name)
        try fileManager.moveItem(at: target, to: destination)
        aside = destination
      }
    }
    do {
      try fileManager.moveItem(at: legacy, to: target)
    } catch {
      if let aside { try? fileManager.moveItem(at: aside, to: target) }
      throw error
    }
  }

  /// True for a tree of directories and zero-byte regular files, which a launcher or an early start
  /// creates and which hold nothing worth keeping. A symbolic link or anything else says no.
  private static func holdsNoData(_ directory: URL) -> Bool {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return false }
    for name in entries {
      let child = directory.appendingPathComponent(name)
      guard let attributes = try? fileManager.attributesOfItem(atPath: child.path) else { return false }
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory: if !holdsNoData(child) { return false }
      case .typeRegular: if (attributes[.size] as? NSNumber)?.intValue != 0 { return false }
      default: return false
      }
    }
    return true
  }

  /// A directory, not a symbolic link to one: a link would move the link and leave the data.
  private static func isRealDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
      == .typeDirectory
  }

  /// Anything at the path, a dangling symbolic link included.
  private static func existsAtAll(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }

  /// True for a URL whose host is exactly `localhost`, `127.0.0.1` or `::1`.
  static func pointsAtThisMac(_ link: String) -> Bool {
    guard let host = URL(string: link)?.host?.lowercased() else { return false }
    return ["localhost", "127.0.0.1", "::1"].contains(host)
  }

  // MARK: - The owner's secrets

  /// What `copySecret` did with one reference.
  public enum SecretCopy: Equatable, Sendable {
    /// Read from the legacy store, written to the new one, and read back.
    case copied
    /// The new store already holds it; it was left as it is.
    case alreadyThere
    /// Neither store holds it (the secret was removed, or never stored); not an error.
    case missing
  }

  /// Copy the secret `ref` from the legacy store (the prod keychain group) to `store` when `store`
  /// lacks it, and check `store` returns it. The legacy item is never changed or removed, so going back
  /// to the prod build keeps working. A failed write or check throws. The value is never put in an
  /// error or a log line.
  @discardableResult
  public static func copySecret(
    _ ref: SecretRef, from legacy: any SecretStore, to store: any SecretStore
  ) async throws -> SecretCopy {
    if try await store.read(ref) != nil { return .alreadyThere }
    guard let value = try await legacy.read(ref) else { return .missing }
    try await store.put(ref, value: value)
    guard try await store.read(ref) == value else {
      throw WorkspaceError(
        .internalError,
        "The secret store did not return \(ref) after it was written; the prod keychain group's item was kept."
      )
    }
    return .copied
  }

  /// The setting, in the adopted database, that records the copy below has run. Settings are this
  /// Mac's own and never synced.
  public static let secretsCopiedKey = "legacySecretsCopiedAt"

  /// Every secret `database` references: its hub link's token and each connection's `secret:`
  /// `authReference` (disabled connections included), each once, in that order.
  static func secretRefs(in database: WorkspaceDatabase) throws -> [SecretRef] {
    var refs: [SecretRef] = []
    if let ref = try database.hubLink().flatMap({ SecretRef(rawValue: $0.tokenRef) }) { refs.append(ref) }
    for connection in try database.listConnections(includeDisabled: true) {
      if let ref = connection.authReference.flatMap(SecretRef.init(rawValue:)), !refs.contains(ref) {
        refs.append(ref)
      }
    }
    return refs
  }

  /// The counts of one run of `copySecretsOnce`.
  public struct SecretCopySummary: Equatable, Sendable {
    public var copied = 0
    public var alreadyThere = 0
    public var missing = 0
  }

  /// D-063's one read of the owner's secrets: copy every secret the adopted `database` references from
  /// the legacy store to `store` (`copySecret`), then record it in the database's settings so no later
  /// start reads the legacy store again. Nil when an earlier start has done it. A throw records
  /// nothing, so the next start tries again; the references already copied are then `alreadyThere`.
  static func copySecretsOnce(
    database: WorkspaceDatabase, from legacy: any SecretStore, to store: any SecretStore
  ) async throws -> SecretCopySummary? {
    guard try database.settings(key: secretsCopiedKey) == nil else { return nil }
    var summary = SecretCopySummary()
    for ref in try secretRefs(in: database) {
      switch try await copySecret(ref, from: legacy, to: store) {
      case .copied: summary.copied += 1
      case .alreadyThere: summary.alreadyThere += 1
      case .missing: summary.missing += 1
      }
    }
    try database.setSetting(key: secretsCopiedKey, value: .string(Timestamp.now()))
    return summary
  }

  /// The prod flavour's keychain group (`<team>.com.cacheplane.b4app.shared`), when this process's
  /// signature claims it: the local flavour's profiles authorise `<team>.*`, and `package.sh` claims
  /// the prod group beside the local one for this read. Nil without it (an ad hoc build, which keeps
  /// its secrets in the login keychain the prod build's would have used, so there is nothing to copy).
  public static func legacySecretStore() -> (any SecretStore)? {
    legacySecretStore(claimedGroups: claimedAccessGroups())
  }

  /// The same, from the groups a signature claims.
  static func legacySecretStore(claimedGroups: [String]) -> (any SecretStore)? {
    guard
      let group = KeychainSecretStore.selectGroup(
        from: claimedGroups, flavorSuffix: Flavor.prod.keychainGroupSuffix)
    else { return nil }
    return KeychainSecretStore(accessGroup: group)
  }

  private static func claimedAccessGroups() -> [String] {
    #if os(macOS)
      return KeychainSecretStore.claimedAccessGroups()
    #else
      return []
    #endif
  }

  // MARK: - Stopping the old install

  public enum BootOutDecision: Equatable, Sendable {
    /// The job is not loaded; there is nothing to boot out.
    case skip
    case bootOut
    case refuse(String)
  }

  /// D-052's identity rule for the old agent: boot a loaded job out only when its plist names a
  /// program that is not this process's own binary. A job that runs this binary would take us down
  /// with it, and one whose program cannot be established is not ours to stop.
  static func bootOutDecision(loaded: Bool, plistProgram: String?, ownProgram: String) -> BootOutDecision {
    guard loaded else { return .skip }
    guard let plistProgram else {
      return .refuse(
        "The LaunchAgent \(legacyLabel) is loaded but its plist is missing, so its program cannot be checked. Nothing was stopped or moved."
      )
    }
    if samePath(plistProgram, ownProgram) {
      return .refuse(
        "The LaunchAgent \(legacyLabel) runs this coordinator (\(ownProgram)). Nothing was stopped or moved; quit it and start the local build again."
      )
    }
    return .bootOut
  }

  /// The program the pre-flavour LaunchAgent's plist names, if the plist exists.
  static func legacyProgramPath(home: URL) -> String? {
    let plist = home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    guard let data = try? Data(contentsOf: plist),
      let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let arguments = (object as? [String: Any])?["ProgramArguments"] as? [String]
    else { return nil }
    return arguments.first
  }

  private static func samePath(_ a: String, _ b: String) -> Bool {
    URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
      == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
  }

  // MARK: - Production wiring

  /// What `Coordinator.start` needs to adopt: where the home is, the two closures `moveDataIfNeeded`
  /// takes, and the store the owner's secrets are copied from. Tests build one from fakes;
  /// `Production.plan` is the real one.
  public struct Plan: Sendable {
    public var home: URL
    public var readHubURL: @Sendable (URL) async throws -> String?
    public var bootOutLegacy: @Sendable () async throws -> Void
    /// The prod keychain group, read once for the secrets the adopted `workspace` database references
    /// (`copySecretsOnce`, run by `AccountManager` before the adopted account's first hub call). Nil
    /// reads nothing.
    public var legacySecretStore: (any SecretStore)?

    public init(
      home: URL, readHubURL: @escaping @Sendable (URL) async throws -> String?,
      bootOutLegacy: @escaping @Sendable () async throws -> Void, legacySecretStore: (any SecretStore)? = nil
    ) {
      self.home = home
      self.readHubURL = readHubURL
      self.bootOutLegacy = bootOutLegacy
      self.legacySecretStore = legacySecretStore
    }
  }

  /// The gate: a plan for the real Mac only when the local flavour was chosen explicitly
  /// (`B4APP_FLAVOR=local`, or `B4AppFlavor` in the enclosing app's Info.plist; never the fallback a
  /// binary outside any bundle gets, so `swift run b4app-coordinator` adopts nothing) and no data
  /// directory or cluster was named (an explicit one means a test or an experiment).
  public static func planIfExplicitLocal(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    resolution: Flavor.Resolution = Flavor.currentResolution
  ) -> Plan? {
    guard resolution.flavor == .local, resolution.source != .default,
      environment["B4APP_DATA_DIR"] == nil, environment["B4APP_POSTGRES_SOCKET_DIR"] == nil
    else { return nil }
    return Production(environment: environment).plan
  }

  /// The two closures `moveDataIfNeeded` takes, for the real Mac: they start and stop the old
  /// install's PostgreSQL cluster through `PostgresServer` (which checks that the postmaster is a
  /// `postgres` serving that directory, D-025) and its LaunchAgent through `launchctl`. Tests do not
  /// use this; they drive `moveDataIfNeeded` with closures of their own.
  public struct Production: Sendable {
    public var home: URL
    public var environment: [String: String]
    public var ownProgram: String

    public init(
      home: URL = FileManager.default.homeDirectoryForCurrentUser,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      ownProgram: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    ) {
      self.home = home
      self.environment = environment
      self.ownProgram = ownProgram
    }

    /// Where the pre-flavour coordinator kept its socket and lock: `$TMPDIR/b4app`.
    var legacyRuntimeDir: String {
      let tmp = environment["TMPDIR"] ?? NSTemporaryDirectory()
      return (tmp as NSString).appendingPathComponent(PlatformPaths.directoryName(for: .prod))
    }

    var plan: Plan {
      Plan(
        home: home, readHubURL: { try await readHubURL($0) }, bootOutLegacy: { try await bootOutLegacy() },
        legacySecretStore: LegacyAdoption.legacySecretStore())
    }

    private func cluster(legacyDirectory: URL) throws -> PostgresCluster {
      guard let binDir = PostgresLocator.binDir(environment: environment) else {
        throw WorkspaceError(
          .missingExecutable,
          "PostgreSQL binaries not found, so the previous install's data cannot be inspected. Nothing was moved."
        )
      }
      return PostgresCluster(
        binDir: binDir, dataDir: legacyDirectory.appendingPathComponent("pg").path,
        socketDir: legacyRuntimeDir,
        logPath: legacyDirectory.appendingPathComponent("logs/postgres.log").path)
    }

    private func legacyDirectory() -> URL {
      home.appendingPathComponent("Library/Application Support/b4app", isDirectory: true)
    }

    /// The legacy hub link's URL. A cluster that is running (the old coordinator's) is read where it
    /// is and left running; one that is stopped is started for the read and stopped again.
    public func readHubURL(_ directory: URL) async throws -> String? {
      guard
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("pg/PG_VERSION").path)
      else { return nil }
      let cluster = try cluster(legacyDirectory: directory)
      let server = PostgresServer(cluster: cluster)
      var startedHere = false
      if case .running = try await server.status() {
      } else {
        try await server.start()
        startedHere = true
      }
      let endpoint = PostgresEndpoint(
        socketDir: cluster.socketDir, port: cluster.port, database: "workspace", dataDir: cluster.dataDir,
        logPath: cluster.logPath, binDir: cluster.binDir)
      let url: String?
      do {
        url = try WorkspaceDatabase.linkedHubURL(endpoint: endpoint, binDir: cluster.binDir)
      } catch {
        if startedHere { try? await server.stop() }
        throw error
      }
      if startedHere { try await server.stop() }
      return url
    }

    /// Boot the old LaunchAgent out, check that no coordinator of the old install is left, and stop
    /// its cluster. Throws, leaving the directory as it is, if any of that cannot be shown to be
    /// done.
    public func bootOutLegacy() async throws {
      let cluster = try cluster(legacyDirectory: legacyDirectory())
      let domainTarget = "gui/\(getuid())/\(LegacyAdoption.legacyLabel)"
      let loaded =
        (try? await CommandRunner.run(
          "/bin/launchctl", ["print", domainTarget], options: CommandOptions(timeout: .seconds(5))))?
        .exitCode == 0
      switch LegacyAdoption.bootOutDecision(
        loaded: loaded, plistProgram: LegacyAdoption.legacyProgramPath(home: home), ownProgram: ownProgram)
      {
      case .skip: break
      case .refuse(let message): throw WorkspaceError(.ownedProcessConflict, message)
      case .bootOut:
        let result = try await CommandRunner.run(
          "/bin/launchctl", ["bootout", domainTarget], options: CommandOptions(timeout: .seconds(90)))
        guard result.exitCode == 0 else {
          throw WorkspaceError(
            .endpointUnavailable,
            "launchctl bootout \(LegacyAdoption.legacyLabel) failed (\(result.exitCode ?? -1)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)). Nothing was moved."
          )
        }
      }
      // A coordinator that is still alive (started by the old app or the CLI, not by launchd, or slow
      // to exit) owns the cluster; this never signals it.
      let lockPath = (legacyRuntimeDir as NSString).appendingPathComponent("coordinator.lock")
      var holder = SingletonLock.peek(path: lockPath)
      for _ in 0..<20 where holder != nil {
        try await Task.sleep(for: .milliseconds(250))
        holder = SingletonLock.peek(path: lockPath)
      }
      if let holder {
        throw WorkspaceError(
          .ownedProcessConflict,
          "The previous install's coordinator (pid \(holder.pid)) is still running. Quit it and start the local build again. Nothing was stopped or moved."
        )
      }
      let server = PostgresServer(cluster: cluster)
      try await server.stop()
      switch try await server.status() {
      case .stopped, .uninitialized: break
      case .running(let pid):
        throw WorkspaceError(
          .ownedProcessConflict,
          "The previous install's PostgreSQL (pid \(pid)) is still running. Nothing was moved.")
      }
    }
  }
}
