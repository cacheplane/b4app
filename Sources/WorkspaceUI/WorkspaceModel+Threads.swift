import Foundation
import WorkspaceClient
import WorkspaceProtocol

/// Deleting threads: the confirmation's words and the delete itself. A deleted thread is hidden on
/// every device and never used for personal memory; there is no undo.
extension WorkspaceModel {
  /// Delete a thread. It leaves the list (and closes if open) once the coordinator, or the phone's
  /// mirror, has marked it. False when the delete was refused; `lastError` says why.
  @discardableResult
  public func deleteThread(id: String) async -> Bool {
    let deleted: ConversationThread? = await perform {
      try await $0.request(
        ThreadDelete.self, ThreadDelete.Params(threadId: id), options: Self.mutation(timeout: .seconds(45))
      ).thread
    }
    guard deleted != nil else { return false }
    forget(threadId: id)
    return true
  }

  /// The confirmation alert's title and message. The runtime is named only when the thread's
  /// connection is enabled, since only then will its copy be deleted too.
  public func deleteConfirmation(for thread: ConversationThread) -> (title: String, message: String) {
    let connection = connections.first { $0.id == thread.connectionId }
    var message: String
    if let connection, connection.enabled {
      message =
        "It's removed from this app and from \(Self.runtimeName(connection.kind)). You can't undo this."
    } else {
      message = "It's removed from this app. You can't undo this."
    }
    if activeTurns[thread.id] != nil { message += " Its running turn will be stopped." }
    return ("Delete \"\(thread.title.isEmpty ? "Untitled" : thread.title)\"?", message)
  }

  static func runtimeName(_ kind: ConnectionKind) -> String {
    switch kind {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .b4: return "the B4 server"
    }
  }
}
