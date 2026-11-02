import Foundation

/// Delete a thread: it disappears from every list and device, the Mac deletes the runtime's copy where
/// the runtime can, and the thread is kept, marked deleted (settings: deleting threads). No undo.
public enum ThreadDelete: WorkspaceCommand {
  public static let method = Method.threadDelete
  public struct Params: Codable, Sendable, Equatable {
    public var threadId: String
    public init(threadId: String) { self.threadId = threadId }
  }
  public typealias Result = ThreadCreate.Result
}

/// Deleted threads whose runtime copy is still waiting to be deleted, or cannot be, for one runtime.
/// Counts only: Diagnostics shows no titles of deleted threads.
public struct ThreadDeleteSummary: Codable, Sendable, Equatable {
  public var kind: ConnectionKind
  public var waiting: Int
  public var unsupported: Int

  public init(kind: ConnectionKind, waiting: Int, unsupported: Int) {
    self.kind = kind
    self.waiting = waiting
    self.unsupported = unsupported
  }
}
