#if os(macOS)
  import AppKit
  import SwiftUI

  extension EnvironmentValues {
    /// The Mac's palettes are shown in panels of their own (`FloatingPanel`), so they are not cut by
    /// a small window. The app's root sets it; a view drawn without it (a snapshot, a preview) keeps
    /// its palette inside itself.
    @Entry var floatsPalettes = false
  }

  /// A borderless panel that takes the keyboard without taking the app's main window away from the
  /// window under it.
  final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  /// Where a panel opens over the view that presents it.
  nonisolated enum FloatingPanelPlacement: Sendable, Equatable {
    /// Centred across, its top this far under the view's top.
    case top(CGFloat)
    /// Centred both ways.
    case centered
  }

  /// Presents `content` in a panel over the window, attached to it (it moves with the window and
  /// follows it to full screen) but not clipped by it. The panel is transparent and `size` large, with
  /// the content top-aligned inside a margin for its shadow, so a list that grows and shrinks never
  /// moves the panel. Losing the keyboard (a click on the window, another app) calls `dismiss`.
  ///
  /// Put it in a `background` of the view to open over. With `rememberAs`, the place it was dragged to
  /// is kept, relative to the window, until the app quits.
  struct FloatingPanel<Content: View>: NSViewRepresentable {
    var isPresented: Bool
    var size: CGSize
    var placement: FloatingPanelPlacement
    var rememberAs: String?
    /// False while something the content opened (a folder panel) has the keyboard: the panel stays.
    var dismissesOnResign = true
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content

    /// Room around the content for its shadow.
    static var margin: CGFloat { 48 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ anchor: NSView, context: Context) {
      let coordinator = context.coordinator
      coordinator.dismiss = dismiss
      let wasHolding = !coordinator.dismissesOnResign
      coordinator.dismissesOnResign = dismissesOnResign
      if isPresented {
        if coordinator.panel == nil {
          // The anchor has no window while its view is being inserted.
          let build = self
          DispatchQueue.main.async { coordinator.present(build, over: anchor) }
        } else if wasHolding, dismissesOnResign {
          // What held the keyboard has gone: the panel takes it back.
          coordinator.panel?.makeKey()
        }
      } else {
        coordinator.close()
      }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) { coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
      var panel: PalettePanel?
      var dismiss: () -> Void = {}
      var dismissesOnResign = true
      private var rememberAs: String?
      /// Where the panel opens, from the window's origin: the window may move while it is up.
      private var home = CGSize.zero
      private var placing = false

      func present(_ build: FloatingPanel, over anchor: NSView) {
        guard panel == nil, build.isPresented, let parent = anchor.window else { return }
        let margin = FloatingPanel.margin
        let frame = CGSize(width: build.size.width + margin * 2, height: build.size.height + margin * 2)
        let panel = PalettePanel(
          contentRect: CGRect(origin: .zero, size: frame),
          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.appearance = parent.effectiveAppearance
        panel.animationBehavior = .none
        panel.delegate = self
        panel.contentView = NSHostingView(
          rootView: build.content()
            .frame(width: build.size.width, height: build.size.height, alignment: .top)
            .padding(margin)
            .environment(\.floatsPalettes, true))

        // The view's rectangle on screen; the content's top-left goes where the placement says.
        let onScreen = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let top: CGFloat
        switch build.placement {
        case .top(let offset): top = onScreen.maxY - offset
        case .centered: top = onScreen.midY + build.size.height / 2
        }
        var origin = CGPoint(x: onScreen.midX - frame.width / 2, y: top + margin - frame.height)
        home = CGSize(width: origin.x - parent.frame.origin.x, height: origin.y - parent.frame.origin.y)
        rememberAs = build.rememberAs
        if let key = build.rememberAs, let offset = FloatingPanelMemory.offsets[key] {
          origin.x += offset.width
          origin.y += offset.height
        }
        // Never off the screen it is on: the content stays wholly visible.
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
          origin.x = min(max(origin.x, visible.minX - margin), visible.maxX - frame.width + margin)
          origin.y = min(max(origin.y, visible.minY - margin), visible.maxY - frame.height + margin)
        }
        placing = true
        panel.setFrameOrigin(origin)
        placing = false

        self.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
          context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.06 : 0.12
          panel.animator().alphaValue = 1
        }
      }

      func close() {
        guard let panel else { return }
        self.panel = nil
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

      /// A drag by the owner, or the window carrying its child along: the offset from where the panel
      /// opens is the same either way, measured against the window's current place.
      func windowDidMove(_ notification: Notification) {
        guard !placing, let key = rememberAs, let panel, let parent = panel.parent,
          NSEvent.pressedMouseButtons != 0, panel.isKeyWindow
        else { return }
        FloatingPanelMemory.offsets[key] = CGSize(
          width: panel.frame.origin.x - parent.frame.origin.x - home.width,
          height: panel.frame.origin.y - parent.frame.origin.y - home.height)
      }
    }
  }

  /// Where each remembered panel was dragged to, as an offset from where it opens. Kept until the app
  /// quits.
  @MainActor enum FloatingPanelMemory {
    static var offsets: [String: CGSize] = [:]
  }

  /// A stretch of a panel that drags it: behind a header or a footer, under whatever is drawn there.
  /// Controls on top of it keep their own clicks.
  struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Handle() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Handle: NSView {
      override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
  }
#endif
