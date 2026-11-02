import Foundation
import Testing
import WorkspaceProtocol

@testable import CodexAdapter

private let observed = "2026-11-01T18:00:00.000Z"
// 2026-11-01T20:14:00Z and 2026-11-05T09:00:00Z.
private let fiveHourReset = 1_793_564_040.0
private let weeklyReset = 1_793_869_200.0

private func snapshot(
  primary: JSONValue = ["usedPercent": 62, "windowDurationMins": 300, "resetsAt": .number(fiveHourReset)],
  secondary: JSONValue = ["usedPercent": 31, "windowDurationMins": 10080, "resetsAt": .number(weeklyReset)],
  reached: JSONValue = .null, allowed: JSONValue = true
) -> JSONValue {
  [
    "rateLimits": [
      "limitId": "codex", "primary": primary, "secondary": secondary, "planType": "pro",
      "rateLimitReachedType": reached, "credits": .null,
    ],
    "ordinaryUsageAllowed": allowed,
  ]
}

@Suite struct CodexUsageTests {
  @Test func mapsPrimaryAndSecondaryWindows() throws {
    let reading = try #require(CodexUsage.reading(from: snapshot(), observedAt: observed))
    #expect(reading.fiveHour?.usedPercent == 62)
    #expect(reading.fiveHour?.windowMinutes == 300)
    #expect(reading.fiveHour?.resetsAt == "2026-11-01T20:14:00.000Z")
    #expect(reading.weekly?.usedPercent == 31)
    #expect(reading.weekly?.windowMinutes == 10080)
    #expect(reading.planType == "pro")
    #expect(reading.blocked == false)
    #expect(reading.observedAt == observed)
  }

  @Test func placesWindowsByDuration() throws {
    let swapped = snapshot(
      primary: ["usedPercent": 31, "windowDurationMins": 10080],
      secondary: ["usedPercent": 62, "windowDurationMins": 300])
    let reading = try #require(CodexUsage.reading(from: swapped, observedAt: observed))
    #expect(reading.fiveHour?.usedPercent == 62)
    #expect(reading.weekly?.usedPercent == 31)
  }

  @Test func blockedWhenOrdinaryUsageIsNotAllowedOrALimitIsReached() throws {
    let refused = try #require(CodexUsage.reading(from: snapshot(allowed: false), observedAt: observed))
    #expect(refused.blocked)
    let reached = try #require(
      CodexUsage.reading(from: snapshot(reached: "rate_limit_reached"), observedAt: observed))
    #expect(reached.blocked)
    // Unknown (null) is not a refusal: the schema says not to infer either way.
    let unknown = try #require(CodexUsage.reading(from: snapshot(allowed: .null), observedAt: observed))
    #expect(unknown.blocked == false)
  }

  @Test func noWindowsIsNoReading() {
    #expect(CodexUsage.reading(from: snapshot(primary: .null, secondary: .null), observedAt: observed) == nil)
    #expect(CodexUsage.reading(from: [:], observedAt: observed) == nil)
  }

  @Test func readUsageAsksTheAppServer() async throws {
    let adapter = CodexAdapter(connectionId: "c1", executablePath: fakeCodexPath(), clientVersion: "test")
    let reading = try #require(try await adapter.readUsage())
    #expect(reading.fiveHour?.usedPercent == 62)
    #expect(reading.weekly?.usedPercent == 31)
    #expect(reading.planType == "pro")
    await adapter.dispose()
  }

  @Test func rateLimitsUpdatedBecomesAUsageEvent() throws {
    let message = RpcMessage.notification(
      method: "account/rateLimits/updated", params: ["rateLimits": snapshot()["rateLimits"] ?? .null])
    let events = CodexEventTranslator.translate(message, connectionId: "c1", generation: 1)
    let event = try #require(events.first)
    #expect(event.kind == .usageChanged)
    let reading = try #require(try event.payload["reading"]?.decode(UsageReading.self))
    #expect(reading.fiveHour?.usedPercent == 62)
  }
}
