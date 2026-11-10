import Foundation
import Testing
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceUI

@Suite @MainActor struct ArchivedDraftRaceTests {
  enum Change: CaseIterable { case navigation, deletion, account }

  @Test(arguments: Change.allCases)
  func aDelayedRefusalCannotRestoreADraftIntoAnotherContext(_ change: Change) async throws {
    let release = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: release) }
    let h = try await ModelHarness.start(extraEnvironment: ["FAKE_CODEX_ARCHIVED_RELEASE": release.path])
    let model = h.model
    let connection = try #require(
      await model.addConnection(kind: .codex, label: "Runtime", executablePath: fakeCodex))
    let db = try #require(h.coordinator.accounts.current).database
    await model.createThread(connectionId: connection.id, directory: h.workDir, title: "Other thread")
    let other = try #require(model.detail?.thread)
    let archived = try db.insertThread(
      ConversationThread(
        id: UUID().uuidString.lowercased(), connectionId: connection.id, nativeThreadId: "thr_archived",
        nativeScope: "owner@example.com", title: "Archived origin", context: h.workDir))
    try await model.refreshSnapshot()
    await model.openThread(id: archived.id)
    model.composerText = "draft belonging to the archived origin"
    let sending = Task { await model.send() }
    try await waitUntil("turn pending") { model.detail?.activeTurn?.status == .submitting }
    switch change {
    // The next selection is already visible while its detail read is still pending.
    case .navigation: model.selectedThreadId = other.id
    case .deletion: model.forget(threadId: archived.id)
    case .account: model.forgetWorkspace()
    }
    try Data().write(to: release)
    await sending.value
    #expect(model.lastFailure?.details?["cause"]?["reason"]?.stringValue == "native_session_archived")
    #expect(model.composerText.isEmpty, "a late refusal must not restore text into a different context")
    if change == .navigation {
      await model.openThread(id: other.id)
      #expect(model.detail?.thread.id == other.id)
      await model.persistDraftNow()
      #expect(try db.draft(threadId: other.id)?.text.isEmpty != false)
    }
    await h.stop()
  }
}
