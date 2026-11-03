import Foundation

/// Who this Mac is signed in as (sign-in plan, Task 9). `account.status` answers it (Task 10) and the
/// event `account.changed` carries it whenever it changes. No token or token reference is part of it.
public enum AccountStatus: WorkspaceCommand {
  public typealias Params = EmptyParams
  public static let method = Method.accountStatus

  public enum State: String, Codable, Sendable, Equatable {
    case signedOut
    case needsOnboarding
    case signedIn
  }

  /// The signed-in account, as the profile button shows it.
  public struct Account: Codable, Sendable, Equatable {
    /// The local account id (16 lowercase hex characters).
    public var id: String
    public var displayName: String
    public var orgName: String
    public var hubURL: String

    public init(id: String, displayName: String, orgName: String, hubURL: String) {
      self.id = id
      self.displayName = displayName
      self.orgName = orgName
      self.hubURL = hubURL
    }
  }

  /// An account that has signed in on this Mac before, signed in now or not.
  public struct Known: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var orgName: String
    public var lastSignedInAt: String?

    public init(id: String, displayName: String, orgName: String, lastSignedInAt: String? = nil) {
      self.id = id
      self.displayName = displayName
      self.orgName = orgName
      self.lastSignedInAt = lastSignedInAt
    }
  }

  public struct Result: Codable, Sendable, Equatable {
    public var state: State
    /// Set unless `state` is `signedOut`.
    public var account: Account?
    public var known: [Known]
    /// Why this Mac was signed out without asking, while it stays signed out.
    public var reason: SignOutReason?
    /// Something to tell the signed-in person until they dismiss it (`account.dismissNotice`): "The last
    /// sign-out could not reach the hub; that session was left open there." `hub.status` carries it too.
    public var notice: String?

    public init(
      state: State, account: Account? = nil, known: [Known] = [], reason: SignOutReason? = nil,
      notice: String? = nil
    ) {
      self.state = state
      self.account = account
      self.known = known
      self.reason = reason
      self.notice = notice
    }
  }
}

/// Why the coordinator signed an account out on its own. The sign-in screen shows
/// "This Mac was signed out of <orgName>." for `rejectedByHub`.
public struct SignOutReason: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, Equatable {
    /// The hub refused the account's token (401): the Mac was removed from the account, or the
    /// account was deleted, on another device.
    case rejectedByHub
  }

  public var kind: Kind
  public var orgName: String

  public init(kind: Kind, orgName: String) {
    self.kind = kind
    self.orgName = orgName
  }

  public static func rejectedByHub(_ orgName: String) -> SignOutReason {
    SignOutReason(kind: .rejectedByHub, orgName: orgName)
  }
}

extension AdapterEvent {
  /// The account this Mac is signed in as changed: a sign-in, a sign-out, or a profile refresh. The
  /// payload is the new `AccountStatus.Result`. Not tied to a connection.
  public static func accountChanged(_ status: AccountStatus.Result) throws -> AdapterEvent {
    AdapterEvent(kind: .accountChanged, connectionId: "", payload: try JSONValue(encoding: status))
  }
}

// MARK: - The account commands (sign-in plan, Task 10)
//
// Every hub call of a sign-in runs in the coordinator, so the device token never enters the app. A
// WebAuthn response or an Apple handoff crosses the socket once, into the coordinator, and is never
// logged, stored, or echoed: each type that carries one prints it as `<redacted>`. The Apple flow's
// verifier never leaves the coordinator.

/// Begin a passkey ceremony at the flavour's hub: the hub's answer, which holds no secret. Hand
/// `authentication` (and, after "Create account", `registration`) to the platform as they are.
public enum AccountPasskeyBegin: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var ceremonyId: String
    /// A WebAuthn `PublicKeyCredentialRequestOptions` wrapper (`{"publicKey": {...}}`).
    public var authentication: JSONValue
    /// A `PublicKeyCredentialCreationOptions` wrapper for a new account; absent while the hub's
    /// sign-up is closed.
    public var registration: JSONValue?
    public init(ceremonyId: String, authentication: JSONValue, registration: JSONValue? = nil) {
      self.ceremonyId = ceremonyId
      self.authentication = authentication
      self.registration = registration
    }
  }
  public static let method = Method.accountPasskeyBegin
}

/// Finish the ceremony with exactly one of `assertion` (sign in) or `attestation` (sign up), and sign
/// in as the hub's answer. The status is `needsOnboarding` until `account.completeProfile`.
public enum AccountPasskeyFinish: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var ceremonyId: String
    public var assertion: JSONValue?
    public var attestation: JSONValue?
    public init(ceremonyId: String, assertion: JSONValue? = nil, attestation: JSONValue? = nil) {
      self.ceremonyId = ceremonyId
      self.assertion = assertion
      self.attestation = attestation
    }
    public var description: String {
      "AccountPasskeyFinish.Params(ceremonyId: \(ceremonyId), response: <redacted>)"
    }
    public var debugDescription: String { description }
  }
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountPasskeyFinish
}

/// Begin Sign in with Apple's web flow (the Mac's): open `url` in an `ASWebAuthenticationSession` that
/// waits for `callback`, then hand the redirect's `handoff` to `account.appleFinish`. One
/// ceremony is in flight at a time; a new start replaces it. `unsupported_capability` on the local
/// flavour.
public enum AccountAppleStart: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var url: String
    /// Where the result comes back, with `?handoff=` or `?error=` appended: `<scheme>://auth` (the
    /// flavour's scheme) or an https URL on the flavour's site, which only this app can take back
    /// from its session (D-160).
    public var callback: String
    public init(url: String, callback: String) {
      self.url = url
      self.callback = callback
    }
  }
  public static let method = Method.accountAppleStart
}

/// Redeem the web flow's one-time `handoff` (with the verifier the coordinator kept) and sign in.
/// `ceremony_expired`, without asking the hub, when no Apple ceremony is in flight.
public enum AccountAppleFinish: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var handoff: String
    public init(handoff: String) { self.handoff = handoff }
    public var description: String { "AccountAppleFinish.Params(handoff: <redacted>)" }
    public var debugDescription: String { description }
  }
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountAppleFinish
}

/// Onboarding: the person's full name (1 to 200 characters once trimmed). The status becomes
/// `signedIn`.
public enum AccountCompleteProfile: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var fullName: String
    public init(fullName: String) { self.fullName = fullName }
  }
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountCompleteProfile
}

/// Log out of the signed-in account: interrupt its running turns and stop its servers (10 s), push
/// once (10 s), end the session at the hub (keeping the device), then forget the token and close the
/// account. With work running and `stopWork` false it refuses with `work_running`, whose
/// `details.work` is a `WorkspaceActiveWork.Result`, and changes nothing. A hub that cannot be reached
/// does not stop it: the session left open there is reported once by `hub.status` at the account's
/// next sign-in.
public enum AccountLogout: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var stopWork: Bool
    public init(stopWork: Bool = false) { self.stopWork = stopWork }

    private enum CodingKeys: String, CodingKey { case stopWork }
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      stopWork = try container.decodeIfPresent(Bool.self, forKey: .stopWork) ?? false
    }
  }
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountLogout
}

/// One of the account's sign-in methods. No credential id, stored passkey, Apple `sub`, or token is
/// part of it.
public struct AccountIdentity: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  /// `passkey` or `apple`.
  public var kind: String
  /// A passkey's name, or an Apple ID's (often relay) email.
  public var name: String?
  public var createdAt: String
  public var lastUsedAt: String?
  public init(id: String, kind: String, name: String? = nil, createdAt: String, lastUsedAt: String? = nil) {
    self.id = id
    self.kind = kind
    self.name = name
    self.createdAt = createdAt
    self.lastUsedAt = lastUsedAt
  }
}

/// The signed-in account's sign-in methods, oldest first.
public enum AccountIdentities: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var identities: [AccountIdentity]
    public init(identities: [AccountIdentity]) { self.identities = identities }
  }
  public static let method = Method.accountIdentities
}

// MARK: - Confirming it's you (D-150)

/// A fresh confirmation that the signed-in person is at this device, for one change that needs it
/// (adding a passkey, connecting an Apple ID, removing a sign-in method, deleting the account): a
/// passkey assertion against `account.stepUpBegin`'s ceremony (`ceremonyId` and `assertion`), the
/// Mac's Apple web flow (`handoff`, against `account.stepUpAppleStart`, whose verifier the coordinator
/// keeps), or, on the phone only, Apple's native sheet (`ceremonyId` and `identityToken`). It crosses
/// once into whoever makes the change, which finishes it at the hub and makes the change with the
/// grant it earns; neither is kept. An account with no sign-in method sends none.
public struct AccountStepUp: Codable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public var ceremonyId: String?
  public var assertion: JSONValue?
  public var handoff: String?
  public var identityToken: String?

  public init(
    ceremonyId: String? = nil, assertion: JSONValue? = nil, handoff: String? = nil,
    identityToken: String? = nil
  ) {
    self.ceremonyId = ceremonyId
    self.assertion = assertion
    self.handoff = handoff
    self.identityToken = identityToken
  }

  public static func passkey(ceremonyId: String, assertion: JSONValue) -> AccountStepUp {
    AccountStepUp(ceremonyId: ceremonyId, assertion: assertion)
  }

  public static func appleWeb(handoff: String) -> AccountStepUp { AccountStepUp(handoff: handoff) }

  public static func appleNative(ceremonyId: String, identityToken: String) -> AccountStepUp {
    AccountStepUp(ceremonyId: ceremonyId, identityToken: identityToken)
  }

  public var description: String {
    let kind =
      assertion != nil
      ? "passkey" : handoff != nil ? "appleWeb" : identityToken != nil ? "appleNative" : "none"
    return "AccountStepUp(\(kind), <redacted>)"
  }
  public var debugDescription: String { description }
}

/// Begin confirming with a passkey: assertion options whose `allowCredentials` are the account's own
/// passkeys. Hand `authentication` to the platform as it is, then send the assertion as an
/// `AccountStepUp` with the change. `not_found` for an account with no passkey.
public enum AccountStepUpBegin: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var ceremonyId: String
    public var authentication: JSONValue
    public init(ceremonyId: String, authentication: JSONValue) {
      self.ceremonyId = ceremonyId
      self.authentication = authentication
    }
  }
  public static let method = Method.accountStepUpBegin
}

/// Begin confirming with the account's Apple ID on the Mac's web flow, as `account.appleLinkStart`
/// begins a link: open `url` in an `ASWebAuthenticationSession` waiting for `callback`, then send
/// the redirect's `handoff` as an `AccountStepUp` with the change. The coordinator keeps the verifier;
/// one step-up is in flight at a time. `not_found` for an account with no Apple ID,
/// `unsupported_capability` on the local flavour.
public enum AccountStepUpAppleStart: WorkspaceCommand {
  public typealias Params = EmptyParams
  public typealias Result = AccountAppleStart.Result
  public static let method = Method.accountStepUpAppleStart
}

/// The params of a change that needs confirming: `stepUp` is absent only for an account with no
/// sign-in method. A change without a live one is `step_up_required`.
public struct AccountStepUpParams: Codable, Sendable, Equatable {
  public var stepUp: AccountStepUp?
  public init(stepUp: AccountStepUp? = nil) { self.stepUp = stepUp }
}

/// Begin adding a passkey to the signed-in account: registration options that exclude its passkeys.
/// Needs confirming (`stepUp`).
public enum AccountAddPasskeyBegin: WorkspaceCommand {
  public typealias Params = AccountStepUpParams
  public struct Result: Codable, Sendable, Equatable {
    public var ceremonyId: String
    public var registration: JSONValue
    public init(ceremonyId: String, registration: JSONValue) {
      self.ceremonyId = ceremonyId
      self.registration = registration
    }
  }
  public static let method = Method.accountAddPasskeyBegin
}

public enum AccountAddPasskeyFinish: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var ceremonyId: String
    public var attestation: JSONValue
    public init(ceremonyId: String, attestation: JSONValue) {
      self.ceremonyId = ceremonyId
      self.attestation = attestation
    }
    public var description: String {
      "AccountAddPasskeyFinish.Params(ceremonyId: \(ceremonyId), attestation: <redacted>)"
    }
    public var debugDescription: String { description }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var identity: AccountIdentity
    public init(identity: AccountIdentity) { self.identity = identity }
  }
  public static let method = Method.accountAddPasskeyFinish
}

/// Unlink one sign-in method; the account's last one is `last_identity`. Answers the methods left.
/// Needs confirming (`stepUp`).
public enum AccountRemoveIdentity: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var identityId: String
    public var stepUp: AccountStepUp?
    public init(identityId: String, stepUp: AccountStepUp? = nil) {
      self.identityId = identityId
      self.stepUp = stepUp
    }
  }
  public typealias Result = AccountIdentities.Result
  public static let method = Method.accountRemoveIdentity
}

/// Dismiss the signed-in account's notice (`AccountStatus.Result.notice`, `HubStatus.Result.notice`)
/// once the person has seen it. Reading a status never clears it.
public enum AccountDismissNotice: WorkspaceCommand {
  public typealias Params = EmptyParams
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountDismissNotice
}

/// Delete the signed-in account at the hub, then sign out and drop its database and registry row on
/// this Mac. A refusal (`shared_org`, `step_up_required`, or any hub error) changes nothing here.
/// Needs confirming (`stepUp`).
public enum AccountDelete: WorkspaceCommand {
  public typealias Params = AccountStepUpParams
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountDelete
}

// MARK: - Linking an Apple ID (sign-in plan, Task 14)

/// Begin linking an Apple ID to the signed-in account with the web flow (the Mac's Settings →
/// Account → Connect Apple ID): open `url` in an `ASWebAuthenticationSession` that waits for
/// `callback`, then hand the redirect's `handoff` to `account.appleLinkFinish`. The coordinator
/// keeps the verifier, as for `account.appleStart`; one link is in flight at a time. `apple_linked`
/// when the account has one already, `unsupported_capability` on the local flavour. Needs confirming
/// (`stepUp`, a passkey's: an account with an Apple ID has nothing to link).
public enum AccountAppleLinkStart: WorkspaceCommand {
  public typealias Params = AccountStepUpParams
  public typealias Result = AccountAppleStart.Result
  public static let method = Method.accountAppleLinkStart
}

/// Redeem a link's one-time `handoff` (with the kept verifier) and add the Apple ID to the signed-in
/// account; answers the new method. `ceremony_expired`, without asking the hub, when no link is in
/// flight.
public enum AccountAppleLinkFinish: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var handoff: String
    public init(handoff: String) { self.handoff = handoff }
    public var description: String { "AccountAppleLinkFinish.Params(handoff: <redacted>)" }
    public var debugDescription: String { description }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var identity: AccountIdentity
    public init(identity: AccountIdentity) { self.identity = identity }
  }
  public static let method = Method.accountAppleLinkFinish
}

/// A native Sign in with Apple ceremony the hub began (the iPhone's): Apple's sheet is handed the
/// lowercase hex SHA-256 of `nonce`, and the answer goes back with `ceremonyId`. Never stored; the nonce
/// prints as `<redacted>`.
public struct AppleNativeCeremony: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible
{
  public var ceremonyId: String
  public var nonce: String
  public init(ceremonyId: String, nonce: String) {
    self.ceremonyId = ceremonyId
    self.nonce = nonce
  }
  public var description: String { "AppleNativeCeremony(ceremonyId: \(ceremonyId), nonce: <redacted>)" }
  public var debugDescription: String { description }
}

/// What Apple's native sheet answered: the identity token, the authorization code, and the person's
/// formatted name (Apple gives it the first time only). Handed to the hub once and never kept; the
/// token and the code print as `<redacted>`.
public struct AppleCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public var identityToken: String
  public var authorizationCode: String
  public var fullName: String?
  public init(identityToken: String, authorizationCode: String, fullName: String? = nil) {
    self.identityToken = identityToken
    self.authorizationCode = authorizationCode
    self.fullName = fullName
  }
  public var description: String {
    "AppleCredential(identityToken: <redacted>, authorizationCode: <redacted>, fullName: \(fullName == nil ? "nil" : "set"))"
  }
  public var debugDescription: String { description }
}
