import Foundation
import Testing

@testable import WorkspaceProtocol

@Suite struct UsageTests {
  @Test func usageReadingRoundTrips() throws {
    let reading = UsageReading(
      fiveHour: UsageWindow(usedPercent: 62, windowMinutes: 300, resetsAt: "2026-11-01T20:00:00Z"),
      weekly: UsageWindow(usedPercent: 31, windowMinutes: 10080, resetsAt: nil),
      blocked: false, planType: "pro", observedAt: "2026-11-01T18:00:00Z")
    let usage = ConnectionUsage(connectionId: "c", reading: reading, tokens: TokenTotals(today: 3, week: 9))
    let decoded = try JSONDecoder().decode(ConnectionUsage.self, from: JSONEncoder().encode(usage))
    #expect(decoded == usage)
    #expect(decoded.id == "c")
  }

  @Test func newMethodsAreAllowlistedWithTheRightMutability() {
    #expect(Method(rawValue: "usage.read")?.isMutation == false)
    #expect(Method(rawValue: "connection.update")?.isMutation == true)
    #expect(UsageRead.method == .usageRead)
    #expect(ConnectionUpdate.method == .connectionUpdate)
  }

  @Test func connectionChangedCarriesTheAttempt() throws {
    let checking = AdapterEvent.connectionChanged(
      connectionId: "c", status: .connecting, authStatus: .unknown, transport: .disconnected,
      message: "Checking…", attempt: 2, attempts: 3)
    #expect(checking.payload["attempt"]?.numberValue == 2)
    #expect(checking.payload["attempts"]?.numberValue == 3)
    let plain = AdapterEvent.connectionChanged(
      connectionId: "c", status: .ready, authStatus: .authenticated, transport: .connected)
    #expect(plain.payload["attempt"] == nil)
  }

  @Test func usageChangedCarriesTheReading() throws {
    let reading = UsageReading(blocked: true, observedAt: "2026-11-01T18:00:00Z")
    let event = try AdapterEvent.usageChanged(connectionId: "c", reading: reading)
    #expect(event.kind == .usageChanged)
    #expect(try event.payload["reading"]?.decode(UsageReading.self) == reading)
  }
}
