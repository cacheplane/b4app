import SwiftUI
import WorkspaceProtocol

/// Sidebar plus detail on both platforms. The sidebar holds the surfaces and the thread list;
/// the detail shows the selected surface or thread. Styling comes from `Theme/` (LLA visual system).
public struct WorkspaceRootView: View {
  @Bindable var model: WorkspaceModel
  /// On a compact width (iPhone) the split view shows one column; choosing a surface or a thread
  /// in the sidebar moves to the detail. Ignored where both columns show.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar

  public init(model: WorkspaceModel) {
    LLAFonts.register()
    self.model = model
  }

  public var body: some View {
    NavigationSplitView(preferredCompactColumn: $compactColumn) {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 290)
        .environment(\.showDetail, { compactColumn = .detail })
    } detail: {
      detail
        .modifier(WorkspaceWindowBackground())
    }
    .tint(LLA.Color.accent)
    .task { model.connect() }
    .sheet(isPresented: $model.showNewThread) { NewThreadSheet(model: model) }
    .onChange(of: model.pendingLoginURL) { _, url in
      guard let url else { return }
      openURL(url)
      model.pendingLoginURL = nil
    }
  }

  @Environment(\.openURL) private var openURL

  @ViewBuilder private var detail: some View {
    switch model.surface {
    case .threads: ThreadsView(model: model)
    case .connections: ConnectionsView(model: model)
    case .servers: LocalServersView(model: model)
    case .diagnostics: DiagnosticsView(model: model)
    }
  }
}

/// The window's own background in the theme colour on macOS; iOS has no window container.
struct WorkspaceWindowBackground: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content.containerBackground(LLA.Color.bg, for: .window)
    #else
      content.background(LLA.Color.bg)
    #endif
  }
}

extension EnvironmentValues {
  /// Moves a collapsed split view to its detail column (set by `WorkspaceRootView`).
  @Entry var showDetail: @MainActor @Sendable () -> Void = {}
}

struct SidebarView: View {
  @Bindable var model: WorkspaceModel
  @Environment(\.showDetail) private var showDetail

  var body: some View {
    content
      .background(LLA.Color.surface)
      .searchable(text: $model.searchText, prompt: "Search titles")
      .navigationTitle("Agent Workspace")
      .toolbar {
        #if os(iOS)
          // The project filter replaces the connection picker; the connection choices sit in its menu.
          ToolbarItem(placement: .topBarLeading) { ProjectFilterMenu(model: model) }
        #endif
        ToolbarItem {
          Button("New thread", systemImage: "square.and.pencil") { model.showNewThread = true }
            .disabled(model.conversationReadyConnections.isEmpty)
            .help(
              model.conversationReadyConnections.isEmpty
                ? "Add a ready Codex connection first" : "Start a new thread"
            )
            .accessibilityIdentifier("new-thread-toolbar")
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { LinkStatusView(model: model) }
  }

  private var header: some View {
    HStack(spacing: LLA.Space.s) {
      LLAMarkView(height: 20)
      Text("Agent Workspace").font(LLAFont.smallStrong).foregroundStyle(LLA.Color.ink)
    }
  }

  #if os(macOS)
    // A scroll view and stacks rather than `List`: inside the split view's sidebar column a List drew
    // nothing on macOS 26 (seen in the app and reproduced by `SnapshotTests` in root mode).
    private var content: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          header
            .padding(.horizontal, 10)
            .padding(.top, LLA.Space.s)
            .padding(.bottom, LLA.Space.m)

          ForEach(Surface.allCases) { surface in
            let selected = model.surface == surface && model.selectedThreadId == nil
            SidebarTextRow(title: surface.title, selected: selected) {
              model.surface = surface
              if surface != .threads { model.selectedThreadId = nil }
              showDetail()
            }
          }

          SidebarGroupLabel("Threads")
          if model.connections.count > 1 {
            Picker("Connection", selection: $model.connectionFilter) {
              Text("All connections").tag(String?.none)
              ForEach(model.connections) { connection in
                Text(connection.label).tag(String?.some(connection.id))
              }
            }
            .labelsHidden()
            .font(LLAFont.small)
            .padding(.horizontal, 10)
            .padding(.bottom, LLA.Space.xs)
          }
          ThreadListView(model: model)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, LLA.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  #else
    // The phone uses a List: rows need swipe actions, and the split view collapses to one column there.
    private var content: some View {
      List {
        Section {
          header.listRowBackground(Color.clear).listRowSeparator(.hidden)
          ForEach(Surface.allCases) { surface in
            let selected = model.surface == surface && model.selectedThreadId == nil
            SidebarTextRow(title: surface.title, selected: selected) {
              model.surface = surface
              if surface != .threads { model.selectedThreadId = nil }
              showDetail()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
          }
        }
        Section {
          ThreadListView(model: model)
        } header: {
          SidebarGroupLabel("Threads", horizontal: 0)
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
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

/// A surface row: text only, ink, raised when selected.
struct SidebarTextRow: View {
  let title: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(selected ? LLAFont.smallStrong : LLAFont.small)
        .foregroundStyle(LLA.Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: LLA.Radius.input, style: .continuous)
            .fill(selected ? LLA.Color.surfaceRaised : .clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct LinkStatusView: View {
  let model: WorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      Hairline()
      HStack(spacing: LLA.Space.s) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(text).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).lineLimit(2)
        Spacer()
        if model.link == .unavailable {
          Button("Retry") { model.connect() }.buttonStyle(.llaLink).font(LLAFont.caption)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      if let note = model.hostNote {
        HStack(alignment: .top, spacing: LLA.Space.s) {
          Text(note).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).fixedSize(
            horizontal: false, vertical: true)
          Spacer()
          if let title = model.hostActionTitle, let action = model.hostAction {
            Button(title) { Task { await action() } }.buttonStyle(.llaLink).font(LLAFont.caption)
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("host-note")
      }
      if let mismatch = model.versionMismatch {
        HStack(alignment: .top, spacing: LLA.Space.s) {
          Text(mismatch).font(LLAFont.caption).foregroundStyle(LLA.Color.muted).fixedSize(
            horizontal: false, vertical: true)
          Spacer()
          if let restart = model.restartCoordinator {
            Button("Restart coordinator") { Task { await restart() } }.buttonStyle(.llaLink).font(
              LLAFont.caption)
          }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("version-note")
      }
    }
    .background(LLA.Color.surface)
    .accessibilityIdentifier("link-status")
  }

  private var color: Color {
    switch model.link {
    case .ready: return LLA.Color.ink
    case .connecting: return LLA.Color.muted
    case .unavailable: return LLA.Color.danger
    }
  }

  private var text: String {
    switch model.link {
    case .ready: return "Coordinator connected"
    case .connecting: return "Connecting to coordinator…"
    case .unavailable: return "Coordinator unavailable: \(model.linkMessage ?? "")"
    }
  }
}
