import SafariServices
import SwiftUI
import UIKit
import WorkspaceUI

/// "Connect your Mac" (sign-in plan, Task 15; `pairing.html`, middle): on a phone whose account has no
/// Mac it takes the thread list's place; the sidebar's footer and profile menu stay. Its state and copy
/// are `ConnectMac`'s (`WorkspaceUI`, tested there); this draws them, with the app's scanner and a
/// Safari sheet.
///
/// - **Scan the code** (primary, hidden without a camera) opens the scanner; what it reads goes the
///   way every pairing link goes (`onScan`).
/// - **Copy download link** copies `https://<site>/app/download` and reads "Copied" for two seconds.
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
    ScrollView {
      VStack(spacing: LLA.Space.l) {
        VStack(spacing: LLA.Space.s) {
          Text(ConnectMacCopy.title)
            .llaDisplay()
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
          Text(ConnectMacCopy.message)
            .llaMuted()
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        if state.showsScan {
          Button(ConnectMacCopy.scan, action: onScan)
            .buttonStyle(.llaPrimary)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("connectMac.scan")
        }
        ViewThatFits(in: .horizontal) {
          HStack(spacing: LLA.Space.l) { links }
          VStack(spacing: 0) { links }
        }
      }
      .frame(maxWidth: 320)
      .padding(.horizontal, LLA.Metrics.margin)
      .padding(.vertical, LLA.Space.xxl)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.center)
    .navigationTitle("")
    .sheet(item: $state.help) { help in
      SafariView(url: help.url).ignoresSafeArea()
    }
  }

  @ViewBuilder private var links: some View {
    Button(state.copyLabel) { Task { await state.copyDownloadLink() } }
      .buttonStyle(.llaLink)
      .accessibilityIdentifier("connectMac.copyLink")
    Button(ConnectMacCopy.help) { state.openHelp() }
      .buttonStyle(.llaLink)
      .accessibilityIdentifier("connectMac.help")
  }
}

/// A web page in Safari's own sheet: the reader's cookies and sign-ins, and nothing the app can read.
private struct SafariView: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> SFSafariViewController {
    SFSafariViewController(url: url)
  }

  func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
