import Foundation
import NIOTransport
import OSLog
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

@testable import Coordinator

let pairingMacEnrollment = EnrollResponse(
  deviceId: "dev-mac", token: "tok-pairing-secret", org: OrgInfo(slug: "acme", name: "Acme"),
  user: UserInfo(username: "brian", displayName: "Brian"))
let pairingEnrollCode = "BCDF2345"

/// A wall clock tests move by hand, for `Pairing`'s expiry check.
final class WallBox: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  init(_ date: Date) { current = date }
  var date: Date { lock.withLock { current } }
  func set(_ date: Date) { lock.withLock { current = date } }
}

/// A `HubSync` over a scratch store and a `FakeHubAPI`, with a manual poll clock and fake power
/// assertions. It has not run `start()`, so there is no pull and no relay link.
struct SyncRig {
  let sync: HubSync
  let database: WorkspaceDatabase
  let fake: FakeHubAPI
  let clock: LinkTestClock
  let wall: WallBox
  let assertions: FakePowerAssertions
  let secrets: MemorySecretStore

  /// 2026-11-01T12:00:00Z
  static let noon = Date(timeIntervalSince1970: 1_793_534_400)

  static func make(joined: Bool = true) async throws -> SyncRig {
    let database = try WorkspaceDatabase.temporary()
    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(pairingEnrollCode, pairingMacEnrollment)
    let clock = LinkTestClock()
    let wall = WallBox(noon)
    let assertions = FakePowerAssertions()
    let secrets = MemorySecretStore()
    let sync = HubSync(
      database: database, secretStore: secrets, eventLog: EventLog(), makeAPI: { _, _ in fake },
      pairing: Pairing(
        pollInterval: .seconds(2), sleep: { try await clock.sleep(for: $0) }, now: { wall.date }),
      powerAssertions: assertions)
    let rig = SyncRig(
      sync: sync, database: database, fake: fake, clock: clock, wall: wall, assertions: assertions,
      secrets: secrets)
    if joined { _ = try await rig.join() }
    return rig
  }

  func join() async throws -> HubStatus.Result {
    try await sync.join(url: "http://127.0.0.1:8080", code: pairingEnrollCode, deviceName: "Test Mac")
  }

  /// A second `HubSync` over the same store, as after a coordinator restart.
  func restarted() -> HubSync {
    let fake = self.fake
    return HubSync(
      database: database, secretStore: secrets, eventLog: EventLog(), makeAPI: { _, _ in fake },
      powerAssertions: assertions)
  }
}

/// Polls until `condition` holds; fails the test after `seconds` of real time.
func waitUntilTrue(
  seconds: Double = 30, _ comment: Comment = "condition", sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @Sendable () async -> Bool
) async {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(comment)", sourceLocation: sourceLocation)
}

private func mac() -> DeviceInfo { DeviceInfo(id: "dev-mac", name: "Test Mac", platform: "macos") }

@Suite(.serialized) struct PairingTests {
  private func code(
    _ code: String = "WXYZ2345", expires: String = "2026-11-01T12:05:00.000000Z", hubURL: String? = nil
  ) -> PairingCodeResponse {
    PairingCodeResponse(code: code, expiresAt: expires, hubURL: hubURL)
  }

  @Test func pairReturnsUrlCodeAndExpiry() async throws {
    let rig = try await SyncRig.make()
    await rig.fake.setPairingCode(code(hubURL: "https://hub.example.com/"))
    let minted = try await rig.sync.pair()
    #expect(
      minted
        == HubPair.Result(
          url: "https://hub.example.com/", code: "WXYZ2345", expiresAt: "2026-11-01T12:05:00.000000Z"))

    // Without a public URL the hub leaves `hubURL` out and the Mac uses the URL it joined with.
    await rig.fake.setPairingCode(code("QRST6789"))
    let fallback = try await rig.sync.pair()
    let joinedURL = try #require(try await rig.sync.status().url)
    #expect(fallback.url == joinedURL && fallback.code == "QRST6789")
    #expect(await rig.fake.mintCalls == 2)
    await rig.sync.stop()
  }

  @Test func pairStatusIsNoneBeforeAnyPairing() async throws {
    let rig = try await SyncRig.make()
    #expect(await rig.sync.pairStatus() == HubPairStatus.Result(state: .none))
  }

  @Test func pairStatusTurnsPairedWhenANewPhoneAppears() async throws {
    let rig = try await SyncRig.make()
    let oldPhone = DeviceInfo(id: "old-phone", name: "Old iPhone", platform: "ios")
    await rig.fake.setDevices([mac(), oldPhone])
    _ = try await rig.sync.pair()
    #expect(await rig.sync.pairStatus() == HubPairStatus.Result(state: .waiting))

    // Polls every two seconds. A phone that was already there, and a new Mac, are not the new phone.
    await waitUntilTrue("the watcher to sleep") { rig.clock.sleeperCount == 1 }
    await rig.fake.setDevices([
      mac(), oldPhone, DeviceInfo(id: "mac-2", name: "Other Mac", platform: "macos"),
    ])
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("the second poll") { rig.clock.sleeperCount == 1 }
    #expect(await rig.sync.pairStatus().state == .waiting)

    // A new phone that is already revoked is not a pairing either.
    await rig.fake.setDevices([
      mac(), oldPhone,
      DeviceInfo(id: "gone", name: "Gone", platform: "ios", revokedAt: "2026-11-01T12:00:01.000000Z"),
    ])
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("the third poll") { rig.clock.sleeperCount == 1 }
    #expect(await rig.sync.pairStatus().state == .waiting)

    await rig.fake.setDevices([
      mac(), oldPhone, DeviceInfo(id: "new-phone", name: "Brian's iPhone", platform: "ios"),
    ])
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("the status to turn paired") { await rig.sync.pairStatus().state == .paired }
    #expect(await rig.sync.pairStatus() == HubPairStatus.Result(state: .paired, deviceName: "Brian's iPhone"))
    // The watcher is done: it no longer polls.
    #expect(rig.clock.sleeperCount == 0)
  }

  @Test func pairStatusExpires() async throws {
    let rig = try await SyncRig.make()
    await rig.fake.setPairingCode(code())
    _ = try await rig.sync.pair()
    await waitUntilTrue("the watcher to sleep") { rig.clock.sleeperCount == 1 }
    rig.wall.set(SyncRig.noon.addingTimeInterval(299))
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("the next poll") { rig.clock.sleeperCount == 1 }
    #expect(await rig.sync.pairStatus().state == .waiting)

    rig.wall.set(SyncRig.noon.addingTimeInterval(301))
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("the status to expire") { await rig.sync.pairStatus().state == .expired }
    #expect(await rig.sync.pairStatus() == HubPairStatus.Result(state: .expired))
    #expect(rig.clock.sleeperCount == 0)

    // A new code starts over.
    _ = try await rig.sync.pair()
    #expect(await rig.sync.pairStatus().state == .waiting)
    await rig.sync.stop()
  }

  @Test func aPhoneThatPairsOnTheLastPollBeforeExpiryCounts() async throws {
    let rig = try await SyncRig.make()
    await rig.fake.setPairingCode(code())
    _ = try await rig.sync.pair()
    await waitUntilTrue("the watcher to sleep") { rig.clock.sleeperCount == 1 }
    await rig.fake.setDevices([mac(), DeviceInfo(id: "p", name: "Phone", platform: "ios")])
    rig.wall.set(SyncRig.noon.addingTimeInterval(301))
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("the status to settle") { await rig.sync.pairStatus().state != .waiting }
    #expect(await rig.sync.pairStatus().state == .paired)
  }

  @Test func aNewCodeReplacesTheWatchOfTheOldOne() async throws {
    let rig = try await SyncRig.make()
    _ = try await rig.sync.pair()
    await waitUntilTrue("the first watcher") { rig.clock.sleeperCount == 1 }
    _ = try await rig.sync.pair()
    // The first watcher is cancelled; only the second sleeps.
    await waitUntilTrue("one watcher") { rig.clock.sleeperCount == 1 }
    await rig.sync.stop()
    await waitUntilTrue("no watcher") { rig.clock.sleeperCount == 0 }
  }

  @Test func pairRefusesWhenNotJoined() async throws {
    let rig = try await SyncRig.make(joined: false)
    do {
      _ = try await rig.sync.pair()
      Issue.record("expected a refusal")
    } catch let error as WorkspaceError {
      #expect(error.code == .protocolInvalid && error.message == "Join a hub first")
    }
    #expect(await rig.fake.mintCalls == 0)
    #expect(await rig.sync.pairStatus().state == .none)
  }

  @Test func leavingEndsThePairing() async throws {
    let rig = try await SyncRig.make()
    _ = try await rig.sync.pair()
    await waitUntilTrue("the watcher") { rig.clock.sleeperCount == 1 }
    try await rig.sync.leave()
    #expect(rig.clock.sleeperCount == 0)
    #expect(await rig.sync.pairStatus().state == .none)
    do {
      _ = try await rig.sync.pair()
      Issue.record("expected a refusal")
    } catch let error as WorkspaceError {
      #expect(error.message == "Join a hub first")
    }
  }

  @Test func theHubsRateLimitSurfacesAsRateLimitedWithTheWait() async throws {
    let rig = try await SyncRig.make()
    await rig.fake.setMintFailure(
      HubError(
        kind: "request_error", code: "rate_limited", message: "too many requests; try again shortly",
        status: 429, retryAfterMs: 120_000))
    do {
      _ = try await rig.sync.pair()
      Issue.record("expected a refusal")
    } catch let error as WorkspaceError {
      #expect(error.code == .rateLimited)
      #expect(error.details?["retryAfterMs"] == .number(120_000))
    }
    #expect(await rig.sync.pairStatus().state == .none)
    #expect(rig.clock.sleeperCount == 0)
  }

  @Test func codeNeverAppearsInLogsOrStatus() async throws {
    let started = Date().addingTimeInterval(-1)
    let secret = "ZQXV7654"
    let rig = try await SyncRig.make()
    await rig.fake.setPairingCode(code(secret, hubURL: "https://hub.example.com/"))
    let minted = try await rig.sync.pair()
    #expect(minted.code == secret)
    await waitUntilTrue("the watcher") { rig.clock.sleeperCount == 1 }
    await rig.fake.setDevices([mac(), DeviceInfo(id: "p", name: "Phone", platform: "ios")])
    rig.clock.advance(by: .seconds(2))
    await waitUntilTrue("paired") { await rig.sync.pairStatus().state == .paired }
    // A refused mint is logged and surfaced too.
    await rig.fake.setMintFailure(
      HubError(
        kind: "request_error", code: "rate_limited", message: "slow down", status: 429, retryAfterMs: 5))
    _ = try? await rig.sync.pair()

    // Everything the coordinator reports: `hub.status`, the pairing status, the errors' text.
    let status = try String(
      decoding: JSONCoding.encoder.encode(try await rig.sync.status()), as: UTF8.self)
    let pairStatus = try String(
      decoding: JSONCoding.encoder.encode(await rig.sync.pairStatus()), as: UTF8.self)
    #expect(!status.contains(secret) && !pairStatus.contains(secret))
    #expect(!"\(minted)".contains(secret) && !String(reflecting: minted).contains(secret))

    // Everything it logged in this process, with a positive control that the capture sees our lines.
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let entries = try store.getEntries(at: store.position(date: started))
      .compactMap { $0 as? OSLogEntryLog }
      .filter { $0.subsystem == Log.subsystem }
      .map(\.composedMessage)
    #expect(entries.contains { $0.contains("joined") }, "the log capture saw nothing of this test")
    #expect(!entries.contains { $0.contains(secret) })
    await rig.sync.stop()
  }
}

// MARK: - Through the socket

/// A coordinator over a scratch store with a `FakeHubAPI`, fake power assertions, and a fake relay link
/// connection, with a client on its socket.
struct SocketRig {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let fake: FakeHubAPI
  let assertions: FakePowerAssertions

  static func start() async throws -> SocketRig {
    let base = NSTemporaryDirectory() + "b4p-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var env = ProcessInfo.processInfo.environment
    env["B4APP_NODE_PATH"] = "/nonexistent/node"
    let fake = FakeHubAPI()
    await fake.addEnrollmentCode(pairingEnrollCode, pairingMacEnrollment)
    let assertions = FakePowerAssertions()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths, environment: env, secretStore: MemorySecretStore(), hubAPIFactory: { _, _ in fake },
        hubLinkConnection: FakeHubLinkConnection(), powerAssertions: assertions))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    return SocketRig(coordinator: coordinator, client: client, fake: fake, assertions: assertions)
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }

  func join() async throws -> HubStatus.Result {
    try await client.request(
      HubJoin.self,
      HubJoin.Params(url: "http://localhost:8080", code: pairingEnrollCode, deviceName: "Test Mac"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
  }
}

@Suite(.serialized) struct PairingSocketTests {
  @Test func pairIsRoutedAndNeverReplayedFromTheOperationCache() async throws {
    let rig = try await SocketRig.start()
    defer { Task { await rig.close() } }
    do {
      _ = try await rig.client.request(HubPair.self, EmptyParams())
      Issue.record("expected a refusal before joining")
    } catch let error as WorkspaceError {
      #expect(error.message == "Join a hub first")
    }
    #expect(try await rig.client.request(HubPairStatus.self, EmptyParams()).state == .none)

    _ = try await rig.join()
    await rig.fake.setPairingCode(
      PairingCodeResponse(code: "AAAA1111", expiresAt: "2026-11-01T12:05:00.000000Z"))
    // Even with an operationId, a code is never kept to be answered again.
    let options = RequestOptions(operationId: "pair-op", timeout: .seconds(30))
    let first = try await rig.client.request(HubPair.self, EmptyParams(), options: options)
    await rig.fake.setPairingCode(
      PairingCodeResponse(code: "BBBB2222", expiresAt: "2026-11-01T12:05:00.000000Z"))
    let second = try await rig.client.request(HubPair.self, EmptyParams(), options: options)
    #expect(first.code == "AAAA1111" && second.code == "BBBB2222")
    #expect(first.url == "http://localhost:8080")
    #expect(try await rig.client.request(HubPairStatus.self, EmptyParams()).state == .waiting)

    // hub.status and Diagnostics carry no code.
    let status = try String(
      decoding: JSONCoding.encoder.encode(try await rig.client.request(HubStatus.self, EmptyParams())),
      as: UTF8.self)
    let diagnostics = try String(
      decoding: JSONCoding.encoder.encode(try await rig.client.request(DiagnosticsRead.self, EmptyParams())),
      as: UTF8.self)
    for text in [status, diagnostics] { #expect(!text.contains("AAAA1111") && !text.contains("BBBB2222")) }
  }
}
