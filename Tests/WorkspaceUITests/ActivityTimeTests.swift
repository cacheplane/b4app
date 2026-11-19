import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite struct ActivityTimeTests {
  @Test func theClock() {
    let cases: [(Int, String)] = [
      (0, "0:00"), (42, "0:42"), (75, "1:15"), (3_599, "59:59"), (3_600, "1:00:00"), (-5, "0:00"),
      (3_725, "1:02:05"),
    ]
    for (seconds, words) in cases { #expect(ActivityTime.clock(seconds) == words, "\(seconds)") }
  }

  @Test func theDuration() {
    let cases: [(Int, String)] = [
      (0, "1s"), (8, "8s"), (59, "59s"), (60, "1m"), (72, "1m 12s"), (3_599, "59m 59s"), (3_600, "1h"),
      (3_840, "1h 4m"), (-3, "1s"),
    ]
    for (seconds, words) in cases { #expect(ActivityTime.duration(seconds) == words, "\(seconds)") }
  }

  @Test func theClockSpoken() {
    let cases: [(Int, String)] = [
      (0, "0 seconds"), (1, "1 second"), (42, "42 seconds"), (60, "1 minute"), (75, "1 minute 15 seconds"),
      (120, "2 minutes"), (3_600, "1 hour"), (3_725, "1 hour 2 minutes 5 seconds"), (-4, "0 seconds"),
    ]
    for (seconds, words) in cases { #expect(ActivityTime.words(seconds) == words, "\(seconds)") }
  }

  @Test func secondsBetweenTwoTimestamps() {
    #expect(ActivityTime.seconds(from: "2026-11-18T10:00:00.000Z", to: "2026-11-18T10:01:12.000Z") == 72)
    #expect(ActivityTime.seconds(from: "2026-11-18T10:00:00.000Z", to: "2026-11-18T10:00:01.900Z") == 1)
    #expect(ActivityTime.seconds(from: "nope", to: "2026-11-18T10:01:12.000Z") == nil)
    #expect(ActivityTime.seconds(from: "2026-11-18T10:00:00.000Z", to: "nope") == nil)
  }

  @Test func secondsSinceAStart() {
    let now = Date()
    #expect(
      ActivityTime.seconds(since: Timestamp.string(from: now.addingTimeInterval(-42.5)), now: now) == 42)
    // A start after `now` (a clock that disagrees) is 0, never negative.
    #expect(ActivityTime.seconds(since: Timestamp.string(from: now.addingTimeInterval(60)), now: now) == 0)
    #expect(ActivityTime.seconds(since: "nope", now: now) == 0)
  }
}
