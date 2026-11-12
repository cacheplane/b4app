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

  /// The palette at rest, in the middle of the window's title bar: the palette's own top row, drawn
  /// flat. The same height, corners, edge, glyph, and prompt as the open palette's field row, so that
  /// opening the palette over it changes nothing but the shadow and the list beneath. It is a button,
  /// not a field: a click (or ⌘K) opens the palette, whose field is drawn where this was. Where the
  /// open palette says "esc", this names the key that opens it.
  struct CommandCenterButton: View {
    @Bindable var model: WorkspaceModel

    /// As wide as the palette when the window has the room, and never narrower than this.
    static let minWidth: CGFloat = 280
    static let height = MacPalette.fieldHeight
    /// What the title bar keeps for its own buttons, on the two sides together.
    static let reserved: CGFloat = 540

    /// The width for a window `window` wide: the palette's, or what its title bar has room for.
    static func width(inWindow window: CGFloat) -> CGFloat {
      min(MacPalette.width, max(window - reserved, minWidth))
    }

    var body: some View {
      Button {
        model.presentPalette(.find)
      } label: {
        // The open palette's field row (`MacPalette.input`), piece for piece.
        HStack(spacing: LLA.Space.s) {
          Image(systemName: "magnifyingglass").foregroundStyle(LLA.Color.muted)
          Text(PaletteModel.findPrompt)
            .font(LLAFont.body)
            .foregroundStyle(Color(nsColor: .placeholderTextColor))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(CommandCatalog.definition(.find).shortcutLabel ?? "")
            .font(LLAFont.codeSmall).foregroundStyle(LLA.Color.muted)
        }
        .padding(.horizontal, LLA.Space.l)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(LLA.Color.bg, in: RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous).strokeBorder(LLA.Color.rule)
        )
        .contentShape(RoundedRectangle(cornerRadius: LLA.Radius.card, style: .continuous))
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
        let size = CGSize(
          width: CommandCenterButton.width(inWindow: parent.frame.width), height: CommandCenterButton.height)
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
        let size = CGSize(
          width: CommandCenterButton.width(inWindow: parent.frame.width), height: CommandCenterButton.height)
        let fits =
          bar >= size.height
          && parent.frame.width >= CommandCenterButton.minWidth + CommandCenterButton.reserved
        let shown =
          isActive && fits && !parent.styleMask.contains(.fullScreen) && parent.attachedSheet == nil
          && parent.isVisible && !parent.isMiniaturized
        let alpha: CGFloat = shown ? 1 : 0
        if panel.alphaValue != alpha { panel.alphaValue = alpha }
        if panel.ignoresMouseEvents == shown { panel.ignoresMouseEvents = !shown }
        if panel.appearance !== parent.effectiveAppearance { panel.appearance = parent.effectiveAppearance }
        let frame = CGRect(
          x: (parent.frame.midX - size.width / 2).rounded(),
          y: (parent.frame.maxY - bar / 2 - size.height / 2).rounded(), width: size.width, height: size.height
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
      }
    }
  }
#endif
