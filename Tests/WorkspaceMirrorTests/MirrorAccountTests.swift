import Foundation
import Synchronization
import Testing
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync

@testable import WorkspaceMirror

// The iPhone's own account (sign-in plan, Task 14): it signs in at the flavour's hub itself, keeps the
// token in the Keychain, and on log-out ends the session, forgets the token, and empties the mirror.

private let hub = URL(string: "https://hub.test.b4.run")!

private func session(
  device: String = "0198aaaa-0000-7000-8000-000000000001", onboarding: Bool = false,
  displayName: String = "Brian Love", token: String = "tok-secret-4411"
) -> AuthSession {
  AuthSession(
    deviceId: device, token: token, org: OrgInfo(slug: "o-abc", name: "Brian's Org"),
    user: UserInfo(username: "u-abc", displayName: displayName), needsOnboarding: onboarding,
    userId: "0197bbbb-0000-7000-8000-000000000001")
}

/// A mirror account over an in-memory store, a memory Keychain, and one fake hub.
@MainActor
private struct Rig {
  let store: MirrorStore
  let secrets = MemorySecretStore()
  let fake: FakeHubAPI
  let memory: MirrorDeviceMemory
  let account: MirrorAccount
  let changes = Changes()

  init(
    store: MirrorStore? = nil, fake: FakeHubAPI = FakeHubAPI(), memory: MirrorDeviceMemory? = nil,
    makeAPI: MirrorAccount.APIFactory? = nil, endSessionTimeout: Duration = .seconds(10),
    flavor: PhoneFlavor = .local
  ) throws {
    self.store = try store ?? MirrorStore.inMemory()
    self.fake = fake
    self.memory = memory ?? MirrorDeviceMemory(url: nil)
    account = MirrorAccount(
      store: self.store, secrets: secrets,
      configuration: MirrorAccount.Configuration(
        hubURL: hub, deviceName: "Brian's iPhone", endSessionTimeout: endSessionTimeout,
        syncBackoff: .milliseconds(20), flavor: flavor),
      memory: self.memory, makeAPI: makeAPI ?? { [fake] _, _ in fake })
    let changes = self.changes
    account.onChange = { changes.append($0) }
  }

  /// Sign in with a passkey assertion as `answer`.
  @discardableResult
  func signIn(_ answer: AuthSession = session()) async throws -> AccountStatus.Result {
    await fake.setSession(answer)
    let begun = try await account.passkeyBegin()
    return try await account.signIn(
      passkey: AccountPasskeyFinish.Params(ceremonyId: begun.ceremonyId, assertion: ["id": "cred"]))
  }

  func token() async throws -> String? {
    guard let link = try store.link(), let ref = SecretRef(rawValue: link.tokenRef) else { return nil }
    return try await secrets.read(ref)
  }
}

@MainActor
private final class Changes {
  private(set) var all: [AccountStatus.Result] = []
  func append(_ status: AccountStatus.Result) { all.append(status) }
}

private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while try await !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(what)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// A hub whose `endSession` never answers and ignores cancellation, like one that dropped off the
/// network mid-request.
private struct HangingHub: HubAPI {
  let fake: FakeHubAPI
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try await fake.enroll(request) }
  func me() async throws -> MeResponse { try await fake.me() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try await fake.push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await fake.pull(after: after, limit: limit, wait: min(wait, 1))
  }
  func snapshot() async throws -> SnapshotResponse { try await fake.snapshot() }
  func devices() async throws -> [DeviceInfo] { try await fake.devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { try await fake.mintPairingCode() }
  func revokeSelf() async throws { try await fake.revokeSelf() }
  func passkeyBegin() async throws -> PasskeyBeginResponse { try await fake.passkeyBegin() }
  func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    try await fake.passkeyFinish(request)
  }
  func endSession() async throws {
    // Answers only after a while, whether or not the call was cancelled.
    await withCheckedContinuation { (answer: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().asyncAfter(deadline: .now() + 60) { answer.resume() }
    }
  }
}

/// Forwards to the fake, except that the first `/v1/me` waits for `gate` and then answers `late`.
private final class HeldProfileHub: HubAPI, @unchecked Sendable {
  let fake: FakeHubAPI
  let gate: Gate
  let late: MeResponse
  private let state = Mutex((calls: 0, answered: false))
  init(fake: FakeHubAPI, gate: Gate, late: MeResponse) {
    self.fake = fake
    self.gate = gate
    self.late = late
  }
  var heldCalls: Int { state.withLock { min($0.calls, 1) } }
  var answered: Bool { state.withLock { $0.answered } }

  func me() async throws -> MeResponse {
    let first = state.withLock { state -> Bool in
      state.calls += 1
      return state.calls == 1
    }
    guard first else { return try await fake.me() }
    await gate.wait()
    defer { state.withLock { $0.answered = true } }
    return late
  }
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try await fake.enroll(request) }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try await fake.push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await fake.pull(after: after, limit: limit, wait: min(wait, 1))
  }
  func snapshot() async throws -> SnapshotResponse { try await fake.snapshot() }
  func devices() async throws -> [DeviceInfo] { try await fake.devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { try await fake.mintPairingCode() }
  func revokeSelf() async throws { try await fake.revokeSelf() }
  func passkeyBegin() async throws -> PasskeyBeginResponse { try await fake.passkeyBegin() }
  func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    try await fake.passkeyFinish(request)
  }
  func endSession() async throws { try await fake.endSession() }
}

/// Forwards to the fake; `deleteAccount` deletes there, then takes a while to answer, long enough for
/// a sync still running to meet the 401 the deleted account now gets. With `refusal`, it refuses
/// instead and deletes nothing.
private struct SlowDeleteHub: HubAPI {
  let fake: FakeHubAPI
  var refusal: HubError? = nil
  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse { try await fake.enroll(request) }
  func me() async throws -> MeResponse { try await fake.me() }
  func push(_ changes: [SyncChange]) async throws -> PushResponse { try await fake.push(changes) }
  func pull(after: Int, limit: Int, wait: Int) async throws -> PullResponse {
    try await fake.pull(after: after, limit: limit, wait: min(wait, 1))
  }
  func snapshot() async throws -> SnapshotResponse { try await fake.snapshot() }
  func devices() async throws -> [DeviceInfo] { try await fake.devices() }
  func mintPairingCode() async throws -> PairingCodeResponse { try await fake.mintPairingCode() }
  func revokeSelf() async throws { try await fake.revokeSelf() }
  func passkeyBegin() async throws -> PasskeyBeginResponse { try await fake.passkeyBegin() }
  func passkeyFinish(_ request: PasskeyFinishRequest) async throws -> AuthSession {
    try await fake.passkeyFinish(request)
  }
  func endSession() async throws { try await fake.endSession() }
  func deleteAccount(stepUp: String?) async throws {
    if let refusal { throw refusal }
    try await fake.deleteAccount(stepUp: stepUp)
    try await Task.sleep(for: .milliseconds(400))
  }
}

@MainActor
@Suite struct MirrorAccountTests {
  // MARK: Signing in

  @Test func aPhoneWithNoLinkIsSignedOut() throws {
    let rig = try Rig()
    #expect(rig.account.accountStatus == AccountStatus.Result(state: .signedOut))
    #expect(rig.account.sync == nil)
  }

  @Test func mirrorSignInStoresTokenAndStartsSync() async throws {
    let rig = try Rig()
    let status = try await rig.signIn(session(onboarding: true, displayName: ""))
    #expect(status.state == .needsOnboarding)
    #expect(status.account?.orgName == "Brian's Org")
    #expect(rig.account.accountStatus == status)
    #expect(rig.changes.all == [status])

    let link = try #require(try rig.store.link())
    #expect(link.hubURL == "https://hub.test.b4.run")
    #expect(link.deviceId == "0198aaaa-0000-7000-8000-000000000001")
    #expect(link.deviceName == "Brian's iPhone")
    #expect(link.needsOnboarding == true)
    // The token is in the Keychain under the link's reference, and nowhere in the link itself.
    #expect(try await rig.token() == "tok-secret-4411")
    let stored = String(decoding: try JSONCoding.encoder.encode(link), as: UTF8.self)
    #expect(!stored.contains("tok-secret-4411"))
    #expect(!status.account.debugDescription.contains("tok-secret-4411"))

    // The phone signed in as an iPhone, and sync runs: its first turn asks the hub for its sequence.
    let sent = try #require(await rig.fake.passkeyFinishes.last)
    #expect(sent.device.platform == "ios")
    #expect(sent.device.deviceName == "Brian's iPhone")
    #expect(sent.device.deviceId == nil)
    #expect(rig.account.sync != nil)
    try await eventually("the sync's first push") { !(await rig.fake.pushed.isEmpty) }
    await rig.account.stopSync()
  }

  @Test func appleNativeSendsTheTokenTheCodeAndTheName() async throws {
    let rig = try Rig()
    await rig.fake.setSession(session(onboarding: true))
    let ceremony = try await rig.account.appleBegin()
    #expect(ceremony == AppleNativeCeremony(ceremonyId: "fake-apple-ceremony", nonce: "fake-nonce"))
    #expect(!ceremony.description.contains("fake-nonce"))
    // The native flow begins with an empty body: no verifier, no scheme.
    #expect(await rig.fake.appleBegins == [AppleBeginRequest()])
    let status = try await rig.account.signIn(
      apple: AppleCredential(
        identityToken: "jwt-secret", authorizationCode: "code-secret", fullName: " Brian Love "),
      ceremonyId: ceremony.ceremonyId)
    #expect(status.state == .needsOnboarding)
    let sent = try #require(await rig.fake.appleNatives.last)
    #expect(sent.ceremonyId == "fake-apple-ceremony")
    #expect(sent.identityToken == "jwt-secret")
    #expect(sent.authorizationCode == "code-secret")
    #expect(sent.fullName == "Brian Love")
    #expect(sent.device.platform == "ios")
    await rig.account.stopSync()

    // No name (every sign-in after Apple's first) sends none.
    let again = try Rig()
    await again.fake.setSession(session())
    _ = try await again.account.signIn(
      apple: AppleCredential(identityToken: "t", authorizationCode: "c", fullName: "  "), ceremonyId: "x")
    #expect(try #require(await again.fake.appleNatives.last).fullName == nil)
    await again.account.stopSync()
  }

  @Test func completeProfileSignsInAndSurvivesARestart() async throws {
    let store = try MirrorStore.inMemory()
    let rig = try Rig(store: store)
    try await rig.signIn(session(onboarding: true, displayName: ""))
    let named = try await rig.account.completeProfile(fullName: "  Brian Love ")
    #expect(named.state == .signedIn)
    #expect(await rig.fake.profiles == [ProfileRequest(fullName: "Brian Love")])
    #expect(named.account?.displayName == "Brian Love")
    #expect(try store.link()?.needsOnboarding == false)
    await rig.account.stopSync()

    // A relaunch reads the state from the stored link, with no hub call first: no flash.
    let relaunched = try Rig(store: store, fake: rig.fake)
    #expect(relaunched.account.accountStatus.state == .signedIn)
    #expect(relaunched.account.accountStatus.account?.displayName == "Brian Love")

    // Mid-onboarding stays mid-onboarding across a relaunch.
    let other = try MirrorStore.inMemory()
    let first = try Rig(store: other)
    try await first.signIn(session(onboarding: true))
    await first.account.stopSync()
    #expect(try Rig(store: other, fake: first.fake).account.accountStatus.state == .needsOnboarding)
  }

  // MARK: Logging out

  @Test func mirrorLogOutReturnsToSignIn() async throws {
    let rig = try Rig()
    try await rig.signIn()
    let link = try #require(try rig.store.link())
    _ = try rig.store.apply(Array(try fixtureAsStored().prefix(4)))
    _ = try rig.store.updateThread(id: "thread-1", title: "Unsent", pinned: nil, archived: nil)
    #expect(try rig.store.thread(id: "thread-1") != nil)

    let status = await rig.account.logOut()
    #expect(status == AccountStatus.Result(state: .signedOut))
    #expect(rig.account.accountStatus == status)
    #expect(rig.changes.all.last == status)
    // The session ended at the hub; the device stays enrolled there.
    #expect(await rig.fake.endSessionCalls == 1)
    // The token is gone, and the mirror is empty (D-053): rows, the outbox, and the link.
    #expect(try await rig.secrets.read(try #require(SecretRef(rawValue: link.tokenRef))) == nil)
    #expect(try rig.store.link() == nil)
    #expect(try rig.store.thread(id: "thread-1") == nil)
    #expect(try rig.store.outbox(limit: 10).isEmpty)
    #expect(rig.account.sync == nil)

    // Signing back in offers the device it had, so the hub reuses it.
    try await rig.signIn()
    #expect(try #require(await rig.fake.passkeyFinishes.last).device.deviceId == link.deviceId)
    await rig.account.stopSync()
  }

  /// Review M2: one phone, two accounts. Each sign-in offers every device the phone has had at this
  /// hub, so switching back reuses the account's own device instead of stranding it.
  @Test func aSignInOffersEveryDeviceThisPhoneHasHadAtTheHub() async throws {
    let rig = try Rig()
    try await rig.signIn(session(device: "dev-a"))
    _ = await rig.account.logOut()
    try await rig.signIn(session(device: "dev-b"))
    _ = await rig.account.logOut()
    try await rig.signIn(session(device: "dev-a"))
    let finishes = await rig.fake.passkeyFinishes.map(\.device)
    #expect(finishes.map(\.deviceId) == [nil, "dev-a", "dev-b"])
    #expect(finishes.map(\.candidateDeviceIds) == [nil, nil, ["dev-a"]])
    // Signing in on dev-a again makes it the most recent.
    #expect(rig.memory.devices(hubURL: "https://hub.test.b4.run") == ["dev-a", "dev-b"])
    await rig.account.stopSync()
  }

  /// Review M1: a `/v1/me` answer asked for under an earlier link never lands on the next one.
  @Test func aLateProfileAnswerIsDroppedAfterASwitch() async throws {
    let fake = FakeHubAPI()
    let gate = Gate()
    let late = MeResponse(
      deviceId: "dev-a", deviceName: "Brian's iPhone", platform: "ios",
      org: OrgInfo(slug: "o-ann", name: "Ann's Org"), user: UserInfo(username: "u-ann", displayName: "Ann"),
      createdAt: "2026-11-02T09:00:00.000000Z", fullName: nil, onboarded: false, identities: [],
      userId: "user-ann")
    let held = HeldProfileHub(fake: fake, gate: gate, late: late)
    let rig = try Rig(fake: fake, makeAPI: { _, _ in held })
    try await rig.signIn(session(device: "dev-a", displayName: "Ann"))
    try await eventually("A's /v1/me held") { held.heldCalls == 1 }
    _ = await rig.account.logOut()
    try await rig.signIn(session(device: "dev-b", displayName: "Bob"))
    try await eventually("B's /v1/me answered") { await fake.meCalls >= 1 }
    gate.open()
    try await eventually("A's /v1/me answered") { held.answered }
    try await Task.sleep(for: .milliseconds(50))
    let link = try #require(try rig.store.link())
    #expect(link.deviceId == "dev-b")
    #expect(link.displayName == "Bob")
    #expect(link.orgName == "Brian's Org")
    #expect(link.needsOnboarding == false)
    #expect(rig.account.accountStatus.state == .signedIn)
    await rig.account.stopSync()
  }

  // MARK: Another flavour's mirror (review M4)

  /// Review I2: a link this build wrote is this phone's own, whatever hub it names: a code for the test
  /// hub entered on a local build survives every launch.
  @Test func aLinkThisBuildEnrolledAtAnotherFlavoursHubSurvivesARestart() async throws {
    for flavor in [PhoneFlavor.local, .prod] {
      let store = try MirrorStore.inMemory()
      let fake = FakeHubAPI(enrollmentCodes: [
        "K7M2Q9XP": EnrollResponse(
          deviceId: "dev-\(flavor)", token: "tok", org: OrgInfo(slug: "o", name: "O"),
          user: UserInfo(username: "u", displayName: "U"))
      ])
      let rig = try Rig(store: store, fake: fake, flavor: flavor)
      _ = try await rig.account.enroll(url: "https://hub.test.b4.run", code: "K7M2Q9XP", deviceName: "iPhone")
      await rig.account.stopSync()
      #expect(try store.link()?.flavor == flavor.rawValue)
      // The next launch: the rule runs first, then the account reads the link.
      #expect(MirrorAccount.discardForeignLink(in: store, flavor: flavor) == nil, "\(flavor)")
      let relaunched = try Rig(store: store, fake: fake, flavor: flavor)
      #expect(relaunched.account.accountStatus.state == .signedIn, "\(flavor)")
      #expect(try store.link()?.hubURL == "https://hub.test.b4.run")
    }
  }

  @Test func onlyTheProdFolderIsCheckedForAnotherFlavoursMirror() throws {
    // The beta and local folders are new: an unmarked link in one cannot be another flavour's.
    for flavor in [PhoneFlavor.beta, .local] {
      let store = try MirrorStore.inMemory()
      try store.saveLink(
        MirrorLink(
          hubURL: "https://hub.b4.run", deviceId: "d", deviceName: "iPhone", tokenRef: "secret:t",
          orgSlug: "o",
          username: "u"))
      #expect(MirrorAccount.discardForeignLink(in: store, flavor: flavor) == nil, "\(flavor)")
      #expect(try store.link() != nil)
    }
  }

  /// An old build's link (no `flavor`) to the test hub, in the prod folder: still emptied.
  @Test func aMirrorLeftByAnotherFlavourIsEmptied() throws {
    let store = try MirrorStore.inMemory()
    let beta = MirrorLink(
      hubURL: "https://hub.test.b4.run/", deviceId: "dev-beta", deviceName: "iPhone", tokenRef: "secret:beta",
      orgSlug: "o", username: "u")
    try store.saveLink(beta)
    _ = try store.apply(Array(try fixtureAsStored().prefix(4)))
    #expect(MirrorAccount.discardForeignLink(in: store, flavor: .prod) == SecretRef(rawValue: "secret:beta"))
    #expect(try store.link() == nil)
    #expect(try store.thread(id: "thread-1") == nil)
  }

  @Test func thisFlavoursOwnOrAnOperatorsMirrorIsKept() throws {
    for (hub, flavor) in [
      ("https://hub.b4.run", PhoneFlavor.prod), ("https://hub.test.b4.run", .beta),
      ("https://hub.example.com", .prod), ("http://localhost:8080", .local),
    ] {
      let store = try MirrorStore.inMemory()
      try store.saveLink(
        MirrorLink(
          hubURL: hub, deviceId: "d", deviceName: "iPhone", tokenRef: "secret:t", orgSlug: "o", username: "u")
      )
      #expect(MirrorAccount.discardForeignLink(in: store, flavor: flavor) == nil, "\(hub)")
      #expect(try store.link()?.hubURL == hub)
    }
    #expect(MirrorAccount.discardForeignLink(in: try MirrorStore.inMemory(), flavor: .prod) == nil)
  }

  @Test func logOutWhenTheHubIsDownStillSignsOut() async throws {
    let rig = try Rig()
    try await rig.signIn()
    await rig.account.stopSync()
    let link = try #require(try rig.store.link())
    await rig.fake.setFailNext(
      HubError(kind: "execution_error", code: "transport", message: "offline", status: 0))
    let status = await rig.account.logOut()
    #expect(status.state == .signedOut)
    #expect(try await rig.secrets.read(try #require(SecretRef(rawValue: link.tokenRef))) == nil)
    #expect(try rig.store.link() == nil)
  }

  @Test func logOutIsBoundedWhenTheHubNeverAnswers() async throws {
    let fake = FakeHubAPI()
    let rig = try Rig(
      fake: fake, makeAPI: { _, _ in HangingHub(fake: fake) }, endSessionTimeout: .milliseconds(200))
    try await rig.signIn()
    let started = ContinuousClock.now
    let status = await rig.account.logOut()
    // The hub would answer only after a minute; the log-out is long done (generous for a loaded run).
    #expect(ContinuousClock.now - started < .seconds(30))
    #expect(status.state == .signedOut)
    #expect(try rig.store.link() == nil)
  }

  @Test func theStandardLogOutWaitsTenSecondsForTheHub() {
    #expect(MirrorAccount.Configuration(hubURL: hub, deviceName: "x").endSessionTimeout == .seconds(10))
  }

  // MARK: The hub refusing the token

  @Test func a401OnSyncSignsThePhoneOut() async throws {
    let rig = try Rig()
    try await rig.signIn()
    let link = try #require(try rig.store.link())
    try await eventually("the sync's first push") { !(await rig.fake.pushed.isEmpty) }
    // Another device removed this one, or the account was deleted: every call is now 401.
    try await rig.fake.endSession()
    try await eventually("the sign-out") { rig.account.accountStatus.state == .signedOut }
    #expect(rig.account.accountStatus.reason == .rejectedByHub("Brian's Org"))
    #expect(rig.changes.all.last?.reason == .rejectedByHub("Brian's Org"))
    #expect(try rig.store.link() == nil)
    #expect(try await rig.secrets.read(try #require(SecretRef(rawValue: link.tokenRef))) == nil)
    #expect(rig.account.sync == nil)
  }

  @Test func a401OnAnAccountCallSignsThePhoneOut() async throws {
    let rig = try Rig()
    try await rig.signIn()
    await rig.account.stopSync()
    try await rig.fake.endSession()
    await #expect(throws: WorkspaceError.self) { _ = try await rig.account.identities() }
    #expect(rig.account.accountStatus.state == .signedOut)
    #expect(rig.account.accountStatus.reason == .rejectedByHub("Brian's Org"))
  }

  // MARK: The account's methods

  @Test func identitiesAddAndRemove() async throws {
    let rig = try Rig()
    try await rig.signIn()
    await rig.account.stopSync()
    await rig.fake.setIdentities([Identity(id: "i1", kind: "passkey", createdAt: "2026-11-01T09:00:00Z")])
    #expect(try await rig.account.identities().map(\.id) == ["i1"])
    // Without a confirmation the hub asks for one, and says what the account can confirm with.
    let unconfirmed = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.addPasskeyBegin(stepUp: nil)
    }
    #expect(unconfirmed?.code == .stepUpRequired)
    #expect(unconfirmed?.details?["methods"] == ["passkey"])
    let options = try await rig.account.stepUpPasskeyBegin()
    let confirmed = AccountStepUp.passkey(ceremonyId: options.ceremonyId, assertion: ["id": "i1"])
    let begun = try await rig.account.addPasskeyBegin(stepUp: confirmed)
    #expect(begun.ceremonyId == "fake-add-ceremony")
    // The phone finished the step-up itself, once, and sent the grant with the change.
    #expect(
      await rig.fake.stepUpFinishes == [
        StepUpFinishRequest(ceremonyId: options.ceremonyId, assertion: ["id": "i1"])
      ])
    #expect(await rig.fake.presentedStepUps == [nil, "fake-step-up-1"])
    let added = try await rig.account.addPasskeyFinish(
      AccountAddPasskeyFinish.Params(ceremonyId: begun.ceremonyId, attestation: ["id": "new"]))
    #expect(added.kind == "passkey")
    #expect(try await rig.account.removeIdentity(id: added.id, stepUp: confirmed).map(\.id) == ["i1"])
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.removeIdentity(id: "i1", stepUp: confirmed)
    }
    #expect(refused?.code == .lastIdentity)
  }

  @Test func anAppleOnlyAccountConfirmsWithAppleNatively() async throws {
    let rig = try Rig()
    try await rig.signIn()
    await rig.account.stopSync()
    await rig.fake.setIdentities([Identity(id: "a1", kind: "apple", createdAt: "2026-11-01T09:00:00Z")])
    let ceremony = try await rig.account.stepUpAppleBegin()
    #expect(await rig.fake.stepUpAppleBegins == [AppleBeginRequest()])
    let confirmed = AccountStepUp.appleNative(ceremonyId: ceremony.ceremonyId, identityToken: "jwt")
    _ = try await rig.account.addPasskeyBegin(stepUp: confirmed)
    // Only the identity token goes to the hub: no code is exchanged for a step-up.
    #expect(
      await rig.fake.stepUpAppleNatives == [
        StepUpAppleNativeRequest(ceremonyId: ceremony.ceremonyId, identityToken: "jwt")
      ])
    #expect(await rig.fake.presentedStepUps == ["fake-step-up-1"])
  }

  @Test func linkingAnAppleIDNatively() async throws {
    let rig = try Rig()
    try await rig.signIn()
    await rig.account.stopSync()
    // An account with no sign-in method yet has nothing to confirm with, and needs nothing.
    let ceremony = try await rig.account.appleLinkBegin(stepUp: nil)
    #expect(await rig.fake.appleLinkBegins == [AppleBeginRequest()])
    let linked = try await rig.account.linkApple(
      AppleCredential(identityToken: "jwt", authorizationCode: "code"), ceremonyId: ceremony.ceremonyId)
    #expect(linked.kind == "apple")
    #expect(
      await rig.fake.appleLinkNatives
        == [
          AppleLinkNativeRequest(
            ceremonyId: "fake-apple-ceremony", identityToken: "jwt", authorizationCode: "code")
        ])
    // One Apple ID per account.
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.appleLinkBegin(stepUp: nil)
    }
    #expect(refused?.code == .appleLinked)
  }

  @Test func deleteAccountSignsOutAndEmptiesTheMirror() async throws {
    let rig = try Rig()
    try await rig.signIn()
    await rig.account.stopSync()
    let status = try await rig.account.deleteAccount(stepUp: nil)
    #expect(status.state == .signedOut)
    #expect(await rig.fake.deleteAccountCalls == 1)
    #expect(try rig.store.link() == nil)
    // The device went with the account: the next sign-in offers none.
    #expect(rig.memory.devices(hubURL: "https://hub.test.b4.run").isEmpty)
  }

  /// Final review M8: the sync is stopped before the hub is asked, so the 401 the deleted account gets
  /// cannot sign the phone out "by the hub" first, and the deleted device is still forgotten.
  @Test func deleteAccountStopsTheSyncFirst() async throws {
    let fake = FakeHubAPI()
    let rig = try Rig(fake: fake, makeAPI: { _, _ in SlowDeleteHub(fake: fake) })
    try await rig.signIn()
    try await eventually("the sync's first push") { !(await rig.fake.pushed.isEmpty) }
    #expect(rig.account.sync != nil)
    let status = try await rig.account.deleteAccount(stepUp: nil)
    #expect(status == AccountStatus.Result(state: .signedOut))
    #expect(!rig.changes.all.contains { $0.reason != nil })
    #expect(try rig.store.link() == nil)
    #expect(rig.memory.devices(hubURL: "https://hub.test.b4.run").isEmpty)
    #expect(rig.account.sync == nil)
  }

  @Test func aRefusedDeleteKeepsTheAccountAndSyncsAgain() async throws {
    let fake = FakeHubAPI()
    let refusal = HubError(
      kind: "request_error", code: "shared_org", message: "the account belongs to a shared org", status: 409)
    let rig = try Rig(fake: fake, makeAPI: { _, _ in SlowDeleteHub(fake: fake, refusal: refusal) })
    try await rig.signIn()
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.deleteAccount(stepUp: nil)
    }
    #expect(refused?.code == .sharedOrg)
    #expect(rig.account.accountStatus.state == .signedIn)
    #expect(try rig.store.link() != nil)
    #expect(rig.account.sync != nil)
    #expect(rig.memory.devices(hubURL: "https://hub.test.b4.run").count == 1)
    await rig.account.stopSync()
  }

  // MARK: Suspending the sync

  /// A sync started while the app is suspended begins parked: nothing reaches the hub until
  /// `resumeSync()`.
  @Test func aSignInWhileSuspendedStartsTheSyncParked() async throws {
    let rig = try Rig()
    await rig.account.suspendSync()
    try await rig.signIn()
    #expect(rig.account.sync != nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await rig.fake.pushed.isEmpty)
    #expect(await rig.fake.parkedPulls == 0)

    await rig.account.resumeSync()
    try await eventually("the resumed sync's first push") { !(await rig.fake.pushed.isEmpty) }
    try await eventually("the resumed sync's pull") { await rig.fake.parkedPulls > 0 }
    await rig.account.stopSync()
  }

  /// A refused delete restarts the sync it stopped; while the app is suspended, that sync stays parked.
  @Test func aRefusedDeleteWhileSuspendedRestartsTheSyncParked() async throws {
    let fake = FakeHubAPI()
    let refusal = HubError(
      kind: "request_error", code: "shared_org", message: "the account belongs to a shared org", status: 409)
    let rig = try Rig(fake: fake, makeAPI: { _, _ in SlowDeleteHub(fake: fake, refusal: refusal) })
    await rig.account.suspendSync()
    try await rig.signIn()
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.deleteAccount(stepUp: nil)
    }
    #expect(refused?.code == .sharedOrg)
    #expect(rig.account.sync != nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await rig.fake.pushed.isEmpty)
    #expect(await rig.fake.parkedPulls == 0)

    await rig.account.resumeSync()
    try await eventually("the resumed sync's first push") { !(await rig.fake.pushed.isEmpty) }
    await rig.account.stopSync()
  }

  /// A launch in the background marks the account suspended before its first sync starts.
  @Test func aPreparedSuspensionParksTheFirstSync() async throws {
    let rig = try Rig()
    try await rig.signIn()
    try await eventually("the first push") { !(await rig.fake.pushed.isEmpty) }
    await rig.account.stopSync()
    let before = await rig.fake.pushed.count

    // The app launches again with the link stored, in the background.
    rig.account.prepareSuspended()
    rig.account.startSync()
    #expect(rig.account.sync != nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await rig.fake.pushed.count == before)
    #expect(await rig.fake.parkedPulls == 0)

    await rig.account.resumeSync()
    try await eventually("the resumed sync's push") { await rig.fake.pushed.count > before }
    await rig.account.stopSync()
  }

  /// Final review I2: a sign-in empties a mirror that holds rows with no link (left by a log-out that
  /// another sign-in overtook), so the new account never inherits them.
  @Test func aSignInEmptiesRowsLeftWithoutALink() async throws {
    let rig = try Rig()
    _ = try rig.store.apply(Array(try fixtureAsStored().prefix(4)))
    #expect(try rig.store.link() == nil)
    #expect(try rig.store.thread(id: "thread-1") != nil)
    try await rig.signIn()
    #expect(try rig.store.thread(id: "thread-1") == nil)
    #expect(try rig.store.link() != nil)
    await rig.account.stopSync()
  }

  /// Final review M11: the hub's reason reaches the shared model, which forgets a passkey only on
  /// `unknown_credential`.
  @Test func theHubsReasonIsPassedOn() {
    let unknown = MirrorAccount.accountError(
      HubError(
        kind: "request_error", code: "credential_rejected", message: "no", status: 401,
        reason: HubError.unknownCredential),
      doing: "sign in")
    #expect(unknown.code == .credentialRejected)
    #expect(unknown.details?["reason"]?.stringValue == "unknown_credential")
    let bare = MirrorAccount.accountError(
      HubError(kind: "request_error", code: "credential_rejected", message: "no", status: 401),
      doing: "sign in")
    #expect(bare.details?["reason"] == nil)
  }

  @Test func callsThatNeedTheAccountRefuseWhileSignedOut() async throws {
    let rig = try Rig()
    let refused = await #expect(throws: WorkspaceError.self) { _ = try await rig.account.identities() }
    #expect(refused?.code == .signedOut)
    #expect(await rig.fake.meCalls == 0)
  }

  @Test func aRefusalKeepsItsCodeAndNoSecret() async throws {
    let rig = try Rig()
    await rig.fake.setFailNext(
      HubError(kind: "request_error", code: "credential_rejected", message: "no", status: 401))
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.signIn(
        passkey: AccountPasskeyFinish.Params(ceremonyId: "c", assertion: ["id": "secret-assertion"]))
    }
    #expect(refused?.code == .credentialRejected)
    #expect(refused?.message.contains("secret-assertion") == false)
    #expect(rig.account.accountStatus.state == .signedOut)
    let unreachable = try Rig()
    await unreachable.fake.setFailNext(
      HubError(kind: "execution_error", code: "transport", message: "offline", status: 0))
    let down = await #expect(throws: WorkspaceError.self) { _ = try await unreachable.account.passkeyBegin() }
    #expect(down?.code == .endpointUnavailable)
  }

  // MARK: Enrollment codes (an operator's hub, and M8c's pairing)

  @Test func enrollingWithACodeSignsIn() async throws {
    let fake = FakeHubAPI(enrollmentCodes: [
      "K7M2Q9XP": EnrollResponse(
        deviceId: "dev-phone", token: "tok-enrolled", org: OrgInfo(slug: "cacheplane", name: "cacheplane"),
        user: UserInfo(username: "blove", displayName: "Brian Love"))
    ])
    let rig = try Rig(fake: fake)
    let status = try await rig.account.enroll(
      url: "http://localhost:8080", code: " k7m2q9xp ", deviceName: "")
    #expect(status.state == .signedIn)
    #expect(status.account?.orgName == "cacheplane")
    #expect(try rig.store.link()?.hubURL == "http://localhost:8080")
    #expect(try rig.store.link()?.deviceName == "iPhone")
    #expect(try await rig.token() == "tok-enrolled")
    await rig.account.stopSync()
  }
}

@Suite struct PhoneFlavorTests {
  @Test func theStorageNamesFollowTheFlavour() {
    // Prod keeps the names every earlier build used, so nothing moves.
    #expect(PhoneFlavor.prod.directoryName == "b4app")
    #expect(PhoneFlavor.prod.keychainService == "b4app")
    #expect(PhoneFlavor.beta.directoryName == "b4app-beta")
    #expect(PhoneFlavor.beta.keychainService == "b4app-beta")
    #expect(PhoneFlavor.local.directoryName == "b4app-local")
    #expect(PhoneFlavor.local.keychainService == "b4app-local")
  }

  @Test func theHubAndTheSiteFollowTheFlavour() {
    #expect(PhoneFlavor.prod.hubURL.absoluteString == "https://hub.b4.run")
    #expect(PhoneFlavor.beta.hubURL.absoluteString == "https://hub.test.b4.run")
    #expect(PhoneFlavor.local.hubURL.absoluteString == "http://localhost:8080")
    #expect(PhoneFlavor.allCases.map(\.siteDomain) == ["b4.run", "test.b4.run", "local.b4.run"])
    #expect(PhoneFlavor.allCases.map(\.appleSignIn) == [true, true, false])
    #expect(PhoneFlavor.allCases.map(\.badge) == [nil, "Test hub", "Local hub"])
    #expect(PhoneFlavor.allCases.map(\.urlScheme) == ["b4app", "b4app-beta", "b4app-local"])
  }

  @Test func theFlavourComesFromTheEnvironmentThenTheInfoPlist() {
    #expect(PhoneFlavor.resolve(environment: [:], info: ["B4AppFlavor": "beta"]) == .beta)
    #expect(
      PhoneFlavor.resolve(environment: ["B4APP_FLAVOR": "prod"], info: ["B4AppFlavor": "beta"]) == .prod)
    #expect(
      PhoneFlavor.resolve(environment: ["B4APP_FLAVOR": "nope"], info: ["B4AppFlavor": "nope"]) == .local)
    #expect(PhoneFlavor.resolve(environment: [:], info: [:]) == .local)
  }

  @Test func theRememberedDeviceSurvivesARelaunch() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "device-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let memory = MirrorDeviceMemory(url: url)
    #expect(memory.all().isEmpty)
    memory.remember(MirrorRememberedDevice(hubURL: "https://hub.b4.run", deviceId: "d1"))
    memory.remember(MirrorRememberedDevice(hubURL: "https://hub.test.b4.run", deviceId: "t1"))
    memory.remember(MirrorRememberedDevice(hubURL: "https://hub.b4.run", deviceId: "d2"))
    #expect(MirrorDeviceMemory(url: url).devices(hubURL: "https://hub.b4.run") == ["d2", "d1"])
    // Signing in again on a known device brings it to the front, once.
    memory.remember(MirrorRememberedDevice(hubURL: "https://hub.b4.run", deviceId: "d1"))
    #expect(memory.devices(hubURL: "https://hub.b4.run") == ["d1", "d2"])
    memory.forget(hubURL: "https://hub.b4.run", deviceId: "d1")
    #expect(MirrorDeviceMemory(url: url).devices(hubURL: "https://hub.b4.run") == ["d2"])
    memory.clear()
    #expect(MirrorDeviceMemory(url: url).all().isEmpty)
  }

  @Test func atMostEightDevicesAreRememberedForEachHub() {
    let memory = MirrorDeviceMemory(url: nil)
    memory.remember(MirrorRememberedDevice(hubURL: "https://other.example.com", deviceId: "o1"))
    for n in 1...12 {
      memory.remember(MirrorRememberedDevice(hubURL: "https://hub.b4.run", deviceId: "d\(n)"))
    }
    #expect(MirrorDeviceMemory.limit == 8)
    #expect(memory.devices(hubURL: "https://hub.b4.run") == (5...12).reversed().map { "d\($0)" })
    // Another hub's devices are not crowded out.
    #expect(memory.devices(hubURL: "https://other.example.com") == ["o1"])
  }

  /// Task 13's carry: a `b4app*://auth?handoff=` (or `?error=`) opened on the phone is no pairing link,
  /// so nothing redeems it.
  @Test func aStrayAuthCallbackIsNoPairingLink() {
    for text in [
      "b4app://auth?handoff=H-stray", "b4app-beta://auth?error=cancelled", "b4app-local://auth?handoff=x",
    ] {
      for flavor in PhoneFlavor.allCases {
        #expect(flavor.pairLinkDecision(URL(string: text)!) == .ignored, "\(text)")
      }
    }
  }
}
