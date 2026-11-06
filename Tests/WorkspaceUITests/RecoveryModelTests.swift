import Foundation
import Testing
import WorkspaceProtocol

@testable import Coordinator
@testable import WorkspaceUI

@Suite @MainActor struct RecoveryModelTests {
  @Test func archivedSendKeepsTheDraftAndCheckAgainKeepsTheNotice() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let h = try await ModelHarness.start(extraEnvironment: ["FAKE_CODEX_UNARCHIVED_FILE": marker.path])
    let model = h.model
    let connection = try #require(
      await model.addConnection(kind: .codex, label: "Codex", executablePath: fakeCodex))
    let db = try #require(h.coordinator.accounts.current).database
    let thread = try db.insertThread(
      ConversationThread(
        id: UUID().uuidString.lowercased(), connectionId: connection.id, nativeThreadId: "thr_archived",
        nativeScope: "owner@example.com", title: "Archived session", context: h.workDir))
    try await model.refreshSnapshot()
    await model.openThread(id: thread.id)
    model.composerText = "keep this draft"
    await model.send()
    #expect(model.lastFailure?.code == .protocolInvalid)
    #expect(model.remediation?.action == .checkAgain)
    #expect(model.composerText == "keep this draft")
    await model.persistDraftNow()
    for _ in 0..<2 {
      await model.perform(.checkAgain)
      #expect(model.lastError?.contains("codex unarchive thr_archived") == true)
      #expect(model.remediation?.action == .checkAgain)
      #expect(model.detail?.thread.continuity == .available)
      #expect(model.composerText == "keep this draft")
    }
    #expect(try db.turns(threadId: thread.id).count == 1)
    #expect(try db.draft(threadId: thread.id)?.text == "keep this draft")
    // The owner unarchives it in Codex; Check again now clears the notice without sending the draft.
    try Data().write(to: marker)
    await model.perform(.checkAgain)
    #expect(model.lastError == nil)
    #expect(model.detail?.thread.continuity == .available)
    #expect(model.composerText == "keep this draft")
    #expect(try db.turns(threadId: thread.id).count == 1)
    await h.stop()
  }
}
