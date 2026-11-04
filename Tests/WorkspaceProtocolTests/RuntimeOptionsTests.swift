import Testing

@testable import WorkspaceProtocol

@Suite struct RuntimeOptionsTests {
  @Test func eachRuntimeOffersItsOwnPermissions() {
    #expect(
      RuntimeOptions.permissions(for: .claude).map(\.id) == [
        "default", "acceptEdits", "plan", "bypassPermissions",
      ])
    #expect(
      RuntimeOptions.permissions(for: .claude).map(\.label) == [
        "Ask permissions", "Accept edits", "Plan mode", "Bypass permissions",
      ])
    #expect(RuntimeOptions.permissions(for: .codex).map(\.id) == ["read-only", "auto", "full-access"])
    #expect(RuntimeOptions.permissions(for: .codex).map(\.label) == ["Read only", "Auto", "Full access"])
    #expect(RuntimeOptions.permissions(for: .b4).isEmpty)
    #expect(RuntimeOptions.permissionLabel(nil, kind: .codex) == "As configured")
  }

  @Test func permissionLabelsFallBackToTheId() {
    #expect(RuntimeOptions.permissionLabel("plan", kind: .claude) == "Plan mode")
    #expect(RuntimeOptions.permissionLabel("auto", kind: .codex) == "Auto")
    #expect(RuntimeOptions.permissionLabel("mystery", kind: .claude) == "mystery")
    #expect(RuntimeOptions.permissionLabel("plan", kind: .codex) == "plan")
  }

  @Test func claudeModelsAreTheThreeAliases() {
    #expect(RuntimeOptions.claudeModels.map(\.id) == ["opus", "sonnet", "haiku"])
    #expect(RuntimeOptions.claudeModels.map(\.label) == ["Opus", "Sonnet", "Haiku"])
    #expect(RuntimeOptions.defaultModelLabel == "Default")
  }

  @Test func codexPresetsMapToPolicyAndSandbox() {
    #expect(CodexPermission.readOnly.approvalPolicy == "on-request")
    #expect(CodexPermission.auto.approvalPolicy == "on-request")
    #expect(CodexPermission.fullAccess.approvalPolicy == "never")
    #expect(
      CodexPermission.auto.sandboxPolicy(writableRoots: ["/a"])
        == ["type": "workspaceWrite", "writableRoots": ["/a"]])
    #expect(CodexPermission.readOnly.sandboxPolicy(writableRoots: ["/a"]) == ["type": "readOnly"])
    #expect(CodexPermission.fullAccess.sandboxPolicy(writableRoots: []) == ["type": "dangerFullAccess"])
  }
}
