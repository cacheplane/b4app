import Foundation
import NIOTransport
import Synchronization
import Testing
import WorkspaceClient
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSync
import WorkspaceTestSupport

@testable import Coordinator
@testable import WorkspaceStorage

// The per-account split (sign-in plan, Task 9): a coordinator over the ephemeral cluster whose hub is a
// set of `FakeHubAPI`s, one per account, told apart by the token each call carries.

private let hubURL = "http://localhost:8080"
private let signedOutMessage = "Nobody is signed in. Sign in from the Agent Workspace app."

private let ann = AuthSession(
  deviceId: "dev-ann", token: "tok-ann-secret", org: OrgInfo(slug: "o-annannan", name: "Ann's Org"),
  user: UserInfo(username: "u-annannan", displayName: "Ann"), needsOnboarding: false,
  userId: "0197aaaa-0000-7000-8000-00000000a001")
private let bob = AuthSession(
  deviceId: "dev-bob", token: "tok-bob-secret", org: OrgInfo(slug: "o-bobbobbo", name: "Bob's Org"),
  user: UserInfo(username: "u-bobbobbo", displayName: "Bob"), needsOnboarding: false,
  userId: "0197bbbb-0000-7000-8000-00000000b002")

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
    paths: PlatformPaths? = nil, secrets: MemorySecretStore = MemorySecretStore(), hub: AccountsHub? = nil,
    environment: [String: String]? = nil, adapterFactory: SessionService.AdapterFactory? = nil,
    legacySecrets: (any SecretStore)? = nil
  ) async throws -> AccountRig {
    let paths = try paths ?? Self.paths()
    let hub = hub ?? AccountsHub()
    let links = FakeHubLinkConnection()
    // The local flavour's plan as `planIfExplicitLocal` makes it, with fakes: no previous install to
    // move (its home has no `b4app`), and `legacySecrets` standing in for the prod keychain group.
    let adoption = legacySecrets.map { store in
      LegacyAdoption.Plan(
        home: URL(fileURLWithPath: paths.dataDir).appendingPathComponent("no-home"),
        readHubURL: { _ in nil }, bootOutLegacy: {}, legacySecretStore: store)
    }
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths,
        environment: environment ?? [
          "PATH": "/nonexistent", "HOME": paths.dataDir, "B4APP_NODE_PATH": "/nonexistent/node",
          ExecutableLocator.fallbackOverrideVariable: "",
        ],
        secretStore: secrets, adapterFactory: adapterFactory, hubAPIFactory: { hub.api($0, $1) },
        hubLinkConnection: links, powerAssertions: FakePowerAssertions(), legacyAdoption: adoption))
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
  _ paths: PlatformPaths, secrets: any SecretStore
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
  user: UserInfo(username: "brian", displayName: "Brian"), needsOnboarding: false,
  userId: "0197cccc-0000-7000-8000-00000000c003")

@Suite(BlockingDatabaseWork(), .serialized, .timeLimit(.minutes(3))) struct AccountManagerTests {
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
    // The first successful /v1/me replaces the placeholder user id and fills in the names.
    try await eventually("the user id and names from /v1/me") {
      try registry.active()?.hubUserId == acme.userId
    }
    let named = try #require(try registry.active())
    #expect(named.id == row.id)
    #expect(named.orgName == "Acme")
    #expect(await rig.accounts.status().account?.orgName == "Acme")
    #expect(await rig.accounts.status().account?.displayName == "Brian")
    #expect(try rig.accounts.scope().account.hubUserId == acme.userId)
  }

  @Test func anAdoptedRowUntilNamedIsAPlaceholderThatASignInClaims() async throws {
    let paths = try AccountRig.paths()
    let secrets = MemorySecretStore()
    _ = try await seedJoinedWorkspace(paths, secrets: secrets)
    let hub = AccountsHub()
    await hub.add(acme)
    hub.setUnreachable(true)
    let rig = try await AccountRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await rig.close() } }
    let adopted = try rig.accounts.scope().account
    #expect(adopted.hubUserId == "device:dev-mac")
    // Names the hub has not given are never made up from the slug or the username.
    #expect(adopted.orgName.isEmpty && adopted.displayName.isEmpty)

    // Signed out before the hub ever answered; signing in as the account on that device claims the row.
    await rig.accounts.signOut(reason: nil)
    hub.setUnreachable(false)
    _ = try await rig.accounts.signIn(session: acme, hubURL: hubURL)
    let claimed = try rig.accounts.scope().account
    #expect(claimed.id == adopted.id)
    #expect(claimed.database == paths.postgres.database)
    #expect(claimed.hubUserId == acme.userId)
    #expect(claimed.orgName == "Acme")
    #expect(try await rig.threadIds() == ["joined"])
    let registry = try rig.registry()
    defer { registry.close() }
    #expect(try registry.all().count == 1)
  }

  @Test func anAdoptedAccountRefusedAtOnceIsSignedOutWithoutItsSlug() async throws {
    let paths = try AccountRig.paths()
    let secrets = MemorySecretStore()
    _ = try await seedJoinedWorkspace(paths, secrets: secrets)
    // The hub knows no such token: every call is a 401.
    let rig = try await AccountRig.start(paths: paths, secrets: secrets, hub: AccountsHub())
    defer { Task { await rig.close() } }
    try await eventually("signed out") { await rig.accounts.status().state == .signedOut }
    let reason = try #require(await rig.accounts.status().reason)
    #expect(reason == .rejectedByHub(AccountManager.unnamedOrg))
    #expect(!reason.orgName.contains("acme"))
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
        id: id, hubURL: hubURL, hubUserId: bob.userId!, deviceId: bob.deviceId,
        database: endpoint.database, displayName: "Bob", orgName: "Bob's Org"))
    let bobBefore = try #require(try registry.find(hubURL: hubURL, hubUserId: bob.userId!))

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
    #expect(try registry.find(hubURL: hubURL, hubUserId: bob.userId!) == bobBefore)
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
    // `account.*` is routed without an account (Task 10's `AccountCommandTests` cover it).
    for method in WorkspaceProtocol.Method.allCases
    where !unscoped.contains(method) && !method.rawValue.hasPrefix("account.") {
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
    await rig.hub.enrollments.setUserId(acme.userId)
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
    // The enrollment answer carries no user id; `/v1/me` after it does.
    #expect(scope.account.hubUserId == acme.userId)
    #expect(scope.account.database == rig.paths.postgres.database)
    #expect(try scope.database.hubLink()?.deviceName == "Test Mac")

    // A second join while signed in is refused before anything reaches the hub.
    await rig.hub.enrollments.addEnrollmentCode(
      "CDFG3456",
      EnrollResponse(deviceId: bob.deviceId, token: bob.token, org: bob.org, user: bob.user))
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        HubJoin.self, HubJoin.Params(url: hubURL, code: "CDFG3456", deviceName: "Test Mac"),
        options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    }
    #expect(error?.code == .protocolInvalid)
    #expect(error?.message.contains("Log out first") == true)
    #expect(error?.message.contains("Acme") == true)
    #expect(await rig.hub.enrollments.enrollCalls == 1)
    #expect(try rig.accounts.scope().account.hubUserId == acme.userId)
  }

  @Test func aLate401FromAnEarlierScopeOfTheSameAccountIsIgnored() async throws {
    let rig = try await AccountRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    let earlier = try rig.accounts.scope()
    // Signing in again as the same account replaces the scope.
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    let later = try rig.accounts.scope()
    #expect(later.instance != earlier.instance)
    #expect(later.account.id == earlier.account.id)
    await rig.accounts.hubRejected(instance: earlier.instance)
    #expect(await rig.accounts.status().state == .signedIn)
    await rig.accounts.hubRejected(instance: later.instance)
    #expect(await rig.accounts.status().state == .signedOut)
  }

  @Test func aTurnSendRacingSignOutLeavesNoLiveAdapter() async throws {
    let adapters = HeldAdapters()
    let rig = try await AccountRig.start(adapterFactory: { _, _, _, _ in adapters.make() })
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    try rig.addThread("busy")
    let scope = try rig.accounts.scope()

    // The send is inside the runtime when the sign-out begins.
    let send = Task {
      try await rig.client.request(
        TurnSend.self, TurnSend.Params(threadId: "busy", text: "go"),
        options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(30)))
    }
    await adapters.arrived()
    let signOut = Task { await rig.accounts.signOut(reason: nil) }
    try await eventually("the scope to start closing") { scope.isClosing }
    // Work that reaches the scope from here on is refused.
    #expect(throws: WorkspaceError.self) { try scope.enter() }
    adapters.release()
    _ = try? await send.value
    await signOut.value

    #expect(adapters.made >= 1)
    #expect(adapters.live == 0, "an adapter outlived the sign-out")
    #expect(await rig.accounts.status().state == .signedOut)
  }

  @Test func aServerStartRacingSignOutLeavesNoServerRunning() async throws {
    let base = NSTemporaryDirectory() + "b4as-\(UUID().uuidString.prefix(8))"
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var environment = ProcessInfo.processInfo.environment
    environment["B4APP_NODE_PATH"] = fakeNodePath()
    let rig = try await AccountRig.start(paths: paths, environment: environment)
    defer { Task { await rig.close() } }
    await rig.hub.add(ann)
    _ = try await rig.accounts.signIn(session: ann, hubURL: hubURL)
    let project = try FakeB4Project.make(root: base + "/proj")
    let server = try await rig.client.request(
      ServerAdd.self, ServerAdd.Params(projectPath: project),
      options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(60))
    ).server
    let scope = try rig.accounts.scope()

    // The start has a process when the sign-out begins.
    let start = Task {
      try await rig.client.request(
        ServerStart.self, ServerRef(serverId: server.id),
        options: RequestOptions(operationId: UUID().uuidString, timeout: .seconds(150)))
    }
    try await eventually("the server's process") {
      (try? scope.database.localServer(id: server.id))??.pid != nil
    }
    let pid = try #require(try scope.database.localServer(id: server.id)?.pid)
    let signOut = Task { await rig.accounts.signOut(reason: nil) }
    try await eventually("the scope to start closing") { scope.isClosing }
    // Work that reaches the scope from here on is refused.
    #expect(throws: WorkspaceError.self) { try scope.enter() }
    _ = try? await start.value
    await signOut.value

    #expect(!ProcessInspector.isAlive(pid: pid), "the managed server outlived the sign-out")
    var endpoint = paths.postgres
    endpoint.database = scope.account.database
    let reopened = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    defer { try? reopened.close() }
    for row in try reopened.listLocalServers() {
      if let pid = row.pid { #expect(!ProcessInspector.isAlive(pid: pid)) }
    }
  }
}

/// Counts the adapters a coordinator makes and how many are live (made or started again, and not
/// disposed), and holds every `sendTurn` until `release()`.
private final class HeldAdapters: Sendable {
  private struct State {
    var made = 0
    var live = 0
    var arrived = false
    var released = false
    var arrivals: [CheckedContinuation<Void, Never>] = []
    var holds: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var made: Int { state.withLock { $0.made } }
  var live: Int { state.withLock { $0.live } }

  func make() -> any AgentAdapter {
    state.withLock {
      $0.made += 1
      $0.live += 1
    }
    return HeldAdapter(owner: self)
  }

  func spawned() { state.withLock { $0.live += 1 } }
  func disposed() { state.withLock { $0.live -= 1 } }

  /// A `sendTurn` is inside the runtime: tell `arrived()`, and wait for `release()`.
  func arrive() async {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.arrived = true
      defer { state.arrivals = [] }
      return state.arrivals
    }
    for waiter in waiters { waiter.resume() }
    await withCheckedContinuation { continuation in
      let now = state.withLock { state -> Bool in
        if state.released { return true }
        state.holds.append(continuation)
        return false
      }
      if now { continuation.resume() }
    }
  }

  /// Returns once a `sendTurn` has arrived.
  func arrived() async {
    await withCheckedContinuation { continuation in
      let now = state.withLock { state -> Bool in
        if state.arrived { return true }
        state.arrivals.append(continuation)
        return false
      }
      if now { continuation.resume() }
    }
  }

  func release() {
    let holds = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released = true
      defer { state.holds = [] }
      return state.holds
    }
    for hold in holds { hold.resume() }
  }
}

/// A runtime that, like one started on demand (the Codex app server after a dispose), starts again
/// when a disposed adapter is used. Only `sendTurn` does anything.
private actor HeldAdapter: AgentAdapter {
  nonisolated let kind: ConnectionKind = .claude
  private let owner: HeldAdapters
  private var disposed = false
  private nonisolated let stream: AsyncStream<AdapterEvent>

  init(owner: HeldAdapters) {
    self.owner = owner
    stream = AsyncStream { _ in }
  }

  private func use() {
    if disposed {
      disposed = false
      owner.spawned()
    }
  }

  private func unsupported() -> WorkspaceError {
    WorkspaceError(.unsupportedCapability, "Not used by this test.")
  }

  func inspectConnection() async throws -> ConnectionInspection { throw unsupported() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef { throw unsupported() }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot { throw unsupported() }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    await owner.arrive()
    use()
    return SubmissionReceipt(nativeTurnId: "native-turn", acknowledged: true)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    throw unsupported()
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws { throw unsupported() }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    throw unsupported()
  }
  nonisolated func events() -> AsyncStream<AdapterEvent> { stream }
  func dispose() async {
    guard !disposed else { return }
    disposed = true
    owner.disposed()
  }
}

// MARK: - The owner's secrets in the prod keychain group (D-094, Task X2)

/// A secret store that counts what is asked of it, so a test can show the prod group was not read.
private actor CountingSecretStore: SecretStore {
  private let inner = MemorySecretStore()
  private(set) var reads = 0
  private(set) var writes = 0
  private(set) var removes = 0

  func put(_ ref: SecretRef, value: String) async throws {
    writes += 1
    try await inner.put(ref, value: value)
  }
  func read(_ ref: SecretRef) async throws -> String? {
    reads += 1
    return try await inner.read(ref)
  }
  func remove(_ ref: SecretRef) async throws -> Bool {
    removes += 1
    return try await inner.remove(ref)
  }
  func resetCounts() {
    reads = 0
    writes = 0
    removes = 0
  }
  nonisolated var backend: String { "counting" }
}

/// A B4 connection in the joined `workspace` whose API key sits in `secrets` under a new reference
/// (nil `value`: the reference names nothing).
private func seedConnectionSecret(
  _ paths: PlatformPaths, id: String, secrets: any SecretStore, value: String?
) async throws -> SecretRef {
  let db = try WorkspaceDatabase(endpoint: paths.postgres, binDir: paths.postgres.binDir!)
  defer { try? db.close() }
  let ref = SecretRef.make()
  if let value { try await secrets.put(ref, value: value) }
  _ = try db.insertConnection(
    Connection(
      id: id, kind: .b4, label: "B4 \(id)", target: "https://b4.example", routeKey: "/chat#agent",
      authReference: ref.rawValue))
  return ref
}

@Suite(BlockingDatabaseWork(), .serialized, .timeLimit(.minutes(3))) struct LegacySecretCopyTests {
  @Test func anAdoptedWorkspacesSecretsAreCopiedAndItStaysSignedIn() async throws {
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    let token = try await seedJoinedWorkspace(paths, secrets: prod)
    let key = try await seedConnectionSecret(paths, id: "b1", secrets: prod, value: "b4-key-secret")
    let hub = AccountsHub()
    await hub.add(acme)

    let rig = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    defer { Task { await rig.close() } }

    #expect(try await local.read(token) == "tok-very-secret")
    #expect(try await local.read(key) == "b4-key-secret")
    // Copied, not moved: the prod build still finds its items.
    #expect(try await prod.read(token) == "tok-very-secret")
    #expect(try await prod.read(key) == "b4-key-secret")
    #expect(await prod.removes == 0)
    #expect(await prod.writes == 2)  // the seeds only

    // The hub call that follows carries the copied token: `/v1/me` answers and names the user.
    let registry = try rig.registry()
    defer { registry.close() }
    try await eventually("the user id from /v1/me") { try registry.active()?.hubUserId == acme.userId }
    #expect(await rig.accounts.status().state == .signedIn)
    #expect(await rig.accountEvents().allSatisfy { $0.state != .signedOut })
    #expect(try rig.accounts.scope().database.settings(key: LegacyAdoption.secretsCopiedKey) != nil)
  }

  @Test func anItemTheLocalGroupHasIsNotOverwritten() async throws {
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    let token = try await seedJoinedWorkspace(paths, secrets: local)
    try await prod.put(token, value: "tok-stale-prod")
    let key = try await seedConnectionSecret(paths, id: "b1", secrets: local, value: "local-key")
    try await prod.put(key, value: "prod-key")
    let hub = AccountsHub()
    await hub.add(acme)

    let rig = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    defer { Task { await rig.close() } }

    #expect(try await local.read(token) == "tok-very-secret")
    #expect(try await local.read(key) == "local-key")
    #expect(try await prod.read(token) == "tok-stale-prod")
    let registry = try rig.registry()
    defer { registry.close() }
    try await eventually("the user id from /v1/me") { try registry.active()?.hubUserId == acme.userId }
    #expect(await rig.accounts.status().state == .signedIn)
  }

  @Test func aSecondStartDoesNotCopyAgain() async throws {
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    _ = try await seedJoinedWorkspace(paths, secrets: prod)
    let key = try await seedConnectionSecret(paths, id: "b1", secrets: prod, value: "b4-key-secret")
    let hub = AccountsHub()
    await hub.add(acme)
    let first = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    #expect(try await local.read(key) == "b4-key-secret")
    await first.close()

    // The key is removed here since (say, the connection's key was cleared): a copy would bring it back.
    _ = try await local.remove(key)
    await prod.resetCounts()
    let second = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    defer { Task { await second.close() } }
    #expect(await second.accounts.status().state == .signedIn)
    #expect(await prod.reads == 0)
    #expect(try await local.read(key) == nil)
  }

  @Test func anAccountRestoredBeforeItsSecretsWereCopiedIsCopiedThen() async throws {
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    let token = try await seedJoinedWorkspace(paths, secrets: local)
    try await prod.put(token, value: "tok-very-secret")
    let hub = AccountsHub()
    await hub.add(acme)
    // A start without the copy registers the adopted account and leaves it active; the token is then
    // taken out of the local store, as when a start stopped between the adoption and the copy.
    hub.setUnreachable(true)
    let first = try await AccountRig.start(paths: paths, secrets: local, hub: hub)
    #expect(await first.accounts.status().state == .signedIn)
    await first.close()
    _ = try await local.remove(token)

    hub.setUnreachable(false)
    let second = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    defer { Task { await second.close() } }
    #expect(try await local.read(token) == "tok-very-secret")
    let registry = try second.registry()
    defer { registry.close() }
    try await eventually("the user id from /v1/me") { try registry.active()?.hubUserId == acme.userId }
    #expect(await second.accounts.status().state == .signedIn)
  }

  /// Final review M5: a copy that has not run when the adopted row is signed out (here, a start without
  /// the legacy store, whose hub refused the token it could not read) runs at the sign-in that claims
  /// the row again, before its first hub call.
  @Test func aSignInThatClaimsTheAdoptedRowCopiesTheSecrets() async throws {
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    _ = try await seedJoinedWorkspace(paths, secrets: prod)
    let key = try await seedConnectionSecret(paths, id: "b1", secrets: prod, value: "b4-key-secret")
    let hub = AccountsHub()
    await hub.add(acme)
    let first = try await AccountRig.start(paths: paths, secrets: local, hub: hub)
    try await eventually("signed out") { await first.accounts.status().state == .signedOut }
    await first.close()

    let second = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    defer { Task { await second.close() } }
    // Signed out, so the start restored nothing and copied nothing.
    #expect(await second.accounts.status().state == .signedOut)
    #expect(try await local.read(key) == nil)
    _ = try await second.accounts.signIn(session: acme, hubURL: hubURL)
    #expect(await second.accounts.status().state == .signedIn)
    #expect(try second.accounts.scope().account.database == paths.postgres.database)
    #expect(try await local.read(key) == "b4-key-secret")
    #expect(try second.accounts.scope().database.settings(key: LegacyAdoption.secretsCopiedKey) != nil)
    #expect(await prod.removes == 0)
  }

  @Test func nothingIsCopiedWithoutTheLegacyStore() async throws {
    // Beta, prod, and a dev coordinator get no plan, so no legacy store: the token stays where it is,
    // and the hub refuses the account whose token this coordinator cannot read.
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    let token = try await seedJoinedWorkspace(paths, secrets: prod)
    let hub = AccountsHub()
    await hub.add(acme)
    await prod.resetCounts()

    let rig = try await AccountRig.start(paths: paths, secrets: local, hub: hub)
    defer { Task { await rig.close() } }
    try await eventually("signed out") { await rig.accounts.status().state == .signedOut }
    #expect(await prod.reads == 0)
    #expect(try await local.read(token) == nil)
  }

  @Test func aMissingProdItemIsTolerated() async throws {
    let paths = try AccountRig.paths()
    let prod = CountingSecretStore()
    let local = MemorySecretStore()
    let token = try await seedJoinedWorkspace(paths, secrets: prod)
    let gone = try await seedConnectionSecret(paths, id: "b1", secrets: prod, value: nil)
    let hub = AccountsHub()
    await hub.add(acme)

    let rig = try await AccountRig.start(paths: paths, secrets: local, hub: hub, legacySecrets: prod)
    defer { Task { await rig.close() } }
    #expect(try await local.read(token) == "tok-very-secret")
    #expect(try await local.read(gone) == nil)
    #expect(await rig.accounts.status().state == .signedIn)
    // The copy is done all the same, and is not tried again.
    #expect(try rig.accounts.scope().database.settings(key: LegacyAdoption.secretsCopiedKey) != nil)
  }
}
