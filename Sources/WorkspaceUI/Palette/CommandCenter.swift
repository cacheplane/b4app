#if os(macOS)
  import AppKit
  import SwiftUI

  /// Where the command centre's button is on screen, for the palette that opens over it. The root
  /// view owns one and hands it to both.
  @MainActor final class CommandCenterAnchor {
    /// The button's panel, while it is up.
    weak var panel: NSWindow?

    /// The button's frame, while it is showing.
    var frameOnScreen: CGRect? {
      guard let panel, panel.isVisible, panel.alphaValue > 0 else { return nil }
      return panel.frame
    }
  }

  /// The palette at rest, in the middle of the window's title bar: a button shaped like the palette's
  /// own field. A click (or ⌘K) lifts the palette out of it, over it; the button itself takes no text.
  /// While the palette is up the button is blank, since the palette's field is drawn in its place.
  struct CommandCenterButton: View {
    @Bindable var model: WorkspaceModel

    static let width: CGFloat = 360
    static let height: CGFloat = 28

    var body: some View {
      Button {
        model.presentPalette(.find)
      } label: {
        HStack(spacing: LLA.Space.s) {
          Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
          Text("Search or run a command").font(LLAFont.caption).lineLimit(1)
          Spacer(minLength: LLA.Space.s)
          Text(CommandCatalog.definition(.find).shortcutLabel ?? "").font(LLAFont.codeSmall)
        }
        .foregroundStyle(LLA.Color.muted)
        .opacity(model.showSearch ? 0 : 1)
        .padding(.horizontal, LLA.Space.m)
        .frame(width: Self.width, height: Self.height)
        .background(Capsule().fill(LLA.Color.surface))
        .overlay(Capsule().strokeBorder(LLA.Color.rule))
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("Search threads, or type > for commands")
      .accessibilityLabel("Search or run a command")
      .accessibilityIdentifier("command-center")
    }
  }

  /// Puts `CommandCenterButton` over the middle of the window's title bar, in a small panel of its
  /// own attached to the window.
  ///
  /// Not a toolbar item: on macOS 26 SwiftUI centres a principal item on the detail column, not the
  /// window, and moved this button (and the sidebar's own buttons with it) into the overflow menu at
  /// any width. A view drawn into the title bar from the content takes no clicks there. A child panel
  /// has neither problem, and its frame is the palette's home. It never takes the keyboard; it is
  /// hidden in full screen (the title bar is hidden there) and under a sheet.
  struct CommandCenterPresenter: NSViewRepresentable {
    @Bindable var model: WorkspaceModel
    let anchor: CommandCenterAnchor
    /// The workspace is showing (signed in, past onboarding): the button has something to open.
    var isActive: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
      let coordinator = context.coordinator
      coordinator.isActive = isActive
      if coordinator.panel == nil {
        let model = self.model
        let anchor = self.anchor
        DispatchQueue.main.async { coordinator.attach(to: view, model: model, anchor: anchor) }
      } else {
        coordinator.layout()
      }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    /// A panel that takes clicks and never the keyboard.
    final class ButtonPanel: NSPanel {
      override var canBecomeKey: Bool { false }
      override var canBecomeMain: Bool { false }
    }

    @MainActor final class Coordinator {
      var panel: ButtonPanel?
      var isActive = true
      private weak var parent: NSWindow?
      private var observers: [NSObjectProtocol] = []

      func attach(to view: NSView, model: WorkspaceModel, anchor: CommandCenterAnchor) {
        guard panel == nil, let parent = view.window else { return }
        self.parent = parent
        let size = CGSize(width: CommandCenterButton.width, height: CommandCenterButton.height)
        let panel = ButtonPanel(
          contentRect: CGRect(origin: .zero, size: size),
          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Command centre")
        let host = NSHostingView(
          rootView: CommandCenterButton(model: model)
            // A click on a panel that does not activate the app still has to bring the app forward.
            .simultaneousGesture(
              TapGesture().onEnded { [weak parent] in
                NSApp.activate()
                parent?.makeKeyAndOrderFront(nil)
              }))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        anchor.panel = panel
        parent.addChildWindow(panel, ordered: .above)
        layout()

        let center = NotificationCenter.default
        // The window resized, went to or from full screen, took a sheet, or changed appearance: all
        // are followed by an update, and nothing is done when nothing changed.
        observers = [
          center.addObserver(forName: NSWindow.didUpdateNotification, object: parent, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.layout() }
          },
          center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.layout() }
          },
        ]
      }

      func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
      }

      /// Centred across the window, in the middle of its title bar; unseen where there is no title bar
      /// to sit in or the window is busy with a sheet.
      func layout() {
        guard let panel, let parent else { return }
        let bar = parent.frame.height - parent.contentLayoutRect.height
        let fits = bar >= CommandCenterButton.height && parent.frame.width >= CommandCenterButton.width + 420
        let shown =
          isActive && fits && !parent.styleMask.contains(.fullScreen) && parent.attachedSheet == nil
          && parent.isVisible && !parent.isMiniaturized
        let alpha: CGFloat = shown ? 1 : 0
        if panel.alphaValue != alpha { panel.alphaValue = alpha }
        if panel.ignoresMouseEvents == shown { panel.ignoresMouseEvents = !shown }
        if panel.appearance !== parent.effectiveAppearance { panel.appearance = parent.effectiveAppearance }
        let origin = CGPoint(
          x: (parent.frame.midX - panel.frame.width / 2).rounded(),
          y: (parent.frame.maxY - bar / 2 - panel.frame.height / 2).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
      }
    }
  }
#endif
