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

    public init(
      hubURL: URL, deviceName: String, endSessionTimeout: Duration = MirrorLogOut.standardTimeout,
      syncBackoff: Duration = .seconds(2)
    ) {
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
  /// The running sync, while signed in.
  public private(set) var sync: MirrorSync?
  private var syncTask: Task<Void, Never>?
  /// Moves on every sign-in and sign-out, so a late answer or refusal for an old link changes nothing.
  private var generation = 0

  private static let logger = Logger(subsystem: "com.cacheplane.b4app", category: "account")

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

  /// Start syncing the stored link (at launch). `fromSnapshot` after the mirror was rebuilt.
  public func startSync(fromSnapshot: Bool = false) {
    guard sync == nil, let link else { return }
    startSync(link, fromSnapshot: fromSnapshot)
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

  /// Join a hub with a one-time enrollment code (an operator's hub, or M8c's pairing): validates the URL
  /// before any request, enrolls as an `ios` device, and signs in. The code is not kept.
  public func enroll(url: String, code: String, deviceName: String) async throws -> AccountStatus.Result {
    let base = try HubURL.validate(url)
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let api = makeAPI(base, { nil })
    let enrolled = try await Self.call("join the hub") {
      try await api.enroll(
        EnrollRequest(
          code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
          deviceName: name.isEmpty ? "iPhone" : name, platform: "ios"))
    }
    let session = AuthSession(
      deviceId: enrolled.deviceId, token: enrolled.token, org: enrolled.org, user: enrolled.user,
      needsOnboarding: false)
    return try await signIn(session, hubURL: base, deviceName: name.isEmpty ? "iPhone" : name)
  }

  // MARK: - The signed-in account

  /// Onboarding's full name (1 to 200 characters once trimmed).
  public func completeProfile(fullName: String) async throws -> AccountStatus.Result {
    let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...200).contains(name.count) else {
      throw WorkspaceError(.protocolInvalid, "The full name must be 1 to 200 characters.")
    }
    let me = try await authed("save your name") { try await $0.setProfile(ProfileRequest(fullName: name)) }
    profileArrived(me)
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

  /// Delete the account at the hub, then sign out and empty the mirror. A refusal changes nothing. The
  /// device went with the account, so the next sign-in offers none.
  public func deleteAccount() async throws -> AccountStatus.Result {
    try await authed("delete the account") { try await $0.deleteAccount() }
    memory.clear()
    await endLink(endingSession: false, reason: nil)
    return accountStatus
  }

  /// Read `/v1/me`: the names and whether onboarding is done. A 401 signs out; other failures keep what
  /// is shown.
  public func refreshProfile() async {
    guard let me = try? await authed("read the account", { try await $0.me() }) else { return }
    profileArrived(me)
  }

  // MARK: - Logging out

  /// Stop syncing, end the session at the hub (bounded), forget the token, and empty the mirror. Always
  /// ends signed out.
  public func logOut() async -> AccountStatus.Result {
    await endLink(endingSession: true, reason: nil)
    return accountStatus
  }

  // MARK: - Helpers

  /// Keep the session's token, store the link, start syncing, and publish the new status. A link left
  /// from before (another account) is ended first, without a hub call.
  private func signIn(
    _ session: AuthSession, hubURL: URL? = nil, deviceName: String? = nil
  ) async throws -> AccountStatus.Result {
    let base = hubURL ?? configuration.hubURL
    if link != nil { await endLink(endingSession: false, reason: nil, publishing: false) }
    let ref = SecretRef.make()
    let link = MirrorLink(
      hubURL: Self.canonical(base), deviceId: session.deviceId,
      deviceName: deviceName ?? configuration.deviceName,
      tokenRef: ref.rawValue, orgSlug: session.org.slug, username: session.user.username,
      userId: session.userId,
      displayName: session.user.displayName, orgName: session.org.name,
      needsOnboarding: session.needsOnboarding)
    do {
      try await secrets.put(ref, value: session.token)
      try store.saveLink(link)
    } catch {
      // The hub made a session nobody can use: end it, so it holds no token this phone forgot.
      _ = try? await secrets.remove(ref)
      let token = session.token
      let orphan = makeAPI(base, { token })
      _ = await Bounded.run(within: configuration.endSessionTimeout) { try await orphan.endSession() }
      throw WorkspaceError(.internalError, "Could not keep the sign-in on this iPhone.")
    }
    memory.save(MirrorRememberedDevice(hubURL: link.hubURL, deviceId: link.deviceId))
    generation += 1
    startSync(link, fromSnapshot: false)
    Self.logger.notice("signed in on device \(link.deviceId, privacy: .public)")
    return publish(Self.status(for: link))
  }

  /// Stop syncing, end the session at the hub (when asked; bounded), forget the token, and empty the
  /// mirror, then publish `signedOut` with `reason`.
  private func endLink(endingSession: Bool, reason: SignOutReason?, publishing: Bool = true) async {
    generation += 1
    await stopSync()
    let link = self.link
    let ref = link.flatMap { SecretRef(rawValue: $0.tokenRef) }
    var api: (any HubAPI)?
    if endingSession, let link, let ref, let base = try? HubURL.validate(link.hubURL) {
      api = makeAPI(base, { [secrets] in try await secrets.read(ref) })
    }
    await MirrorLogOut.run(store: store, api: api, timeout: configuration.endSessionTimeout) { [secrets] in
      if let ref { _ = try? await secrets.remove(ref) }
    }
    if publishing { publish(AccountStatus.Result(state: .signedOut, reason: reason)) }
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
      })
    self.sync = sync
    syncTask = Task { await sync.run() }
    Task { await refreshProfile() }
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

  /// This phone as a sign-in describes it: the device it last had at this hub, so the hub reuses it.
  private func deviceSpec() -> DeviceSpec {
    let hub = Self.canonical(configuration.hubURL)
    let previous = memory.load().flatMap { $0.hubURL == hub ? $0.deviceId : nil }
    return DeviceSpec(deviceName: configuration.deviceName, platform: "ios", deviceId: previous)
  }

  /// A `/v1/me` answer: the names, the user id, and whether onboarding is done.
  private func profileArrived(_ me: MeResponse) {
    guard var link else { return }
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
    return WorkspaceError(code, "Could not \(action): \(error.message)", details: .object(details))
  }

  private static func identity(_ identity: Identity) -> AccountIdentity {
    AccountIdentity(
      id: identity.id, kind: identity.kind, name: identity.name, createdAt: identity.createdAt,
      lastUsedAt: identity.lastUsedAt)
  }
}

/// The device this phone last had at a hub. Kept across a log-out, which empties the mirror, so the
/// next sign-in offers it and the hub reuses it rather than making another. An id, not a secret.
public struct MirrorRememberedDevice: Codable, Sendable, Equatable {
  public var hubURL: String
  public var deviceId: String
  public init(hubURL: String, deviceId: String) {
    self.hubURL = hubURL
    self.deviceId = deviceId
  }
}

/// Where `MirrorRememberedDevice` is kept: a small JSON file beside the mirror, or memory only.
public final class MirrorDeviceMemory: Sendable {
  private let url: URL?
  private let value: Mutex<MirrorRememberedDevice?>

  /// `url` nil keeps it in memory (tests).
  public init(url: URL?) {
    self.url = url
    let stored = url.flatMap { try? Data(contentsOf: $0) }.flatMap {
      try? JSONCoding.decoder.decode(MirrorRememberedDevice.self, from: $0)
    }
    value = Mutex(stored)
  }

  public func load() -> MirrorRememberedDevice? { value.withLock { $0 } }

  public func save(_ device: MirrorRememberedDevice) {
    value.withLock { $0 = device }
    guard let url, let data = try? JSONCoding.encoder.encode(device) else { return }
    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  public func clear() {
    value.withLock { $0 = nil }
    if let url { try? FileManager.default.removeItem(at: url) }
  }
}
