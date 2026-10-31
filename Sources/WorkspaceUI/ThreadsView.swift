import SwiftUI
import WorkspaceProtocol

struct ThreadsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    if let thread = model.threads.first(where: { $0.id == model.selectedThreadId }) {
      ThreadDetailView(model: model, thread: thread)
    } else {
      ContentUnavailableView {
        Label("Threads", systemImage: "bubble.left.and.bubble.right")
      } description: {
        Text(
          model.connections.isEmpty
            ? "Add a connection to start a conversation with Codex, Claude Code, or a B4 agent."
            : "Select a thread, or start a new one.")
      } actions: {
        if model.conversationReadyConnections.isEmpty {
          Button("Add connection") { model.surface = .connections }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("add-connection")
        } else {
          Button("New thread") { model.showNewThread = true }
            .buttonStyle(.borderedProminent)
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

  private var connection: Connection? { model.connection(id: thread.connectionId) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let detail = model.detail, detail.thread.id == thread.id {
        TranscriptView(detail: detail)
        if !detail.requests.isEmpty {
          Divider()
          RuntimeRequestList(model: model, requests: detail.requests)
        }
        Divider()
        ComposerView(model: model, detail: detail)
      } else if model.detailLoading {
        ProgressView("Loading thread…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Text(model.lastError ?? "Thread not loaded.").foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(thread.title.isEmpty ? "Untitled" : thread.title)
    .task(id: thread.id) {
      if model.detail?.thread.id != thread.id { await model.openThread(id: thread.id) }
    }
    .toolbar {
      ToolbarItemGroup {
        Button(thread.pinned ? "Unpin" : "Pin", systemImage: thread.pinned ? "pin.slash" : "pin") {
          Task { await model.updateThread(id: thread.id, pinned: !thread.pinned) }
        }
        Button("Archive", systemImage: "archivebox") {
          Task {
            await model.updateThread(id: thread.id, archived: true)
            model.selectedThreadId = nil
          }
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(thread.title.isEmpty ? "Untitled" : thread.title).font(.title3).bold()
        Spacer()
        if let turn = model.detail?.activeTurn, model.detail?.thread.id == thread.id {
          TurnStatusBadge(turn: turn)
        }
      }
      Text(
        "\(connection?.label ?? "Unknown connection") · \(connection?.kind.rawValue ?? "?") · \(connection?.kind == .b4 ? "route \(thread.context ?? "?")" : (thread.context ?? "no directory"))"
      )
      .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }
}

struct TurnStatusBadge: View {
  let turn: Turn

  var body: some View {
    HStack(spacing: 6) {
      if turn.status == .running || turn.status == .submitting || turn.status == .stopping {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: icon)
      }
      Text(text)
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.quaternary, in: Capsule())
    .accessibilityIdentifier("turn-status")
  }

  private var icon: String {
    switch turn.status {
    case .waitingForUser: return "questionmark.bubble"
    case .reconciling: return "exclamationmark.triangle"
    default: return "circle"
    }
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
