import Testing

@testable import WorkspaceProtocol

@Suite struct TaskListTests {
  @Test func statusesAreReadLeniently() {
    #expect(TaskList.status("in_progress") == .inProgress)
    #expect(TaskList.status("inProgress") == .inProgress)
    #expect(TaskList.status("completed") == .completed)
    #expect(TaskList.status("pending") == .pending)
    #expect(TaskList.status("done") == .pending)
    #expect(TaskList.status(nil) == .pending)
  }

  @Test func thePayloadRoundTrips() {
    let list = TaskList(
      steps: [.init(text: "Read", status: .completed), .init(text: "Write", status: .inProgress)],
      explanation: "Why")
    #expect(TaskList(payload: list.payload) == list)
    #expect(list.payload["status"]?.stringValue == "completed")
    #expect(list.payload["type"]?.stringValue == "taskList")
    #expect(list.completedCount == 1)
  }

  @Test func aListWithNoExplanationStoresNone() {
    let list = TaskList(steps: [.init(text: "Read", status: .pending)])
    #expect(list.payload["explanation"] == nil)
    #expect(TaskList(payload: list.payload) == list)
  }

  @Test func anotherItemIsNotAList() {
    #expect(TaskList(payload: ["type": "toolUse", "steps": []]) == nil)
  }

  @Test func theIdNamesTheTurn() {
    #expect(TaskList.nativeItemId(turn: "t1") == "tasks:t1")
  }
}
