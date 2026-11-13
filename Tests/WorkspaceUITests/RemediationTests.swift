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

  @Test(arguments: [false, true])
  func archivedSessionKeepsItsRecoveryInstruction(wrappedByTurnSend: Bool) {
    let message = "This Codex session is archived. Run `codex unarchive thr_archived`, then check again."
    let details: JSONValue = ["reason": "native_session_archived"]
    let remedy = Remediation.for(
      WorkspaceError(.protocolInvalid, message, details: wrappedByTurnSend ? ["cause": details] : details),
      connection: codex)
    #expect(remedy.message == message)
    #expect(remedy.action == .checkAgain)
    #expect(remedy.actionTitle == "Check again")
  }

  @Test func continuityCoversOnlyTheSameFailure() {
    let missing = WorkspaceError(.nativeSessionMissing, "gone")
    let identity = WorkspaceError(.identityChanged, "changed")
    #expect(Remediation.coveredByContinuity(missing, continuity: .missing))
    #expect(Remediation.coveredByContinuity(identity, continuity: .identityChanged))
    #expect(!Remediation.coveredByContinuity(missing, continuity: .available))
    #expect(!Remediation.coveredByContinuity(missing, continuity: .identityChanged))
    #expect(!Remediation.coveredByContinuity(identity, continuity: .missing))
    for continuity in [ThreadContinuity.available, .missing, .identityChanged] {
      #expect(!Remediation.coveredByContinuity(nil, continuity: continuity))
      #expect(
        !Remediation.coveredByContinuity(
          WorkspaceError(.endpointUnavailable, "offline"), continuity: continuity))
      #expect(
        !Remediation.coveredByContinuity(
          WorkspaceError(.protocolInvalid, "archived", details: ["reason": "native_session_archived"]),
          continuity: continuity))
    }
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
    #expect(
      SettingsPage.allCases.map(\.title) == [
        "Account", "Display", "Connections", "B4 projects", "Remote access", "Diagnostics",
      ])
    #expect(
      SettingsPage.allCases.map(\.systemImage) == [
        "person.crop.circle", "textformat.size", "link", "server.rack", "iphone", "waveform.path.ecg",
      ])
  }
}
