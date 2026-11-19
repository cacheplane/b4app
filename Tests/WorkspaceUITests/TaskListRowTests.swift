import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// A turn's plan or task list: where it goes, how an ended turn settles it, and what the
/// row says. Decided without SwiftUI.
@Suite struct TaskListRowTests {
  private func item(
    _ id: String, role: DisplayItemRole, type: String, payload: JSONValue = [:]
  )
    -> DisplayItem
  {
    DisplayItem(
      id: id, threadId: "th", turnId: "t1", role: role, type: type, payload: payload, sequence: 0,
      provenance: .live)
  }
  private func user(_ id: String) -> DisplayItem { item(id, role: .user, type: "userMessage") }
  private func message(_ id: String) -> DisplayItem {
    item(id, role: .assistant, type: "agentMessage", payload: ["text": "Reply."])
  }
  private func command(_ id: String) -> DisplayItem {
    item(id, role: .tool, type: "commandExecution", payload: ["status": "completed", "command": "ls"])
  }
  private func list(_ statuses: [TaskList.Status], explanation: String? = nil) -> DisplayItem {
    let id = "p1"
    let steps = statuses.enumerated().map { TaskList.Step(text: "Step \($0.offset + 1)", status: $0.element) }
    return item(
      id, role: .tool, type: "taskList", payload: TaskList(steps: steps, explanation: explanation).payload)
  }
  private func turn(_ status: TurnStatus = .terminal, _ outcome: TurnOutcome? = .completed) -> Turn {
    Turn(id: "t1", threadId: "th", operationId: "op", status: status, outcome: outcome)
  }
  private func ids(_ entries: [DenseTranscript.Entry]) -> [String] { entries.map(\.id) }
  private func dense(_ items: [DisplayItem], _ turn: Turn, open: Set<String> = []) -> [DenseTranscript.Entry]
  {
    DenseTranscript.entries(items: items, turns: [turn], open: open)
  }
  private func marks(_ id: String = "p1", in entries: [DenseTranscript.Entry]) -> [TaskStepMark]? {
    // A running turn's list stands outside the fold; an ended turn's is one of its opened rows.
    for entry in entries {
      switch entry {
      case .item(let item) where item.id == id: return TaskListDisplay(item: item)?.steps.map(\.mark)
      case .step(let row) where row.id == id: return TaskListDisplay(item: row.item)?.steps.map(\.mark)
      default: continue
      }
    }
    return nil
  }
  private func line(_ entries: [DenseTranscript.Entry]) -> DenseTranscript.ActivityLine? {
    for case .line(let line) in entries { return line }
    return nil
  }

  // MARK: dense

  @Test func aRunningTurnShowsItsListAfterItsLine() throws {
    let result = dense([user("u1"), command("k1"), list([.completed, .inProgress])], turn(.running, nil))
    #expect(ids(result) == ["u1", "steps-t1", "p1"])
    #expect(try #require(line(result)).counted == 1)
    #expect(marks(in: result) == [.done, .running])
  }

  @Test func anEndedTurnFoldsItsList() throws {
    let items = [user("u1"), command("k1"), list([.completed, .completed]), message("m1")]
    let result = dense(items, turn())
    #expect(ids(result) == ["u1", "steps-t1", "m1"])
    let folded = try #require(line(result))
    #expect(folded.counted == 1 && folded.folded.map(\.id) == ["k1", "p1"])
    #expect(ids(dense(items, turn(), open: ["t1"])) == ["u1", "steps-t1", "k1", "p1", "m1"])
  }

  /// A running turn always has its line, whatever its list says: the list follows it.
  @Test func aRunningTurnsListFollowsItsLine() {
    let running = turn(.running, nil)
    #expect(ids(dense([user("u1"), list([.inProgress, .pending])], running)) == ["u1", "steps-t1", "p1"])
    #expect(ids(dense([user("u1"), list([.pending, .pending])], running)) == ["u1", "steps-t1", "p1"])
    #expect(
      ids(dense([user("u1"), list([.completed, .completed])], running)) == ["u1", "steps-t1", "p1"])
    #expect(
      ids(dense([user("u1"), list([.pending]), message("m1")], running)) == ["u1", "steps-t1", "p1", "m1"])
  }

  @Test func aListIsNotACountedStep() {
    #expect(!DenseTranscript.isCountedStep(list([.pending])))
    #expect(DenseTranscript.title(of: list([.pending])) == "Plan")
  }

  @Test func anEmptyListIsNotDrawn() {
    let items = [user("u1"), list([]), message("m1")]
    #expect(ids(dense(items, turn(), open: ["t1"])) == ["u1", "m1"])
    #expect(ids(dense([user("u1"), list([])], turn(.running, nil))) == ["u1", "steps-t1"])
  }

  @Test(arguments: [TurnOutcome.completed, .cancelled, .failed])
  func aStepInProgressWhenTheTurnEndedIsUnfinished(_ outcome: TurnOutcome) {
    let items = [user("u1"), list([.completed, .inProgress, .pending])]
    let ended = turn(.terminal, outcome)
    #expect(marks(in: dense(items, ended, open: ["t1"])) == [.done, .unfinished, .pending])
  }

  @Test func aStepInProgressWhileReconcilingIsUnknown() {
    let items = [user("u1"), list([.inProgress])]
    #expect(marks(in: dense(items, turn(.reconciling, nil), open: ["t1"])) == [.unknown])
  }

  @Test func aRunningTurnLeavesAStepInProgress() {
    let items = [user("u1"), list([.inProgress])]
    #expect(marks(in: dense(items, turn(.running, nil), open: ["t1"])) == [.running])
  }

  // MARK: the row

  @Test func theHeaderCountsWhatIsDone() throws {
    let display = try #require(
      TaskListDisplay(item: list([.completed, .completed, .inProgress, .pending], explanation: "Why")))
    #expect(display.header == "Plan · 2 of 4")
    #expect(display.accessibilityHeader == "Plan, 2 of 4 done")
    #expect(display.explanation == "Why")
    #expect(display.steps.map(\.text) == ["Step 1", "Step 2", "Step 3", "Step 4"])
    #expect(display.steps.map(\.mark) == [.done, .done, .running, .pending])
    #expect(
      display.steps.map(\.accessibilityLabel) == [
        "Step 1, done", "Step 2, done", "Step 3, in progress", "Step 4, not started",
      ])
  }

  @Test func settledStepsSayTheyAreUnfinishedOrUnknown() {
    #expect(TaskStepMark.unfinished.spoken == "unfinished")
    #expect(TaskStepMark.unknown.spoken == "unknown")
  }

  @Test func nothingIsDrawnForAnEmptyListOrAnotherItem() {
    #expect(TaskListDisplay(item: list([])) == nil)
    #expect(TaskListDisplay(item: command("k1")) == nil)
  }
}
