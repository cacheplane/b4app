import Foundation

/// A build flavour: which hub the app talks to and which names it owns, so that a production app, a
/// beta app and a local development build can run side by side on one Mac (sign-in plan, Task 1).
///
/// The flavour is chosen at run time, in this order: the `B4APP_FLAVOR` environment variable, then
/// `B4AppFlavor` in the `Info.plist` of the enclosing `.app` (a CLI in `Contents/Helpers/` walks up to
/// its app), then `local`. An unknown value in either place is ignored.
public enum Flavor: String, Sendable, CaseIterable {
  case prod, beta, local

  /// The flavour of this process, resolved once.
  public static let current: Flavor = resolve(
    environment: ProcessInfo.processInfo.environment, executableURL: Bundle.main.executableURL)

  public static func resolve(environment: [String: String], executableURL: URL?) -> Flavor {
    if let value = environment["B4APP_FLAVOR"], let flavor = Flavor(rawValue: value) { return flavor }
    if let executableURL, let value = bundleFlavor(enclosing: executableURL),
      let flavor = Flavor(rawValue: value)
    {
      return flavor
    }
    return .local
  }

  /// `B4AppFlavor` from `Contents/Info.plist` of the nearest ancestor of `url` named `*.app`.
  private static func bundleFlavor(enclosing url: URL) -> String? {
    var directory = url.deletingLastPathComponent()
    while true {
      if directory.pathExtension == "app" {
        let plist = directory.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
          let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary["B4AppFlavor"] as? String
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { return nil }
      directory = parent
    }
  }

  public var hubURL: URL {
    switch self {
    case .prod: URL(string: "https://hub.b4.run")!
    case .beta: URL(string: "https://hub.test.b4.run")!
    case .local: URL(string: "http://localhost:8080")!
    }
  }

  /// The passkey relying-party domain.
  public var siteDomain: String {
    switch self {
    case .prod: "b4.run"
    case .beta: "test.b4.run"
    case .local: "local.b4.run"
    }
  }

  public var appleSignIn: Bool { self != .local }

  /// Appended to directory names and the URL scheme.
  public var dirSuffix: String {
    switch self {
    case .prod: ""
    case .beta: "-beta"
    case .local: "-local"
    }
  }

  /// Appended to reverse-DNS identifiers (bundle ids, the LaunchAgent label, keychain groups).
  public var idSuffix: String {
    switch self {
    case .prod: ""
    case .beta: ".beta"
    case .local: ".local"
    }
  }

  public var urlScheme: String { "b4app" + dirSuffix }

  /// What the UI shows to mark a non-production hub; nil for production.
  public var badge: String? {
    switch self {
    case .prod: nil
    case .beta: "Test hub"
    case .local: "Local hub"
    }
  }

  public var macBundleId: String { "com.cacheplane.b4app" + idSuffix }

  /// The part of the shared keychain access group between the team id and `.shared`.
  public var keychainGroupSuffix: String { idSuffix }
}
