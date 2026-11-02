import Foundation

/// The iPhone's build flavour (sign-in plan, Task 1): which hub it signs in at, and which names its
/// storage owns. The values are `Flavor`'s (`WorkspacePlatform`, which the phone does not link); a test
/// of the shared UI checks that the two agree.
///
/// The prod and beta iPhone builds share one bundle id, so an App Store build and a TestFlight build
/// installed one after the other share the app's container and Keychain. Their mirror folder and
/// Keychain service therefore differ by flavour (prod keeps `b4app`, where every earlier build kept
/// them), so neither reads a mirror or a token meant for the other's hub.
public enum PhoneFlavor: String, Sendable, CaseIterable {
  case prod, beta, local

  /// `B4APP_FLAVOR` in the environment, then `B4AppFlavor` in the app's `Info.plist`, then `local`. An
  /// unknown value in either place is ignored.
  public static func resolve(environment: [String: String], info: [String: Any]) -> PhoneFlavor {
    if let value = environment["B4APP_FLAVOR"], let flavor = PhoneFlavor(rawValue: value) { return flavor }
    if let value = info["B4AppFlavor"] as? String, let flavor = PhoneFlavor(rawValue: value) { return flavor }
    return .local
  }

  /// The flavour of this app, resolved once.
  public static let current = resolve(
    environment: ProcessInfo.processInfo.environment, info: Bundle.main.infoDictionary ?? [:])

  public var hubURL: URL {
    switch self {
    case .prod: URL(string: "https://hub.b4.run")!
    case .beta: URL(string: "https://hub.test.b4.run")!
    case .local: URL(string: "http://localhost:8080")!
    }
  }

  /// The passkey relying party, and the site the app's links open.
  public var siteDomain: String {
    switch self {
    case .prod: "b4.run"
    case .beta: "test.b4.run"
    case .local: "local.b4.run"
    }
  }

  /// The local flavour has no Sign in with Apple entitlement.
  public var appleSignIn: Bool { self != .local }

  /// What the sign-in screen shows to mark a non-production hub.
  public var badge: String? {
    switch self {
    case .prod: nil
    case .beta: "Test hub"
    case .local: "Local hub"
    }
  }

  public var dirSuffix: String {
    switch self {
    case .prod: ""
    case .beta: "-beta"
    case .local: "-local"
    }
  }

  public var urlScheme: String { "b4app" + dirSuffix }

  /// The mirror's folder under Application Support.
  public var directoryName: String { "b4app" + dirSuffix }

  /// The Keychain service the device token is kept under.
  public var keychainService: String { "b4app" + dirSuffix }
}
