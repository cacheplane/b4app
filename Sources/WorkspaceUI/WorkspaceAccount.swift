import Foundation
import WorkspaceProtocol

/// The hub user this device is signed in as, for the profile button.
public struct WorkspaceAccount: Sendable, Equatable {
  public var username: String
  public var displayName: String?

  public init(username: String, displayName: String?) {
    self.username = username
    self.displayName = displayName
  }

  /// The account a joined coordinator reports; nil when it has not joined or names no user.
  public init?(status: HubStatus.Result) {
    guard status.joined, let username = status.username else { return nil }
    self.init(username: username, displayName: status.displayName)
  }

  /// The account a joined coordinator reports, named by the signed-in account (`account.status`)
  /// when that has a name: onboarding and Settings keep it current, while the hub link's name is read
  /// once at join, before a new account has given one.
  public init?(status: HubStatus.Result, profile: AccountStatus.Account?) {
    guard var account = WorkspaceAccount(status: status) else { return nil }
    account.rename(from: profile)
    self = account
  }

  /// Takes the signed-in account's display name, unless it has none.
  mutating func rename(from profile: AccountStatus.Account?) {
    let name = profile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !name.isEmpty { displayName = name }
  }

  private var trimmedDisplayName: String? {
    let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The display name when it has one, else the username.
  public var name: String { trimmedDisplayName ?? username }

  /// The first letters of the first and last words of the display name ("Brian de Love" is "BL"), or the
  /// username's first two letters without one. Characters, not scalars, so an emoji stays whole.
  public var initials: String {
    guard let displayName = trimmedDisplayName else { return String(username.prefix(2)).uppercased() }
    let words = displayName.split(whereSeparator: \.isWhitespace)
    guard let first = words.first?.first else { return "" }
    guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
    return (String(first) + String(last)).uppercased()
  }
}

/// Who supplies the account: the coordinator's hub link (the Mac) or the app around the model (the
/// phone's mirror, which has no coordinator to ask).
public enum AccountSource: Sendable {
  case coordinator, host
}
