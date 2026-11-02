import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// Who this device is signed in as, as the root view needs it (sign-in plan, Task 11). The Mac's
/// model reads `account.status` when it connects and follows `account.changed`; the phone's host
/// supplies the account itself (`AccountSource.host`).
public enum AccountState: Sendable, Equatable {
  /// Not asked yet, or not answered: the root shows neither the sign-in screen nor the workspace, so a
  /// restart never flashes one of them.
  case unknown
  /// Nobody is signed in. `reason` is the line the sign-in screen shows, when the hub signed this Mac
  /// out ("This Mac was signed out of <org name>.").
  case signedOut(reason: String?)
  /// Signed up, not named yet. `prefillName` is Apple's name when Apple gave one.
  case needsOnboarding(prefillName: String?)
  case signedIn

  init(_ status: AccountStatus.Result) {
    switch status.state {
    case .signedOut:
      self = .signedOut(reason: status.reason.map { SignInCopy.signedOut(of: $0.orgName) })
    case .needsOnboarding:
      let name = status.account?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      self = .needsOnboarding(prefillName: name.isEmpty ? nil : name)
    case .signedIn:
      self = .signedIn
    }
  }
}

/// What the root view shows.
public enum RootScreen: Sendable, Equatable {
  /// A blank themed window while the account is not known yet.
  case loading
  case signIn
  case onboarding
  case workspace
}

/// What the sign-in screen needs from the app's flavour (`Flavor` in `WorkspacePlatform`, which
/// `WorkspaceUI` does not link). The app sets it on the model; the default is the local flavour's.
public struct SignInConfiguration: Sendable, Equatable {
  /// `b4.run`, `test.b4.run`, or `local.b4.run`: the relying party, and the site the links open.
  public var siteDomain: String
  /// False on the local flavour, which hides Continue with Apple.
  public var appleSignIn: Bool
  /// "Test hub" or "Local hub"; nil for prod.
  public var badge: String?

  public init(siteDomain: String, appleSignIn: Bool, badge: String?) {
    self.siteDomain = siteDomain
    self.appleSignIn = appleSignIn
    self.badge = badge
  }

  public static let local = SignInConfiguration(
    siteDomain: "local.b4.run", appleSignIn: false, badge: "Local hub")

  public var termsURL: URL { URL(string: "https://\(siteDomain)/app/terms")! }
  public var privacyURL: URL { URL(string: "https://\(siteDomain)/app/privacy")! }
}

public enum SignInMethod: Sendable, Equatable {
  case apple, passkey
}

/// Where a sign-in stands on the screen: which button is busy, the one failure line, and the
/// "Create a new account?" question. It never holds a credential, a handoff, or a hub message.
public struct SignInProgress: Sendable, Equatable {
  public var inFlight: SignInMethod?
  public var failure: String?
  public var confirmation: String?

  public init(inFlight: SignInMethod? = nil, failure: String? = nil, confirmation: String? = nil) {
    self.inFlight = inFlight
    self.failure = failure
    self.confirmation = confirmation
  }
}

/// How `logOut(stopWork:)` ended.
public enum LogOutOutcome: Sendable, Equatable {
  case loggedOut
  /// Refused: work is running and `stopWork` was false. Nothing changed.
  case workRunning(WorkspaceActiveWork.Result)
  /// Refused for another reason, in a line the view can show.
  case failed(String)
}

/// Onboarding's rule for the full name: 1 to 200 characters once trimmed (the coordinator checks the
/// same before calling the hub).
public enum FullName {
  public static let maximumLength = 200

  public static func trimmed(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func isValid(_ name: String) -> Bool {
    let count = trimmed(name).count
    return count >= 1 && count <= maximumLength
  }
}

/// The sign-in and onboarding copy, verbatim from the plan's global constraints.
public enum SignInCopy {
  public static let title = "Agent Workspace"
  public static let intro = "Your Codex, Claude, and B4 threads, on your Mac and your phone."
  public static let apple = "Continue with Apple"
  public static let passkey = "Continue with a passkey"
  public static let signingIn = "Signing in…"
  public static let newHere = "New here? Either one creates your account."
  public static let terms = "By continuing you agree to the terms and privacy policy."
  public static let createAccount = "Create account"
  public static let cancel = "Cancel"
  public static let welcome = "Welcome"
  public static let askName = "What should we call you?"
  public static let fullName = "Full name"
  public static let `continue` = "Continue"
  public static let notYou = "Not you? Log out"

  public static func noPasskey(siteDomain: String) -> String {
    "No passkey for \(siteDomain) on this device. Create a new account?"
  }

  public static func signedOut(of orgName: String) -> String { "This Mac was signed out of \(orgName)." }

  /// One short line for a failed sign-in. Never the code or the hub's own text, which can carry
  /// detail meant for logs.
  public static func failure(for error: WorkspaceError) -> String {
    switch error.code {
    case .signupClosed: return "This hub isn't taking new accounts. Sign in with an account you already have."
    case .credentialRejected: return "That sign-in wasn't accepted. Try again."
    case .rateLimited: return "Too many tries. Wait a minute and try again."
    case .ceremonyExpired: return "That took too long. Try again."
    case .endpointUnavailable: return "Can't reach the hub. Check your connection and try again."
    default: return "Couldn't sign in. Try again."
    }
  }

  /// A failed onboarding or log-out, in the same style.
  static func accountFailure(for error: WorkspaceError) -> String {
    switch error.code {
    case .endpointUnavailable: return "Can't reach the hub. Check your connection and try again."
    case .rateLimited: return "Too many tries. Wait a minute and try again."
    default: return "That didn't work. Try again."
    }
  }
}

/// Raised by a ceremony when the person closes the sheet; the model shows nothing for it.
public struct SignInCanceled: Error, Sendable, Equatable {
  public init() {}
}

/// A registration offered after "No passkey for … Create a new account?", kept until the answer.
/// It holds the hub's options (no secret) and the ceremony that asked, never a credential.
struct PendingRegistration {
  var ceremonyId: String
  var registration: JSONValue
  var begunAt: Date
  var ceremony: any PasskeyCeremony
}

// MARK: - The model

extension WorkspaceModel {
  /// A hub ceremony lives 5 minutes; a registration begun longer ago than this begins again first.
  static let ceremonyLifetime: TimeInterval = 5 * 60 - 15

  /// What the root view shows. A coordinator that cannot be reached shows the existing
  /// coordinator-unavailable state (the workspace and its notice), not the sign-in screen.
  public var rootScreen: RootScreen {
    if accountSource == .host { return .workspace }
    switch accountState {
    case .signedIn:
      return .workspace
    case .unknown:
      return link == .unavailable ? .workspace : .loading
    case .signedOut:
      return link == .unavailable ? .workspace : .signIn
    case .needsOnboarding:
      return link == .unavailable ? .workspace : .onboarding
    }
  }

  /// Ask the coordinator who is signed in. A transport without accounts (the phone's mirror, an older
  /// coordinator) answers unsupported: its workspace shows as before. Other failures throw.
  func readAccountState(_ client: WorkspaceClient) async throws {
    guard accountSource == .coordinator else { return }
    do {
      applyAccountStatus(try await client.request(AccountStatus.self, EmptyParams()), loadStore: false)
    } catch let error as WorkspaceError
      where error.code == .unsupportedCapability || error.code == .methodUnknown
    {
      accountState = .signedIn
    }
  }

  /// Take a status from `account.status`, `account.changed`, or a sign-in command's answer. Signing in
  /// (or switching accounts) reads the new store; signing out forgets the old one's rows on screen.
  func applyAccountStatus(_ status: AccountStatus.Result, loadStore: Bool = true) {
    let wasSignedIn = accountState == .signedIn
    let previousId = accountStatus?.account?.id
    accountStatus = status
    accountState = AccountState(status)
    accountNotice = status.state == .signedOut ? nil : status.notice
    if status.state != .signedOut {
      // Signed in elsewhere (the CLI, another window) while the screen was asking: nothing is pending.
      pendingRegistration = nil
      signInProgress = SignInProgress()
    }
    if status.state != .signedIn {
      if wasSignedIn || status.state == .signedOut { forgetWorkspace() }
      return
    }
    if loadStore, !wasSignedIn || previousId != status.account?.id {
      Task {
        try? await refreshSnapshot()
        await refreshAccount()
      }
    }
  }

  private func signInClient() throws -> WorkspaceClient {
    guard let client else { throw WorkspaceError(.endpointUnavailable, "Coordinator is not connected.") }
    return client
  }

  /// The hub's answer can take a while (the coordinator signs in and opens the account's store).
  private static let signInCall = RequestOptions(timeout: .seconds(60))

  private static func signInMutation() -> RequestOptions {
    RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: .seconds(60))
  }

  private func signInFailed(_ error: any Error) {
    if error is SignInCanceled || error is CancellationError {
      signInProgress = SignInProgress()
      return
    }
    signInProgress = SignInProgress(failure: SignInCopy.failure(for: WorkspaceError.from(error)))
  }

  // MARK: Passkeys

  /// Continue with a passkey: one button signs in or, after asking, signs up. The assertion and the
  /// attestation go to the coordinator once and are not kept.
  public func signInWithPasskey(using ceremony: any PasskeyCeremony) async {
    guard signInProgress.inFlight == nil else { return }
    pendingRegistration = nil
    signInProgress = SignInProgress(inFlight: .passkey)
    do {
      let client = try signInClient()
      let begun = try await client.request(AccountPasskeyBegin.self, EmptyParams(), options: Self.signInCall)
      guard let assertion = try await ceremony.assert(begun.authentication) else {
        // No passkey for this site on this device. Ask before making a second, empty account.
        guard let registration = begun.registration else {
          throw WorkspaceError(.signupClosed, "Sign-up is closed.")
        }
        pendingRegistration = PendingRegistration(
          ceremonyId: begun.ceremonyId, registration: registration, begunAt: now(), ceremony: ceremony)
        signInProgress = SignInProgress(
          confirmation: SignInCopy.noPasskey(siteDomain: signInConfiguration.siteDomain))
        return
      }
      let status = try await client.request(
        AccountPasskeyFinish.self,
        AccountPasskeyFinish.Params(ceremonyId: begun.ceremonyId, assertion: assertion),
        options: Self.signInMutation())
      signInProgress = SignInProgress()
      applyAccountStatus(status)
    } catch {
      signInFailed(error)
    }
  }

  /// "Create account": register a new passkey with the ceremony that found none, beginning again
  /// when the first ceremony has expired.
  public func confirmCreateAccount() async {
    guard let pending = pendingRegistration, signInProgress.inFlight == nil else { return }
    pendingRegistration = nil
    signInProgress = SignInProgress(inFlight: .passkey)
    do {
      let client = try signInClient()
      var ceremonyId = pending.ceremonyId
      var registration = pending.registration
      if now().timeIntervalSince(pending.begunAt) >= Self.ceremonyLifetime {
        let begun = try await client.request(
          AccountPasskeyBegin.self, EmptyParams(), options: Self.signInCall)
        guard let fresh = begun.registration else {
          throw WorkspaceError(.signupClosed, "Sign-up is closed.")
        }
        ceremonyId = begun.ceremonyId
        registration = fresh
      }
      let attestation = try await pending.ceremony.register(registration)
      let status = try await client.request(
        AccountPasskeyFinish.self,
        AccountPasskeyFinish.Params(ceremonyId: ceremonyId, attestation: attestation),
        options: Self.signInMutation())
      signInProgress = SignInProgress()
      applyAccountStatus(status)
    } catch {
      signInFailed(error)
    }
  }

  /// "Cancel" on the question: back to the two buttons.
  public func cancelCreateAccount() {
    pendingRegistration = nil
    signInProgress = SignInProgress()
  }

  // MARK: Apple on the Mac

  /// Continue with Apple (the Mac's web flow): the coordinator starts the ceremony, the session shows
  /// Apple's page, and the redirect's one-time handoff goes back to the coordinator, which keeps the
  /// verifier. A cancelled sheet shows nothing; the next tap starts a new ceremony.
  public func signInWithApple(using session: any AppleWebSignIn) async {
    guard signInProgress.inFlight == nil else { return }
    pendingRegistration = nil
    signInProgress = SignInProgress(inFlight: .apple)
    do {
      let client = try signInClient()
      let start = try await client.request(AccountAppleStart.self, EmptyParams(), options: Self.signInCall)
      guard let url = URL(string: start.url) else {
        throw WorkspaceError(.protocolInvalid, "The sign-in address is not a URL.")
      }
      let callback = try await session.authenticate(url: url, callbackScheme: start.callbackScheme)
      let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard let handoff = query.first(where: { $0.name == "handoff" })?.value, !handoff.isEmpty else {
        let code = query.first { $0.name == "error" }?.value.flatMap(ErrorCode.init(rawValue:))
        throw WorkspaceError(code ?? .credentialRejected, "Apple's sign-in did not finish.")
      }
      let status = try await client.request(
        AccountAppleFinish.self, AccountAppleFinish.Params(handoff: handoff), options: Self.signInMutation())
      signInProgress = SignInProgress()
      applyAccountStatus(status)
    } catch {
      signInFailed(error)
    }
  }

  // MARK: Onboarding

  /// Continue on onboarding: names the account (1 to 200 characters once trimmed). A name outside
  /// that is never sent.
  public func completeProfile(fullName: String) async {
    guard FullName.isValid(fullName), !onboardingBusy else { return }
    onboardingBusy = true
    defer { onboardingBusy = false }
    onboardingFailure = nil
    do {
      let status = try await signInClient().request(
        AccountCompleteProfile.self, AccountCompleteProfile.Params(fullName: FullName.trimmed(fullName)),
        options: Self.signInMutation())
      applyAccountStatus(status)
    } catch {
      onboardingFailure = SignInCopy.accountFailure(for: WorkspaceError.from(error))
    }
  }

  // MARK: Log out

  /// Log out of the signed-in account. The pending draft is saved first (the coordinator buffers none).
  /// The command goes on a connection of its own when the app gives one (`sideTransportProvider`): one
  /// connection's commands are answered in order, so a log-out behind a slow `server.start` would
  /// wait for it. The state follows the answer, or `account.changed`.
  public func logOut(stopWork: Bool) async -> LogOutOutcome {
    await persistDraftNow()
    do {
      let params = AccountLogout.Params(stopWork: stopWork)
      // The coordinator bounds a log-out at 21 s; this waits a little longer for its answer.
      let options = RequestOptions(operationId: UUID().uuidString.lowercased(), timeout: .seconds(40))
      let status: AccountStatus.Result
      if let side = sideTransportProvider {
        let sideClient = WorkspaceClient(transport: try await side())
        defer { Task { await sideClient.close() } }
        _ = try await sideClient.ready()
        status = try await sideClient.request(AccountLogout.self, params, options: options)
      } else {
        status = try await signInClient().request(AccountLogout.self, params, options: options)
      }
      applyAccountStatus(status)
      return .loggedOut
    } catch {
      let failure = WorkspaceError.from(error)
      if failure.code == .workRunning,
        let work = try? failure.details?["work"]?.decode(WorkspaceActiveWork.Result.self)
      {
        return .workRunning(work)
      }
      return .failed(SignInCopy.accountFailure(for: failure))
    }
  }

  // MARK: The left-open notice

  /// Dismiss "The last sign-out could not reach the hub; …". Only this clears it.
  public func dismissAccountNotice() async {
    guard let client else { return }
    guard
      let status = try? await client.request(
        AccountDismissNotice.self, EmptyParams(), options: Self.signInMutation())
    else { return }
    accountNotice = nil
    applyAccountStatus(status, loadStore: false)
  }
}
