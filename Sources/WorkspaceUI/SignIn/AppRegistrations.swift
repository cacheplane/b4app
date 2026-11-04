import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// The copies of this app that macOS has registered under its bundle id besides the one running
/// (D-173). Launch Services keeps a record per copy it has seen (Xcode registers every build product;
/// scratch copies and other checkouts' `dist/` add more), and the daemon that checks associated
/// domains can pick any of them, so a copy without the `webcredentials` entitlement makes Apple's https
/// callback and passkeys fail in the packaged app with the same codes as a closed sheet. The ceremonies
/// ask here before reading such a code as a cancel, and `Scripts/fix-app-registrations.sh` clears the
/// copies.
public enum AppRegistrations {
  /// The registered copies other than `own`, each path once, in Launch Services' order.
  static func others(registered: [URL], own: URL) -> [URL] {
    let ownPath = Self.path(own)
    var seen: Set<String> = [ownPath]
    return registered.filter { seen.insert(Self.path($0)).inserted }
  }

  private static func path(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  /// The other copies of the running app; none off the Mac, or outside a bundle.
  @MainActor
  static func othersOfThisApp() -> [URL] {
    #if canImport(AppKit)
      guard let id = Bundle.main.bundleIdentifier else { return [] }
      let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
      return others(registered: registered, own: Bundle.main.bundleURL)
    #else
      return []
    #endif
  }

  /// `AppRegisteredElsewhere` when the Mac has other copies registered, else nil.
  @MainActor
  static func elsewhere() -> AppRegisteredElsewhere? {
    let others = othersOfThisApp()
    return others.isEmpty ? nil : AppRegisteredElsewhere(count: others.count)
  }
}

/// Raised by a ceremony on the Mac when the system refused to run it (or ended it at once) while
/// Launch Services has this app's bundle id registered from other copies (D-173). The sign-in screen
/// names the count and the script that clears them.
public struct AppRegisteredElsewhere: Error, Sendable, Equatable {
  public var count: Int
  public init(count: Int) { self.count = count }
}
