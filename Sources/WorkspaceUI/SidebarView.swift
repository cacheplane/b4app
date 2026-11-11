import SwiftUI
import WorkspaceProtocol

/// The sidebar on both platforms. On the Mac, New thread, Search, and More are rows above the threads
/// and the profile button is at the bottom. On the iPhone the profile menu leads the navigation bar,
/// the filter menu and a search button (for the list's own search field) trail it, and a "New thread"
/// field sits at the bottom (D-053; the new-thread composer spec, "The iPhone"), so the list starts
/// at the top. No surfaces: Connections, B4 projects, and Diagnostics live in Settings, reached from the
/// profile menu.
struct SidebarView: View {
  @Bindable var model: WorkspaceModel
  /// The phone's "Connect your Mac", which takes the list's place while the account has no Mac.
  @Environment(\.connectMacContent) private var connectMacContent
  @Environment(\.workspaceStatusBanner) private var statusBanner

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

  /// New thread, Search, More (the Mac's rows). New thread is off while no environment's Mac can take a
  /// thread: all offline, or left the hub (the list's notice says why). Search and More stay, since
  /// every thread is still browsable.
  #if os(macOS)
    private var actionRows: some View {
      VStack(alignment: .leading, spacing: 2) {
        // Selected while the pane is the new-thread composer, as a thread row is while it is open.
        SidebarActionRow(
          title: "New thread", systemImage: "square.and.pencil", shortcut: shortcut("⌘N"),
          selected: model.selectedThreadId == nil && model.newThreadEntryReason == nil
        ) {
          Task { await model.openNewThread() }
        }
        .disabled(model.newThreadEntryReason != nil)
        .help(model.newThreadEntryReason ?? "Start a new thread")
        .accessibilityIdentifier("new-thread-toolbar")
        SidebarActionRow(title: "Search", systemImage: "magnifyingglass", shortcut: shortcut("⌘K")) {
          model.showSearch = true
        }
        .keyboardShortcut("k")
        .accessibilityIdentifier("sidebar-search")
        MoreMenu(model: model)
      }
    }

    private func shortcut(_ text: String) -> String? { text }
  #endif

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
        actionRows
          .padding(.horizontal, 10)
          .padding(.top, LLA.Space.s)
          .padding(.bottom, LLA.Space.m)
        listNotice
        ScrollView {
          ThreadListView(model: model)
            .padding(.horizontal, 10)
            .padding(.bottom, LLA.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  #else
    // The phone uses a List: rows need swipe actions, and the split view collapses to one column there.
    // The filters and search are in the navigation bar, and the search field pulls down from above the
    // list (or opens from the search button), as in the iPhone's own Mail. New thread is the field at
    // the bottom.
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
      .searchable(
        text: $model.listSearch, isPresented: $model.listSearchPresented,
        placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search threads"
      )
      // Titles are matched in any case; a capital the keyboard adds unasked only gets in the way.
      .textInputAutocapitalization(.never)
      .navigationTitle(model.environmentFilter == .all ? "Threads" : model.filterTitle)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          MoreMenu(model: model, inToolbar: true)
          Button("Search", systemImage: "magnifyingglass") { model.listSearchPresented = true }
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

/// A sidebar row's face: an SF Symbol in ink, the title, and an optional muted trailing note (a
/// shortcut, or the More menu's active filter). Raised when selected.
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

/// "More": the list's view options for now, and the place for future app features. On the Mac, the
/// archive switch and the connection filter; on the iPhone, the environment filter (which includes the
/// archive) and the connection filter.
struct MoreMenu: View {
  @Bindable var model: WorkspaceModel

  /// The iPhone's navigation bar shows the menu as a filter button rather than a sidebar row.
  let inToolbar: Bool

  init(model: WorkspaceModel, inToolbar: Bool = false) {
    self.model = model
    self.inToolbar = inToolbar
  }

  var body: some View {
    Menu {
      #if os(macOS)
        Toggle("Show archived", isOn: $model.showArchived)
        connectionPicker
      #else
        Picker("Environment", selection: $model.environmentFilter) {
          Text("All environments").tag(EnvironmentFilter.all)
          ForEach(model.filterEnvironments) { environment in
            Text(environment.displayName).tag(EnvironmentFilter.environment(environment.id))
          }
          if model.hasOtherThreads || model.environmentFilter == .other {
            Text("Other").tag(EnvironmentFilter.other)
          }
          Text("Archived").tag(EnvironmentFilter.archived)
        }
        .pickerStyle(.inline)
        // A name alone saves through the change log; folders and Delete go to the environment's Mac.
        if let environment = selectedEnvironment {
          Button("Edit \u{201C}\(environment.displayName)\u{201D}\u{2026}", systemImage: "pencil") {
            model.environmentSheet = .edit(environmentId: environment.id)
          }
          .accessibilityIdentifier("edit-environment")
        }
        Button("New Environment\u{2026}", systemImage: "folder.badge.plus") {
          model.environmentSheet = .create
        }
        .accessibilityIdentifier("new-environment")
        connectionPicker
      #endif
    } label: {
      if inToolbar {
        // Filled while a filter narrows the list, as the iPhone's own apps show it.
        Label(
          "Filter",
          systemImage: activeFilter == nil
            ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        )
        .accessibilityValue(activeFilter ?? "None")
      } else {
        SidebarRowLabel(title: "More", systemImage: "ellipsis", trailing: activeFilter)
      }
    }
    .menuIndicator(.hidden)
    .modifier(SidebarMenuStyle(inToolbar: inToolbar))
    .accessibilityIdentifier("sidebar-more")
  }

  @ViewBuilder private var connectionPicker: some View {
    if model.connections.count > 1 {
      Divider()
      Picker("Connection", selection: $model.connectionFilter) {
        Text("All connections").tag(String?.none)
        ForEach(model.connections) { connection in
          Text(connection.label).tag(String?.some(connection.id))
        }
      }
      .pickerStyle(.inline)
    }
  }

  /// What the menu narrows the list to, if anything, shown muted beside "More".
  private var activeFilter: String? {
    var parts: [String] = []
    #if os(iOS)
      if model.environmentFilter != .all { parts.append(model.filterTitle) }
    #endif
    if let id = model.connectionFilter, let connection = model.connection(id: id) {
      parts.append(connection.label)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  #if os(iOS)
    private var selectedEnvironment: WorkEnvironment? {
      guard case .environment(let id) = model.environmentFilter else { return nil }
      return model.filterEnvironments.first { $0.id == id }
    }
  #endif
}

/// A sidebar row's plain look for the More row; the toolbar's own button look for the filter button.
private struct SidebarMenuStyle: ViewModifier {
  let inToolbar: Bool
  func body(content: Content) -> some View {
    if inToolbar { content } else { content.buttonStyle(.plain) }
  }
}
