import Foundation
import Synchronization
import Testing
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync

@testable import WorkspaceMirror

// Pairing by QR code (sign-in plan, Task 15; D-066): the link is `https://<site>/pair#c=<code>`, the
// flavour's own site only, and a scan signs a signed-out phone in, merges a phone-only account into the
// Mac's, or asks before switching away from an account that has a Mac of its own.

private let code = "K7M2Q9XP"

private func url(_ text: String) -> URL { URL(string: text)! }

private func enrolled(
  device: String = "dev-paired", token: String = "tok-paired", org: String = "Brian's Org"
) -> EnrollResponse {
  EnrollResponse(
    deviceId: device, token: token, org: OrgInfo(slug: "o-mac", name: org),
    user: UserInfo(username: "u-mac", displayName: "Brian Love"))
}

private func ownSession(token: String = "tok-own-5501") -> AuthSession {
  AuthSession(
    deviceId: "dev-own", token: token, org: OrgInfo(slug: "o-own", name: "Phone's Org"),
    user: UserInfo(username: "u-own", displayName: "Brian"), needsOnboarding: false,
    userId: "0197cccc-0000-7000-8000-000000000001")
}

/// Every call the account makes, in order, with the token a merge carried.
private final class CallLog: Sendable {
  private let entries = Mutex<[String]>([])
  func append(_ entry: String) { entries.withLock { $0.append(entry) } }
  var all: [String] { entries.withLock { $0 } }
}

/// Forwards to the fake and logs the account-changing calls. With `mergeRefusal` set, an enrollment
/// that carries a token is refused with `409 merge_refused` and that `details.reason` (`.some(nil)`
/// for none, as an older hub), leaving the code redeemable, as the hub does: the code is checked
/// first, so a code the fake does not hold is `invalid_code` whatever the token.
private struct LoggingHub: HubAPI {
  let fake: FakeHubAPI
  let log: CallLog
  var mergeRefusal: String?? = nil
  var refuseToken = false

  func enroll(_ request: EnrollRequest) async throws -> EnrollResponse {
    try await enroll(request, replacingToken: nil)
  }
  func enroll(_ request: EnrollRequest, replacingToken token: String?) async throws -> EnrollResponse {
    log.append(token == nil ? "enroll" : "enroll+merge")
    if token != nil, refuseToken {
      throw HubError(kind: "request_error", code: "unauthorized", message: "unauthorized", status: 401)
    }
    if token != nil, let reason = mergeRefusal, await fake.enrollmentCodes[request.code] != nil {
      throw HubError(
        kind: "request_error", code: "merge_refused", message: "this account cannot be merged into another",
        status: 409, reason: reason)
    }
    return try await fake.enroll(request, replacingToken: token)
  }
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
    log.append("endSession")
    try await fake.endSession()
  }
}

/// A phone account over an in-memory mirror, a memory Keychain, and one fake hub.
@MainActor
private struct Rig {
  let store: MirrorStore
  let secrets = MemorySecretStore()
  let fake: FakeHubAPI
  let memory = MirrorDeviceMemory(url: nil)
  let log = CallLog()
  let account: MirrorAccount

  init(flavor: PhoneFlavor = .prod, mergeRefusal: String?? = nil, refuseToken: Bool = false) throws {
    store = try MirrorStore.inMemory()
    fake = FakeHubAPI(enrollmentCodes: [code: enrolled()])
    let hub = LoggingHub(fake: fake, log: log, mergeRefusal: mergeRefusal, refuseToken: refuseToken)
    account = MirrorAccount(
      store: store, secrets: secrets,
      configuration: MirrorAccount.Configuration(
        hubURL: flavor.hubURL, deviceName: "Brian's iPhone", syncBackoff: .milliseconds(20),
        flavor: flavor),
      memory: memory, makeAPI: { _, _ in hub })
  }

  /// Signed in to an account of the phone's own, whose devices are `devices`.
  func signIn(devices: [DeviceInfo], token: String = "tok-own-5501") async throws {
    await fake.setSession(ownSession(token: token))
    await fake.setDevices(devices)
    let begun = try await account.passkeyBegin()
    _ = try await account.signIn(
      passkey: AccountPasskeyFinish.Params(ceremonyId: begun.ceremonyId, assertion: ["id": "cred"]))
  }

  func token() async throws -> String? {
    guard let link = try store.link(), let ref = SecretRef(rawValue: link.tokenRef) else { return nil }
    return try await secrets.read(ref)
  }
}

private let iPhoneOnly = [DeviceInfo(id: "dev-own", name: "Brian's iPhone", platform: "ios")]
private let withAMac = [
  DeviceInfo(id: "dev-mac", name: "Brian's MacBook Pro", platform: "macos"),
  DeviceInfo(id: "dev-own", name: "Brian's iPhone", platform: "ios"),
]

@Suite struct PairLinkTests {
  // MARK: The link

  @Test func makeAndParseRoundTrip() throws {
    #expect(
      PairLink.make(siteDomain: "b4.run", code: code).absoluteString == "https://b4.run/pair#c=K7M2Q9XP")
    for flavor in PhoneFlavor.allCases {
      let link = PairLink.make(siteDomain: flavor.siteDomain, code: code)
      #expect(link.absoluteString == "https://\(flavor.siteDomain)/pair#c=\(code)")
      // The code is after `#`, so it never reaches a web server's log; the link carries no hub.
      let parts = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false))
      #expect(parts.query == nil && parts.fragment == "c=\(code)")
      // The hub is the flavour's.
      #expect(flavor.parsePairLink(link) == PairLink(hub: flavor.hubURL, code: code))
      #expect(flavor.pairLinkDecision(link) == .confirm(PairLink(hub: flavor.hubURL, code: code)))
    }
    // Case-insensitive where it may be: the host and the code (kept upper case, as minted).
    #expect(PhoneFlavor.prod.parsePairLink(url("https://B4.Run/pair#c=k7m2q9xp"))?.code == code)
    #expect(PhoneFlavor.prod.parsePairLink(url("https://b4.run/pair/#c=K7M2Q9XP"))?.code == code)
  }

  @Test func parseRejectsOtherDomain() {
    // A test-hub code on a prod phone would enroll at the wrong hub: refused, and said so.
    let beta = url("https://test.b4.run/pair#c=K7M2Q9XP")
    #expect(PhoneFlavor.prod.parsePairLink(beta) == nil)
    #expect(PhoneFlavor.prod.pairLinkDecision(beta) == .invalid)
    #expect(PhoneFlavor.beta.parsePairLink(url("https://b4.run/pair#c=K7M2Q9XP")) == nil)
    #expect(PhoneFlavor.local.parsePairLink(url("https://b4.run/pair#c=K7M2Q9XP")) == nil)
    for text in [
      "https://evil.test/pair#c=K7M2Q9XP", "https://b4.run.evil.test/pair#c=K7M2Q9XP",
      "https://x.b4.run/pair#c=K7M2Q9XP", "http://b4.run/pair#c=K7M2Q9XP",
      "https://b4.run:8443/pair#c=K7M2Q9XP",
      "https://user@b4.run/pair#c=K7M2Q9XP", "https://b4.run/pairing#c=K7M2Q9XP",
      "https://b4.run/pair/extra#c=K7M2Q9XP", "https://b4.run/app/pair#c=K7M2Q9XP",
    ] {
      #expect(PhoneFlavor.prod.parsePairLink(url(text)) == nil, "\(text)")
    }
  }

  @Test func parseRejectsQueryCode() {
    // The code must be in the fragment: one in the query would reach the site's server logs.
    for text in [
      "https://b4.run/pair?c=K7M2Q9XP", "https://b4.run/pair?c=K7M2Q9XP#c=K7M2Q9XP",
      "https://b4.run/pair?x=1#c=K7M2Q9XP", "https://b4.run/pair", "https://b4.run/pair#",
      "https://b4.run/pair#c=", "https://b4.run/pair#code=K7M2Q9XP",
      "https://b4.run/pair#c=K7M2Q9XP&c=MNPQRSTV",
      "https://b4.run/pair#c=K7M2Q9XP&x=1", "https://b4.run/pair#c=K7M2Q9X",
      "https://b4.run/pair#c=K7M2Q9XPZ",
      "https://b4.run/pair#c=K7M2Q9XA", "https://b4.run/pair#c=BCDFGH%C3%9F",
    ] {
      #expect(PhoneFlavor.prod.parsePairLink(url(text)) == nil, "\(text)")
    }
    #expect(PhoneFlavor.prod.pairLinkDecision(url("https://b4.run/pair?c=K7M2Q9XP")) == .invalid)
  }

  @Test func theOldLinkIsReadOnlyByTheLocalFlavourForALoopbackHub() throws {
    // M8c's form, during the transition: on the local flavour, for a hub on this machine only.
    let local = PairLink.makeLegacy(url: "http://localhost:8080", code: code)
    #expect(local.absoluteString == "b4app://pair?hub=http%3A%2F%2Flocalhost%3A8080&code=K7M2Q9XP")
    #expect(
      PhoneFlavor.local.parsePairLink(local)
        == PairLink(hub: try HubURL.validate("http://localhost:8080"), code: code))
    #expect(
      PhoneFlavor.local.parsePairLink(PairLink.makeLegacy(url: "http://127.0.0.1:9", code: code))?.host
        == "127.0.0.1")
    #expect(
      PhoneFlavor.local.parsePairLink(PairLink.makeLegacy(url: "http://[::1]:8080", code: code))?.host
        == "::1")
    // A remote hub in an old link is refused even locally, and prod and beta read no old link at all.
    let remote = PairLink.makeLegacy(url: "https://hub.example.com", code: code)
    #expect(PhoneFlavor.local.parsePairLink(remote) == nil)
    #expect(PhoneFlavor.local.pairLinkDecision(remote) == .invalid)
    for flavor in [PhoneFlavor.prod, .beta] {
      #expect(flavor.parsePairLink(local) == nil)
      #expect(flavor.pairLinkDecision(local) == .invalid)
    }
  }

  @Test func onlyPairingLinksAreDecided() {
    // Not pairing links at all: another app link, a sign-in callback (dropped elsewhere), any page.
    for text in [
      "b4app://thread/abc", "b4app://auth?handoff=H-stray", "b4app-beta://auth?error=cancelled",
      "b4app-local://auth?handoff=x", "https://b4.run/app/download", "https://example.com/",
    ] {
      for flavor in PhoneFlavor.allCases {
        #expect(flavor.pairLinkDecision(url(text)) == .ignored, "\(text)")
      }
    }
  }

  @Test func theCodeIsNeverPrinted() {
    let link = PairLink(hub: PhoneFlavor.prod.hubURL, code: code)
    #expect(!String(describing: link).contains(code))
    #expect(!String(reflecting: link).contains(code))
    #expect(!String(describing: PairLinkDecision.confirm(link)).contains(code))
  }

  // MARK: What a scan does

  @MainActor @Test func scanWhileSignedOutSignsIn() async throws {
    let rig = try Rig()
    let link = PairLink(hub: PhoneFlavor.prod.hubURL, code: code)
    let outcome = try await rig.account.pair(link, deviceName: "Brian's iPhone")
    guard case .signedIn(let status) = outcome else {
      Issue.record("expected a sign-in, got \(outcome)")
      return
    }
    #expect(status.state == .signedIn)
    #expect(status.account?.orgName == "Brian's Org")
    // A plain enrollment at the flavour's hub, with no token to merge.
    #expect(rig.log.all == ["enroll"])
    #expect(await rig.fake.enrollTokens == [nil])
    #expect(try rig.store.link()?.hubURL == "https://hub.b4.run")
    #expect(try await rig.token() == "tok-paired")
    await rig.account.stopSync()
  }

  @MainActor @Test func scanSameAccountAlreadyPaired() async throws {
    // Signed in to the code's own account: the merge is tried, the hub answers `same_account`, and
    // nothing else happens. The code is not used up.
    let rig = try Rig(mergeRefusal: "same_account")
    try await rig.signIn(devices: withAMac)
    let outcome = try await rig.account.pair(
      PairLink(hub: PhoneFlavor.prod.hubURL, code: code), deviceName: "Brian's iPhone")
    #expect(outcome == .alreadyPaired)
    #expect(PairingCopy.alreadyPaired == "This iPhone is already paired")
    #expect(rig.log.all.filter { $0.hasPrefix("enroll") } == ["enroll+merge"])
    #expect(!rig.log.all.contains("endSession"))
    #expect(await rig.fake.enrollmentCodes[code] != nil)
    #expect(rig.account.accountStatus.account?.orgName == "Phone's Org")
    #expect(try await rig.token() == "tok-own-5501")
    #expect(rig.account.sync != nil)
    await rig.account.stopSync()
  }

  @MainActor @Test func scanPhoneOnlyAccountMerges() async throws {
    let rig = try Rig()
    try await rig.signIn(devices: iPhoneOnly)
    let oldLink = try #require(try rig.store.link())
    let oldRef = try #require(SecretRef(rawValue: oldLink.tokenRef))
    let outcome = try await rig.account.pair(
      PairLink(hub: PhoneFlavor.prod.hubURL, code: code), deviceName: "Brian's iPhone")
    guard case .signedIn(let status) = outcome else {
      Issue.record("expected a merge, got \(outcome)")
      return
    }
    // `enroll(_:replacingToken:)` carried the phone's current token, once.
    #expect(await rig.fake.enrollTokens == ["tok-own-5501"])
    #expect(rig.log.all.filter { $0.hasPrefix("enroll") } == ["enroll+merge"])
    // The phone is now in the code's account, under the device and token the merge gave it.
    #expect(status.account?.orgName == "Brian's Org")
    #expect(try rig.store.link()?.deviceId == "dev-paired")
    #expect(try await rig.token() == "tok-paired")
    // The old token is forgotten (the hub deleted it), with no hub call for it.
    #expect(try await rig.secrets.read(oldRef) == nil)
    #expect(!rig.log.all.contains("endSession"))
    // The old account's device is gone at the hub, so no later sign-in offers it.
    #expect(rig.memory.devices(hubURL: "https://hub.b4.run") == ["dev-paired"])
    await rig.account.stopSync()
  }

  @MainActor @Test func theMergeIsTriedWhateverTheDevicesSay() async throws {
    // A device list that shows a Mac (perhaps a minute stale) does not stop the merge: the hub judges.
    let rig = try Rig()
    try await rig.signIn(devices: withAMac)
    let outcome = try await rig.account.pair(
      PairLink(hub: PhoneFlavor.prod.hubURL, code: code), deviceName: "Brian's iPhone")
    guard case .signedIn = outcome else {
      Issue.record("expected a merge, got \(outcome)")
      return
    }
    #expect(await rig.fake.enrollTokens == ["tok-own-5501"])
    await rig.account.stopSync()
  }

  @MainActor @Test func aRefusedMergeFallsBackToTheSwitchQuestion() async throws {
    // The hub refuses to merge an account that has a Mac, one in a shared org, or (an older hub) with
    // no reason: nothing changed, the code is still good, and the phone asks before switching.
    for reason: String? in ["has_mac", "shared_org", nil] {
      let rig = try Rig(mergeRefusal: .some(reason))
      try await rig.signIn(devices: iPhoneOnly)
      let link = PairLink(hub: PhoneFlavor.prod.hubURL, code: code)
      let outcome = try await rig.account.pair(link, deviceName: "Brian's iPhone")
      #expect(outcome == .askToSwitch(from: "Phone's Org"), "\(reason ?? "none")")
      #expect(rig.account.accountStatus.state == .signedIn)
      #expect(rig.account.accountStatus.account?.orgName == "Phone's Org")
      #expect(try await rig.token() == "tok-own-5501")
      #expect(await rig.fake.enrollmentCodes[code] != nil)
      // Syncing goes on for the account it still is.
      #expect(rig.account.sync != nil)
      await rig.account.stopSync()
    }
  }

  @MainActor @Test func aMergeThatFailsOtherwiseChangesNothing() async throws {
    // An expired or used code: the hub checks it before the merge, so the phone stays as it was and
    // the refusal is one line, without the code in it.
    let rig = try Rig(mergeRefusal: "has_mac")
    try await rig.signIn(devices: withAMac)
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.pair(
        PairLink(hub: PhoneFlavor.prod.hubURL, code: "BCDFGHJK"), deviceName: "Brian's iPhone")
    }
    #expect(error.map { !"\($0)".contains("BCDFGHJK") } == true)
    #expect(rig.account.accountStatus.state == .signedIn)
    #expect(rig.account.accountStatus.account?.orgName == "Phone's Org")
    #expect(try await rig.token() == "tok-own-5501")
    #expect(!rig.log.all.contains("endSession"))
    #expect(rig.account.sync != nil)
    await rig.account.stopSync()
  }

  @MainActor @Test func aMergeWithATokenTheHubNoLongerTakesEnrollsPlainly() async throws {
    // The phone's own session is already dead at the hub: it signs out of it, then the confirmed
    // pairing goes ahead without a merge.
    let rig = try Rig(refuseToken: true)
    try await rig.signIn(devices: iPhoneOnly)
    let outcome = try await rig.account.pair(
      PairLink(hub: PhoneFlavor.prod.hubURL, code: code), deviceName: "Brian's iPhone")
    guard case .signedIn(let status) = outcome else {
      Issue.record("expected a sign-in, got \(outcome)")
      return
    }
    #expect(status.account?.orgName == "Brian's Org")
    #expect(rig.log.all.filter { $0.hasPrefix("enroll") } == ["enroll+merge", "enroll"])
    #expect(try await rig.token() == "tok-paired")
    await rig.account.stopSync()
  }

  @MainActor @Test func scanOtherAccountWithMacAsksToSwitch() async throws {
    let rig = try Rig(mergeRefusal: "has_mac")
    try await rig.signIn(devices: withAMac)
    let link = PairLink(hub: PhoneFlavor.prod.hubURL, code: code)
    let outcome = try await rig.account.pair(link, deviceName: "Brian's iPhone")
    #expect(outcome == .askToSwitch(from: "Phone's Org"))
    // The spec's copy where the code's org is known; the phone does not know it before redeeming the
    // code, so it names "this Mac's account" instead.
    #expect(
      PairingCopy.switchQuestion(to: "Brian's Org", from: "Phone's Org")
        == "Switch to Brian's Org? You'll be signed out of Phone's Org.")
    #expect(
      PairingCopy.switchQuestion(to: nil, from: "Phone's Org")
        == "Switch to this Mac's account? You'll be signed out of Phone's Org.")
    #expect(PairingCopy.switchButton == "Switch")

    // On confirm: the code is redeemed first, then the old session ends at the hub and its token is
    // forgotten.
    let oldLink = try #require(try rig.store.link())
    let oldRef = try #require(SecretRef(rawValue: oldLink.tokenRef))
    let status = try await rig.account.switchAndPair(link, deviceName: "Brian's iPhone")
    let calls = rig.log.all
    let enrolledAt = try #require(calls.lastIndex(of: "enroll"))
    let endedAt = try #require(calls.lastIndex(of: "endSession"))
    #expect(enrolledAt < endedAt)
    #expect(status.state == .signedIn)
    #expect(status.account?.orgName == "Brian's Org")
    #expect(try await rig.token() == "tok-paired")
    #expect(try await rig.secrets.read(oldRef) == nil)
    await rig.account.stopSync()
  }

  @MainActor @Test func aRefusedCodeOnSwitchLeavesThePhoneSignedIn() async throws {
    // The code expired while the question was up: nothing is ended, and the phone is as it was.
    let rig = try Rig(mergeRefusal: "has_mac")
    try await rig.signIn(devices: withAMac)
    let link = PairLink(hub: PhoneFlavor.prod.hubURL, code: code)
    #expect(
      try await rig.account.pair(link, deviceName: "Brian's iPhone") == .askToSwitch(from: "Phone's Org"))
    _ = try await rig.fake.enroll(EnrollRequest(code: code, deviceName: "Someone else", platform: "ios"))
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.switchAndPair(link, deviceName: "Brian's iPhone")
    }
    #expect(error.map { !"\($0)".contains(code) } == true)
    #expect(rig.account.accountStatus.state == .signedIn)
    #expect(rig.account.accountStatus.account?.orgName == "Phone's Org")
    #expect(try await rig.token() == "tok-own-5501")
    #expect(!rig.log.all.contains("endSession"))
    #expect(rig.account.sync != nil)
    await rig.account.stopSync()
  }

  @MainActor @Test func aTypedEnrollOnASignedInPhoneIsRefused() async throws {
    // Only a pairing scan may change a signed-in phone's account, and it asks first.
    let rig = try Rig()
    try await rig.signIn(devices: iPhoneOnly)
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.enroll(url: "https://hub.b4.run", code: code, deviceName: "Brian's iPhone")
    }
    #expect(error?.code == .protocolInvalid)
    #expect(!rig.log.all.contains { $0.hasPrefix("enroll") })
    #expect(rig.account.accountStatus.account?.orgName == "Phone's Org")
    #expect(try await rig.token() == "tok-own-5501")
    await rig.account.stopSync()
  }

  @MainActor @Test func aCodeFromAnotherHubIsNeverMerged() async throws {
    // A phone joined to an operator's hub, scanning a link for the flavour's hub: the current token
    // means nothing there, so it is never sent; the phone asks before switching.
    let rig = try Rig(flavor: .local)
    try await rig.signIn(devices: iPhoneOnly)
    let outcome = try await rig.account.pair(
      PairLink(hub: try HubURL.validate("https://hub.example.com"), code: code), deviceName: "Brian's iPhone")
    #expect(outcome == .askToSwitch(from: "Phone's Org"))
    #expect(await rig.fake.enrollTokens.isEmpty)
    await rig.account.stopSync()
  }

  @MainActor @Test func aRefusedCodeKeepsItOutOfTheError() async throws {
    let rig = try Rig()
    let error = await #expect(throws: WorkspaceError.self) {
      _ = try await rig.account.pair(
        PairLink(hub: PhoneFlavor.prod.hubURL, code: "BCDFGHJK"), deviceName: "Brian's iPhone")
    }
    #expect(error.map { !"\($0)".contains("BCDFGHJK") } == true)
    #expect(rig.account.accountStatus.state == .signedOut)
  }

  // MARK: Connect your Mac

  @Test func connectMacShownWithoutMacosDevice() {
    // Not fetched yet: not phone-only, so a phone that has a Mac never flashes "Connect your Mac".
    #expect(![DeviceInfo]().phoneOnly)
    #expect(iPhoneOnly.phoneOnly)
    #expect(!withAMac.phoneOnly)
    // A Mac that left still counts: its threads are there to read, and the hub will not merge.
    #expect(
      ![
        DeviceInfo(id: "m", name: "Mac", platform: "macos", revokedAt: "2026-11-01T00:00:00.000000Z"),
        DeviceInfo(id: "p", name: "iPhone", platform: "ios"),
      ].phoneOnly)
  }

  @MainActor @Test func theAccountSaysWhetherItHasAMacOnceTheSyncAsks() async throws {
    let rig = try Rig()
    #expect(!rig.account.hasNoMac)
    let told = Mutex(0)
    rig.account.onDevices = { told.withLock { $0 += 1 } }
    try await rig.signIn(devices: iPhoneOnly)
    // The first sync turn reads the devices before its long-poll, and says so.
    try await eventually("the devices to be read") { told.withLock { $0 } > 0 }
    #expect(rig.account.hasNoMac)
    // Signed out, nothing is known.
    _ = await rig.account.logOut()
    #expect(!rig.account.hasNoMac)
  }
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
