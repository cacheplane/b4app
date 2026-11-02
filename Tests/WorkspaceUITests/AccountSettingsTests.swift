import AuthenticationServices
import Foundation
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
private let beta = SignInConfiguration(siteDomain: "test.b4.run", appleSignIn: true, badge: "Test hub")
private let local = SignInConfiguration(siteDomain: "local.b4.run", appleSignIn: false, badge: "Local hub")

private func status(_ result: AccountStatus.Result) throws -> ScriptedTransport.Reply {
  .result(try JSONValue(encoding: result))
}

private func reply<T: Encodable>(_ value: T) throws -> ScriptedTransport.Reply {
  .result(try JSONValue(encoding: value))
}

/// A connected model whose coordinator first answers `account.status` with `initial`.
@MainActor
private func connected(
  _ initial: AccountStatus.Result = signedIn, transport: ScriptedTransport = ScriptedTransport(),
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

private func turn(_ id: String, local: Bool = true) -> ActiveTurnSummary {
  ActiveTurnSummary(
    threadId: "t-\(id)", threadTitle: "Thread \(id)", turnId: id, status: .running, connectionId: "c1",
    connectionLabel: local ? "Codex" : "Remote B4", kind: local ? .codex : .b4,
    b4Mode: local ? nil : .remote, local: local)
}

private func server(_ id: String) -> LocalServer {
  LocalServer(
    id: id, name: "site-\(id)", projectPath: "/tmp/\(id)", nodePath: "/usr/bin/node", cliPath: "/tmp/cli",
    launchMode: .development, health: .ready)
}

private func workRunning(_ work: WorkspaceActiveWork.Result) throws -> ScriptedTransport.Reply {
  .failure(WorkspaceError(.workRunning, "Work is running.", details: ["work": try JSONValue(encoding: work)]))
}

private func identity(
  _ id: String, kind: String = "passkey", name: String? = nil, createdAt: String = "2026-11-01T09:00:00Z"
) -> AccountIdentity {
  AccountIdentity(id: id, kind: kind, name: name, createdAt: createdAt)
}

private let gb = Locale(identifier: "en_GB")
/// 2 November 2026, so "1 Nov" is this year.
private let today = Date(timeIntervalSince1970: 1_793_620_800)

private let registrationOptions: JSONValue = [
  "publicKey": [
    "challenge": "SaCNwlH3QwCt591RUpzizyufYVups0FttxAuD4EuN98",
    "rp": ["id": "test.b4.run", "name": "b4.run"],
    "user": ["id": "x1DZeP_JTHG6OCuGv4E2CQ", "name": "Agent Workspace account"],
  ]
]

/// Stands in for the system passkey sheet when adding a passkey.
@MainActor
private final class FakeCeremony: PasskeyCeremony {
  var registerError: (any Error)?
  private(set) var registered: [JSONValue] = []
  private(set) var reportedUnknown: [String] = []

  func assert(_ options: JSONValue) async throws -> JSONValue? { nil }

  func register(_ options: JSONValue) async throws -> JSONValue {
    registered.append(options)
    if let registerError { throw registerError }
    return ["id": "bmV3", "rawId": "bmV3", "type": "public-key"]
  }

  func reportUnknownCredential(relyingParty: String, credentialID: Data) async {
    reportedUnknown.append(relyingParty)
  }
}

/// A flow whose sleeps return at once, moving a clock the test owns by a second each.
@MainActor
private func fastFlow(_ model: WorkspaceModel) -> PairingFlow {
  let flow = PairingFlow(model: model)
  let clock = SecondsClock()
  flow.sleep = { _ in
    clock.seconds += 1
    await Task.yield()
  }
  flow.uptime = { clock.now }
  return flow
}

private final class SecondsClock: @unchecked Sendable {
  private let base = ContinuousClock.Instant.now
  var seconds = 0.0
  var now: ContinuousClock.Instant { base.advanced(by: .seconds(seconds)) }
}

private let joined = HubStatus.Result(
  joined: true, url: "https://hub.test.b4.run", deviceId: "dev-mac", deviceName: "Mac", orgSlug: "o-abc",
  username: "u-abc", displayName: "Brian Love", unsyncedChanges: 0)

private let minted = HubPair.Result(
  url: "https://hub.test.b4.run", code: "K7M2Q9XP", expiresAt: "2026-11-01T10:05:00.000000Z")

// MARK: - Tests

@MainActor
@Suite(.serialized) struct AccountSettingsTests {
  // MARK: Log out

  @Test func logOutConfirmationListsWork() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    let work = WorkspaceActiveWork.Result(turns: [turn("u1")], servers: [server("s1")])
    transport.script(.workspaceActiveWork, [try reply(work)])
    await model.requestLogOut()
    let confirmation = try #require(model.logOutConfirmation)
    #expect(confirmation.title == "Log out of Brian's Org?")
    #expect(confirmation.message.hasPrefix("1 turn is running and 1 local server is up."))
    #expect(confirmation.buttons == ["Stop and log out", "Cancel"])
    #expect(confirmation.stopsWork)

    // Plurals, and a remote run is said to go on where it runs.
    let more = LogOutConfirmation(
      orgName: "Brian's Org",
      work: WorkspaceActiveWork.Result(
        turns: [turn("u1"), turn("u2"), turn("r1", local: false)], servers: [server("s1"), server("s2")]))
    #expect(more.message.hasPrefix("2 turns are running and 2 local servers are up."))
    #expect(more.message.contains("1 remote B4 run keeps going on its server."))
    let servers = LogOutConfirmation(
      orgName: "O", work: WorkspaceActiveWork.Result(turns: [], servers: [server("s1")]))
    #expect(servers.message.hasPrefix("1 local server is up."))
    let remote = LogOutConfirmation(
      orgName: "O",
      work: WorkspaceActiveWork.Result(
        turns: [turn("r1", local: false), turn("r2", local: false)], servers: []))
    #expect(remote.message.hasPrefix("2 remote B4 runs keep going on their servers."))
    // Nothing on this Mac stops: the button says Log out, though the coordinator needs stopWork.
    #expect(remote.buttons == ["Log out", "Cancel"])
    #expect(remote.stopsWork)

    // "Stop and log out" sends stopWork, and nothing else is asked.
    transport.script(.accountLogout, [try status(signedOut)])
    await model.confirmLogOut()
    #expect(transport.calls(.accountLogout) == [["stopWork": true]])
    #expect(model.logOutConfirmation == nil)
    #expect(model.accountState == .signedOut(reason: nil))
  }

  @Test func logOutWithoutWorkSkipsList() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    transport.script(.workspaceActiveWork, [try reply(WorkspaceActiveWork.Result(turns: [], servers: []))])
    await model.requestLogOut()
    let confirmation = try #require(model.logOutConfirmation)
    #expect(confirmation.title == "Log out of Brian's Org?")
    #expect(confirmation.message == LogOutConfirmation.neutralMessage)
    #expect(!confirmation.message.contains("running"))
    #expect(confirmation.buttons == ["Log out", "Cancel"])
    #expect(!confirmation.stopsWork)

    // Cancel changes nothing and sends nothing.
    model.cancelLogOut()
    #expect(model.logOutConfirmation == nil)
    #expect(transport.calls(.accountLogout).isEmpty)
    #expect(model.accountState == .signedIn)
  }

  @Test func logOutFlushesTheDraftFirst() async throws {
    let transport = ScriptedTransport()
    let open = ConversationThread(
      id: "t1", connectionId: "c1", nativeThreadId: "n-t1", title: "t1", pinned: false, archived: false,
      createdAt: "2026-11-01T10:00:00Z", updatedAt: "2026-11-01T10:00:00Z")
    transport.set(threads: [open])
    transport.setRead(ThreadRead.Result(thread: open, turns: [], items: [], requests: []))
    let model = try await connected(transport: transport)
    model.draftSaveDelay = .seconds(600)
    await model.openThread(id: "t1")
    model.composerText = "half a thought"
    let saved = Draft(threadId: "t1", text: "half a thought", updatedAt: "2026-11-01T10:00:00Z")
    transport.script(.draftSave, [try reply(DraftSave.Result(draft: saved))])
    transport.script(.accountLogout, [try status(signedOut)])
    await model.requestLogOut()
    await model.confirmLogOut()
    let methods = transport.methods()
    let save = try #require(methods.lastIndex(of: "draft.save"))
    let logout = try #require(methods.lastIndex(of: "account.logout"))
    #expect(save < logout)
    #expect(transport.calls(.draftSave).last == ["threadId": "t1", "text": "half a thought"])
  }

  @Test func aLateWorkRunningShowsTheConfirmationAgain() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    transport.script(.workspaceActiveWork, [try reply(WorkspaceActiveWork.Result(turns: [], servers: []))])
    await model.requestLogOut()
    #expect(model.logOutConfirmation?.stopsWork == false)

    // A turn started between the question and the answer: the coordinator refuses, with the list.
    let fresh = WorkspaceActiveWork.Result(turns: [turn("u9")], servers: [])
    transport.script(.accountLogout, [try workRunning(fresh), try status(signedOut)])
    await model.confirmLogOut()
    let again = try #require(model.logOutConfirmation)
    #expect(again.message.hasPrefix("1 turn is running."))
    #expect(again.buttons == ["Stop and log out", "Cancel"])
    #expect(model.accountState == .signedIn)

    await model.confirmLogOut()
    #expect(transport.calls(.accountLogout) == [["stopWork": false], ["stopWork": true]])
    #expect(model.accountState == .signedOut(reason: nil))
  }

  @Test func aFailedLogOutShowsOneLine() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    await model.requestLogOut()
    transport.script(.accountLogout, [.failure(WorkspaceError(.internalError, "secret hub detail"))])
    await model.confirmLogOut()
    #expect(model.logOutFailure == "That didn't work. Try again.")
    #expect(model.logOutConfirmation == nil)
    #expect(model.accountState == .signedIn)
    model.dismissLogOutFailure()
    #expect(model.logOutFailure == nil)
  }

  // MARK: Signing out closes what needs an account

  @Test func settingsCloseWhenSignedOut() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    model.openSettings(.account)
    model.settingsVisible = true
    model.showAddPhone = true
    #expect(model.settingsAvailable)
    let before = model.settingsCloseRequest

    transport.emit(try .accountChanged(signedOut))
    try await waitUntil("the sign-out") { model.accountState == .signedOut(reason: nil) }
    #expect(!model.settingsAvailable)
    #expect(model.settingsCloseRequest == before + 1)
    #expect(model.showAddPhone == false)
    #expect(model.showSettingsSheet == false)
    #expect(model.identities == nil)
  }

  // MARK: The Account page

  @Test func accountPageComesFirst() {
    #expect(SettingsPage.allCases.first == .account)
    #expect(SettingsPage.account.title == "Account")
  }

  @Test func accountPageShowsTheNameOrgAndMethods() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    transport.script(
      .accountIdentities,
      [
        try reply(
          AccountIdentities.Result(identities: [
            identity("i1", kind: "apple", name: "x@privaterelay.appleid.com"),
            identity("i2", name: "Brian Love", createdAt: "2025-03-04T09:00:00Z"),
          ]))
      ])
    await model.refreshIdentities()
    let page = AccountSettingsContent(model: model, now: today, locale: gb)
    #expect(page.fullName == "Brian Love")
    #expect(page.nameHint == "Your org is named after your first name.")
    #expect(page.orgName == "Brian's Org")
    #expect(
      page.methods.map(\.text) == ["Apple ID · added 1 Nov", "Passkey · Brian Love · added 4 Mar 2025"])
    #expect(page.methods.allSatisfy { $0.removeEnabled })
    #expect(page.addPasskey == "Add a passkey")
    // An Apple ID is linked already: no Connect Apple ID.
    #expect(page.connectApple == nil)
    #expect(page.delete == "Delete account…")
  }

  @Test func removeDisabledForLastIdentity() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    transport.script(
      .accountIdentities, [try reply(AccountIdentities.Result(identities: [identity("i1", name: "Mac")]))])
    await model.refreshIdentities()
    let page = AccountSettingsContent(model: model, now: today, locale: gb)
    #expect(page.methods.count == 1)
    #expect(page.methods.first?.removeEnabled == false)
    // Removing it anyway is not sent.
    await model.removeIdentity(id: "i1")
    #expect(transport.calls(.accountRemoveIdentity).isEmpty)

    // With two, both can go; the hub's `last_identity` (another device removed one) is one line.
    transport.script(
      .accountIdentities,
      [try reply(AccountIdentities.Result(identities: [identity("i1"), identity("i2", kind: "apple")]))])
    await model.refreshIdentities()
    #expect(
      AccountSettingsContent(model: model, now: today, locale: gb).methods.allSatisfy { $0.removeEnabled })
    // The list is read again, so the stale row stops offering Remove.
    transport.script(.accountRemoveIdentity, [.failure(WorkspaceError(.lastIdentity, "hub detail"))])
    transport.script(
      .accountIdentities, [try reply(AccountIdentities.Result(identities: [identity("i1")]))])
    await model.removeIdentity(id: "i2")
    #expect(model.accountSettingsFailure == AccountCopy.lastIdentity)
    #expect(model.identities?.map(\.id) == ["i1"])
    #expect(AccountSettingsContent(model: model).methods.first?.removeEnabled == false)

    // A removal that works shows what is left.
    transport.script(
      .accountIdentities,
      [try reply(AccountIdentities.Result(identities: [identity("i1"), identity("i2", kind: "apple")]))])
    await model.refreshIdentities()
    transport.script(
      .accountRemoveIdentity, [try reply(AccountIdentities.Result(identities: [identity("i1")]))])
    await model.removeIdentity(id: "i2")
    #expect(transport.calls(.accountRemoveIdentity).last == ["identityId": "i2"])
    #expect(model.identities?.map(\.id) == ["i1"])
    #expect(model.accountSettingsFailure == nil)
  }

  @Test func deleteRequiresTypedOrgName() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    #expect(!model.canDeleteAccount(typed: ""))
    #expect(!model.canDeleteAccount(typed: "brian's org"))
    #expect(!model.canDeleteAccount(typed: "Brian's Org "))
    #expect(model.canDeleteAccount(typed: "Brian's Org"))
    await model.deleteAccount(typed: "Brians Org", accountId: theAccount.id)
    #expect(transport.calls(.accountDelete).isEmpty)

    // A shared org is refused at the hub: one line, nothing changes.
    transport.script(.accountDelete, [.failure(WorkspaceError(.sharedOrg, "hub detail"))])
    await model.deleteAccount(typed: "Brian's Org", accountId: theAccount.id)
    #expect(transport.calls(.accountDelete).count == 1)
    #expect(model.deleteFailure == AccountCopy.sharedOrg)
    #expect(model.accountState == .signedIn)

    transport.script(.accountDelete, [.failure(WorkspaceError(.internalError, "secret hub detail"))])
    await model.deleteAccount(typed: "Brian's Org", accountId: theAccount.id)
    #expect(model.deleteFailure == "That didn't work. Try again.")
    #expect(model.accountState == .signedIn)

    transport.script(.accountDelete, [try status(signedOut)])
    await model.deleteAccount(typed: "Brian's Org", accountId: theAccount.id)
    #expect(model.deleteFailure == nil)
    #expect(model.accountState == .signedOut(reason: nil))
  }

  @Test func editingTheNameSavesIt() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    var renamed = signedIn
    renamed.account?.displayName = "Brian F. Love"
    transport.script(.accountCompleteProfile, [try status(renamed)])
    await model.updateFullName("   ")
    #expect(transport.calls(.accountCompleteProfile).isEmpty)
    await model.updateFullName("  Brian F. Love ")
    #expect(transport.calls(.accountCompleteProfile) == [["fullName": "Brian F. Love"]])
    #expect(AccountSettingsContent(model: model).fullName == "Brian F. Love")
    // Editing the name is not onboarding.
    #expect(model.showAddPhone == false)
  }

  @Test func addAPasskey() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    transport.script(
      .accountIdentities, [try reply(AccountIdentities.Result(identities: [identity("i1", kind: "apple")]))])
    await model.refreshIdentities()
    let begun = AccountAddPasskeyBegin.Result(ceremonyId: "c9", registration: registrationOptions)
    transport.script(.accountAddPasskeyBegin, [try reply(begun)])
    transport.script(
      .accountAddPasskeyFinish, [try reply(AccountAddPasskeyFinish.Result(identity: identity("i2")))])
    let ceremony = FakeCeremony()
    await model.addPasskey(using: ceremony)
    #expect(ceremony.registered == [registrationOptions])
    let finish = try #require(transport.calls(.accountAddPasskeyFinish).first)
    #expect(finish["ceremonyId"] == "c9")
    #expect(model.identities?.map(\.id) == ["i1", "i2"])

    // Closing the sheet shows nothing and sends nothing more.
    transport.script(.accountAddPasskeyBegin, [try reply(begun)])
    ceremony.registerError = SignInCanceled()
    await model.addPasskey(using: ceremony)
    #expect(transport.calls(.accountAddPasskeyFinish).count == 1)
    #expect(model.accountSettingsFailure == nil)

    // A refused passkey is one line, and the new credential is reported unknown.
    ceremony.registerError = nil
    transport.script(.accountAddPasskeyBegin, [try reply(begun)])
    transport.script(.accountAddPasskeyFinish, [.failure(WorkspaceError(.credentialRejected, "no"))])
    await model.addPasskey(using: ceremony)
    #expect(model.accountSettingsFailure != nil)
    #expect(ceremony.reportedUnknown == ["test.b4.run"])
  }

  @Test func connectAppleIDShowsOnBetaAndProdOnly() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport, configuration: local)
    transport.script(
      .accountIdentities, [try reply(AccountIdentities.Result(identities: [identity("i1")]))])
    await model.refreshIdentities()
    #expect(AccountSettingsContent(model: model).connectApple == nil)
    // Task 14 wires the link calls (`AppleSignInTests`): beta and prod show it while there is none.
    model.signInConfiguration = beta
    #expect(AccountSettingsContent(model: model).connectApple == AccountCopy.connectApple)
  }

  // MARK: Add your iPhone

  @Test func addPhoneShownOnceAfterOnboarding() async throws {
    let transport = ScriptedTransport()
    var fresh = theAccount
    fresh.orgName = "My Org"
    let model = try await connected(
      AccountStatus.Result(state: .needsOnboarding, account: fresh), transport: transport)
    #expect(model.showAddPhone == false)
    transport.script(.accountCompleteProfile, [try status(signedIn)])
    await model.completeProfile(fullName: "Brian Love")
    #expect(model.accountState == .signedIn)
    #expect(model.showAddPhone)

    // Done closes it; nothing shows it again by itself.
    model.showAddPhone = false
    transport.script(.accountCompleteProfile, [try status(signedIn)])
    await model.updateFullName("Brian Love")
    transport.emit(try .accountChanged(signedIn))
    await model.refreshAccount()
    #expect(model.showAddPhone == false)

    // An account that signs in already onboarded never sees it.
    let returning = try await connected(signedOut)
    returning.applyAccountStatus(signedIn)
    #expect(returning.showAddPhone == false)
  }

  @Test func addPhoneNewCodeAfterExpiry() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .waiting)])
    let model = try await connected(transport: transport)

    // The sheet's copy, and the code while it waits.
    let showing = PairingFlow(model: model)
    showing.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    let running = Task { await showing.run() }
    try await waitUntil("the first code") { showing.phase == .waiting }
    let waiting = AddPhoneContent(flow: showing)
    #expect(waiting.title == "Add your iPhone")
    #expect(waiting.intro == "Scan this with your iPhone's camera to see your threads there.")
    #expect(waiting.showsCode)
    #expect(waiting.expiry == "Works for 5 minutes")
    #expect(waiting.newCode == "New code")
    #expect(waiting.done == "Done")
    #expect(waiting.appStore == "No iPhone app yet? It's on the App Store.")
    running.cancel()
    await running.value
    showing.clear()

    // Once a code expires the sheet mints the next by itself, which then pairs.
    transport.setPairing(
      .success(minted),
      statuses: [
        HubPairStatus.Result(state: .waiting), HubPairStatus.Result(state: .expired),
        HubPairStatus.Result(state: .waiting), HubPairStatus.Result(state: .paired, deviceName: "iPhone"),
      ])
    let mints = transport.calls(.hubPair).count
    let flow = fastFlow(model)
    flow.renewsExpiredCodes = 1
    await flow.run()
    #expect(transport.calls(.hubPair).count == mints + 2)
    #expect(flow.phase == .paired("iPhone"))
    #expect(AddPhoneContent(flow: flow).status == "Paired with iPhone")

    // Past its renewals, an expired code waits for New code.
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .expired)])
    let once = fastFlow(model)
    await once.run()
    #expect(once.phase == .expired)
    #expect(AddPhoneContent(flow: once).newCode == "New code")
    #expect(!AddPhoneContent(flow: once).showsCode)
    // New code mints again.
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .paired, deviceName: "P")])
    let before = transport.calls(.hubPair).count
    await once.run()
    #expect(transport.calls(.hubPair).count == before + 1)
    #expect(once.phase == .paired("P"))
  }
  // MARK: Fix round 1

  @Test func registrationExcludesTheAccountsPasskeys() throws {
    let options: JSONValue = [
      "publicKey": [
        "challenge": "SaCNwlH3QwCt591RUpzizyufYVups0FttxAuD4EuN98",
        "rp": ["id": "test.b4.run", "name": "b4.run"],
        "user": ["id": "x1DZeP_JTHG6OCuGv4E2CQ", "name": "Agent Workspace account"],
        "excludeCredentials": [
          ["type": "public-key", "id": "AQID"], ["type": "public-key", "id": "-_8B"],
        ],
      ]
    ]
    let request = try WebAuthnJSON.registrationRequest(from: options)
    #expect(request.excludedCredentials == [Data([1, 2, 3]), Data([0xfb, 0xff, 0x01])])
    let platform = SystemPasskeyCeremony.platformRequest(for: request)
    #expect(
      platform.excludedCredentials?.map(\.credentialID) == [Data([1, 2, 3]), Data([0xfb, 0xff, 0x01])])
    // None to exclude (a new account) is an empty list.
    #expect(try WebAuthnJSON.registrationRequest(from: registrationOptions).excludedCredentials.isEmpty)
    // The device holding one of them is its own error.
    #expect(
      SystemPasskeyCeremony.registrationError(ASAuthorizationError(.matchedExcludedCredential))
        is PasskeyAlreadyOnDevice)
  }

  @Test func aPasskeyAlreadyOnTheDeviceIsOneLineAndNoOrphan() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    let begun = AccountAddPasskeyBegin.Result(ceremonyId: "c9", registration: registrationOptions)
    transport.script(.accountAddPasskeyBegin, [try reply(begun)])
    let ceremony = FakeCeremony()
    ceremony.registerError = PasskeyAlreadyOnDevice()
    await model.addPasskey(using: ceremony)
    #expect(model.accountSettingsFailure == "This device already has a passkey for this account.")
    #expect(transport.calls(.accountAddPasskeyFinish).isEmpty)
    #expect(ceremony.reportedUnknown.isEmpty)
  }

  @Test func anAccountSwitchClosesSettings() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    model.openSettings(.account)
    model.showSettingsSheet = true
    let before = model.settingsCloseRequest
    var other = signedIn
    other.account?.id = "ffffffffffffffff"
    transport.emit(try .accountChanged(other))
    try await waitUntil("the switch") { model.accountStatus?.account?.id == "ffffffffffffffff" }
    #expect(model.accountState == .signedIn)
    #expect(model.settingsCloseRequest == before + 1)
    #expect(model.showSettingsSheet == false)
  }

  @Test func deleteIsBoundToTheAccountItWasOpenedFor() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    let openedFor = AccountSettingsContent(model: model).accountId
    #expect(openedFor == theAccount.id)
    // A switch to another account whose org has the same name.
    var other = signedIn
    other.account?.id = "ffffffffffffffff"
    model.applyAccountStatus(other)
    #expect(model.canDeleteAccount(typed: "Brian's Org"))
    await model.deleteAccount(typed: "Brian's Org", accountId: openedFor)
    #expect(transport.calls(.accountDelete).isEmpty)
    await model.deleteAccount(typed: "Brian's Org", accountId: nil)
    #expect(transport.calls(.accountDelete).isEmpty)
  }

  @Test func addPhoneStopsOnAnAccountSwitch() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .waiting)])
    let model = try await connected(transport: transport)
    let flow = AddPhoneView.makeFlow(model: model)
    flow.sleep = { _ in try await Task.sleep(for: .milliseconds(5)) }
    let running = Task { await flow.run() }
    try await waitUntil("a poll") { transport.calls(.hubPairStatus).count >= 1 }
    var other = signedIn
    other.account?.id = "ffffffffffffffff"
    model.applyAccountStatus(other)
    // It ends by itself, drops the code, and mints nothing for the new account.
    await running.value
    #expect(flow.code == nil && flow.link == nil)
    #expect(transport.calls(.hubPair).count == 1)
    let polls = transport.calls(.hubPairStatus).count
    try await Task.sleep(for: .milliseconds(40))
    #expect(transport.calls(.hubPairStatus).count == polls)
  }

  @Test func addPhoneRenewsAnExpiredCodeTwice() async throws {
    let transport = ScriptedTransport()
    transport.setHub(joined)
    transport.setPairing(.success(minted), statuses: [HubPairStatus.Result(state: .expired)])
    let model = try await connected(transport: transport)
    let flow = AddPhoneView.makeFlow(model: model)
    #expect(flow.renewsExpiredCodes == 2)
    flow.sleep = { _ in await Task.yield() }
    await flow.run()
    // The first code and two renewals, then it waits for New code.
    #expect(transport.calls(.hubPair).count == 3)
    #expect(flow.phase == .expired)
    // New code (`restart`) runs the view's task again.
    let generation = flow.generation
    flow.restart()
    #expect(flow.generation == generation + 1)
  }

  @Test func signingOutClearsTheLogOutFailure() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    await model.requestLogOut()
    transport.script(.accountLogout, [.failure(WorkspaceError(.internalError, "no"))])
    await model.confirmLogOut()
    #expect(model.logOutFailure != nil)
    transport.emit(try .accountChanged(signedOut))
    try await waitUntil("the sign-out") { model.accountState == .signedOut(reason: nil) }
    #expect(model.logOutFailure == nil)
  }

  @Test func removeThisMacSavesTheDraftFirst() async throws {
    let transport = ScriptedTransport()
    let open = ConversationThread(
      id: "t1", connectionId: "c1", nativeThreadId: "n-t1", title: "t1", pinned: false, archived: false,
      createdAt: "2026-11-01T10:00:00Z", updatedAt: "2026-11-01T10:00:00Z")
    transport.set(threads: [open])
    transport.setRead(ThreadRead.Result(thread: open, turns: [], items: [], requests: []))
    transport.setHub(joined)
    let model = try await connected(transport: transport)
    model.draftSaveDelay = .seconds(600)
    await model.openThread(id: "t1")
    model.composerText = "half a thought"
    let saved = Draft(threadId: "t1", text: "half a thought", updatedAt: "2026-11-01T10:00:00Z")
    transport.script(.draftSave, [try reply(DraftSave.Result(draft: saved))])
    await model.removeThisMac()
    let methods = transport.methods()
    let save = try #require(methods.lastIndex(of: "draft.save"))
    let leave = try #require(methods.lastIndex(of: "hub.leave"))
    #expect(save < leave)
    #expect(transport.calls(.draftSave).last == ["threadId": "t1", "text": "half a thought"])
  }

  @Test func aDeletedAccountWhoseLocalDataStayedSaysSo() async throws {
    let transport = ScriptedTransport()
    let model = try await connected(transport: transport)
    // The coordinator signed out, then answered that the drop failed.
    transport.script(
      .accountDelete,
      [
        .failure(
          WorkspaceError(
            .internalError,
            "The account was deleted at the hub, but its data on this Mac could not be removed",
            details: ["database": "workspace_a1b2c3d4e5f60718"]))
      ])
    await model.deleteAccount(typed: "Brian's Org", accountId: theAccount.id)
    #expect(model.deleteFailure == AccountCopy.deletedLocalDataKept)
    #expect(!AccountCopy.deletedLocalDataKept.contains("Try again"))

    // The sign-out usually lands first and closes Settings: the sign-in screen says it then.
    transport.script(.accountDelete, [.hold])
    let deleting = Task { await model.deleteAccount(typed: "Brian's Org", accountId: theAccount.id) }
    try await waitUntil("the delete to be sent") { transport.heldCount(.accountDelete) == 1 }
    transport.emit(try .accountChanged(signedOut))
    try await waitUntil("the sign-out") { model.accountState == .signedOut(reason: nil) }
    transport.release(
      .accountDelete,
      with: .failure(WorkspaceError(.internalError, "x", details: ["database": "workspace_a1b2c3d4e5f60718"]))
    )
    await deleting.value
    #expect(model.signInProgress.failure == AccountCopy.deletedLocalDataKept)
  }
}
