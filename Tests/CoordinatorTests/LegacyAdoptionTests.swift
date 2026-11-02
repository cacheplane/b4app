import Foundation
import Testing
import WorkspacePlatform
import WorkspaceProtocol

@testable import Coordinator

/// Counts calls from closures that run on any thread.
private final class Calls: @unchecked Sendable {
  private let lock = NSLock()
  private var _read: [URL] = []
  private var _bootOuts = 0
  var reads: [URL] { lock.withLock { _read } }
  var bootOuts: Int { lock.withLock { _bootOuts } }
  func read(_ url: URL) { lock.withLock { _read.append(url) } }
  func bootOut() { lock.withLock { _bootOuts += 1 } }
}

private struct Failure: Error {}

/// A temporary home holding the pre-flavour data directory; never the real `~/Library`.
private struct TemporaryHome {
  let home: URL
  var support: URL { home.appendingPathComponent("Library/Application Support") }
  var legacy: URL { support.appendingPathComponent("b4app") }
  var local: URL { support.appendingPathComponent("b4app-local") }

  init(legacy: Bool = true, local: Bool = false) throws {
    home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "b4app-adopt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    if legacy {
      try FileManager.default.createDirectory(
        at: self.legacy.appendingPathComponent("pg"), withIntermediateDirectories: true)
      try Data("marker".utf8).write(to: self.legacy.appendingPathComponent("pg/PG_VERSION"))
    }
    if local { try FileManager.default.createDirectory(at: self.local, withIntermediateDirectories: true) }
  }

  func remove() { try? FileManager.default.removeItem(at: home) }
  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
  func putCluster(in directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("pg"), withIntermediateDirectories: true)
    try Data("17".utf8).write(to: directory.appendingPathComponent("pg/PG_VERSION"))
  }
  /// Directories set aside next to `b4app-local` by an adoption.
  var asides: [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
    return names.filter { $0.hasPrefix("b4app-local.") }.map { support.appendingPathComponent($0) }
  }
}

@Suite struct LegacyAdoptionTests {
  private func run(
    _ fixture: TemporaryHome, flavor: Flavor = .local, link: String? = "http://localhost:8080",
    readFails: Bool = false, bootOutFails: Bool = false, calls: Calls = Calls()
  ) async throws -> (moved: Bool, calls: Calls) {
    let moved = try await LegacyAdoption.moveDataIfNeeded(
      flavor: flavor, home: fixture.home,
      readHubURL: { directory in
        calls.read(directory)
        if readFails { throw Failure() }
        return link
      },
      bootOutLegacy: {
        calls.bootOut()
        if bootOutFails { throw Failure() }
      })
    return (moved, calls)
  }

  @Test func movesLocalhostLinkedDataForLocal() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let result = try await run(fixture)
    #expect(result.moved)
    #expect(fixture.exists(fixture.local))
    #expect(!fixture.exists(fixture.legacy))
    #expect(fixture.exists(fixture.local.appendingPathComponent("pg/PG_VERSION")))
    #expect(result.calls.bootOuts == 1)
    #expect(result.calls.reads.map(\.lastPathComponent) == ["b4app"])
  }

  @Test(arguments: ["http://127.0.0.1:8080", "http://[::1]:8080/", "http://LOCALHOST:9000"])
  func movesAnyLoopbackLink(url: String) async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let result = try await run(fixture, link: url)
    #expect(result.moved)
    #expect(fixture.exists(fixture.local))
  }

  @Test(arguments: [Flavor.prod, .beta])
  func leavesDataForOtherFlavours(flavor: Flavor) async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let result = try await run(fixture, flavor: flavor)
    #expect(!result.moved)
    #expect(fixture.exists(fixture.legacy))
    #expect(!fixture.exists(fixture.local))
    #expect(result.calls.bootOuts == 0)
    #expect(result.calls.reads.isEmpty)
  }

  @Test func leavesDataWhenTargetHoldsACluster() async throws {
    let fixture = try TemporaryHome(local: true)
    defer { fixture.remove() }
    try fixture.putCluster(in: fixture.local)
    let result = try await run(fixture)
    #expect(!result.moved)
    #expect(fixture.exists(fixture.legacy))
    #expect(result.calls.bootOuts == 0)
    #expect(result.calls.reads.isEmpty)
  }

  @Test func anEmptyTargetDoesNotBlockTheMove() async throws {
    let fixture = try TemporaryHome(local: true)
    defer { fixture.remove() }
    let result = try await run(fixture)
    #expect(result.moved)
    #expect(!fixture.exists(fixture.legacy))
    #expect(fixture.exists(fixture.local.appendingPathComponent("pg/PG_VERSION")))
    #expect(fixture.asides.isEmpty)
  }

  @Test func aTargetWithOnlyEmptyLogsDoesNotBlockTheMoveAndLeavesNothingBehind() async throws {
    // What the CLI launcher or an early Coordinator.start leaves: logs/ and a zero-byte log file.
    let fixture = try TemporaryHome(local: true)
    defer { fixture.remove() }
    let logs = fixture.local.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: logs.appendingPathComponent("coordinator.stdout.log").path, contents: nil)
    let result = try await run(fixture)
    #expect(result.moved)
    #expect(!fixture.exists(fixture.legacy))
    #expect(fixture.exists(fixture.local.appendingPathComponent("pg/PG_VERSION")))
    #expect(!fixture.exists(fixture.local.appendingPathComponent("logs/coordinator.stdout.log")))
    #expect(fixture.asides.isEmpty)
  }

  @Test func aTargetHoldingDataIsSetAsideNotDeleted() async throws {
    let fixture = try TemporaryHome(local: true)
    defer { fixture.remove() }
    let logs = fixture.local.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try Data("a line of output".utf8).write(to: logs.appendingPathComponent("coordinator.stdout.log"))
    let result = try await run(fixture)
    #expect(result.moved)
    #expect(fixture.exists(fixture.local.appendingPathComponent("pg/PG_VERSION")))
    let aside = try #require(fixture.asides.first)
    #expect(fixture.asides.count == 1)
    #expect(
      try String(contentsOf: aside.appendingPathComponent("logs/coordinator.stdout.log"), encoding: .utf8)
        == "a line of output")
  }

  @Test func aFailedMoveRestoresTheSetAsideTarget() async throws {
    let fixture = try TemporaryHome(local: true)
    defer { fixture.remove() }
    try Data("keep me".utf8).write(to: fixture.local.appendingPathComponent("notes.txt"))
    // The boot-out succeeds and then the legacy directory is gone, so the rename fails.
    await #expect(throws: (any Error).self) {
      _ = try await LegacyAdoption.moveDataIfNeeded(
        flavor: .local, home: fixture.home, readHubURL: { _ in "http://localhost:8080" },
        bootOutLegacy: { try FileManager.default.removeItem(at: fixture.legacy) })
    }
    #expect(
      try String(contentsOf: fixture.local.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep me")
    #expect(fixture.asides.isEmpty)
  }

  @Test func aTargetThatIsAFileIsNeverReplaced() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    try Data("x".utf8).write(to: fixture.local)
    let result = try await run(fixture)
    #expect(!result.moved)
    #expect(fixture.exists(fixture.legacy))
    #expect(result.calls.bootOuts == 0)
  }

  @Test func leavesDataWhenTargetIsADanglingSymlink() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    try FileManager.default.createSymbolicLink(
      at: fixture.local, withDestinationURL: fixture.home.appendingPathComponent("nowhere"))
    let result = try await run(fixture)
    #expect(!result.moved)
    #expect(fixture.exists(fixture.legacy))
    #expect(result.calls.bootOuts == 0)
  }

  @Test func leavesNonLocalhostLink() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    for link in ["https://hub.b4.run", "http://localhost.evil.example:8080", "not a url", ""] {
      let result = try await run(fixture, link: link)
      #expect(!result.moved)
      #expect(fixture.exists(fixture.legacy))
      #expect(!fixture.exists(fixture.local))
      #expect(result.calls.bootOuts == 0)
    }
  }

  @Test func leavesDataWithoutALink() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let result = try await run(fixture, link: nil)
    #expect(!result.moved)
    #expect(fixture.exists(fixture.legacy))
    #expect(result.calls.bootOuts == 0)
  }

  @Test func leavesDataWithoutALegacyDirectory() async throws {
    let fixture = try TemporaryHome(legacy: false)
    defer { fixture.remove() }
    let result = try await run(fixture)
    #expect(!result.moved)
    #expect(!fixture.exists(fixture.local))
    #expect(result.calls.reads.isEmpty)
    #expect(result.calls.bootOuts == 0)
  }

  @Test func aFailedReadMovesNothingAndPropagates() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let calls = Calls()
    await #expect(throws: Failure.self) { _ = try await run(fixture, readFails: true, calls: calls) }
    #expect(fixture.exists(fixture.legacy))
    #expect(!fixture.exists(fixture.local))
    #expect(calls.bootOuts == 0)
  }

  @Test func aFailedBootOutMovesNothingAndPropagates() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let calls = Calls()
    await #expect(throws: Failure.self) { _ = try await run(fixture, bootOutFails: true, calls: calls) }
    #expect(fixture.exists(fixture.legacy))
    #expect(fixture.exists(fixture.legacy.appendingPathComponent("pg/PG_VERSION")))
    #expect(!fixture.exists(fixture.local))
    #expect(calls.bootOuts == 1)
  }

  @Test func movingTwiceMovesOnce() async throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let first = try await run(fixture)
    let second = try await run(fixture)
    #expect(first.moved)
    #expect(!second.moved)
    #expect(second.calls.bootOuts == 0)
  }

  // MARK: - The hub token

  private let ref = SecretRef(rawValue: "secret:hub-token")!

  @Test func movesTokenOnce() async throws {
    let legacy = MemorySecretStore()
    let store = MemorySecretStore()
    try await legacy.put(ref, value: "tok-very-secret")
    try await LegacyAdoption.moveToken(from: legacy, to: store, ref: ref)
    #expect(try await store.read(ref) == "tok-very-secret")
    #expect(try await legacy.read(ref) == nil)
    // A second run finds nothing to move and leaves the new store alone.
    try await LegacyAdoption.moveToken(from: legacy, to: store, ref: ref)
    #expect(try await store.read(ref) == "tok-very-secret")
  }

  @Test func tokenMoveIsANoOpWithoutALegacyItem() async throws {
    let legacy = MemorySecretStore()
    let store = MemorySecretStore()
    try await store.put(ref, value: "already-here")
    try await LegacyAdoption.moveToken(from: legacy, to: store, ref: ref)
    #expect(try await store.read(ref) == "already-here")
  }

  @Test func aFailedCopyKeepsTheLegacyToken() async throws {
    let legacy = MemorySecretStore()
    try await legacy.put(ref, value: "tok-very-secret")
    await #expect(throws: Failure.self) {
      try await LegacyAdoption.moveToken(from: legacy, to: RefusingSecretStore(), ref: ref)
    }
    #expect(try await legacy.read(ref) == "tok-very-secret")
  }

  @Test func aCopyThatDoesNotReadBackKeepsTheLegacyToken() async throws {
    let legacy = MemorySecretStore()
    try await legacy.put(ref, value: "tok-very-secret")
    await #expect(throws: WorkspaceError.self) {
      try await LegacyAdoption.moveToken(from: legacy, to: ForgetfulSecretStore(), ref: ref)
    }
    #expect(try await legacy.read(ref) == "tok-very-secret")
  }

  @Test func tokenErrorsNeverCarryTheValue() async throws {
    let legacy = MemorySecretStore()
    try await legacy.put(ref, value: "tok-very-secret")
    do {
      try await LegacyAdoption.moveToken(from: legacy, to: ForgetfulSecretStore(), ref: ref)
      Issue.record("expected a throw")
    } catch {
      #expect(!"\(error)".contains("tok-very-secret"))
    }
  }

  // MARK: - The boot-out decision (D-052's identity rule)

  @Test func bootOutDecisionFollowsTheProgramPath() {
    let own = "/Applications/B4 Local.app/Contents/Helpers/b4app-coordinator"
    let old = "/Applications/Agent Workspace.app/Contents/Helpers/b4app-coordinator"
    // Not loaded: nothing to boot out, whatever the plist says.
    #expect(LegacyAdoption.bootOutDecision(loaded: false, plistProgram: old, ownProgram: own) == .skip)
    #expect(LegacyAdoption.bootOutDecision(loaded: false, plistProgram: nil, ownProgram: own) == .skip)
    // Loaded, and its program is a different file: boot it out.
    #expect(LegacyAdoption.bootOutDecision(loaded: true, plistProgram: old, ownProgram: own) == .bootOut)
    // Loaded and it is this very binary, or its program cannot be established: refuse.
    guard case .refuse = LegacyAdoption.bootOutDecision(loaded: true, plistProgram: own, ownProgram: own)
    else {
      Issue.record("expected a refusal for this install's own program")
      return
    }
    guard case .refuse = LegacyAdoption.bootOutDecision(loaded: true, plistProgram: nil, ownProgram: own)
    else {
      Issue.record("expected a refusal for an unknown program")
      return
    }
  }

  @Test func theLegacyPlistIsReadFromTheLegacyLabel() throws {
    let fixture = try TemporaryHome()
    defer { fixture.remove() }
    let agents = fixture.home.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let plist: [String: Any] = [
      "Label": "com.cacheplane.b4app.coordinator", "ProgramArguments": ["/old/b4app-coordinator"],
    ]
    try (plist as NSDictionary).write(
      to: agents.appendingPathComponent("com.cacheplane.b4app.coordinator.plist"))
    #expect(LegacyAdoption.legacyProgramPath(home: fixture.home) == "/old/b4app-coordinator")
    #expect(LegacyAdoption.legacyLabel == "com.cacheplane.b4app.coordinator")
    #expect(LegacyAdoption.legacyProgramPath(home: fixture.home.appendingPathComponent("elsewhere")) == nil)
  }
}

private struct RefusingSecretStore: SecretStore {
  func put(_ ref: SecretRef, value: String) async throws { throw Failure() }
  func read(_ ref: SecretRef) async throws -> String? { nil }
  func remove(_ ref: SecretRef) async throws -> Bool { false }
}

/// Accepts a write and then reads back nothing, as a store that silently dropped it would.
private struct ForgetfulSecretStore: SecretStore {
  func put(_ ref: SecretRef, value: String) async throws {}
  func read(_ ref: SecretRef) async throws -> String? { nil }
  func remove(_ ref: SecretRef) async throws -> Bool { false }
}

@Suite struct LegacyAdoptionGateTests {
  private func plan(
    flavor: Flavor = .local, source: Flavor.Source = .environment, environment: [String: String] = [:]
  ) -> LegacyAdoption.Plan? {
    LegacyAdoption.planIfExplicitLocal(
      environment: environment, resolution: Flavor.Resolution(flavor: flavor, source: source))
  }

  @Test func onlyAnExplicitLocalFlavourAdopts() {
    #expect(plan(source: .environment) != nil)
    #expect(plan(source: .bundle) != nil)
    // The fallback default is what any binary outside an app bundle resolves to.
    #expect(plan(source: .default) == nil)
    #expect(plan(flavor: .prod, source: .bundle) == nil)
    #expect(plan(flavor: .beta, source: .environment) == nil)
  }

  @Test func anExplicitDataDirectoryOrClusterNeverAdopts() {
    #expect(plan(environment: ["B4APP_DATA_DIR": "/tmp/x"]) == nil)
    #expect(plan(environment: ["B4APP_POSTGRES_SOCKET_DIR": "/tmp/x"]) == nil)
  }
}
