import SwiftUI
import UIKit
import WorkspaceUI

/// "Connect your Mac" (sign-in plan, Task 15; mockup A2): on a phone whose account has no Mac it takes
/// the thread list's place; the sidebar's footer and profile menu stay. It is the signed-out landing's
/// layout and copy without "Other ways to sign in". Its state and copy are `ConnectMac`'s and the
/// drawing is `ConnectMacScreen`'s (`WorkspaceUI`, tested there); this gives them the pasteboard and
/// the app's scanner.
///
/// - **Scan the code** (primary, hidden without a camera) opens the scanner; what it reads goes the
///   way every pairing link goes (`onScan`).
/// - **Get the Mac app** copies `https://<site>/app/download` and reads "Copied" for two seconds.
/// - **Help** opens `https://<site>/app/help/iphone` in an `SFSafariViewController` sheet.
struct ConnectMacView: View {
  let onScan: () -> Void
  @State private var state: ConnectMac

  init(siteDomain: String, onScan: @escaping () -> Void) {
    self.onScan = onScan
    _state = State(
      initialValue: ConnectMac(
        siteDomain: siteDomain, hasCamera: QRScannerView.isAvailable,
        copy: { UIPasteboard.general.string = $0 }))
  }

  var body: some View {
    ConnectMacScreen(state: state, onScan: onScan)
      .navigationTitle("")
  }
}
