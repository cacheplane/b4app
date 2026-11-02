import Foundation

/// Who this Mac is signed in as (sign-in plan, Task 9). `account.status` answers it (Task 10) and the
/// event `account.changed` carries it whenever it changes. No token or token reference is part of it.
public enum AccountStatus {
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
