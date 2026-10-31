import SwiftUI
import WorkspaceProtocol

/// Sidebar plus detail on both platforms. The sidebar holds the surfaces and the thread list;
/// the detail shows the selected surface or thread.
public struct WorkspaceRootView: View {
  @Bindable var model: WorkspaceModel

  public init(model: WorkspaceModel) {
    self.model = model
  }

  public var body: some View {
    NavigationSplitView {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
    } detail: {
      detail
    }
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

struct SidebarView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    List {
      Section("Workspace") {
        ForEach(Surface.allCases) { surface in
          Button {
            model.surface = surface
            if surface != .threads { model.selectedThreadId = nil }
          } label: {
            Label(surface.title, systemImage: surface.systemImage)
              .foregroundStyle(
                model.surface == surface && model.selectedThreadId == nil ? Color.accentColor : Color.primary)
          }
          .buttonStyle(.plain)
        }
      }
      Section("Threads") {
        if model.connections.count > 1 {
          Picker("Connection", selection: $model.connectionFilter) {
            Text("All connections").tag(String?.none)
            ForEach(model.connections) { connection in
              Text(connection.label).tag(String?.some(connection.id))
            }
          }
          .labelsHidden()
        }
        if model.visibleThreads.isEmpty {
          Text("No threads yet.").foregroundStyle(.secondary)
        }
        ForEach(model.visibleThreads) { thread in
          ThreadRow(model: model, thread: thread)
        }
      }
      if model.showArchived || !model.archivedThreads.isEmpty {
        Section {
          if model.showArchived {
            if model.archivedThreads.isEmpty {
              Text("No archived threads.").foregroundStyle(.secondary)
            }
            ForEach(model.archivedThreads) { thread in
              ThreadRow(model: model, thread: thread)
            }
          }
        } header: {
          Toggle(isOn: $model.showArchived) {
            Text("Archived (\(model.archivedThreads.count))")
          }
          .toggleStyle(.switch)
          .controlSize(.mini)
          .accessibilityIdentifier("show-archived")
        }
      }
    }
    .searchable(text: $model.searchText, prompt: "Search titles")
    .navigationTitle("Agent Workspace")
    .toolbar {
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
    .safeAreaInset(edge: .bottom) { LinkStatusView(model: model) }
  }
}

/// One sidebar row: pin, title, connection, and the state dot; the context menu holds the
/// organization actions (spec 3.1). Archiving never stops a turn (spec 3.3).
struct ThreadRow: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread
  @State private var renaming = false
  @State private var newTitle = ""

  var body: some View {
    let state = model.threadState(thread)
    Button {
      Task { await model.openThread(id: thread.id) }
    } label: {
      HStack(alignment: .top, spacing: 8) {
        ThreadStateDot(state: state).padding(.top, 5)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            if thread.pinned { Image(systemName: "pin.fill").font(.caption2) }
            Text(thread.title.isEmpty ? "Untitled" : thread.title).fontWeight(.medium).lineLimit(1)
          }
          Text(
            state == .idle
              ? (model.connection(id: thread.connectionId)?.label ?? "Unknown connection")
              : "\(model.connection(id: thread.connectionId)?.label ?? "Unknown connection") · \(state.label)"
          )
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .buttonStyle(.plain)
    .listRowBackground(model.selectedThreadId == thread.id ? Color.accentColor.opacity(0.15) : nil)
    .accessibilityIdentifier("thread-row")
    .accessibilityValue(state.rawValue)
    .contextMenu {
      Button("Rename…", systemImage: "pencil") {
        newTitle = thread.title
        renaming = true
      }
      Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") {
        Task { await model.updateThread(id: thread.id, pinned: !thread.pinned) }
      }
      Button(
        thread.archived ? "Unarchive" : "Archive",
        systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
      ) {
        Task { await model.updateThread(id: thread.id, archived: !thread.archived) }
      }
    }
    .alert("Rename thread", isPresented: $renaming) {
      TextField("Title", text: $newTitle)
      Button("Rename") { Task { await model.updateThread(id: thread.id, title: newTitle) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The title is local to this app; the runtime's own history is not changed.")
    }
  }
}

struct ThreadStateDot: View {
  let state: ThreadRowState

  var body: some View {
    Circle().fill(color).frame(width: 8, height: 8)
      .overlay {
        if state == .running || state == .stopping {
          Circle().stroke(color.opacity(0.4), lineWidth: 2).frame(width: 12, height: 12)
        }
      }
      .help(state.label)
  }

  private var color: Color {
    switch state {
    case .idle: return .secondary.opacity(0.35)
    case .running, .stopping: return .blue
    case .waiting: return .orange
    case .unknown: return .yellow
    case .reconnecting: return .gray
    case .error: return .red
    }
  }
}

struct LinkStatusView: View {
  let model: WorkspaceModel

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Spacer()
      if model.link == .unavailable {
        Button("Retry") { model.connect() }.font(.caption).buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .accessibilityIdentifier("link-status")
  }

  private var color: Color {
    switch model.link {
    case .ready: return .green
    case .connecting: return .orange
    case .unavailable: return .red
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
