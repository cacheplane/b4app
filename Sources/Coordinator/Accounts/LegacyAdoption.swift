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
/// to its own, once (D-094).
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

  /// Copy the secret `ref` from the legacy store (the prod keychain group, then the login keychain)
  /// to `store` when `store` lacks it, and check `store` returns it. Every read and write is the
  /// store's own (`readHere`, `putHere`): `store`'s ordinary read would find an item still in the login
  /// keychain and move it into this flavour's group, out of the prod build's reach, and its ordinary
  /// write would delete the login copy. So the legacy item, wherever it is, is never changed or
  /// removed, and going back to the prod build keeps working. A failed write or check throws. The
  /// value is never put in an error or a log line.
  @discardableResult
  public static func copySecret(
    _ ref: SecretRef, from legacy: any SecretStore, to store: any SecretStore
  ) async throws -> SecretCopy {
    if try await store.readHere(ref) != nil { return .alreadyThere }
    guard let value = try await legacy.readHere(ref) else { return .missing }
    try await store.putHere(ref, value: value)
    guard try await store.readHere(ref) == value else {
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

  /// The same, from the groups a signature claims: the prod group, then the login keychain (where a
  /// secret the prod build has not read since D-051 still is), each read as it is.
  static func legacySecretStore(claimedGroups: [String]) -> (any SecretStore)? {
    guard
      let group = KeychainSecretStore.selectGroup(
        from: claimedGroups, flavorSuffix: Flavor.prod.keychainGroupSuffix)
    else { return nil }
    return LegacySecrets(
      stores: [KeychainSecretStore(accessGroup: group), KeychainSecretStore(accessGroup: nil)])
  }

  /// The prod build's secrets as the copy reads them: each store's own copy (`readHere`), first found
  /// wins, nothing moved. Read-only: writing or removing throws.
  struct LegacySecrets: SecretStore {
    let stores: [any SecretStore]

    func read(_ ref: SecretRef) async throws -> String? { try await readHere(ref) }
    func readHere(_ ref: SecretRef) async throws -> String? {
      for store in stores {
        if let value = try await store.readHere(ref) { return value }
      }
      return nil
    }
    func put(_ ref: SecretRef, value: String) async throws { throw Self.readOnly }
    func putHere(_ ref: SecretRef, value: String) async throws { throw Self.readOnly }
    func remove(_ ref: SecretRef) async throws -> Bool { throw Self.readOnly }
    var backend: String { stores.map(\.backend).joined(separator: ", then ") }

    private static let readOnly = WorkspaceError(
      .internalError, "The prod build's secrets are only read here, never changed.")
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
    /// The job is not loaded, or nothing shows it is ours to stop; there is nothing to boot out.
    case skip
    case bootOut
    case refuse(String)
  }

  /// What `launchctl print` showed of the old job.
  public enum JobState: Equatable, Sendable {
    case loaded
    case notLoaded
    /// The print timed out, could not run, or answered something else: it proves nothing either way.
    /// (At the live gate a timed-out print read as "not loaded" and left the job loaded.)
    case unknown
  }

  /// launchctl's exit codes for a service it does not have: `print` answers 113 ("Could not find
  /// service"), `bootout` 3 ("No such process").
  static let serviceNotFound: Int32 = 113
  static let noSuchProcess: Int32 = 3

  static func jobState(printed result: CommandResult?) -> JobState {
    guard let result, !result.timedOut else { return .unknown }
    switch result.exitCode {
    case 0: return .loaded
    case serviceNotFound: return .notLoaded
    default: return .unknown
    }
  }

  /// D-052's identity rule for the old agent: boot a loaded job out only when its plist names a
  /// program that is not this process's own binary. A job that runs this binary would take us down
  /// with it, and one whose program cannot be established is not ours to stop. A job whose state is
  /// unknown is booted out by the same rule, but never refused: with no plist, or this binary's,
  /// there is nothing to show it is loaded, so adoption goes on as for one that is not.
  static func bootOutDecision(state: JobState, plistProgram: String?, ownProgram: String) -> BootOutDecision {
    switch state {
    case .notLoaded:
      return .skip
    case .unknown:
      guard let plistProgram, !samePath(plistProgram, ownProgram) else { return .skip }
      return .bootOut
    case .loaded:
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
  }

  /// Runs `/bin/launchctl` with these arguments and a timeout; nil when it could not be run.
  public typealias Launchctl = @Sendable (_ arguments: [String], _ timeout: Duration) async -> CommandResult?

  /// The real `launchctl`, an argument array and never a shell string.
  public static let systemLaunchctl: Launchctl = { arguments, timeout in
    try? await CommandRunner.run("/bin/launchctl", arguments, options: CommandOptions(timeout: timeout))
  }

  /// Boot the old job (`domainTarget`, `gui/<uid>/<legacy label>`) out by `bootOutDecision`: launchd
  /// stops the job's process, and nothing here signals one itself. When the job's state was unknown,
  /// launchctl's "not found" answers to the boot-out mean it was not loaded. Answers whether a job was
  /// booted out; throws on a refusal or a boot-out that failed.
  @discardableResult
  static func bootOutLegacyJob(
    home: URL, ownProgram: String, domainTarget: String, launchctl: Launchctl
  ) async throws -> Bool {
    let state = jobState(printed: await launchctl(["print", domainTarget], .seconds(15)))
    switch bootOutDecision(state: state, plistProgram: legacyProgramPath(home: home), ownProgram: ownProgram)
    {
    case .skip:
      return false
    case .refuse(let message):
      throw WorkspaceError(.ownedProcessConflict, message)
    case .bootOut:
      let result = await launchctl(["bootout", domainTarget], .seconds(90))
      if result?.succeeded == true { return true }
      if state == .unknown, let result, !result.timedOut,
        result.exitCode == noSuchProcess || result.exitCode == serviceNotFound
      {
        return false
      }
      let answer =
        result.map {
          $0.timedOut
            ? "timed out"
            : "\($0.exitCode ?? -1): \($0.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } ?? "could not run"
      throw WorkspaceError(
        .endpointUnavailable,
        "launchctl bootout \(legacyLabel) failed (\(answer)). Nothing was moved.")
    }
  }

  /// The pre-flavour LaunchAgent's plist under `home`.
  static func legacyPlist(home: URL) -> URL {
    home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
  }

  /// After a successful adoption, delete the pre-flavour LaunchAgent's plist, which the boot-out
  /// leaves: it has `RunAtLoad`, so at the next login launchd would start the old coordinator again,
  /// which would make a fresh, empty `b4app` (or respawn in a loop once the old app is gone). Only
  /// when the plist names a program that is not `ownProgram`, by D-052's identity rule
  /// (`bootOutDecision`); a plist whose program cannot be read, or that runs this binary, is kept.
  /// Answers whether it deleted the plist. A prod app opened later registers its agent again.
  @discardableResult
  static func removeLegacyPlist(home: URL, ownProgram: String) -> Bool {
    guard
      bootOutDecision(state: .loaded, plistProgram: legacyProgramPath(home: home), ownProgram: ownProgram)
        == .bootOut
    else { return false }
    return (try? FileManager.default.removeItem(at: legacyPlist(home: home))) != nil
  }

  /// The program the pre-flavour LaunchAgent's plist names, if the plist exists.
  static func legacyProgramPath(home: URL) -> String? {
    let plist = legacyPlist(home: home)
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
    /// Runs once the data directory has moved: boots the old LaunchAgent out if it is still loaded
    /// and retires its plist (`removeLegacyPlist`), so the next login does not start the old
    /// coordinator again.
    public var retireLegacyAgent: @Sendable () async -> Void

    public init(
      home: URL, readHubURL: @escaping @Sendable (URL) async throws -> String?,
      bootOutLegacy: @escaping @Sendable () async throws -> Void, legacySecretStore: (any SecretStore)? = nil,
      retireLegacyAgent: @escaping @Sendable () async -> Void = {}
    ) {
      self.home = home
      self.readHubURL = readHubURL
      self.bootOutLegacy = bootOutLegacy
      self.legacySecretStore = legacySecretStore
      self.retireLegacyAgent = retireLegacyAgent
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
    public var launchctl: Launchctl

    public init(
      home: URL = FileManager.default.homeDirectoryForCurrentUser,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      ownProgram: String = Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
      launchctl: @escaping Launchctl = LegacyAdoption.systemLaunchctl
    ) {
      self.home = home
      self.environment = environment
      self.ownProgram = ownProgram
      self.launchctl = launchctl
    }

    /// The old job in this user's GUI domain.
    var domainTarget: String { "gui/\(getuid())/\(LegacyAdoption.legacyLabel)" }

    /// Where the pre-flavour coordinator kept its socket and lock: `$TMPDIR/b4app`.
    var legacyRuntimeDir: String {
      let tmp = environment["TMPDIR"] ?? NSTemporaryDirectory()
      return (tmp as NSString).appendingPathComponent(PlatformPaths.directoryName(for: .prod))
    }

    var plan: Plan {
      Plan(
        home: home, readHubURL: { try await readHubURL($0) }, bootOutLegacy: { try await bootOutLegacy() },
        legacySecretStore: LegacyAdoption.legacySecretStore(),
        retireLegacyAgent: { await retireLegacyAgent() })
    }

    /// After the move: the job goes first (still loaded if it came back, or if the boot-out before the
    /// move could not tell), then its plist, both by D-052's rule. A boot-out that fails is logged and
    /// the plist still goes, so at worst the job stays loaded until the next login.
    func retireLegacyAgent() async {
      let logger = Log.logger("coordinator")
      do {
        if try await LegacyAdoption.bootOutLegacyJob(
          home: home, ownProgram: ownProgram, domainTarget: domainTarget, launchctl: launchctl)
        {
          logger.notice("booted out the previous install's LaunchAgent")
        }
      } catch {
        logger.warning(
          "could not boot out the previous install's LaunchAgent: \(WorkspaceError.from(error).message, privacy: .public)"
        )
      }
      if LegacyAdoption.removeLegacyPlist(home: home, ownProgram: ownProgram) {
        logger.notice("removed the previous install's LaunchAgent plist")
      }
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
      try await LegacyAdoption.bootOutLegacyJob(
        home: home, ownProgram: ownProgram, domainTarget: domainTarget, launchctl: launchctl)
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
