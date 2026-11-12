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
    /// How tall the panel's content is now.
    var height: CGFloat = 500
  }

  /// The panel's content, a view of its own so it follows the state as a palette follows its model.
  private struct PanelBody: View {
    let state: PanelState
    var body: some View { Color.white.frame(height: state.height) }
  }

  private struct PanelHost: View {
    let state: PanelState
    static let size = CGSize(width: 420, height: 500)

    var body: some View {
      if state.mounted { presenter } else { Color.clear }
    }

    private var presenter: some View {
      Color.clear
        .background(
          FloatingPanel(
            isPresented: state.shown, size: Self.size, placement: .top(96), draggable: true,
            dismiss: {
              state.dismissed += 1
              state.shown = false
            }
          ) {
            PanelBody(state: state)
          })
    }
  }

  /// Where a released panel rests, and how it is kept on the screen.
  @Suite struct FloatingPanelGeometryTests {
    private let home = CGPoint(x: 400, y: 900)

    @Test func aLineDrawsAPanelLightlyAndOnlyWhenItIsNear() {
      let line: CGFloat = 400
      // Out of reach: exactly where it was taken.
      #expect(FloatingPanelGeometry.drawn(424, toward: line) == 424)
      #expect(FloatingPanelGeometry.drawn(460, toward: line) == 460)
      #expect(FloatingPanelGeometry.drawn(340, toward: line) == 340)
      // In reach: nearer the line than it was taken, and not on it.
      let half = FloatingPanelGeometry.drawn(412, toward: line)
      #expect(half > 406 && half < 410)
      #expect(FloatingPanelGeometry.drawn(388, toward: line) == 800 - half)
      // Light: most of the way out, the pull is a point or two.
      #expect(FloatingPanelGeometry.drawn(420, toward: line) > 417)
      // Close: on the line.
      #expect(FloatingPanelGeometry.drawn(403, toward: line) == line)
      #expect(FloatingPanelGeometry.drawn(399, toward: line) == line)
      // Nothing jumps and nothing holds: as the pointer moves away, so does the panel, all the way.
      var last = line
      for step in 4...60 {
        let drawn = FloatingPanelGeometry.drawn(line + CGFloat(step) / 2, toward: line)
        #expect(drawn >= last && drawn - last < 1.5)
        last = drawn
      }
    }

    @Test func theLineDownTheMiddleAndTheLinesAcrossDrawByThemselves() {
      // The line down the middle is at 400; the lines across are where the panel opens (900) and the
      // middle of the window (600).
      func snapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        FloatingPanelGeometry.snapped(CGPoint(x: x, y: y), centre: 400, heights: [900, 600])
      }
      // On the line down the middle, free along it.
      #expect(snapped(402, 760) == CGPoint(x: 400, y: 760))
      #expect(snapped(402, 700) == CGPoint(x: 400, y: 700))
      // On the line across the middle, free across it.
      #expect(snapped(120, 601) == CGPoint(x: 120, y: 600))
      #expect(snapped(733, 601) == CGPoint(x: 733, y: 600))
      // Where they cross, both.
      #expect(snapped(401, 598) == CGPoint(x: 400, y: 600))
      // Where it opens is a height too, so it can be put back.
      #expect(snapped(398, 902) == CGPoint(x: 400, y: 900))
      // Away from all of them, nothing.
      #expect(snapped(520, 760) == CGPoint(x: 520, y: 760))
    }

    @Test func aPanelIsKeptWhollyOnItsScreen() {
      let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
      let size = CGSize(width: 600, height: 300)
      #expect(
        FloatingPanelGeometry.clamped(CGPoint(x: 100, y: 500), size: size, visible: visible)
          == CGPoint(x: 100, y: 500))
      #expect(
        FloatingPanelGeometry.clamped(CGPoint(x: -50, y: 2000), size: size, visible: visible)
          == CGPoint(x: 0, y: 900))
      #expect(
        FloatingPanelGeometry.clamped(CGPoint(x: 1200, y: 100), size: size, visible: visible)
          == CGPoint(x: 840, y: 340))
      #expect(
        FloatingPanelGeometry.frame(topLeft: CGPoint(x: 100, y: 500), size: size)
          == CGRect(x: 100, y: 200, width: 600, height: 300))
    }
  }

  /// The Mac's palettes are presented in a panel attached to the window, so a short window does not
  /// cut them. These drive a real window and panel; what a key or a drag does is the smoke suite's.
  @Suite(.serialized) @MainActor struct FloatingPanelTests {
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private func settle() async throws {
      for _ in 0..<8 {
        pump()
        try await Task.sleep(for: .milliseconds(40))
      }
    }

    /// A window shorter than the panel, placed mid-screen so nothing is clamped by the screen's edge.
    private func shortWindow(_ state: PanelState) throws -> SnapshotWindow<PanelHost> {
      let window = SnapshotWindow(
        rootView: PanelHost(state: state), untitled: true, size: CGSize(width: 900, height: 300))
      let visible = try #require(window.window.screen ?? NSScreen.main).visibleFrame
      window.window.setFrameOrigin(NSPoint(x: visible.midX - 450, y: visible.maxY - 320))
      return window
    }

    @Test func aPanelIsItsContentsSizeOverTheWindowAndIsNotCutByIt() async throws {
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
      // The window server draws the shadow, from a window that is exactly the content.
      #expect(panel.hasShadow && !panel.isOpaque)
      #expect(abs(panel.frame.width - PanelHost.size.width) < 0.5)
      #expect(abs(panel.frame.height - 500) < 0.5)
      // Centred across the window, its top 96 pt under the window's top.
      #expect(abs(panel.frame.midX - host.window.frame.midX) < 0.5)
      let top = host.window.frame.maxY - 96
      #expect(abs(panel.frame.maxY - top) < 0.5)
      // It reaches below a window too short to hold it.
      #expect(panel.frame.minY < host.window.frame.minY)

      // The content shrinks and grows: the panel is that size at once, and its top does not move.
      state.height = 180
      try await settle()
      #expect(abs(panel.frame.height - 180) < 0.5)
      #expect(abs(panel.frame.maxY - top) < 0.5)
      state.height = 360
      try await settle()
      #expect(abs(panel.frame.height - 360) < 0.5)
      #expect(abs(panel.frame.maxY - top) < 0.5)

      // The window is resized: the panel stays centred on it.
      var frame = host.window.frame
      frame.size.width = 1100
      host.window.setFrame(frame, display: true)
      try await settle()
      #expect(abs(panel.frame.midX - host.window.frame.midX) < 0.5)

      // It goes with its presentation, and leaves nothing behind.
      state.shown = false
      try await settle()
      #expect((host.window.childWindows ?? []).isEmpty)
      #expect(!panel.isVisible)
      #expect(state.dismissed == 0)
    }

    @Test func aPanelOpensAtHomeEveryTime() async throws {
      let state = PanelState()
      let host = try shortWindow(state)
      defer { host.window.close() }
      state.shown = true
      try await settle()
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      let home = panel.frame.origin
      // As a drag leaves it, far from home.
      panel.setFrameOrigin(CGPoint(x: home.x + 200, y: home.y - 120))
      panel.dragEnded()
      try await settle()
      #expect(abs(panel.frame.origin.x - home.x - 200) < 0.5)
      state.shown = false
      try await settle()
      state.shown = true
      try await settle()
      let again = try #require(host.window.childWindows?.first)
      #expect(abs(again.frame.origin.x - home.x) < 0.5)
      #expect(abs(again.frame.origin.y - home.y) < 0.5)
      state.shown = false
      try await settle()
    }

    @Test func aDraggedPanelIsDrawnToEachLineByItselfAndADoubleClickSendsItHome() async throws {
      let state = PanelState()
      let host = try shortWindow(state)
      defer { host.window.close() }
      state.shown = true
      try await settle()
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      let home = panel.frame.origin
      // What a drag asks for, and what the panel does with it. The window is 300 tall and the panel
      // 500, so the middle line's height is 196 pt above where the panel opens.
      #expect(panel.snap(CGPoint(x: home.x + 2, y: home.y - 2)) == home)
      #expect(panel.snap(CGPoint(x: home.x + 2, y: home.y - 140)) == CGPoint(x: home.x, y: home.y - 140))
      #expect(panel.snap(CGPoint(x: home.x + 210, y: home.y + 2)) == CGPoint(x: home.x + 210, y: home.y))
      #expect(
        panel.snap(CGPoint(x: home.x + 210, y: home.y + 197)) == CGPoint(x: home.x + 210, y: home.y + 196))
      #expect(panel.snap(CGPoint(x: home.x - 1, y: home.y + 195)) == CGPoint(x: home.x, y: home.y + 196))
      #expect(
        panel.snap(CGPoint(x: home.x + 40, y: home.y - 60)) == CGPoint(x: home.x + 40, y: home.y - 60))
      let near = panel.snap(CGPoint(x: home.x + 12, y: home.y - 60))
      #expect(near.x > home.x + 6 && near.x < home.x + 10 && near.y == home.y - 60)
      // Left on the line down the middle, lower: it stays there.
      panel.setFrameOrigin(panel.snap(CGPoint(x: home.x - 2, y: home.y - 150)))
      panel.dragEnded()
      try await settle()
      #expect(abs(panel.frame.origin.x - home.x) < 0.5)
      #expect(abs(panel.frame.origin.y - home.y + 150) < 0.5)
      // Far away it stays, until a double click on a drag area.
      panel.setFrameOrigin(CGPoint(x: home.x - 260, y: home.y - 150))
      panel.dragEnded()
      try await settle()
      #expect(abs(panel.frame.origin.x - home.x + 260) < 0.5)
      panel.resetRequested()
      try await settle()
      #expect(abs(panel.frame.origin.x - home.x) < 0.5)
      #expect(abs(panel.frame.origin.y - home.y) < 0.5)
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

#if os(macOS)
  /// The title bar's resting control is the palette's top row, as wide as the palette where the
  /// window has the room.
  @Suite @MainActor struct CommandCenterTests {
    @Test func theRestingControlIsThePalettesWidthWhereTheWindowHasRoom() {
      #expect(CommandCenterButton.height == MacPalette.fieldHeight)
      #expect(CommandCenterButton.width(inWindow: 1200) == MacPalette.width)
      #expect(CommandCenterButton.width(inWindow: 1140) == MacPalette.width)
      // Narrower windows keep the title bar's own buttons clear.
      #expect(CommandCenterButton.width(inWindow: 1000) == 460)
      #expect(CommandCenterButton.width(inWindow: 900) == 360)
      #expect(CommandCenterButton.width(inWindow: 700) == CommandCenterButton.minWidth)
    }
  }
#endif
