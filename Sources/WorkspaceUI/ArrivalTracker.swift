import Foundation
import WorkspaceProtocol

/// A thread that has just entered the top list (approve, reply, failed, or finished): its row slides
/// in and its edge is traced (`arrivalTrace`). `laps` is false when another arrival's point of light
/// was still lapping at `at`, so only one row laps at a time (decision 9).
public struct Arrival: Equatable, Hashable, Sendable {
  public var threadId: String
  public var at: Date
  public var laps: Bool

  public init(threadId: String, at: Date, laps: Bool) {
    self.threadId = threadId
    self.at = at
    self.laps = laps
  }

  /// How long the point of light laps the edge: two laps in all.
  public static let lapDuration: TimeInterval = 3.5
  /// How long the arrival lasts; the hairline has faded out by then.
  public static let lifetime: TimeInterval = 10

  public func isLapping(at now: Date) -> Bool { laps && now < at.addingTimeInterval(Self.lapDuration) }
  public func isLive(at now: Date) -> Bool { now < at.addingTimeInterval(Self.lifetime) }
}

/// Which threads have just arrived in the top list, from successive states of the list. A pure value:
/// it owns no timers, and every call says what time it is.
public struct ArrivalTracker: Equatable, Sendable {
  /// The states of the last update; nil until the first update after `reset()`.
  private var states: [String: ThreadState]?
  private var arrivals: [String: Arrival] = [:]

  public init() {}

  /// Records the list's states and returns the threads that arrived since the last update: top-list now,
  /// and not top-list (or not listed) before. The first update after `reset()` only records. A thread
  /// that leaves the top list, or the list, loses its arrival.
  public mutating func update(_ states: [String: ThreadState], at now: Date) -> [Arrival] {
    defer { self.states = states }
    arrivals = arrivals.filter { id, arrival in arrival.isLive(at: now) && states[id]?.isTopList == true }
    guard let previous = self.states else { return [] }
    var lapping = arrivals.values.contains { $0.isLapping(at: now) }
    // The most urgent arrival laps when several arrive at once.
    let entered =
      states
      .filter { id, state in state.isTopList && previous[id]?.isTopList != true }
      .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
    return entered.map { id, _ in
      let arrival = Arrival(threadId: id, at: now, laps: !lapping)
      lapping = true
      arrivals[id] = arrival
      return arrival
    }
  }

  /// Records the list's states as the new baseline without tracing anything: the owner's own action
  /// (Mark as Unread, a mark-read rollback, unarchiving) or a change to which threads the filter shows
  /// moved threads, and none of them arrived. Unlike `reset()`, another thread's live trace goes on; a
  /// thread that left the top list, or the list, loses its arrival, as in `update`.
  public mutating func record(_ states: [String: ThreadState], at now: Date) {
    arrivals = arrivals.filter { id, arrival in arrival.isLive(at: now) && states[id]?.isTopList == true }
    self.states = states
  }

  /// The thread's arrival while it lasts (10 s from its `at`).
  public func arrival(for threadId: String, at now: Date) -> Arrival? {
    arrivals[threadId].flatMap { $0.isLive(at: now) ? $0 : nil }
  }

  /// Forgets every state and arrival, so the next update traces nothing: a sign-in, a sign-out, or a
  /// filter change rebuilds the list without anything having arrived.
  public mutating func reset() {
    states = nil
    arrivals = [:]
  }
}
