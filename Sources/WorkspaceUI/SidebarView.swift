import SwiftUI
import WorkspaceProtocol

/// The sidebar on both platforms: New thread, Search, and More at the top, then the threads; the
/// profile button sits at the bottom. No surfaces: Connections, Local servers, and Diagnostics live in
/// Settings, reached from the profile menu.
struct SidebarView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    content
      .background(LLA.Color.surface)
      .overlay {
        // A click anywhere else in the sidebar closes the profile menu.
        if model.showProfileMenu {
          Color.clear.contentShape(Rectangle())
            .onTapGesture { model.showProfileMenu = false }
            .accessibilityHidden(true)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(model: model) }
  }

  /// New thread, Search, More. Disabled while the phone has no joined Mac to show.
  private var actionRows: some View {
    VStack(alignment: .leading, spacing: 2) {
      SidebarActionRow(
        title: "New thread", systemImage: "square.and.pencil", shortcut: shortcut("⌘N")
      ) {
        model.showNewThread = true
      }
      .disabled(model.conversationReadyConnections.isEmpty)
      .help(
        model.conversationReadyConnections.isEmpty
          ? "Add a ready Codex connection first" : "Start a new thread"
      )
      .accessibilityIdentifier("new-thread-toolbar")
      SidebarActionRow(title: "Search", systemImage: "magnifyingglass", shortcut: shortcut("⌘K")) {
        model.showSearch = true
      }
      .keyboardShortcut("k")
      .accessibilityIdentifier("sidebar-search")
      MoreMenu(model: model)
    }
    .disabled(model.hostDisconnected)
  }

  /// The Mac shows the shortcut beside the row; the phone has no keyboard to advertise.
  private func shortcut(_ text: String) -> String? {
    #if os(macOS)
      return text
    #else
      return nil
    #endif
  }

  private var hostDisconnected: some View {
    LLAEmptyState(
      "Host disconnected", text: "Your Mac has left the hub. Its threads come back when it joins again."
    )
    .accessibilityIdentifier("host-disconnected")
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
        if model.hostDisconnected {
          hostDisconnected
        } else {
          ScrollView {
            ThreadListView(model: model)
              .padding(.horizontal, 10)
              .padding(.bottom, LLA.Space.l)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  #else
    // The phone uses a List: rows need swipe actions, and the split view collapses to one column there.
    @ViewBuilder private var content: some View {
      if model.hostDisconnected {
        VStack(alignment: .leading, spacing: 0) {
          actionRows.padding(.horizontal, LLA.Space.l).padding(.top, LLA.Space.s)
          hostDisconnected
        }
      } else {
        List {
          Section {
            actionRows
              .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: LLA.Space.m, trailing: 6))
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
          }
          Section {
            ThreadListView(model: model)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
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

  var body: some View {
    HStack(spacing: LLA.Space.s) {
      Image(systemName: systemImage)
        .font(LLAFont.small)
        .foregroundStyle(LLA.Color.ink)
        .frame(width: 18)
      Text(title)
        .font(selected ? LLAFont.smallStrong : LLAFont.small)
        .foregroundStyle(LLA.Color.ink)
        .lineLimit(1)
      Spacer(minLength: LLA.Space.s)
      if let trailing {
        Text(trailing).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(1)
      }
    }
    .opacity(isEnabled ? 1 : 0.45)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
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
    .buttonStyle(.plain)
  }
}

/// "More": the list's view options for now, and the place for future app features. On the Mac, the
/// archive switch and the connection filter; on the iPhone, the project filter (which includes the
/// archive) and the connection filter.
struct MoreMenu: View {
  @Bindable var model: WorkspaceModel
  #if os(iOS)
    @State private var renaming: Project?
    @State private var newName = ""
  #endif

  init(model: WorkspaceModel) { self.model = model }

  var body: some View {
    Menu {
      #if os(macOS)
        Toggle("Show archived", isOn: $model.showArchived)
        connectionPicker
      #else
        Picker("Project", selection: $model.projectFilter) {
          Text("All projects").tag(ProjectFilter.all)
          ForEach(model.filterProjects) { project in
            Text(project.displayName).tag(ProjectFilter.project(project.id))
          }
          if model.hasOtherThreads || model.projectFilter == .other {
            Text("Other").tag(ProjectFilter.other)
          }
          Text("Archived").tag(ProjectFilter.archived)
        }
        .pickerStyle(.inline)
        if let project = selectedProject {
          Button("Rename \u{201C}\(project.displayName)\u{201D}\u{2026}", systemImage: "pencil") {
            newName = project.name
            renaming = project
          }
          .accessibilityIdentifier("rename-project")
        }
        connectionPicker
      #endif
    } label: {
      SidebarRowLabel(title: "More", systemImage: "ellipsis", trailing: activeFilter)
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar-more")
    #if os(iOS)
      .alert(
        "Rename project",
        isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
        presenting: renaming
      ) { project in
        TextField("Name", text: $newName)
        Button("Rename") {
          Task {
            await model.renameProject(id: project.id, name: newName.trimmingCharacters(in: .whitespaces))
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("Leave it empty to show the first folder's name.")
      }
    #endif
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
      if model.projectFilter != .all { parts.append(model.filterTitle) }
    #endif
    if let id = model.connectionFilter, let connection = model.connection(id: id) {
      parts.append(connection.label)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  #if os(iOS)
    private var selectedProject: Project? {
      guard case .project(let id) = model.projectFilter else { return nil }
      return model.filterProjects.first { $0.id == id }
    }
  #endif
}
