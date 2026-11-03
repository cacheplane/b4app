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
/// in an error. A change that needs a step-up (D-150) brings its assertion or handoff in its own
/// params; the coordinator finishes the step-up and makes the change in the same command, so the grant
/// the hub answers never leaves it.
extension AccountManager {
  /// Log-out's bounds: the spec's two steps of about 10 s, a short last word for the hub session, and
  /// the close, all inside 21 s.
  public struct LogoutTimeouts: Sendable, Equatable {
    /// Step 1, from the moment the log-out arrives (a wait for another transition comes out of it):
    /// interrupt the local turns, stop the servers and the runtimes, and let admitted commands finish.
    public var work: Duration
    /// Step 2: push the change log once. Step 3 (ending the hub session) gets what is left of it.
    public var push: Duration
    /// Step 3's least time, when the push used all of its own.
    public var endSessionFloor: Duration
    /// Step 4: close the scope, after the token is forgotten; what is left goes on in the background.
    public var close: Duration
    /// The longest a log-out waits for another sign-in or sign-out to finish before answering
    /// `endpoint_unavailable` (inside `work`).
    public var lockWait: Duration

    public init(
      work: Duration, push: Duration, endSessionFloor: Duration, close: Duration,
      lockWait: Duration = .seconds(3)
    ) {
      self.work = work
      self.push = push
      self.endSessionFloor = endSessionFloor
      self.close = close
      self.lockWait = lockWait
    }

    /// The most a log-out can take.
    public var total: Duration { work + push + endSessionFloor + close }

    /// 9.5 + 9.5 + 0.5 + 1.5 s: a log-out returns within 21 s whatever the hub and the runtimes do.
    public static let standard = LogoutTimeouts(
      work: .milliseconds(9500), push: .milliseconds(9500), endSessionFloor: .milliseconds(500),
      close: .milliseconds(1500))
  }

  /// What step 1 keeps for stopping the servers and the runtimes when the turns take their longest:
  /// 3 s (enough for `stopAll`'s SIGTERM-then-SIGKILL), or a third of a shorter step.
  static func stopReserve(_ work: Duration) -> Duration { min(.seconds(3), work / 3) }
  /// How long a deletion waits for the hub's answer; without one nothing changes here.
  static let deleteWait: Duration = .seconds(15)

  /// A Sign in with Apple web ceremony: the hub's id and the verifier whose SHA-256 the hub holds.
  struct AppleCeremony: Sendable {
    var id: String
    var verifier: String
  }

  /// What `account.status` and `hub.status` say, until dismissed, after a log-out that could not reach
  /// the hub.
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
  ///
  /// Starts run one at a time, so the ceremony kept is always the one in the last answer given (two
  /// racing starts would otherwise keep whichever hub answer came back last).
  public func appleStart() async throws -> AccountAppleStart.Result {
    try requireAppleSignIn()
    await appleStarts.lock()
    defer { appleStarts.unlock() }
    let verifier = Self.newVerifier()
    let api = signInAPI()
    let request = AppleBeginRequest(
      verifierHash: Self.sha256Hex(verifier), scheme: flavor.urlScheme, httpsCallback: true)
    let begun = try await Self.hubCall("begin Sign in with Apple") { try await api.appleBegin(request) }
    let url = try appleStartURL(ceremony: begun.ceremonyId)
    let callback = try appleCallback(begun.callback)
    appleCeremony = AppleCeremony(id: begun.ceremonyId, verifier: verifier)
    return AccountAppleStart.Result(url: url.absoluteString, callback: callback)
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

  // MARK: - Connecting an Apple ID (the Mac's web flow, Task 14)

  /// A link's web ceremony: the hub's id, the verifier, and the account that began it.
  struct AppleLinkCeremony: Sendable {
    var id: String
    var verifier: String
    var accountId: String
  }

  /// Begin linking an Apple ID to the signed-in account (`POST /v1/me/apple` with a fresh verifier's
  /// hash, this flavour's scheme, and the step-up `params` carries), keep the verifier, and answer
  /// the start URL. A start replaces a link already in flight. `apple_linked` when the account has one.
  public func appleLinkStart(
    _ params: AccountAppleLinkStart.Params = AccountStepUpParams()
  ) async throws -> AccountAppleLinkStart.Result {
    try requireAppleSignIn()
    let scope = try self.scope()
    await appleStarts.lock()
    defer { appleStarts.unlock() }
    let verifier = Self.newVerifier()
    let request = AppleBeginRequest(
      verifierHash: Self.sha256Hex(verifier), scheme: flavor.urlScheme, httpsCallback: true)
    let begun = try await Self.inScope(scope) {
      let grant = try await stepUpGrant(params.stepUp, in: scope)
      return try await Self.hubCall("begin connecting an Apple ID") {
        try await scope.hub.client().appleLinkBegin(request, stepUp: grant)
      }
    }
    let url = try appleStartURL(ceremony: begun.ceremonyId)
    let callback = try appleCallback(begun.callback)
    appleLinkCeremony = AppleLinkCeremony(
      id: begun.ceremonyId, verifier: verifier, accountId: scope.account.id)
    return AccountAppleLinkStart.Result(url: url.absoluteString, callback: callback)
  }

  /// Redeem a link's handoff with the kept verifier, once, for the account that began it. With no link
  /// in flight for the signed-in account (a stray or repeated callback), `ceremony_expired` without
  /// asking the hub.
  public func appleLinkFinish(
    _ params: AccountAppleLinkFinish.Params
  ) async throws -> AccountAppleLinkFinish.Result {
    try requireAppleSignIn()
    let scope = try self.scope()
    let ceremony = appleLinkCeremony
    // Single use, whatever the hub answers.
    appleLinkCeremony = nil
    guard let ceremony, ceremony.accountId == scope.account.id else {
      throw WorkspaceError(
        .ceremonyExpired, "No Apple ID is being connected on this Mac. Start again from Settings.")
    }
    let request = AppleLinkHandoffRequest(handoff: params.handoff, verifier: ceremony.verifier)
    let added = try await Self.inScope(scope) {
      try await Self.hubCall("connect the Apple ID") {
        try await scope.hub.client().appleLinkHandoff(request)
      }
    }
    return AccountAppleLinkFinish.Result(identity: Self.identity(added))
  }

  // MARK: - Step-up (D-150)

  /// Begin confirming with a passkey: options for the account's own passkeys.
  public func stepUpBegin() async throws -> AccountStepUpBegin.Result {
    let scope = try self.scope()
    let begun = try await Self.inScope(scope) {
      try await Self.hubCall("begin confirming it's you") {
        try await scope.hub.client().stepUpPasskeyBegin()
      }
    }
    return AccountStepUpBegin.Result(ceremonyId: begun.ceremonyId, authentication: begun.authentication)
  }

  /// Begin confirming with the account's Apple ID on the web: a fresh verifier's hash and this
  /// flavour's scheme to `POST /v1/me/step-up/apple`, the verifier kept for the change that brings the
  /// handoff. A start replaces a step-up already in flight.
  public func stepUpAppleStart() async throws -> AccountStepUpAppleStart.Result {
    try requireAppleSignIn()
    let scope = try self.scope()
    await appleStarts.lock()
    defer { appleStarts.unlock() }
    let verifier = Self.newVerifier()
    let request = AppleBeginRequest(
      verifierHash: Self.sha256Hex(verifier), scheme: flavor.urlScheme, httpsCallback: true)
    let begun = try await Self.inScope(scope) {
      try await Self.hubCall("begin confirming it's you") {
        try await scope.hub.client().stepUpAppleBegin(request)
      }
    }
    let url = try appleStartURL(ceremony: begun.ceremonyId)
    let callback = try appleCallback(begun.callback)
    stepUpAppleCeremony = AppleLinkCeremony(
      id: begun.ceremonyId, verifier: verifier, accountId: scope.account.id)
    return AccountStepUpAppleStart.Result(url: url.absoluteString, callback: callback)
  }

  /// The grant `proof` earns for `scope`'s account (`nil` for no proof: an account with no sign-in
  /// method needs none, and the hub refuses any other with `step_up_required`). A passkey assertion
  /// goes to the hub once; an Apple handoff is redeemed with the verifier `account.stepUpAppleStart`
  /// kept, which is used up whatever the hub answers. The grant is answered only to the caller, which
  /// sends it with the change at once.
  func stepUpGrant(_ proof: AccountStepUp?, in scope: AccountScope) async throws -> String? {
    guard let proof else { return nil }
    if let ceremonyId = proof.ceremonyId, let assertion = proof.assertion, proof.handoff == nil {
      let request = StepUpFinishRequest(ceremonyId: ceremonyId, assertion: assertion)
      return try await Self.hubCall("confirm it's you") {
        try await scope.hub.client().stepUpPasskeyFinish(request)
      }.stepUp
    }
    if let handoff = proof.handoff, proof.assertion == nil, proof.ceremonyId == nil {
      let ceremony = stepUpAppleCeremony
      // Single use, whatever the hub answers.
      stepUpAppleCeremony = nil
      guard let ceremony, ceremony.accountId == scope.account.id else {
        throw WorkspaceError(
          .ceremonyExpired, "No Apple confirmation is in progress on this Mac. Start again.")
      }
      let request = AppleLinkHandoffRequest(handoff: handoff, verifier: ceremony.verifier)
      return try await Self.hubCall("confirm it's you") {
        try await scope.hub.client().stepUpAppleHandoff(request)
      }.stepUp
    }
    throw WorkspaceError(
      .protocolInvalid, "Confirm with a passkey assertion and its ceremony, or an Apple handoff.")
  }

  /// Where the web flow's result comes back (D-160): the hub's `callback`, taken only as this flavour's
  /// `<scheme>://auth` or an https URL with a path on its site domain, so no answer can point the
  /// session anywhere else. A hub older than D-160 names none, which means the scheme.
  func appleCallback(_ named: String?) throws -> String {
    let scheme = "\(flavor.urlScheme)://auth"
    guard let named, named != scheme else { return scheme }
    if let url = URL(string: named), url.scheme == "https", url.host()?.lowercased() == flavor.siteDomain,
      url.port == nil, url.user() == nil, url.query() == nil, url.fragment() == nil,
      url.path().count > 1
    {
      return named
    }
    throw WorkspaceError(
      .protocolInvalid, "The hub named a place to finish Sign in with Apple that this app does not use.")
  }

  /// `<hub>/v1/auth/apple/start?ceremony=<id>`, which the browser session opens.
  private func appleStartURL(ceremony: String) throws -> URL {
    var components = URLComponents(
      url: flavor.hubURL.appendingPathComponent("v1/auth/apple/start"), resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "ceremony", value: ceremony)]
    guard let url = components?.url else {
      throw WorkspaceError(.internalError, "Could not build the Sign in with Apple address.")
    }
    return url
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

  /// Finish the step-up `params` carries and begin adding a passkey with its grant.
  public func addPasskeyBegin(
    _ params: AccountAddPasskeyBegin.Params = AccountStepUpParams()
  ) async throws -> AccountAddPasskeyBegin.Result {
    let scope = try self.scope()
    let begun = try await Self.inScope(scope) {
      let grant = try await stepUpGrant(params.stepUp, in: scope)
      return try await Self.hubCall("begin adding a passkey") {
        try await scope.hub.client().addPasskeyBegin(stepUp: grant)
      }
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

  /// Finish the step-up `params` carries and unlink one sign-in method with its grant, answering the
  /// ones left.
  public func removeIdentity(_ params: AccountRemoveIdentity.Params) async throws -> AccountIdentities.Result
  {
    let scope = try self.scope()
    let left = try await Self.inScope(scope) {
      let grant = try await stepUpGrant(params.stepUp, in: scope)
      return try await Self.hubCall("remove the sign-in method") {
        let api = try await scope.hub.client()
        try await api.removeIdentity(params.identityId, stepUp: grant)
        return try await api.identities()
      }
    }
    return AccountIdentities.Result(identities: left.map(Self.identity))
  }

  // MARK: - Logging out

  /// Log out, in the spec's four steps, within `logoutTimeouts` (21 s at most by default, counted from
  /// the moment the request arrives):
  /// 1. refuse new work, then decide; interrupt every running turn of a local runtime and wait for the
  ///    runtimes to confirm, then stop the account's servers and dispose its runtimes side by side, and
  ///    let admitted commands finish (`work`). Remote and attached B4 runs are detached, never cancelled;
  /// 2. push the change log once (`push`; drafts are already in it, since `draft.save` writes them);
  /// 3. end the session at the hub, keeping the device (what is left of `push`, at least
  ///    `endSessionFloor`); a hub that cannot be reached leaves it open, which the registry records;
  /// 4. forget the token and write the registry row, then close the scope (`close`; the rest of the
  ///    close goes on in the background), and publish `account.changed`.
  ///
  /// With work running (remote runs included, as `local: false`) and `stopWork` false it throws
  /// `work_running` (`details.work`, the shape of `workspace.activeWork`) and changes nothing.
  public func logout(stopWork: Bool) async throws -> AccountStatus.Result {
    let timeouts = logoutTimeouts
    let started = ContinuousClock.now
    try await acquire(within: timeouts.lockWait)
    defer { release() }
    guard let scope = slot.get() else { throw WorkspaceError(.signedOut, Self.signedOutMessage) }
    let id = scope.account.id

    // Nothing new starts while this decides, so a turn cannot slip in between the check and the stop.
    scope.refuseNewWork()
    let work: WorkspaceActiveWork.Result
    do {
      work = try await scope.sessions.activeWork()
    } catch {
      scope.admitWorkAgain()
      throw error
    }
    if !stopWork, !work.turns.isEmpty || !work.servers.isEmpty {
      scope.admitWorkAgain()
      throw WorkspaceError(
        .workRunning, Self.workRunningMessage(work), details: ["work": try JSONValue(encoding: work)])
    }

    // 1. Stop what runs. The turns may take the whole step but for a reserve for stopping the servers
    // and the runtimes.
    let workDeadline = started + timeouts.work
    let turnDeadline = workDeadline - Self.stopReserve(timeouts.work)
    let unconfirmed = await Bounded.run(within: Bounded.remaining(until: turnDeadline)) {
      await scope.sessions.interruptLocalTurns(until: turnDeadline)
    }
    if (try? unconfirmed?.get())?.isEmpty != true {
      logger.warning("log-out of \(id, privacy: .public): some turns did not confirm they stopped")
    }
    let stopped = await Bounded.run(within: Bounded.remaining(until: workDeadline)) {
      async let servers = scope.servers.stopAll(within: Bounded.remaining(until: workDeadline))
      async let runtimes: Void = scope.sessions.shutdown()
      let (serversStopped, _) = await (servers, runtimes)
      return serversStopped
    }
    let serversStopped = (try? stopped?.get()) == true
    if !serversStopped {
      logger.warning("log-out of \(id, privacy: .public): servers or runtimes were still stopping")
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

    // 4. Forget the token and close the account, the close bounded.
    await performSignOut(
      reason: nil, hubSessionLeftOpen: !ended, drainTimeout: .zero, serverBudget: .seconds(1),
      stoppingServers: !serversStopped, closeBudget: timeouts.close)
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
    var message = "Still running: \(parts.joined(separator: " and ")). Stop them to log out."
    let elsewhere = work.remoteTurns.count
    if elsewhere > 0 {
      message +=
        elsewhere == 1
        ? " 1 turn runs on another server and continues there."
        : " \(elsewhere) turns run on other servers and continue there."
    }
    return message
  }

  // MARK: - The notice

  /// The signed-in account's notice for `hub.status` (the same as `account.status`'s). Reading it never
  /// clears it.
  func notice(for scope: AccountScope) -> String? {
    guard slot.get()?.instance == scope.instance, active?.hubSessionLeftOpen == true else { return nil }
    return Self.sessionLeftOpenNotice
  }

  /// `account.dismissNotice`: the person has seen the notice; clear it here and in the registry.
  public func dismissNotice() async throws -> AccountStatus.Result {
    let scope = try self.scope()
    guard var row = active, row.id == scope.account.id else {
      throw WorkspaceError(.signedOut, Self.signedOutMessage)
    }
    guard row.hubSessionLeftOpen else { return status() }
    try registry.clearHubSessionLeftOpen(id: row.id)
    row.hubSessionLeftOpen = false
    active = row
    var scoped = scope.account
    scoped.hubSessionLeftOpen = false
    scope.update(account: scoped)
    await publish()
    return status()
  }

  // MARK: - Deleting the account

  /// Finish the step-up `params` carries, then `DELETE /v1/me` with its grant (both waiting at most
  /// `deleteWait`), then sign out and drop the account's database, and only once it is gone the
  /// registry row. A refusal from the hub, or no answer, changes nothing here. A drop that fails keeps
  /// the (signed-out) row, so the database is not lost track of, and reports it.
  public func deleteAccount(
    _ params: AccountDelete.Params = AccountStepUpParams()
  ) async throws
    -> AccountStatus.Result
  {
    try await acquire(within: logoutTimeouts.lockWait)
    defer { release() }
    guard let scope = slot.get() else { throw WorkspaceError(.signedOut, Self.signedOutMessage) }
    let answer = await Bounded.run(within: Self.deleteWait) {
      let grant = try await self.stepUpGrant(params.stepUp, in: scope)
      return try await Self.hubCall("delete the account") {
        try await scope.hub.client().deleteAccount(stepUp: grant)
      }
    }
    switch answer {
    case .none:
      throw WorkspaceError(
        .endpointUnavailable,
        "The hub did not answer the deletion in time. Nothing was removed from this Mac; try again.")
    case .failure(let error): throw error
    case .success: break
    }
    let row = scope.account
    // The hub has already ended every session of the account.
    await performSignOut(reason: nil, closeBudget: Self.switchCloseBudget, publishing: false)
    do {
      try WorkspaceDatabase.drop(endpoint: cluster.endpoint(database: row.database), binDir: cluster.binDir)
    } catch {
      let message = WorkspaceError.from(error).message
      logger.error(
        "could not drop deleted account \(row.id, privacy: .public)'s database: \(message, privacy: .public)"
      )
      await publish()
      throw WorkspaceError(
        .internalError,
        "The account was deleted at the hub, but its data on this Mac could not be removed: \(message)",
        details: ["database": .string(row.database)])
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

  /// This Mac, as a sign-in (or `hub join`, at the hub it joins) describes it: the device it has with
  /// every account it knows on that hub, most recently signed in first, so the hub reuses the one that
  /// is the signing-in user's. The first goes as `deviceId`, which a hub older than
  /// `candidateDeviceIds` understands; the rest (at most 32 more) as candidates, left out when there
  /// are none. The hub is the flavour's unless `hubURL` names another.
  func deviceSpec(hubURL: URL? = nil, deviceName: String? = nil) throws -> DeviceSpec {
    let base = (hubURL ?? flavor.hubURL).absoluteString
    var known: [String] = []
    for row in try registry.all().filter({ Self.sameHub($0.hubURL, base) })
      .sorted(by: { ($0.lastSignedInAt ?? "") > ($1.lastSignedInAt ?? "") })
    where UUID(uuidString: row.deviceId) != nil && !known.contains(row.deviceId) {
      known.append(row.deviceId)
    }
    known = Array(known.prefix(DeviceSpec.maxCandidates + 1))
    let rest = Array(known.dropFirst())
    return DeviceSpec(
      deviceName: deviceName ?? HubSync.defaultDeviceName(), platform: "macos", deviceId: known.first,
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
      .sharedOrg, .rateLimited, .notFound, .stepUpRequired,
    ]
    guard let code = ErrorCode(rawValue: error.code), known.contains(code) else {
      return HubSync.workspaceError(error, doing: action)
    }
    var details: [String: JSONValue] = ["hubCode": .string(error.code)]
    if let wait = error.retryAfterMs { details["retryAfterMs"] = .number(Double(wait)) }
    if let methods = error.methods { details["methods"] = .array(methods.map { .string($0) }) }
    // The hub's reason names no secret (`unknown_credential`, a merge refusal's).
    if let reason = error.reason { details["reason"] = .string(reason) }
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
