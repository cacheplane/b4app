import Foundation
import WorkspaceProtocol

/// Claude Code's task list, built from the tools that keep it. `TodoWrite` sends the whole list;
/// `TaskCreate` and `TaskUpdate` send one change each, and a created task's number is only in its
/// result ("Task #3 created successfully"). Every change is made when its result arrives, so a use
/// Claude Code reports as failed changes nothing (D-246). The list lives for the session, so the fold
/// does too: the live tracker and the history import both run their tool uses and results through one.
///
/// A turn that changes the list gets one item holding the whole list as it then stands, named after
/// the tool use that first changed it in that turn. The app's turn id is not in Claude Code's
/// transcript, and a tool use's id is in both, so history finds the row the live turn wrote.
struct ClaudeTaskFold: Sendable {
  static let toolNames: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]

  private var steps: [(id: String?, step: TaskList.Step)] = []
  /// Uses whose result is still to come, by tool use id. A use is forgotten at its result, so a long
  /// session keeps only the ones a stopped turn left without one.
  private var uses: [String: (name: String, input: JSONValue)] = [:]
  private var itemId: String?

  /// A new turn: the next change starts a new item.
  mutating func beginTurn() { itemId = nil }

  /// Whether `use` was given this tool use and its result is still to come: that result is the
  /// fold's, not a tool row's.
  func owns(toolUseId: String) -> Bool { uses[toolUseId] != nil }

  /// A tool use by one of `toolNames`. It changes nothing until its result.
  mutating func use(id: String, name: String, input: JSONValue) {
    uses[id] = (name, input)
  }

  /// The result of a use given to `use`. The turn's item when the list changed.
  mutating func result(toolUseId: String, text: String, isError: Bool) -> SnapshotItem? {
    guard let use = uses.removeValue(forKey: toolUseId), !isError else { return nil }
    switch use.name {
    case "TodoWrite":
      guard let todos = use.input["todos"]?.arrayValue else { return nil }
      steps = todos.map {
        (
          nil,
          TaskList.Step(
            text: $0["content"]?.stringValue ?? "", status: TaskList.status($0["status"]?.stringValue))
        )
      }
    case "TaskCreate":
      guard let number = Self.taskNumber(in: text) else { return nil }
      steps.append((number, TaskList.Step(text: use.input["subject"]?.stringValue ?? "", status: .pending)))
    case "TaskUpdate":
      guard let taskId = use.input["taskId"]?.stringValue,
        let index = steps.firstIndex(where: { $0.id == taskId })
      else { return nil }
      let before = steps[index].step
      if use.input["status"]?.stringValue == "deleted" {
        steps.remove(at: index)
      } else {
        if let status = use.input["status"]?.stringValue {
          steps[index].step.status = TaskList.status(status)
        }
        if let subject = use.input["subject"]?.stringValue { steps[index].step.text = subject }
        if steps[index].step == before { return nil }
      }
    default:
      return nil
    }
    return item(changedBy: toolUseId)
  }

  private mutating func item(changedBy toolUseId: String) -> SnapshotItem {
    let id = itemId ?? TaskList.nativeItemId(turn: toolUseId)
    itemId = id
    return SnapshotItem(
      nativeItemId: id, role: DisplayItemRole.tool.rawValue, type: TaskList.itemType,
      payload: TaskList(steps: steps.map(\.step)).payload)
  }

  /// The number in "Task #3 created successfully".
  static func taskNumber(in text: String) -> String? {
    guard let hash = text.range(of: "Task #") else { return nil }
    let digits = text[hash.upperBound...].prefix { $0.isASCII && $0.isNumber }
    return digits.isEmpty ? nil : String(digits)
  }
}
