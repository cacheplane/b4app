import Foundation
import WorkspaceProtocol

/// A runtime as a new thread used it: the connection and, for Codex and Claude, the model and
/// permission chosen (nil for the runtime's default and "As configured").
struct RuntimeChoice: Codable, Equatable {
  var connectionId: String
  var model: String?
  var permission: String?
}

/// What the new-thread composer remembers on this device, never synced: the project the last thread
/// was started in, the last starting folder and runtime of each project, the last runtime anywhere,
/// and the unsent first message. Ids may name what no longer exists; the draft falls back past them.
struct NewThreadMemory: Codable, Equatable {
  static let key = "newThread.memory"

  var projectId: String?
  var folderByProject: [String: String] = [:]
  var runtimeByProject: [String: RuntimeChoice] = [:]
  var lastRuntime: RuntimeChoice?
  var text = ""

  /// The stored memory; an empty one when there is none or it cannot be read.
  static func load(from preferences: any LocalPreferences) -> Self {
    guard let data = preferences.data(forKey: key),
      let memory = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return memory
  }

  func save(to preferences: any LocalPreferences) {
    preferences.set(try? JSONEncoder().encode(self), forKey: Self.key)
  }

  /// Load, change, and save, so two writers never undo each other's fields.
  static func update(_ preferences: any LocalPreferences, _ change: (inout Self) -> Void) {
    var memory = load(from: preferences)
    let before = memory
    change(&memory)
    if memory != before { memory.save(to: preferences) }
  }

  /// A start the Mac accepted: its project (the one the coordinator resolved, when the Mac chose a
  /// folder outside every project), starting folder, and runtime are now the last ones. A remote B4
  /// start has no project and leaves the remembered one alone.
  mutating func remember(_ start: ThreadStart.Params, thread: ConversationThread?) {
    let choice = RuntimeChoice(
      connectionId: start.connectionId, model: start.model, permission: start.permission)
    lastRuntime = choice
    guard let project = thread?.projectId ?? start.projectId else { return }
    projectId = project
    runtimeByProject[project] = choice
    // A B4 thread has no folder (its context is the route). The thread's own context is the folder as
    // the coordinator wrote it, the same form as the project's folder list.
    if let folder = start.folder { folderByProject[project] = thread?.context ?? folder }
  }
}
