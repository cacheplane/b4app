import SwiftUI
import WorkspaceProtocol

struct ThreadsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    if let thread = model.threads.first(where: { $0.id == model.selectedThreadId }) {
      ThreadDetailView(model: model, thread: thread)
    } else {
      LLAEmptyState(
        "Threads",
        text: model.connections.isEmpty
          ? "Add a connection to start a conversation with Codex, Claude Code, or a B4 agent."
          : "Select a thread in the sidebar, or start a new one."
      ) {
        if model.conversationReadyConnections.isEmpty {
          Button("Add connection") { model.surface = .connections }
            .buttonStyle(.llaPrimary)
            .accessibilityIdentifier("add-connection")
        } else {
          Button("New thread") { model.showNewThread = true }
            .buttonStyle(.llaPrimary)
            .accessibilityIdentifier("new-thread")
        }
      }
      .navigationTitle("Threads")
    }
  }
}

struct ThreadDetailView: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread
  @State private var renaming = false
  @State private var newTitle = ""

  private var connection: Connection? { model.connection(id: thread.connectionId) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Hairline()
      if let detail = model.detail, detail.thread.id == thread.id {
        TranscriptView(detail: detail)
        if !detail.requests.isEmpty {
          Hairline()
          RuntimeRequestList(model: model, requests: detail.requests)
        }
        Hairline()
        if thread.continuity != .available {
          ContinuityBanner(model: model, thread: thread)
        }
        ComposerView(model: model, detail: detail)
      } else if model.detailLoading {
        ProgressView("Loading thread…").llaSmallMuted().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text(model.lastError ?? "Thread not loaded.").llaMuted()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(thread.title.isEmpty ? "Untitled" : thread.title)
    .task(id: thread.id) {
      if model.detail?.thread.id != thread.id { await model.openThread(id: thread.id) }
    }
    .toolbar {
      ToolbarItemGroup {
        Button("Rename", systemImage: "pencil") {
          newTitle = thread.title
          renaming = true
        }
        .accessibilityIdentifier("rename")
        Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") {
          Task { await model.updateThread(id: thread.id, pinned: !thread.pinned) }
        }
        .accessibilityIdentifier("pin")
        Button(
          thread.archived ? "Unarchive" : "Archive",
          systemImage: thread.archived ? "tray.and.arrow.up" : "archivebox"
        ) {
          Task { await model.updateThread(id: thread.id, archived: !thread.archived) }
        }
        .accessibilityIdentifier("archive")
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

  private var header: some View {
    VStack(alignment: .leading, spacing: LLA.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: LLA.Space.m) {
        Text(thread.title.isEmpty ? "Untitled" : thread.title).llaDisplay().lineLimit(1)
        if thread.archived { LLABadge("Archived") }
        Spacer()
        if let turn = model.detail?.activeTurn, model.detail?.thread.id == thread.id {
          TurnStatusBadge(turn: turn)
        }
      }
      Text(
        "\(connection?.label ?? "Unknown connection") · \(connection?.kind.rawValue ?? "?") · \(connection?.kind == .b4 ? "route \(thread.context ?? "?")" : (thread.context ?? "no directory"))"
      )
      .llaSmallMuted().lineLimit(1).truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, LLA.Space.xl)
    .padding(.vertical, LLA.Space.l)
  }
}

/// Spec 3.3: when the native session is gone or belongs to another identity, keep the cached view,
/// say so, and offer a new thread. The composer stays disabled.
struct ContinuityBanner: View {
  @Bindable var model: WorkspaceModel
  let thread: ConversationThread

  var body: some View {
    LLACard(fill: .surface) {
      HStack(alignment: .top, spacing: LLA.Space.l) {
        VStack(alignment: .leading, spacing: LLA.Space.xs) {
          Text("Continuation is unavailable").font(LLAFont.bodyStrong).foregroundStyle(LLA.Color.ink)
          Text(explanation).llaSmallMuted().fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("Check again") { Task { await model.reconcileThread(id: thread.id) } }
          .buttonStyle(.llaSecondary)
          .disabled(model.busy)
        Button("New thread") { model.showNewThread = true }
          .buttonStyle(.llaPrimary)
          .disabled(model.conversationReadyConnections.isEmpty)
      }
    }
    .padding(.horizontal, LLA.Space.xl)
    .padding(.top, LLA.Space.l)
    .frame(maxWidth: LLA.Metrics.column)
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier("continuity-banner")
  }

  private var explanation: String {
    switch thread.continuity {
    case .available: return ""
    case .missing:
      return
        "The runtime no longer has this thread's native session. The cached transcript stays; nothing was re-sent."
    case .identityChanged:
      let now = model.connection(id: thread.connectionId)?.nativeScope ?? "another identity"
      return
        "This thread was created under \(thread.nativeScope); the connection is now \(now). Old threads are never retargeted to a different account or server."
    }
  }
}

struct TurnStatusBadge: View {
  let turn: Turn

  var body: some View {
    HStack(spacing: 6) {
      if turn.status == .running || turn.status == .submitting || turn.status == .stopping {
        ProgressView().controlSize(.mini)
      }
      Text(text)
    }
    .font(LLAFont.caption)
    .foregroundStyle(turn.status == .waitingForUser ? LLA.Color.accent : LLA.Color.ink)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(Capsule().fill(LLA.Color.surface))
    .accessibilityIdentifier("turn-status")
  }

  private var text: String {
    switch turn.status {
    case .submitting: return "Sending…"
    case .running: return "Running"
    case .waitingForUser: return "Waiting for you"
    case .stopping: return "Stopping…"
    case .reconciling: return "Outcome unknown"
    case .terminal: return turn.outcome?.rawValue ?? "finished"
    }
  }
}
