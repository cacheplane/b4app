import Foundation

/// Create a thread and send its first turn in one step. Reachable only through the relay (the phone
/// mints `threadId`; the command id is the turn's operationId), so a retry lands on the same thread and
/// the same turn. `folder` is required for Codex and Claude and must be one of the project's folders;
/// it is absent for a local B4 connection, whose thread is bound to its route.
public enum ThreadStart: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public var projectId: String
    public var connectionId: String
    public var folder: String?
    public var text: String
    public init(
      threadId: String, projectId: String, connectionId: String, folder: String? = nil, text: String
    ) {
      self.threadId = threadId
      self.projectId = projectId
      self.connectionId = connectionId
      self.folder = folder
      self.text = text
    }
  }
  public struct Result: Codable, Sendable, Equatable {
    public var thread: ConversationThread
    public var turn: Turn
    public init(thread: ConversationThread, turn: Turn) {
      self.thread = thread
      self.turn = turn
    }
  }
  public static let method = Method.threadStart
}

/// Settle a send whose reply never came: `in_flight` while the Mac is still running it, `found` with
/// the turn once a turn has that operationId, otherwise `none`. Read-only, and only relayed.
public enum TurnLookup: WorkspaceCommand {
  public struct Params: Codable, Sendable, Equatable {
    public var operationId: String
    public var threadId: String
    public init(operationId: String, threadId: String) {
      self.operationId = operationId
      self.threadId = threadId
    }
  }
  public enum State: String, Codable, Sendable, Equatable {
    case found
    case inFlight = "in_flight"
    case none
  }
  public struct Result: Codable, Sendable, Equatable {
    public var state: State
    public var turn: Turn?
    public init(state: State, turn: Turn? = nil) {
      self.state = state
      self.turn = turn
    }
  }
  public static let method = Method.turnLookup
}
