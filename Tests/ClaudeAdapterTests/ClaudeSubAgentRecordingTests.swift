import Foundation
import Testing
import WorkspaceProtocol

/// What Claude Code 2.1.282 sends for sub-agents, read from four live recordings (2026-11-19, scrubbed;
/// `docs/verification/2026-11-19-live-sub-agent-recordings.md`). These hold the runtime's shape, not the
/// adapter's handling of it.
@Suite struct ClaudeSubAgentRecordingTests {
  private func frames(_ name: String) throws -> [JSONValue] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/\(name).jsonl")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
  }

  private func blocks(_ frame: JSONValue) -> [JSONValue] { frame["message"]?["content"]?.arrayValue ?? [] }
  private func parent(_ frame: JSONValue) -> String? { frame["parent_tool_use_id"]?.stringValue }
  private func agentCalls(_ frames: [JSONValue]) -> [JSONValue] {
    frames.filter { $0["type"]?.stringValue == "assistant" }.flatMap(blocks).filter {
      $0["type"]?.stringValue == "tool_use" && $0["name"]?.stringValue == "Agent"
    }
  }

  /// Two agents started in one message run in the background: each call's result is a launch note, the
  /// turn's result comes while they work, their frames follow it, and Claude Code then starts a turn of
  /// its own for each hand-back, with no user frame.
  @Test func backgroundAgentsOutliveTheTurnAndWakeIt() throws {
    let all = try frames("subagent-background-parallel")
    let calls = agentCalls(all).compactMap { $0["id"]?.stringValue }
    #expect(calls.count == 2)
    let launches = all.filter { $0["type"]?.stringValue == "user" && parent($0) == nil }.flatMap(blocks)
      .filter {
        $0["type"]?.stringValue == "tool_result" && calls.contains($0["tool_use_id"]?.stringValue ?? "")
      }
    #expect(launches.count == 2)
    #expect(
      launches.allSatisfy {
        $0["content"]?.arrayValue?.first?["text"]?.stringValue?.hasPrefix("Async agent launched") == true
      })
    let results = all.indices.filter { all[$0]["type"]?.stringValue == "result" }
    #expect(results.count == 3)
    let childFrames = all.indices.filter { parent(all[$0]).map(calls.contains) == true }
    #expect(childFrames.contains { $0 > results[0] })
    // The wake-up turns: an `init` frame, a reply and a result, and no user frame of the thread's own.
    let afterFirst = all[(results[0] + 1)...]
    #expect(afterFirst.filter { $0["subtype"]?.stringValue == "init" }.count == 2)
    #expect(!afterFirst.contains { $0["type"]?.stringValue == "user" && parent($0) == nil })
    // In the background a sub-agent's text and thinking are sent, each naming its call.
    #expect(
      all.contains { frame in
        frame["type"]?.stringValue == "assistant" && parent(frame).map(calls.contains) == true
          && blocks(frame).contains { $0["type"]?.stringValue == "text" }
      })
    // Each agent's end is a `task_notification` naming its call.
    let ended = all.filter { $0["subtype"]?.stringValue == "task_notification" }.compactMap {
      $0["tool_use_id"]?.stringValue
    }
    #expect(calls.allSatisfy(ended.contains))
  }

  /// A foreground agent's own text and thinking are not sent: only its prompt, tool uses and results.
  @Test func aForegroundAgentsTextIsNotSent() throws {
    let all = try frames("subagent-foreground-text")
    let call = try #require(agentCalls(all).first)
    #expect(call["input"]?["run_in_background"]?.boolValue == false)
    let child = all.filter { parent($0) == call["id"]?.stringValue && $0["type"]?.stringValue == "assistant" }
    #expect(!child.isEmpty)
    #expect(child.flatMap(blocks).allSatisfy { $0["type"]?.stringValue == "tool_use" })
  }

  /// An agent started by an agent names the first agent's call; its own steps are not sent at all.
  @Test func aNestedAgentsStepsAreNotSent() throws {
    let all = try frames("subagent-nested")
    let outer = try #require(
      all.first { $0["type"]?.stringValue == "assistant" && parent($0) == nil && !agentCalls([$0]).isEmpty })
    let outerId = try #require(agentCalls([outer]).first?["id"]?.stringValue)
    let inner = try #require(
      all.first {
        $0["type"]?.stringValue == "assistant" && parent($0) == outerId && !agentCalls([$0]).isEmpty
      })
    let innerId = try #require(agentCalls([inner]).first?["id"]?.stringValue)
    #expect(!all.contains { parent($0) == innerId })
  }

  /// A stop sent after the turn ended with its agent in the background: the agent is killed
  /// (`task_updated` "killed", `task_notification` "stopped") and no result frame follows.
  @Test func stoppingABackgroundAgentSendsNoResult() throws {
    let all = try frames("subagent-background-stopped")
    let result = try #require(all.firstIndex { $0["type"]?.stringValue == "result" })
    let after = all[(result + 1)...]
    #expect(after.contains { $0["patch"]?["status"]?.stringValue == "killed" })
    #expect(
      after.contains {
        $0["subtype"]?.stringValue == "task_notification" && $0["status"]?.stringValue == "stopped"
      })
    #expect(!after.contains { $0["type"]?.stringValue == "result" })
  }
}
