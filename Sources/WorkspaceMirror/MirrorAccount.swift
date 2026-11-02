import Foundation
import Synchronization
import WorkspaceProtocol
import WorkspaceSecrets
import WorkspaceSync
import os

/// The iPhone's account (sign-in plan, Task 14): the phone signs in at its flavour's hub itself, as it
/// enrolled before, with no coordinator in between. It keeps the device token in the Keychain under the
/// link's reference (read for each request, never held), stores the link in the mirror, and runs the
/// mirror's sync while signed in.
///
/// - **Signing in** (a passkey, Apple's native sheet, or an enrollment code) offers the device this
///   phone had at the hub last, so the hub reuses it (`DeviceSpec.deviceId`), and starts syncing.
/// - **Log out** stops syncing, ends the session at the hub (`DELETE /v1/sessions/self`, at most
///   `endSessionTimeout`; a hub that does not answer does not stop it), forgets the token, and empties
///   the mirror (`MirrorLogOut`, D-053). The device stays enrolled.
/// - **A 401** from the sync or an account call means the hub no longer takes the token: the phone
///   signs out the same way, without the hub call, with the rejected-by-hub reason.
///
/// Its methods are those of `WorkspaceUI.AccountHost`, which the app declares it conforms to, so the
/// shared model runs the same sign-in, onboarding, and Settings flows over it as over the coordinator.
/// No credential, token, nonce, or Apple code is logged, stored, or put in an error.
@MainActor public final class MirrorAccount {
  public struct Configuration: Sendable {
    /// The flavour's hub, where every sign-in goes (an enrollment names its own).
    public var hubURL: URL
    /// What the hub calls this device.
    public var deviceName: String
    /// The longest a log-out waits for the hub to end the session.
    public var endSessionTimeout: Duration
    /// The sync's first wait after a failure.
    public var syncBackoff: Duration
    /// This build's flavour, recorded on every link it writes (`MirrorLink.flavor`).
    public var flavor: PhoneFlavor

    public init(
      hubURL: URL, deviceName: String, endSessionTimeout: Duration = MirrorLogOut.standardTimeout,
      syncBackoff: Duration = .seconds(2), flavor: PhoneFlavor = .local
    ) {
      self.flavor = flavor
      self.hubURL = hubURL
      self.deviceName = deviceName
      self.endSessionTimeout = endSessionTimeout
      self.syncBackoff = syncBackoff
    }
  }

  /// A client for a hub, whose token closure runs for each request (`nil`: none is sent).
  public typealias APIFactory = @Sendable (URL, @escaping @Sendable () async throws -> String?) -> any HubAPI

  public let store: MirrorStore
  private let secrets: any SecretStore
  private let configuration: Configuration
  private let memory: MirrorDeviceMemory
  private let makeAPI: APIFactory
  private let onBatch: @Sendable (AppliedBatch) async -> Void
  private let onSyncStatus: @Sendable (MirrorSyncStatus) async -> Void

  /// Who this phone is signed in as, as `account.status` would say it. Known from the stored link at
  /// once, so a launch never waits for the hub to decide between sign-in and the workspace.
  public private(set) var accountStatus: AccountStatus.Result
  /// Called after every change of `accountStatus`: a sign-in, onboarding, a log-out, or the hub
  /// refusing the token.
  public var onChange: (@MainActor (AccountStatus.Result) -> Void)?
  /// Called after the sync (or a pairing scan) has read the account's devices, so the app can say
  /// whether the account has a Mac (`hasNoMac`).
  public var onDevices: (@MainActor () -> Void)?
  /// The running sync, while signed in.
  public private(set) var sync: MirrorSync?
  /// Set by `suspendSync()` (the app is going to the background, M8f) and cleared by `resumeSync()`: a
  /// sync started meanwhile (a sign-in that finished late, a restart after a refused call) begins
  /// parked, so it holds no lock on the App Group's mirror while the app is suspended.
  private var syncSuspended = false
  private var syncTask: Task<Void, Never>?
  /// Moves on every sign-in and sign-out, so a late answer or refusal for an old link changes nothing.
  private var generation = 0

  nonisolated private static let logger = Logger(subsystem: "com.cacheplane.b4app", category: "account")

  public init(
    store: MirrorStore, secrets: any SecretStore, configuration: Configuration, memory: MirrorDeviceMemory,
    makeAPI: @escaping APIFactory = { HTTPHubAPI(baseURL: $0, token: $1) },
    onBatch: @escaping @Sendable (AppliedBatch) async -> Void = { _ in },
    onSyncStatus: @escaping @Sendable (MirrorSyncStatus) async -> Void = { _ in }
  ) {
    self.store = store
    self.secrets = secrets
    self.configuration = configuration
    self.memory = memory
    self.makeAPI = makeAPI
    self.onBatch = onBatch
    self.onSyncStatus = onSyncStatus
    accountStatus = Self.status(for: try? store.link())
  }

  /// The stored link, while signed in.
  public var link: MirrorLink? { try? store.link() }

  /// The account is known to have no Mac (`GET /v1/devices`, as the sync last read it): "Connect your
  /// Mac" replaces the thread list. False while signed out and before the list is read, so a phone
  /// that has a Mac never shows it.
  public var hasNoMac: Bool { link != nil && ((try? store.devices()) ?? []).phoneOnly }

  /// Start syncing the stored link (at launch). `fromSnapshot` after the mirror was rebuilt.
  public func startSync(fromSnapshot: Bool = false) {
    guard sync == nil, let link else { return }
    startSync(link, fromSnapshot: fromSnapshot)
  }

  /// Park the sync between turns and return once it is idle (`MirrorSync.suspend`); syncs started
  /// before `resumeSync()` begin parked.
  public func suspendSync() async {
    syncSuspended = true
    await sync?.suspend()
  }

  /// Let the sync go round again (`MirrorSync.resume`), and the syncs started from now on run at once.
  public func resumeSync() async {
    syncSuspended = false
    await sync?.resume()
  }

  /// Stop syncing and wait for the loop to end, so nothing it does lands after this returns.
  public func stopSync() async {
    let running = syncTask
    await sync?.stop()
    sync = nil
    syncTask = nil
    await running?.value
  }

  // MARK: - Signing in with a passkey

  public func passkeyBegin() async throws -> AccountPasskeyBegin.Result {
    let api = signInAPI()
    let begun = try await Self.call("begin a passkey sign-in") { try await api.passkeyBegin() }
    return AccountPasskeyBegin.Result(
      ceremonyId: begun.ceremonyId, authentication: begun.authentication, registration: begun.registration)
  }

  /// Finish the ceremony with exactly one of an assertion (sign in) or an attestation (sign up).
  public func signIn(passkey params: AccountPasskeyFinish.Params) async throws -> AccountStatus.Result {
    guard (params.assertion == nil) != (params.attestation == nil) else {
      throw WorkspaceError(.protocolInvalid, "Send exactly one of assertion or attestation.")
    }
    let api = signInAPI()
    let request = PasskeyFinishRequest(
      ceremonyId: params.ceremonyId, assertion: params.assertion, attestation: params.attestation,
      device: deviceSpec())
    let session = try await Self.call("sign in") { try await api.passkeyFinish(request) }
    return try await signIn(session)
  }

  // MARK: - Signing in with Apple (the native sheet)

  /// Begin a native ceremony. Apple's sheet is handed the SHA-256 hex of its nonce.
  public func appleBegin() async throws -> AppleNativeCeremony {
    let api = signInAPI()
    let begun = try await Self.call("begin Sign in with Apple") { try await api.appleBegin() }
    return AppleNativeCeremony(ceremonyId: begun.ceremonyId, nonce: begun.nonce)
  }

  /// Hand what Apple's sheet answered to the hub, once, and sign in (or up).
  public func signIn(
    apple credential: AppleCredential, ceremonyId: String
  ) async throws -> AccountStatus.Result {
    let api = signInAPI()
    let name = credential.fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let request = AppleNativeRequest(
      ceremonyId: ceremonyId, identityToken: credential.identityToken,
      authorizationCode: credential.authorizationCode, fullName: name.isEmpty ? nil : name,
      device: deviceSpec())
    let session = try await Self.call("finish Sign in with Apple") { try await api.appleNative(request) }
    return try await signIn(session)
  }

  // MARK: - Enrollment codes

  /// Join a hub with a typed one-time enrollment code (an operator's hub): validates the URL before any
  /// request, enrolls as an `ios` device, and signs in. The code is not kept. Refused on a phone that is
  /// signed in: a typed code would replace the account without asking; pairing (`pair`) asks.
  public func enroll(url: String, code: String, deviceName: String) async throws -> AccountStatus.Result {
    guard link == nil else {
      throw WorkspaceError(
        .protocolInvalid, "This iPhone is signed in. Scan the code your Mac shows, or log out first.")
    }
    let base = try HubURL.validate(url)
    let (session, name) = try await redeem(code, at: base, deviceName: deviceName)
    return try await signIn(session, hubURL: base, deviceName: name)
  }

  /// Redeem `code` at `base` with no token: the session it gives, and the device name used. Nothing on
  /// this phone changes.
  private func redeem(
    _ code: String, at base: URL, deviceName: String
  ) async throws -> (AuthSession, String) {
    let name = Self.deviceName(deviceName)
    let api = makeAPI(base, { nil })
    let request = EnrollRequest(
      code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
      device: deviceSpec(hubURL: base, deviceName: name))
    let enrolled = try await Self.call("join the hub") { try await api.enroll(request) }
    return (Self.session(enrolled), name)
  }

  private static func deviceName(_ typed: String) -> String {
    let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "iPhone" : name
  }

  private static func session(_ enrolled: EnrollResponse) -> AuthSession {
    AuthSession(
      deviceId: enrolled.deviceId, token: enrolled.token, org: enrolled.org, user: enrolled.user,
      needsOnboarding: false)
  }

  // MARK: - Pairing by QR code (D-066)

  /// A pairing link the person confirmed ("Pair this iPhone with the hub at <host>?"):
  /// - signed out, it enrolls into the code's account, which signs the phone in;
  /// - signed in at the code's hub, whatever the account's devices, it first tries the merge: enroll
  ///   with the current token. The hub checks the code before anything else (a wrong or expired one is
  ///   refused and nothing changes), then merges a phone-only account into the code's, or refuses
  ///   with `merge_refused` and a reason: `same_account` is "already paired"; `has_mac`, `shared_org`,
  ///   or none (an older hub) asks the switch question;
  /// - signed in at another hub, the token means nothing there, so it is never sent: it asks.
  ///
  /// Any other failure changes nothing and is thrown. The code is not kept; neither it nor the token
  /// is logged or put in an error.
  public func pair(_ pairLink: PairLink, deviceName: String) async throws -> MirrorPairOutcome {
    guard let current = link else {
      return .signedIn(try await enroll(pairLink, deviceName: deviceName))
    }
    let from = current.orgName ?? current.orgSlug
    guard Self.canonical(pairLink.hub) == current.hubURL else { return .askToSwitch(from: from) }
    do {
      return .signedIn(try await merge(pairLink, into: current, deviceName: deviceName))
    } catch let error as HubError where error.code == "merge_refused" {
      Self.logger.notice(
        "the hub refused to merge this phone's account (\(error.reason ?? "no reason", privacy: .public))")
      return error.reason == "same_account" ? .alreadyPaired : .askToSwitch(from: from)
    }
  }

  /// The switch question was confirmed. The code is redeemed first, with no token; only once that
  /// succeeds is the old session ended at the hub (bounded), its token forgotten, and the mirror
  /// emptied for the new account. A refused code (expired while the question was up, already used)
  /// leaves the phone signed in as it was.
  public func switchAndPair(_ pairLink: PairLink, deviceName: String) async throws -> AccountStatus.Result {
    guard link != nil else { return try await enroll(pairLink, deviceName: deviceName) }
    let (session, name) = try await redeem(pairLink.code, at: pairLink.hub, deviceName: deviceName)
    return try await signIn(session, hubURL: pairLink.hub, deviceName: name, endingPrevious: true)
  }

  private func enroll(_ pairLink: PairLink, deviceName: String) async throws -> AccountStatus.Result {
    try await enroll(url: pairLink.hub.absoluteString, code: pairLink.code, deviceName: deviceName)
  }

  /// Enroll with this phone's own token, which merges its phone-only account into the code's. The sync
  /// is stopped first, since the hub deletes the old device and its token as it merges; a refusal
  /// restarts it on the account the phone still is. A token the hub no longer takes signs that
  /// account out, and the confirmed pairing goes ahead without a merge.
  private func merge(
    _ pairLink: PairLink, into current: MirrorLink, deviceName: String
  ) async throws -> AccountStatus.Result {
    guard let ref = SecretRef(rawValue: current.tokenRef), let token = try? await secrets.read(ref) else {
      throw WorkspaceError(.signedOut, "Nobody is signed in on this iPhone.")
    }
    let name = Self.deviceName(deviceName)
    // Every device this phone has had at the hub, its current one included: the hub matches them only
    // against the code's account, so the phone's earlier device there is reused.
    let request = EnrollRequest(
      code: pairLink.code, device: deviceSpec(hubURL: pairLink.hub, deviceName: name))
    let api = makeAPI(pairLink.hub, { nil })
    let seen = generation
    await stopSync()
    let enrolled: EnrollResponse
    do {
      enrolled = try await api.enroll(request, replacingToken: token)
    } catch let error as HubError where error.status == 401 && error.code == "unauthorized" {
      await rejected(generation: seen)
      return try await enroll(pairLink, deviceName: deviceName)
    } catch {
      if seen == generation, link?.tokenRef == current.tokenRef { startSync(current, fromSnapshot: false) }
      if let error = error as? HubError, error.code == "merge_refused" { throw error }
      if let error = error as? HubError { throw Self.accountError(error, doing: "join the hub") }
      throw error
    }
    // The hub deleted the old account's device with it: no later sign-in offers it.
    memory.forget(hubURL: current.hubURL, deviceId: current.deviceId)
    Self.logger.notice("merged this phone's account into the pairing code's")
    return try await signIn(Self.session(enrolled), hubURL: pairLink.hub, deviceName: name)
  }

  // MARK: - The signed-in account

  /// Onboarding's full name (1 to 200 characters once trimmed).
  public func completeProfile(fullName: String) async throws -> AccountStatus.Result {
    let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...200).contains(name.count) else {
      throw WorkspaceError(.protocolInvalid, "The full name must be 1 to 200 characters.")
    }
    let seen = generation
    let me = try await authed("save your name") { try await $0.setProfile(ProfileRequest(fullName: name)) }
    profileArrived(me, generation: seen)
    return accountStatus
  }

  public func identities() async throws -> [AccountIdentity] {
    try await authed("list your sign-in methods") { try await $0.identities() }.map(Self.identity)
  }

  public func addPasskeyBegin() async throws -> AccountAddPasskeyBegin.Result {
    let begun = try await authed("begin adding a passkey") { try await $0.addPasskeyBegin() }
    return AccountAddPasskeyBegin.Result(ceremonyId: begun.ceremonyId, registration: begun.registration)
  }

  public func addPasskeyFinish(_ params: AccountAddPasskeyFinish.Params) async throws -> AccountIdentity {
    let request = AddPasskeyFinishRequest(ceremonyId: params.ceremonyId, attestation: params.attestation)
    return Self.identity(try await authed("add the passkey") { try await $0.addPasskeyFinish(request) })
  }

  /// Unlink one sign-in method; answers the ones left.
  public func removeIdentity(id: String) async throws -> [AccountIdentity] {
    try await authed("remove the sign-in method") { api in
      try await api.removeIdentity(id)
      return try await api.identities()
    }
    .map(Self.identity)
  }

  /// Begin linking an Apple ID with the native sheet. `apple_linked` with one already.
  public func appleLinkBegin() async throws -> AppleNativeCeremony {
    let begun = try await authed("begin connecting an Apple ID") {
      try await $0.appleLinkBegin(AppleBeginRequest())
    }
    return AppleNativeCeremony(ceremonyId: begun.ceremonyId, nonce: begun.nonce)
  }

  /// Hand the sheet's answer to the hub once; answers the new method.
  public func linkApple(_ credential: AppleCredential, ceremonyId: String) async throws -> AccountIdentity {
    let request = AppleLinkNativeRequest(
      ceremonyId: ceremonyId, identityToken: credential.identityToken,
      authorizationCode: credential.authorizationCode)
    return Self.identity(try await authed("connect the Apple ID") { try await $0.appleLinkNative(request) })
  }

  /// Delete the account at the hub, then sign out and empty the mirror. A refusal changes nothing (the
  /// sync starts again). The device went with the account, so no later sign-in offers it. The link is
  /// taken and the sync stopped first, so a 401 the sync meets as the account goes cannot sign the
  /// phone out with "This iPhone was signed out of …" or change which device is forgotten.
  public func deleteAccount() async throws -> AccountStatus.Result {
    guard let deleting = link else { throw WorkspaceError(.signedOut, "Nobody is signed in on this iPhone.") }
    generation += 1
    await stopSync()
    let seen = generation
    do {
      try await authed("delete the account") { try await $0.deleteAccount() }
    } catch {
      if seen == generation, link?.tokenRef == deleting.tokenRef { startSync(deleting, fromSnapshot: false) }
      throw error
    }
    memory.forget(hubURL: deleting.hubURL, deviceId: deleting.deviceId)
    if seen == generation, link?.tokenRef == deleting.tokenRef {
      await endLink(endingSession: false, reason: nil)
    }
    return accountStatus
  }

  /// Read `/v1/me`: the names and whether onboarding is done. A 401 signs out; other failures keep what
  /// is shown.
  public func refreshProfile() async {
    let seen = generation
    guard let me = try? await authed("read the account", { try await $0.me() }) else { return }
    profileArrived(me, generation: seen)
  }

  // MARK: - Logging out

  /// Stop syncing, end the session at the hub (bounded), forget the token, and empty the mirror. Always
  /// ends signed out.
  public func logOut() async -> AccountStatus.Result {
    await endLink(endingSession: true, reason: nil)
    return accountStatus
  }

  // MARK: - Helpers

  /// Keep the session's token, store the link, start syncing, and publish the new status. Any sync
  /// still running is stopped and the mirror emptied first, whether or not a link is left from before
  /// (a log-out still waiting on the hub may already have cleared it), so nothing of another account
  /// reaches the new one.
  ///
  /// A link left from before (another account) is ended: its rows go before the new link is saved, and
  /// its token only once the new link and token are saved, so the phone is never left holding neither.
  /// `endingPrevious` then ends the old session at the hub (a confirmed switch; bounded), with the
  /// token taken before it was forgotten; otherwise it is dropped without a call (its token is already
  /// dead, or the hub deleted it in a merge). If the new sign-in cannot be kept, the old account is
  /// gone all the same and `signedOut` is published.
  private func signIn(
    _ session: AuthSession, hubURL: URL? = nil, deviceName: String? = nil, endingPrevious: Bool = false
  ) async throws -> AccountStatus.Result {
    let base = hubURL ?? configuration.hubURL
    generation += 1
    await stopSync()
    let previous = link
    let previousRef = previous.flatMap { SecretRef(rawValue: $0.tokenRef) }
    var previousToken: String?
    if endingPrevious, let previousRef { previousToken = try? await secrets.read(previousRef) }
    try? store.forgetAccount()
    let ref = SecretRef.make()
    let link = MirrorLink(
      hubURL: Self.canonical(base), deviceId: session.deviceId,
      deviceName: deviceName ?? configuration.deviceName,
      tokenRef: ref.rawValue, orgSlug: session.org.slug, username: session.user.username,
      userId: session.userId,
      displayName: session.user.displayName, orgName: session.org.name,
      needsOnboarding: session.needsOnboarding, flavor: configuration.flavor.rawValue)
    do {
      try await secrets.put(ref, value: session.token)
      try store.saveLink(link)
    } catch {
      // The hub made a session nobody can use: end it, so it holds no token this phone forgot.
      _ = try? await secrets.remove(ref)
      let token = session.token
      let orphan = makeAPI(base, { token })
      _ = await Bounded.run(within: configuration.endSessionTimeout) { try await orphan.endSession() }
      if let previous {
        await endPrevious(previous, ref: previousRef, token: previousToken)
        publish(AccountStatus.Result(state: .signedOut))
      }
      throw WorkspaceError(.internalError, "Could not keep the sign-in on this iPhone.")
    }
    memory.remember(MirrorRememberedDevice(hubURL: link.hubURL, deviceId: link.deviceId))
    startSync(link, fromSnapshot: false)
    Self.logger.notice("signed in on device \(link.deviceId, privacy: .public)")
    let status = publish(Self.status(for: link))
    if let previous { await endPrevious(previous, ref: previousRef, token: previousToken) }
    return status
  }

  /// Forget a replaced link's token and, given the token (a confirmed switch), end its session at the
  /// hub, bounded.
  private func endPrevious(_ previous: MirrorLink, ref: SecretRef?, token: String?) async {
    if let ref { _ = try? await secrets.remove(ref) }
    guard let token, let base = try? HubURL.validate(previous.hubURL) else { return }
    let api = makeAPI(base, { token })
    _ = await Bounded.run(within: configuration.endSessionTimeout) { try await api.endSession() }
  }

  /// Stop syncing, end the session at the hub (when asked; bounded), forget the token, and empty the
  /// mirror, then publish `signedOut` with `reason`. The token forgotten is always the one taken on
  /// entry; the mirror is emptied and `signedOut` published only if nothing signed in (or out) while
  /// the hub was being waited for, since a pairing scan can sign another account in meanwhile.
  private func endLink(endingSession: Bool, reason: SignOutReason?) async {
    generation += 1
    let entered = generation
    await stopSync()
    let link = self.link
    let ref = link.flatMap { SecretRef(rawValue: $0.tokenRef) }
    var api: (any HubAPI)?
    if endingSession, let link, let ref, let base = try? HubURL.validate(link.hubURL) {
      api = makeAPI(base, { [secrets] in try await secrets.read(ref) })
    }
    await MirrorLogOut.run(
      store: store, api: api, timeout: configuration.endSessionTimeout,
      forgetToken: { [secrets] in
        if let ref { _ = try? await secrets.remove(ref) }
      },
      stillCurrent: { @MainActor [weak self] in self?.generation == entered })
    guard generation == entered else { return }
    publish(AccountStatus.Result(state: .signedOut, reason: reason))
  }

  /// The hub refused this link's token: sign out with the reason, unless the link has changed since.
  private func rejected(generation seen: Int) async {
    guard seen == generation, let link else { return }
    Self.logger.notice("the hub refused device \(link.deviceId, privacy: .public)'s token; signing out")
    await endLink(
      endingSession: false, reason: .rejectedByHub(link.orgName ?? link.orgSlug))
  }

  private func startSync(_ link: MirrorLink, fromSnapshot: Bool) {
    guard let base = try? HubURL.validate(link.hubURL), let ref = SecretRef(rawValue: link.tokenRef) else {
      return
    }
    let api = makeAPI(base, { [secrets] in try await secrets.read(ref) })
    let seen = generation
    let sync = MirrorSync(
      store: store, api: api, onBatch: onBatch, onStatus: onSyncStatus,
      initialBackoff: configuration.syncBackoff,
      startFromSnapshot: fromSnapshot,
      onUnauthorized: { [weak self] in
        // Not awaited by the loop's caller: signing out waits for the loop, which is still running.
        Task { @MainActor in await self?.rejected(generation: seen) }
      },
      onDevices: { [weak self] in await self?.devicesRead(generation: seen) },
      startSuspended: syncSuspended)
    self.sync = sync
    syncTask = Task { await sync.run() }
    Task { await refreshProfile() }
  }

  /// The sync stored the account's devices; told only for the link it was syncing.
  private func devicesRead(generation seen: Int) {
    guard seen == generation else { return }
    onDevices?()
  }

  /// The signed-in hub's client, its token read from the Keychain for each request. A 401 signs out.
  private func authed<T: Sendable>(
    _ action: String, _ body: @Sendable (any HubAPI) async throws -> T
  ) async throws -> T {
    guard let link, let base = try? HubURL.validate(link.hubURL), let ref = SecretRef(rawValue: link.tokenRef)
    else { throw WorkspaceError(.signedOut, "Nobody is signed in on this iPhone.") }
    let seen = generation
    let api = makeAPI(base, { [secrets] in try await secrets.read(ref) })
    do {
      return try await body(api)
    } catch let error as HubError where error.status == 401 && error.code == "unauthorized" {
      await rejected(generation: seen)
      throw WorkspaceError(.signedOut, "This iPhone was signed out.")
    } catch let error as HubError {
      throw Self.accountError(error, doing: action)
    }
  }

  /// The flavour's hub with no token: the sign-in calls carry none.
  private func signInAPI() -> any HubAPI { makeAPI(configuration.hubURL, { nil }) }

  /// This phone as a sign-in (or an enrollment, at the hub it enrolls with) describes it: every device
  /// it has had at that hub, most recent first, so the hub reuses the one that is the user's (the phone
  /// cannot know whose passkey or Apple ID is coming, nor which account a code is for). The first goes
  /// as `deviceId`, the rest as candidates, left out when none. The flavour's hub and the configured
  /// name unless given.
  private func deviceSpec(hubURL: URL? = nil, deviceName: String? = nil) -> DeviceSpec {
    let known = memory.devices(hubURL: Self.canonical(hubURL ?? configuration.hubURL))
    let rest = Array(known.dropFirst())
    return DeviceSpec(
      deviceName: deviceName ?? configuration.deviceName, platform: "ios", deviceId: known.first,
      candidateDeviceIds: rest.isEmpty ? nil : rest)
  }

  /// A `/v1/me` answer: the names, the user id, and whether onboarding is done. Dropped when it was
  /// asked under another link (a log-out and a sign-in since) or names another device.
  private func profileArrived(_ me: MeResponse, generation seen: Int) {
    guard seen == generation, var link, me.deviceId == link.deviceId else { return }
    let before = link
    link.displayName = me.user.displayName
    link.orgName = me.org.name
    link.userId = me.userId ?? link.userId
    link.needsOnboarding = !me.onboarded
    guard link != before else { return }
    try? store.saveLink(link)
    publish(Self.status(for: link))
  }

  @discardableResult
  private func publish(_ status: AccountStatus.Result) -> AccountStatus.Result {
    accountStatus = status
    onChange?(status)
    return status
  }

  /// The status a link stands for. The local account id is the device's: the hub reuses a device only
  /// for its own user, so another account is always another id.
  static func status(for link: MirrorLink?) -> AccountStatus.Result {
    guard let link else { return AccountStatus.Result(state: .signedOut) }
    let account = AccountStatus.Account(
      id: link.deviceId, displayName: link.displayName ?? link.username,
      orgName: link.orgName ?? link.orgSlug, hubURL: link.hubURL)
    return AccountStatus.Result(
      state: link.needsOnboarding == true ? .needsOnboarding : .signedIn, account: account)
  }

  private static func canonical(_ url: URL) -> String {
    (try? HubURL.canonical(url.absoluteString)) ?? url.absoluteString
  }

  /// A hub call whose refusal keeps the hub's code when it is one the sign-in screen has a line for.
  private static func call<T: Sendable>(_ action: String, _ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as HubError {
      throw accountError(error, doing: action)
    }
  }

  /// The hub's own code when the protocol knows it for signing in and the account, otherwise one by
  /// the status. Never a request body; the hub's message names no secret.
  static func accountError(_ error: HubError, doing action: String) -> WorkspaceError {
    let known: Set<ErrorCode> = [
      .signupClosed, .ceremonyExpired, .credentialRejected, .lastIdentity, .mergeRefused, .appleLinked,
      .sharedOrg, .rateLimited, .notFound,
    ]
    let code: ErrorCode
    if let own = ErrorCode(rawValue: error.code), known.contains(own) {
      code = own
    } else {
      switch error.status {
      case 401, 403: code = .authRequired
      case 429: code = .rateLimited
      case 0, 500...: code = .endpointUnavailable
      default: code = .protocolInvalid
      }
    }
    var details: [String: JSONValue] = ["hubCode": .string(error.code)]
    if let wait = error.retryAfterMs { details["retryAfterMs"] = .number(Double(wait)) }
    // The hub's reason names no secret (`unknown_credential`, a merge refusal's).
    if let reason = error.reason { details["reason"] = .string(reason) }
    return WorkspaceError(code, "Could not \(action): \(error.message)", details: .object(details))
  }

  private static func identity(_ identity: Identity) -> AccountIdentity {
    AccountIdentity(
      id: identity.id, kind: identity.kind, name: identity.name, createdAt: identity.createdAt,
      lastUsedAt: identity.lastUsedAt)
  }
}

extension MirrorAccount {
  /// Empties a mirror another flavour left in this flavour's folder, before anything reads it, and
  /// answers its token's reference for the caller to forget. Builds before the flavoured folders kept
  /// every flavour's mirror in `b4app`, prod's folder, and prod and beta share the app's container, so a
  /// prod install can inherit a beta mirror whose link points at the test hub; it starts clean
  /// instead.
  ///
  /// Only that case counts: the prod folder (`b4app-beta` and `b4app-local` are new, so all they hold
  /// is this build's own), a link with no `flavor` (written before the flavoured folders), and another
  /// flavour's hub. A link this build wrote, to whatever hub (a code for another flavour's hub, a
  /// pairing link, an operator's hub), is this phone's own and is kept.
  public nonisolated static func discardForeignLink(in store: MirrorStore, flavor: PhoneFlavor) -> SecretRef?
  {
    guard flavor == .prod, let link = try? store.link(), link.flavor == nil,
      let hub = try? HubURL.canonical(link.hubURL)
    else { return nil }
    let others = PhoneFlavor.allCases.filter { $0 != flavor }.compactMap {
      try? HubURL.canonical($0.hubURL.absoluteString)
    }
    guard others.contains(hub) else { return nil }
    try? store.forgetAccount()
    logger.notice("emptied a mirror another flavour's build left here")
    return SecretRef(rawValue: link.tokenRef)
  }
}

/// A device this phone has had at a hub. Kept across a log-out, which empties the mirror, so a later
/// sign-in offers it and the hub reuses it rather than making another. An id, not a secret.
public struct MirrorRememberedDevice: Codable, Sendable, Equatable {
  public var hubURL: String
  public var deviceId: String
  public init(hubURL: String, deviceId: String) {
    self.hubURL = hubURL
    self.deviceId = deviceId
  }
}

/// Where the phone's devices are remembered: a small JSON file beside the mirror, or memory only. At
/// most `limit` per hub, the most recently signed in first; one phone signs in to several accounts
/// with one device each.
public final class MirrorDeviceMemory: Sendable {
  /// How many devices are kept for each hub.
  public static let limit = 8

  private let url: URL?
  private let value: Mutex<[MirrorRememberedDevice]>

  /// `url` nil keeps them in memory (tests).
  public init(url: URL?) {
    self.url = url
    let stored = url.flatMap { try? Data(contentsOf: $0) }.flatMap {
      try? JSONCoding.decoder.decode([MirrorRememberedDevice].self, from: $0)
    }
    value = Mutex(stored ?? [])
  }

  /// Every device remembered, most recent first.
  public func all() -> [MirrorRememberedDevice] { value.withLock { $0 } }

  /// The devices remembered at `hubURL`, most recent first.
  public func devices(hubURL: String) -> [String] {
    value.withLock { $0.filter { $0.hubURL == hubURL }.map(\.deviceId) }
  }

  /// `device` is the most recent at its hub; the oldest beyond `limit` there are dropped.
  public func remember(_ device: MirrorRememberedDevice) {
    write { devices in
      devices.removeAll { $0 == device }
      devices.insert(device, at: 0)
      var atHub = 0
      devices.removeAll { remembered in
        guard remembered.hubURL == device.hubURL else { return false }
        atHub += 1
        return atHub > Self.limit
      }
    }
  }

  /// One device is gone (its account was deleted).
  public func forget(hubURL: String, deviceId: String) {
    write { $0.removeAll { $0 == MirrorRememberedDevice(hubURL: hubURL, deviceId: deviceId) } }
  }

  public func clear() { write { $0 = [] } }

  private func write(_ change: (inout [MirrorRememberedDevice]) -> Void) {
    let devices = value.withLock { devices in
      change(&devices)
      return devices
    }
    guard let url else { return }
    if devices.isEmpty {
      try? FileManager.default.removeItem(at: url)
    } else if let data = try? JSONCoding.encoder.encode(devices) {
      try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }
}
