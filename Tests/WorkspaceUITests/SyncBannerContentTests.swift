import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite nonisolated struct SyncBannerContentTests {
  struct Scenario: Sendable, CustomStringConvertible {
    let name: String
    var lastError: String? = nil
    var lastSyncAt: String? = nil
    var relayRefused: String? = nil
    var syncPaused = false
    var expected: String? = nil
    var description: String { name }
  }

  private static let scenarios = [
    Scenario(name: "healthy without history"),
    Scenario(name: "healthy", lastSyncAt: "2026-11-05T10:30:00Z"),
    Scenario(
      name: "first failure", lastError: "Hub error 0 transport: internal diagnostic",
      expected: "Not synced yet. Retrying…"),
    Scenario(
      name: "invalid last success", lastError: "offline", lastSyncAt: "invalid",
      expected: "Not synced yet. Retrying…"),
    Scenario(
      name: "refusal overrides transient failure", lastError: "offline",
      relayRefused: "Log out, then sign in to reconnect.",
      expected: "Log out, then sign in to reconnect."),
    Scenario(
      name: "refusal without transient failure",
      relayRefused: "Log out, then sign in to reconnect.",
      expected: "Log out, then sign in to reconnect."),
    Scenario(name: "empty refusal remains present", relayRefused: "", expected: ""),
    Scenario(
      name: "paused without transient failure", syncPaused: true,
      expected: "Sync paused. Check Diagnostics."),
    Scenario(
      name: "paused overrides refusal and failure", lastError: "offline",
      relayRefused: "Log out, then sign in to reconnect.", syncPaused: true,
      expected: "Sync paused. Check Diagnostics."),
  ]

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  @Test(arguments: scenarios)
  func presentationPreservesVisibilityCopyAndPrecedence(_ scenario: Scenario) throws {
    let content = SyncBannerContent(
      lastError: scenario.lastError, lastSyncAt: scenario.lastSyncAt,
      relayRefused: scenario.relayRefused, syncPaused: scenario.syncPaused,
      now: try #require(Timestamp.date(from: "2026-11-05T12:00:00Z")),
      calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    #expect(content.text == scenario.expected)
    #expect(SyncBannerContent.signInRequiredMessage == "Log out, then sign in to reconnect.")
  }

  @Test func todayShowsTimeWithoutRepeatingTheDate() throws {
    let content = SyncBannerContent(
      lastError: "raw server diagnostic", lastSyncAt: "2026-11-05T10:30:00Z",
      now: try #require(Timestamp.date(from: "2026-11-05T12:00:00Z")),
      calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    let text = try #require(content.text)
    #expect(text.hasPrefix("Last synced "))
    #expect(text.contains("10:30") && text.contains("AM"))
    #expect(!text.contains("Nov") && !text.contains("2026"))
    #expect(!text.contains("diagnostic"))
    #expect(text.hasSuffix(". Retrying…"))
  }

  @Test func earlierDayIncludesItsDateAndTime() throws {
    let content = SyncBannerContent(
      lastError: "raw transport diagnostic", lastSyncAt: "2026-11-04T10:30:00Z",
      now: try #require(Timestamp.date(from: "2026-11-05T12:00:00Z")),
      calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    let text = try #require(content.text)
    #expect(text.hasPrefix("Last synced "))
    #expect(text.contains("Nov 4") && text.contains("2026"))
    #expect(text.contains("10:30") && text.contains("AM"))
    #expect(!text.contains("diagnostic"))
    #expect(text.hasSuffix(". Retrying…"))
  }
}
