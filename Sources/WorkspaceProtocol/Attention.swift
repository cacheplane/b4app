import Foundation

/// Where a thread sits in the sidebar: the raw value is the display rank, so sorting by band puts
/// threads that need the owner first.
public enum AttentionBand: Int, Codable, Sendable, Comparable {
  case needsInput = 0
  case unread = 1
  case working = 2
  case quiet = 3

  public static func < (lhs: AttentionBand, rhs: AttentionBand) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a thread has been doing, computed on read from its turns and runtime requests (never a
/// database column).
public struct ThreadActivity: Codable, Sendable, Equatable {
  /// The latest turn by `createdAt`, ties by `id`.
  public var latestTurnId: String?
  public var latestTurnStatus: TurnStatus?
  public var latestTurnOutcome: TurnOutcome?
  /// Runtime requests in state `pending`, across all of the thread's turns.
  public var pendingRequests: Int
  /// The newest of the thread's `createdAt` and its latest turn's and requests' `updatedAt`. Never
  /// the thread's own `updatedAt`, which moves on renames and pins.
  public var lastActivityAt: String

  public init(
    latestTurnId: String? = nil, latestTurnStatus: TurnStatus? = nil, latestTurnOutcome: TurnOutcome? = nil,
    pendingRequests: Int = 0, lastActivityAt: String
  ) {
    self.latestTurnId = latestTurnId
    self.latestTurnStatus = latestTurnStatus
    self.latestTurnOutcome = latestTurnOutcome
    self.pendingRequests = pendingRequests
    self.lastActivityAt = lastActivityAt
  }
}

public enum Attention {
  /// Needs input when any request is pending (even on an older turn); working when the latest turn
  /// has not finished; unread when it finished and is not the turn the owner last read; else quiet.
  /// A thread without `activity` is quiet.
  public static func band(of thread: ConversationThread) -> AttentionBand {
    guard let activity = thread.activity else { return .quiet }
    if activity.pendingRequests > 0 { return .needsInput }
    guard let turnId = activity.latestTurnId, let status = activity.latestTurnStatus else { return .quiet }
    if status != .terminal { return .working }
    return turnId != thread.readTurnId ? .unread : .quiet
  }

  /// Pinned first, then by band, then newest activity first, ties by `id`. Threads without
  /// `activity` count from their creation.
  public static func ordered(_ threads: [ConversationThread]) -> [ConversationThread] {
    func key(_ thread: ConversationThread) -> (pinned: Bool, band: AttentionBand, at: String, id: String) {
      (thread.pinned, band(of: thread), thread.activity?.lastActivityAt ?? thread.createdAt, thread.id)
    }
    return threads.sorted { lhs, rhs in
      let l = key(lhs)
      let r = key(rhs)
      if l.pinned != r.pinned { return l.pinned }
      if l.band != r.band { return l.band < r.band }
      if l.at != r.at { return l.at > r.at }
      return l.id < r.id
    }
  }
}
