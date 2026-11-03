import Foundation
import Testing
import WorkspaceProtocol
import WorkspaceTestSupport

@testable import WorkspaceStorage

private func seed(_ db: WorkspaceDatabase, _ id: String = "c1", kind: ConnectionKind = .codex) throws {
  _ = try db.insertConnection(Connection(id: id, kind: kind, label: id, target: "/x/\(id)"))
}

@Suite struct UsageStoreTests {
  @Test func usageReadingIsReplacedPerConnection() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    let first = UsageReading(
      fiveHour: UsageWindow(usedPercent: 10), observedAt: "2026-11-01T10:00:00.000Z")
    let second = UsageReading(
      fiveHour: UsageWindow(usedPercent: 62, windowMinutes: 300, resetsAt: "2026-11-01T15:00:00.000Z"),
      weekly: UsageWindow(usedPercent: 31), blocked: true, planType: "pro",
      observedAt: "2026-11-01T11:00:00.000Z")
    try db.saveUsage(connectionId: "c1", reading: first)
    try db.saveUsage(connectionId: "c1", reading: second)
    let readings = try db.usageReadings()
    #expect(readings.count == 1)
    #expect(readings["c1"] == second)
  }

  @Test func tokensSumSinceABoundaryAndCountATurnOnce() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db, kind: .b4)
    try seed(db, "c2", kind: .b4)
    try db.recordTokens(turnId: "t1", connectionId: "c1", total: 100, at: "2026-11-01T09:00:00.000Z")
    try db.recordTokens(turnId: "t2", connectionId: "c1", total: 50, at: "2026-11-01T11:00:00.000Z")
    try db.recordTokens(turnId: "t2", connectionId: "c1", total: 50, at: "2026-11-01T11:05:00.000Z")
    try db.recordTokens(turnId: "t3", connectionId: "c2", total: 7, at: "2026-11-01T11:00:00.000Z")
    #expect(try db.tokenTotals(connectionId: "c1", since: "2026-11-01T10:00:00.000Z") == 50)
    #expect(try db.tokenTotals(connectionId: "c1", since: "2026-11-01T08:00:00.000Z") == 150)
    #expect(try db.tokenTotals(connectionId: "c2", since: "2026-11-01T08:00:00.000Z") == 7)
    #expect(try db.tokenTotals(connectionId: "none", since: "2026-11-01T08:00:00.000Z") == 0)
  }

  @Test func usageTablesAreNotInTheChangeLog() throws {
    let db = try WorkspaceDatabase.temporary()
    try seed(db)
    try db.saveUsage(connectionId: "c1", reading: UsageReading(observedAt: "2026-11-01T10:00:00.000Z"))
    try db.recordTokens(turnId: "t1", connectionId: "c1", total: 5, at: "2026-11-01T10:00:00.000Z")
    let tables = Set(try db.changes(after: 0).map(\.table))
    #expect(!tables.contains("usageReadings"))
    #expect(!tables.contains("tokenUsage"))
    #expect(tables.contains("connections"))
  }
}
