import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// The Mac's answer to a request: the card goes with the coordinator's reply, not with the event
/// that follows it, so its buttons are never offered again in between (D-253).
@Suite @MainActor struct RequestAnswerTests {
  private let thread = ConversationThread(id: "th", connectionId: "c", nativeThreadId: "native")

  private func request(_ state: RuntimeRequestState) -> RuntimeRequest {
    RuntimeRequest(
      id: "r1", nativeRequestId: "n-r1", threadId: "th", adapterGeneration: 1, kind: .commandApproval,
      state: state, payload: ["answerable": true], createdAt: PhoneFixture.at(0),
      updatedAt: PhoneFixture.at(0))
  }

  private func model(_ transport: ScriptedTransport) async throws -> WorkspaceModel {
    transport.set(threads: [thread])
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: [request(.pending)]))
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try #require(await model.settledLink() == .ready)
    await model.openThread(id: thread.id)
    try #require(model.detail?.requests.map(\.id) == ["r1"])
    return model
  }

  @Test func anAnsweredRequestLeavesWithTheReplyBeforeItsEvent() async throws {
    let transport = ScriptedTransport()
    transport.script(
      .requestRespond,
      [.result(try JSONValue(encoding: RequestRespond.Result(request: request(.resolved))))])
    let model = try await model(transport)
    await model.respond(requestId: "r1", decision: .allowOnce)
    // No resolved event has arrived, and the reply is all the model has heard.
    #expect(model.detail?.requests.isEmpty == true)
    #expect(model.lastError == nil)
    await model.disconnect()
  }

  @Test func answersToAQuestionLeaveWithTheReplyToo() async throws {
    let transport = ScriptedTransport()
    transport.script(
      .requestRespond,
      [.result(try JSONValue(encoding: RequestRespond.Result(request: request(.resolved))))])
    let model = try await model(transport)
    await model.answer(requestId: "r1", answers: ["q0": ["red"]])
    #expect(model.detail?.requests.isEmpty == true)
    await model.disconnect()
  }

  /// A refused answer, and a reply that says the request is still pending, keep the card.
  @Test func aRequestThatWasNotAnsweredStays() async throws {
    let transport = ScriptedTransport()
    transport.script(
      .requestRespond,
      [
        .failure(WorkspaceError(.unsupportedCapability, "Nothing wider here.")),
        .result(try JSONValue(encoding: RequestRespond.Result(request: request(.pending)))),
      ])
    let model = try await model(transport)
    await model.respond(requestId: "r1", decision: .allowAlways)
    #expect(model.detail?.requests.map(\.id) == ["r1"])
    #expect(model.lastFailure?.code == .unsupportedCapability)
    await model.respond(requestId: "r1", decision: .allowOnce)
    #expect(model.detail?.requests.map(\.id) == ["r1"])
    #expect(model.canAnswer(request(.pending)))
    await model.disconnect()
  }
}
