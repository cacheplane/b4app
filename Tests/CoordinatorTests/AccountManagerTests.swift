import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync

@testable import Coordinator
@testable import WorkspaceStorage

// The per-account split (sign-in plan, Task 9): a coordinator over the ephemeral cluster whose hub is a
// set of `FakeHubAPI`s, one per account, told apart by the token each call carries.

private let hubURL = "http://localhost:8080"
private let signedOutMessage = "Nobody is signed in. Sign in from the Agent Workspace app."

private let ann = AuthSession(
  deviceId: "dev-ann", token: "tok-ann-secret", org: OrgInfo(slug: "o-annannan", name: "Ann's Org"),
  user: UserInfo(username: "u-annannan", displayName: "Ann"), needsOnboarding: false)
private let bob = AuthSession(
  deviceId: "dev-bob", token: "tok-bob-secret", org: OrgInfo(slug: "o-bobbobbo", name: "Bob's Org"),
  user: UserInfo(username: "u-bobbobbo", displayName: "Bob"), needsOnboarding: false)

private func unauthorized() -> HubError {
  HubError(kind: "request_error", code: "unauthorized", message: "Unauthorized.", status: 401)
}

/// The hub as several accounts see it: each token reaches its own `FakeHubAPI`, an unknown token is
/// answered 401, and every call (enrollments included) is counted.
private final class AccountsHub: Sendable {
  private struct State {
    var fakes: [String: FakeHubAPI] = [:]
    var refusingPushes: Set<String> = []
    var unreachable = false
    var calls = 0
  }

  private let state = Mutex(State())
  /// Redeems enrollment codes; the token it hands out then reaches it.
  let enrollments = FakeHubAPI()

  var calls: Int { state.withLock { $0.calls } }

  /// A fake for `session`'s account, signed in on its device so `me()` and `devices()` answer for it.
  @discardableResult
  func add(_ session: AuthSession) async -> FakeHubAPI {
    let fake = FakeHubAPI()
    await fake.setSession(session)
    _ = try? await fake.passkeyFinish(
      PasskeyFinishRequest(
        ceremonyId: "c", assertion: nil, attestation: nil,
        device: DeviceSpec(deviceName: "Test Mac", platform: "macos", deviceId: session.deviceId)))
    state.withLock { $0.fakes[session.token] = fake }
    return fake
  }

  func refusePushes(token: String) { _ = state.withLock { $0.refusingPushes.insert(token) } }
  func setUnreachable(_ value: Bool) { state.withLock { $0.unreachable = value } }

  func api(_ url: URL, _ token: @escaping @Sendable () async throws -> String?) -> any HubAPI {
    RoutedAPI(hub: self, token: token)
  }

  fileprivate func count() throws {
    let unreachable = state.withLock { state -> Bool in
      state.calls += 1
      return state.unreachable
    }
    if unreachable {
      throw HubError(kind: "network", code: "unreachable", message: "The hub is unreachable.", status: 0)
    }
  }

  fileprivate func fake(_ token: String?) throws -> FakeHubAPI {
    guard let token, let fake = state.withLock({ $0.fakes[token] }) else { throw unauthorized() }
    return fake
  }

  fileprivate func refusesPushes(_ token: String?) -> Bool {
    guard let token else { return true }
    return state.withLock { $0.refusingPushes.contains(token) }
  }

  fileprivate func enrolled(_ response: EnrollResponse) {
    state.withLock { $0.fakes[response.token] = enrollments }
  }
}

private struct RoutedAPI: HubAPI {
  let hub: AccountsHub
  let token: @Sendable () async throws -> String?

  private func fake() async throws -> FakeHubAPI {
    try hub.count()
    return try hub.fake(try await token())
  }

  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    try hub.count()
    let response = try await hub.enrollments.enroll(request)
    hub.enrolled(response)
    return response
  }
  func me() async throws -> MeResponse { try await fake().me() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse {
    let fake = try await fake()
    if hub.refusesPushes(try await token()) { throw unauthorized() }
    return try await fake.push(changes)
  }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await fake().pull(after: after, limit: limit, wait: wait)
  }
  func snapshot() async throws -> SnapshotResponse { try await fake().snapshot() }
  func devices() async throws -> [DeviceInfo] { try await fake().devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { try await fake().mintPairingCode() }
  func revokeSelf() async throws { try await fake().revokeSelf() }
}

private struct AccountRig {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let paths: PlatformPaths
  let secrets: MemorySecretStore
  let hub: AccountsHub
  let links: FakeHubLinkConnection

  var accounts: AccountManager { coordinator.accounts }

  static func paths() throws -> PlatformPaths {
    let base = NSTemporaryDirectory() + "b4a-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
  }

  static func start(
    paths: PlatformPaths? = nil, secrets: MemorySecretStore = MemorySecretStore(), hub: AccountsHub? = nil
  ) async throws -> AccountRig {
    let paths = try paths ?? Self.paths()
    let hub = hub ?? AccountsHub()
    let links = FakeHubLinkConnection()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths,
        environment: [
          "PATH": "/nonexistent", "HOME": paths.dataDir, "B4APP_NODE_PATH": "/nonexistent/node",
          ExecutableLocator.fallbackOverrideVariable: "",
        ],
        secretStore: secrets, hubAPIFactory: { hub.api($0, $1) }, hubLinkConnection: links,
        powerAssertions: FakePowerAssertions()))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    return AccountRig(
      coordinator: coordinator, client: client, paths: paths, secrets: secrets, hub: hub, links: links)
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }

  /// The threads the coordinator lists over its socket.
  func threadIds() async throws -> [String] {
    try await client.request(ThreadList.self, ThreadList.Params(includeArchived: true)).threads.map(\.id)
  }

  /// A thread written straight into the signed-in account's store.
  func addThread(_ id: String) throws {
    let db = try accounts.scope().database
    if try db.connection(id: "c1") == nil {
      _ = try db.insertConnection(Connection(id: "c1", kind: .claude, label: "Claude", target: "/bin/claude"))
    }
    _ = try db.insertThread(
      ConversationThread(
        id: id, connectionId: "c1", nativeThreadId: "native-\(id)", nativeScope: "me", title: id))
  }

  /// Every `account.changed` the coordinator has published since it started.
  func accountEvents() async -> [AccountStatus.Result] {
    let log = coordinator.eventLog
    return (await log.replay(epoch: log.epoch, afterSequence: 0) ?? [])
      .filter { $0.event.kind == .accountChanged }
      .compactMap { try? $0.event.payload.decode(AccountStatus.Result.self) }
  }

  func registry() throws -> AccountRegistry {
    try AccountRegistry(
      endpoint: paths.postgres, binDir: paths.postgres.binDir!,
      databaseName: AccountManager.registryDatabaseName(for: paths.postgres))
  }
}

/// Polls `condition` every 20 ms for up to ten seconds.
private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while try await !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(what)")
      return
    }
    try await Task.sleep(for: .milliseconds(20))
  }
}

/// Writes a joined `workspace` database as a build before sign-in left it: a hub link, a thread, and
/// the device token in the secret store.
private func seedJoinedWorkspace(
  _ paths: PlatformPaths, secrets: MemorySecretStore
) async throws -> SecretRef {
  let db = try WorkspaceDatabase(endpoint: paths.postgres, binDir: paths.postgres.binDir!)
  defer { try? db.close() }
  let ref = SecretRef.make()
  try await secrets.put(ref, value: "tok-very-secret")
  try db.saveHubLink(
    WorkspaceDatabase.HubLink(
      url: hubURL, deviceId: "dev-mac", deviceName: "Test Mac", tokenRef: ref.rawValue, orgSlug: "acme",
      username: "brian", joinedAt: Timestamp.now()))
  _ = try db.insertConnection(Connection(id: "c1", kind: .claude, label: "Claude", target: "/bin/claude"))
  _ = try db.insertThread(
    ConversationThread(id: "joined", connectionId: "c1", nativeThreadId: "n1", nativeScope: "me", title: "J"))
  return ref
}

private let acme = AuthSession(
  deviceId: "dev-mac", token: "tok-very-secret", org: OrgInfo(slug: "acme", name: "Acme"),
  user: UserInfo(username: "brian", displayName: "Brian"), needsOnboarding: false)

@Suite(.serialized, .timeLimit(.minutes(3))) struct AccountManagerTests {
  @Test func adoptsJoinedWorkspace() async throws {
    let paths = try AccountRig.paths()
    let secrets = MemorySecretStore()
    let ref = try await seedJoinedWorkspace(paths, secrets: secrets)
    let hub = AccountsHub()
    let fake = await hub.add(acme)

    let rig = try await AccountRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await rig.close() } }

    // Signed in at once from the link, with no sign-in call and no signed-out moment.
    let status = await rig.accounts.status()
    #expect(status.state == .signedIn)
    let scope = try rig.accounts.scope()
    #expect(scope.account.database == paths.postgres.database)
    #expect(scope.account.deviceId == "dev-mac")
    #expect(try await rig.threadIds() == ["joined"])
    #expect(await fake.passkeyFinishes.count == 1)  // only the rig's own setup
    #expect(await rig.accountEvents().allSatisfy { $0.state != .signedOut })

    // Registered with the link's device and token reference; `/v1/me` fills in the names.
    let registry = try rig.registry()
    defer { registry.close() }
    let row = try #require(try registry.active())
    #expect(row.database == paths.postgres.database)
    #expect(row.deviceId == "dev-mac")
    #expect(row.tokenRef == ref.rawValue)
    #expect(row.hubURL == hubURL)
    try await eventually("the names from /v1/me") {
      await rig.accounts.status().account?.orgName == "Acme"
    }
    #expect(await rig.accounts.status().account?.displayName == "Brian")
    #expect(try registry.active()?.orgName == "Acme")
  }

  @Test func adoptsJoinedWorkspaceWhileTheHubIsDown() async throws {
    let paths = try AccountRig.paths()
    let secrets = MemorySecretStore()
    _ = try await seedJoinedWorkspace(paths, secrets: secrets)
    let hub = AccountsHub()
    await hub.add(acme)
    hub.setUnreachable(true)

    let rig = try await AccountRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await rig.close() } }
    #expect(await rig.accounts.status().state == .signedIn)
    #expect(try rig.accounts.scope().account.database == paths.postgres.database)
    #expect(try await rig.threadIds() == ["joined"])
    #expect(await rig.accountEvents().allSatisfy { $0.state != .signedOut })
  }

  @Test func unjoinedWorkspaceGoesToFirstSignIn() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    await rig.hub.add(bob)
    #expect(await rig.accounts.status().state == .signedOut)

    let first = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    #expect(first.state == .signedIn)
    #expect(first.account?.orgName == "Ann's Org")
    #expect(try rig.accounts.scope().account.database == rig.paths.postgres.database)

    await rig.accounts.signOut(reason: nil)
    _ = try await rig.accounts.signIn(session: bob, hubURL: hubURL)
    let second = try rig.accounts.scope().account
    #expect(second.database == AccountRegistry.databaseName(id: second.id))
    #expect(second.database != rig.paths.postgres.database)
    #expect(await rig.accounts.status().known.count == 2)
  }

  @Test func switchPreservesThreads() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    await rig.hub.add(bob)

    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    try rig.addThread("ann-thread")
    _ = try await rig.client.request(
      DraftSave.self, DraftSave.Params(threadId: "ann-thread", text: "half a thought"),
      options: RequestOptions(operationId: UUID().uuidString))
    #expect(try await rig.threadIds() == ["ann-thread"])

    await rig.accounts.signOut(reason: nil)
    _ = try await rig.accounts.signIn(session: bob, hubURL: hubURL)
    #expect(try await rig.threadIds().isEmpty)

    await rig.accounts.signOut(reason: nil)
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    #expect(try await rig.threadIds() == ["ann-thread"])
    let draft = try await rig.client.request(DraftRead.self, DraftRead.Params(threadId: "ann-thread")).draft
    #expect(draft?.text == "half a thought")
  }

  @Test func restartKeepsActiveAccount() async throws {
    let paths = try AccountRig.paths()
    let secrets = MemorySecretStore()
    let hub = AccountsHub()
    await hub.add(ann)
    let first = try await AccountRig.start(paths: paths, secrets: secrets, hub: hub)
    _ = try await first.accounts.signIn(session: ann, hubURL: hubURL)
    try first.addThread("kept")
    let before = try first.accounts.scope().account
    await first.close()

    let second = try await AccountRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await second.close() } }
    let status = await second.accounts.status()
    #expect(status.state == .signedIn)
    #expect(status.account?.id == before.id)
    let after = try second.accounts.scope().account
    #expect(after.database == before.database)
    #expect(after.id == before.id)
    #expect(try await second.threadIds() == ["kept"])
    // Nothing during the boot said "signed out".
    #expect(await second.accountEvents().allSatisfy { $0.state != .signedOut })
  }

  @Test func hub401SignsOut() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    rig.hub.refusePushes(token: ann.token)
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    let scope = try rig.accounts.scope()
    let ref = try #require(scope.account.tokenRef.flatMap(SecretRef.init(rawValue:)))
    #expect(try await rig.secrets.read(ref) == ann.token)

    try rig.addThread("unsynced")
    _ = try? await scope.hub.pushNow()
    try await eventually("signed out") { await rig.accounts.status().state == .signedOut }

    let status = await rig.accounts.status()
    #expect(status.reason == .rejectedByHub("Ann's Org"))
    #expect(status.reason?.orgName == "Ann's Org")
    #expect(status.account == nil)
    #expect(rig.accounts.current == nil)
    // The scope is closed: its store refuses work.
    #expect(throws: (any Error).self) { try scope.database.listThreads(ThreadFilter()) }
    // The token is forgotten, in the secret store and the registry.
    #expect(try await rig.secrets.read(ref) == nil)
    let registry = try rig.registry()
    defer { registry.close() }
    let row = try #require(try registry.all().first)
    #expect(row.tokenRef == nil)
    #expect(row.active == false)
    // The change was published with the reason, and no token went with it.
    let published = try #require(await rig.accountEvents().last)
    #expect(published.state == .signedOut)
    #expect(published.reason == .rejectedByHub("Ann's Org"))
    let payload = String(decoding: try JSONCoding.encoder.encode(published), as: UTF8.self)
    #expect(!payload.contains(ann.token))
    #expect(!payload.contains(ref.rawValue))

    // Nothing more goes to the hub for that account. Timed on purpose: an absence has no event.
    let calls = rig.hub.calls
    let opens = rig.links.openCount
    try await Task.sleep(for: .milliseconds(800))
    #expect(rig.hub.calls == calls)
    #expect(rig.links.openCount == opens)
    await #expect(throws: WorkspaceError.self) { _ = try await rig.threadIds() }
  }

  @Test func failedMigrationRefusesSignIn() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    await rig.hub.add(bob)
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    try rig.addThread("ann-thread")
    let annRow = try rig.accounts.scope().account

    // Bob's row points at a database a newer build has migrated.
    let registry = try rig.registry()
    defer { registry.close() }
    let id = AccountRegistry.newId()
    var endpoint = rig.paths.postgres
    endpoint.database = AccountRegistry.databaseName(id: id)
    let future = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    _ = try future.read { connection in
      try connection.execute(
        "INSERT INTO \"schemaMigrations\" (\"name\", \"appliedAt\") VALUES ('9999_from_the_future', 'now')")
    }
    try future.close()
    try registry.insert(
      AccountRow(
        id: id, hubURL: hubURL, hubUserId: "\(bob.org.slug)/\(bob.user.username)", deviceId: bob.deviceId,
        database: endpoint.database, displayName: "Bob", orgName: "Bob's Org"))
    let bobBefore = try #require(try registry.find(hubURL: hubURL, hubUserId: "o-bobbobbo/u-bobbobbo"))

    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.accounts.signIn(session: bob, hubURL: hubURL)
    }
    #expect(error?.code == .incompatibleVersion)
    #expect(error?.message.contains("9999_from_the_future") == true)

    // Ann is still the active, open account; Bob's row is exactly as it was.
    let status = await rig.accounts.status()
    #expect(status.state == .signedIn)
    #expect(status.account?.id == annRow.id)
    #expect(try rig.accounts.scope().account.id == annRow.id)
    #expect(try await rig.threadIds() == ["ann-thread"])
    #expect(try registry.active()?.id == annRow.id)
    #expect(try registry.find(hubURL: hubURL, hubUserId: "o-bobbobbo/u-bobbobbo") == bobBefore)
  }

  @Test func storeCommandsSignedOut() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    #expect(await rig.accounts.status().state == .signedOut)

    let error = await #expect(throws: WorkspaceError.self) { _ = try await rig.threadIds() }
    #expect(error?.code == .signedOut)
    #expect(error?.message == signedOutMessage)

    // Every method that reads or writes the store answers the same, before its params are read.
    let unscoped: Set<WorkspaceProtocol.Method> = [
      .systemPing, .diagnosticsRead, .eventsReplay, .hubJoin, .threadStart, .turnLookup,
    ]
    for method in WorkspaceProtocol.Method.allCases where !unscoped.contains(method) {
      let operation = UUID().uuidString
      let line =
        #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"\#(operation)","method":"\#(method.rawValue)","params":{}}"#
      let response = await rig.coordinator.router.dispatch(line: Data(line.utf8))
      #expect(response.error?.code == .signedOut, "\(method.rawValue)")
      #expect(response.error?.message == signedOutMessage, "\(method.rawValue)")
    }

    // The rest work without an account.
    #expect(try await rig.client.request(SystemPing.self, EmptyParams()).pong)
    let report = try await rig.client.request(
      DiagnosticsRead.self, EmptyParams(), options: RequestOptions(timeout: .seconds(60)))
    #expect(report.runtimes.map(\.kind) == [.node, .codex, .claude])
    let replay = try await rig.client.request(
      EventsReplay.self, EventsReplay.Params(epoch: rig.coordinator.epoch, afterSequence: 0))
    #expect(replay.events.allSatisfy { $0.event.kind == .accountChanged })
  }

  @Test func hubJoinWhileSignedOutSignsIn() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.enrollments.addEnrollmentCode(
      "BCDF2345",
      EnrollResponse(deviceId: acme.deviceId, token: acme.token, org: acme.org, user: acme.user))

    let joined = try await rig.client.request(
      HubJoin.self, HubJoin.Params(url: hubURL, code: "BCDF2345", deviceName: "Test Mac"),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    #expect(joined.joined)
    #expect(joined.deviceId == "dev-mac")
    let status = await rig.accounts.status()
    #expect(status.state == .signedIn)
    #expect(status.account?.orgName == "Acme")
    let scope = try rig.accounts.scope()
    #expect(scope.account.hubUserId == "acme/brian")
    #expect(scope.account.database == rig.paths.postgres.database)
    #expect(try scope.database.hubLink()?.deviceName == "Test Mac")
  }
}
