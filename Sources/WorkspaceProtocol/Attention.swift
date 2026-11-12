import Foundation

/// What a thread row says about a thread: the raw value is the display rank, so sorting by state puts
/// the threads that need the owner first.
public enum ThreadState: Int, Codable, Sendable, Comparable, CaseIterable {
  /// A request for approval is pending.
  case approve = 0
  /// A question is pending, or the latest turn waits for the user.
  case reply = 1
  /// The latest turn failed, read or not.
  case failed = 2
  /// The latest turn ended (completed or cancelled) and the owner has not read it.
  case finished = 3
  /// The latest turn has not ended.
  case working = 4
  /// Nothing to do: no turns, or the latest turn ended and was read.
  case quiet = 5

  public static func < (lhs: ThreadState, rhs: ThreadState) -> Bool { lhs.rawValue < rhs.rawValue }

  /// Approve, reply, and failed: the owner has something to act on.
  public var isActLevel: Bool { self <= .failed }

  /// The act-level states and finished: the threads that sit at the top of the list.
  public var isTopList: Bool { self <= .finished }
}

extension RuntimeRequestKind {
  /// A request that asks for a decision on an action (approve state) rather than an answer (reply).
  public var isApproval: Bool {
    switch self {
    case .commandApproval, .fileChangeApproval, .toolPermission: true
    case .userQuestion, .elicitation, .unknown: false
    }
  }
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
  /// The pending requests whose kind `isApproval`; the rest of `pendingRequests` are questions. Absent
  /// on the wire reads as 0.
  public var pendingApprovals: Int
  /// The newest of the thread's `createdAt` and its latest turn's and requests' `updatedAt`. Never
  /// the thread's own `updatedAt`, which moves on renames and pins.
  public var lastActivityAt: String

  public init(
    latestTurnId: String? = nil, latestTurnStatus: TurnStatus? = nil, latestTurnOutcome: TurnOutcome? = nil,
    pendingRequests: Int = 0, pendingApprovals: Int = 0, lastActivityAt: String
  ) {
    self.latestTurnId = latestTurnId
    self.latestTurnStatus = latestTurnStatus
    self.latestTurnOutcome = latestTurnOutcome
    self.pendingRequests = pendingRequests
    self.pendingApprovals = pendingApprovals
    self.lastActivityAt = lastActivityAt
  }

  private enum CodingKeys: String, CodingKey {
    case latestTurnId, latestTurnStatus, latestTurnOutcome, pendingRequests, pendingApprovals, lastActivityAt
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    latestTurnId = try c.decodeIfPresent(String.self, forKey: .latestTurnId)
    latestTurnStatus = try c.decodeIfPresent(TurnStatus.self, forKey: .latestTurnStatus)
    latestTurnOutcome = try c.decodeIfPresent(TurnOutcome.self, forKey: .latestTurnOutcome)
    pendingRequests = try c.decode(Int.self, forKey: .pendingRequests)
    pendingApprovals = try c.decodeIfPresent(Int.self, forKey: .pendingApprovals) ?? 0
    lastActivityAt = try c.decode(String.self, forKey: .lastActivityAt)
  }
}

public enum Attention {
  /// The first rule that holds: no `activity` is quiet; a pending approval is approve (it wins over a
  /// pending question); any other pending request is reply; no turn is quiet; a latest turn waiting
  /// for the user is reply; one that has not ended is working; one that failed is failed, read or
  /// not; one the owner has not read is finished (completed or cancelled); else quiet.
  public static func state(of thread: ConversationThread) -> ThreadState {
    guard let activity = thread.activity else { return .quiet }
    if activity.pendingApprovals > 0 { return .approve }
    if activity.pendingRequests > 0 { return .reply }
    guard let turnId = activity.latestTurnId, let status = activity.latestTurnStatus else { return .quiet }
    if status == .waitingForUser { return .reply }
    if status != .terminal { return .working }
    if activity.latestTurnOutcome == .failed { return .failed }
    return turnId != thread.readTurnId ? .finished : .quiet
  }

  /// By state, then pinned first, then newest activity first, ties by `id`. A pin never lifts a
  /// thread above a more urgent state. Threads without `activity` count from their creation.
  public static func ordered(_ threads: [ConversationThread]) -> [ConversationThread] {
    ordered(threads, by: state(of:))
  }

  /// The same order with the state a list ranks each thread by (`rank`), for a list that holds a
  /// thread above its real state (the selected thread, in `WorkspaceUI`).
  public static func ordered(
    _ threads: [ConversationThread], by rank: (ConversationThread) -> ThreadState
  ) -> [ConversationThread] {
    func key(_ thread: ConversationThread) -> (state: ThreadState, pinned: Bool, at: String, id: String) {
      (rank(thread), thread.pinned, thread.activity?.lastActivityAt ?? thread.createdAt, thread.id)
    }
    return threads.map { (key($0), $0) }.sorted { lhs, rhs in
      let (l, r) = (lhs.0, rhs.0)
      if l.state != r.state { return l.state < r.state }
      if l.pinned != r.pinned { return l.pinned }
      if l.at != r.at { return l.at > r.at }
      return l.id < r.id
    }.map(\.1)
  }

  /// Whether the thread counts toward the app icon's badge: a pending request (approve, or a reply
  /// that has one), or a latest turn that ended and is unread (finished, or failed while unread).
  /// This is the hub's badge SQL (`Tests/Fixtures/sync/attention.json`), so a turn waiting for the
  /// user without a request, which reads as reply, does not count.
  public static func countsTowardBadge(_ thread: ConversationThread) -> Bool {
    guard let activity = thread.activity else { return false }
    switch state(of: thread) {
    case .approve, .finished: return true
    case .reply: return activity.pendingRequests > 0
    case .failed: return activity.latestTurnId != thread.readTurnId
    case .working, .quiet: return false
    }
  }
}
