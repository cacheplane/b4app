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

    public init(state: State, account: Account? = nil, known: [Known] = [], reason: SignOutReason? = nil) {
      self.state = state
      self.account = account
      self.known = known
      self.reason = reason
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
/// waits for `callbackScheme`, then hand the redirect's `handoff` to `account.appleFinish`. One
/// ceremony is in flight at a time; a new start replaces it. `unsupported_capability` on the local
/// flavour.
public enum AccountAppleStart: WorkspaceCommand {
  public typealias Params = EmptyParams
  public struct Result: Codable, Sendable, Equatable {
    public var url: String
    public var callbackScheme: String
    public init(url: String, callbackScheme: String) {
      self.url = url
      self.callbackScheme = callbackScheme
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

/// Begin adding a passkey to the signed-in account: registration options that exclude its passkeys.
public enum AccountAddPasskeyBegin: WorkspaceCommand {
  public typealias Params = EmptyParams
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
public enum AccountRemoveIdentity: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var identityId: String
    public init(identityId: String) { self.identityId = identityId }
  }
  public typealias Result = AccountIdentities.Result
  public static let method = Method.accountRemoveIdentity
}

/// Delete the signed-in account at the hub, then sign out and drop its database and registry row on
/// this Mac. A refusal (`shared_org`, or any hub error) changes nothing here.
public enum AccountDelete: WorkspaceCommand {
  public typealias Params = EmptyParams
  public typealias Result = AccountStatus.Result
  public static let method = Method.accountDelete
}
