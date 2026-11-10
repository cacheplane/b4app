import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

@Suite @MainActor struct LocalSendDraftTests {
  @Test(arguments: [false, true], [false, true])
  func unavailableEndpointPreservesCurrentDraft(eventFirst: Bool, newerText: Bool) async throws {
    let transport = ScriptedTransport()
    let thread = ConversationThread(id: "b4-thread", connectionId: "b4", nativeThreadId: "native-thread")
    transport.set(threads: [thread])
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    transport.script(.turnSend, [.hold])
    let draft = Draft(threadId: thread.id, text: "keep this B4 draft")
    transport.script(.draftSave, [.result(try JSONValue(encoding: DraftSave.Result(draft: draft)))])
    let model = WorkspaceModel(transportProvider: { transport })
    model.draftSaveDelay = .seconds(30)
    model.connect()
    try #require(await model.settledLink() == .ready)
    await model.openThread(id: thread.id)
    model.composerText = draft.text
    let sending = Task { await model.send() }
    try await waitUntil("held local send") { transport.heldCount(.turnSend) == 1 }
    let expected = newerText ? "newer text while sending" : draft.text
    if newerText { model.composerText = expected }
    let turn = Turn(
      id: "refused", threadId: thread.id, operationId: "send", status: .terminal,
      submission: .prepared, outcome: .failed)
    let event = AdapterEvent(
      kind: .turnFinished, connectionId: "b4", threadId: thread.id, turnId: turn.id,
      payload: ["turn": try JSONValue(encoding: turn)])
    if eventFirst {
      transport.emit(event)
      try await waitUntil("terminal refusal") { model.detail?.turns.first?.status == .terminal }
    }
    try #require(
      transport.release(
        .turnSend,
        with: .failure(WorkspaceError(.endpointUnavailable, "B4 is stopped", details: ["turnId": "refused"])))
    )
    await sending.value
    #expect(model.lastFailure?.code == .endpointUnavailable)
    #expect(model.composerText == expected)
    if !eventFirst {
      transport.emit(event)
      try await waitUntil("late terminal refusal") { model.detail?.turns.first?.status == .terminal }
      #expect(model.composerText == expected)
    }
    await model.persistDraftNow()
    #expect(transport.calls(.draftSave).last?["text"]?.stringValue == expected)
    #expect(transport.calls(.turnSend).count == 1, "Restoring a draft must not resend it")
    await model.disconnect()
  }
}
