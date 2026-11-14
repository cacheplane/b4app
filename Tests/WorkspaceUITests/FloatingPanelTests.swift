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
    /// Where the panel was left, as the app keeps it between openings; nil while `remembers` is false.
    var offset: CGSize?
    var remembers = false
    /// The content is a text field, as a palette's header is, and not a drag area.
    var field = false
    var text = ""
  }

  /// The panel's content, a view of its own so it follows the state as a palette follows its model.
  private struct PanelBody: View {
    let state: PanelState
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
      if state.field {
        @Bindable var state = state
        // A palette's header as the app builds it: a chip, the field with its selection and its
        // keys, a hint, and the drag area behind them all.
        HStack(spacing: 8) {
          Text("Commands").font(.caption)
          TextField("Run a command", text: $state.text, selection: $selection)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit { focused = true }
            .onKeyPress(.downArrow) { .handled }
            .onKeyPress(.escape) { .handled }
            .onKeyPress(keys: [.tab]) { _ in .handled }
            .accessibilityIdentifier("palette-field")
          Text("esc").font(.caption)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background { WindowDragArea() }
        .frame(maxHeight: state.height, alignment: .top)
        .background(Color.white)
        .onAppear { focused = true }
      } else {
        WindowDragArea().frame(height: state.height).background(Color.white)
      }
    }
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
            offset: state.remembers ? state.offset : nil,
            remember: state.remembers ? { state.offset = $0 } : nil,
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
      #expect(FloatingPanelGeometry.drawn(440, toward: line) == 440)
      #expect(FloatingPanelGeometry.drawn(460, toward: line) == 460)
      #expect(FloatingPanelGeometry.drawn(340, toward: line) == 340)
      // In reach: nearer the line than it was taken, and not on it.
      let half = FloatingPanelGeometry.drawn(412, toward: line)
      #expect(half > 400 && half < 403)
      #expect(FloatingPanelGeometry.drawn(388, toward: line) == 800 - half)
      // Felt well before the line: at 20 pt it has been drawn 14 pt in.
      let far = FloatingPanelGeometry.drawn(420, toward: line)
      #expect(far > 404 && far < 408)
      // Close: on the line, and held there over a few points of the pointer's travel.
      #expect(FloatingPanelGeometry.drawn(408, toward: line) == line)
      #expect(FloatingPanelGeometry.drawn(405, toward: line) == line)
      #expect(FloatingPanelGeometry.drawn(395, toward: line) == line)
      #expect(FloatingPanelGeometry.drawn(403, toward: line) == line)
      #expect(FloatingPanelGeometry.drawn(399, toward: line) == line)
      // Nothing jumps: past the hold, as the pointer moves away so does the panel, all the way.
      var last = line
      for step in 16...90 {
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

    @Test func whereThePanelOpensDrawsItFromEverySide() {
      let home = CGPoint(x: 400, y: 900)
      func snapped(_ x: CGFloat, _ y: CGFloat, home: CGPoint?) -> CGPoint {
        FloatingPanelGeometry.snapped(CGPoint(x: x, y: y), centre: 400, heights: [900, 600], home: home)
      }
      // Off both lines' holds, from a diagonal: the point takes it home; the lines alone would not.
      #expect(snapped(430, 880, home: home) == home)
      #expect(snapped(375, 925, home: home) == home)
      #expect(snapped(430, 880, home: nil) != home)
      // Further off it is drawn towards home, not onto it.
      let near = FloatingPanelGeometry.drawn(CGPoint(x: 450, y: 860), towardPoint: home)
      #expect(near.x > 400 && near.x < 450 && near.y > 860 && near.y < 900)
      #expect(abs((near.x - 400) / (900 - near.y) - 50 / 40) < 0.001)
      // Out of its reach, nothing.
      #expect(snapped(470, 840, home: home) == CGPoint(x: 470, y: 840))
      // Nothing jumps on the way out.
      var last: CGFloat = 0
      for step in 28...160 {
        let distance = CGFloat(step) / 2
        let drawn = FloatingPanelGeometry.drawn(CGPoint(x: 400 + distance, y: 900), towardPoint: home)
        #expect(drawn.x - 400 >= last && drawn.x - 400 - last < 1.5)
        last = drawn.x - 400
      }
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
    /// One short turn of the run loop. Short, because nothing else on the main actor runs meanwhile:
    /// these tests ran beside the whole package on CI, and their longer turns held other suites'
    /// requests past the client's 15 second timeout.
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }

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
        panel.snap(CGPoint(x: home.x + 60, y: home.y - 70)) == CGPoint(x: home.x + 60, y: home.y - 70))
      let near = panel.snap(CGPoint(x: home.x + 20, y: home.y - 140))
      #expect(near.x > home.x + 4 && near.x < home.x + 8 && near.y == home.y - 140)
      // Near where it opens, from a diagonal: home.
      #expect(panel.snap(CGPoint(x: home.x + 25, y: home.y - 25)) == home)
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

    /// Left somewhere, the panel opens there the next time, and a double click forgets the place.
    @Test func aPanelOpensWhereItWasLastLeft() async throws {
      let state = PanelState()
      state.remembers = true
      let host = try shortWindow(state)
      defer { host.window.close() }
      state.shown = true
      try await settle()
      var panel = try #require(host.window.childWindows?.first as? PalettePanel)
      let home = panel.frame.origin
      panel.setFrameOrigin(CGPoint(x: home.x - 180, y: home.y - 90))
      panel.dragEnded()
      try await settle()
      #expect(state.offset == CGSize(width: -180, height: -90))
      state.shown = false
      try await settle()
      state.shown = true
      try await settle()
      panel = try #require(host.window.childWindows?.first as? PalettePanel)
      // Where it was left, as far as the screen allows (a small screen cuts the way down short).
      let visible = try #require(host.window.screen ?? NSScreen.main).visibleFrame
      let left = FloatingPanelGeometry.clamped(
        CGPoint(x: home.x - 180, y: home.y + panel.frame.height - 90), size: panel.frame.size,
        visible: visible)
      #expect(abs(panel.frame.minX - left.x) < 0.5)
      #expect(abs(panel.frame.maxY - left.y) < 0.5)
      #expect(abs(panel.frame.minX - home.x) > 100)
      // A double click on a drag area: home, now and next time.
      panel.resetRequested()
      try await settle()
      #expect(state.offset == nil)
      state.shown = false
      try await settle()
      state.shown = true
      try await settle()
      panel = try #require(host.window.childWindows?.first as? PalettePanel)
      #expect(abs(panel.frame.origin.x - home.x) < 0.5)
      #expect(abs(panel.frame.origin.y - home.y) < 0.5)
      state.shown = false
      try await settle()
    }

    /// A press, a drag, and a release, as the window server sends them, with the pointer at `screen`.
    private func send(_ type: NSEvent.EventType, at screen: CGPoint, to panel: PalettePanel) throws {
      // The replayed events say where the pointer is; the real pointer is wherever the owner left it.
      panel.pointer = { [unowned panel] event in panel.convertPoint(toScreen: event.locationInWindow) }
      let inWindow = CGPoint(x: screen.x - panel.frame.minX, y: screen.y - panel.frame.minY)
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
      panel.sendEvent(event)
    }

    /// The panel goes where the pointer takes it on every step of a drag, however often its window
    /// lays out in between. (It used to be put back where it opens by each layout, and the pointer and
    /// the layout fought over it: the drag the owner called jittery.)
    @Test func aDragIsNeverFoughtByTheWindowsLayout() async throws {
      let state = PanelState()
      let host = try shortWindow(state)
      defer { host.window.close() }
      state.shown = true
      try await settle()
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      let home = panel.frame.origin
      let grip = CGPoint(x: panel.frame.minX + 60, y: panel.frame.maxY - 20)
      try send(.leftMouseDown, at: grip, to: panel)
      var path: [CGPoint] = []
      for step in 1...40 {
        // Away from every line: 5 pt right and 1 pt down each step.
        let pointer = CGPoint(x: grip.x + CGFloat(step) * 5, y: grip.y - CGFloat(step))
        try send(.leftMouseDragged, at: pointer, to: panel)
        // What AppKit does between events in a running app: the window updates, and lays out.
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: host.window)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: host.window)
        pump()
        path.append(panel.frame.origin)
      }
      try send(.leftMouseUp, at: CGPoint(x: grip.x + 200, y: grip.y - 40), to: panel)
      try await settle()
      // Every step moved it on, never back; out of reach of the lines it is exactly under the pointer.
      // (Near where it opens it is held there, so the first steps may not move it; it never goes back.)
      for (index, (before, after)) in zip(path, path.dropFirst()).enumerated() {
        #expect(after.x >= before.x, "went back across: \(before) then \(after)")
        if index >= 16 { #expect(after.x > before.x, "stood still out of reach: \(before) then \(after)") }
        #expect(after.y < before.y + 0.01, "went back up: \(before) then \(after)")
      }
      #expect(abs(path[39].x - home.x - 200) < 0.5)
      #expect(abs(path[39].y - home.y + 40) < 0.5)
      #expect(abs(path[19].x - home.x - 100) < 0.5)
      // Released, it is still where it was left.
      #expect(abs(panel.frame.origin.x - home.x - 200) < 0.5)
      #expect(abs(panel.frame.origin.y - home.y + 40) < 0.5)
      state.shown = false
      try await settle()
    }

    /// The empty part of a palette's field drags it, with the cursor in the field (as it always is in
    /// an open palette): the press lands on the field's editor, not on the field.
    @Test func theEmptyPartOfAFocusedFieldDragsThePanel() async throws {
      let state = PanelState()
      state.field = true
      let host = try shortWindow(state)
      defer { host.window.close() }
      state.shown = true
      try await settle()
      try await settle()
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      let home = panel.frame.origin
      // 70% along the field's row, as the screen test presses.
      let grip = CGPoint(x: panel.frame.minX + panel.frame.width * 0.7, y: panel.frame.maxY - 18)
      let hit = panel.contentView?.hitTest(
        CGPoint(x: grip.x - panel.frame.minX, y: grip.y - panel.frame.minY))
      let what =
        "pressed on \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), first responder "
        + "\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
      try send(.leftMouseDown, at: grip, to: panel)
      for step in 1...20 {
        try send(
          .leftMouseDragged, at: CGPoint(x: grip.x + CGFloat(step) * 9, y: grip.y - CGFloat(step) * 6.5),
          to: panel)
        pump()
      }
      try send(.leftMouseUp, at: CGPoint(x: grip.x + 180, y: grip.y - 130), to: panel)
      try await settle()
      #expect(abs(panel.frame.origin.x - home.x - 180) < 0.5, "\(what)")
      #expect(abs(panel.frame.origin.y - home.y + 130) < 0.5, "\(what)")
      state.shown = false
      try await settle()
    }

    /// The panel ends a drag where the pointer was released, when no drag event came from there: a
    /// busy machine drops the last ones, and CI's screen test found the palette one step short.
    @Test func aDragEndsWhereThePointerIsReleased() async throws {
      let state = PanelState()
      let host = try shortWindow(state)
      defer { host.window.close() }
      state.shown = true
      try await settle()
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      let home = panel.frame.origin
      let grip = CGPoint(x: panel.frame.minX + 60, y: panel.frame.maxY - 20)
      try send(.leftMouseDown, at: grip, to: panel)
      // Fourteen of fifteen steps arrive; the release is at the fifteenth.
      for step in 1...14 {
        try send(
          .leftMouseDragged, at: CGPoint(x: grip.x + CGFloat(step) * 12, y: grip.y - CGFloat(step) * 9),
          to: panel)
        pump()
      }
      try send(.leftMouseUp, at: CGPoint(x: grip.x + 180, y: grip.y - 135), to: panel)
      try await settle()
      #expect(abs(panel.frame.origin.x - home.x - 180) < 0.5)
      #expect(abs(panel.frame.origin.y - home.y + 135) < 0.5)
      state.shown = false
      try await settle()
    }

    /// The real palette, in its panel, is dragged by the empty part of its field, by its header's
    /// glyph, and by its footer; a click on the field's empty part still puts the cursor in it. In
    /// the palette's header SwiftUI answers for every spot, so a press there hits the hosting view
    /// and neither the field nor the drag area behind it: CI's screen test found the palette could
    /// not be dragged by its field at all.
    @Test func thePaletteIsDraggedByItsFieldAndItsHeader() async throws {
      let model = WorkspaceModel(transportProvider: { ScriptedTransport() })
      model.presentPalette(.commands)
      let host = SnapshotWindow(
        rootView: Color.clear.background(
          FloatingPanel(
            isPresented: model.showSearch,
            size: CGSize(width: MacPalette.width, height: MacPalette.fullHeight),
            placement: .top(40), cornerRadius: MacPalette.radius, continuousCorners: false, draggable: true,
            dismiss: {}
          ) { PaletteView(model: model, floating: true) }),
        untitled: true, size: CGSize(width: 900, height: 300))
      defer { host.close() }
      let visible = try #require(host.window.screen ?? NSScreen.main).visibleFrame
      host.window.setFrameOrigin(NSPoint(x: visible.midX - 450, y: visible.maxY - 320))
      for _ in 0..<16 {
        pump()
        try await Task.sleep(for: .milliseconds(40))
      }
      let panel = try #require(host.window.childWindows?.first as? PalettePanel)
      panel.pointer = { [unowned panel] event in panel.convertPoint(toScreen: event.locationInWindow) }
      func send(_ type: NSEvent.EventType, _ screen: CGPoint) throws {
        let inWindow = CGPoint(x: screen.x - panel.frame.minX, y: screen.y - panel.frame.minY)
        panel.sendEvent(
          try #require(
            NSEvent.mouseEvent(
              with: type, location: inWindow, modifierFlags: [],
              timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
      }
      /// Press at a spot in the panel (from its left and its top), drag by `by`, release.
      func drag(fromLeft x: CGFloat, fromTop y: CGFloat, by: CGSize) throws {
        let grip = CGPoint(x: panel.frame.minX + x, y: panel.frame.maxY - y)
        try send(.leftMouseDown, grip)
        for step in 1...10 {
          let part = CGFloat(step) / 10
          try send(.leftMouseDragged, CGPoint(x: grip.x + by.width * part, y: grip.y + by.height * part))
          pump()
        }
        try send(.leftMouseUp, CGPoint(x: grip.x + by.width, y: grip.y + by.height))
        pump()
      }
      var before = panel.frame.origin
      // 70% along the field, where there is no text: as the screen test presses.
      try drag(fromLeft: 420, fromTop: 18, by: CGSize(width: 150, height: -100))
      #expect(abs(panel.frame.origin.x - before.x - 150) < 0.5, "the field's empty part did not drag it")
      #expect(abs(panel.frame.origin.y - before.y + 100) < 0.5)
      // The header's leading end, on the purpose's chip.
      before = panel.frame.origin
      try drag(fromLeft: 30, fromTop: 18, by: CGSize(width: -80, height: -30))
      #expect(abs(panel.frame.origin.x - before.x + 80) < 0.5, "the header's leading end did not drag it")
      // The footer's middle.
      before = panel.frame.origin
      try drag(fromLeft: 300, fromTop: panel.frame.height - 20, by: CGSize(width: 60, height: 40))
      #expect(abs(panel.frame.origin.x - before.x - 60) < 0.5, "the footer did not drag it")
      // A row is not a handle.
      before = panel.frame.origin
      try drag(fromLeft: 300, fromTop: 120, by: CGSize(width: 60, height: 40))
      #expect(panel.frame.origin == before, "a row dragged it")
      // A click on the field's empty part is a click: nothing moves, and the cursor is in the field.
      let grip = CGPoint(x: panel.frame.minX + 420, y: panel.frame.maxY - 18)
      try send(.leftMouseDown, grip)
      try send(.leftMouseUp, grip)
      pump()
      #expect(panel.frame.origin == before)
      #expect(panel.firstResponder is NSTextView)
      model.dismissPalette()
      for _ in 0..<6 { pump() }
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
