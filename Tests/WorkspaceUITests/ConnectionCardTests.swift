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
}
