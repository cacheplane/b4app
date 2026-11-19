import Foundation
import Testing
import WorkspaceProtocol

/// What codex-cli 0.166.0's app-server sends for one sub-agent, read from a live recording (2026-11-19,
/// scrubbed; `docs/verification/2026-11-19-live-sub-agent-recordings.md`). The runtime's shape, not the
/// adapter's handling of it.
@Suite struct CodexSubAgentRecordingTests {
  @Test func aSubAgentIsAThreadOfItsOwnNamedByAnActivityItem() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent-run.jsonl")
    let all = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    let items = all.filter { $0["method"]?.stringValue == "item/completed" }.compactMap { $0["params"] }
    let root = try #require(items.first?["threadId"]?.stringValue)
    let activity = items.filter { $0["item"]?["type"]?.stringValue == "subAgentActivity" }
    #expect(activity.map { $0["item"]?["kind"]?.stringValue } == ["started", "completed"])
    #expect(activity.allSatisfy { $0["threadId"]?.stringValue == root })
    let child = try #require(activity.first?["item"]?["agentThreadId"]?.stringValue)
    #expect(child != root)
    // The agent's steps and messages are items of its own thread, in its own turn.
    let childItems = items.filter { $0["threadId"]?.stringValue == child }
    #expect(
      childItems.compactMap { $0["item"]?["type"]?.stringValue } == [
        "agentMessage", "commandExecution", "commandExecution", "agentMessage",
      ])
    #expect(
      all.contains {
        $0["method"]?.stringValue == "turn/completed" && $0["params"]?["threadId"]?.stringValue == child
      })
    // The only `collabAgentToolCall` is the wait, and it carries no prompt.
    let collab = items.filter { $0["item"]?["type"]?.stringValue == "collabAgentToolCall" }
    #expect(collab.count == 1)
    #expect(collab.first?["item"]?["tool"]?.stringValue == "wait")
    #expect(collab.first?["item"]?["prompt"] == .null)
  }

  /// The parent did not wait: its turn completes while the agent works, the agent's turn names the
  /// parent's as `rootTurnId`, and the "completed" activity item lands on the ended turn. No turn is
  /// started on the parent thread afterwards.
  @Test func anAgentNotWaitedForOutlivesItsTurn() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent-not-awaited.jsonl")
    let all = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
      try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
    }
    func index(_ method: String, thread: String) -> Int? {
      all.firstIndex {
        $0["method"]?.stringValue == method && $0["params"]?["threadId"]?.stringValue == thread
      }
    }
    let started = try #require(all.first { $0["method"]?.stringValue == "turn/started" })
    let root = try #require(started["params"]?["threadId"]?.stringValue)
    let rootTurn = try #require(started["params"]?["turn"]?["id"]?.stringValue)
    let activity = all.indices.filter {
      all[$0]["method"]?.stringValue == "item/completed"
        && all[$0]["params"]?["item"]?["type"]?.stringValue == "subAgentActivity"
    }
    #expect(activity.count == 2)
    let child = try #require(all[activity[0]]["params"]?["item"]?["agentThreadId"]?.stringValue)
    let rootEnd = try #require(index("turn/completed", thread: root))
    let childStart = try #require(index("turn/started", thread: child))
    let childEnd = try #require(index("turn/completed", thread: child))
    #expect(rootEnd < childEnd)
    #expect(all[childStart]["params"]?["turn"]?["rootTurnId"]?.stringValue == rootTurn)
    #expect(activity[1] > rootEnd)
    #expect(all[activity[1]]["params"]?["turnId"]?.stringValue == rootTurn)
    #expect(all.filter { $0["method"]?.stringValue == "turn/started" }.count == 2)
  }
}
