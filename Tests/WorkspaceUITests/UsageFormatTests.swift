import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

private func date(_ iso: String) -> Date { Timestamp.date(from: iso)! }

private var utc: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  calendar.locale = Locale(identifier: "en_US")
  return calendar
}

@Suite struct UsageFormatTests {
  let now = date("2026-11-01T18:00:00.000Z")

  @Test func percentRoundsAndKeepsOverflow() {
    #expect(UsageFormat.percent(62) == "62%")
    #expect(UsageFormat.percent(61.6) == "62%")
    #expect(UsageFormat.percent(120) == "120%")
  }

  @Test func fillClampsToTheBar() {
    #expect(UsageFormat.fill(62) == 0.62)
    #expect(UsageFormat.fill(120) == 1)
    #expect(UsageFormat.fill(-3) == 0)
  }

  @Test func hotFromNinetyPercent() {
    #expect(UsageFormat.isHot(89.9) == false)
    #expect(UsageFormat.isHot(90))
  }

  @Test func resetsInMinutesHoursOrADay() {
    #expect(UsageFormat.resets("2026-11-01T18:38:00.000Z", now: now, calendar: utc) == "Resets in 38m")
    #expect(UsageFormat.resets("2026-11-01T20:14:00.000Z", now: now, calendar: utc) == "Resets in 2h 14m")
    #expect(UsageFormat.resets("2026-11-01T20:00:00.000Z", now: now, calendar: utc) == "Resets in 2h")
    #expect(
      UsageFormat.resets("2026-11-05T09:00:00.000Z", now: now, calendar: utc) == "Resets Thu 9:00\u{202F}AM")
    #expect(UsageFormat.resets("2026-11-01T17:00:00.000Z", now: now, calendar: utc) == "Reset")
    #expect(UsageFormat.resets(nil, now: now, calendar: utc) == nil)
  }

  @Test func ageReadsLikeAClock() {
    #expect(UsageFormat.age("2026-11-01T17:59:30.000Z", now: now) == "Just now")
    #expect(UsageFormat.age("2026-11-01T17:40:00.000Z", now: now) == "As of 20 min ago")
    #expect(UsageFormat.age("2026-11-01T15:00:00.000Z", now: now) == "As of 3 h ago")
    #expect(UsageFormat.age("2026-10-30T18:00:00.000Z", now: now) == "As of 2 days ago")
    #expect(UsageFormat.age("2026-10-31T17:00:00.000Z", now: now) == "As of 1 day ago")
  }

  @Test func tokensAreCompact() {
    #expect(UsageFormat.tokens(999) == "999")
    #expect(UsageFormat.tokens(412_300) == "412k")
    #expect(UsageFormat.tokens(2_140_000) == "2.1M")
    #expect(UsageFormat.tokens(12_000_000) == "12M")
    #expect(UsageFormat.tokens(1_500) == "1.5k")
  }

  @Test func statusFromAConnection() {
    var connection = Connection(
      id: "c", kind: .codex, label: "Codex", target: "", status: .ready, authStatus: .authenticated)
    #expect(LLAStatus(connection: connection, checking: false, blocked: false) == .ok)
    #expect(LLAStatus(connection: connection, checking: true, blocked: false) == .busy)
    #expect(LLAStatus(connection: connection, checking: false, blocked: true) == .attention)
    connection.authStatus = .required
    #expect(LLAStatus(connection: connection, checking: false, blocked: false) == .attention)
    connection.authStatus = .authenticated
    connection.status = .offline
    #expect(LLAStatus(connection: connection, checking: false, blocked: false) == .attention)
    connection.status = .connecting
    #expect(LLAStatus(connection: connection, checking: false, blocked: false) == .busy)
    connection.status = .unconfigured
    #expect(LLAStatus(connection: connection, checking: false, blocked: false) == .idle)
    #expect(LLAStatus.ok.label == "Connected")
    #expect(LLAStatus.attention.label == "Needs attention")
  }

  @Test func statusFromAServer() {
    #expect(LLAStatus(health: .ready) == .ok)
    #expect(LLAStatus(health: .starting) == .busy)
    #expect(LLAStatus(health: .unhealthy) == .attention)
    #expect(LLAStatus(health: .stopped) == .idle)
  }
}
