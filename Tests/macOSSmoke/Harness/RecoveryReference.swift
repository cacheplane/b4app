import AppKit
import SwiftUI
import WorkspaceUI

/// A fresh intrinsic rendering measures required text height without a checked-in pixel baseline.
enum RecoveryReference {
  static var panel: NSWindow?

  static func show(socket: String) {
    guard socket.hasPrefix("/tmp/b4smk-"),
      let model = SmokeDelegate.model,
      let message = model.remediation?.message ?? model.lastFailure?.message ?? model.lastError,
      let data = try? Data(
        contentsOf: URL(fileURLWithPath: socket).deletingLastPathComponent()
          .deletingLastPathComponent().appendingPathComponent("reference.json")),
      let request = try? JSONDecoder().decode([String: Double].self, from: data),
      let width = request["width"], width > 100, width < 1000
    else { return }
    let env = ProcessInfo.processInfo.environment
    // The runner measures the actual message width; no assumptions about sidebar restoration.
    let text = Text(message).font(LLAFont.small).foregroundStyle(LLA.Color.danger)
      .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("fixture.reference")
    let host = NSHostingController(
      rootView: text.padding(16).background(LLA.Color.bg)
        .preferredColorScheme(env["SMOKE_DARK"] == "1" ? .dark : .light))
    let panel = NSWindow(contentViewController: host)
    panel.isReleasedWhenClosed = false
    panel.title = "Recovery reference"
    panel.setContentSize(CGSize(width: width + 32, height: 200))
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    self.panel = panel
  }
}
