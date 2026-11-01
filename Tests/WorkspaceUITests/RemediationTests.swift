import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite struct RemediationTests {
  private let codex = Connection(id: "c1", kind: .codex, label: "Codex", target: "/opt/codex")
  private let b4 = Connection(id: "c2", kind: .b4, label: "Research", target: "https://agent.example")

  @Test func authRequiredOffersTheRuntimesOwnSignIn() {
    let codexFix = Remediation.for(WorkspaceError(.authRequired, "signed out"), connection: codex)
    #expect(codexFix.action == .signIn(connectionId: "c1"))
    #expect(codexFix.actionTitle == "Sign in with ChatGPT")
    let b4Fix = Remediation.for(WorkspaceError(.authRequired, "401"), connection: b4)
    #expect(b4Fix.action == .openConnections)
    #expect(b4Fix.message.contains("credential add"))
  }

  @Test func allowanceAndAuthModeNeverSuggestABillingSwitch() {
    let allowance = Remediation.for(WorkspaceError(.allowanceExceeded, "limit"), connection: codex)
    #expect(allowance.action == .none)
    #expect(allowance.message.contains("never switches to API billing"))
    let conflict = Remediation.for(WorkspaceError(.authModeConflict, "key"), connection: codex)
    #expect(conflict.message.contains("ANTHROPIC_API_KEY"))
  }

  @Test func continuityAndRecoveryFailuresNameTheNextStep() {
    #expect(
      Remediation.for(WorkspaceError(.nativeSessionMissing, "gone"), connection: codex).action == .newThread)
    #expect(
      Remediation.for(WorkspaceError(.identityChanged, "other"), connection: codex).action == .newThread)
    #expect(
      Remediation.for(WorkspaceError(.submissionUnknown, "lost"), connection: codex).action == .checkAgain)
    let locked = Remediation.for(
      WorkspaceError(.protocolInvalid, "locked", details: ["reason": "directory_locked", "threadId": "t9"]),
      connection: codex)
    #expect(locked.action == .openThread(threadId: "t9"))
    let unknownActive = Remediation.for(
      WorkspaceError(
        .protocolInvalid, "active", details: ["reason": "turn_active", "status": "reconciling"]),
      connection: codex)
    #expect(unknownActive.action == .abandonTurn)
    let stopped = Remediation.for(
      WorkspaceError(
        .endpointUnavailable, "stopped", details: ["reason": "server_stopped", "serverId": "s1"]),
      connection: b4)
    #expect(stopped.action == .openServers(serverId: "s1"))
  }
}

@MainActor
@Suite struct SettingsRequestTests {
  private func model() -> WorkspaceModel {
    WorkspaceModel(transportProvider: { throw WorkspaceError(.endpointUnavailable, "no coordinator") })
  }

  @Test func remediationOpensSettingsAtThePage() async {
    let model = model()
    await model.perform(.openConnections)
    #expect(model.settingsPage == .connections)
    #expect(model.settingsRequest == 1)
    await model.perform(.openServers(serverId: "s1"))
    #expect(model.settingsPage == .servers)
    #expect(model.settingsRequest == 2)
  }

  @Test func openSettingsTwiceRequestsTwice() {
    let model = model()
    model.openSettings(.diagnostics)
    model.openSettings(.diagnostics)
    #expect(model.settingsRequest == 2)
    #expect(model.settingsPage == .diagnostics)
    model.openSettings()
    #expect(model.settingsRequest == 3)
    #expect(model.settingsPage == .diagnostics)
  }

  @Test func pagesHaveTheirTitlesAndSymbols() {
    #expect(SettingsPage.allCases.map(\.title) == ["Connections", "Local servers", "Diagnostics"])
    #expect(SettingsPage.allCases.map(\.systemImage) == ["link", "server.rack", "waveform.path.ecg"])
  }
}
