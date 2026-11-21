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
  /// connection is enabled and still signed in as the thread's identity, since only then will its copy
  /// be deleted too.
  public func deleteConfirmation(for thread: ConversationThread) -> (title: String, message: String) {
    let connection = connections.first { $0.id == thread.connectionId }
    var message: String
    let canReachRuntime = connection.map { $0.kind == .codex || $0.kind == .claude } ?? false
    if let connection, canReachRuntime, connection.enabled, !thread.identityChanged(on: connection) {
      message =
        "It's removed from this app and from \(Self.runtimeName(connection.kind)). You can't undo this."
    } else {
      message = "It's removed from this app. You can't undo this."
    }
    if canReachRuntime, activeTurns[thread.id] != nil { message += " Its running turn will be stopped." }
    return ("Delete \"\(thread.title.isEmpty ? "Untitled" : thread.title)\"?", message)
  }

  static func runtimeName(_ kind: ConnectionKind) -> String {
    switch kind {
    case .codex: return "Codex"
    case .claude: return "Claude Code"
    case .b4: return "the B4 server"
    case .agentProtocol: return "the Agent Protocol server"
    }
  }
}

/// A thread's model and permission, changed from the picker row under its composer.
extension WorkspaceModel {
  /// Choose the model or permission a thread's next turn uses; nil leaves that one as it is (no
  /// override, once made, can be cleared: Codex keeps a turn's override for later turns). The phone's
  /// change is a synced field the Mac applies on the next turn, never a relayed call. A refusal (a B4
  /// thread, a permission the runtime lacks) shows in `lastError`.
  public func setThreadRuntime(threadId: String, model: String?, permission: String?) async {
    guard model != nil || permission != nil else { return }
    let updated: ConversationThread? = await perform {
      try await $0.request(
        ThreadUpdate.self,
        ThreadUpdate.Params(threadId: threadId, model: model, permission: permission),
        options: Self.mutation()
      ).thread
    }
    if let updated { store(updated) }
  }
}
