import AppKit
import SwiftUI
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The real notice at desktop and narrow widths, using the live archived-session response shape.
@Suite(.serialized) @MainActor struct RecoveryNoticeTests {
  @Test func longExpandedPrimaryErrorKeepsTheMinimumSizeBounded() {
    let message = String(repeating: "A runtime failure with an arbitrarily long explanation. ", count: 300)
    let failure = WorkspaceError(.internalError, message)
    let notice = ThreadErrorNotice(
      error: message, failure: failure, remedy: nil, perform: { _ in }, dismiss: {},
      detailsExpanded: true)
    let controller = NSHostingController(rootView: notice)
    for width in [CGFloat(0), 340, 610] {
      let minimum = controller.sizeThatFits(in: CGSize(width: width, height: 0))
      #expect(minimum.height < 300, "primary error forces a tall split-view minimum: \(minimum)")
    }
  }

  @Test func longExpandedDiagnosticsStayWithinTheWindowBudget() {
    let failure = WorkspaceError(
      .internalError, "Could not read the session.",
      details: [
        "nativeMessage": .string(String(repeating: "A native diagnostic with no fixed length. ", count: 300))
      ])
    let notice = ThreadErrorNotice(
      error: failure.message, failure: failure, remedy: nil, perform: { _ in }, dismiss: {},
      detailsExpanded: true)
    let controller = NSHostingController(rootView: notice)
    for proposal in [CGSize.zero, CGSize(width: 340, height: 0), CGSize(width: 640, height: 0)] {
      let size = controller.sizeThatFits(in: proposal)
      #expect(size.height < 300, "expanded diagnostics exceed the window budget: \(size)")
    }
  }

  @Test(arguments: [CGFloat(340), 640], [false, true])
  func recoveryNoticeFitsAndRenders(_ width: CGFloat, expanded: Bool) async throws {
    let id = "01900000-0000-7000-8000-000000000001"
    let failure = WorkspaceError(
      .protocolInvalid,
      "This Codex session is archived. Run `codex unarchive \(id)` in Terminal, then choose Check again. Your transcript and draft are preserved.",
      details: [
        "reason": "native_session_archived",
        "nativeMessage": .string(
          "session \(id) is archived. Run `codex unarchive \(id)` to unarchive it first."),
      ])
    let remedy = Remediation.for(failure, connection: nil)
    let notice = ThreadErrorNotice(
      error: failure.message, failure: failure, remedy: remedy, perform: { _ in }, dismiss: {},
      detailsExpanded: expanded)
    let controller = NSHostingController(rootView: notice)
    let size = controller.sizeThatFits(in: CGSize(width: width, height: 0))
    #expect(size.width <= width, "notice exceeds its available width: \(size)")
    #expect(size.height > 80 && size.height < 240, "notice clips or exceeds its budget: \(size)")
    let minimum = controller.sizeThatFits(in: .zero)
    #expect(minimum.height < 300, "notice forces the whole window taller: \(minimum)")
    guard let directory = ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let window = SnapshotWindow(
      rootView: notice.padding(LLA.Space.l).frame(width: width + 32, height: 340, alignment: .top)
        .background(LLA.Color.bg).tint(LLA.Color.accent).ignoresSafeArea(),
      size: CGSize(width: width + 32, height: 340))
    defer { window.close() }
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      window.appearance = NSAppearance(named: appearance)
      let state = expanded ? "expanded" : "collapsed"
      try await window.capture(to: "\(directory)/recovery-\(Int(width))-\(state)-\(suffix).png")
    }
  }
}
