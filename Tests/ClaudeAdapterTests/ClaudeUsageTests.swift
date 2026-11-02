import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

private let observed = "2026-11-01T18:00:00.000Z"
// 2026-11-01T18:38:00Z and 2026-11-07T14:00:00Z.
private let fiveHourReset = 1_793_558_280.0
private let weeklyReset = 1_794_060_000.0

private let unified: JSONValue = [
  "status": "allowed", "rateLimitType": "five_hour", "utilization": 0.91, "resetsAt": .number(fiveHourReset),
  "unifiedWindows": [
    "five_hour": ["utilization": 0.91, "resetsAt": .number(fiveHourReset)],
    "seven_day": ["utilization": 0.48, "resetsAt": .number(weeklyReset)],
  ],
]

@Suite struct ClaudeUsageTests {
  @Test func mapsUnifiedWindows() throws {
    let reading = try #require(ClaudeUsage.reading(from: unified, observedAt: observed))
    #expect(reading.fiveHour?.usedPercent == 91)
    #expect(reading.fiveHour?.windowMinutes == 300)
    #expect(reading.fiveHour?.resetsAt == "2026-11-01T18:38:00.000Z")
    #expect(reading.weekly?.usedPercent == 48)
    #expect(reading.weekly?.windowMinutes == 10080)
    #expect(reading.weekly?.resetsAt == "2026-11-07T14:00:00.000Z")
    #expect(reading.blocked == false)
  }

  @Test func fallsBackToTheLimitingWindow() throws {
    let info: JSONValue = [
      "status": "allowed_warning", "rateLimitType": "seven_day", "utilization": 0.5,
      "resetsAt": .number(weeklyReset),
    ]
    let reading = try #require(ClaudeUsage.reading(from: info, observedAt: observed))
    #expect(reading.weekly?.usedPercent == 50)
    #expect(reading.weekly?.resetsAt == "2026-11-07T14:00:00.000Z")
    #expect(reading.fiveHour == nil)
  }

  @Test func keepsUtilizationPastTheCap() throws {
    let info: JSONValue = ["status": "allowed", "rateLimitType": "five_hour", "utilization": 1.2]
    #expect(try #require(ClaudeUsage.reading(from: info, observedAt: observed)).fiveHour?.usedPercent == 120)
  }

  @Test func rejectedIsBlocked() throws {
    let info: JSONValue = ["status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0]
    #expect(try #require(ClaudeUsage.reading(from: info, observedAt: observed)).blocked)
  }

  @Test func overageAloneIsNoReading() {
    let info: JSONValue = ["status": "allowed", "rateLimitType": "overage", "utilization": 0.2]
    #expect(ClaudeUsage.reading(from: info, observedAt: observed) == nil)
    #expect(ClaudeUsage.reading(from: ["status": "allowed"], observedAt: observed) == nil)
  }

  @Test func decodesTheFrame() {
    let line =
      #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","utilization":0.4},"uuid":"u","session_id":"s"}"#
    guard case .rateLimit(let info) = ClaudeStream.decodeFrame(line) else {
      Issue.record("rate_limit_event must decode as a rate-limit frame")
      return
    }
    #expect(info["utilization"]?.numberValue == 0.4)
  }

  @Test func aTurnEmitsUsageChanged() async throws {
    let rig = try Rig()
    let ref = try await rig.adapter.createSession(NewSessionInput(workingDirectory: rig.workDir))
    _ = try await rig.turn(ref, "hello")
    let event = try await rig.collector.waitFor { $0.kind == .usageChanged }
    #expect(event.connectionId == "c1")
    let reading = try #require(try event.payload["reading"]?.decode(UsageReading.self))
    #expect(reading.fiveHour?.usedPercent == 91)
    #expect(reading.weekly?.usedPercent == 48)
    await rig.adapter.dispose()
  }
}
