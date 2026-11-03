import CryptoKit
import Foundation
import Testing
import WorkspaceClient
import WorkspaceMirror
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync

@testable import WorkspaceUI

// Sign in with Apple in the apps, and the iPhone's own sign-in (sign-in plan, Task 14). The Mac runs
// Apple's web flow through the coordinator; the phone runs the native sheet against its hub through its
// host (`MirrorAccount`, as the app wires it).

/// The app's own declaration (`MirrorHost.swift`): the phone's account is the model's host.
extension MirrorAccount: AccountHost {}

// MARK: - Fixtures

private let theAccount = AccountStatus.Account(
  id: "a1b2c3d4e5f60718", displayName: "Brian Love", orgName: "Brian's Org",
  hubURL: "https://hub.test.b4.run")
private let signedIn = AccountStatus.Result(state: .signedIn, account: theAccount)
private let signedOut = AccountStatus.Result(state: .signedOut)
private let beta = SignInConfiguration(siteDomain: "test.b4.run", appleSignIn: true, badge: "Test hub")
private let local = SignInConfiguration(siteDomain: "local.b4.run", appleSignIn: false, badge: "Local hub")

private func onboarding(name: String = "") -> AccountStatus.Result {
  var account = theAccount
  account.displayName = name
  account.orgName = "My Org"
  return AccountStatus.Result(state: .needsOnboarding, account: account)
}

private func status(_ result: AccountStatus.Result) throws -> ScriptedTransport.Reply {
  .result(try JSONValue(encoding: result))
}

private func reply<T: Encodable>(_ value: T) throws -> ScriptedTransport.Reply {
  .result(try JSONValue(encoding: value))
}

private func start(_ ceremony: String) -> ScriptedTransport.Reply {
  .result([
    "url": .string("https://hub.test.b4.run/v1/auth/apple/start?ceremony=\(ceremony)"),
    "callbackScheme": "b4app-beta",
  ])
}

private let registrationOptions: JSONValue = [
  "publicKey": [
    "challenge": "SaCNwlH3QwCt591RUpzizyufYVups0FttxAuD4EuN98",
    "rp": ["id": "test.b4.run", "name": "b4.run"],
    "user": ["id": "x1DZeP_JTHG6OCuGv4E2CQ", "name": "Agent Workspace account"],
  ]
]
private let assertionOptions: JSONValue = [
  "publicKey": ["challenge": "RRV2OiwiBN1y1E_3XWanjdAsGI1ZRVftjhQ7nNxaM5U", "rpId": "test.b4.run"]
]

/// A Mac model connected to a scripted coordinator that first answers `account.status` with `initial`.
@MainActor
private func mac(
  _ initial: AccountStatus.Result, transport: ScriptedTransport, configuration: SignInConfiguration = beta
) async throws -> WorkspaceModel {
  transport.script(.accountStatus, [try status(initial)])
  let model = WorkspaceModel(transportProvider: { transport })
  model.signInConfiguration = configuration
  model.connect()
  try #require(await model.settledLink() == .ready, "\(model.linkMessage ?? "")")
  return model
}

/// The phone as the app wires it: a mirror, its account over one fake hub, and the model with the
/// account as its host.
@MainActor
private struct Phone {
  let store: MirrorStore
  let fake: FakeHubAPI
  let account: MirrorAccount
  let model: WorkspaceModel

  init(
    fake: FakeHubAPI = FakeHubAPI(), configuration: SignInConfiguration = beta, api: (any HubAPI)? = nil
  ) async throws {
    let store = try MirrorStore.inMemory()
    self.store = store
    self.fake = fake
    let hub: any HubAPI = api ?? fake
    account = MirrorAccount(
      store: store, secrets: MemorySecretStore(),
      configuration: MirrorAccount.Configuration(
        hubURL: URL(string: "https://hub.test.b4.run")!, deviceName: "Brian's iPhone",
        syncBackoff: .milliseconds(20)),
      memory: MirrorDeviceMemory(url: nil), makeAPI: { _, _ in hub })
    let model = WorkspaceModel(
      transportProvider: { MirrorTransport(store: store, version: "test") }, accountSource: .host)
    model.signInConfiguration = configuration
    model.accountHost = account
    account.onChange = { [weak model] in model?.applyHostAccount($0) }
    self.model = model
    model.connect()
    try #require(await model.settledLink() == .ready, "\(model.linkMessage ?? "")")
  }

  /// Signed in as a named account, through the model, as the sign-in screen does it.
  func signIn(onboarding: Bool = false) async throws {
    await fake.setSession(
      AuthSession(
        deviceId: "0198aaaa-0000-7000-8000-000000000001", token: "tok-phone-secret",
        org: OrgInfo(slug: "o-abc", name: "Brian's Org"),
        user: UserInfo(username: "u-abc", displayName: "Brian Love"),
        needsOnboarding: onboarding, userId: "0197bbbb-0000-7000-8000-000000000001"))
    await model.signInWithPasskey(using: FakePasskeys())
    try #require(model.accountState != .signedOut(reason: nil), "\(model.signInProgress)")
  }

  func close() async {
    await account.stopSync()
    await model.disconnect()
  }
}

/// Stands in for Apple's sheets: the native one answers `native`, the web one `web`. Records what it
/// was handed.
@MainActor
private final class FakeApple: AppleCeremony {
  var native: Result<AppleCredential?, any Error> = .success(
    AppleCredential(identityToken: "jwt-secret-1", authorizationCode: "code-secret-1", fullName: "Brian Love")
  )
  var web: Result<URL?, any Error> = .success(URL(string: "b4app-beta://auth?handoff=H-one-time")!)
  private(set) var nonces: [String] = []
  private(set) var opened: [(url: URL, scheme: String)] = []
  /// Runs inside the web sheet, before it answers: while the ceremony is in flight.
  var whileOpen: (() -> Void)?

  func nativeSignIn(nonce: String) async throws -> AppleCredential? {
    nonces.append(nonce)
    return try native.get()
  }

  func webSignIn(url: URL, callbackScheme: String) async throws -> URL? {
    opened.append((url, callbackScheme))
    whileOpen?()
    return try web.get()
  }
}

/// Stands in for the passkey sheet: a credential for the assertion, a new one for a registration, and
/// what it was asked to rename.
@MainActor
private final class FakePasskeys: PasskeyCeremony {
  var hasPasskey = true
  private(set) var renamed: [(relyingParty: String, userHandle: Data, name: String)] = []
  private(set) var reportedUnknown: [(relyingParty: String, credentialID: Data)] = []

  func reportUnknownCredential(relyingParty: String, credentialID: Data) async {
    reportedUnknown.append((relyingParty, credentialID))
  }

  func assert(_ options: JSONValue) async throws -> JSONValue? {
    hasPasskey ? ["id": "cred", "rawId": "cred", "type": "public-key"] : nil
  }

  func register(_ options: JSONValue) async throws -> JSONValue {
    ["id": "bmV3", "rawId": "bmV3", "type": "public-key"]
  }

  func renamePasskey(relyingParty: String, userHandle: Data, name: String) async {
    renamed.append((relyingParty, userHandle, name))
  }
}

/// The fake hub, except that every passkey sign-in is refused `credential_rejected`, with `reason`
/// (as the hub refuses a deleted account's passkey) or without (as for a bad signature).
private struct RejectingPasskeyHub: HubAPI {
  let fake: FakeHubAPI
  var reason: String?
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
    throw HubError(
      kind: "request_error", code: "credential_rejected", message: "the credential could not be verified",
      status: 401, reason: reason)
  }
}

private func sha256Hex(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Tests

@MainActor
@Suite(.serialized) struct AppleSignInTests {
  // MARK: The Mac's web flow

  @Test func macWebFlowPassesHandoffToCoordinator() async throws {
    let transport = ScriptedTransport()
    let model = try await mac(signedOut, transport: transport)
    transport.script(.accountAppleStart, [start("x")])
    transport.script(.accountAppleFinish, [try status(onboarding(name: "Brian Love"))])
    let apple = FakeApple()
    apple.web = .success(URL(string: "b4app-local://auth?handoff=X&state=ignored&extra=1")!)
    await model.signInWithApple(using: apple)
    #expect(
      apple.opened.map(\.url.absoluteString) == ["https://hub.test.b4.run/v1/auth/apple/start?ceremony=x"])
    #expect(apple.opened.map(\.scheme) == ["b4app-beta"])
    // Only the handoff goes on, and nothing else of the URL.
    #expect(transport.calls(.accountAppleFinish) == [["handoff": "X"]])
    // The Mac never runs the native sheet: its token would enter the app.
    #expect(apple.nonces.isEmpty)
    #expect(model.accountState == .needsOnboarding(prefillName: "Brian Love"))
    #expect(model.signInProgress == SignInProgress())
  }

  // MARK: The iPhone's native flow

  @Test func iosNativeSendsTokenAndName() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    #expect(phone.model.rootScreen == .signIn)
    await phone.fake.setSession(
      AuthSession(
        deviceId: "dev-phone", token: "tok-phone-secret", org: OrgInfo(slug: "o-new", name: "My Org"),
        user: UserInfo(username: "u-new", displayName: "Brian Love"), needsOnboarding: true))
    let apple = FakeApple()
    await phone.model.signInWithApple(using: apple)

    // The sheet got the ceremony's nonce; the system ceremony hands Apple its SHA-256 hex.
    #expect(apple.nonces == ["fake-nonce"])
    #expect(SystemAppleCeremony.requestNonce("fake-nonce") == sha256Hex("fake-nonce"))
    #expect(apple.opened.isEmpty)
    let sent = try #require(await phone.fake.appleNatives.last)
    #expect(sent.ceremonyId == "fake-apple-ceremony")
    #expect(sent.identityToken == "jwt-secret-1")
    #expect(sent.authorizationCode == "code-secret-1")
    #expect(sent.fullName == "Brian Love")
    #expect(sent.device.platform == "ios")
    #expect(phone.model.accountState == .needsOnboarding(prefillName: "Brian Love"))
    #expect(phone.model.rootScreen == .onboarding)
    // Nothing of the credential is kept in the model.
    #expect(!String(describing: phone.model.signInProgress).contains("jwt-secret-1"))
    #expect(!String(describing: phone.model.accountStatus).contains("tok-phone-secret"))
  }

  @Test func appleCancelShowsNothing() async throws {
    // The phone: the sheet closed.
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    let apple = FakeApple()
    apple.native = .success(nil)
    await phone.model.signInWithApple(using: apple)
    apple.native = .failure(SignInCanceled())
    await phone.model.signInWithApple(using: apple)
    #expect(phone.model.signInProgress == SignInProgress())
    #expect(await phone.fake.appleNatives.isEmpty)
    #expect(phone.model.accountState == .signedOut(reason: nil))

    // The Mac: the session closed, or Cancel on Apple's own page (`?error=cancelled`).
    let transport = ScriptedTransport()
    let model = try await mac(signedOut, transport: transport)
    transport.script(.accountAppleStart, [start("a"), start("b"), start("c")])
    let web = FakeApple()
    web.web = .success(nil)
    await model.signInWithApple(using: web)
    web.web = .failure(SignInCanceled())
    await model.signInWithApple(using: web)
    web.web = .success(URL(string: "b4app-beta://auth?error=cancelled")!)
    await model.signInWithApple(using: web)
    #expect(web.opened.count == 3)
    #expect(model.signInProgress == SignInProgress())
    #expect(transport.calls(.accountAppleFinish).isEmpty)
    #expect(!SignInContent(model: model).elements.contains { $0.id == "signIn.failure" })
  }

  @Test func aRefusedNativeSignInIsOneLine() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    await phone.fake.setFailNext(
      HubError(kind: "request_error", code: "signup_closed", message: "closed", status: 403))
    await phone.model.signInWithApple(using: FakeApple())
    #expect(phone.model.signInProgress.failure == SignInCopy.failure(for: WorkspaceError(.signupClosed, "")))
  }

  // MARK: Stray callbacks (Task 13's carry)

  @Test func aStrayCallbackIsDroppedOnTheMac() async throws {
    let transport = ScriptedTransport()
    let model = try await mac(signedOut, transport: transport)
    let before = transport.methods()
    for text in [
      "b4app-beta://auth?handoff=H-stray", "b4app-beta://auth?error=signup_closed", "b4app://auth",
    ] {
      #expect(model.openURL(URL(string: text)!), "\(text)")
    }
    #expect(transport.methods() == before)
    #expect(model.signInProgress == SignInProgress())
    #expect(model.accountState == .signedOut(reason: nil))
    // Not an auth callback: not the model's to drop.
    #expect(!model.openURL(URL(string: "b4app://pair?hub=https://hub.b4.run&code=K7M2Q9XP")!))
    #expect(!model.openURL(URL(string: "https://b4.run/pair#c=K7M2Q9XP")!))

    // Nor during a ceremony: the ceremony's callback comes from its own session, never from a URL
    // the app was handed.
    transport.script(.accountAppleStart, [start("x")])
    transport.script(.accountAppleFinish, [try status(signedIn)])
    let apple = FakeApple()
    var droppedWhileOpen: Bool?
    apple.whileOpen = {
      // Apple's page is up: the sign-in has begun and not finished.
      #expect(model.signInProgress.inFlight == .apple)
      #expect(transport.calls(.accountAppleStart).count == 1)
      #expect(transport.calls(.accountAppleFinish).isEmpty)
      droppedWhileOpen = model.openURL(URL(string: "b4app-beta://auth?handoff=H-second")!)
    }
    await model.signInWithApple(using: apple)
    #expect(droppedWhileOpen == true)
    #expect(transport.calls(.accountAppleFinish) == [["handoff": "H-one-time"]])
    #expect(model.accountState == .signedIn)
  }

  /// Apple's sheet names itself when there is no window to show it in (the test process has none).
  @Test func appleSheetSaysItHasNoWindow() async {
    let refused = await #expect(throws: WorkspaceError.self) {
      _ = try await SystemAppleCeremony(session: nil).nativeSignIn(nonce: "n")
    }
    #expect(refused?.message == "There is no window to show Sign in with Apple in.")
  }

  @Test func aStrayCallbackIsDroppedOnThePhone() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    #expect(phone.model.openURL(URL(string: "b4app-beta://auth?handoff=H-stray")!))
    #expect(phone.model.openURL(URL(string: "b4app://auth?error=cancelled")!))
    #expect(await phone.fake.handoffs.isEmpty)
    #expect(await phone.fake.appleNatives.isEmpty)
    #expect(phone.model.accountState == .signedOut(reason: nil))
    #expect(phone.model.signInProgress == SignInProgress())
  }

  // MARK: The phone's sign-in, root, and log out

  @Test func thePhoneSignsInAndOutThroughItsHost() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    #expect(phone.model.rootScreen == .signIn)
    try await phone.signIn()
    #expect(phone.model.accountState == .signedIn)
    #expect(phone.model.rootScreen == .workspace)
    #expect(await phone.fake.passkeyFinishes.count == 1)
    #expect(try phone.store.link()?.deviceId == "0198aaaa-0000-7000-8000-000000000001")
    // The profile button names the account.
    try await waitUntil("the profile") { phone.model.account?.name == "Brian Love" }

    await phone.model.logOut()
    #expect(phone.model.accountState == .signedOut(reason: nil))
    #expect(phone.model.rootScreen == .signIn)
    #expect(await phone.fake.endSessionCalls == 1)
    #expect(try phone.store.link() == nil)
    #expect(phone.model.account == nil)

    // Onboarding's "Not you? Log out" goes to the host too.
    try await phone.signIn(onboarding: true)
    #expect(phone.model.rootScreen == .onboarding)
    #expect(await phone.model.logOut(stopWork: false) == .loggedOut)
    #expect(phone.model.rootScreen == .signIn)
  }

  @Test func onboardingOnThePhoneSignsIn() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    try await phone.signIn(onboarding: true)
    await phone.model.completeProfile(fullName: "  Brian Love ")
    #expect(await phone.fake.profiles == [ProfileRequest(fullName: "Brian Love")])
    #expect(phone.model.accountState == .signedIn)
    #expect(phone.model.rootScreen == .workspace)
    // Only the Mac offers "Add your iPhone".
    #expect(phone.model.showAddPhone == false)
  }

  /// Final review M11 on the phone: the hub refuses the passkey of a deleted account as unknown; the
  /// phone reports it, through the same ceremony, so it is not offered again. A refusal without that
  /// reason reports nothing.
  @Test func aRefusedPasskeySignInOnThePhoneReportsThePasskeyOnlyWhenUnknown() async throws {
    for reason in [String?.none, HubError.unknownCredential] {
      let fake = FakeHubAPI()
      await fake.setPasskeyBegin(
        PasskeyBeginResponse(
          ceremonyId: "c1", authentication: assertionOptions, registration: registrationOptions))
      let phone = try await Phone(fake: fake, api: RejectingPasskeyHub(fake: fake, reason: reason))
      let passkeys = FakePasskeys()
      await phone.model.signInWithPasskey(using: passkeys)
      #expect(phone.model.accountState == .signedOut(reason: nil))
      #expect(phone.model.signInProgress.failure != nil)
      if reason == nil {
        #expect(passkeys.reportedUnknown.isEmpty)
      } else {
        #expect(passkeys.reportedUnknown.map(\.relyingParty) == ["test.b4.run"])
        #expect(
          passkeys.reportedUnknown.map(\.credentialID) == [try #require(WebAuthnJSON.data(base64URL: "cred"))]
        )
      }
      await phone.close()
    }
  }

  @Test func a401MovesThePhoneToSignIn() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    try await phone.signIn()
    try await waitUntil("the sync's first push", timeout: .seconds(10)) { phone.account.sync != nil }
    // The hub ends the session (another device removed this one): the next sync call is a 401.
    try await phone.fake.endSession()
    try await waitUntil("signed out", timeout: .seconds(10)) { phone.model.rootScreen == .signIn }
    #expect(phone.model.accountState == .signedOut(reason: "This iPhone was signed out of Brian's Org."))
    #expect(SignInContent(model: phone.model).reason?.text == "This iPhone was signed out of Brian's Org.")
    #expect(try phone.store.link() == nil)
  }

  @Test func aHostWithoutAnAccountStillShowsTheWorkspace() async throws {
    // A host that does not own a sign-in (an unreadable mirror) keeps today's behaviour.
    let store = try MirrorStore.inMemory()
    let model = WorkspaceModel(
      transportProvider: { MirrorTransport(store: store, version: "test") }, accountSource: .host)
    model.connect()
    #expect(await model.settledLink() == .ready)
    #expect(model.rootScreen == .workspace)
    #expect(model.settingsAvailable)
    await model.disconnect()
  }

  // MARK: Connect Apple ID

  @Test func connectAppleIDOnTheMac() async throws {
    let transport = ScriptedTransport()
    let model = try await mac(signedIn, transport: transport)
    let passkey = AccountIdentity(id: "i1", kind: "passkey", createdAt: "2026-11-01T09:00:00Z")
    transport.script(.accountIdentities, [try reply(AccountIdentities.Result(identities: [passkey]))])
    await model.refreshIdentities()
    #expect(AccountSettingsContent(model: model).connectApple == "Connect Apple ID")

    // Each try is confirmed with the account's passkey first (D-135).
    let passkeys = FakePasskeys()
    let confirm: ScriptedTransport.Reply = .result([
      "ceremonyId": "s1", "authentication": ["publicKey": ["challenge": "c3RlcA", "rpId": "test.b4.run"]],
    ])
    transport.script(.accountStepUpBegin, Array(repeating: confirm, count: 5))
    // Closed sheet, or Cancel on Apple's page: nothing, and nothing redeemed.
    let apple = FakeApple()
    transport.script(.accountAppleLinkStart, [start("l1"), start("l2"), start("l3"), start("l4")])
    apple.web = .success(nil)
    await model.connectAppleID(using: apple, passkey: passkeys)
    apple.web = .success(URL(string: "b4app-beta://auth?error=cancelled")!)
    await model.connectAppleID(using: apple, passkey: passkeys)
    #expect(model.accountSettingsFailure == nil)
    #expect(transport.calls(.accountAppleLinkFinish).isEmpty)

    // Already linked elsewhere in the meantime: one line.
    apple.web = .success(URL(string: "b4app-beta://auth?error=apple_linked")!)
    await model.connectAppleID(using: apple, passkey: passkeys)
    #expect(model.accountSettingsFailure == AccountCopy.alreadyApple)

    let linked = AccountIdentity(
      id: "i2", kind: "apple", name: "x@privaterelay.appleid.com", createdAt: "2026-11-02T09:00:00Z")
    transport.script(.accountAppleLinkFinish, [try reply(AccountAppleLinkFinish.Result(identity: linked))])
    apple.web = .success(URL(string: "b4app-beta://auth?handoff=L-one-time")!)
    await model.connectAppleID(using: apple, passkey: passkeys)
    #expect(transport.calls(.accountAppleLinkFinish) == [["handoff": "L-one-time"]])
    #expect(
      transport.calls(.accountAppleLinkStart).last
        == [
          "stepUp": ["ceremonyId": "s1", "assertion": ["id": "cred", "rawId": "cred", "type": "public-key"]]
        ])
    #expect(apple.nonces.isEmpty)
    #expect(model.accountSettingsFailure == nil)
    #expect(model.identities?.map(\.kind) == ["passkey", "apple"])
    #expect(AccountSettingsContent(model: model).connectApple == nil)

    // A refusal at the start (the hub's `apple_linked`) is the same line.
    transport.script(.accountAppleLinkStart, [.failure(WorkspaceError(.appleLinked, "has one"))])
    await model.connectAppleID(using: apple, passkey: passkeys)
    #expect(model.accountSettingsFailure == AccountCopy.alreadyApple)
  }

  @Test func connectAppleIDIsHiddenLocallyAndWhenLinked() async throws {
    let transport = ScriptedTransport()
    let model = try await mac(signedIn, transport: transport, configuration: local)
    transport.script(
      .accountIdentities,
      [
        try reply(
          AccountIdentities.Result(identities: [AccountIdentity(id: "i1", kind: "passkey", createdAt: "x")]))
      ])
    await model.refreshIdentities()
    #expect(AccountSettingsContent(model: model).connectApple == nil)
    model.signInConfiguration = SignInConfiguration(siteDomain: "b4.run", appleSignIn: true, badge: nil)
    #expect(AccountSettingsContent(model: model).connectApple == "Connect Apple ID")
  }

  @Test func connectAppleIDOnThePhone() async throws {
    let phone = try await Phone()
    defer { Task { await phone.close() } }
    try await phone.signIn()
    await phone.fake.setIdentities([Identity(id: "i1", kind: "passkey", createdAt: "2026-11-01T09:00:00Z")])
    await phone.model.refreshIdentities()
    #expect(phone.model.identities?.map(\.id) == ["i1"])
    #expect(AccountSettingsContent(model: phone.model).connectApple == "Connect Apple ID")

    let apple = FakeApple()
    apple.native = .success(nil)
    await phone.model.connectAppleID(using: apple, passkey: FakePasskeys())
    #expect(await phone.fake.appleLinkNatives.isEmpty)
    #expect(phone.model.accountSettingsFailure == nil)

    apple.native = .success(AppleCredential(identityToken: "jwt-link", authorizationCode: "code-link"))
    await phone.model.connectAppleID(using: apple, passkey: FakePasskeys())
    #expect(apple.nonces == ["fake-nonce", "fake-nonce"])
    #expect(apple.opened.isEmpty)
    // The phone confirmed with its passkey each time, finishing the step-up itself.
    #expect(await phone.fake.stepUpFinishes.count == 2)
    #expect(
      await phone.fake.appleLinkNatives
        == [
          AppleLinkNativeRequest(
            ceremonyId: "fake-apple-ceremony", identityToken: "jwt-link", authorizationCode: "code-link")
        ])
    #expect(phone.model.identities?.map(\.kind) == ["passkey", "apple"])
    #expect(AccountSettingsContent(model: phone.model).connectApple == nil)

    // The account has one now: the hub's `apple_linked` is one line.
    await phone.model.connectAppleID(using: apple, passkey: FakePasskeys())
    #expect(phone.model.accountSettingsFailure == AccountCopy.alreadyApple)
  }

  // MARK: Renaming the passkey after onboarding

  @Test func thePasskeyIsRenamedAfterOnboarding() async throws {
    let transport = ScriptedTransport()
    let model = try await mac(signedOut, transport: transport)
    transport.script(
      .accountPasskeyBegin,
      [
        try reply(
          AccountPasskeyBegin.Result(
            ceremonyId: "c1", authentication: assertionOptions, registration: registrationOptions))
      ])
    transport.script(.accountPasskeyFinish, [try status(onboarding())])
    let passkeys = FakePasskeys()
    passkeys.hasPasskey = false
    await model.signInWithPasskey(using: passkeys)
    await model.confirmCreateAccount()
    #expect(model.accountState == .needsOnboarding(prefillName: nil))
    #expect(passkeys.renamed.isEmpty)

    transport.script(.accountCompleteProfile, [try status(signedIn), try status(signedIn)])
    await model.completeProfile(fullName: " Brian Love ")
    #expect(passkeys.renamed.count == 1)
    let renamed = try #require(passkeys.renamed.first)
    #expect(renamed.relyingParty == "test.b4.run")
    #expect(renamed.userHandle == WebAuthnJSON.data(base64URL: "x1DZeP_JTHG6OCuGv4E2CQ"))
    #expect(renamed.name == "Brian Love")
    // Once: changing the name later in Settings renames nothing.
    await model.updateFullName("Bri Love")
    #expect(passkeys.renamed.count == 1)
  }

  @Test func anAppleSignUpAfterAnUnfinishedPasskeySignUpRenamesNothing() async throws {
    let transport = ScriptedTransport()
    let model = try await mac(signedOut, transport: transport)
    transport.script(
      .accountPasskeyBegin,
      [
        try reply(
          AccountPasskeyBegin.Result(
            ceremonyId: "c1", authentication: assertionOptions, registration: registrationOptions))
      ])
    transport.script(.accountPasskeyFinish, [try status(onboarding())])
    let passkeys = FakePasskeys()
    passkeys.hasPasskey = false
    await model.signInWithPasskey(using: passkeys)
    await model.confirmCreateAccount()
    // "Not you? Log out" (here, the coordinator signing out), then a new account with Apple.
    transport.emit(try AdapterEvent.accountChanged(signedOut))
    try await waitUntil("signed out") { model.accountState == .signedOut(reason: nil) }
    transport.script(.accountAppleStart, [start("x")])
    transport.script(.accountAppleFinish, [try status(onboarding(name: "Brian Love"))])
    await model.signInWithApple(using: FakeApple())
    transport.script(.accountCompleteProfile, [try status(signedIn)])
    await model.completeProfile(fullName: "Brian Love")
    #expect(model.accountState == .signedIn)
    #expect(passkeys.renamed.isEmpty)
  }

  // MARK: Flavours

  @Test func thePhoneFlavourAgreesWithTheMacs() {
    for flavor in Flavor.allCases {
      let phone = PhoneFlavor(rawValue: flavor.rawValue)
      #expect(phone?.hubURL == flavor.hubURL)
      #expect(phone?.siteDomain == flavor.siteDomain)
      #expect(phone?.appleSignIn == flavor.appleSignIn)
      #expect(phone?.badge == flavor.badge)
      #expect(phone?.urlScheme == flavor.urlScheme)
      #expect(phone?.dirSuffix == flavor.dirSuffix)
    }
    #expect(PhoneFlavor.allCases.count == Flavor.allCases.count)
  }

  @Test func theNoncesAreHashedAndNeverPrinted() {
    let ceremony = AppleNativeCeremony(ceremonyId: "c", nonce: "secret-nonce")
    #expect(!ceremony.description.contains("secret-nonce"))
    let credential = AppleCredential(
      identityToken: "jwt-7731", authorizationCode: "c0de-7731", fullName: "Brian")
    #expect(!credential.description.contains("7731"))
    #expect(
      !String(reflecting: credential).contains("7731") && !String(reflecting: credential).contains("Brian"))
    #expect(
      SystemAppleCeremony.requestNonce("abc")
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }
}
