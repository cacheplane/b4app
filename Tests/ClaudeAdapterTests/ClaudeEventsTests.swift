import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

private func frames(_ text: String) -> [ClaudeStream.Frame] {
  text.split(separator: "\n").map { ClaudeStream.decodeFrame(String($0)) }
}

private func run(_ tracker: inout ClaudeTurnTracker, _ text: String) -> [AdapterEvent] {
  frames(text).flatMap { tracker.translate($0) }
}

private let streamedTurn = """
  {"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup","session_id":"s1"}
  {"type":"system","subtype":"init","session_id":"s1","cwd":"/w","model":"claude-x","permissionMode":"default","apiKeySource":"none","claude_code_version":"2.1.282","tools":[],"capabilities":["interrupt_receipt_v1"]}
  {"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]},"session_id":"s1","uuid":"turn-1","isReplay":true}
  {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}},"session_id":"s1","user_message_uuid":"turn-1"}
  {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s1"}
  {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}},"session_id":"s1"}
  {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}},"session_id":"s1"}
  {"type":"stream_event","event":{"type":"message_stop"},"session_id":"s1"}
  {"type":"assistant","message":{"id":"msg_1","role":"assistant","model":"claude-x","content":[{"type":"text","text":"Hello"}]},"session_id":"s1","uuid":"a1","user_message_uuid":"turn-1"}
  {"type":"result","subtype":"success","is_error":false,"duration_ms":5,"num_turns":1,"total_cost_usd":0.01,"result":"Hello","session_id":"s1","user_message_uuid":"turn-1"}
  """

@Suite struct ClaudeTurnTrackerTests {
  private func tracker() -> ClaudeTurnTracker {
    var tracker = ClaudeTurnTracker(connectionId: "c1", sessionId: "s1", generation: 2)
    tracker.beginTurn(uuid: "turn-1")
    return tracker
  }

  @Test func translatesAStreamedTurnInOrder() {
    var t = tracker()
    let events = run(&t, streamedTurn)
    #expect(
      events.map(\.kind) == [
        .turnStateChanged, .messageStarted, .messageDelta, .messageDelta, .messageCompleted, .turnFinished,
      ])
    #expect(events.allSatisfy { $0.nativeIds["threadId"] == "s1" && $0.adapterGeneration == 2 })
    #expect(events[1].nativeIds["itemId"] == "msg_1#0")
    #expect(events[2].payload["delta"]?.stringValue == "Hel")
    #expect(events[4].nativeIds["itemId"] == "msg_1#0")
    #expect(events[4].payload["item"]?["text"]?.stringValue == "Hello")
    #expect(events[4].payload["role"]?.stringValue == "assistant")
    #expect(events[5].payload["outcome"]?.stringValue == "completed")
    #expect(events[5].nativeIds["turnId"] == "turn-1")
    #expect(t.activeTurnUuid == nil)
    #expect(t.model == "claude-x")
  }

  @Test func successSubtypeWithErrorFlagIsAFailedTurn() {
    var t = tracker()
    let events = run(
      &t,
      """
      {"type":"assistant","message":{"id":"m","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired"}]},"error":"authentication_failed","is_api_error_message":true,"session_id":"s1","user_message_uuid":"turn-1"}
      {"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"Failed to authenticate: OAuth session expired","num_turns":1,"session_id":"s1","user_message_uuid":"turn-1"}
      """)
    #expect(events.map(\.kind) == [.adapterError, .messageCompleted, .turnFinished])
    #expect(events[0].payload["errorCode"]?.stringValue == "auth_required")
    #expect(events[2].payload["outcome"]?.stringValue == "failed")
    #expect(events[2].payload["errorCode"]?.stringValue == "auth_required")
    #expect(events[2].payload["error"]?["message"]?.stringValue?.contains("authenticate") == true)
  }

  @Test func interruptedTurnEndsAsCancelled() {
    var t = tracker()
    t.markInterruptRequested()
    let events = run(
      &t, #"{"type":"result","subtype":"success","is_error":false,"result":"","session_id":"s1"}"#)
    #expect(events[0].payload["outcome"]?.stringValue == "cancelled")
    var u = tracker()
    let reason = run(
      &u,
      #"{"type":"result","subtype":"success","is_error":false,"terminal_reason":"interrupted","session_id":"s1"}"#
    )
    #expect(reason[0].payload["outcome"]?.stringValue == "cancelled")
  }

  @Test func pairsToolUseWithItsResult() {
    var t = tracker()
    let events = run(
      &t,
      """
      {"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la"}}]},"session_id":"s1"}
      {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"total 0"}],"is_error":false}]},"session_id":"s1","uuid":"u2"}
      """)
    #expect(events.map(\.kind) == [.toolStarted, .toolCompleted])
    #expect(events[0].nativeIds["itemId"] == "toolu_1")
    #expect(events[0].payload["item"]?["command"]?.stringValue == "ls -la")
    #expect(events[0].payload["role"]?.stringValue == "tool")
    #expect(events[1].payload["item"]?["name"]?.stringValue == "Bash")
    #expect(events[1].payload["item"]?["status"]?.stringValue == "completed")
    #expect(events[1].payload["item"]?["output"]?.stringValue == "total 0")
    #expect(events[1].payload["type"]?.stringValue == "toolUse")
  }

  @Test func permissionRequestsOpenRuntimeRequestsWithSafePayloads() {
    var t = tracker()
    let events = run(
      &t,
      """
      {"type":"control_request","request_id":"abc","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build","description":"Clean"},"tool_use_id":"toolu_9","permission_suggestions":[{"type":"addRules"}],"decision_reason":null}}
      {"type":"control_request","request_id":"q","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"red","description":"warm"}],"multiSelect":false}]},"tool_use_id":"toolu_10"}}
      {"type":"control_request","request_id":"e","request":{"subtype":"elicitation","message":"Enter a token"}}
      {"type":"control_cancel_request","request_id":"q"}
      """)
    #expect(
      events.map(\.kind) == [
        .runtimeRequestOpened, .runtimeRequestOpened, .runtimeRequestOpened, .runtimeRequestResolved,
      ])
    #expect(events[0].payload["kind"]?.stringValue == "tool_permission")
    #expect(events[0].payload["answerable"]?.boolValue == true)
    #expect(events[0].nativeIds["requestId"] == "abc")
    #expect(events[0].payload["request"]?["command"]?.stringValue == "rm -rf build")
    #expect(events[0].payload["request"]?["reason"]?.stringValue == "Clean")
    #expect(events[0].payload["request"]?["permission_suggestions"] == nil)
    #expect(events[1].payload["kind"]?.stringValue == "user_question")
    #expect(events[1].payload["request"]?["questions"]?.arrayValue?.first?["id"]?.stringValue == "q0")
    #expect(events[2].payload["kind"]?.stringValue == "elicitation")
    #expect(events[2].payload["answerable"]?.boolValue == false)
    #expect(events[3].nativeIds["requestId"] == "q")
  }

  @Test func sessionStateAndApiKeyConflictTranslate() {
    var t = tracker()
    let waiting = run(
      &t, #"{"type":"system","subtype":"session_state_changed","state":"requires_action","session_id":"s1"}"#)
    #expect(waiting[0].kind == .turnStateChanged)
    #expect(waiting[0].payload["status"]?.stringValue == "waiting_for_user")
    let conflict = run(
      &t,
      #"{"type":"system","subtype":"init","session_id":"s1","model":"m","apiKeySource":"ANTHROPIC_API_KEY","tools":[],"capabilities":[]}"#
    )
    #expect(conflict.map(\.kind) == [.turnStateChanged, .adapterError])
    #expect(conflict[1].payload["errorCode"]?.stringValue == "auth_mode_conflict")
    #expect(run(&t, #"{"type":"command_lifecycle","state":"queued"}"#).isEmpty)
    #expect(run(&t, #"{"type":"keep_alive"}"#).isEmpty)
  }

  @Test func processExitEndsTheActiveTurnAsFailedAndScopesTheDisconnect() {
    var t = tracker()
    let events = t.processExited(status: "signaled(9)")
    #expect(events.map(\.kind) == [.turnFinished, .connectionChanged])
    #expect(events[0].payload["outcome"]?.stringValue == "failed")
    #expect(events[0].nativeIds["turnId"] == "turn-1")
    #expect(events[1].nativeIds["threadId"] == "s1")
    #expect(events[1].payload["transport"]?.stringValue == "disconnected")
    var idle = ClaudeTurnTracker(connectionId: "c1", sessionId: "s1", generation: 1)
    #expect(idle.processExited(status: "exited(0)").map(\.kind) == [.connectionChanged])
  }

  @Test func snapshotItemsComeFromTheTranscript() {
    let lines = [
      #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}"#,
      #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}"#,
      #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"total 0","is_error":false}]}}"#,
      #"{"type":"summary","summary":"ignored"}"#,
    ]
    let items = ClaudeTurnTracker.snapshotItems(transcriptLines: lines)
    #expect(items.map(\.type) == ["userMessage", "agentMessage", "toolUse"])
    #expect(items.map(\.role) == ["user", "assistant", "tool"])
    #expect(items[2].payload["status"]?.stringValue == "completed")
    #expect(items[2].payload["output"]?.stringValue == "total 0")
  }
}
