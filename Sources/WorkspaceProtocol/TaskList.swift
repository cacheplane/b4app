import Foundation

/// An agent's plan or task list for one turn: the display item every adapter writes for it, whatever
/// its runtime sends (Codex `turn/plan/updated`, Claude Code `TodoWrite` and the task tools, B4
/// `plan_update`). One item per turn, replaced whole on each update.
public struct TaskList: Equatable, Sendable {
  public static let itemType = "taskList"

  public enum Status: String, Sendable { case pending, inProgress, completed }

  public struct Step: Equatable, Sendable {
    public var text: String
    public var status: Status
    public init(text: String, status: Status) {
      self.text = text
      self.status = status
    }
  }

  public var steps: [Step]
  public var explanation: String?

  public init(steps: [Step], explanation: String? = nil) {
    self.steps = steps
    self.explanation = explanation
  }

  /// A runtime's word for a step's state. Anything unknown is pending: a step is never read as done
  /// or under way unless the runtime said so.
  public static func status(_ native: String?) -> Status {
    switch native {
    case "in_progress", "inProgress": return .inProgress
    case "completed": return .completed
    default: return .pending
    }
  }

  public static func nativeItemId(turn: String) -> String { "tasks:\(turn)" }

  public var completedCount: Int { steps.filter { $0.status == .completed }.count }

  /// The stored item. Its own `status` is `completed`, so nothing reads the row as an open tool.
  public var payload: JSONValue {
    var body: [String: JSONValue] = [
      "type": .string(Self.itemType), "status": "completed",
      "steps": .array(steps.map { ["text": .string($0.text), "status": .string($0.status.rawValue)] }),
    ]
    if let explanation { body["explanation"] = .string(explanation) }
    return .object(body)
  }

  /// Nil unless the payload is a task list's.
  public init?(payload: JSONValue) {
    guard payload["type"]?.stringValue == Self.itemType else { return nil }
    steps = (payload["steps"]?.arrayValue ?? []).map {
      Step(text: $0["text"]?.stringValue ?? "", status: Self.status($0["status"]?.stringValue))
    }
    explanation = payload["explanation"]?.stringValue
  }
}
