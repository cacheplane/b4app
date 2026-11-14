import Foundation
import Synchronization
import WorkspacePlatform
import WorkspaceProtocol

/// One private cluster per test process, started on first use from the fetched binaries and stopped
/// at exit; every caller gets its own fresh database. Production code never calls this.
///
/// Every caller waits on the start, and the callers are synchronous tests on Swift's cooperative
/// threads, one per core: while the cluster starts, as many waiting tests as the machine has cores
/// stop every other test in the process, timers included. On CI no test finished in the first 50 to
/// 70 s, and tests that wait on a clock timed out. So the start should be done before the tests run: with
/// `B4APP_TEST_POSTGRES_DIR` set, the cluster lives in that directory and outlives the process, and a
/// later process that finds it running uses it at once (CI starts it with one test before the run).
public enum EphemeralPostgres {
  private static let state = Mutex<Shared?>(nil)
  /// Suites run in parallel; the one-time initdb and start happen under this lock.
  private static let startLock = NSLock()
  /// A directory for a cluster that outlives the test process (see above). It is never swept, and
  /// stopped only by hand: `pg_ctl -D "$B4APP_TEST_POSTGRES_DIR/data" stop`.
  public static let persistentVariable = "B4APP_TEST_POSTGRES_DIR"

  struct Shared {
    var cluster: PostgresCluster
  }

  /// A `PlatformPaths` for `base` whose store is a fresh database on the shared cluster.
  public static func paths(runtimeDir: String, dataDir: String) throws -> PlatformPaths {
    var paths = PlatformPaths(runtimeDir: runtimeDir, dataDir: dataDir)
    paths.postgres = try endpoint()
    return paths
  }

  /// A fresh database on the shared cluster.
  public static func endpoint() throws -> PostgresEndpoint {
    let shared = try ensureStarted()
    let name = "t_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
    let lib = try LibPQ.load(binDir: shared.cluster.binDir)
    let admin = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(shared.cluster.socketDir) port=\(shared.cluster.port) dbname=postgres user=\(shared.cluster.user)"
    )
    try admin.execute("CREATE DATABASE \(Rows.quote(String(name)))")
    return PostgresEndpoint(
      socketDir: shared.cluster.socketDir, port: shared.cluster.port, database: String(name), dataDir: nil,
      logPath: shared.cluster.logPath, binDir: shared.cluster.binDir)
  }

  private static func ensureStarted() throws -> Shared {
    startLock.lock()
    defer { startLock.unlock() }
    if let existing = state.withLock({ $0 }) { return existing }
    guard let binDir = PostgresLocator.binDir(anchors: [StorageResources.bundle.bundleURL]) else {
      throw WorkspaceError(
        .missingExecutable,
        "No PostgreSQL binaries: run ./Scripts/fetch-postgres.sh (or set \(PostgresLocator.environmentVariable))."
      )
    }
    let began = ContinuousClock.now
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let short = String(ownPid)
    let environment = ProcessInfo.processInfo.environment
    let tmp = environment["TMPDIR"] ?? NSTemporaryDirectory()
    // What earlier runs left behind is removed beside the start, not before it: every test that needs
    // the cluster waits for this lock, and a sweep of a few old clusters took longer than the start.
    Thread.detachNewThread { sweepStale(in: [NSTemporaryDirectory(), tmp], ownPid: ownPid) }
    if let directory = environment[persistentVariable], !directory.isEmpty {
      let cluster = PostgresCluster(
        binDir: binDir, dataDir: (directory as NSString).appendingPathComponent("data"),
        socketDir: directory, logPath: (directory as NSString).appendingPathComponent("postgres.log"),
        maxConnections: 300)
      // The socket is made in the directory, and a Unix socket path is limited to 104 bytes.
      guard cluster.socketPath.utf8.count < 104 else {
        throw WorkspaceError(
          .internalError, "\(persistentVariable) is too long for a socket in it; use a shorter directory.")
      }
      let running = postmasterPid(dataDir: cluster.dataDir).map { ProcessInspector.isAlive(pid: $0) } ?? false
      if !running {
        try PrivateFiles.ensurePrivateDirectory(cluster.socketDir)
        if !cluster.isInitialized { try initdb(cluster) }
        try start(cluster)
      }
      report(running ? "in use" : "started", in: directory, since: began)
      let shared = Shared(cluster: cluster)
      state.withLock { $0 = shared }
      return shared
    }
    let cluster = PostgresCluster(
      binDir: binDir, dataDir: NSTemporaryDirectory() + "b4pg-shared-\(short)/data",
      socketDir: (tmp as NSString).appendingPathComponent("b4pgs-\(short)"),
      logPath: NSTemporaryDirectory() + "b4pg-shared-\(short)/postgres.log", maxConnections: 300)
    try initdb(cluster)
    try PrivateFiles.ensurePrivateDirectory(cluster.socketDir)
    try start(cluster)
    report("started", in: cluster.socketDir, since: began)
    atexit {
      // Best effort: stop the shared cluster and remove it when the test process exits. A run that
      // is killed skips this; the next run's sweep removes what it left.
      if let shared = EphemeralPostgres.state.withLock({ $0 }) {
        try? EphemeralPostgres.run(
          shared.cluster, "pg_ctl", ["-D", shared.cluster.dataDir, "-m", "immediate", "stop"])
        let fm = FileManager.default
        try? fm.removeItem(atPath: (shared.cluster.dataDir as NSString).deletingLastPathComponent)
        try? fm.removeItem(atPath: shared.cluster.socketDir)
      }
    }
    let shared = Shared(cluster: cluster)
    state.withLock { $0 = shared }
    return shared
  }

  private static func initdb(_ cluster: PostgresCluster) throws {
    try run(
      cluster, "initdb",
      [
        "-D", cluster.dataDir, "-U", cluster.user, "--auth=trust", "--encoding=UTF8", "--locale=C",
        "--no-instructions",
      ])
  }

  private static func start(_ cluster: PostgresCluster) throws {
    try run(
      cluster, "pg_ctl",
      [
        "-D", cluster.dataDir, "-l", cluster.logPath, "-w", "-t", "60", "-o",
        cluster.serverOptions.joined(separator: " "), "start",
      ])
  }

  /// One line on stderr, so a slow start shows in a CI log: every test that needs the cluster, and
  /// on a small machine every other test too, waited this long.
  private static func report(_ what: String, in directory: String, since began: ContinuousClock.Instant) {
    let elapsed = (ContinuousClock.now - began).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    let line = "EphemeralPostgres: the shared cluster in \(directory) is \(what) after "
    FileHandle.standardError.write(Data((line + String(format: "%.1f s\n", seconds)).utf8))
  }

  /// Who owns a test scratch entry in the temporary directory, from its name.
  enum ScratchOwner: Equatable {
    /// The test process with this pid.
    case process(Int32)
    /// A name from before owners were recorded (`PostgresServerTests`' `b4pg-<name>-<hex>` and
    /// `b4pg-<hex>`).
    case unknown
  }

  /// `b4pg-shared-<pid>` (this cluster's data and log), `b4pgs-<pid>` (its socket), and
  /// `b4pg-<pid>-…` (`PostgresServerTests`) name the test process that made them. Nil for anything
  /// else, which the sweep never touches.
  static func scratchOwner(_ name: String) -> ScratchOwner? {
    func pid(_ text: Substring) -> Int32? {
      text.isEmpty || !text.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int32(text)
    }
    if name.hasPrefix("b4pgs-") { return pid(name.dropFirst(6)).map(ScratchOwner.process) }
    guard name.hasPrefix("b4pg-") else { return nil }
    let rest = name.dropFirst(5)
    if rest.hasPrefix("shared-") { return pid(rest.dropFirst(7)).map(ScratchOwner.process) }
    if let dash = rest.firstIndex(of: "-"), let owner = pid(rest[..<dash]) { return .process(owner) }
    return .unknown
  }

  /// Remove test scratch whose owner has exited, so a killed or crashed run does not leave a cluster
  /// (about 800 MB each) behind for good. A postgres still serving one is stopped first, and only if
  /// it is a postgres for that data directory, so a recycled pid is never signalled; when it does not
  /// stop, the scratch stays. Scratch from a live process, this one included, is left alone, and an
  /// entry with no owner in its name only once it is a day old. Returns the paths removed.
  @discardableResult
  static func sweepStale(
    in directories: [String], ownPid: Int32, now: Date = Date(),
    isAlive: (Int32) -> Bool = { ProcessInspector.isAlive(pid: $0) },
    stopOrphan: (_ dataDir: String, _ pid: Int32) -> Bool = { stopOrphan(dataDir: $0, pid: $1) }
  ) -> [String] {
    let fm = FileManager.default
    var removed: [String] = []
    for directory in Set(directories.map { ($0 as NSString).standardizingPath }) {
      guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
      for name in names {
        guard let owner = scratchOwner(name) else { continue }
        let path = (directory as NSString).appendingPathComponent(name)
        switch owner {
        case .process(let pid):
          if pid == ownPid || isAlive(pid) { continue }
        case .unknown:
          guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
            now.timeIntervalSince(modified) > 86_400
          else { continue }
        }
        let dataDir = (path as NSString).appendingPathComponent("data")
        if let postmaster = postmasterPid(dataDir: dataDir), isAlive(postmaster),
          !stopOrphan(dataDir, postmaster)
        {
          continue
        }
        if (try? fm.removeItem(atPath: path)) != nil { removed.append(path) }
      }
    }
    return removed.sorted()
  }

  /// The first line of `<dataDir>/postmaster.pid`.
  static func postmasterPid(dataDir: String) -> Int32? {
    let path = (dataDir as NSString).appendingPathComponent("postmaster.pid")
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
      let first = text.split(separator: "\n").first
    else { return nil }
    return Int32(first.trimmingCharacters(in: .whitespaces))
  }

  /// Fast shutdown (SIGINT, as `pg_ctl -m fast` sends) of a postmaster an exited test left running,
  /// waiting up to 30 s. True when nothing serves `dataDir` any more: the pid has exited, or it now
  /// belongs to a process that is not a postgres for `dataDir` (the pid file is stale, and that
  /// process is not signalled).
  static func stopOrphan(dataDir: String, pid: Int32) -> Bool {
    func resolved(_ path: String) -> String {
      URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    guard let identity = ProcessInspector.identity(pid: pid) else { return true }
    let target = resolved(dataDir)
    guard identity.arguments.contains(where: { $0.hasSuffix("/postgres") || $0 == "postgres" }),
      identity.arguments.contains(where: { resolved($0) == target })
    else { return true }
    guard kill(pid, SIGINT) == 0 else { return !ProcessInspector.isAlive(pid: pid) }
    let deadline = Date().addingTimeInterval(30)
    while ProcessInspector.isAlive(pid: pid), Date() < deadline { usleep(100_000) }
    return !ProcessInspector.isAlive(pid: pid)
  }

  /// Synchronous Foundation `Process`, since this runs from synchronous test code.
  private static func run(_ cluster: PostgresCluster, _ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cluster.binDir).appendingPathComponent(tool)
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "C"
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw WorkspaceError(
        .internalError,
        "\(tool) failed (\(process.terminationStatus)): \(String(decoding: output, as: UTF8.self).suffix(400))"
      )
    }
  }
}
