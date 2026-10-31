import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspacePlatform

/// The fetched binaries (`Scripts/fetch-postgres.sh`) under the repository's `.build/postgres`.
let fetchedPostgresBin =
  URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent(".build/postgres/bin").path

func testCluster(_ name: String) -> PostgresCluster {
  let short = String(UUID().uuidString.prefix(6))
  let tmp = (ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
  let base = NSTemporaryDirectory() + "b4pg-\(name)-\(short)"
  return PostgresCluster(
    binDir: fetchedPostgresBin, dataDir: base + "/data",
    socketDir: (tmp as NSString).appendingPathComponent("b4pg-\(short)"),
    logPath: base + "/postgres.log")
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

  @Test func recoversFromAStalePidFile() async throws {
    let server = PostgresServer(cluster: testCluster("stale"))
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
