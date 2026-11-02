import Foundation
import WorkspaceProtocol

/// An in-memory hub for tests of the readers and writers that sit above `HubAPI`. It models the parts
/// of the real hub those layers depend on: single-use enrollment codes, per-device idempotency on
/// `deviceSeq`, a feed ordered by `hubSeq`, long-poll wake-up, revocation, and injected failures. It is
/// not a hub: it does not apply changes to tables and does not check tokens.
public actor FakeHubAPI: HubAPI {
  /// Codes the fake will redeem, each once.
  public private(set) var enrollmentCodes: [String: EnrollResponse]
  /// The feed, oldest first.
  public private(set) var stored: [StoredChange]
  /// Every batch `push` received, including repeats the feed ignored.
  public private(set) var pushed: [[SyncChange]] = []
  /// Fails the next call of any method once, then clears itself.
  public private(set) var failNext: HubError?
  /// Set by `revokeSelf`, `endSession`, and `deleteAccount`; every later call except `enroll` and the
  /// sign-in calls answers 401 `unauthorized`, until a sign-in or an enrollment clears it.
  public private(set) var revoked = false
  /// How many times `enroll` was called, redeemed or not.
  public private(set) var enrollCalls = 0
  public private(set) var meCalls = 0
  /// How many times `mintPairingCode` was called, refused or not.
  public private(set) var mintCalls = 0
  private var mintFailure: HubError?
  private var mintResponse: PairingCodeResponse?
  private var failMe: HubError?

  // What the sign-in calls were sent, oldest first. Nothing else about a request is kept.
  public private(set) var passkeyFinishes: [PasskeyFinishRequest] = []
  public private(set) var appleBegins: [AppleBeginRequest] = []
  public private(set) var appleNatives: [AppleNativeRequest] = []
  public private(set) var handoffs: [HandoffRequest] = []
  public private(set) var appleLinkBegins: [AppleBeginRequest] = []
  public private(set) var appleLinkNatives: [AppleLinkNativeRequest] = []
  public private(set) var appleLinkHandoffs: [AppleLinkHandoffRequest] = []
  public private(set) var profiles: [ProfileRequest] = []
  public private(set) var removedIdentities: [String] = []
  /// The token each `enroll` call was asked to merge from (`nil` for none), oldest first.
  public private(set) var enrollTokens: [String?] = []
  /// What each `enroll` call was sent, oldest first.
  public private(set) var enrollRequests: [EnrollRequest] = []
  public private(set) var endSessionCalls = 0
  public private(set) var deleteAccountCalls = 0

  private var authConfigAnswer = AuthConfig(
    passkeys: .init(rpId: "fake.test"), apple: .init(native: false, web: false), signup: .open)
  private var passkeyBeginAnswer = PasskeyBeginResponse(
    ceremonyId: "fake-ceremony", authentication: ["publicKey": ["challenge": "fake"]],
    registration: ["publicKey": ["challenge": "fake"]])
  private var appleBeginAnswer = AppleBeginResponse(ceremonyId: "fake-apple-ceremony", nonce: "fake-nonce")
  private var addPasskeyBeginAnswer = AddPasskeyBeginResponse(
    ceremonyId: "fake-add-ceremony", registration: ["publicKey": ["challenge": "fake"]])
  private var sessionAnswer = AuthSession(
    deviceId: "fake-device", token: "fake-token", org: OrgInfo(slug: "fake", name: "Fake"),
    user: UserInfo(username: "fake", displayName: "Fake"), needsOnboarding: false)
  private var identityList: [Identity] = []
  private var fullName: String?
  private var onboarded = true
  private var addedIdentities = 0

  private var device: EnrollResponse?
  /// The signed-in user's id, from the scripted session; `me()` makes one up from the org and the
  /// username when none was scripted.
  private var userIdAnswer: String?
  private var deviceName = "Fake device"
  private var platform = "macos"
  private var acceptedSeqs: Set<Int> = []
  private var snapshotOverride: SnapshotResponse?
  private var devicesOverride: [DeviceInfo]?
  /// Long polls parked in `pull`, woken by anything that can change their answer.
  private var pullWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  /// Callers of `untilPulling`, each waiting for its count of parked pulls.
  private var parkWatchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  /// The hub refuses a `value` over this many bytes of serialised JSON.
  private static let maxValueBytes = 2_097_152
  /// The hub refuses a whole push whose body is over this many bytes with a 413, before reading it.
  public static let maxBodyBytes = 33_554_432
  private struct Body: Encodable { var changes: [SyncChange] }

  public init(enrollmentCodes: [String: EnrollResponse] = [:], stored: [StoredChange] = []) {
    self.enrollmentCodes = enrollmentCodes
    self.stored = stored
  }

  public func setFailNext(_ error: HubError?) {
    failNext = error
    wakePulls()
  }
  /// Fail the next `me()` only, whatever other calls run first.
  public func setFailMe(_ error: HubError?) { failMe = error }

  /// Sets the platform of the fake's device, which decides what `push` refuses: `macos` may write
  /// anything, `ios` and `cli` only the phone's columns. `enroll` sets it from its request.
  public func setPlatform(_ platform: String) { self.platform = platform }

  /// What `snapshot()` answers. Without it the fake answers an empty snapshot at the feed's tip.
  public func setSnapshot(_ snapshot: SnapshotResponse?) { snapshotOverride = snapshot }

  /// What `devices()` answers. Without it the fake lists the enrolled device alone.
  public func setDevices(_ devices: [DeviceInfo]?) { devicesOverride = devices }

  /// What `mintPairingCode()` answers until changed. Without it the fake answers a fresh `FAKE`-prefixed
  /// code that expires in five minutes.
  public func setPairingCode(_ response: PairingCodeResponse?) { mintResponse = response }

  /// Fails `mintPairingCode()` (every call, until cleared with `nil`), as the hub's rate limit does.
  public func setMintFailure(_ error: HubError?) { mintFailure = error }

  public func addEnrollmentCode(_ code: String, _ response: EnrollResponse) {
    enrollmentCodes[code] = response
  }

  /// What `authConfig()` answers.
  public func setAuthConfig(_ config: AuthConfig) { authConfigAnswer = config }
  /// What `passkeyBegin()` answers.
  public func setPasskeyBegin(_ response: PasskeyBeginResponse) { passkeyBeginAnswer = response }
  /// What `appleBegin()` answers.
  public func setAppleBegin(_ response: AppleBeginResponse) { appleBeginAnswer = response }
  /// What `addPasskeyBegin()` answers.
  public func setAddPasskeyBegin(_ response: AddPasskeyBeginResponse) { addPasskeyBeginAnswer = response }
  /// What `passkeyFinish`, `appleNative`, and `handoff` answer. The fake is then signed in as that
  /// session's account, on the device the request named.
  public func setSession(_ session: AuthSession) {
    sessionAnswer = session
    onboarded = !session.needsOnboarding
  }
  /// The user id `me()` answers (nil: one made up from the org slug and the username).
  public func setUserId(_ id: String?) { userIdAnswer = id }
  /// The account's sign-in methods, which `me()` and `identities()` list.
  public func setIdentities(_ identities: [Identity]) { identityList = identities }

  /// Adds changes to the feed as if another device had pushed them.
  public func append(_ changes: [StoredChange]) {
    stored.append(contentsOf: changes)
    wakePulls()
  }

  /// How many pulls are parked in their long poll right now.
  public var parkedPulls: Int { pullWaiters.count }

  /// Returns once `count` pulls are parked in their long poll, so a test changes the feed after its
  /// reader is waiting rather than after a guess at how long that takes.
  public func untilPulling(_ count: Int = 1) async {
    guard pullWaiters.count < count else { return }
    await withCheckedContinuation { parkWatchers.append((count, $0)) }
  }

  public func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    try await enroll(request, replacingToken: nil)
  }

  /// Redeems the code as `enroll(_:)` does and records `token`; the fake merges no accounts.
  public func enroll(_ request: EnrollRequest, replacingToken token: String?) async throws -> EnrollResponse {
    enrollTokens.append(token)
    enrollRequests.append(request)
    enrollCalls += 1
    try consumeFailure()
    guard let response = enrollmentCodes.removeValue(forKey: request.code) else {
      throw Self.error("invalid_code", "The enrollment code is not valid.", status: 401)
    }
    device = response
    deviceName = request.deviceName
    platform = request.platform
    revoked = false
    return response
  }

  public func me() async throws -> MeResponse {
    meCalls += 1
    if let failure = failMe {
      failMe = nil
      throw failure
    }
    try authorize()
    let device =
      device
      ?? EnrollResponse(
        deviceId: "fake-device", token: "fake-token", org: OrgInfo(slug: "fake", name: "Fake"),
        user: UserInfo(username: "fake", displayName: "Fake"))
    return MeResponse(
      deviceId: device.deviceId, deviceName: deviceName, platform: platform, org: device.org,
      user: device.user, createdAt: "2026-10-31T12:00:00.000000Z", fullName: fullName,
      onboarded: onboarded, identities: identityList,
      userId: userIdAnswer ?? "user-\(device.org.slug)-\(device.user.username)")
  }

  public func push(_ changes: [SyncChange]) async throws -> PushResponse {
    try authorize()
    if let body = try? JSONCoding.encoder.encode(Body(changes: changes)), body.count > Self.maxBodyBytes {
      throw Self.error("payload_too_large", "The request body is too large.", status: 413)
    }
    pushed.append(changes)
    let deviceId = device?.deviceId ?? "fake-device"
    var rejected: [RejectedChange] = []
    for change in changes where !acceptedSeqs.contains(change.deviceSeq) {
      if let code = refusal(for: change) {
        rejected.append(RejectedChange(deviceSeq: change.deviceSeq, code: code))
        continue
      }
      acceptedSeqs.insert(change.deviceSeq)
      stored.append(
        StoredChange(
          hubSeq: (stored.last?.hubSeq ?? 0) + 1, deviceId: deviceId, deviceSeq: change.deviceSeq,
          wall: change.wall, table: change.table, rowId: change.rowId, op: change.op, column: change.column,
          value: change.value, hlc: change.hlc))
    }
    wakePulls()
    return PushResponse(
      acceptedThrough: changes.map(\.deviceSeq).max() ?? acceptedSeqs.max() ?? 0, rejected: rejected)
  }

  public func snapshot() async throws -> SnapshotResponse {
    try authorize()
    return snapshotOverride ?? SnapshotResponse(changes: [], clocks: [], next: stored.last?.hubSeq ?? 0)
  }

  public func devices() async throws -> [DeviceInfo] {
    try authorize()
    if let devicesOverride { return devicesOverride }
    guard let device else { return [] }
    return [DeviceInfo(id: device.deviceId, name: deviceName, platform: platform)]
  }

  public func mintPairingCode() async throws -> PairingCodeResponse {
    mintCalls += 1
    try authorize()
    if let mintFailure { throw mintFailure }
    guard platform == "macos" else { throw Self.error("not_found", "Not found.", status: 404) }
    if let mintResponse { return mintResponse }
    return PairingCodeResponse(
      code: "FAKE\(2345 + mintCalls)", expiresAt: Timestamp.string(from: Date().addingTimeInterval(300)))
  }

  public func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try authorize()
    let deadline = ContinuousClock.now + .seconds(max(wait, 0))
    while true {
      let newer = stored.filter { $0.hubSeq > after }
      if !newer.isEmpty || ContinuousClock.now >= deadline {
        let page = Array(newer.prefix(max(1, min(limit, 1000))))
        return PullResponse(
          changes: page, next: page.last?.hubSeq ?? after, more: newer.count > page.count)
      }
      try await park(until: deadline)
      try authorize()
    }
  }

  public func revokeSelf() async throws {
    try authorize()
    revoked = true
    wakePulls()
  }

  // MARK: - Long poll

  /// Waits, as the hub's long poll does, until something that can change the answer happens (an
  /// `append`, a push, a failure or revocation to report) or the deadline passes, rather than
  /// re-reading on a clock. A cancelled reader's task ends with `CancellationError`.
  private func park(until deadline: ContinuousClock.Instant) async throws {
    let id = UUID()
    let alarm = Task { [weak self] in
      _ = try? await Task.sleep(until: deadline, clock: .continuous)
      await self?.wake(id)
    }
    defer { alarm.cancel() }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pullWaiters[id] = continuation
        let parked = pullWaiters.count
        let ready = parkWatchers.filter { $0.count <= parked }
        parkWatchers.removeAll { $0.count <= parked }
        for watcher in ready { watcher.continuation.resume() }
      }
    } onCancel: {
      Task { await self.wake(id) }
    }
    try Task.checkCancellation()
  }

  private func wake(_ id: UUID) {
    pullWaiters.removeValue(forKey: id)?.resume()
  }

  private func wakePulls() {
    let waiters = pullWaiters.values
    pullWaiters = [:]
    for waiter in waiters { waiter.resume() }
  }

  // MARK: - Signing in

  public func authConfig() async throws -> AuthConfig {
    try consumeFailure()
    return authConfigAnswer
  }

  public func passkeyBegin() async throws -> PasskeyBeginResponse {
    try consumeFailure()
    return passkeyBeginAnswer
  }

  public func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    try consumeFailure()
    passkeyFinishes.append(request)
    return signIn(as: request.device)
  }

  public func appleBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    try consumeFailure()
    appleBegins.append(request)
    return appleBeginAnswer
  }

  public func appleNative(_ request: AppleNativeRequest) async throws -> AuthSession {
    try consumeFailure()
    appleNatives.append(request)
    return signIn(as: request.device)
  }

  public func handoff(_ request: HandoffRequest) async throws -> AuthSession {
    try consumeFailure()
    handoffs.append(request)
    return signIn(as: request.device)
  }

  // MARK: - The signed-in account

  public func setProfile(_ request: ProfileRequest) async throws -> MeResponse {
    try authorize()
    profiles.append(request)
    fullName = request.fullName
    onboarded = true
    if let current = device {
      device = EnrollResponse(
        deviceId: current.deviceId, token: current.token, org: current.org,
        user: UserInfo(username: current.user.username, displayName: request.fullName))
    }
    return try await me()
  }

  public func identities() async throws -> [Identity] {
    try authorize()
    return identityList
  }

  public func addPasskeyBegin() async throws -> AddPasskeyBeginResponse {
    try authorize()
    return addPasskeyBeginAnswer
  }

  public func addPasskeyFinish(_ request: AddPasskeyFinishRequest) async throws -> Identity {
    try authorize()
    addedIdentities += 1
    let identity = Identity(
      id: "fake-passkey-\(addedIdentities)", kind: "passkey", name: "Agent Workspace account",
      createdAt: "2026-11-01T12:00:00.000000Z")
    identityList.append(identity)
    return identity
  }

  public func removeIdentity(_ id: String) async throws {
    try authorize()
    removedIdentities.append(id)
    guard let index = identityList.firstIndex(where: { $0.id == id }) else {
      throw Self.error("not_found", "not found", status: 404)
    }
    guard identityList.count > 1 else {
      throw Self.error("last_identity", "That is the only way to sign in.", status: 409)
    }
    identityList.remove(at: index)
  }

  public func appleLinkBegin(_ request: AppleBeginRequest) async throws -> AppleBeginResponse {
    try authorize()
    appleLinkBegins.append(request)
    if identityList.contains(where: { $0.kind == "apple" }) {
      throw Self.error("apple_linked", "This account already has an Apple ID.", status: 409)
    }
    return appleBeginAnswer
  }

  public func appleLinkNative(_ request: AppleLinkNativeRequest) async throws -> Identity {
    try authorize()
    appleLinkNatives.append(request)
    return linkApple()
  }

  public func appleLinkHandoff(_ request: AppleLinkHandoffRequest) async throws -> Identity {
    try authorize()
    appleLinkHandoffs.append(request)
    return linkApple()
  }

  /// Adds an Apple ID to the account's methods (the one it has, if any) and answers it.
  private func linkApple() -> Identity {
    if let linked = identityList.first(where: { $0.kind == "apple" }) { return linked }
    let identity = Identity(
      id: "fake-apple-\(identityList.count + 1)", kind: "apple", name: "fake@privaterelay.appleid.com",
      createdAt: "2026-11-02T12:00:00.000000Z")
    identityList.append(identity)
    return identity
  }

  public func endSession() async throws {
    try authorize()
    endSessionCalls += 1
    revoked = true
    // A parked long poll answers 401 now, as `revokeSelf`'s does.
    wakePulls()
  }

  public func deleteAccount() async throws {
    try authorize()
    deleteAccountCalls += 1
    revoked = true
    wakePulls()
  }

  // MARK: - Helpers

  /// Signs the fake in as the scripted session's account, on the session's device (the one the hub
  /// chose: a hub reuses a requested `deviceId` or candidate only when it is the user's) with `spec`'s
  /// name and platform, and answers the session.
  private func signIn(as spec: DeviceSpec) -> AuthSession {
    let session = sessionAnswer
    device = EnrollResponse(
      deviceId: session.deviceId, token: session.token, org: session.org, user: session.user)
    deviceName = spec.deviceName
    platform = spec.platform
    revoked = false
    if let userId = session.userId { userIdAnswer = userId }
    return session
  }

  /// The hub's per-change refusal, or `nil` when the change is accepted. A `macos` device may write
  /// anything; any other platform may only update phone-writable columns or insert a draft.
  private func refusal(for change: SyncChange) -> String? {
    if let hlc = change.hlc, HLC(rawValue: hlc) == nil { return "invalid_clock" }
    if platform != "macos" {
      let phoneUpdate =
        change.op == "update"
        && change.column.map { SyncColumns.isPhoneWritable(table: change.table, column: $0) } == true
      let draftInsert = change.op == "insert" && change.table == "drafts"
      if !phoneUpdate && !draftInsert { return "column_not_writable" }
    }
    if let value = change.value,
      let encoded = try? JSONCoding.encoder.encode(value), encoded.count > Self.maxValueBytes
    {
      return "payload_too_large"
    }
    return nil
  }

  private func consumeFailure() throws {
    if let failure = failNext {
      failNext = nil
      throw failure
    }
  }

  private func authorize() throws {
    try consumeFailure()
    if revoked { throw Self.error("unauthorized", "Unauthorized.", status: 401) }
  }

  private static func error(_ code: String, _ message: String, status: Int) -> HubError {
    HubError(kind: "request_error", code: code, message: message, status: status)
  }
}
