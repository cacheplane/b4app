import AppKit
import SwiftUI
import Testing

@testable import WorkspaceUI

/// Debug aid: the ideal size SwiftUI reports for the root and its pieces, as the window sizing
/// path sees it. Enabled with B4APP_SNAPSHOT_DIR like the snapshots.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["B4APP_SNAPSHOT_DIR"] != nil))
@MainActor struct IdealSizeTests {
  @Test func printsFittingSizes() async throws {
    let h = try await ModelHarness.start()
    defer { Task { await h.stop() } }
    let model = h.model
    func size<V: View>(_ label: String, _ view: V) {
      let host = NSHostingView(rootView: view)
      host.layoutSubtreeIfNeeded()
      print("IDEAL \(label): fitting=\(host.fittingSize) intrinsic=\(host.intrinsicContentSize)")
    }
    size("root", WorkspaceRootView(model: model))
    size(
      "split(sidebar, text)",
      NavigationSplitView {
        SidebarView(model: model)
      } detail: {
        Text("d")
      })
    size(
      "split(text, threads)",
      NavigationSplitView {
        Text("s")
      } detail: {
        ThreadsView(model: model)
      })
    size(
      "split(text, text)",
      NavigationSplitView {
        Text("s")
      } detail: {
        Text("d")
      })
    size("sidebar alone", SidebarView(model: model))
    size("threads alone", ThreadsView(model: model))
    size("empty state alone", LLAEmptyState("T", text: "x"))
    size(
      "split(scroll, text)",
      NavigationSplitView {
        ScrollView { Text("s") }
      } detail: {
        Text("d")
      })
  }
}
