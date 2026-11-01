import Foundation
import Testing

@testable import WorkspaceStorage

/// The sweep that removes test clusters left by exited runs. Every case runs on fake directories under
/// a private root with injected liveness, so no real process is signalled and the real temporary
/// directory is untouched.
@Suite struct ScratchSweepTests {
  @Test func ownersComeFromTheName() {
    #expect(EphemeralPostgres.scratchOwner("b4pg-shared-4242") == .process(4242))
    #expect(EphemeralPostgres.scratchOwner("b4pgs-4242") == .process(4242))
    #expect(EphemeralPostgres.scratchOwner("b4pg-4242-1A2B3C-life") == .process(4242))
    #expect(EphemeralPostgres.scratchOwner("b4pg-4242-1A2B3C") == .process(4242))
    #expect(EphemeralPostgres.scratchOwner("b4pg-life-1A2B3C") == .unknown)
    #expect(EphemeralPostgres.scratchOwner("b4pg-123456") == .unknown)
    #expect(EphemeralPostgres.scratchOwner("b4pgs-abc") == nil)
    #expect(EphemeralPostgres.scratchOwner("b4pg-shared-abc") == nil)
    #expect(EphemeralPostgres.scratchOwner("b4app") == nil)
    #expect(EphemeralPostgres.scratchOwner("TemporaryDirectory.x") == nil)
  }

  @Test func removesOnlyScratchWhoseOwnerHasExited() throws {
    let root = NSTemporaryDirectory() + "scratch-sweep-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    func make(_ name: String, postmaster: Int32? = nil, age: TimeInterval = 0) throws {
      let data = "\(root)/\(name)/data"
      try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
      if let postmaster {
        try "\(postmaster)\n\(data)\n".write(
          toFile: "\(data)/postmaster.pid", atomically: true, encoding: .utf8)
      }
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: "\(root)/\(name)")
    }
    try make("b4pg-shared-111")  // owner exited
    try make("b4pgs-111")
    try make("b4pg-shared-222")  // owner alive
    try make("b4pg-shared-999")  // this process
    try make("b4pg-333-AAAAAA-life", postmaster: 444)  // orphan server that will not stop
    try make("b4pg-555-BBBBBB-swap", postmaster: 666)  // orphan server that stops
    try make("b4pg-777-CCCCCC-stale", postmaster: 888)  // stale pid file: 888 is not running
    try make("b4pg-life-DDDDDD", age: 2 * 86_400)  // no owner, two days old
    try make("b4pg-1A2B3C", age: 60)  // no owner, a minute old
    try make("b4app")
    try make("unrelated")

    var stopped: [Int32] = []
    let removed = EphemeralPostgres.sweepStale(
      in: [root, root + "/"], ownPid: 999,
      isAlive: { [222, 444, 666].contains($0) },
      stopOrphan: { dataDir, pid in
        #expect(dataDir.hasSuffix("/data"))
        stopped.append(pid)
        return pid == 666
      })

    #expect(
      removed.map { ($0 as NSString).lastPathComponent }
        == [
          "b4pg-555-BBBBBB-swap", "b4pg-777-CCCCCC-stale", "b4pg-life-DDDDDD", "b4pg-shared-111", "b4pgs-111",
        ])
    #expect(stopped.sorted() == [444, 666])
    let left = try FileManager.default.contentsOfDirectory(atPath: root).sorted()
    #expect(
      left == [
        "b4app", "b4pg-1A2B3C", "b4pg-333-AAAAAA-life", "b4pg-shared-222", "b4pg-shared-999", "unrelated",
      ])
  }

  @Test func aRecycledPidIsNeverSignalled() {
    // This test process is alive but is not a postgres serving that directory.
    let me = ProcessInfo.processInfo.processIdentifier
    #expect(EphemeralPostgres.stopOrphan(dataDir: "/nonexistent/b4pg-1-AAAAAA-x/data", pid: me))
    #expect(EphemeralPostgres.stopOrphan(dataDir: "/nonexistent/data", pid: 2_147_000_000))
  }
}
