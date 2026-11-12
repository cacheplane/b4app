#if os(macOS)
  import SwiftUI

  /// The Mac's top-bar buttons. The sidebar's top bar, left to right after the traffic lights and a
  /// flexible space: view options, search, and new thread (in ink; the others muted), then the system's
  /// sidebar toggle. With the sidebar hidden, search and new thread move to the main view's toolbar.
  /// The phone has none of these: its navigation bar and docked "New thread" field stand in for them.
  public enum TopBarButton: Hashable, Sendable {
    case viewOptions, search, newThread

    /// The sidebar's top bar, in order, while the sidebar shows. AppKit keeps a hidden sidebar's
    /// toolbar items in the window's toolbar, so the sidebar declares none while it is hidden.
    static func sidebar(_ visibility: NavigationSplitViewVisibility) -> [TopBarButton] {
      visibility == .detailOnly ? [] : [.viewOptions, .search, .newThread]
    }

    /// What the main view's toolbar adds: search and new thread while the sidebar is hidden, else nothing.
    static func mainView(_ visibility: NavigationSplitViewVisibility) -> [TopBarButton] {
      visibility == .detailOnly ? [.search, .newThread] : []
    }

    var title: String {
      switch self {
      case .viewOptions: "View options"
      case .search: "Search"
      case .newThread: "New thread"
      }
    }

    var systemImage: String {
      switch self {
      case .viewOptions: "line.3.horizontal.decrease"
      case .search: "magnifyingglass"
      case .newThread: "square.and.pencil"
      }
    }

    /// UI tests find the buttons by these.
    var identifier: String {
      switch self {
      case .viewOptions: "view-options"
      case .search: "sidebar-search"
      case .newThread: "new-thread-toolbar"
      }
    }

    /// Each button's square target, in points.
    static let side: CGFloat = 28

    /// New thread is the bar's one ink button; the others are muted.
    var isInk: Bool { self == .newThread }

    /// The symbol and its ink. While a filter is active (`WorkspaceModel.viewOptionsFiltered`), view
    /// options is the filled symbol in ink, so the narrowed list is never a surprise; the other buttons
    /// never change.
    func face(filtered: Bool) -> (systemImage: String, isInk: Bool) {
      guard self == .viewOptions, filtered else { return (systemImage, isInk) }
      return ("line.3.horizontal.decrease.circle.fill", true)
    }

    /// What VoiceOver says: the title, whatever the symbol. The symbols carry descriptions of their own
    /// ("filter" for both of view options' faces), which AppKit spoke once a thread was open while the
    /// label sat only on a wrapper outside the menu's own label; `TopBarLabel` sets this on the symbol.
    var accessibilityLabel: String { title }

    /// The shortcut, from the command catalog, declared once by the app's File menu (so it works with the sidebar hidden and
    /// over the palette or the composer); the buttons only name it in their help.
    public var shortcut: KeyboardShortcut? {
      switch self {
      case .viewOptions: nil
      case .search: CommandCatalog.definition(.find).shortcut
      case .newThread: CommandCatalog.definition(.newThread).shortcut
      }
    }

    /// New thread is off while no environment's Mac can take a thread (the list's notice says why).
    /// Search and view options stay on, since every thread is still browsable.
    func isEnabled(entryReason: String?) -> Bool { self != .newThread || entryReason == nil }

    /// The tooltip: the reason new thread is off, else the title and its shortcut.
    func help(entryReason: String?) -> String {
      if self == .newThread, let entryReason { return entryReason }
      guard let shortcut else { return title }
      return "\(title) (\u{2318}\(String(shortcut.key.character).uppercased()))"
    }
  }

  /// One top-bar button. View options is the list's view menu (`MoreMenu`); search opens the palette;
  /// new thread opens the composer.
  struct TopBarButtonView: View {
    @Bindable var model: WorkspaceModel
    let button: TopBarButton

    var body: some View {
      let face = button.face(filtered: model.viewOptionsFiltered)
      Group {
        switch button {
        case .viewOptions:
          MoreMenu(model: model)
        case .search:
          Button {
            model.presentPalette(.find)
          } label: {
            TopBarLabel(button: button)
          }
        case .newThread:
          Button {
            Task { await model.openNewThread() }
          } label: {
            TopBarLabel(button: button)
          }
        }
      }
      // Plain icons on a 28 pt target, not the toolbar's own 44 pt glass items: in the 240 pt sidebar,
      // three of those beside the traffic lights and the sidebar toggle sent new thread to the overflow.
      .buttonStyle(.borderless)
      .menuStyle(.button)
      .tint(face.isInk ? LLA.Color.ink : LLA.Color.muted)
      .disabled(!button.isEnabled(entryReason: model.newThreadEntryReason))
      .help(button.help(entryReason: model.newThreadEntryReason))
      .accessibilityLabel(button.accessibilityLabel)
      .accessibilityIdentifier(button.identifier)
    }
  }

  /// A top-bar button's face: its symbol alone, in ink or muted (`TopBarButton.face`).
  struct TopBarLabel: View {
    let button: TopBarButton
    var filtered = false

    var body: some View {
      let face = button.face(filtered: filtered)
      // An image, not a `Label`: the toolbar item holding all three would take the first label's title
      // as every button's accessibility name.
      Image(systemName: face.systemImage)
        .foregroundStyle(face.isInk ? LLA.Color.ink : LLA.Color.muted)
        .frame(width: TopBarButton.side, height: TopBarButton.side)
        .contentShape(Rectangle())
        // On the symbol itself, so no host of the button (the menu's, the toolbar's) falls back on the
        // symbol's own description.
        .accessibilityLabel(button.accessibilityLabel)
    }
  }

  /// `buttons` as one toolbar item, with no shared background, so they take only their own width.
  struct TopBarItems: ToolbarContent {
    @Bindable var model: WorkspaceModel
    let buttons: [TopBarButton]
    var placement: ToolbarItemPlacement = .automatic

    var body: some ToolbarContent {
      if !buttons.isEmpty {
        ToolbarItem(placement: placement) {
          HStack(spacing: LLA.Space.xs) {
            ForEach(buttons, id: \.self) { TopBarButtonView(model: model, button: $0) }
          }
          .accessibilityElement(children: .contain)
        }
        .sharedBackgroundVisibility(.hidden)
      }
    }
  }

  extension WorkspaceModel {
    /// Whether the view-options menu narrows the Mac's list: a connection is picked. The arrangement and
    /// "Show archived" are settings, not filters.
    var viewOptionsFiltered: Bool {
      connectionFilter.flatMap { connection(id: $0) } != nil
    }
  }

  extension EnvironmentValues {
    /// The Mac split view's column visibility, for the sidebar's top bar (set by `WorkspaceShell`).
    @Entry var sidebarVisibility = NavigationSplitViewVisibility.automatic
  }
#endif
