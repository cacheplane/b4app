import SwiftUI
import WorkspaceProtocol

struct ThreadsView: View {
  @Bindable var model: WorkspaceModel

  var body: some View {
    if let thread = model.threads.first(where: { $0.id == model.selectedThreadId }) {
      ThreadDetailView(thread: thread, connection: model.connection(id: thread.connectionId))
    } else {
      ContentUnavailableView {
        Label("Threads", systemImage: "bubble.left.and.bubble.right")
      } description: {
        Text(
          model.connections.isEmpty
            ? "Add a connection to start a conversation with Codex, Claude Code, or a B4 agent."
            : "Select a thread, or start a new one from a connection.")
      } actions: {
        Button("Add connection") { model.surface = .connections }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("add-connection")
      }
      .navigationTitle("Threads")
    }
  }
}

struct ThreadDetailView: View {
  let thread: ConversationThread
  let connection: Connection?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(thread.title.isEmpty ? "Untitled" : thread.title).font(.title2).bold()
        Text(
          "\(connection?.label ?? "Unknown connection") · \(connection?.kind.rawValue ?? "?") · \(thread.context ?? "no directory")"
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      Divider()
      Text("Conversation display and the composer arrive with the first provider slice (M1).")
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationTitle(thread.title.isEmpty ? "Untitled" : thread.title)
  }
}
