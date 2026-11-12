#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI
  import Testing

  @testable import WorkspaceUI

  @MainActor @Observable private final class PanelState {
    var shown = false
    var dismissed = 0
    /// The view that presents the panel is in the window.
    var mounted = true
  }

  private struct PanelHost: View {
    let state: PanelState
    var rememberAs: String?
    static let size = CGSize(width: 420, height: 500)

    var body: some View {
      if state.mounted { presenter } else { Color.clear }
    }

    private var presenter: some View {
      Color.clear
        .background(
          FloatingPanel(
            isPresented: state.shown, size: Self.size, placement: .top(96), rememberAs: rememberAs,
            dismiss: {
              state.dismissed += 1
              state.shown = false
            }
          ) {
            Text("In the panel").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)
          })
    }
  }

  /// The Mac's palettes are presented in a panel attached to the window, so a short window does not
  /// cut them. These drive a real window and panel; what a key or a drag does is checked by hand.
  @Suite(.serialized) @MainActor struct FloatingPanelTests {
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func settle() async throws {
      for _ in 0..<8 {
        pump()
        try await Task.sleep(for: .milliseconds(40))
      }
    }

    /// A window shorter than the panel, placed mid-screen so nothing is clamped by the screen's edge.
    private func shortWindow(
      _ state: PanelState, rememberAs: String? = nil
    ) throws -> SnapshotWindow<PanelHost> {
      let window = SnapshotWindow(
        rootView: PanelHost(state: state, rememberAs: rememberAs), untitled: true,
        size: CGSize(width: 900, height: 300))
      let visible = try #require(window.window.screen ?? NSScreen.main).visibleFrame
      window.window.setFrameOrigin(NSPoint(x: visible.midX - 450, y: visible.maxY - 320))
      return window
    }

    @Test func aPanelOpensOverTheWindowAndIsNotCutByIt() async throws {
      let state = PanelState()
      let host = try shortWindow(state)
      defer { host.window.close() }
      try await settle()
      #expect((host.window.childWindows ?? []).isEmpty)

      state.shown = true
      try await settle()
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      #expect(host.window.childWindows?.count == 1)
      #expect(panel.canBecomeKey && !panel.canBecomeMain)
      #expect(!panel.isOpaque && !panel.hasShadow)
      let margin = FloatingPanel<Text>.margin
      let content = panel.frame.insetBy(dx: margin, dy: margin)
      // The content: its own size, centred across the window, its top 96 pt under the window's top.
      #expect(abs(content.width - PanelHost.size.width) < 0.5)
      #expect(abs(content.height - PanelHost.size.height) < 0.5)
      #expect(abs(content.midX - host.window.frame.midX) < 0.5)
      #expect(abs(content.maxY - (host.window.frame.maxY - 96)) < 0.5)
      // It reaches below a window too short to hold it.
      #expect(content.minY < host.window.frame.minY)

      // It goes with its presentation, and leaves nothing behind.
      state.shown = false
      try await settle()
      #expect((host.window.childWindows ?? []).isEmpty)
      #expect(!panel.isVisible)
      #expect(state.dismissed == 0)
    }

    @Test func aRememberedPanelOpensWhereItWasLeft() async throws {
      let state = PanelState()
      let host = try shortWindow(state, rememberAs: "test-panel")
      defer {
        host.window.close()
        FloatingPanelMemory.offsets["test-panel"] = nil
      }
      state.shown = true
      try await settle()
      let first = try #require(host.window.childWindows?.first).frame.origin
      state.shown = false
      try await settle()

      // As a drag leaves it: 40 pt right and 30 pt down from where it opens.
      FloatingPanelMemory.offsets["test-panel"] = CGSize(width: 40, height: -30)
      state.shown = true
      try await settle()
      let second = try #require(host.window.childWindows?.first).frame.origin
      #expect(abs(second.x - first.x - 40) < 0.5)
      #expect(abs(second.y - first.y + 30) < 0.5)
      state.shown = false
      try await settle()
    }

    @Test func aPanelLeavesWithTheViewThatPresentsIt() async throws {
      let state = PanelState()
      let host = try shortWindow(state)
      state.shown = true
      try await settle()
      let panel = try #require(host.window.childWindows?.first)
      // Its screen goes away with the panel still asked for (the owner moved to another thread).
      state.mounted = false
      try await settle()
      #expect(!panel.isVisible)
      #expect((host.window.childWindows ?? []).isEmpty)
      host.window.close()
    }
  }
#endif
