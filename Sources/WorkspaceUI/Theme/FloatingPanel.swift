#if os(macOS)
  import AppKit
  import SwiftUI

  extension EnvironmentValues {
    /// The Mac's palettes are shown in panels of their own (`FloatingPanel`), so they are not cut by
    /// a small window. The app's root sets it; a view drawn without it (a snapshot, a preview) keeps
    /// its palette inside itself.
    @Entry var floatsPalettes = false
    /// The view is the content of a `FloatingPanel`: the window draws its shadow and its corners, so
    /// the view draws neither.
    @Entry var isInFloatingPanel = false
  }

  /// Where a panel opens over the view that presents it.
  nonisolated enum FloatingPanelPlacement: Sendable, Equatable {
    /// Centred across, its top this far under the view's top.
    case top(CGFloat)
    /// Centred both ways, as if it were at its tallest.
    case centered
  }

  /// The arithmetic of a panel's place: everything is the panel's top-left corner in screen points
  /// (y up), because the panel's height changes and its top is what stays put.
  nonisolated enum FloatingPanelGeometry {
    /// How far a line's pull reaches. Beyond it a dragged panel goes exactly where the pointer takes it.
    static let reach: CGFloat = 40
    /// How near a line the panel sits on it: a short stretch of the pointer's travel that does not
    /// move it, which is what says "it is on the line".
    static let hold: CGFloat = 8
    /// The same two figures for the point where the panel opens, which draws from every side and
    /// from further off than a line does, so the panel is easy to put back.
    static let pointReach: CGFloat = 72
    static let pointHold: CGFloat = 14
    /// How the pull grows from the edge of the reach to the hold: 1 would be no pull at all, larger
    /// is stronger.
    static let pull: CGFloat = 2
    /// How far the pointer travels before a press becomes a drag, so a click is never a nudge.
    static let dragThreshold: CGFloat = 3

    /// `value` drawn towards `line`. Outside `reach` it is itself. Within `hold` it is on the line.
    /// Between, its distance from the line shrinks, more the nearer it is (`reach` × t ^ `pull`, t
    /// running from 0 at the hold to 1 at the edge of the reach), so the panel is drawn onto the line
    /// as it comes close and leaves it as smoothly: nothing jumps, at the hold or at the edge.
    static func drawn(_ value: CGFloat, toward line: CGFloat) -> CGFloat {
      let distance = abs(value - line)
      guard let eased = eased(distance, reach: reach, hold: hold) else { return value }
      return line + (value < line ? -eased : eased)
    }

    /// `point` drawn towards `home` along the straight line between them, by the same rule with the
    /// point's own reach and hold.
    static func drawn(_ point: CGPoint, towardPoint home: CGPoint) -> CGPoint {
      let distance = hypot(point.x - home.x, point.y - home.y)
      guard let eased = eased(distance, reach: pointReach, hold: pointHold) else { return point }
      guard eased > 0 else { return home }
      let scale = eased / distance
      return CGPoint(x: home.x + (point.x - home.x) * scale, y: home.y + (point.y - home.y) * scale)
    }

    /// A distance from a line or a point, as it is drawn: nil beyond `reach` (it is itself), 0 within
    /// `hold` or when under half a point is left.
    private static func eased(_ distance: CGFloat, reach: CGFloat, hold: CGFloat) -> CGFloat? {
      guard distance < reach else { return nil }
      guard distance > hold else { return 0 }
      let eased = reach * pow((distance - hold) / (reach - hold), pull)
      return eased >= 0.5 ? eased : 0
    }

    /// Where a panel dragged to `topLeft` is drawn. Two lines cross the window, one down its middle
    /// and one across it, and each draws the panel by itself: near the line down the middle the panel
    /// drifts onto it and still moves freely up and down; near a line across (`heights`: the middle
    /// of the window, and where the panel opens) it drifts to that height and still moves freely from
    /// side to side. Where two cross, both draw it. `home`, where the panel opens, is a point as
    /// well: it draws the panel first, from any direction, and the lines draw what that leaves.
    static func snapped(
      _ topLeft: CGPoint, centre: CGFloat, heights: [CGFloat], home: CGPoint? = nil
    ) -> CGPoint {
      let near = home.map { drawn(topLeft, towardPoint: $0) } ?? topLeft
      let nearest = heights.min { abs($0 - near.y) < abs($1 - near.y) }
      return CGPoint(
        x: drawn(near.x, toward: centre),
        y: nearest.map { drawn(near.y, toward: $0) } ?? near.y)
    }

    /// `topLeft` moved so a panel of `size` is wholly on `visible`.
    static func clamped(_ topLeft: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
      CGPoint(
        x: min(max(topLeft.x, visible.minX), max(visible.maxX - size.width, visible.minX)),
        y: max(min(topLeft.y, visible.maxY), min(visible.minY + size.height, visible.maxY)))
    }

    /// The frame of a panel of `size` whose top-left corner is `topLeft`.
    static func frame(topLeft: CGPoint, size: CGSize) -> CGRect {
      CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }
  }

  /// A borderless panel that takes the keyboard without taking the app's main window away from the
  /// window under it, and that the owner can drag by its own content.
  ///
  /// A drag starts on a `WindowDragArea`, or on the empty part of a text field (past the end of its
  /// text), once the pointer has travelled `FloatingPanelGeometry.dragThreshold`. The panel moves
  /// itself, which is what lets it know when the drag ends (`NSWindow.performDrag` does not say). A
  /// press on a field that never becomes a drag is given to the field afterwards, as the click it was.
  final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isDraggable = false
    /// The pointer came up after a drag.
    var dragEnded: () -> Void = {}
    /// Where the panel is drawn when a drag would put its frame's origin at the given point: the
    /// place itself, or a line of home's it is near enough to sit on.
    var snap: (CGPoint) -> CGPoint = { $0 }
    /// A double click on a drag area: go home.
    var resetRequested: () -> Void = {}
    /// Where the pointer is on the screen during a press or a drag. The pointer itself, not the
    /// event's place in the window: the window is moving under it, and on CI's screen a dragged
    /// event's place in a panel that had just moved did not follow the pointer, so the panel never
    /// left. A test that replays events gives their places instead.
    var pointer: (NSEvent) -> CGPoint = { _ in NSEvent.mouseLocation }

    private struct Press {
      var down: NSEvent
      var pointer: CGPoint
      var origin: CGPoint
      /// The press landed on a field, which gets it back if it does not become a drag.
      var onField: Bool
      var moving = false
    }
    private var press: Press?

    /// The owner is moving the panel now: its place is theirs until the pointer comes up.
    var isBeingDragged: Bool { press?.moving == true }

    override func sendEvent(_ event: NSEvent) {
      guard isDraggable else { return super.sendEvent(event) }
      switch event.type {
      case .leftMouseDown:
        guard let onField = dragStart(event) else { break }
        if !onField, event.clickCount == 2 {
          resetRequested()
          return
        }
        press = Press(
          down: event, pointer: pointer(event), origin: frame.origin,
          onField: onField)
        return
      case .leftMouseDragged:
        guard var current = press else { break }
        let pointer = pointer(event)
        let travel = CGSize(width: pointer.x - current.pointer.x, height: pointer.y - current.pointer.y)
        if !current.moving, hypot(travel.width, travel.height) > FloatingPanelGeometry.dragThreshold {
          current.moving = true
        }
        if current.moving {
          // Measured from the press each time, not from where the panel is: a panel held on a line
          // leaves it as soon as the pointer has carried it far enough, and not before.
          setFrameOrigin(
            snap(CGPoint(x: current.origin.x + travel.width, y: current.origin.y + travel.height)))
        }
        press = current
        return
      case .leftMouseUp:
        guard let current = press else { break }
        press = nil
        if current.moving {
          dragEnded()
        } else if current.onField {
          // It was a click on the field's empty part: the cursor goes to the end of its text. (Giving
          // the field the press itself now would start its own tracking loop, with no release to end it.)
          clickPastText(current.down)
        }
        return
      default:
        break
      }
      super.sendEvent(event)
    }

    private func clickPastText(_ down: NSEvent) {
      guard let hit = text(at: down) else { return }
      if let field = hit as? NSTextField, firstResponder !== field.currentEditor() {
        makeFirstResponder(field)
      }
      if let editor = (hit as? NSTextView) ?? (hit as? NSTextField)?.currentEditor() as? NSTextView {
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
      }
    }

    /// The field or the field's editor under a press. The press may land on a view inside either (a
    /// clip view), depending on the system, so it is the nearest of the few views above the one hit.
    private func text(at event: NSEvent) -> NSView? {
      guard let hit = contentView?.hitTest(event.locationInWindow) else { return nil }
      return sequence(first: hit, next: \.superview).prefix(4).first { $0 is NSTextView || $0 is NSTextField }
    }

    /// Whether a press here can start a drag, and if so whether it is on a field: nil for a press on
    /// anything else (a row, a button, text in a field).
    private func dragStart(_ event: NSEvent) -> Bool? {
      guard let hit = contentView?.hitTest(event.locationInWindow) else { return nil }
      if hit is WindowDragArea.Handle { return false }
      guard let text = text(at: event) else { return nil }
      let point = text.convert(event.locationInWindow, from: nil)
      // The text's width is measured from the text itself, not asked of a layout manager: a field's
      // editor has one only under TextKit 1, and without it no press on a field ever began a drag.
      if let editor = text as? NSTextView {
        let written = editor.attributedString()
        let width = written.length == 0 ? 0 : written.size().width
        let end = editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0) + width
        return point.x > end + 6 ? true : nil
      }
      if let field = text as? NSTextField {
        let width = field.stringValue.isEmpty ? 0 : field.attributedStringValue.size().width
        return point.x > width + 6 ? true : nil
      }
      return nil
    }
  }

  /// Presents `content` in a panel over the window: attached to it (it moves with the window) but not
  /// clipped by it. The panel is exactly the size of its content, which it follows with its top edge
  /// held, and the window server draws its shadow, so nothing trails when a list grows or shrinks.
  /// Losing the keyboard (a click on the window, another app) calls `dismiss`.
  ///
  /// Put it in a `background` of the view to open over. `size` is the content's width and its height
  /// at its tallest, which places it. A `draggable` panel can be moved by its `WindowDragArea`s and by
  /// the empty part of a text field. While it is dragged, the line down the middle of the window and
  /// the lines across it (its middle, and where the panel opens) each draw it when it is near, and so does the point where it opens; a
  /// double click on a drag area sends it back. With `remember`, it opens where it was last left
  /// (`offset`, from where it would open otherwise); without, it opens at home every time.
  struct FloatingPanel<Content: View>: NSViewRepresentable {
    var isPresented: Bool
    var size: CGSize
    var placement: FloatingPanelPlacement
    var cornerRadius: CGFloat = LLA.Radius.card
    /// Continuous corners, as the app's cards have; false for a capsule's circular ones.
    var continuousCorners = true
    var draggable = false
    /// How far from home the owner left it last time, to open there again; nil for home.
    var offset: CGSize?
    /// The owner left it somewhere else (nil: at home), to be kept for the next time it opens.
    var remember: ((CGSize?) -> Void)?
    /// A rectangle on screen to open over instead (a button in the title bar): the panel is centred on
    /// it, with its middle `overInset` under the panel's top, so the panel's first row covers it.
    /// Without one (full screen, a window too narrow for the button), `placement` stands.
    var over: (@MainActor () -> CGRect?)?
    var overInset: CGFloat = 0
    /// False while something the content opened (a folder panel) has the keyboard: the panel stays.
    var dismissesOnResign = true
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> FloatingPanelCoordinator { FloatingPanelCoordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ anchor: NSView, context: Context) {
      let coordinator = context.coordinator
      coordinator.dismiss = dismiss
      let wasHolding = !coordinator.dismissesOnResign
      coordinator.dismissesOnResign = dismissesOnResign
      coordinator.remember = remember
      if isPresented {
        if coordinator.panel == nil {
          // The anchor has no window while its view is being inserted.
          let build = self
          DispatchQueue.main.async {
            guard build.isPresented else { return }
            coordinator.present(
              AnyView(build.content()), size: build.size, placement: build.placement,
              cornerRadius: build.cornerRadius, continuousCorners: build.continuousCorners,
              draggable: build.draggable, offset: build.offset, target: build.over,
              targetInset: build.overInset, over: anchor)
          }
        } else if wasHolding, dismissesOnResign {
          // What held the keyboard has gone: the panel takes it back.
          coordinator.panel?.makeKey()
        }
      } else {
        coordinator.close()
      }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: FloatingPanelCoordinator) {
      coordinator.close()
    }
  }

  @MainActor final class FloatingPanelCoordinator: NSObject, NSWindowDelegate {
    private(set) var panel: PalettePanel?
    var dismiss: () -> Void = {}
    var dismissesOnResign = true
    var remember: ((CGSize?) -> Void)?

    private weak var anchor: NSView?
    private var size = CGSize.zero
    private var placement = FloatingPanelPlacement.centered
    private var target: (@MainActor () -> CGRect?)?
    private var targetInset: CGFloat = 0
    /// How far the owner dragged it from where it opens; nil at home. Kept through the window's
    /// resizes, and handed to `remember` for the next time it opens.
    private var offset: CGSize?
    /// The content has been measured, so the panel is the right size to be seen.
    private var shown = false
    private var observers: [NSObjectProtocol] = []

    func present(
      _ content: AnyView, size: CGSize, placement: FloatingPanelPlacement, cornerRadius: CGFloat,
      continuousCorners: Bool = true,
      draggable: Bool, offset: CGSize? = nil, target: (@MainActor () -> CGRect?)? = nil,
      targetInset: CGFloat = 0,
      over anchor: NSView
    ) {
      guard panel == nil, let parent = anchor.window else { return }
      self.anchor = anchor
      anchor.postsFrameChangedNotifications = true
      self.size = size
      self.placement = placement
      self.target = target
      self.targetInset = targetInset
      self.offset = draggable ? offset : nil
      shown = false

      let panel = PalettePanel(
        contentRect: CGRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      // The window server's shadow, taken from the content's own (rounded) shape.
      panel.hasShadow = true
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.isMovable = false
      panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
      panel.appearance = parent.effectiveAppearance
      panel.animationBehavior = .none
      panel.isDraggable = draggable
      panel.dragEnded = { [weak self] in self?.dragEnded() }
      panel.snap = { [weak self] origin in self?.snapped(origin: origin) ?? origin }
      panel.resetRequested = { [weak self] in self?.goHome(animated: true) }
      panel.delegate = self

      let host = NSHostingView(
        rootView:
          content
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: size.width)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
            self?.contentHeight(height)
          }
          .frame(maxHeight: .infinity, alignment: .top)
          .environment(\.floatsPalettes, true)
          .environment(\.isInFloatingPanel, true))
      // The panel follows the content; the content must not size the panel behind its back.
      host.sizingOptions = []
      host.wantsLayer = true
      host.layer?.cornerRadius = cornerRadius
      host.layer?.cornerCurve = continuousCorners ? .continuous : .circular
      host.layer?.masksToBounds = true
      panel.contentView = host

      self.panel = panel
      place(height: size.height, animated: false)
      parent.addChildWindow(panel, ordered: .above)
      // Unseen until the content has been measured, but it has the keyboard from the start.
      panel.alphaValue = 0
      panel.makeKeyAndOrderFront(nil)

      let center = NotificationCenter.default
      observers = [
        // A child follows its window's moves, not its resizes: the presenting view's new frame (laid
        // out a moment after the window's) is where home is now.
        center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated {
            self?.reposition()
            DispatchQueue.main.async { self?.reposition() }
          }
        },
        center.addObserver(forName: NSView.frameDidChangeNotification, object: anchor, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.reposition() }
        },
        // The title bar lays its items out again without the window changing size (the sidebar
        // opening): home is asked for again whenever the window has drawn. Nothing moves when home has not.
        center.addObserver(forName: NSWindow.didUpdateNotification, object: parent, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.reposition() }
        },
        // Full screen moves the window's title bar into another window: the panel gives way.
        center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: parent, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.dismiss() }
        },
        center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: parent, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.dismiss() }
        },
      ]
    }

    func close() {
      guard let panel else { return }
      self.panel = nil
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers = []
      panel.delegate = nil
      let parent = panel.parent
      parent?.removeChildWindow(panel)
      panel.orderOut(nil)
      panel.contentView = nil
      // The window under it has the keyboard again, wherever the click or the key went.
      if let parent, parent.isVisible, NSApp.keyWindow == nil || NSApp.keyWindow === panel {
        parent.makeKey()
      }
    }

    func windowDidResignKey(_ notification: Notification) {
      guard dismissesOnResign, panel != nil else { return }
      dismiss()
    }

    // MARK: Place

    /// Where the panel opens: centred across the presenting view, its top where the placement says.
    var home: CGPoint? {
      guard let anchor, let parent = anchor.window else { return nil }
      // Over its target while that is on screen (in full screen the title bar's button is hidden).
      if let rect = target?(), rect.width > 0 {
        return CGPoint(x: rect.midX - size.width / 2, y: rect.midY + targetInset)
      }
      let onScreen = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
      let top: CGFloat
      switch placement {
      case .top(let below): top = onScreen.maxY - below
      case .centered: top = onScreen.midY + size.height / 2
      }
      return CGPoint(x: onScreen.midX - size.width / 2, y: top)
    }

    private var visible: CGRect? { (panel?.parent?.screen ?? panel?.screen ?? NSScreen.main)?.visibleFrame }

    /// Put the panel at home plus the owner's offset, `height` tall, with its top held.
    private func place(height: CGFloat, animated: Bool) {
      guard let panel, let home else { return }
      let panelSize = CGSize(width: size.width, height: height)
      var topLeft = CGPoint(x: home.x + (offset?.width ?? 0), y: home.y + (offset?.height ?? 0))
      // While it is dragged it is where the pointer has it, not where it was before the drag: only
      // its height may change under the owner's hand, with its top held.
      if panel.isBeingDragged { topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY) }
      if let visible { topLeft = FloatingPanelGeometry.clamped(topLeft, size: panelSize, visible: visible) }
      let frame = FloatingPanelGeometry.frame(topLeft: topLeft, size: panelSize)
      guard frame != panel.frame else { return }
      if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.16
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak panel] in
          MainActor.assumeIsolated { panel?.invalidateShadow() }
        }
      } else {
        panel.setFrame(frame, display: true)
        refreshShadow()
      }
    }

    /// The window resized, or its title bar laid out again: the panel goes to its place there. Not
    /// while it is being dragged, when every layout would pull it out of the owner's hand.
    private func reposition() {
      guard let panel, !panel.isBeingDragged else { return }
      place(height: panel.frame.height, animated: false)
    }

    /// The shadow is the shape of what was last drawn: ask for it again once the new size has been.
    private func refreshShadow() {
      DispatchQueue.main.async { [weak panel] in
        panel?.displayIfNeeded()
        panel?.invalidateShadow()
      }
    }

    /// The content was laid out `height` tall: the panel becomes that, top held, at once (an animated
    /// frame would trail the content, and its shadow with it).
    private func contentHeight(_ height: CGFloat) {
      guard let panel, height > 0 else { return }
      place(height: height.rounded(.up), animated: false)
      guard !shown else { return }
      shown = true
      focusField()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.05 : 0.1
        panel.animator().alphaValue = 1
      }
    }

    /// The cursor goes to the content's field. SwiftUI's own focus request can come before the panel
    /// has the keyboard and be lost, so the panel puts it there itself, and once more a moment later
    /// in case the field was not in the window yet.
    private func focusField() {
      func attempt() {
        guard let panel, panel.firstResponder === panel || panel.firstResponder == nil,
          let field = Self.firstField(in: panel.contentView)
        else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        panel.makeFirstResponder(field)
      }
      attempt()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { attempt() }
    }

    private static func firstField(in view: NSView?) -> NSTextField? {
      guard let view else { return nil }
      if let field = view as? NSTextField, field.isEditable, !field.isHidden { return field }
      for child in view.subviews {
        if let found = firstField(in: child) { return found }
      }
      return nil
    }

    // MARK: Drag

    /// The lines that draw a dragged panel, as places for its top-left corner: the line down the
    /// middle of the window, and two heights, where it opens and where it would sit (at its tallest)
    /// in the middle of the window.
    private var lines: (centre: CGFloat, heights: [CGFloat], home: CGPoint)? {
      guard let home, let parent = panel?.parent else { return nil }
      return (parent.frame.midX - size.width / 2, [home.y, parent.frame.midY + size.height / 2], home)
    }

    /// A drag would put the panel's origin at `origin`: the origin it is given, drawn towards the lines
    /// it is near.
    private func snapped(origin: CGPoint) -> CGPoint {
      guard let panel, let lines else { return origin }
      let height = panel.frame.height
      let rest = FloatingPanelGeometry.snapped(
        CGPoint(x: origin.x, y: origin.y + height), centre: lines.centre, heights: lines.heights,
        home: lines.home)
      return CGPoint(x: rest.x, y: rest.y - height)
    }

    /// Released: it stays where the drag left it, and opens there next time.
    private func dragEnded() {
      guard let panel, let home else { return }
      let moved = CGSize(width: panel.frame.minX - home.x, height: panel.frame.maxY - home.y)
      offset = abs(moved.width) < 0.5 && abs(moved.height) < 0.5 ? nil : moved
      remember?(offset)
    }

    private func goHome(animated: Bool) {
      offset = nil
      remember?(nil)
      place(height: panel?.frame.height ?? size.height, animated: animated)
    }
  }

  /// A stretch of a panel that drags it: behind a header or a footer, under whatever is drawn there.
  /// Controls on top of it keep their own clicks. `PalettePanel` does the dragging; a double click
  /// sends the panel back to where it opens.
  struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Handle: NSView {
      override func accessibilityRole() -> NSAccessibility.Role? { .handle }
      override func accessibilityLabel() -> String? { "Move" }
      override func isAccessibilityElement() -> Bool { true }
    }
  }
#endif
