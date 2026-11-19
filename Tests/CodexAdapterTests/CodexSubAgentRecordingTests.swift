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
}
