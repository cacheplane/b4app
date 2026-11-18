import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What takes a reader who scrolled back to the end of the thread: a message they sent from this app,
/// and never a turn that arrived from somewhere else.
@Suite @MainActor struct OwnSendTests {
  private let thread = ConversationThread(id: "th", connectionId: "c", nativeThreadId: "native")

  private func turn(_ id: String) -> Turn {
    Turn(id: id, threadId: "th", operationId: "op-\(id)", status: .running, outcome: nil)
  }

  private func model(_ transport: ScriptedTransport) async throws -> WorkspaceModel {
    transport.set(threads: [thread])
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try #require(await model.settledLink() == .ready)
    await model.openThread(id: thread.id)
    try #require(model.detail?.thread.id == "th")
    return model
  }

  /// Counted at the press, before the coordinator has replied.
  @Test func aSendFromThisAppIsCountedWhenItIsPressed() async throws {
    let transport = ScriptedTransport()
    transport.script(.turnSend, [.hold])
    let model = try await model(transport)
    #expect(model.ownSends(in: "th") == 0)
    model.composerText = "Hello"
    let sending = Task { await model.send() }
    try await waitUntil("sent") { transport.heldCount(.turnSend) == 1 }
    #expect(model.ownSends(in: "th") == 1)
    #expect(
      transport.release(
        .turnSend, with: .result(try JSONValue(encoding: TurnSend.Result(turn: turn("t1"))))))
    await sending.value
    #expect(model.ownSends(in: "th") == 1)
    await model.disconnect()
  }

  @Test func anEmptyComposerSendsAndCountsNothing() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    model.composerText = "   "
    await model.send()
    #expect(model.ownSends(in: "th") == 0)
    #expect(transport.recorded(.turnSend).isEmpty)
    await model.disconnect()
  }

  /// A turn another device started reaches this app as a thread that now has one more turn.
  @Test func aTurnFromElsewhereIsNotCounted() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    transport.setRead(ThreadRead.Result(thread: thread, turns: [turn("t9")], items: [], requests: []))
    await model.reconcileAfter("wake")
    try #require(model.detail?.turns.map(\.id) == ["t9"])
    #expect(model.ownSends(in: "th") == 0)
    await model.disconnect()
  }
}
