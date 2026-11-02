import CryptoKit
import Foundation
import Security
import WorkspacePlatform
import WorkspaceProtocol
import WorkspaceStorage
import WorkspaceSync

/// The `account.*` commands (sign-in plan, Task 10): every hub call of a sign-in, onboarding, the
/// account's sign-in methods, log-out, and deletion. The app runs only the ceremony UI; the token never
/// leaves the coordinator. A WebAuthn response or an Apple handoff arrives once over the socket and goes
/// to the hub; the Apple flow's verifier is made and kept here. None of them is logged, stored, or put
/// in an error.
extension AccountManager {
  /// Log-out's bounds (the spec's two 10 s steps, then a short last word for the hub session).
  public struct LogoutTimeouts: Sendable, Equatable {
    /// Step 1: interrupt the running turns, stop the servers, and let admitted commands finish.
    public var work: Duration
    /// Step 2: push the change log once. Step 3 (ending the hub session) gets what is left of it.
    public var push: Duration
    /// Step 3's least time, when the push used all of its own.
    public var endSessionFloor: Duration

    public init(work: Duration, push: Duration, endSessionFloor: Duration) {
      self.work = work
      self.push = push
      self.endSessionFloor = endSessionFloor
    }

    /// At most 10 + 10 + 0.5 s: a log-out returns within 21 s whatever the hub and the runtimes do.
    public static let standard = LogoutTimeouts(
      work: .seconds(10), push: .seconds(10), endSessionFloor: .milliseconds(500))
  }

  /// A Sign in with Apple web ceremony: the hub's id and the verifier whose SHA-256 the hub holds.
  struct AppleCeremony: Sendable {
    var id: String
    var verifier: String
  }

  /// What `hub.status` says once after a log-out that could not reach the hub.
  public static let sessionLeftOpenNotice =
    "The last sign-out could not reach the hub; that session was left open there."

  func setLogoutTimeouts(_ timeouts: LogoutTimeouts) { logoutTimeouts = timeouts }

  // MARK: - Signing in with a passkey

  public func passkeyBegin() async throws -> AccountPasskeyBegin.Result {
    let api = signInAPI()
    let begun = try await Self.hubCall("begin a passkey sign-in") { try await api.passkeyBegin() }
    return AccountPasskeyBegin.Result(
      ceremonyId: begun.ceremonyId, authentication: begun.authentication, registration: begun.registration)
  }

  /// Finish the ceremony and sign in as the hub's answer (or sign up, with an attestation).
  public func passkeyFinish(_ params: AccountPasskeyFinish.Params) async throws -> AccountStatus.Result {
    guard (params.assertion == nil) != (params.attestation == nil) else {
      throw WorkspaceError(.protocolInvalid, "Send exactly one of assertion or attestation.")
    }
    let api = signInAPI()
    let request = PasskeyFinishRequest(
      ceremonyId: params.ceremonyId, assertion: params.assertion, attestation: params.attestation,
      device: try deviceSpec())
    let session = try await Self.hubCall("sign in") { try await api.passkeyFinish(request) }
    return try await signIn(session: session, hubURL: flavor.hubURL.absoluteString)
  }

  // MARK: - Signing in with Apple (the Mac's web flow)

  /// Make a verifier, begin a web ceremony with its hash and this flavour's scheme, and keep both. A
  /// start replaces a ceremony already in flight.
  public func appleStart() async throws -> AccountAppleStart.Result {
    try requireAppleSignIn()
    let verifier = Self.newVerifier()
    let api = signInAPI()
    let request = AppleBeginRequest(verifierHash: Self.sha256Hex(verifier), scheme: flavor.urlScheme)
    let begun = try await Self.hubCall("begin Sign in with Apple") { try await api.appleBegin(request) }
    appleCeremony = AppleCeremony(id: begun.ceremonyId, verifier: verifier)
    var components = URLComponents(
      url: flavor.hubURL.appendingPathComponent("v1/auth/apple/start"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "ceremony", value: begun.ceremonyId)]
    guard let url = components?.url else {
      throw WorkspaceError(.internalError, "Could not build the Sign in with Apple address.")
    }
    return AccountAppleStart.Result(url: url.absoluteString, callbackScheme: flavor.urlScheme)
  }

  /// Redeem the redirect's handoff with the kept verifier, once, and sign in. With no ceremony in
  /// flight (a stray or repeated `b4app://auth?handoff=`), `ceremony_expired` without asking the hub.
  public func appleFinish(_ params: AccountAppleFinish.Params) async throws -> AccountStatus.Result {
    try requireAppleSignIn()
    guard let ceremony = appleCeremony else {
      throw WorkspaceError(
        .ceremonyExpired, "No Sign in with Apple is in progress on this Mac. Start again.")
    }
    // Single use, whatever the hub answers.
    appleCeremony = nil
    let api = signInAPI()
    let request = HandoffRequest(
      handoff: params.handoff, verifier: ceremony.verifier, device: try deviceSpec())
    let session = try await Self.hubCall("finish Sign in with Apple") { try await api.handoff(request) }
    return try await signIn(session: session, hubURL: flavor.hubURL.absoluteString)
  }

  private func requireAppleSignIn() throws {
    guard flavor.appleSignIn else {
      throw WorkspaceError(
        .unsupportedCapability,
        "Sign in with Apple is not available on the \(flavor.rawValue) flavour; continue with a passkey.")
    }
  }

  // MARK: - The signed-in account

  /// Onboarding's full name: stored at the hub, then the account is `signedIn` with its new names.
  public func completeProfile(_ params: AccountCompleteProfile.Params) async throws -> AccountStatus.Result {
    let scope = try self.scope()
    let name = params.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...200).contains(name.count) else {
      throw WorkspaceError(.protocolInvalid, "The full name must be 1 to 200 characters.")
    }
    let me = try await Self.inScope(scope) {
      try await Self.hubCall("save your name") {
        try await scope.hub.client().setProfile(ProfileRequest(fullName: name))
      }
    }
    await profileArrived(me, instance: scope.instance)
    return status()
  }

  public func identities() async throws -> AccountIdentities.Result {
    let scope = try self.scope()
    let listed = try await Self.inScope(scope) {
      try await Self.hubCall("list your sign-in methods") { try await scope.hub.client().identities() }
    }
    return AccountIdentities.Result(identities: listed.map(Self.identity))
  }

  public func addPasskeyBegin() async throws -> AccountAddPasskeyBegin.Result {
    let scope = try self.scope()
    let begun = try await Self.inScope(scope) {
      try await Self.hubCall("begin adding a passkey") { try await scope.hub.client().addPasskeyBegin() }
    }
    return AccountAddPasskeyBegin.Result(ceremonyId: begun.ceremonyId, registration: begun.registration)
  }

  public func addPasskeyFinish(
    _ params: AccountAddPasskeyFinish.Params
  ) async throws
    -> AccountAddPasskeyFinish.Result
  {
    let scope = try self.scope()
    let request = AddPasskeyFinishRequest(ceremonyId: params.ceremonyId, attestation: params.attestation)
    let added = try await Self.inScope(scope) {
      try await Self.hubCall("add the passkey") { try await scope.hub.client().addPasskeyFinish(request) }
    }
    return AccountAddPasskeyFinish.Result(identity: Self.identity(added))
  }

  /// Unlink one sign-in method, answering the ones left.
  public func removeIdentity(_ params: AccountRemoveIdentity.Params) async throws -> AccountIdentities.Result
  {
    let scope = try self.scope()
    let left = try await Self.inScope(scope) {
      try await Self.hubCall("remove the sign-in method") {
        let api = try await scope.hub.client()
        try await api.removeIdentity(params.identityId)
        return try await api.identities()
      }
    }
    return AccountIdentities.Result(identities: left.map(Self.identity))
  }

  // MARK: - Logging out

  /// Log out, in the spec's four steps, within `logoutTimeouts` (21 s at most by default):
  /// 1. refuse new work, interrupt every running turn and wait for the runtimes, stop the account's
  ///    servers, and let admitted commands finish (`work`);
  /// 2. push the change log once (`push`; drafts are already in it, since `draft.save` writes them);
  /// 3. end the session at the hub, keeping the device (what is left of `push`, at least
  ///    `endSessionFloor`); a hub that cannot be reached leaves it open, which the registry records;
  /// 4. forget the token, close the scope, and publish `account.changed`.
  ///
  /// With work running and `stopWork` false it throws `work_running` (`details.work`, the shape of
  /// `workspace.activeWork`) and changes nothing.
  public func logout(stopWork: Bool) async throws -> AccountStatus.Result {
    await acquire()
    defer { release() }
    guard let scope = slot.get() else { throw WorkspaceError(.signedOut, Self.signedOutMessage) }
    let work = try await scope.sessions.activeWork()
    if !stopWork, !work.turns.isEmpty || !work.servers.isEmpty {
      throw WorkspaceError(
        .workRunning, Self.workRunningMessage(work), details: ["work": try JSONValue(encoding: work)])
    }
    let timeouts = logoutTimeouts
    let id = scope.account.id

    // 1. Nothing new starts; what runs is stopped.
    scope.refuseNewWork()
    let workDeadline = ContinuousClock.now + timeouts.work
    // The turns get up to half of the step, so the servers always have the rest.
    let turnDeadline = ContinuousClock.now + timeouts.work / 2
    let unconfirmed = await Bounded.run(within: timeouts.work / 2) {
      await scope.sessions.interruptAll(until: turnDeadline)
    }
    if (try? unconfirmed?.get())?.isEmpty != true {
      logger.warning("log-out of \(id, privacy: .public): some turns did not confirm they stopped")
    }
    if await !scope.servers.stopAll(within: Bounded.remaining(until: workDeadline)) {
      logger.warning("log-out of \(id, privacy: .public): some servers were still stopping")
    }
    _ = await scope.drain(timeout: Bounded.remaining(until: workDeadline))

    // 2. Push once.
    let pushDeadline = ContinuousClock.now + timeouts.push
    switch await Bounded.run(within: timeouts.push, { try await scope.hub.pushNow() }) {
    case .none:
      logger.warning("log-out of \(id, privacy: .public): the push did not finish in time")
    case .failure(let error):
      logger.warning(
        "log-out of \(id, privacy: .public): the push failed: \(WorkspaceError.from(error).message, privacy: .public)"
      )
    case .success: break
    }

    // 3. End the session at the hub.
    let budget = max(Bounded.remaining(until: pushDeadline), timeouts.endSessionFloor)
    let ended = await Self.endHubSession(of: scope, within: budget)

    // 4. Forget the token and close the account.
    await performSignOut(
      reason: nil, hubSessionLeftOpen: !ended, drainTimeout: .zero, serverBudget: .seconds(1))
    return status()
  }

  /// `DELETE /v1/sessions/self` for `scope`'s account, within `timeout`. Whether the hub ended it (an
  /// account that has joined no hub has no session to end).
  static func endHubSession(of scope: AccountScope, within timeout: Duration) async -> Bool {
    guard await scope.hub.isJoined else { return true }
    switch await Bounded.run(within: timeout, { try await scope.hub.endSession() }) {
    case .success: return true
    case .failure(let error):
      Log.logger("accounts").warning(
        "could not end account \(scope.account.id, privacy: .public)'s hub session: \(WorkspaceError.from(error).message, privacy: .public)"
      )
      return false
    case .none:
      Log.logger("accounts").warning(
        "the hub did not answer ending account \(scope.account.id, privacy: .public)'s session")
      return false
    }
  }

  static func workRunningMessage(_ work: WorkspaceActiveWork.Result) -> String {
    var parts: [String] = []
    if !work.turns.isEmpty { parts.append(work.turns.count == 1 ? "1 turn" : "\(work.turns.count) turns") }
    if !work.servers.isEmpty {
      parts.append(work.servers.count == 1 ? "1 local server" : "\(work.servers.count) local servers")
    }
    return "Still running: \(parts.joined(separator: " and ")). Stop them to log out."
  }

  /// `hub.status`'s one-time notice for `scope`'s account, cleared as it is read.
  /// The scope's row is the registry's as the account signed in, so only an account that has the record
  /// asks the registry; taking it clears the row's copy too.
  func takeNotice(for scope: AccountScope) -> String? {
    var row = scope.account
    guard row.hubSessionLeftOpen, slot.get()?.instance == scope.instance else { return nil }
    guard (try? registry.takeHubSessionLeftOpen(id: row.id)) == true else { return nil }
    row.hubSessionLeftOpen = false
    scope.update(account: row)
    if active?.id == row.id { active = row }
    return Self.sessionLeftOpenNotice
  }

  // MARK: - Deleting the account

  /// `DELETE /v1/me`, then sign out and drop the account's database and registry row. A refusal from
  /// the hub changes nothing here.
  public func deleteAccount() async throws -> AccountStatus.Result {
    await acquire()
    defer { release() }
    guard let scope = slot.get() else { throw WorkspaceError(.signedOut, Self.signedOutMessage) }
    try await Self.hubCall("delete the account") { try await scope.hub.client().deleteAccount() }
    let row = scope.account
    // The hub has already ended every session of the account.
    await performSignOut(reason: nil, publishing: false)
    do {
      try WorkspaceDatabase.drop(endpoint: cluster.endpoint(database: row.database), binDir: cluster.binDir)
    } catch {
      logger.error(
        "could not drop deleted account \(row.id, privacy: .public)'s database: \(WorkspaceError.from(error).message, privacy: .public)"
      )
    }
    do {
      try registry.remove(id: row.id)
    } catch {
      logger.error("could not remove deleted account \(row.id, privacy: .public) from the registry")
    }
    logger.notice("deleted account \(row.id, privacy: .public)")
    await publish()
    return status()
  }

  // MARK: - Helpers

  /// A client for the flavour's hub with no token: the sign-in calls carry none.
  private func signInAPI() -> any HubAPI {
    scopeContext.makeAPI(flavor.hubURL, { nil })
  }

  /// This Mac, as a sign-in describes it: the device it has with every account it knows on this hub,
  /// most recently signed in first, so the hub reuses the one that is the signing-in user's. The first
  /// goes as `deviceId`, which a hub older than `candidateDeviceIds` understands; the rest (at most 31
  /// more) as candidates, left out when there are none.
  private func deviceSpec() throws -> DeviceSpec {
    let base = flavor.hubURL.absoluteString
    var known: [String] = []
    for row in try registry.all().filter({ $0.hubURL == base })
      .sorted(by: { ($0.lastSignedInAt ?? "") > ($1.lastSignedInAt ?? "") })
    where UUID(uuidString: row.deviceId) != nil && !known.contains(row.deviceId) {
      known.append(row.deviceId)
    }
    known = Array(known.prefix(DeviceSpec.maxCandidates + 1))
    let rest = Array(known.dropFirst())
    return DeviceSpec(
      deviceName: HubSync.defaultDeviceName(), platform: "macos", deviceId: known.first,
      candidateDeviceIds: rest.isEmpty ? nil : rest)
  }

  /// Run `body` admitted to `scope` (so a closing scope refuses it and a log-out waits for it).
  private static func inScope<T: Sendable>(
    _ scope: AccountScope, _ body: () async throws -> T
  ) async throws -> T {
    try scope.enter()
    defer { scope.leave() }
    return try await body()
  }

  /// A hub refusal as the error a client shows: the hub's own code when it is one the protocol knows
  /// for signing in and the account, otherwise `HubSync`'s mapping. No request body is in it.
  static func hubCall<T: Sendable>(_ action: String, _ body: () async throws -> T) async throws -> T {
    do {
      return try await body()
    } catch let error as HubError {
      throw accountError(error, doing: action)
    }
  }

  static func accountError(_ error: HubError, doing action: String) -> WorkspaceError {
    let known: Set<ErrorCode> = [
      .signupClosed, .ceremonyExpired, .credentialRejected, .lastIdentity, .mergeRefused, .appleLinked,
      .sharedOrg, .rateLimited, .notFound,
    ]
    guard let code = ErrorCode(rawValue: error.code), known.contains(code) else {
      return HubSync.workspaceError(error, doing: action)
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

  /// 64 characters of the URL-safe alphabet (RFC 7636's unreserved set) from 48 random bytes.
  static func newVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 48)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
      var generator = SystemRandomNumberGenerator()
      bytes = (0..<48).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
