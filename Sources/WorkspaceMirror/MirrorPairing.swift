import Foundation
import WorkspaceProtocol

/// What a link opened on this phone, or a QR code scanned in the app, may do (sign-in plan, Task 15).
/// The system Camera and universal links, `onOpenURL`, and the in-app scanner all reach this one
/// decision. Deciding sends nothing; a `confirm` is only an offer, which the phone asks about first.
public enum PairLinkDecision: Sendable, Equatable, CustomStringConvertible {
  /// Ask "Pair this iPhone with the hub at <host>?", then `MirrorAccount.pair`.
  case confirm(PairLink)
  /// A pairing link this phone refuses: another flavour's site, the code in the query, a bad code, an
  /// old `b4app://pair` link outside the local flavour, ….
  case invalid
  /// Not a pairing link.
  case ignored

  public var description: String {
    switch self {
    case .confirm(let link): "confirm(\(link))"
    case .invalid: "invalid"
    case .ignored: "ignored"
    }
  }
}

extension PhoneFlavor {
  /// The offer `url` makes to a phone of this flavour: `https://<siteDomain>/pair#c=<code>` for this
  /// flavour's hub, or (the local flavour only, during M8c's transition) `b4app://pair?hub=&code=` for
  /// a hub on this machine. Nil for anything else, another flavour's site included.
  public func parsePairLink(_ url: URL) -> PairLink? {
    PairLink.parse(url, siteDomain: siteDomain, hubURL: hubURL, legacyLoopback: self == .local)
  }

  public func pairLinkDecision(_ url: URL) -> PairLinkDecision {
    guard PairLink.isPairLink(url) else { return .ignored }
    return parsePairLink(url).map(PairLinkDecision.confirm) ?? .invalid
  }
}

/// What `MirrorAccount.pair` did with a confirmed pairing link.
public enum MirrorPairOutcome: Sendable, Equatable {
  /// The phone enrolled into the code's account (it was signed out), or merged its phone-only account
  /// into it: either way it is now signed in there.
  case signedIn(AccountStatus.Result)
  /// The code is for the org this phone is already in (`merge_refused`, `same_account`). Nothing
  /// changed; say `PairingCopy.alreadyPaired`.
  case alreadyPaired
  /// The phone is signed in to another account that will not merge (it has a Mac, it is in a shared
  /// org) or is at another hub. Nothing changed: ask `PairingCopy.switchQuestion(to: nil, from:)` and,
  /// on confirm, `MirrorAccount.switchAndPair`.
  case askToSwitch(from: String)
}

/// The words a pairing scan uses on the phone.
public enum PairingCopy {
  /// M8c's answer on a phone that is paired already.
  public static let alreadyPaired = "This iPhone is already paired"
  public static let switchButton = "Switch"

  /// "Switch to <org name>? You'll be signed out of <other org name>." The phone does not know the
  /// code's org before redeeming it, which happens only once this is confirmed, so it names "this
  /// Mac's account" when `orgName` is nil.
  public static func switchQuestion(to orgName: String?, from current: String) -> String {
    "Switch to \(orgName ?? "this Mac's account")? You'll be signed out of \(current)."
  }
}
