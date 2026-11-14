import Foundation
import Testing
import WorkspaceClient
import WorkspaceProtocol

@testable import WorkspaceUI

/// The words of the dense composer's line. Environments and connections are `Phone`'s: Atlas has two
/// folders, Borealis one.
@Suite @MainActor struct ComposerSummaryTests {
  private static func draft(
    in environmentId: String? = "p2", runtime: String? = "claude-1", model chosen: String? = nil,
    connections: [Connection] = Phone.macConnections
  ) async throws -> (NewThreadDraft, WorkspaceModel) {
    let model = try await Phone.macModel(ScriptedTransport(), connections: connections)
    let draft = NewThreadDraft(model: model, environmentId: environmentId)
    if let runtime { draft.selectRuntime(connectionId: runtime, model: chosen) }
    return (draft, model)
  }

  private static func thread(
    _ connectionId: String, model chosen: String? = nil, permission: String? = nil,
    environmentId: String? = "p2"
  ) -> ConversationThread {
    var thread = PhoneFixture.thread("t1", owner: nil)
    thread.connectionId = connectionId
    thread.model = chosen
    thread.permission = permission
    thread.environmentId = environmentId
    return thread
  }

  @Test func aDraftNamesThePlaceTheRuntimeAndTheModel() async throws {
    let (draft, model) = try await Self.draft(model: "opus")
    let summary = ComposerSummary.draft(draft, in: model)
    #expect(summary.text == "Borealis · Claude Code · Opus")
    #expect(summary.permission == nil)
    #expect(summary.spoken == "Runs in Borealis with Claude Code, Opus")
    await model.disconnect()
  }

  @Test func aDraftWithNoModelSaysDefault() async throws {
    let (draft, model) = try await Self.draft()
    #expect(ComposerSummary.draft(draft, in: model).text.hasSuffix("Claude Code · Default"))
    await model.disconnect()
  }

  @Test func anEnvironmentWithSeveralFoldersNamesTheFolder() async throws {
    let (draft, model) = try await Self.draft(in: "p1")
    #expect(draft.folder != nil)
    #expect(ComposerSummary.draft(draft, in: model).place == "Atlas · atlas")
    await model.disconnect()
  }

  @Test func aChosenFolderIsNamedByItsLastComponent() async throws {
    let (draft, model) = try await Self.draft()
    draft.chooseFolder("/Users/x/scratch")
    #expect(ComposerSummary.draft(draft, in: model).place == "scratch")
    await model.disconnect()
  }

  @Test func noFolderIsSaid() async throws {
    let (draft, model) = try await Self.draft()
    draft.selectNoFolder()
    #expect(ComposerSummary.draft(draft, in: model).text.hasPrefix("No folder · "))
    await model.disconnect()
  }

  @Test func aRemoteB4DraftHasNoFolderAndNoPermission() async throws {
    let (draft, model) = try await Self.draft(runtime: "b4-remote")
    let remote = try #require(draft.connection)
    #expect(draft.isRemoteB4)
    let summary = ComposerSummary.draft(draft, in: model)
    #expect(summary.place == "No folder")
    #expect(summary.runtime == model.startLabel(for: remote))
    #expect(summary.permission == nil)
    await model.disconnect()
  }

  @Test func thePermissionIsNamedOnlyWhenItIsNotTheDefault() async throws {
    let (draft, model) = try await Self.draft(model: "opus")
    let first = try #require(RuntimeOptions.permissions(for: .claude).first)
    draft.selectPermission(first.id)
    let named = ComposerSummary.draft(draft, in: model)
    #expect(named.permission == first.label)
    #expect(named.text.hasSuffix(" · \(first.label)"))
    #expect(named.spoken.hasSuffix(", \(first.label) permissions"))
    draft.selectPermission(nil)
    let plain = ComposerSummary.draft(draft, in: model)
    #expect(plain.permission == nil)
    #expect(!plain.text.contains(first.label))
    #expect(!plain.spoken.contains("permissions"))
    await model.disconnect()
  }

  @Test func aDraftWithNoConnectionSaysNoRuntime() async throws {
    let (draft, model) = try await Self.draft(runtime: nil, connections: [])
    #expect(draft.connection == nil)
    let summary = ComposerSummary.draft(draft, in: model)
    #expect(summary.runtime == "No runtime")
    #expect(summary.spoken == "Runs in Borealis, no runtime")
    await model.disconnect()
  }

  @Test func aThreadLeavesThePlaceOut() async throws {
    let thread = Self.thread("claude-1", model: "sonnet")
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    let summary = ComposerSummary.thread(thread, in: model)
    #expect(summary.place == nil)
    #expect(summary.text == "Claude Code · Sonnet")
    #expect(summary.spoken == "Runs with Claude Code, Sonnet")
    await model.disconnect()
  }

  @Test func aThreadsOwnPermissionIsNamed() async throws {
    let option = try #require(RuntimeOptions.permissions(for: .claude).first)
    let thread = Self.thread("claude-1", model: "sonnet", permission: option.id)
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    let summary = ComposerSummary.thread(thread, in: model)
    #expect(summary.permission == option.label)
    #expect(summary.text == "Claude Code · Sonnet · \(option.label)")
    #expect(summary.spoken == "Runs with Claude Code, Sonnet, \(option.label) permissions")
    await model.disconnect()
  }

  @Test func aB4ThreadIsItsRoutesLabelAlone() async throws {
    let thread = Self.thread("b4-p1", model: "opus", permission: "anything")
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    let agent = try #require(model.connection(id: "b4-p1"))
    let summary = ComposerSummary.thread(thread, in: model)
    #expect(summary.text == model.startLabel(for: agent))
    #expect(summary.place == nil)
    #expect(summary.permission == nil)
    #expect(summary.spoken == "Runs with \(model.startLabel(for: agent))")
    await model.disconnect()
  }

  @Test func aThreadWhoseConnectionIsGoneSaysNoRuntime() async throws {
    let thread = Self.thread("deleted", model: "opus")
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    let summary = ComposerSummary.thread(thread, in: model)
    #expect(summary.runtime == "No runtime")
    #expect(summary.spoken == "No runtime")
    await model.disconnect()
  }

  @Test func aThreadWithNoEnvironmentHasNoFolder() async throws {
    let thread = Self.thread("claude-1", environmentId: nil)
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    #expect(ComposerSummary.placeText(thread, in: model) == "No folder")
    await model.disconnect()
  }

  @Test func anEnvironmentThatIsNotLoadedIsNamedByTheThreadsFolder() async throws {
    var thread = Self.thread("claude-1", environmentId: "gone")
    thread.context = "/x/scratch"
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    #expect(ComposerSummary.placeText(thread, in: model) == "scratch")
    thread.context = ""
    #expect(ComposerSummary.placeText(thread, in: model) == "No folder")
    await model.disconnect()
  }

  @Test func aB4ThreadInASeveralFolderEnvironmentIsTheEnvironmentAlone() async throws {
    var thread = Self.thread("b4-p1", environmentId: "p1")
    thread.context = "/work/atlas-docs"
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    #expect(ComposerSummary.placeText(thread, in: model) == "Atlas")
    await model.disconnect()
  }

  @Test func aThreadInASeveralFolderEnvironmentNamesItsFolder() async throws {
    var thread = Self.thread("claude-1", environmentId: "p1")
    thread.context = "/work/atlas-docs"
    let model = try await Phone.macModel(ScriptedTransport(), threads: [thread])
    #expect(ComposerSummary.placeText(thread, in: model) == "Atlas · atlas-docs")
    await model.disconnect()
  }

  @Test func aB4DraftInASeveralFolderEnvironmentIsTheEnvironmentAlone() async throws {
    let (draft, model) = try await Self.draft(in: "p1", runtime: "b4-p1")
    #expect(draft.connection?.kind == .b4)
    #expect(ComposerSummary.placeText(draft) == "Atlas")
    await model.disconnect()
  }

  @Test func thePickerRowAndTheLineAgree() async throws {
    let (draft, model) = try await Self.draft(in: "p1")
    #expect(
      ComposerPickerRow(model: model, .draft(draft)).placeText(draft) == ComposerSummary.placeText(draft))
    var thread = Self.thread("claude-1", environmentId: "p1")
    thread.context = "/work/atlas-docs"
    #expect(
      ComposerPickerRow(model: model, .thread(thread)).placeText(thread)
        == ComposerSummary.placeText(thread, in: model))
    await model.disconnect()
  }
}
