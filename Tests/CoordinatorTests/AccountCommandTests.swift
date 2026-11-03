import CryptoKit
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

// The `account.*` commands (sign-in plan, Task 10): sign-in, onboarding, log-out, and deletion over
// the coordinator's socket, against one `FakeHubAPI` that can be made to hang like a hub that takes
// the connection and never answers.

private let localHub = "http://localhost:8080"
private let signedOutMessage = "Nobody is signed in. Sign in from the Agent Workspace app."
private let leftOpenNotice = "The last sign-out could not reach the hub; that session was left open there."

// Device ids are UUIDs, as the hub makes them: a sign-in offers only those (ruling 3).
private let devNew = "0197dddd-0000-7000-8000-0000000000d1"
private let devAnn = "0197aaaa-0000-7000-8000-0000000000a1"
private let devBob = "0197bbbb-0000-7000-8000-0000000000b1"
private let devMac = "0197cccc-0000-7000-8000-0000000000c1"

private let newcomer = AuthSession(
  deviceId: devNew, token: "tok-new-secret", org: OrgInfo(slug: "o-newnewne", name: "My Org"),
  user: UserInfo(username: "u-newnewne", displayName: ""), needsOnboarding: true,
  userId: "0197dddd-0000-7000-8000-00000000d004")
private let ann = AuthSession(
  deviceId: devAnn, token: "tok-ann-secret", org: OrgInfo(slug: "o-annannan", name: "Ann's Org"),
  user: UserInfo(username: "u-annannan", displayName: "Ann"), needsOnboarding: false,
  userId: "0197aaaa-0000-7000-8000-00000000a001")
private let bob = AuthSession(
  deviceId: devBob, token: "tok-bob-secret", org: OrgInfo(slug: "o-bobbobbo", name: "Bob's Org"),
  user: UserInfo(username: "u-bobbobbo", displayName: "Bob"), needsOnboarding: false,
  userId: "0197bbbb-0000-7000-8000-00000000b002")
private let acme = AuthSession(
  deviceId: devMac, token: "tok-acme-secret", org: OrgInfo(slug: "acme", name: "Acme"),
  user: UserInfo(username: "brian", displayName: "Brian"), needsOnboarding: false,
  userId: "0197cccc-0000-7000-8000-00000000c003")

private func hubError(_ code: String, status: Int) -> HubError {
  HubError(kind: "request_error", code: code, message: "Refused: \(code).", status: status)
}

/// The hub for these tests: one `FakeHubAPI` behind every client the coordinator builds.
/// - While `hanging`, every call waits (until its task is cancelled) instead of answering.
/// - While `stuck`, every call waits and ignores its cancellation, as a request in a client that does
///   not honour it; `unstick()` lets them go on.
/// - A call can be refused, or delayed, once by name; the order of the calls is recorded.
final class CommandHub: Sendable {
  private struct State {
    var hanging = false
    var stuck = false
    var held: [CheckedContinuation<Void, Never>] = []
    var failures: [String: HubError] = [:]
    var delays: [String: Duration] = [:]
    var numberAppleCeremonies = false
    var appleBegins = 0
    var calls: [String] = []
    var onEndSession: (@Sendable () -> Void)?
  }

  let fake = FakeHubAPI()
  private let state = Mutex(State())

  var calls: [String] { state.withLock { $0.calls } }
  func setHanging(_ value: Bool) { state.withLock { $0.hanging = value } }
  func stick() { state.withLock { $0.stuck = true } }
  func unstick() {
    let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.stuck = false
      defer { state.held = [] }
      return state.held
    }
    for call in held { call.resume() }
  }
  func fail(_ call: String, with error: HubError) { state.withLock { $0.failures[call] = error } }
  func delay(_ call: String, by duration: Duration) { state.withLock { $0.delays[call] = duration } }
  /// Each `appleBegin` answers a ceremony id of its own (`<scripted id>-<n>`).
  func numberAppleCeremonies() { state.withLock { $0.numberAppleCeremonies = true } }
  func onEndSession(_ body: @escaping @Sendable () -> Void) { state.withLock { $0.onEndSession = body } }

  func api(_ url: URL, _ token: @escaping @Sendable () async throws -> String?) -> any HubAPI {
    ForwardingAPI(hub: self)
  }

  fileprivate func numberedAppleBegin(_ answer: AppleBeginResponse) -> AppleBeginResponse {
    state.withLock { state in
      state.appleBegins += 1
      guard state.numberAppleCeremonies else { return answer }
      return AppleBeginResponse(ceremonyId: "\(answer.ceremonyId)-\(state.appleBegins)", nonce: answer.nonce)
    }
  }

  fileprivate func enter(_ call: String) async throws {
    let (hanging, stuck, failure, delay, hook) = state.withLock {
      state -> (Bool, Bool, HubError?, Duration?, (@Sendable () -> Void)?) in
      state.calls.append(call)
      return (
        state.hanging, state.stuck, state.failures.removeValue(forKey: call),
        state.delays.removeValue(forKey: call), call == "endSession" ? state.onEndSession : nil
      )
    }
    if stuck {
      await withCheckedContinuation { continuation in
        let still = state.withLock { state -> Bool in
          if state.stuck { state.held.append(continuation) }
          return state.stuck
        }
        if !still { continuation.resume() }
      }
    }
    if hanging { try await Task.sleep(for: .seconds(3600)) }
    if let delay { try await Task.sleep(for: delay) }
    if let failure { throw failure }
    hook?()
  }
}

private struct ForwardingAPI: HubAPI {
  let hub: CommandHub
  var fake: FakeHubAPI { hub.fake }

  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    try await hub.enter("enroll")
    return try await fake.enroll(request)
  }
  func me() async throws -> MeResponse {
    try await hub.enter("me")
    return try await fake.me()
  }
  func push(_ changes: [SyncChange]) async throws -> PushResponse {
    try await hub.enter("push")
    return try await fake.push(changes)
  }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await hub.enter("pull")
    return try await fake.pull(after: after, limit: limit, wait: min(wait, 1))
  }
  func snapshot() async throws -> SnapshotResponse {
    try await hub.enter("snapshot")
    return try await fake.snapshot()
  }
  func devices() async throws -> [DeviceInfo] {
    try await hub.enter("devices")
    return try await fake.devices()
  }
  func mintPairingCode() async throws -> PairingCodeResponse {
    try await hub.enter("mintPairingCode")
    return try await fake.mintPairingCode()
  }
  func revokeSelf() async throws {
    try await hub.enter("revokeSelf")
    try await fake.revokeSelf()
  }
  func passkeyBegin() async throws -> PasskeyBeginResponse {
    try await hub.enter("passkeyBegin")
    return try await fake.passkeyBegin()
  }
  func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    try await hub.enter("passkeyFinish")
    return try await fake.passkeyFinish(request)
  }
  func appleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    try await hub.enter("appleBegin")
    return hub.numberedAppleBegin(try await fake.appleBegin(request))
  }
  func handoff(_ request: HandoffRequest) async throws -> AuthSession {
    try await hub.enter("handoff")
    return try await fake.handoff(request)
  }
  func setProfile(_ request: ProfileRequest) async throws -> MeResponse {
    try await hub.enter("setProfile")
    return try await fake.setProfile(request)
  }
  func identities() async throws -> [Identity] {
    try await hub.enter("identities")
    return try await fake.identities()
  }
  func addPasskeyBegin(stepUp: String?) async throws -> AddPasskeyBeginResponse {
    try await hub.enter("addPasskeyBegin")
    return try await fake.addPasskeyBegin(stepUp: stepUp)
  }
  func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity {
    try await hub.enter("addPasskeyFinish")
    return try await fake.addPasskeyFinish(request)
  }
  func removeIdentity(_ id: String, stepUp: String?) async throws {
    try await hub.enter("removeIdentity")
    try await fake.removeIdentity(id, stepUp: stepUp)
  }
  func appleLinkBegin(_ request: AppleBeginRequest, stepUp: String?) async throws -> AppleBeginResponse {
    try await hub.enter("appleLinkBegin")
    return try await fake.appleLinkBegin(request, stepUp: stepUp)
  }
  func stepUpPasskeyBegin() async throws -> StepUpBeginResponse {
    try await hub.enter("stepUpPasskeyBegin")
    return try await fake.stepUpPasskeyBegin()
  }
  func stepUpPasskeyFinish(_ request: StepUpFinishRequest) async throws -> StepUpResponse {
    try await hub.enter("stepUpPasskeyFinish")
    return try await fake.stepUpPasskeyFinish(request)
  }
  func stepUpAppleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    try await hub.enter("stepUpAppleBegin")
    return hub.numberedAppleBegin(try await fake.stepUpAppleBegin(request))
  }
  func stepUpAppleHandoff(_ request: AppleLinkHandoffRequest) async throws -> StepUpResponse {
    try await hub.enter("stepUpAppleHandoff")
    return try await fake.stepUpAppleHandoff(request)
  }
  func appleLinkNative(_ request: AppleLinkNativeRequest) async throws -> Identity {
    try await hub.enter("appleLinkNative")
    return try await fake.appleLinkNative(request)
  }
  func appleLinkHandoff(_ request: AppleLinkHandoffRequest) async throws -> Identity {
    try await hub.enter("appleLinkHandoff")
    return try await fake.appleLinkHandoff(request)
  }
  func endSession() async throws {
    try await hub.enter("endSession")
    try await fake.endSession()
  }
  func deleteAccount(stepUp: String?) async throws {
    try await hub.enter("deleteAccount")
    try await fake.deleteAccount(stepUp: stepUp)
  }
}

/// A secret store whose removals can be made to fail.
private actor FlakySecretStore: SecretStore {
  private var values: [SecretRef: String] = [:]
  private var failingRemovals = false
  func failRemovals(_ value: Bool) { failingRemovals = value }
  func put(_ ref: SecretRef, value: String) async throws { values[ref] = value }
  func read(_ ref: SecretRef) async throws -> String? { values[ref] }
  func remove(_ ref: SecretRef) async throws -> Bool {
    if failingRemovals { throw WorkspaceError(.internalError, "The secret store refused the removal.") }
    return values.removeValue(forKey: ref) != nil
  }
}

struct CommandRig {
  let coordinator: RunningCoordinator
  let client: WorkspaceClient
  let paths: PlatformPaths
  let secrets: any SecretStore
  let hub: CommandHub

  var accounts: AccountManager { coordinator.accounts }

  static func paths() throws -> PlatformPaths {
    let base = NSTemporaryDirectory() + "b4ac-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
  }

  static func start(
    paths: PlatformPaths? = nil, secrets: any SecretStore = MemorySecretStore(), hub: CommandHub? = nil,
    flavor: Flavor = .local, environment: [String: String]? = nil,
    adapterFactory: SessionService.AdapterFactory? = nil
  ) async throws -> CommandRig {
    let paths = try paths ?? Self.paths()
    let hub = hub ?? CommandHub()
    let outcome = try await Coordinator.start(
      options: CoordinatorOptions(
        paths: paths,
        environment: environment ?? [
          "PATH": "/nonexistent", "HOME": paths.dataDir, "B4APP_NODE_PATH": "/nonexistent/node",
          ExecutableLocator.fallbackOverrideVariable: "",
        ],
        secretStore: secrets, adapterFactory: adapterFactory, hubAPIFactory: { hub.api($0, $1) },
        hubLinkConnection: FakeHubLinkConnection(), powerAssertions: FakePowerAssertions(), flavor: flavor))
    guard case .running(let coordinator) = outcome else {
      throw WorkspaceError(.internalError, "expected running")
    }
    let client = try await UnixSocketTransport.client(path: paths.socketPath)
    return CommandRig(coordinator: coordinator, client: client, paths: paths, secrets: secrets, hub: hub)
  }

  func close() async {
    await client.close()
    await coordinator.close()
  }

  static func mutation(_ timeout: Duration = .seconds(60)) -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString, timeout: timeout)
  }

  /// Sign in as `session` with a passkey, through the coordinator.
  @discardableResult
  func signIn(
    _ session: AuthSession, assertion: JSONValue = ["id": "credential"]
  ) async throws
    -> AccountStatus.Result
  {
    await hub.fake.setSession(session)
    let begun = try await client.request(AccountPasskeyBegin.self, EmptyParams())
    return try await client.request(
      AccountPasskeyFinish.self,
      AccountPasskeyFinish.Params(ceremonyId: begun.ceremonyId, assertion: assertion),
      options: Self.mutation())
  }

  func logout(stopWork: Bool = false) async throws -> AccountStatus.Result {
    try await client.request(
      AccountLogout.self, AccountLogout.Params(stopWork: stopWork), options: Self.mutation(.seconds(60)))
  }

  func registry() throws -> AccountRegistry {
    try AccountRegistry(
      endpoint: paths.postgres, binDir: paths.postgres.binDir!,
      databaseName: AccountManager.registryDatabaseName(for: paths.postgres))
  }

  /// A thread written straight into the signed-in account's store.
  func addThread(_ id: String, kind: ConnectionKind = .claude) throws {
    let db = try accounts.scope().database
    if try db.connection(id: "c1") == nil {
      _ = try db.insertConnection(Connection(id: "c1", kind: kind, label: "Runtime", target: "/bin/runtime"))
    }
    _ = try db.insertThread(
      ConversationThread(
        id: id, connectionId: "c1", nativeThreadId: "native-\(id)", nativeScope: "me", title: "Thread \(id)"))
  }

  func accountEvents() async -> [String] {
    let log = coordinator.eventLog
    return (await log.replay(epoch: log.epoch, afterSequence: 0) ?? [])
      .filter { $0.event.kind == .accountChanged }
      .map { String(decoding: (try? JSONCoding.encoder.encode($0)) ?? Data(), as: UTF8.self) }
  }

  /// Run one statement on `database` of the rig's cluster.
  func execute(_ sql: String, _ arguments: [String?], database: String) throws {
    let lib = try LibPQ.load(binDir: paths.postgres.binDir!)
    let connection = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(paths.postgres.socketDir) port=\(paths.postgres.port) user=\(NSUserName()) dbname=\(database)"
    )
    _ = try connection.execute(sql, arguments)
  }

  func databaseExists(_ name: String) throws -> Bool {
    let lib = try LibPQ.load(binDir: paths.postgres.binDir!)
    let admin = try PostgresConnection(
      lib: lib,
      connectionString:
        "host=\(paths.postgres.socketDir) port=\(paths.postgres.port) user=\(NSUserName()) dbname=postgres")
    return !(try admin.execute("SELECT 1 FROM pg_database WHERE datname = $1", [name]).rows.isEmpty)
  }
}

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

private func sha256Hex(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Suite(.serialized, .timeLimit(.minutes(3))) struct AccountCommandTests {
  @Test func passkeyRoundTripThroughCoordinator() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    await rig.hub.fake.setSession(newcomer)

    let begun = try await rig.client.request(AccountPasskeyBegin.self, EmptyParams())
    #expect(begun.ceremonyId == "fake-ceremony")
    #expect(begun.authentication == ["publicKey": ["challenge": "fake"]])
    #expect(begun.registration == ["publicKey": ["challenge": "fake"]])

    let attestation: JSONValue = ["id": "cred", "response": ["attestationObject": "attestation-secret-0451"]]
    let status = try await rig.client.request(
      AccountPasskeyFinish.self,
      AccountPasskeyFinish.Params(ceremonyId: begun.ceremonyId, attestation: attestation),
      options: CommandRig.mutation())
    #expect(status.state == .needsOnboarding)
    #expect(status.account?.orgName == "My Org")
    #expect(status.account?.hubURL == localHub)

    // The hub got the attestation, for this Mac.
    let sent = try #require(await rig.hub.fake.passkeyFinishes.last)
    #expect(sent.ceremonyId == "fake-ceremony")
    #expect(sent.attestation == attestation && sent.assertion == nil)
    #expect(sent.device.platform == "macos")
    #expect(!sent.device.deviceName.isEmpty)

    // A registry row and a database for the new account.
    let registry = try rig.registry()
    defer { registry.close() }
    let row = try #require(try registry.find(hubURL: localHub, hubUserId: newcomer.userId!))
    #expect(row.active && row.needsOnboarding)
    #expect(row.deviceId == newcomer.deviceId)
    #expect(try rig.databaseExists(row.database))
    #expect(try rig.accounts.scope().database.hubLink()?.deviceId == newcomer.deviceId)

    let asked = try await rig.client.request(AccountStatus.self, EmptyParams())
    #expect(asked.state == .needsOnboarding)
    #expect(asked.account?.id == row.id)
    // Neither the response nor the token went anywhere a client can read.
    for event in await rig.accountEvents() {
      #expect(!event.contains("attestation-secret-0451"))
      #expect(!event.contains(newcomer.token))
    }
  }

  @Test func completeProfileMovesToSignedIn() async throws {
    let paths = try CommandRig.paths()
    let hub = CommandHub()
    let secrets = MemorySecretStore()
    let rig = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    try await rig.signIn(newcomer)

    // Out of range once trimmed: refused before the hub is asked.
    for bad in ["   ", String(repeating: "x", count: 201)] {
      let error = await #expect(throws: WorkspaceError.self) {
        _ = try await rig.client.request(
          AccountCompleteProfile.self, AccountCompleteProfile.Params(fullName: bad),
          options: CommandRig.mutation())
      }
      #expect(error?.code == .protocolInvalid)
    }
    #expect(await hub.fake.profiles.isEmpty)

    let status = try await rig.client.request(
      AccountCompleteProfile.self, AccountCompleteProfile.Params(fullName: "  Ann Example  "),
      options: CommandRig.mutation())
    #expect(status.state == .signedIn)
    #expect(status.account?.displayName == "Ann Example")
    #expect(await hub.fake.profiles == [ProfileRequest(fullName: "Ann Example")])
    let registry = try rig.registry()
    defer { registry.close() }
    let row = try #require(try registry.active())
    #expect(row.displayName == "Ann Example")
    #expect(!row.needsOnboarding)

    // A restart keeps it.
    await rig.close()
    let again = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await again.close() } }
    #expect(try await again.client.request(AccountStatus.self, EmptyParams()).state == .signedIn)
  }

  /// Ruling 5: a restart mid-onboarding comes back in onboarding at once, while `/v1/me` has not
  /// answered, and never says "signed out" or "signed in" on the way; `/v1/me` then corrects it.
  @Test func aRestartMidOnboardingStaysInOnboarding() async throws {
    let paths = try CommandRig.paths()
    let hub = CommandHub()
    let secrets = MemorySecretStore()
    let first = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    try await first.signIn(newcomer)
    await first.close()

    // `/v1/me` is asked at the restore and gets no answer.
    hub.stick()
    let second = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await second.close() } }
    #expect(try await second.client.request(AccountStatus.self, EmptyParams()).state == .needsOnboarding)
    // Nothing was published on the way: no "signed out", no "signed in".
    #expect(await second.accountEvents().isEmpty)

    // The person finished onboarding on another device; the answer, when it comes, says so.
    _ = try await hub.fake.setProfile(ProfileRequest(fullName: "New Person"))
    hub.unstick()
    try await eventually("the /v1/me answer") { await second.accounts.status().state == .signedIn }
    let events = await second.accountEvents()
    #expect(events.count == 1)
    #expect(events.allSatisfy { $0.contains("signedIn") && !$0.contains("signedOut") })
  }

  @Test func logoutRefusedWithWorkRunning() async throws {
    let adapters = RunningAdapters()
    let rig = try await CommandRig.start(adapterFactory: { _, _, _, _ in adapters.make() })
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    try rig.addThread("busy")
    let turn = try await rig.client.request(
      TurnSend.self, TurnSend.Params(threadId: "busy", text: "go"), options: CommandRig.mutation()
    ).turn
    #expect(turn.status == .running)
    let ref = try #require(try rig.accounts.scope().account.tokenRef.flatMap(SecretRef.init(rawValue:)))

    let error = await #expect(throws: WorkspaceError.self) { _ = try await rig.logout(stopWork: false) }
    #expect(error?.code == .workRunning)
    let work = try #require(try error?.details?["work"]?.decode(WorkspaceActiveWork.Result.self))
    #expect(work.turns.map(\.turnId) == [turn.id])
    #expect(work.turns.first?.threadTitle == "Thread busy")

    // Nothing changed.
    #expect(await rig.accounts.status().state == .signedIn)
    #expect(try await rig.secrets.read(ref) == ann.token)
    #expect(await rig.hub.fake.endSessionCalls == 0)
    #expect(adapters.interrupts == 0)
    #expect(try rig.accounts.scope().database.turn(id: turn.id)?.status == .running)
    #expect(try await rig.client.request(ThreadList.self, ThreadList.Params()).threads.count == 1)
  }

  @Test func logoutStopWorkStopsTurnsAndServers() async throws {
    let base = NSTemporaryDirectory() + "b4al-\(UUID().uuidString.prefix(8))"
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var environment = ProcessInfo.processInfo.environment
    environment["B4APP_NODE_PATH"] = fakeNodePath()
    let adapters = RunningAdapters()
    let rig = try await CommandRig.start(
      paths: paths, environment: environment, adapterFactory: { _, _, _, _ in adapters.make() })
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    try rig.addThread("busy")
    let turn = try await rig.client.request(
      TurnSend.self, TurnSend.Params(threadId: "busy", text: "go"), options: CommandRig.mutation()
    ).turn
    let server = try await rig.client.request(
      ServerAdd.self, ServerAdd.Params(projectPath: try FakeB4Project.make(root: base + "/proj")),
      options: CommandRig.mutation()
    ).server
    let started = try await rig.client.request(
      ServerStart.self, ServerRef(serverId: server.id), options: CommandRig.mutation(.seconds(150))
    ).server
    let pid = try #require(started.pid)
    _ = try await rig.client.request(
      DraftSave.self, DraftSave.Params(threadId: "busy", text: "a thought for later"),
      options: CommandRig.mutation())
    let database = try rig.accounts.scope().account.database

    let status = try await rig.logout(stopWork: true)
    #expect(status.state == .signedOut)
    #expect(status.account == nil)
    #expect(adapters.interrupts == 1)
    #expect(!ProcessInspector.isAlive(pid: pid), "the managed server outlived the log-out")

    var endpoint = paths.postgres
    endpoint.database = database
    let reopened = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    defer { try? reopened.close() }
    let after = try #require(try reopened.turn(id: turn.id))
    #expect(after.status == .terminal && after.outcome == .cancelled)
    #expect(try reopened.localServer(id: server.id)?.health == .stopped)
    // The draft was kept and pushed.
    #expect(try reopened.draft(threadId: "busy")?.text == "a thought for later")
    #expect(try reopened.unsyncedChangeCount() == 0)
    #expect(await rig.hub.fake.stored.contains { $0.table == "drafts" })
  }

  @Test func logoutPushesThenEndsSession() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let scope = try rig.accounts.scope()
    let ref = try #require(scope.account.tokenRef.flatMap(SecretRef.init(rawValue:)))
    try rig.addThread("unsynced")
    let atEnd = Mutex<Int?>(nil)
    rig.hub.onEndSession { atEnd.withLock { $0 = try? scope.database.unsyncedChangeCount() } }

    let status = try await rig.logout()
    #expect(status.state == .signedOut)
    // Everything was pushed before the session was ended, and it was ended once.
    #expect(atEnd.withLock { $0 } == 0)
    #expect(await rig.hub.fake.endSessionCalls == 1)
    let calls = rig.hub.calls
    let lastPush = try #require(calls.lastIndex(of: "push"))
    let ended = try #require(calls.lastIndex(of: "endSession"))
    #expect(lastPush < ended)
    #expect(await rig.hub.fake.stored.contains { $0.rowId == "unsynced" })
    // The token is forgotten, and nothing was left open.
    #expect(try await rig.secrets.read(ref) == nil)
    let registry = try rig.registry()
    defer { registry.close() }
    let row = try #require(try registry.all().first)
    #expect(row.tokenRef == nil && !row.active && !row.hubSessionLeftOpen)
    #expect(rig.accounts.current == nil)
  }

  @Test func logoutBoundedWhenHubDown() async throws {
    // The standard bounds keep a log-out, close included, within 21 s whatever the hub does.
    let standard = AccountManager.LogoutTimeouts.standard
    #expect(standard.total <= .seconds(21))
    #expect(standard.work >= .milliseconds(9500) && standard.push >= .milliseconds(9500))

    let paths = try CommandRig.paths()
    let hub = CommandHub()
    let secrets = MemorySecretStore()
    let rig = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    try await rig.signIn(ann)
    let row = try rig.accounts.scope().account
    let ref = try #require(row.tokenRef.flatMap(SecretRef.init(rawValue:)))
    try rig.addThread("stuck")
    // Shortened bounds, so the suite does not wait out the standard 21 s.
    let short = AccountManager.LogoutTimeouts(
      work: .seconds(2), push: .seconds(2), endSessionFloor: .milliseconds(300), close: .seconds(1))
    await rig.accounts.setLogoutTimeouts(short)
    hub.setHanging(true)

    let clock = ContinuousClock()
    var status: AccountStatus.Result?
    let elapsed = try await clock.measure { status = try await rig.logout() }
    #expect(elapsed < .seconds(21))
    #expect(elapsed < short.total + .seconds(1), "the shortened bounds were not honoured: \(elapsed)")
    #expect(status?.state == .signedOut)
    #expect(try await secrets.read(ref) == nil)
    #expect(rig.accounts.current == nil)
    let registry = try rig.registry()
    defer { registry.close() }
    let stored = try #require(try registry.all().first { $0.id == row.id })
    #expect(stored.tokenRef == nil && stored.hubSessionLeftOpen)
    #expect(await hub.fake.endSessionCalls == 0)

    // A restart between the failed log-out and the next sign-in keeps the record.
    await rig.close()
    hub.setHanging(false)
    let again = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await again.close() } }
    #expect(try await again.client.request(AccountStatus.self, EmptyParams()).notice == nil)
    try await again.signIn(ann)
    #expect(try again.accounts.scope().account.id == row.id)
    #expect(try await again.client.request(HubStatus.self, EmptyParams()).notice == leftOpenNotice)
  }

  /// Ruling for I2: the notice stays, in `account.status` and `hub.status`, across reads and restarts,
  /// until `account.dismissNotice`.
  @Test func aLeftOpenNoticeLastsUntilDismissed() async throws {
    let paths = try CommandRig.paths()
    let hub = CommandHub()
    let secrets = MemorySecretStore()
    let rig = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    try await rig.signIn(ann)
    await rig.accounts.setLogoutTimeouts(
      AccountManager.LogoutTimeouts(
        work: .seconds(1), push: .milliseconds(500), endSessionFloor: .milliseconds(200), close: .seconds(1)))
    hub.setHanging(true)
    _ = try await rig.logout()
    hub.setHanging(false)
    try await rig.signIn(ann)

    for _ in 0..<3 {
      #expect(try await rig.client.request(HubStatus.self, EmptyParams()).notice == leftOpenNotice)
      #expect(try await rig.client.request(AccountStatus.self, EmptyParams()).notice == leftOpenNotice)
    }
    await rig.close()

    let again = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    #expect(try await again.client.request(AccountStatus.self, EmptyParams()).notice == leftOpenNotice)
    #expect(try await again.client.request(HubStatus.self, EmptyParams()).notice == leftOpenNotice)
    let dismissed = try await again.client.request(
      AccountDismissNotice.self, EmptyParams(), options: CommandRig.mutation())
    #expect(dismissed.notice == nil && dismissed.state == .signedIn)
    #expect(try await again.client.request(HubStatus.self, EmptyParams()).notice == nil)
    #expect(await again.accountEvents().last?.contains("notice") == false)
    await again.close()

    let third = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await third.close() } }
    #expect(try await third.client.request(AccountStatus.self, EmptyParams()).notice == nil)
    #expect(try await third.client.request(HubStatus.self, EmptyParams()).notice == nil)
  }

  /// I1: the whole log-out, close included, stays inside its bounds when a runtime ignores its interrupt
  /// and its dispose, and the hub never answers and ignores cancellation (the pull loop too).
  @Test func logoutIsBoundedWhenTheRuntimeAndTheHubIgnoreCancellation() async throws {
    let adapters = StubbornAdapters()
    let rig = try await CommandRig.start(adapterFactory: { _, _, _, _ in adapters.make() })
    try await rig.signIn(ann)
    try rig.addThread("busy")
    _ = try await rig.client.request(
      TurnSend.self, TurnSend.Params(threadId: "busy", text: "go"), options: CommandRig.mutation())
    let row = try rig.accounts.scope().account
    let ref = try #require(row.tokenRef.flatMap(SecretRef.init(rawValue:)))
    let short = AccountManager.LogoutTimeouts(
      work: .seconds(2), push: .seconds(1), endSessionFloor: .milliseconds(300), close: .seconds(1))
    await rig.accounts.setLogoutTimeouts(short)
    rig.hub.stick()

    let clock = ContinuousClock()
    var status: AccountStatus.Result?
    let elapsed = try await clock.measure { status = try await rig.logout(stopWork: true) }
    #expect(elapsed < short.total + .seconds(1), "the log-out took \(elapsed)")
    #expect(status?.state == .signedOut)
    #expect(adapters.interrupts == 1)
    #expect(adapters.disposes == 1)
    // Signed out and recorded, although the close never finished.
    #expect(try await rig.secrets.read(ref) == nil)
    let registry = try rig.registry()
    defer { registry.close() }
    let stored = try #require(try registry.all().first { $0.id == row.id })
    #expect(stored.tokenRef == nil && !stored.active && stored.hubSessionLeftOpen)

    rig.hub.unstick()
    adapters.release()
    await rig.close()
  }

  /// M8: remote B4 runs are detached, never cancelled; they still count as work to confirm, marked as
  /// running elsewhere.
  @Test func logoutDetachesRemoteRunsAndInterruptsLocalOnes() async throws {
    let adapters = RunningAdapters()
    let rig = try await CommandRig.start(adapterFactory: { _, _, _, _ in adapters.make() })
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let db = try rig.accounts.scope().database
    _ = try db.insertConnection(
      Connection(id: "local", kind: .claude, label: "Claude", target: "/bin/claude"))
    _ = try db.insertConnection(
      Connection(
        id: "remote", kind: .b4, label: "Remote B4", target: "https://b4.example.com",
        routeKey: "/chat#agent",
        b4Mode: .remote))
    for (thread, connection) in [("mine", "local"), ("theirs", "remote")] {
      _ = try db.insertThread(
        ConversationThread(
          id: thread, connectionId: connection, nativeThreadId: "n-\(thread)", nativeScope: "me",
          title: thread))
      _ = try await rig.client.request(
        TurnSend.self, TurnSend.Params(threadId: thread, text: "go"), options: CommandRig.mutation())
    }
    let remoteTurn = try #require(try db.activeTurn(threadId: "theirs"))
    let database = try rig.accounts.scope().account.database

    let refused = await #expect(throws: WorkspaceError.self) { _ = try await rig.logout(stopWork: false) }
    let work = try #require(try refused?.details?["work"]?.decode(WorkspaceActiveWork.Result.self))
    #expect(work.localTurns.map(\.threadId) == ["mine"])
    #expect(work.remoteTurns.map(\.threadId) == ["theirs"])
    #expect(refused?.message.contains("continues there") == true)
    // A refused log-out admits work again.
    _ = try await rig.client.request(
      DraftSave.self, DraftSave.Params(threadId: "mine", text: "still here"), options: CommandRig.mutation())

    _ = try await rig.logout(stopWork: true)
    #expect(adapters.interrupts == 1, "only the local runtime is interrupted")
    var endpoint = rig.paths.postgres
    endpoint.database = database
    let reopened = try WorkspaceDatabase(endpoint: endpoint, binDir: endpoint.binDir!)
    defer { try? reopened.close() }
    #expect(try reopened.turn(id: remoteTurn.id)?.status != .terminal)
  }

  /// M6: a server whose start is still in flight is stopped by a log-out, within its bounds.
  @Test func logoutStopsAServerStartInFlight() async throws {
    let base = NSTemporaryDirectory() + "b4af-\(UUID().uuidString.prefix(8))"
    let paths = try EphemeralPostgres.paths(runtimeDir: base + "/rt", dataDir: base + "/data")
    var environment = ProcessInfo.processInfo.environment
    environment["B4APP_NODE_PATH"] = fakeNodePath()
    let rig = try await CommandRig.start(paths: paths, environment: environment)
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let project = try FakeB4Project.make(root: base + "/proj")
    try "FAKE_B4_READY_DELAY=60\n".write(toFile: project + "/.env", atomically: true, encoding: .utf8)
    let server = try await rig.client.request(
      ServerAdd.self, ServerAdd.Params(projectPath: project), options: CommandRig.mutation()
    ).server
    let scope = try rig.accounts.scope()
    let start = Task {
      try await rig.client.request(
        ServerStart.self, ServerRef(serverId: server.id), options: CommandRig.mutation(.seconds(150)))
    }
    try await eventually("the server's process") {
      (try? scope.database.localServer(id: server.id))??.pid != nil
    }
    let pid = try #require(try scope.database.localServer(id: server.id)?.pid)
    await rig.accounts.setLogoutTimeouts(
      AccountManager.LogoutTimeouts(
        work: .seconds(6), push: .seconds(1), endSessionFloor: .milliseconds(300), close: .seconds(1)))

    // Another connection: the socket answers one connection's commands in order, so the log-out would
    // otherwise queue behind the start.
    let other = try await UnixSocketTransport.client(path: rig.paths.socketPath)
    defer { Task { await other.close() } }
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
      _ = try await other.request(
        AccountLogout.self, AccountLogout.Params(stopWork: true), options: CommandRig.mutation())
    }
    #expect(elapsed < .seconds(10), "the log-out took \(elapsed)")
    // The start answers (refused), rather than waiting out its readiness.
    let waited = await clock.measure { _ = await start.result }
    #expect(waited < .seconds(10), "the start answered after \(waited)")
    let started = await start.result
    #expect(throws: (any Error).self) { try started.get() }
    try await eventually("the starting server to be gone") { !ProcessInspector.isAlive(pid: pid) }
  }

  /// M7: a row made with another spelling of the same hub is the same account and offers its device.
  @Test func aHubSpelledWithASlashIsTheSameHub() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let row = try rig.accounts.scope().account
    _ = try await rig.logout()
    // As `hub join http://localhost:8080/` would have stored it.
    try rig.execute(
      "UPDATE \"accounts\" SET \"hub_url\" = $1 WHERE \"id\" = $2", [localHub + "/", row.id],
      database: AccountManager.registryDatabaseName(for: rig.paths.postgres))

    try await rig.signIn(ann)
    #expect(await rig.hub.fake.passkeyFinishes.last?.device.deviceId == devAnn)
    #expect(try rig.accounts.scope().account.id == row.id)
    let registry = try rig.registry()
    defer { registry.close() }
    #expect(try registry.all().count == 1)
  }

  @Test func deleteDropsDatabaseAndRow() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let annRow = try rig.accounts.scope().account
    _ = try await rig.logout()
    // Bob's account is the second on this Mac, so it has a database of its own.
    try await rig.signIn(bob)
    let bobRow = try rig.accounts.scope().account
    #expect(bobRow.database == AccountRegistry.databaseName(id: bobRow.id))
    try rig.addThread("bob-thread")

    let status = try await rig.client.request(
      AccountDelete.self, AccountStepUpParams(), options: CommandRig.mutation())
    #expect(status.state == .signedOut)
    #expect(await rig.hub.fake.deleteAccountCalls == 1)
    #expect(!(try rig.databaseExists(bobRow.database)))
    let registry = try rig.registry()
    defer { registry.close() }
    #expect(try registry.all().map(\.id) == [annRow.id])
    #expect(status.known.map(\.id) == [annRow.id])
    #expect(try rig.databaseExists(annRow.database))
  }

  @Test func aRefusedDeleteChangesNothing() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    try rig.addThread("kept")
    let row = try rig.accounts.scope().account
    rig.hub.fail("deleteAccount", with: hubError("shared_org", status: 409))

    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        AccountDelete.self, AccountStepUpParams(), options: CommandRig.mutation())
    }
    #expect(error?.code == .sharedOrg)
    #expect(await rig.accounts.status().state == .signedIn)
    #expect(try rig.accounts.scope().account.id == row.id)
    #expect(try rig.databaseExists(row.database))
    #expect(try await rig.client.request(ThreadList.self, ThreadList.Params()).threads.map(\.id) == ["kept"])
  }

  @Test func appleStartAndFinishSignIn() async throws {
    let rig = try await CommandRig.start(flavor: .beta)
    defer { Task { await rig.close() } }
    await rig.hub.fake.setSession(newcomer)

    // A second start replaces the first ceremony: its verifier is the one used.
    _ = try await rig.client.request(AccountAppleStart.self, EmptyParams())
    await rig.hub.fake.setAppleBegin(AppleBeginResponse(ceremonyId: "apple-2", nonce: "n2"))
    let started = try await rig.client.request(AccountAppleStart.self, EmptyParams())
    #expect(started.callbackScheme == "b4app-beta")
    #expect(started.url == "https://hub.test.b4.run/v1/auth/apple/start?ceremony=apple-2")
    let begins = await rig.hub.fake.appleBegins
    #expect(begins.count == 2)
    let begin = try #require(begins.last)
    #expect(begin.scheme == "b4app-beta")
    let hash = try #require(begin.verifierHash)
    #expect(hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(begins[0].verifierHash != hash)

    let status = try await rig.client.request(
      AccountAppleFinish.self, AccountAppleFinish.Params(handoff: "handoff-secret-7731"),
      options: CommandRig.mutation())
    #expect(status.state == .needsOnboarding)
    let sent = try #require(await rig.hub.fake.handoffs.last)
    #expect(sent.handoff == "handoff-secret-7731")
    #expect((43...128).contains(sent.verifier.count))
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    #expect(sent.verifier.allSatisfy { unreserved.contains($0) })
    #expect(sha256Hex(sent.verifier) == hash)
    #expect(sent.device.platform == "macos")
    #expect(try rig.accounts.scope().account.hubURL == "https://hub.test.b4.run")

    // The ceremony is spent: a stray redirect is dropped without asking the hub.
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        AccountAppleFinish.self, AccountAppleFinish.Params(handoff: "handoff-secret-7731"),
        options: CommandRig.mutation())
    }
    #expect(error?.code == .ceremonyExpired)
    #expect(error?.message.contains("handoff-secret-7731") == false)
    #expect(await rig.hub.fake.handoffs.count == 1)
    for event in await rig.accountEvents() {
      #expect(!event.contains("handoff-secret-7731") && !event.contains(sent.verifier))
    }
  }

  @Test func appleFinishWithoutACeremonyIsDropped() async throws {
    let rig = try await CommandRig.start(flavor: .beta)
    defer { Task { await rig.close() } }
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        AccountAppleFinish.self, AccountAppleFinish.Params(handoff: "stray"), options: CommandRig.mutation())
    }
    #expect(error?.code == .ceremonyExpired)
    #expect(await rig.hub.fake.handoffs.isEmpty)
    #expect(!rig.hub.calls.contains("handoff"))
  }

  @Test func appleIsUnsupportedOnTheLocalFlavour() async throws {
    let rig = try await CommandRig.start(flavor: .local)
    defer { Task { await rig.close() } }
    let start = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(AccountAppleStart.self, EmptyParams())
    }
    #expect(start?.code == .unsupportedCapability)
    #expect(start?.message.contains("local") == true)
    let finish = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        AccountAppleFinish.self, AccountAppleFinish.Params(handoff: "h"), options: CommandRig.mutation())
    }
    #expect(finish?.code == .unsupportedCapability)
    #expect(await rig.hub.fake.appleBegins.isEmpty)
  }

  /// Task 14: Connect Apple ID on the Mac. The coordinator begins the link with its own verifier's hash,
  /// the app shows Apple's page, and the handoff comes back to be redeemed once with that verifier.
  @Test func appleLinkStartAndFinishAddAnAppleID() async throws {
    let rig = try await CommandRig.start(flavor: .beta)
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    await rig.hub.fake.setAppleBegin(AppleBeginResponse(ceremonyId: "link-1", nonce: "n1"))
    let started = try await rig.client.request(AccountAppleLinkStart.self, AccountStepUpParams())
    #expect(started.callbackScheme == "b4app-beta")
    #expect(started.url == "https://hub.test.b4.run/v1/auth/apple/start?ceremony=link-1")
    let begin = try #require(await rig.hub.fake.appleLinkBegins.last)
    #expect(begin.scheme == "b4app-beta")
    let hash = try #require(begin.verifierHash)
    // A sign-in ceremony is not a link's, and a link's is not a sign-in's.
    #expect(await rig.hub.fake.appleBegins.isEmpty)

    let linked = try await rig.client.request(
      AccountAppleLinkFinish.self, AccountAppleLinkFinish.Params(handoff: "link-handoff-5521"),
      options: CommandRig.mutation())
    #expect(linked.identity.kind == "apple")
    let sent = try #require(await rig.hub.fake.appleLinkHandoffs.last)
    #expect(sent.handoff == "link-handoff-5521")
    #expect(sha256Hex(sent.verifier) == hash)
    // Still signed in to the same account.
    #expect(try await rig.client.request(AccountStatus.self, EmptyParams()).account?.orgName == "Ann's Org")

    // Single use: the same (or a stray) handoff is dropped without asking the hub.
    let again = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        AccountAppleLinkFinish.self, AccountAppleLinkFinish.Params(handoff: "link-handoff-5521"),
        options: CommandRig.mutation())
    }
    #expect(again?.code == .ceremonyExpired)
    #expect(again?.message.contains("link-handoff-5521") == false)
    #expect(await rig.hub.fake.appleLinkHandoffs.count == 1)

    // The account has an Apple ID now: the hub refuses another, and the refusal keeps its code.
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(AccountAppleLinkStart.self, AccountStepUpParams())
    }
    #expect(refused?.code == .appleLinked)
  }

  /// D-135 on the Mac: an Apple-only account confirms on Apple's web flow. The coordinator begins the
  /// step-up with its own verifier's hash and redeems the handoff the change brings with that verifier,
  /// once.
  @Test func anAppleStepUpRedeemsItsHandoffWithTheKeptVerifier() async throws {
    let rig = try await CommandRig.start(flavor: .beta)
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    await rig.hub.fake.setIdentities([
      Identity(id: "a1", kind: "apple", name: "x7k2@privaterelay.appleid.com", createdAt: "2026-11-01")
    ])
    await rig.hub.fake.setAppleBegin(AppleBeginResponse(ceremonyId: "step-1", nonce: "n1"))
    let started = try await rig.client.request(AccountStepUpAppleStart.self, EmptyParams())
    #expect(started.callbackScheme == "b4app-beta")
    #expect(started.url == "https://hub.test.b4.run/v1/auth/apple/start?ceremony=step-1")
    let begin = try #require(await rig.hub.fake.stepUpAppleBegins.last)
    #expect(begin.scheme == "b4app-beta")
    let hash = try #require(begin.verifierHash)
    #expect(await rig.hub.fake.appleLinkBegins.isEmpty)

    let confirmed = AccountStepUp.appleWeb(handoff: "step-handoff-7")
    let begun = try await rig.client.request(
      AccountAddPasskeyBegin.self, AccountStepUpParams(stepUp: confirmed))
    #expect(begun.ceremonyId == "fake-add-ceremony")
    let sent = try #require(await rig.hub.fake.stepUpAppleHandoffs.last)
    #expect(sent.handoff == "step-handoff-7")
    #expect(sha256Hex(sent.verifier) == hash)

    // Single use: the same handoff again is dropped without asking the hub.
    let again = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(AccountAddPasskeyBegin.self, AccountStepUpParams(stepUp: confirmed))
    }
    #expect(again?.code == .ceremonyExpired)
    #expect(again?.message.contains("step-handoff-7") == false)
    #expect(await rig.hub.fake.stepUpAppleHandoffs.count == 1)
  }

  @Test func appleLinkNeedsAnAccountAndApple() async throws {
    let rig = try await CommandRig.start(flavor: .beta)
    defer { Task { await rig.close() } }
    let signedOut = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(AccountAppleLinkStart.self, AccountStepUpParams())
    }
    #expect(signedOut?.code == .signedOut)
    let local = try await CommandRig.start(flavor: .local)
    defer { Task { await local.close() } }
    try await local.signIn(ann)
    let unsupported = await #expect(throws: WorkspaceError.self) {
      _ = try await local.client.request(AccountAppleLinkStart.self, AccountStepUpParams())
    }
    #expect(unsupported?.code == .unsupportedCapability)
    #expect(await local.hub.fake.appleLinkBegins.isEmpty)
  }

  /// Ruling 3: the Mac cannot know whose passkey is coming, so it offers the hub every device it has on
  /// that hub; another hub's devices are not sent.
  @Test func aSignInOffersEveryKnownDeviceOfThisHub() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    _ = try await rig.logout()
    try await rig.signIn(bob)
    _ = try await rig.logout()
    let registry = try rig.registry()
    defer { registry.close() }
    let other = AccountRegistry.newId()
    try registry.insert(
      AccountRow(
        id: other, hubURL: "https://elsewhere.example.com", hubUserId: "u-x",
        deviceId: "0197eeee-0000-7000-8000-0000000000e1",
        database: AccountRegistry.databaseName(id: other), displayName: "X", orgName: "X"))

    try await rig.signIn(acme)
    let device = try #require(await rig.hub.fake.passkeyFinishes.last?.device)
    let offered = Set([device.deviceId].compactMap { $0 } + (device.candidateDeviceIds ?? []))
    #expect(offered == [devAnn, devBob])
    // The most recent account's device comes first, as `deviceId`, which an older hub understands.
    #expect(device.deviceId == devBob)
  }

  /// X3: a Mac that logged out and rejoins with an enrollment code (`hub join`) offers the hub the
  /// devices it has there, as a sign-in does, so the hub reuses its device and the rows it synced keep
  /// their owner. Another hub's devices are not sent.
  @Test func hubJoinOffersEveryKnownDeviceOfThisHub() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    _ = try await rig.logout()
    try await rig.signIn(bob)
    _ = try await rig.logout()
    let registry = try rig.registry()
    defer { registry.close() }
    let other = AccountRegistry.newId()
    try registry.insert(
      AccountRow(
        id: other, hubURL: "https://elsewhere.example.com", hubUserId: "u-x",
        deviceId: "0197eeee-0000-7000-8000-0000000000e1",
        database: AccountRegistry.databaseName(id: other), displayName: "X", orgName: "X"))
    let before = try registry.all().count

    // The hub reuses Ann's device for her code.
    await rig.hub.fake.addEnrollmentCode(
      "JOIN2345",
      EnrollResponse(deviceId: devAnn, token: "tok-ann-again-secret", org: ann.org, user: ann.user))
    await rig.hub.fake.setUserId(ann.userId)
    _ = try await rig.accounts.join(url: localHub, code: "JOIN2345", deviceName: "Brian's Mac")

    let request = try #require(await rig.hub.fake.enrollRequests.last)
    #expect(request.deviceName == "Brian's Mac")
    #expect(request.platform == "macos")
    // The most recent account's device first, as `deviceId`; the rest as candidates.
    #expect(request.deviceId == devBob)
    #expect(request.candidateDeviceIds == [devAnn])
    // Ann's account is signed in again on the same row: no new account, the same device.
    let rows = try registry.all()
    #expect(rows.count == before)
    #expect(rows.first { $0.hubUserId == ann.userId }?.deviceId == devAnn)
    #expect(try rig.accounts.scope().account.deviceId == devAnn)
  }

  /// Ruling 3 again: a joined `workspace` adopted before the hub ever named its user is claimed by a
  /// passkey sign-in that the hub answers on that device.
  @Test func anAdoptedPlaceholderIsClaimedByAPasskeySignIn() async throws {
    let paths = try CommandRig.paths()
    let secrets = MemorySecretStore()
    let db = try WorkspaceDatabase(endpoint: paths.postgres, binDir: paths.postgres.binDir!)
    let tokenRef = SecretRef.make()
    try await secrets.put(tokenRef, value: "tok-old-secret")
    try db.saveHubLink(
      WorkspaceDatabase.HubLink(
        url: localHub, deviceId: devMac, deviceName: "Test Mac", tokenRef: tokenRef.rawValue,
        orgSlug: "acme", username: "brian", joinedAt: Timestamp.now()))
    _ = try db.insertConnection(Connection(id: "c1", kind: .claude, label: "Claude", target: "/bin/claude"))
    _ = try db.insertThread(
      ConversationThread(
        id: "joined", connectionId: "c1", nativeThreadId: "n1", nativeScope: "me", title: "J"))
    try db.close()
    let hub = CommandHub()
    hub.setHanging(true)
    let rig = try await CommandRig.start(paths: paths, secrets: secrets, hub: hub)
    defer { Task { await rig.close() } }
    let adopted = try rig.accounts.scope().account
    #expect(adopted.hubUserId == "device:" + devMac)
    await rig.accounts.signOut(reason: nil)

    hub.setHanging(false)
    try await rig.signIn(acme)
    let device = try #require(await hub.fake.passkeyFinishes.last?.device)
    #expect(device.deviceId == devMac)
    let claimed = try rig.accounts.scope().account
    #expect(claimed.id == adopted.id)
    #expect(claimed.hubUserId == acme.userId)
    #expect(
      try await rig.client.request(ThreadList.self, ThreadList.Params()).threads.map(\.id) == ["joined"])
  }

  @Test func accountCommandsThatNeedAnAccountAnswerSignedOut() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    #expect(try await rig.client.request(AccountStatus.self, EmptyParams()).state == .signedOut)
    let scoped: [WorkspaceProtocol.Method] = [
      .accountCompleteProfile, .accountLogout, .accountIdentities, .accountAddPasskeyBegin,
      .accountAddPasskeyFinish, .accountRemoveIdentity, .accountDelete,
    ]
    for method in scoped {
      let line =
        #"{"protocolVersion":1,"kind":"command","requestId":"r","operationId":"\#(UUID().uuidString)","method":"\#(method.rawValue)","params":{"fullName":"A","ceremonyId":"c","attestation":{},"identityId":"i"}}"#
      let response = await rig.coordinator.router.dispatch(line: Data(line.utf8))
      #expect(response.error?.code == .signedOut, "\(method.rawValue)")
      #expect(response.error?.message == signedOutMessage, "\(method.rawValue)")
    }
    #expect(rig.hub.calls.filter { $0 != "pull" }.isEmpty)
  }

  @Test func identitiesAreListedAddedAndRemoved() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let first = Identity(id: "i1", kind: "passkey", name: "Ann", createdAt: "2026-11-01")
    await rig.hub.fake.setIdentities([first])

    let listed = try await rig.client.request(AccountIdentities.self, EmptyParams())
    #expect(listed.identities.map(\.id) == ["i1"])
    #expect(listed.identities.first?.kind == "passkey")
    // Unconfirmed, the hub asks for a step-up, and the code and the methods come through.
    let unconfirmed = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(AccountAddPasskeyBegin.self, AccountStepUpParams())
    }
    #expect(unconfirmed?.code == .stepUpRequired)
    #expect(unconfirmed?.details?["methods"] == ["passkey"])
    // The app confirms with a passkey; the coordinator finishes the step-up and makes the change in
    // one command, so the grant never reaches the app.
    let options = try await rig.client.request(AccountStepUpBegin.self, EmptyParams())
    #expect(options.ceremonyId == "fake-step-up-ceremony")
    let confirmed = AccountStepUp.passkey(ceremonyId: options.ceremonyId, assertion: ["id": "i1"])
    let begun = try await rig.client.request(
      AccountAddPasskeyBegin.self, AccountStepUpParams(stepUp: confirmed))
    #expect(begun.ceremonyId == "fake-add-ceremony")
    #expect(await rig.hub.fake.presentedStepUps == [nil, "fake-step-up-1"])
    #expect(
      await rig.hub.fake.stepUpFinishes == [
        StepUpFinishRequest(ceremonyId: options.ceremonyId, assertion: ["id": "i1"])
      ])
    let added = try await rig.client.request(
      AccountAddPasskeyFinish.self,
      AccountAddPasskeyFinish.Params(ceremonyId: begun.ceremonyId, attestation: ["id": "new"]),
      options: CommandRig.mutation()
    ).identity
    #expect(added.kind == "passkey")
    let left = try await rig.client.request(
      AccountRemoveIdentity.self, AccountRemoveIdentity.Params(identityId: added.id, stepUp: confirmed),
      options: CommandRig.mutation())
    #expect(left.identities.map(\.id) == ["i1"])
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(
        AccountRemoveIdentity.self, AccountRemoveIdentity.Params(identityId: "i1"),
        options: CommandRig.mutation())
    }
    #expect(error?.code == .lastIdentity)
  }

  @Test func aRefusedFinishEchoesNoSecret() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    rig.hub.fail("passkeyFinish", with: hubError("credential_rejected", status: 401))
    let error = await #expect(throws: WorkspaceError.self) {
      try await rig.signIn(ann, assertion: ["id": "c", "response": ["signature": "assertion-secret-9157"]])
    }
    #expect(error?.code == .credentialRejected)
    let encoded = String(decoding: try JSONCoding.encoder.encode(error), as: UTF8.self)
    #expect(!encoded.contains("assertion-secret-9157"))
    #expect(await rig.accounts.status().state == .signedOut)
    let registry = try rig.registry()
    defer { registry.close() }
    #expect(try registry.all().isEmpty)
  }

  /// Carried from Task 9's review: `hub leave` signs out even when the leave fails after the pull and
  /// the link have stopped.
  @Test func hubLeaveSignsOutWhenTheLeaveFails() async throws {
    let secrets = FlakySecretStore()
    let rig = try await CommandRig.start(secrets: secrets)
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    await secrets.failRemovals(true)
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.client.request(HubLeave.self, EmptyParams(), options: CommandRig.mutation())
    }
    #expect(error != nil)
    #expect(rig.accounts.current == nil)
    #expect(await rig.accounts.status().state == .signedOut)
    let registry = try rig.registry()
    defer { registry.close() }
    #expect(try registry.active() == nil)
  }
}

// MARK: - The CLI

/// The `agent-workspace` binary this package built.
private func cliPath(file: StaticString = #filePath) -> String {
  URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/agent-workspace").path
}

/// Run the CLI against `paths`' coordinator (never spawning one), returning its exit status and output.
private func runCLI(
  _ arguments: [String], paths: PlatformPaths
) async throws -> (
  status: Int32, stdout: String, stderr: String
) {
  let path = cliPath()
  guard FileManager.default.isExecutableFile(atPath: path) else {
    throw WorkspaceError(.missingExecutable, "Build the package first: \(path) is missing.")
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = arguments
  process.environment = [
    "B4APP_RUNTIME_DIR": paths.runtimeDir, "B4APP_DATA_DIR": paths.dataDir, "HOME": paths.dataDir,
    "B4APP_COORDINATOR_PATH": "/nonexistent/b4app-coordinator", "PATH": "/usr/bin:/bin",
  ]
  let out = Pipe()
  let err = Pipe()
  process.standardOutput = out
  process.standardError = err
  try process.run()
  let stdout = out.fileHandleForReading.readDataToEndOfFile()
  let stderr = err.fileHandleForReading.readDataToEndOfFile()
  while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
  return (
    process.terminationStatus, String(decoding: stdout, as: UTF8.self),
    String(decoding: stderr, as: UTF8.self)
  )
}

/// The hub's `details.reason` reaches the app in the error's details (final review M11): the app
/// forgets a passkey only on `unknown_credential`.
@Suite struct AccountErrorReasonTests {
  @Test func theHubsReasonIsPassedOn() {
    let unknown = AccountManager.accountError(
      HubError(
        kind: "request_error", code: "credential_rejected", message: "no", status: 401,
        reason: HubError.unknownCredential),
      doing: "sign in")
    #expect(unknown.code == .credentialRejected)
    #expect(unknown.details?["reason"]?.stringValue == "unknown_credential")
    let bare = AccountManager.accountError(
      HubError(kind: "request_error", code: "credential_rejected", message: "no", status: 401),
      doing: "sign in")
    #expect(bare.code == .credentialRejected)
    #expect(bare.details?["reason"] == nil)
  }
}

@Suite(.serialized, .timeLimit(.minutes(3))) struct AccountCLITests {
  @Test func accountStatusJSON() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    let run = try await runCLI(["account", "status", "--json"], paths: rig.paths)
    #expect(run.status == 0, "\(run.stderr)")
    let envelope = try JSONCoding.decoder.decode(JSONValue.self, from: Data(run.stdout.utf8))
    #expect(envelope["ok"] == true)
    let status = try #require(try envelope["result"]?.decode(AccountStatus.Result.self))
    #expect(status.state == .signedIn)
    #expect(status.account?.orgName == "Ann's Org")
    #expect(!run.stdout.contains(ann.token))

    let plain = try await runCLI(["account", "status"], paths: rig.paths)
    #expect(plain.status == 0)
    #expect(plain.stdout.contains("Ann's Org"))
  }

  /// The CLI shows the left-open notice once, then dismisses it.
  @Test func hubStatusShowsTheNoticeThenDismissesIt() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    await rig.accounts.setLogoutTimeouts(
      AccountManager.LogoutTimeouts(
        work: .seconds(1), push: .milliseconds(500), endSessionFloor: .milliseconds(200), close: .seconds(1)))
    rig.hub.setHanging(true)
    _ = try await rig.logout()
    rig.hub.setHanging(false)
    try await rig.signIn(ann)
    #expect(try await rig.client.request(AccountStatus.self, EmptyParams()).notice == leftOpenNotice)

    let shown = try await runCLI(["hub", "status"], paths: rig.paths)
    #expect(shown.status == 0, "\(shown.stderr)")
    #expect(shown.stdout.contains(leftOpenNotice))
    #expect(try await rig.client.request(AccountStatus.self, EmptyParams()).notice == nil)
    let again = try await runCLI(["hub", "status"], paths: rig.paths)
    #expect(!again.stdout.contains(leftOpenNotice))
  }

  @Test func threadListSignedOutExitsFour() async throws {
    let rig = try await CommandRig.start()
    defer { Task { await rig.close() } }
    for arguments in [["thread", "list"], ["server", "list"], ["hub", "status"]] {
      let run = try await runCLI(arguments, paths: rig.paths)
      #expect(run.status == 4, "\(arguments): \(run.stderr)")
      #expect(run.stderr.contains(signedOutMessage), "\(arguments)")
    }
    let status = try await runCLI(["account", "status"], paths: rig.paths)
    #expect(status.status == 0)
    #expect(status.stdout.contains("signed out"))
  }

  @Test func accountLogoutRefusedListsTheWorkAndHowToStopIt() async throws {
    let adapters = RunningAdapters()
    let rig = try await CommandRig.start(adapterFactory: { _, _, _, _ in adapters.make() })
    defer { Task { await rig.close() } }
    try await rig.signIn(ann)
    try rig.addThread("busy")
    _ = try await rig.client.request(
      TurnSend.self, TurnSend.Params(threadId: "busy", text: "go"), options: CommandRig.mutation())

    let refused = try await runCLI(["account", "logout"], paths: rig.paths)
    #expect(refused.status != 0)
    let output = refused.stdout + refused.stderr
    #expect(output.contains("Thread busy"))
    #expect(output.contains("--stop-work"))
    #expect(await rig.accounts.status().state == .signedIn)

    let stopped = try await runCLI(["account", "logout", "--stop-work"], paths: rig.paths)
    #expect(stopped.status == 0, "\(stopped.stderr)")
    #expect(await rig.accounts.status().state == .signedOut)
    #expect(adapters.interrupts == 1)
  }
}

// MARK: - A runtime whose turns keep running until interrupted

final class RunningAdapters: Sendable {
  private let count = Mutex(0)
  var interrupts: Int { count.withLock { $0 } }
  func interrupted() { count.withLock { $0 += 1 } }
  func make() -> any AgentAdapter { RunningAdapter(owner: self) }
}

private actor RunningAdapter: AgentAdapter {
  nonisolated let kind: ConnectionKind = .claude
  private let owner: RunningAdapters
  private nonisolated let stream: AsyncStream<AdapterEvent>
  private var turns = 0

  init(owner: RunningAdapters) {
    self.owner = owner
    stream = AsyncStream { _ in }
  }

  private func unsupported() -> WorkspaceError {
    WorkspaceError(.unsupportedCapability, "Not used by this test.")
  }

  func inspectConnection() async throws -> ConnectionInspection { throw unsupported() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef { throw unsupported() }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot { throw unsupported() }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    turns += 1
    return SubmissionReceipt(nativeTurnId: "native-turn-\(turns)", acknowledged: true)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    owner.interrupted()
    return StopReceipt(confirmed: true, outcome: .cancelled)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws { throw unsupported() }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    throw unsupported()
  }
  nonisolated func events() -> AsyncStream<AdapterEvent> { stream }
  func dispose() async {}
}

// MARK: - A runtime that ignores its interrupt and its dispose

/// Counts the interrupts and disposes of its adapters, none of which ever returns (nor honours
/// cancellation) until `release()`.
final class StubbornAdapters: Sendable {
  private struct State {
    var interrupts = 0
    var disposes = 0
    var released = false
    var held: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())
  var interrupts: Int { state.withLock { $0.interrupts } }
  var disposes: Int { state.withLock { $0.disposes } }
  func make() -> any AgentAdapter { StubbornAdapter(owner: self) }

  func interrupted() { state.withLock { $0.interrupts += 1 } }
  func disposed() { state.withLock { $0.disposes += 1 } }

  /// Wait, ignoring cancellation, until `release()`.
  func hold() async {
    await withCheckedContinuation { continuation in
      let now = state.withLock { state -> Bool in
        if !state.released { state.held.append(continuation) }
        return state.released
      }
      if now { continuation.resume() }
    }
  }

  func release() {
    let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released = true
      defer { state.held = [] }
      return state.held
    }
    for waiter in held { waiter.resume() }
  }
}

private actor StubbornAdapter: AgentAdapter {
  nonisolated let kind: ConnectionKind = .claude
  private let owner: StubbornAdapters
  private nonisolated let stream: AsyncStream<AdapterEvent>

  init(owner: StubbornAdapters) {
    self.owner = owner
    stream = AsyncStream { _ in }
  }

  private func unsupported() -> WorkspaceError {
    WorkspaceError(.unsupportedCapability, "Not used by this test.")
  }

  func inspectConnection() async throws -> ConnectionInspection { throw unsupported() }
  func createSession(_ input: NewSessionInput) async throws -> NativeSessionRef { throw unsupported() }
  func loadSession(_ ref: NativeSessionRef) async throws -> SessionSnapshot { throw unsupported() }
  func sendTurn(_ ref: NativeSessionRef, input: TurnInput) async throws -> SubmissionReceipt {
    SubmissionReceipt(nativeTurnId: "native-stubborn", acknowledged: true)
  }
  func interrupt(_ ref: NativeSessionRef, turn: ActiveTurnRef) async throws -> StopReceipt {
    owner.interrupted()
    await owner.hold()
    return StopReceipt(confirmed: false, outcome: nil)
  }
  func respond(_ ref: RuntimeRequestRef, response: RuntimeResponse) async throws { throw unsupported() }
  func reconcile(_ ref: NativeSessionRef, turn: ActiveTurnRef?) async throws -> ReconcileResult {
    throw unsupported()
  }
  nonisolated func events() -> AsyncStream<AdapterEvent> { stream }
  func dispose() async {
    owner.disposed()
    await owner.hold()
  }
}
