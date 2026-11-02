import Foundation
import Observation
import SwiftUI

/// "Connect your Mac" (sign-in plan, Task 15; mockup A2, approved 2026-11-02): the iPhone's signed-out
/// screen leads with it, and on a phone whose account has no Mac it replaces the thread list in the
/// same layout. The sidebar's footer and the profile menu stay. Threads run on a Mac, so there is
/// nothing to list until one joins; the phone's next sync (at most a minute) finds it. Both are drawn
/// from `PhoneLandingContent`; the scanner and the enrollment sheet are the app's.
public enum ConnectMacCopy {
  public static let title = "Connect your Mac"
  public static let message = "Scan the code Agent Workspace shows on your Mac."
  public static let scan = "Scan the code"
  /// The signed-out screen's one quiet link, to the sheet of other sign-ins.
  public static let otherWays = "Other ways to sign in"
  /// The sheet's passkey row (the Mac's button stays `SignInCopy.passkey`).
  public static let passkey = "Sign in with a passkey"
  public static let enroll = "Use an enrollment code"
  /// Copies `https://<site>/app/download`, then reads `copied` for two seconds.
  public static let getMacApp = "Get the Mac app"
  public static let copied = "Copied"
  public static let help = "Help"
}

extension WorkspaceModel {
  /// The phone is signed in to an account that has no Mac. Never on the Mac, whose account is the
  /// coordinator's, and never while signed out or onboarding (those screens come first).
  public var showsConnectMac: Bool {
    accountSource == .host && accountHost != nil && rootScreen == .workspace && accountHasNoMac
  }
}

/// The view's state: what Get the Mac app copies and how long it reads "Copied", and the help page
/// a Safari sheet shows. The pasteboard and the clock are the app's.
@MainActor @Observable
public final class ConnectMac {
  /// The help page while its sheet is open.
  public struct Help: Identifiable, Equatable {
    public let url: URL
    public var id: URL { url }
  }

  public let downloadURL: URL
  public let helpURL: URL
  /// A camera exists, so the primary button can scan.
  public let showsScan: Bool
  /// Set by Help; the sheet clears it when it closes.
  public var help: Help?
  /// "Copied" for two seconds after a copy.
  public private(set) var copied = false

  /// How long "Copied" stays.
  public static let copiedFor: Duration = .seconds(2)

  @ObservationIgnored private let copy: @MainActor (String) -> Void
  @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
  /// Counts copies, so only the latest one's wait puts the label back.
  @ObservationIgnored private var copies = 0

  public init(
    siteDomain: String, hasCamera: Bool, copy: @escaping @MainActor (String) -> Void,
    sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    let configuration = SignInConfiguration(siteDomain: siteDomain, appleSignIn: false, badge: nil)
    downloadURL = configuration.downloadURL
    helpURL = configuration.iPhoneHelpURL
    showsScan = hasCamera
    self.copy = copy
    self.sleep = sleep
  }

  public var copyLabel: String { copied ? ConnectMacCopy.copied : ConnectMacCopy.getMacApp }

  /// Copies the download link, then reads "Copied" for two seconds (from the latest tap).
  public func copyDownloadLink() async {
    copies += 1
    let mine = copies
    copy(downloadURL.absoluteString)
    copied = true
    await sleep(Self.copiedFor)
    if mine == copies { copied = false }
  }

  public func openHelp() { help = Help(url: helpURL) }
}

extension EnvironmentValues {
  /// What replaces the phone's thread list while `showsConnectMac` holds; the app sets it. Nil leaves the
  /// list (the Mac, and tests).
  @Entry public var connectMacContent: (@MainActor () -> AnyView)? = nil
}
