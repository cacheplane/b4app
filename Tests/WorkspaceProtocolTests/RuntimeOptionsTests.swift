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

  // MARK: Runtime commands

  @Test func aRuntimesListIsKeptAsNamesAComposerCanSpell() {
    let long = String(repeating: "x", count: 400)
    let kept = RuntimeCommand.normalized([
      RuntimeCommand(name: "/compact", description: " Summarize \nand more", argumentHint: " "),
      RuntimeCommand(name: "compact", description: "a duplicate"),
      RuntimeCommand(name: "has space", description: "dropped"),
      RuntimeCommand(name: "", description: "dropped"),
      RuntimeCommand(
        name: "superpowers:plan", description: long, argumentHint: "[topic]",
        aliases: ["plan", "superpowers:plan", "no good"]),
    ])
    #expect(kept.map(\.name) == ["compact", "superpowers:plan"])
    #expect(kept[0].description == "Summarize")
    #expect(kept[0].argumentHint == nil)
    #expect(kept[1].description.count == RuntimeCommand.descriptionLimit)
    #expect(kept[1].description.hasSuffix("\u{2026}"))
    #expect(kept[1].aliases == ["plan"])
    let many = (0..<400).map { RuntimeCommand(name: "c\($0)") }
    #expect(RuntimeCommand.normalized(many).count == RuntimeCommand.listLimit)
  }

  @Test func aShorterReportChangesNothingAndANewNameReplacesTheList() {
    let stored = [RuntimeCommand(name: "context"), RuntimeCommand(name: "compact")]
    // The first report is kept as it is.
    #expect(RuntimeCommand.replacement(stored: nil, reported: stored) == stored)
    #expect(RuntimeCommand.replacement(stored: nil, reported: []) == [])
    // A runtime that answered before its plugins loaded names nothing new.
    #expect(RuntimeCommand.replacement(stored: stored, reported: [RuntimeCommand(name: "context")]) == nil)
    #expect(RuntimeCommand.replacement(stored: stored, reported: stored.reversed()) == nil)
    // A new name replaces the list, dropping what the runtime no longer reports.
    let next = [RuntimeCommand(name: "context"), RuntimeCommand(name: "review")]
    #expect(RuntimeCommand.replacement(stored: stored, reported: next) == next)
  }

  @Test func aMessageIsACommandOnlyWhenItStartsWithOne() {
    #expect(RuntimeCommand.parse("/review")?.name == "review")
    #expect(RuntimeCommand.parse("/review")?.arguments == "")
    #expect(RuntimeCommand.parse("/review  the auth change\n")?.arguments == "the auth change")
    #expect(RuntimeCommand.parse("/superpowers:plan x")?.name == "superpowers:plan")
    #expect(RuntimeCommand.parse("/usr/local/bin") == nil)
    #expect(RuntimeCommand.parse("review") == nil)
    #expect(RuntimeCommand.parse("/") == nil)
    #expect(RuntimeCommand.parse(" /review") == nil)
  }
}
