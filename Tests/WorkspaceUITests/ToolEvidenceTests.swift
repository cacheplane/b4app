import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What an opened tool card shows for each runtime's payload shape (F05, F18).
@Suite struct ToolEvidenceTests {
  private func tool(_ type: String, _ payload: [String: JSONValue]) -> DisplayItem {
    DisplayItem(
      id: "k1", threadId: "th", turnId: "t1", role: .tool, type: type, payload: .object(payload),
      sequence: 1, provenance: .live)
  }

  /// A B4 call's arguments and result, and no dump of the payload beside them.
  @Test func aB4CallShowsItsInputAndOutputOnly() {
    let detail = ToolEvidence.detail(
      of: tool(
        "toolCall",
        [
          "name": "search", "status": "completed", "input": ["q": "b4", "limit": 2], "output": "{\"hits\":2}",
        ]))
    #expect(detail.input == "{\n  \"limit\" : 2,\n  \"q\" : \"b4\"\n}")
    #expect(detail.output == .text("{\"hits\":2}"))
    #expect(detail.raw == nil)
  }

  /// Missing output and an empty result are different.
  @Test func anEmptyResultIsNotAMissingOne() {
    let open = ToolEvidence.detail(
      of: tool("toolUse", ["name": "Bash", "status": "inProgress", "input": .null]))
    #expect(open.output == .none)
    let empty = ToolEvidence.detail(
      of: tool(
        "toolUse", ["name": "Bash", "status": "completed", "input": ["command": "true"], "output": ""]))
    #expect(empty.output == .empty)
    #expect(ToolEvidence.detail(of: tool("toolCall", ["name": "t", "output": .null])).output == .empty)
  }

  /// `false`, `0` and an empty list are results, shown as they are.
  @Test func falsyResultsAreShown() {
    func output(_ value: JSONValue) -> ToolEvidence.Output {
      ToolEvidence.detail(of: tool("toolCall", ["name": "t", "status": "completed", "output": value])).output
    }
    #expect(output(false) == .text("false"))
    #expect(output(0) == .text("0"))
    #expect(output([]) == .text("[\n\n]"))
  }

  @Test func aCommandShowsItsDirectoryOutputAndExitCode() {
    let done = ToolEvidence.detail(
      of: tool(
        "commandExecution",
        [
          "command": "swift build", "cwd": "/repo", "status": "failed",
          "aggregatedOutput": "error: no such module",
          "exitCode": 1,
        ]))
    #expect(done.cwd == "/repo")
    #expect(done.output == .text("error: no such module"))
    #expect(done.exitCode == 1)
    #expect(done.raw == nil)
    // Still running, nothing printed yet: the directory, and no dump of the payload.
    let running = ToolEvidence.detail(
      of: tool("commandExecution", ["command": "swift build", "cwd": "/repo", "status": "inProgress"]))
    #expect(running.output == .none)
    #expect(running.exitCode == nil)
    #expect(running.raw == nil)
  }

  @Test func aFileChangeShowsEachPathAndDiff() {
    let detail = ToolEvidence.detail(
      of: tool(
        "fileChange",
        [
          "status": "completed",
          "changes": [["path": "a.swift", "diff": "+let a = 1"], ["path": "b.swift"]],
        ]))
    #expect(
      detail.changes == [
        ToolEvidence.Change(path: "a.swift", diff: "+let a = 1"),
        ToolEvidence.Change(path: "b.swift", diff: nil),
      ])
    #expect(detail.raw == nil)
  }

  /// An item type the card does not know is still inspectable, and bounded.
  @Test func anUnknownShapeFallsBackToItsPayload() {
    let detail = ToolEvidence.detail(
      of: tool(
        "plan_update", ["event": "plan_update", "zdata": .string(String(repeating: "x", count: 5_000))]))
    #expect(detail.raw?.hasPrefix("{\n  \"event\" : \"plan_update\"") == true)
    #expect(detail.raw?.count == ToolEvidence.rawLimit)
    #expect(detail.rawCut)
    #expect(!ToolEvidence.detail(of: tool("plan_update", ["event": "plan_update"])).rawCut)
  }
}
