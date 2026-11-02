import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

private func connection(
  _ kind: ConnectionKind, status: ConnectionStatus = .ready, auth: AuthStatus = .authenticated,
  target: String = "", scope: String? = "owner@example.com"
) -> Connection {
  Connection(
    id: "c", kind: kind, label: "x", target: target, nativeScope: scope, status: status, authStatus: auth)
}

@Suite struct ConnectionCardTests {
  @Test func subtitleNamesThePlanAndAccount() {
    let reading = UsageReading(planType: "pro", observedAt: "2026-11-01T18:00:00.000Z")
    #expect(
      ConnectionSummary.subtitle(connection(.codex), reading: reading, check: nil)
        == "Pro · owner@example.com")
    #expect(ConnectionSummary.subtitle(connection(.claude), reading: nil, check: nil) == "owner@example.com")
    #expect(
      ConnectionSummary.subtitle(connection(.claude, scope: nil), reading: nil, check: nil) == "Not signed in"
    )
  }

  @Test func subtitleShowsTheTryWhileChecking() {
    #expect(
      ConnectionSummary.subtitle(
        connection(.codex), reading: nil, check: ConnectionCheck(attempt: 1, attempts: 3))
        == "Checking…")
    #expect(
      ConnectionSummary.subtitle(
        connection(.codex), reading: nil, check: ConnectionCheck(attempt: 2, attempts: 3))
        == "Checking… try 2 of 3")
  }

  @Test func subtitleGivesTheReasonWhenItNeedsYou() {
    let b4 = connection(.b4, status: .offline, auth: .notRequired, target: "http://localhost:3000")
    #expect(ConnectionSummary.subtitle(b4, reading: nil, check: nil) == "Can't reach localhost:3000")
    #expect(
      ConnectionSummary.subtitle(connection(.codex, auth: .required), reading: nil, check: nil)
        == "Sign-in needed")
    #expect(
      ConnectionSummary.subtitle(connection(.claude, status: .incompatible), reading: nil, check: nil)
        == "Update needed")
    #expect(
      ConnectionSummary.subtitle(
        connection(.b4, status: .incompatible, target: "http://h"), reading: nil, check: nil)
        == "Not an agent route")
    let blocked = UsageReading(blocked: true, planType: "pro", observedAt: "2026-11-01T18:00:00.000Z")
    #expect(
      ConnectionSummary.subtitle(connection(.codex), reading: blocked, check: nil) == "Usage limit reached")
    #expect(
      ConnectionSummary.subtitle(connection(.codex, status: .error), reading: nil, check: nil)
        == "Unavailable")
  }

  @Test func b4ServerMustBeHTTPSUnlessLocal() {
    #expect(B4ConnectionForm.serverProblem("") == nil)
    #expect(B4ConnectionForm.serverProblem("https://agents.example.com") == nil)
    #expect(B4ConnectionForm.serverProblem("http://127.0.0.1:8000") == nil)
    #expect(B4ConnectionForm.serverProblem("http://localhost:3000") == nil)
    #expect(B4ConnectionForm.serverProblem("http://agents.example.com") == "Remote servers need HTTPS.")
    #expect(
      B4ConnectionForm.serverProblem("agents.example.com") == "Enter a full address, like https://host.")
  }

  @Test func b4FormIsReadyWithAServerAndAnAgent() {
    #expect(B4ConnectionForm.ready(server: "https://h", agent: "/chat#agent"))
    #expect(!B4ConnectionForm.ready(server: "https://h", agent: ""))
    #expect(!B4ConnectionForm.ready(server: "http://remote.example", agent: "/chat#agent"))
    #expect(!B4ConnectionForm.ready(server: "", agent: "/chat#agent"))
  }

  @Test func planCodesReadAsNames() {
    #expect(ConnectionSummary.planName("pro") == "Pro")
    #expect(ConnectionSummary.planName("promax") == "Pro Max")
    #expect(ConnectionSummary.planName("prolite") == "Pro Lite")
    #expect(ConnectionSummary.planName("plus") == "Plus")
    #expect(ConnectionSummary.planName("self_serve_business_prolite") == "Self Serve Business Prolite")
    #expect(ConnectionSummary.planName("unknown") == nil)
  }

  @Test func windowsFillFromTheLeadingEdge() {
    let weeklyOnly = UsageReading(
      weekly: UsageWindow(usedPercent: 87, windowMinutes: 10080), observedAt: "2026-11-02T00:00:00.000Z")
    #expect(ConnectionSummary.windows(weeklyOnly).map(\.title) == ["Weekly"])
    let both = UsageReading(
      fiveHour: UsageWindow(usedPercent: 10), weekly: UsageWindow(usedPercent: 20),
      observedAt: "2026-11-02T00:00:00.000Z")
    #expect(ConnectionSummary.windows(both).map(\.title) == ["5-hour", "Weekly"])
  }

  @Test func aRefusalEndsWhenItsWindowResets() {
    let now = Timestamp.date(from: "2026-11-02T12:00:00.000Z")!
    func reading(_ fiveHour: (Double, String)?, _ weekly: (Double, String)?) -> UsageReading {
      UsageReading(
        fiveHour: fiveHour.map { UsageWindow(usedPercent: $0.0, resetsAt: $0.1) },
        weekly: weekly.map { UsageWindow(usedPercent: $0.0, resetsAt: $0.1) }, blocked: true,
        observedAt: "2026-11-02T09:00:00.000Z")
    }
    // The capped 5-hour window has reset: no longer blocked, though the week resets later.
    #expect(
      !ConnectionSummary.isBlocked(
        reading((100, "2026-11-02T11:00:00.000Z"), (40, "2026-11-05T09:00:00.000Z")), now: now))
    // The capped weekly window has not reset.
    #expect(
      ConnectionSummary.isBlocked(
        reading((20, "2026-11-02T11:00:00.000Z"), (100, "2026-11-05T09:00:00.000Z")), now: now))
    // Nothing capped: the refusal lasts until the first reset.
    #expect(!ConnectionSummary.isBlocked(reading((80, "2026-11-02T11:00:00.000Z"), nil), now: now))
    #expect(ConnectionSummary.isBlocked(reading((80, "2026-11-02T13:00:00.000Z"), nil), now: now))
    // No reset time: it holds.
    #expect(ConnectionSummary.isBlocked(reading((100, ""), nil), now: now))
    var open = reading((100, "2026-11-02T13:00:00.000Z"), nil)
    open.blocked = false
    #expect(!ConnectionSummary.isBlocked(open, now: now))
  }

  @Test func usageBeforeAnyReportSaysSo() {
    #expect(ConnectionSummary.noUsage(.codex) == "Usage unavailable")
    #expect(ConnectionSummary.noUsage(.claude) == "Usage appears after the first turn")
    #expect(ConnectionSummary.noUsage(.b4) == "Token use appears after the first turn")
  }
}
