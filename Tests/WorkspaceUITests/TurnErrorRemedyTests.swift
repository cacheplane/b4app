import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// A runtime's error during a turn reaches the open thread as `adapter.error`, with the app's code in
/// `errorCode`. The notice reads the code: an expired sign-in offers Sign in, and the runtime's own
/// words move to Details rather than standing in for the explanation.
@Suite @MainActor struct TurnErrorRemedyTests {
  private let claude = Connection(
    id: "c", kind: .claude, label: "Claude Code", enabled: true, target: "", status: .ready)
  private let thread = ConversationThread(id: "th", connectionId: "c", nativeThreadId: "native")
  private let native = "Failed to authenticate: OAuth session expired and could not be refreshed"

  private func model(_ transport: ScriptedTransport) async throws -> WorkspaceModel {
    transport.set(connections: [claude], threads: [thread])
    transport.setRead(ThreadRead.Result(thread: thread, turns: [], items: [], requests: []))
    let model = WorkspaceModel(transportProvider: { transport })
    model.connect()
    try #require(await model.settledLink() == .ready)
    await model.openThread(id: thread.id)
    try #require(model.detail?.thread.id == "th")
    return model
  }

  private func adapterError(code: String?, threadId: String = "th") -> AdapterEvent {
    var payload: [String: JSONValue] = [
      "message": .string(native), "willRetry": false, "nativeError": "authentication_failed",
    ]
    if let code { payload["errorCode"] = .string(code) }
    return AdapterEvent(kind: .adapterError, connectionId: "c", threadId: threadId, payload: .object(payload))
  }

  @Test func anExpiredSignInDuringATurnOffersSignIn() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    transport.emit(adapterError(code: "auth_required"))
    try await waitUntil("the error arrived") { model.lastError != nil }
    #expect(model.lastFailure?.code == .authRequired)
    #expect(model.lastFailure?.details?["nativeMessage"]?.stringValue == native)
    let remedy = try #require(model.remediation)
    #expect(remedy.action == .signIn(connectionId: "c"))
    #expect(remedy.actionTitle == "Sign in to Claude")
    #expect(remedy.message.contains("signed out or the login expired"))
    await model.disconnect()
  }

  @Test func anUncodedErrorKeepsTheRuntimesWords() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    transport.emit(adapterError(code: nil))
    try await waitUntil("the error arrived") { model.lastError != nil }
    #expect(model.lastFailure?.code == .internalError)
    #expect(model.remediation?.message == native)
    #expect(model.remediation?.action == Remediation.Action.none)
    await model.disconnect()
  }

  @Test func anotherThreadsErrorLeavesTheOpenThreadAlone() async throws {
    let transport = ScriptedTransport()
    let model = try await model(transport)
    transport.emit(adapterError(code: "auth_required", threadId: "elsewhere"))
    transport.emit(AdapterEvent(kind: .threadUpdated, connectionId: "c", threadId: "th"))
    try await waitUntil("later event applied") { transport.methods().contains("thread.read") }
    #expect(model.lastError == nil)
    #expect(model.lastFailure == nil)
    await model.disconnect()
  }
}
