import SwiftUI
import WorkspaceProtocol

/// The sidebar on both platforms. On the Mac, view options, search, and new thread are icon buttons in
/// the sidebar's top bar (`TopBarButton`), the threads fill the column, and the profile button is at
/// the bottom. On the iPhone the profile menu leads the navigation bar,
/// the view-options menu and a search button (for the Search sheet) trail it, and a "New thread"
/// field sits at the bottom (D-053; the new-thread composer spec, "The iPhone"), so the list starts
/// at the top. No surfaces: Connections, B4 projects, and Diagnostics live in Settings, reached from the
/// profile menu.
struct SidebarView: View {
  @Bindable var model: WorkspaceModel
  /// The phone's "Connect your Mac", which takes the list's place while the account has no Mac.
  @Environment(\.connectMacContent) private var connectMacContent
  @Environment(\.workspaceStatusBanner) private var statusBanner
  #if os(macOS)
    @Environment(\.sidebarVisibility) private var visibility
  #endif

  var body: some View {
    shown
      .background(LLA.Color.surface)
      #if os(macOS)
        .overlay {
          // A click anywhere else in the sidebar closes the profile menu.
          if model.showProfileMenu {
            Color.clear.contentShape(Rectangle())
            .onTapGesture { model.showProfileMenu = false }
            .accessibilityHidden(true)
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(model: model) }
      #else
        // On "Connect your Mac" too, so the account can still be left from there.
        .toolbar {
          ToolbarItem(placement: .topBarLeading) { ProfileToolbarMenu(model: model) }
          .sharedBackgroundVisibility(.hidden)
        }
      #endif
  }

  /// The list, or the phone's "Connect your Mac" in its place while the account has no Mac.
  @ViewBuilder private var shown: some View {
    if model.showsConnectMac, let connectMacContent {
      connectMacContent()
        .safeAreaInset(edge: .top, spacing: 0) { statusBanner?() }
    } else {
      content
    }
  }

  /// The Mac left the hub, or the primary Mac is offline: a persistent notice above the list, which
  /// stays browsable (M8c; this replaced M8b's empty state).
  @ViewBuilder private var listNotice: some View {
    if let notice = model.accountNotice {
      AccountNoticeBanner(text: notice) { Task { await model.dismissAccountNotice() } }
    }
    if let notice = model.listNotice {
      HostNotice(message: notice)
        .accessibilityIdentifier(notice.kind == .leftHub ? "host-disconnected" : "host-notice")
    }
  }

  #if os(macOS)
    // A scroll view and stacks rather than `List`: inside the split view's sidebar column a List drew
    // nothing on macOS 26 (seen in the app and reproduced by `SnapshotTests` in root mode).
    private var content: some View {
      VStack(alignment: .leading, spacing: 0) {
        listNotice
        ScrollView {
          ThreadListView(model: model)
            .padding(.horizontal, 10)
            .padding(.top, LLA.Space.s)
            .padding(.bottom, LLA.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      // The top bar: a flexible space after the traffic lights, then view options, search, and new
      // thread; the system's sidebar toggle follows.
      .toolbar {
        ToolbarSpacer(.flexible)
        TopBarItems(model: model, buttons: TopBarButton.sidebar(visibility))
      }
    }
  #else
    // The phone uses a List: rows need swipe actions, and the split view collapses to one column there.
    // The filters and search are in the navigation bar; the search button opens the Search sheet, so
    // no field sits above the list. New thread is the field at the bottom.
    private var content: some View {
      List {
        Section {
          ThreadListView(model: model)
        } header: {
          VStack(spacing: 0) {
            statusBanner?()
            listNotice
          }
          .textCase(nil)
          .listRowInsets(EdgeInsets())
        }
      }
      .listStyle(.plain)
      .navigationTitle("Threads")
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          MoreMenu(model: model)
          Button("Search", systemImage: "magnifyingglass") { model.showSearch = true }
            .accessibilityIdentifier("list-search")
        }
      }
      .scrollContentBackground(.hidden)
      // Rows are exactly their 44 pt target: no untappable band above and below each one.
      .environment(\.defaultMinListRowHeight, LLA.Metrics.row)
      // Plain-list section headers pin below the navigation bar. A top safe-area inset/bar
      // suppresses the large title while a notice is present, even when attached to the List itself.
      .environment(\.defaultMinListHeaderHeight, 0)
      .safeAreaInset(edge: .bottom, spacing: 0) { NewThreadDock(model: model) }
    }
  #endif
}

/// A group label in the sidebar: small, muted, sentence case.
struct SidebarGroupLabel: View {
  let title: String
  /// Side inset; the sidebar's own padding is 10, a list header supplies its own.
  let horizontal: CGFloat
  init(_ title: String, horizontal: CGFloat = 10) {
    self.title = title
    self.horizontal = horizontal
  }

  var body: some View {
    Text(title).font(LLAFont.small).foregroundStyle(LLA.Color.muted)
      .padding(.horizontal, horizontal)
      .padding(.top, LLA.Space.m)
      .padding(.bottom, LLA.Space.xs)
      .textCase(nil)
  }
}

/// A sidebar row's face: an SF Symbol in ink, the title, and an optional muted trailing note. Raised
/// when selected.
struct SidebarRowLabel: View {
  let title: String
  let systemImage: String
  var trailing: String?
  var selected = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.dynamicTypeSize) private var typeSize
  /// The symbol's column grows with the text, so a large size never runs the symbol into the title.
  @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 18

  var body: some View {
    HStack(spacing: LLA.Space.s) {
      Image(systemName: systemImage)
        .font(LLAFont.row)
        .foregroundStyle(LLA.Color.ink)
        .frame(width: symbolWidth)
      Text(title)
        .font(selected ? LLAFont.rowStrong : LLAFont.row)
        .foregroundStyle(LLA.Color.ink)
        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
      Spacer(minLength: LLA.Space.s)
      if let trailing {
        Text(trailing).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(1)
      }
    }
    .opacity(isEnabled ? 1 : 0.45)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(minHeight: LLA.Metrics.row)
    .background(
      RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
        .fill(selected ? LLA.Color.surfaceRaised : .clear)
    )
    .contentShape(Rectangle())
  }
}

/// A sidebar action: symbol, title, and the shortcut at the trailing edge.
struct SidebarActionRow: View {
  let title: String
  let systemImage: String
  let shortcut: String?
  var selected = false
  let action: () -> Void

  init(
    title: String, systemImage: String, shortcut: String?, selected: Bool = false,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.shortcut = shortcut
    self.selected = selected
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      SidebarRowLabel(title: title, systemImage: systemImage, trailing: shortcut, selected: selected)
    }
    .buttonStyle(.llaRow)
  }
}

/// The view-options menu's words and rules, apart from the view so they can be tested (decision 11).
enum ViewOptions {
  static let arrangements = ViewSettings.Arrangement.allCases
  static let quietThreads = ViewSettings.QuietThreads.allCases

  static func title(_ arrangement: ViewSettings.Arrangement) -> String {
    switch arrangement {
    case .needsYouFirst: return "Needs you first"
    case .byEnvironment: return "By environment"
    }
  }

  static func title(_ quietThreads: ViewSettings.QuietThreads) -> String {
    switch quietThreads {
    case .small: return "Small"
    case .tiny: return "Tiny"
    case .collapsed: return "Collapsed"
    case .hidden: return "Hidden"
    }
  }

  /// The secondary line under an item that this device draws as something else (decision 5).
  static func note(_ quietThreads: ViewSettings.QuietThreads, onPhone: Bool) -> String? {
    guard onPhone else { return nil }
    let stored = ViewSettings(quietThreads: quietThreads)
    return stored.shown(on: .phone).quietThreads == quietThreads ? nil : "Shown collapsed on this device"
  }

  /// "By environment" draws every thread in its environment's group, so how quiet threads are drawn does
  /// not apply and its items are disabled.
  static func quietThreadsDisabled(_ settings: ViewSettings) -> Bool {
    settings.arrangement == .byEnvironment
  }
}

/// The list's view options, a menu behind a toolbar button on both platforms (decision 11): Arrange,
/// "Threads that don't need you", "Show archived", and the connection filter. On the Mac it is the top
/// bar's view-options button (`TopBarButton.viewOptions`); on the iPhone the navigation bar's button,
/// which also keeps New Environment and Edit Environment at its foot until the environment form gives
/// them a home of their own. The items check the stored values; choosing one writes it for every device.
struct MoreMenu: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    Menu {
      Picker("Arrange", selection: arrangement) {
        ForEach(ViewOptions.arrangements, id: \.self) { Text(ViewOptions.title($0)).tag($0) }
      }
      .pickerStyle(.inline)
      Picker("Threads that don\u{2019}t need you", selection: quietThreads) {
        ForEach(ViewOptions.quietThreads, id: \.self) { option in
          // A second text is the menu item's secondary line.
          VStack(alignment: .leading) {
            Text(ViewOptions.title(option))
            if let note = ViewOptions.note(option, onPhone: model.relaysThroughHub) { Text(note) }
          }
          .tag(option)
        }
      }
      .pickerStyle(.inline)
      .disabled(ViewOptions.quietThreadsDisabled(model.shownSettings))
      Divider()
      Toggle("Show archived", isOn: showArchived)
      connectionPicker
      #if os(iOS)
        environmentActions
      #endif
    } label: {
      #if os(macOS)
        // Filled and in ink while a connection is picked.
        TopBarLabel(button: .viewOptions, filtered: model.viewOptionsFiltered)
          .accessibilityValue(activeFilter ?? "None")
      #else
        // Filled while a connection filter narrows the list, as the iPhone's own apps show it.
        Label(
          "View options",
          systemImage: activeFilter == nil
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        )
        .accessibilityValue(activeFilter ?? "None")
      #endif
    }
    .menuIndicator(.hidden)
    #if os(macOS)
      // The menu's button sizes itself to the symbol; this gives it the other buttons' 28 pt target.
      .frame(width: TopBarButton.side, height: TopBarButton.side)
      .contentShape(Rectangle())
      .accessibilityIdentifier(TopBarButton.viewOptions.identifier)
    #else
      .accessibilityIdentifier("sidebar-more")
    #endif
  }

  private var arrangement: Binding<ViewSettings.Arrangement> {
    Binding(
      get: { model.viewSettings.arrangement },
      set: { value in Task { await model.setArrangement(value) } })
  }

  private var quietThreads: Binding<ViewSettings.QuietThreads> {
    Binding(
      get: { model.viewSettings.quietThreads },
      set: { value in Task { await model.setQuietThreads(value) } })
  }

  private var showArchived: Binding<Bool> {
    Binding(
      get: { model.viewSettings.showArchived },
      set: { value in Task { await model.setShowArchived(value) } })
  }

  @ViewBuilder private var connectionPicker: some View {
    if model.connections.count > 1 {
      Divider()
      Picker("Connections", selection: $model.connectionFilter) {
        Text("All connections").tag(String?.none)
        ForEach(model.connections) { connection in
          Text(connection.label).tag(String?.some(connection.id))
        }
      }
      .pickerStyle(.inline)
    }
  }

  #if os(iOS)
    /// New Environment and Edit Environment, which have no other home on the phone yet. A name alone
    /// saves through the change log; folders and Delete go to the environment's Mac.
    @ViewBuilder private var environmentActions: some View {
      Divider()
      if !model.filterEnvironments.isEmpty {
        Menu("Edit Environment", systemImage: "pencil") {
          ForEach(model.filterEnvironments) { environment in
            Button("\(environment.displayName)\u{2026}") {
              model.environmentSheet = .edit(environmentId: environment.id)
            }
          }
        }
        .accessibilityIdentifier("edit-environment")
      }
      Button("New Environment\u{2026}", systemImage: "folder.badge.plus") {
        model.environmentSheet = .create
      }
      .accessibilityIdentifier("new-environment")
    }
  #endif

  /// What the menu narrows the list to, if anything (the button's accessibility value).
  private var activeFilter: String? {
    guard let id = model.connectionFilter, let connection = model.connection(id: id) else { return nil }
    return connection.label
  }
}
