import Foundation
import SwiftUI
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite struct ArrivalTrackerTests {
  private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

  /// A tracker that has seen `states` once, so the next update can trace.
  private func tracker(_ states: [String: ThreadState]) -> ArrivalTracker {
    var tracker = ArrivalTracker()
    _ = tracker.update(states, at: t0)
    return tracker
  }

  @Test func theFirstUpdateTracesNothing() {
    var tracker = ArrivalTracker()
    #expect(tracker.update(["a": .approve, "b": .finished, "c": .quiet], at: t0).isEmpty)
    #expect(tracker.arrival(for: "a", at: t0) == nil)
    #expect(tracker.arrival(for: "b", at: t0) == nil)
  }

  @Test func enteringTheTopListIsAnArrival() {
    var tracker = tracker(["a": .working, "b": .quiet])
    let at = t0.addingTimeInterval(5)
    let arrivals = tracker.update(["a": .finished, "b": .quiet], at: at)
    #expect(arrivals == [Arrival(threadId: "a", at: at, laps: true)])
    #expect(tracker.arrival(for: "a", at: at) == Arrival(threadId: "a", at: at, laps: true))
    #expect(tracker.arrival(for: "b", at: at) == nil)
  }

  @Test func movingWithinTheTopListIsNotAnArrival() {
    var tracker = tracker(["a": .finished, "b": .reply])
    let at = t0.addingTimeInterval(5)
    #expect(tracker.update(["a": .approve, "b": .failed], at: at).isEmpty)
    #expect(tracker.arrival(for: "a", at: at) == nil)
  }

  @Test func aNewThreadAlreadyInTheTopListIsAnArrival() {
    var tracker = tracker(["a": .quiet])
    let at = t0.addingTimeInterval(5)
    let arrivals = tracker.update(["a": .quiet, "b": .reply], at: at)
    #expect(arrivals == [Arrival(threadId: "b", at: at, laps: true)])
    // A new thread outside the top list is not one.
    #expect(tracker.update(["a": .quiet, "b": .reply, "c": .working], at: at).isEmpty)
  }

  @Test func aSecondArrivalWithinTheLapWindowDoesNotLap() {
    var tracker = tracker(["a": .working, "b": .working, "c": .working, "d": .working])
    let first = t0.addingTimeInterval(10)
    #expect(
      tracker.update(["a": .finished, "b": .working, "c": .working, "d": .working], at: first)
        == [Arrival(threadId: "a", at: first, laps: true)])
    // 3.4 s later the first lap is still running: the second gets the slide and the hairline only.
    let second = first.addingTimeInterval(3.4)
    #expect(
      tracker.update(["a": .finished, "b": .reply, "c": .working, "d": .working], at: second)
        == [Arrival(threadId: "b", at: second, laps: false)])
    // A non-lapping arrival opens no window of its own: at 3.5 s after the first, the next one laps.
    let third = first.addingTimeInterval(3.5)
    #expect(
      tracker.update(["a": .finished, "b": .reply, "c": .failed, "d": .working], at: third)
        == [Arrival(threadId: "c", at: third, laps: true)])
    // Two arrivals in one update: one laps, the most urgent.
    var both = self.tracker(["x": .working, "y": .working])
    let together = both.update(["x": .finished, "y": .approve], at: first)
    #expect(
      together == [
        Arrival(threadId: "y", at: first, laps: true), Arrival(threadId: "x", at: first, laps: false),
      ])
  }

  @Test func anArrivalExpiresAfterTenSeconds() {
    var tracker = tracker(["a": .working])
    let at = t0.addingTimeInterval(1)
    _ = tracker.update(["a": .reply], at: at)
    #expect(tracker.arrival(for: "a", at: at.addingTimeInterval(9.9)) != nil)
    #expect(tracker.arrival(for: "a", at: at.addingTimeInterval(10)) == nil)
    #expect(tracker.arrival(for: "a", at: at.addingTimeInterval(60)) == nil)
  }

  @Test func resetForgetsEverything() {
    var tracker = tracker(["a": .working])
    _ = tracker.update(["a": .reply], at: t0)
    tracker.reset()
    #expect(tracker.arrival(for: "a", at: t0) == nil)
    // The update after reset records and traces nothing, even a thread that was not top-list before.
    #expect(tracker.update(["a": .reply, "b": .finished], at: t0).isEmpty)
    #expect(
      tracker.update(["a": .reply, "b": .finished, "c": .failed], at: t0) == [
        Arrival(threadId: "c", at: t0, laps: true)
      ])
  }

  @Test func theTraceFollowsItsTimings() {
    func at(_ t: TimeInterval, laps: Bool = true, reduceMotion: Bool = false) -> ArrivalTraceFrame {
      ArrivalTraceFrame(elapsed: t, laps: laps, reduceMotion: reduceMotion)
    }
    // The slide: 12 pt below, eased out into place by 0.5 s.
    #expect(at(0).offset == 12)
    #expect(at(0.25).offset == 1.5)
    #expect(at(0.5).offset == 0)
    // The hairline: in by 0.5 s, full until 8.5 s, gone at 10 s.
    #expect(at(0).hairline == 0)
    #expect(at(0.5).hairline == 1)
    #expect(at(8.5).hairline == 1)
    #expect(at(9.25).hairline == 0.5)
    #expect(at(10) == .rest)
    #expect(at(60) == .rest)
    // The light: two laps in 3.5 s, faded in and out at the ends.
    #expect(at(0).light == 0)
    #expect(at(1.75).light == 1)
    #expect(at(1.75).head == 1)
    #expect(at(3.5).light == 0)
    #expect(at(5).light == 0)
    // No lap: the slide and the hairline only.
    #expect(at(1.75, laps: false).light == 0)
    #expect(at(0.25, laps: false).offset == 1.5)
    // Reduce Motion: the hairline only.
    #expect(at(0.25, reduceMotion: true).offset == 0)
    #expect(at(1.75, reduceMotion: true).light == 0)
    #expect(at(1.75, reduceMotion: true).hairline == 1)
  }

  @Test func theLightTravelsTheEdgeAtConstantSpeed() {
    func head(_ t: TimeInterval) -> Double {
      ArrivalTraceFrame(elapsed: t, laps: true, reduceMotion: false).head
    }
    // Linear in elapsed time along the perimeter: equal times cover equal lengths.
    let step = Arrival.lapDuration / 70
    for i in 0..<70 {
      let t = Double(i) * step
      #expect(abs(head(t) - 2 * t / Arrival.lapDuration) < 1e-9, "t = \(t)")
      #expect(abs((head(t + step) - head(t)) - 2 * step / Arrival.lapDuration) < 1e-9, "t = \(t)")
    }
    // Exactly two laps by 3.5 s, and no further.
    #expect(head(0) == 0)
    #expect(head(Arrival.lapDuration) == 2)
    #expect(head(5) == 2)
    // No lap, or Reduce Motion: the light never leaves the start.
    #expect(ArrivalTraceFrame(elapsed: 1, laps: false, reduceMotion: false).head == 0)
    #expect(ArrivalTraceFrame(elapsed: 1, laps: true, reduceMotion: true).head == 0)
  }

  @Test func theLitSegmentWrapsAcrossThePathsStart() {
    let length = ArrivalTraceFrame.segment
    #expect(length == 0.12)
    func total(_ pieces: [ArrivalTraceFrame.Piece]) -> Double { pieces.reduce(0) { $0 + $1.to - $1.from } }
    // Inside one lap: one piece, ending at the head.
    let inside = ArrivalTraceFrame.pieces(head: 0.5, length: length)
    #expect(inside.count == 1)
    #expect(abs(inside[0].from - 0.38) < 1e-9 && inside[0].to == 0.5)
    // Across the start: two pieces, the tail to the path's end and the start to the head, together the
    // segment's length with no gap and no overlap.
    let across = ArrivalTraceFrame.pieces(head: 1.05, length: length)
    #expect(across.count == 2)
    #expect(abs(across[0].from - 0.93) < 1e-9 && across[0].to == 1)
    #expect(across[1].from == 0 && abs(across[1].to - 0.05) < 1e-9)
    #expect(abs(total(across) - length) < 1e-9)
    // The same in the second lap, and at the very end of it.
    let second = ArrivalTraceFrame.pieces(head: 1.98 + 0.1, length: length)
    #expect(abs(total(second) - length) < 1e-9)
    #expect(second.allSatisfy { 0 <= $0.from && $0.from <= $0.to && $0.to <= 1 })
    let end = ArrivalTraceFrame.pieces(head: 2, length: length)
    #expect(end.count == 1 && abs(end[0].from - 0.88) < 1e-9 && end[0].to == 1)
    // At the start the light has not yet drawn a full segment behind it: it begins at the path's start.
    let start = ArrivalTraceFrame.pieces(head: 0.05, length: length)
    #expect(start.count == 1 && start[0].from == 0 && abs(start[0].to - 0.05) < 1e-9)
  }

  @Test func ownActionsRecordTheListWithoutTracing() {
    var tracker = tracker(["live": .working, "a": .quiet, "b": .working])
    let first = t0.addingTimeInterval(1)
    #expect(tracker.update(["live": .finished, "a": .quiet, "b": .working], at: first).count == 1)
    // Mark as unread: "a" enters the top list, recorded but not traced; the live trace stays.
    let later = first.addingTimeInterval(1)
    tracker.record(["live": .finished, "a": .finished, "b": .working], at: later)
    #expect(tracker.arrival(for: "a", at: later) == nil)
    #expect(tracker.arrival(for: "live", at: later) == Arrival(threadId: "live", at: first, laps: true))
    // The recorded list is the baseline: the next update does not see "a" arrive, but "b" does, and
    // the live lap still holds the one lap.
    let next = later.addingTimeInterval(1)
    #expect(
      tracker.update(["live": .finished, "a": .finished, "b": .reply], at: next)
        == [Arrival(threadId: "b", at: next, laps: false)])
    // A recorded list without a thread's top-list state drops that thread's trace, as an update does.
    tracker.record(["live": .quiet, "a": .finished, "b": .reply], at: next)
    #expect(tracker.arrival(for: "live", at: next) == nil)
    #expect(tracker.arrival(for: "b", at: next) != nil)
  }

  @Test func leavingAndReenteringTracesAgain() {
    var tracker = tracker(["a": .working])
    let first = t0.addingTimeInterval(1)
    #expect(tracker.update(["a": .finished], at: first) == [Arrival(threadId: "a", at: first, laps: true)])
    // Read: it leaves the top list, and its trace goes with it.
    let read = first.addingTimeInterval(1)
    #expect(tracker.update(["a": .quiet], at: read).isEmpty)
    #expect(tracker.arrival(for: "a", at: read) == nil)
    let again = first.addingTimeInterval(20)
    #expect(tracker.update(["a": .finished], at: again) == [Arrival(threadId: "a", at: again, laps: true)])
  }
}
