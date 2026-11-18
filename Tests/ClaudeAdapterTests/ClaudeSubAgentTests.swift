import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

/// A sub-agent's frames (Claude Code 2.1.282, `Fixtures/subagent-run.jsonl`, recorded live and scrubbed):
/// every item written for one names the tool call that started it.
@Suite struct ClaudeSubAgentTests {
  private static let agentCall = "toolu_01MYgoiNaRXENvWnkmFHm6m3"
  private static let bash = "toolu_01AYqQZFiYBu9gBzJMaJ4JqG"
  private static let read = "toolu_01TUgdc6SEEu9HLJuG6paxPJ"

  private func recording() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent-run.jsonl")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  private func tracker() -> ClaudeTurnTracker {
    var tracker = ClaudeTurnTracker(connectionId: "c1", sessionId: "session-1", generation: 1)
    tracker.beginTurn(uuid: "turn-1")
    return tracker
  }

  private func run(_ tracker: inout ClaudeTurnTracker, _ lines: [String]) -> [AdapterEvent] {
    lines.flatMap { tracker.translate(ClaudeStream.decodeFrame($0)) }
  }

  private func parent(_ event: AdapterEvent) -> String? {
    event.payload["item"]?["parentNativeItemId"]?.stringValue
  }

  @Test func theRecordedRunYieldsTheCallItsChildrenAndTheReply() throws {
    var t = tracker()
    let events = run(&t, try recording())
    let shown = events.filter { $0.kind != .turnStateChanged && $0.kind != .usageChanged }
    let rows = shown.map { event in
      "\(event.kind.rawValue) \(event.nativeIds["itemId"] ?? "-") \(event.payload["item"]?["name"]?.stringValue ?? event.payload["type"]?.stringValue ?? "")"
    }
    #expect(
      rows == [
        "tool.started \(Self.agentCall) Agent",
        "tool.started \(Self.agentCall) Agent",
        "tool.started \(Self.bash) Bash",
        "tool.started \(Self.read) Read",
        "tool.completed \(Self.read) Read",
        "tool.completed \(Self.bash) Bash",
        "tool.completed \(Self.agentCall) Agent",
        "tool.started msg_011ChAwXmFX8y9Aiw3YkeXK3#0 thinking",
        "tool.completed msg_011ChAwXmFX8y9Aiw3YkeXK3#0 thinking",
        "message.started msg_011ChAwXmFX8y9Aiw3YkeXK3#1 agentMessage",
        "message.delta msg_011ChAwXmFX8y9Aiw3YkeXK3#1 ",
        "message.completed msg_011ChAwXmFX8y9Aiw3YkeXK3#1 agentMessage",
        "turn.finished - ",
      ])
    // The parent call's own item is the id its children name, and names no parent.
    for event in shown where event.nativeIds["itemId"] == Self.agentCall {
      #expect(parent(event) == nil)
      #expect(event.payload["item"]?["id"]?.stringValue == Self.agentCall)
    }
    // Each child names the call, on its started and on its completed event.
    for id in [Self.bash, Self.read] {
      let writes = shown.filter { $0.nativeIds["itemId"] == id }
      #expect(writes.map(\.kind) == [.toolStarted, .toolCompleted])
      #expect(writes.allSatisfy { parent($0) == Self.agentCall })
    }
    let handBack = try #require(
      shown.last { $0.nativeIds["itemId"] == Self.agentCall && $0.kind == .toolCompleted })
    #expect(handBack.payload["item"]?["output"]?.stringValue?.hasPrefix("[Subagent hand-back]") == true)
    #expect(handBack.payload["item"]?["status"]?.stringValue == "completed")
    #expect(
      try #require(shown.first { $0.nativeIds["itemId"] == Self.read && $0.kind == .toolCompleted })
        .payload["item"]?["output"]?.stringValue == "1\tlet a = 1\n2\t")
    // The parent's own thinking and reply name no parent, and the reply's delta is its own.
    let reply = shown.filter { $0.nativeIds["itemId"]?.hasPrefix("msg_011ChAwXmFX8y9Aiw3YkeXK3") == true }
    #expect(reply.allSatisfy { parent($0) == nil })
    #expect(shown.last?.payload["outcome"]?.stringValue == "completed")
  }

  /// The sub-agent's first frame is its prompt, a `user` frame with text: not a message of the thread.
  @Test func aSubAgentsPromptIsNoRow() {
    var t = tracker()
    let events = run(
      &t,
      [
        #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Count the files."}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"u1"}"#
      ])
    #expect(events.isEmpty)
  }

  @Test func theTaskSystemFramesProduceNothing() {
    var t = tracker()
    let events = run(
      &t,
      [
        #"{"type":"system","subtype":"task_started","task_id":"a","tool_use_id":"toolu_agent","description":"d","session_id":"s1"}"#,
        #"{"type":"system","subtype":"task_progress","task_id":"a","tool_use_id":"toolu_agent","session_id":"s1"}"#,
        #"{"type":"system","subtype":"task_summary","detail":null,"session_id":"s1"}"#,
        #"{"type":"system","subtype":"task_updated","task_id":"a","patch":{"status":"completed"},"session_id":"s1"}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"a","tool_use_id":"toolu_agent","status":"completed","session_id":"s1"}"#,
        #"{"type":"system","subtype":"post_turn_summary","status_category":"completed","session_id":"s1"}"#,
      ])
    #expect(events.isEmpty)
  }

  /// Not observed on 2.1.282 (the recorded sub-agent sent no text or thinking frame): hand-written
  /// frames modelled on the recorded `assistant` frames.
  @Test func aSubAgentsTextAndThinkingNameTheCall() {
    var t = tracker()
    let events = run(
      &t,
      [
        #"{"type":"assistant","message":{"id":"msg_c1","role":"assistant","content":[{"type":"thinking","thinking":"Plan."}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"a1"}"#,
        #"{"type":"assistant","message":{"id":"msg_c1","role":"assistant","content":[{"type":"text","text":"Found 3."}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"a2"}"#,
      ])
    #expect(events.map(\.kind) == [.toolCompleted, .messageCompleted])
    #expect(events.map { parent($0) } == ["toolu_agent", "toolu_agent"])
    #expect(events.map { $0.payload["type"]?.stringValue } == ["thinking", "agentMessage"])
  }

  /// Not observed on 2.1.282 (no `stream_event` frame was sent for the recorded sub-agent): a
  /// hand-written frame. A child's started items name the call and its text is not streamed.
  @Test func aSubAgentsStreamedItemsNameTheCallAndItsTextIsNotStreamed() {
    var t = tracker()
    let events = run(
      &t,
      [
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_c2","role":"assistant","content":[]}},"parent_tool_use_id":"toolu_agent","session_id":"s1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":"toolu_agent","session_id":"s1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}},"parent_tool_use_id":"toolu_agent","session_id":"s1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_c","name":"Bash","input":{}}},"parent_tool_use_id":"toolu_agent","session_id":"s1"}"#,
        #"{"type":"assistant","message":{"id":"msg_c2","role":"assistant","content":[{"type":"tool_use","id":"toolu_c","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"a1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_c","content":"x","is_error":true}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"u2"}"#,
      ])
    #expect(events.map(\.kind) == [.messageStarted, .toolStarted, .toolStarted, .toolCompleted])
    #expect(events.allSatisfy { parent($0) == "toolu_agent" })
    #expect(events.last?.payload["item"]?["status"]?.stringValue == "failed")
  }

  @Test func aDeclinedChildNamesTheCallToo() {
    var t = tracker()
    t.markDeclined(toolUseId: "toolu_c")
    let events = run(
      &t,
      [
        #"{"type":"assistant","message":{"id":"msg_c3","role":"assistant","content":[{"type":"tool_use","id":"toolu_c","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"a1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_c","content":"no","is_error":true}]},"parent_tool_use_id":"toolu_agent","session_id":"s1","uuid":"u2"}"#,
      ])
    #expect(events.last?.payload["item"]?["status"]?.stringValue == "declined")
    #expect(events.allSatisfy { parent($0) == "toolu_agent" })
  }
}
