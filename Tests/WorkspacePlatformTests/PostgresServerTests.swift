import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspacePlatform

/// The fetched binaries (`Scripts/fetch-postgres.sh`) under the repository's `.build/postgres`.
let fetchedPostgresBin =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent(".build/postgres/bin").path

/// Scratch named `b4pg-<pid>-…` so `EphemeralPostgres`' sweep can tell when its owner is gone.
func testCluster(_ name: String) -> PostgresCluster {
  let owner = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6))"
  let tmp = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
  let base = NSTemporaryDirectory() + "b4pg-\(owner)-\(name)"
  return PostgresCluster(
    binDir: fetchedPostgresBin, dataDir: base + "/data",
    socketDir: (tmp as NSString).appendingPathComponent("b4pg-\(owner)"),
    logPath: base + "/postgres.log")
}

/// Remove a stopped test cluster's data, log, and socket directories. One still running (a test that
/// failed before its `stop()`) is left for the sweep, which stops it first.
func removeScratch(_ cluster: PostgresCluster) {
  if let pid = PostgresServer(cluster: cluster).postmasterPid(), ProcessInspector.isAlive(pid: pid) { return }
  try? FileManager.default.removeItem(atPath: (cluster.dataDir as NSString).deletingLastPathComponent)
  try? FileManager.default.removeItem(atPath: cluster.socketDir)
}

@Suite(.serialized) struct PostgresServerTests {
  @Test func locatorFindsTheFetchedTreeAndRejectsIncompleteDirectories() {
    #expect(PostgresLocator.complete(fetchedPostgresBin))
    #expect(!PostgresLocator.complete("/usr/bin"))
    #expect(
      PostgresLocator.binDir(
        environment: [PostgresLocator.environmentVariable: fetchedPostgresBin], executableURL: nil)
        == fetchedPostgresBin)
    #expect(PostgresLocator.binDir(environment: ["HOME": "/nonexistent"], executableURL: nil) == nil)
  }

  @Test func initializesStartsAdoptsAndStops() async throws {
    let server = PostgresServer(cluster: testCluster("life"))
    defer { removeScratch(server.cluster) }
    #expect(try await server.status() == .uninitialized)
    #expect(try await server.initializeIfNeeded() == true)
    #expect(try await server.initializeIfNeeded() == false)
    #expect(try await server.status() == .stopped)
    let pid = try await server.start()
    #expect(pid > 0)
    #expect(try await server.status() == .running(pid: pid))
    #expect(FileManager.default.fileExists(atPath: server.cluster.socketPath))
    // A second start adopts the running postmaster.
    #expect(try await server.start() == pid)
    // The data directory is private and nothing listens on TCP (only -k/listen_addresses= are passed).
    let mode =
      try FileManager.default.attributesOfItem(atPath: server.cluster.dataDir)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    try await server.stop()
    #expect(try await server.status() == .stopped)
    #expect(!ProcessInspector.isAlive(pid: pid))
    try await server.stop()  // already stopped: not an error
  }

  @Test func replacesAPostmasterFromAnotherInstall() async throws {
    let cluster = testCluster("swap")
    defer { removeScratch(cluster) }
    let first = PostgresServer(cluster: cluster)
    let oldPid = try await first.start()
    #expect(first.runsThisInstall(pid: oldPid))
    // As after the app bundle is rebuilt in place: our postgres was written after that server started.
    let rebuilt = PostgresServer(cluster: cluster) { _ in Date().addingTimeInterval(60) }
    #expect(!rebuilt.runsThisInstall(pid: oldPid))
    let newPid = try await rebuilt.start()
    #expect(newPid != oldPid)
    #expect(!ProcessInspector.isAlive(pid: oldPid))
    // A server it started itself is adopted by an unchanged install.
    #expect(try await first.start() == newPid)
    try await first.stop()
  }

  @Test func aPostmasterRunningAnotherBinaryIsNotThisInstalls() async throws {
    let server = PostgresServer(cluster: testCluster("other"))
    defer { removeScratch(server.cluster) }
    let pid = try await server.start()
    var moved = server.cluster
    moved.binDir = "/nonexistent/Agent Workspace.app/Contents/SharedSupport/postgres/bin"
    #expect(!PostgresServer(cluster: moved).runsThisInstall(pid: pid))
    #expect(!server.runsThisInstall(pid: 2_147_000_000))
    try await server.stop()
  }

  @Test func recoversFromAStalePidFile() async throws {
    let server = PostgresServer(cluster: testCluster("stale"))
    defer { removeScratch(server.cluster) }
    try await server.initializeIfNeeded()
    let pidFile = (server.cluster.dataDir as NSString).appendingPathComponent("postmaster.pid")
    try "2147000000\n\(server.cluster.dataDir)\n0\n\(server.cluster.port)\n\(server.cluster.socketDir)\n\n"
      .write(
        toFile: pidFile, atomically: true, encoding: .utf8)
    let pid = try await server.start()
    #expect(pid > 0 && pid != 2_147_000_000)
    try await server.stop()
  }
}
