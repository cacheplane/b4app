import Foundation
import SwiftUI
import Synchronization
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

// MARK: - Fixtures

private let theAccount = AccountStatus.Account(
  id: "a1b2c3d4e5f60718", displayName: "Brian Love", orgName: "Brian's Org",
  hubURL: "https://hub.test.b4.run")
private let signedIn = AccountStatus.Result(state: .signedIn, account: theAccount)
private let signedOut = AccountStatus.Result(state: .signedOut)

private func onboarding(name: String) -> AccountStatus.Result {
  var account = theAccount
  account.displayName = name
  account.orgName = "My Org"
  return AccountStatus.Result(state: .needsOnboarding, account: account)
}

private let beta = SignInConfiguration(siteDomain: "test.b4.run", appleSignIn: true, badge: "Test hub")
private let prod = SignInConfiguration(siteDomain: "b4.run", appleSignIn: true, badge: nil)
private let local = SignInConfiguration(siteDomain: "local.b4.run", appleSignIn: false, badge: "Local hub")

private let assertionOptions: JSONValue = [
  "publicKey": ["challenge": "RRV2OiwiBN1y1E_3XWanjdAsGI1ZRVftjhQ7nNxaM5U", "rpId": "test.b4.run"]
]
private let registrationOptions: JSONValue = [
  "publicKey": [
    "challenge": "SaCNwlH3QwCt591RUpzizyufYVups0FttxAuD4EuN98",
    "rp": ["id": "test.b4.run", "name": "b4.run"],
    "user": ["id": "x1DZeP_JTHG6OCuGv4E2CQ", "name": "Agent Workspace account"],
  ]
]

private func begin(_ ceremonyId: String = "c1") throws -> ScriptedTransport.Reply {
  .result(
    try JSONValue(
      encoding: AccountPasskeyBegin.Result(
        ceremonyId: ceremonyId, authentication: assertionOptions, registration: registrationOptions)))
}

private func status(_ result: AccountStatus.Result) throws -> ScriptedTransport.Reply {
  .result(try JSONValue(encoding: result))
}

/// A connected model whose coordinator first answers `account.status` with `initial`.
@MainActor
private func connected(
  _ initial: AccountStatus.Result, transport: ScriptedTransport = ScriptedTransport(),
  configuration: SignInConfiguration = beta
) async throws -> WorkspaceModel {
  transport.script(.accountStatus, [try status(initial)])
  let model = WorkspaceModel(transportProvider: { transport })
  model.signInConfiguration = configuration
  model.connect()
  let link = await model.settledLink()
  try #require(link == .ready, "the model did not connect: \(model.linkMessage ?? "no message")")
  return model
}

/// Stands in for the system passkey sheet: answers what the test sets and counts the calls.
@MainActor
private final class FakeCeremony: PasskeyCeremony {
  enum Outcome {
    case credential(JSONValue)
    case noCredential
    case cancel
    case failure(any Error)
  }

  var assertOutcome: Outcome = .credential(["id": "cred", "type": "public-key"])
  var registerOutcome: Outcome = .credential(["id": "new-cred", "type": "public-key"])
  private(set) var asserted: [JSONValue] = []
  private(set) var registered: [JSONValue] = []

  func assert(_ options: JSONValue) async throws -> JSONValue? {
    asserted.append(options)
    return try Self.resolve(assertOutcome)
  }

  func register(_ options: JSONValue) async throws -> JSONValue {
    registered.append(options)
    guard let value = try Self.resolve(registerOutcome) else { throw SignInCanceled() }
    return value
  }

  private static func resolve(_ outcome: Outcome) throws -> JSONValue? {
    switch outcome {
    case .credential(let value): return value
    case .noCredential: return nil
    case .cancel: throw SignInCanceled()
    case .failure(let error): throw error
    }
  }
}

/// Stands in for `ASWebAuthenticationSession`: returns the callback URL the test sets.
@MainActor
private final class FakeAppleSession: AppleWebSignIn {
  var callback: Result<URL, any Error> = .success(URL(string: "b4app-beta://auth?handoff=H-one-time")!)
  private(set) var opened: [(url: URL, scheme: String)] = []

  func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    opened.append((url, callbackScheme))
    return try callback.get()
  }
}

// MARK: - Reading a screen

/// The sign-in and onboarding views draw from `SignInContent` and `OnboardingContent`, which give
/// every element the accessibility identifier the view sets; the tests read the screens through them.
extension Array where Element == ScreenElement {
  fileprivate func text(of id: String) -> String? { first { $0.id == id }?.text }
  fileprivate func has(_ id: String) -> Bool { contains { $0.id == id } }
  fileprivate func shows(_ text: String) -> Bool { contains { $0.text.contains(text) } }
}

@MainActor private func signInScreen(_ model: WorkspaceModel) -> [ScreenElement] {
  SignInContent(model: model).elements
}

@MainActor private func onboardingScreen(_ model: WorkspaceModel) -> [ScreenElement] {
  OnboardingContent(model: model).elements
}

// MARK: - Tests

@MainActor
@Suite(.serialized) struct SignInTests {
  // MARK: The root

  @Test func rootShowsSignInWhenSignedOut() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    #expect(model.accountState == .signedOut(reason: nil))
    #expect(model.rootScreen == .signIn)
    // Nothing from a store is read while nobody is signed in.
    #expect(transport.calls(.eventsSnapshot).isEmpty)
  }

  @Test func rejectedByHubNamesTheOrg() async throws {
    let rejected = AccountStatus.Result(state: .signedOut, reason: .rejectedByHub("Brian's Org"))
    let model = try await connected(rejected)
    #expect(model.accountState == .signedOut(reason: "This Mac was signed out of Brian's Org."))
    let tree = signInScreen(model)
    #expect(tree.shows("This Mac was signed out of Brian's Org."))
  }

  @Test func rootShowsOnboardingWhenNeeded() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(onboarding(name: "Brian Love"), transport: transport)
    #expect(model.accountState == .needsOnboarding(prefillName: "Brian Love"))
    #expect(model.rootScreen == .onboarding)
    #expect(transport.calls(.eventsSnapshot).isEmpty)
    // A passkey sign-up has no name to offer: the field starts empty.
    let blank = try await connected(onboarding(name: ""))
    #expect(blank.accountState == .needsOnboarding(prefillName: nil))
  }

  @Test func rootShowsWorkspaceWhenSignedIn() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedIn, transport: transport)
    #expect(model.accountState == .signedIn)
    #expect(model.rootScreen == .workspace)
    #expect(transport.calls(.eventsSnapshot).count == 1)
  }

  @Test func unknownShowsNeither() async throws {
    // A coordinator that has not answered `account.status` yet, as at a launch or a restart.
    let transport = ScriptedTransport()
    transport.script(.accountStatus, [.hold])
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try await waitUntil("account.status sent") { transport.heldCount(.accountStatus) == 1 }
    #expect(model.accountState == .unknown)
    #expect(model.rootScreen == .loading)
    // Signed in all along: straight to the workspace, never through the sign-in screen.
    #expect(transport.release(.accountStatus, with: try status(signedIn)))
    #expect(await model.settledLink() == .ready)
    #expect(model.rootScreen == .workspace)
  }

  @Test func accountChangedMovesTheRoot() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    transport.emit(try .accountChanged(onboarding(name: "")))
    try await waitUntil("onboarding") { model.rootScreen == .onboarding }
    transport.emit(try .accountChanged(signedIn))
    try await waitUntil("workspace") { model.rootScreen == .workspace }
    // Signing in reads the new account's store.
    try await waitUntil("snapshot") { !transport.calls(.eventsSnapshot).isEmpty }
    transport.emit(try .accountChanged(signedOut))
    try await waitUntil("sign-in") { model.rootScreen == .signIn }
    #expect(model.threads.isEmpty && model.account == nil)
  }

  @Test func aSignedOutAnswerWhileSignedInIsNotASignOut() async throws {
    // A refused log-out answers `signed_out` to other commands for a moment; only `account.changed`
    // moves the account.
    let transport = ScriptedTransport()
    let model = try await connected(signedIn, transport: transport)
    transport.script(.projectCreate, [.failure(WorkspaceError(.signedOut, "Nobody is signed in."))])
    _ = await model.createProject(name: "x", folders: [])
    #expect(model.accountState == .signedIn)
    #expect(model.rootScreen == .workspace)
  }

  @Test func aTransportWithoutAccountsShowsTheWorkspace() async throws {
    // The phone's mirror and an older coordinator answer `account.status` as unsupported.
    let transport = ScriptedTransport()
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    #expect(await model.settledLink() == .ready)
    #expect(model.rootScreen == .workspace)
    let host = WorkspaceModel(transportProvider: { transport }, accountSource: .host)
    #expect(host.rootScreen == .workspace)
  }

  // MARK: Passkeys

  @Test func passkeySignInSendsTheAssertionOnce() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    transport.script(.accountPasskeyBegin, [try begin()])
    transport.script(.accountPasskeyFinish, [try status(signedIn)])
    let ceremony = FakeCeremony()
    await model.signInWithPasskey(using: ceremony)
    #expect(ceremony.asserted == [assertionOptions])
    #expect(ceremony.registered.isEmpty)
    let finish = try #require(transport.calls(.accountPasskeyFinish).first)
    #expect(finish["ceremonyId"] == "c1")
    #expect(finish["assertion"] == ["id": "cred", "type": "public-key"])
    #expect(finish["attestation"] == nil)
    #expect(model.accountState == .signedIn)
    #expect(model.signInProgress == SignInProgress())
  }

  @Test func noCredentialAsksBeforeRegistering() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    transport.script(.accountPasskeyBegin, [try begin()])
    transport.script(.accountPasskeyFinish, [try status(onboarding(name: ""))])
    let ceremony = FakeCeremony()
    ceremony.assertOutcome = .noCredential
    await model.signInWithPasskey(using: ceremony)
    #expect(
      model.signInProgress.confirmation == "No passkey for test.b4.run on this device. Create a new account?")
    #expect(model.signInProgress.inFlight == nil)
    #expect(ceremony.registered.isEmpty)
    #expect(transport.calls(.accountPasskeyFinish).isEmpty)
    let tree = signInScreen(model)
    #expect(tree.shows("No passkey for test.b4.run on this device. Create a new account?"))
    #expect(tree.text(of: "signIn.createAccount") == "Create account")
    #expect(tree.text(of: "signIn.cancelCreate") == "Cancel")

    await model.confirmCreateAccount()
    #expect(ceremony.registered == [registrationOptions])
    let finish = try #require(transport.calls(.accountPasskeyFinish).first)
    #expect(finish["ceremonyId"] == "c1")
    #expect(finish["attestation"] == ["id": "new-cred", "type": "public-key"])
    #expect(finish["assertion"] == nil)
    #expect(model.signInProgress.confirmation == nil)
    #expect(model.accountState == .needsOnboarding(prefillName: nil))
  }

  @Test func cancellingTheConfirmationRegistersNothing() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    transport.script(.accountPasskeyBegin, [try begin()])
    let ceremony = FakeCeremony()
    ceremony.assertOutcome = .noCredential
    await model.signInWithPasskey(using: ceremony)
    model.cancelCreateAccount()
    #expect(model.signInProgress == SignInProgress())
    await model.confirmCreateAccount()
    #expect(ceremony.registered.isEmpty)
    #expect(transport.calls(.accountPasskeyFinish).isEmpty)
  }

  @Test func anExpiredCeremonyBeginsAgainBeforeRegistering() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    let clock = Mutex(Date(timeIntervalSince1970: 1_793_000_000))
    model.now = { clock.withLock { $0 } }
    transport.script(.accountPasskeyBegin, [try begin("c1"), try begin("c2")])
    transport.script(.accountPasskeyFinish, [try status(onboarding(name: ""))])
    let ceremony = FakeCeremony()
    ceremony.assertOutcome = .noCredential
    await model.signInWithPasskey(using: ceremony)
    // The person reads the question for longer than the ceremony lives.
    clock.withLock { $0 = $0.addingTimeInterval(6 * 60) }
    await model.confirmCreateAccount()
    #expect(transport.calls(.accountPasskeyBegin).count == 2)
    #expect(transport.calls(.accountPasskeyFinish).first?["ceremonyId"] == "c2")
  }

  @Test func cancelShowsNoError() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    transport.script(.accountPasskeyBegin, [try begin()])
    let ceremony = FakeCeremony()
    ceremony.assertOutcome = .cancel
    await model.signInWithPasskey(using: ceremony)
    #expect(model.signInProgress == SignInProgress())
    #expect(transport.calls(.accountPasskeyFinish).isEmpty)
    #expect(model.lastError == nil)

    // A closed Apple sheet is silent too.
    transport.script(
      .accountAppleStart,
      [
        .result([
          "url": "https://hub.test.b4.run/v1/auth/apple/start?ceremony=x", "callbackScheme": "b4app-beta",
        ])
      ])
    let apple = FakeAppleSession()
    apple.callback = .failure(SignInCanceled())
    await model.signInWithApple(using: apple)
    #expect(model.signInProgress == SignInProgress())
    #expect(transport.calls(.accountAppleFinish).isEmpty)
    let tree = signInScreen(model)
    #expect(!tree.has("signIn.failure"))
  }

  @Test func failureShowsOneLine() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    let ceremony = FakeCeremony()

    // While the call is out, the pressed button says so and both are off.
    transport.script(.accountPasskeyBegin, [try begin()])
    transport.script(.accountPasskeyFinish, [.hold])
    let signingIn = Task { await model.signInWithPasskey(using: ceremony) }
    try await waitUntil("finish sent") { transport.heldCount(.accountPasskeyFinish) == 1 }
    #expect(model.signInProgress.inFlight == .passkey)
    let busy = signInScreen(model)
    #expect(busy.text(of: "signIn.passkey") == "Signing in…")
    #expect(busy.text(of: "signIn.apple") == "Continue with Apple")
    let server = WorkspaceError(.credentialRejected, "webauthn: Signature verification failed (abc123)")
    #expect(transport.release(.accountPasskeyFinish, with: .failure(server)))
    await signingIn.value

    let line = try #require(model.signInProgress.failure)
    #expect(!line.contains("credential_rejected") && !line.contains("webauthn") && !line.contains("abc123"))
    #expect(model.signInProgress.inFlight == nil)
    let tree = signInScreen(model)
    #expect(tree.text(of: "signIn.failure") == line)

    // Each refusal has its own short line; none shows the code or the server's text.
    var lines: Set<String> = [line]
    for code in [
      ErrorCode.signupClosed, .rateLimited, .endpointUnavailable, .ceremonyExpired, .internalError,
    ] {
      transport.script(.accountPasskeyBegin, [.failure(WorkspaceError(code, "raw server text \(code)"))])
      await model.signInWithPasskey(using: ceremony)
      let next = try #require(model.signInProgress.failure)
      #expect(!next.contains(code.rawValue) && !next.contains("raw server text"))
      lines.insert(next)
    }
    #expect(lines.count == 6)
  }

  // MARK: Apple on the Mac

  @Test func appleWebFlowHandsTheCodeToTheCoordinator() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedOut, transport: transport)
    transport.script(
      .accountAppleStart,
      [
        .result([
          "url": "https://hub.test.b4.run/v1/auth/apple/start?ceremony=x", "callbackScheme": "b4app-beta",
        ])
      ])
    transport.script(.accountAppleFinish, [try status(onboarding(name: "Brian Love"))])
    let apple = FakeAppleSession()
    await model.signInWithApple(using: apple)
    #expect(
      apple.opened.map(\.url.absoluteString) == ["https://hub.test.b4.run/v1/auth/apple/start?ceremony=x"])
    #expect(apple.opened.map(\.scheme) == ["b4app-beta"])
    #expect(transport.calls(.accountAppleFinish) == [["handoff": "H-one-time"]])
    #expect(model.accountState == .needsOnboarding(prefillName: "Brian Love"))

    // The hub's refusal comes back in the callback as a code, shown as its line.
    transport.script(
      .accountAppleStart,
      [
        .result([
          "url": "https://hub.test.b4.run/v1/auth/apple/start?ceremony=y", "callbackScheme": "b4app-beta",
        ])
      ])
    apple.callback = .success(URL(string: "b4app-beta://auth?error=signup_closed")!)
    await model.signInWithApple(using: apple)
    #expect(transport.calls(.accountAppleFinish).count == 1)
    #expect(model.signInProgress.failure == SignInCopy.failure(for: WorkspaceError(.signupClosed, "")))
  }

  // MARK: The flavour

  @Test func localFlavourHidesApple() async throws {
    let model = try await connected(signedOut, configuration: local)
    let tree = signInScreen(model)
    #expect(!tree.has("signIn.apple"))
    #expect(tree.has("signIn.passkey"))
    #expect(tree.text(of: "signIn.badge") == "Local hub")

    model.signInConfiguration = prod
    let shipped = signInScreen(model)
    #expect(shipped.has("signIn.apple"))
    // The App Store build has no badge.
    #expect(!shipped.has("signIn.badge"))
  }

  // MARK: Onboarding

  @Test func onboardingValidatesName() async throws {
    #expect(!FullName.isValid(""))
    #expect(!FullName.isValid("   \n "))
    #expect(!FullName.isValid(String(repeating: "x", count: 201)))
    #expect(FullName.isValid(String(repeating: "x", count: 200)))
    #expect(FullName.isValid("  " + String(repeating: "x", count: 200) + "  "))
    #expect(FullName.isValid("Brian Love"))

    let transport = ScriptedTransport()
    let model = try await connected(onboarding(name: ""), transport: transport)
    await model.completeProfile(fullName: "   ")
    await model.completeProfile(fullName: String(repeating: "x", count: 201))
    #expect(transport.calls(.accountCompleteProfile).isEmpty)

    let tree = onboardingScreen(model)
    #expect(tree.has("onboarding.continue"))

    transport.script(.accountCompleteProfile, [try status(signedIn)])
    await model.completeProfile(fullName: "  Brian Love ")
    #expect(transport.calls(.accountCompleteProfile) == [["fullName": "Brian Love"]])
    #expect(model.accountState == .signedIn)
  }

  @Test func onboardingLogOutNeverStopsWork() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(onboarding(name: ""), transport: transport)
    transport.script(.accountLogout, [try status(signedOut)])
    let outcome = await model.logOut(stopWork: false)
    #expect(outcome == .loggedOut)
    #expect(transport.calls(.accountLogout) == [["stopWork": false]])
    #expect(model.accountState == .signedOut(reason: nil))
  }

  // MARK: Log out

  @Test func logOutUsesAConnectionOfItsOwn() async throws {
    // On one connection the coordinator answers in order, so a log-out behind a slow `server.start`
    // would wait for it; a side connection does not.
    let transport = ScriptedTransport()
    let model = try await connected(signedIn, transport: transport)
    let side = ScriptedTransport()
    side.script(.accountLogout, [try status(signedOut)])
    model.sideTransportProvider = { side }
    let outcome = await model.logOut(stopWork: false)
    #expect(outcome == .loggedOut)
    #expect(side.calls(.accountLogout).count == 1)
    #expect(transport.calls(.accountLogout).isEmpty)
    #expect(model.accountState == .signedOut(reason: nil))
  }

  @Test func logOutRefusedListsTheWork() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(signedIn, transport: transport)
    let work = WorkspaceActiveWork.Result(turns: [], servers: [])
    transport.script(
      .accountLogout,
      [
        .failure(
          WorkspaceError(.workRunning, "Work is running.", details: ["work": try JSONValue(encoding: work)]))
      ])
    #expect(await model.logOut(stopWork: false) == .workRunning(work))
    #expect(model.accountState == .signedIn)
  }

  // MARK: The left-open notice

  @Test func leftOpenNoticeShowsUntilDismissed() async throws {
    let text = "The last sign-out could not reach the hub; that session was left open there."
    let transport = ScriptedTransport()
    var withNotice = signedIn
    withNotice.notice = text
    transport.setHub(
      HubStatus.Result(
        joined: true, url: "https://hub.test.b4.run", deviceId: "d", deviceName: "Mac", orgSlug: "o",
        username: "u", displayName: "Brian Love", unsyncedChanges: 0))
    let model = try await connected(withNotice, transport: transport)
    #expect(model.accountNotice == text)
    // Routine `hub.status` reads, which here carry no notice, never clear it or dismiss it.
    await model.refreshAccount()
    await model.refreshAccount()
    #expect(model.accountNotice == text)
    #expect(transport.calls(.accountDismissNotice).isEmpty)

    transport.script(.accountDismissNotice, [try status(signedIn)])
    await model.dismissAccountNotice()
    #expect(transport.calls(.accountDismissNotice).count == 1)
    #expect(model.accountNotice == nil)
  }

  // MARK: The copy

  @Test func signInViewCopy() async throws {
    let model = try await connected(signedOut)
    let tree = signInScreen(model)
    #expect(tree.text(of: "signIn.apple") == "Continue with Apple")
    #expect(tree.text(of: "signIn.passkey") == "Continue with a passkey")
    #expect(tree.text(of: "signIn.badge") == "Test hub")
    #expect(tree.shows("Agent Workspace"))
    #expect(tree.shows("Your Codex, Claude, and B4 threads, on your Mac and your phone."))
    #expect(tree.shows("New here? Either one creates your account."))
    #expect(tree.shows("By continuing you agree to the terms and privacy policy."))
    // The line as drawn, with its two links, reads the same.
    let terms = SignInView.termsLine(beta)
    #expect(String(terms.characters) == "By continuing you agree to the terms and privacy policy.")
    #expect(terms.runs.compactMap(\.link) == [beta.termsURL, beta.privacyURL])
    #expect(beta.termsURL.absoluteString == "https://test.b4.run/app/terms")
    #expect(tree.shows("b4.run"))

    let welcome = try await connected(onboarding(name: "Brian Love"))
    let form = onboardingScreen(welcome)
    #expect(form.shows("Welcome"))
    #expect(form.shows("What should we call you?"))
    #expect(form.shows("Full name"))
    #expect(form.text(of: "onboarding.name")?.contains("Brian Love") == true)
    #expect(form.text(of: "onboarding.continue") == "Continue")
    #expect(form.shows("Not you? Log out"))
  }

  // MARK: WebAuthn JSON

  @Test func webAuthnOptionsAndResponsesUseBase64URL() throws {
    let request = try WebAuthnJSON.assertionRequest(from: assertionOptions)
    #expect(request.relyingParty == "test.b4.run")
    #expect(WebAuthnJSON.base64URL(request.challenge) == "RRV2OiwiBN1y1E_3XWanjdAsGI1ZRVftjhQ7nNxaM5U")
    let registration = try WebAuthnJSON.registrationRequest(from: registrationOptions)
    #expect(registration.relyingParty == "test.b4.run")
    #expect(registration.name == "Agent Workspace account")
    #expect(WebAuthnJSON.base64URL(registration.userID) == "x1DZeP_JTHG6OCuGv4E2CQ")
    #expect(throws: (any Error).self) { try WebAuthnJSON.assertionRequest(from: ["publicKey": [:]]) }

    let bytes = Data([0xfb, 0xff, 0x01])
    let assertion = WebAuthnJSON.assertion(
      credentialID: bytes, authenticatorData: bytes, clientDataJSON: bytes, signature: bytes, userID: bytes)
    #expect(assertion["id"] == "-_8B")
    #expect(assertion["rawId"] == "-_8B")
    #expect(assertion["type"] == "public-key")
    #expect(assertion["response"]?["userHandle"] == "-_8B")
    #expect(assertion["response"]?["signature"] == "-_8B")
    let attestation = WebAuthnJSON.attestation(
      credentialID: bytes, attestationObject: bytes, clientDataJSON: bytes)
    #expect(attestation["response"]?["attestationObject"] == "-_8B")
    #expect(attestation["response"]?["clientDataJSON"] == "-_8B")
  }
}
