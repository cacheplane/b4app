import Foundation
import Testing
import WorkspaceProtocol

@testable import ClaudeAdapter

private func steps(_ item: SnapshotItem?) -> [TaskList.Step]? {
  item.flatMap { TaskList(payload: $0.payload) }?.steps
}

private func create(
  _ fold: inout ClaudeTaskFold, _ use: String, _ subject: String, number: Int
)
  -> SnapshotItem?
{
  _ = fold.use(id: use, name: "TaskCreate", input: ["subject": .string(subject), "description": "d"])
  return fold.result(
    toolUseId: use, text: "Task #\(number) created successfully: \(subject)", isError: false)
}

private func update(_ fold: inout ClaudeTaskFold, _ use: String, _ input: JSONValue) -> SnapshotItem? {
  _ = fold.use(id: use, name: "TaskUpdate", input: input)
  return fold.result(toolUseId: use, text: "Updated task", isError: false)
}

@Suite struct ClaudeTaskFoldTests {
  @Test func aTodoWriteIsTheList() {
    var fold = ClaudeTaskFold()
    let item = fold.use(
      id: "toolu_1", name: "TodoWrite",
      input: [
        "todos": [
          ["content": "Read", "status": "completed", "activeForm": "Reading"],
          ["content": "Write", "status": "in_progress", "activeForm": "Writing"],
          ["content": "Ship", "status": "pending", "activeForm": "Shipping"],
        ]
      ])
    #expect(item?.nativeItemId == "tasks:toolu_1")
    #expect(item?.role == "tool" && item?.type == "taskList")
    #expect(
      steps(item) == [
        .init(text: "Read", status: .completed), .init(text: "Write", status: .inProgress),
        .init(text: "Ship", status: .pending),
      ])
    #expect(fold.owns(toolUseId: "toolu_1"))
    // Its result changes nothing.
    #expect(fold.result(toolUseId: "toolu_1", text: "Todos have been modified", isError: false) == nil)
  }

  @Test func aSecondTodoWriteInTheTurnNamesTheSameItem() {
    var fold = ClaudeTaskFold()
    _ = fold.use(id: "toolu_1", name: "TodoWrite", input: ["todos": [["content": "a", "status": "pending"]]])
    let second = fold.use(
      id: "toolu_2", name: "TodoWrite", input: ["todos": [["content": "a", "status": "completed"]]])
    #expect(second?.nativeItemId == "tasks:toolu_1")
    #expect(steps(second) == [.init(text: "a", status: .completed)])
  }

  @Test func aNewTurnStartsANewItemWithTheWholeList() {
    var fold = ClaudeTaskFold()
    _ = create(&fold, "toolu_1", "Read", number: 1)
    _ = create(&fold, "toolu_2", "Write", number: 2)
    fold.beginTurn()
    let item = update(&fold, "toolu_3", ["taskId": "2", "status": "in_progress"])
    #expect(item?.nativeItemId == "tasks:toolu_3")
    #expect(
      steps(item) == [.init(text: "Read", status: .pending), .init(text: "Write", status: .inProgress)])
  }

  @Test func createdTasksAppearWhenTheirResultsArrive() {
    var fold = ClaudeTaskFold()
    #expect(fold.use(id: "toolu_1", name: "TaskCreate", input: ["subject": "Read"]) == nil)
    let item = fold.result(toolUseId: "toolu_1", text: "Task #1 created successfully: Read", isError: false)
    #expect(item?.nativeItemId == "tasks:toolu_1")
    #expect(steps(item) == [.init(text: "Read", status: .pending)])
  }

  @Test func anUpdateChangesItsTask() {
    var fold = ClaudeTaskFold()
    _ = create(&fold, "toolu_1", "Read", number: 1)
    #expect(
      steps(update(&fold, "toolu_2", ["taskId": "1", "status": "in_progress"]))
        == [.init(text: "Read", status: .inProgress)])
    #expect(
      steps(update(&fold, "toolu_3", ["taskId": "1", "status": "completed", "subject": "Read it all"]))
        == [.init(text: "Read it all", status: .completed)])
  }

  @Test func aDeletedTaskIsRemoved() {
    var fold = ClaudeTaskFold()
    _ = create(&fold, "toolu_1", "Read", number: 1)
    _ = create(&fold, "toolu_2", "Write", number: 2)
    #expect(
      steps(update(&fold, "toolu_3", ["taskId": "1", "status": "deleted"]))
        == [.init(text: "Write", status: .pending)])
  }

  @Test func aFailedCreateAddsNothing() {
    var fold = ClaudeTaskFold()
    _ = fold.use(id: "toolu_1", name: "TaskCreate", input: ["subject": "Read"])
    #expect(fold.result(toolUseId: "toolu_1", text: "Task #1 created successfully", isError: true) == nil)
    #expect(steps(create(&fold, "toolu_2", "Write", number: 1)) == [.init(text: "Write", status: .pending)])
  }

  @Test func aCreateResultWithNoNumberAddsNothing() {
    var fold = ClaudeTaskFold()
    _ = fold.use(id: "toolu_1", name: "TaskCreate", input: ["subject": "Read"])
    #expect(fold.result(toolUseId: "toolu_1", text: "Created.", isError: false) == nil)
    #expect(steps(create(&fold, "toolu_2", "Write", number: 2)) == [.init(text: "Write", status: .pending)])
  }

  @Test func anUpdateThatChangesNothingWritesNothing() {
    var fold = ClaudeTaskFold()
    _ = create(&fold, "toolu_1", "Read", number: 1)
    #expect(update(&fold, "toolu_2", ["taskId": "9", "status": "completed"]) == nil)
    #expect(update(&fold, "toolu_3", ["taskId": "1", "status": "pending"]) == nil)
    _ = fold.use(id: "toolu_4", name: "TaskUpdate", input: ["taskId": "1", "status": "completed"])
    #expect(fold.result(toolUseId: "toolu_4", text: "Task not found", isError: true) == nil)
  }

  @Test func listingTasksChangesNothing() {
    var fold = ClaudeTaskFold()
    _ = create(&fold, "toolu_1", "Read", number: 1)
    #expect(fold.use(id: "toolu_2", name: "TaskList", input: [:]) == nil)
    #expect(fold.result(toolUseId: "toolu_2", text: "#1 [pending] Read", isError: false) == nil)
    #expect(fold.use(id: "toolu_3", name: "TaskGet", input: ["taskId": "1"]) == nil)
    #expect(fold.owns(toolUseId: "toolu_2") && fold.owns(toolUseId: "toolu_3"))
  }

  @Test func aResultTheFoldWasNotGivenIsNotItsOwn() {
    var fold = ClaudeTaskFold()
    #expect(!fold.owns(toolUseId: "toolu_9"))
    #expect(fold.result(toolUseId: "toolu_9", text: "Task #4 created successfully", isError: false) == nil)
  }

  @Test func aTodoWriteReplacesCreatedTasks() {
    var fold = ClaudeTaskFold()
    _ = create(&fold, "toolu_1", "Read", number: 1)
    let item = fold.use(
      id: "toolu_2", name: "TodoWrite", input: ["todos": [["content": "Other", "status": "pending"]]])
    #expect(steps(item) == [.init(text: "Other", status: .pending)])
    #expect(update(&fold, "toolu_3", ["taskId": "1", "status": "completed"]) == nil)
  }
}

private func frames(_ text: String) -> [ClaudeStream.Frame] {
  text.split(separator: "\n").map { ClaudeStream.decodeFrame(String($0)) }
}

private func run(_ tracker: inout ClaudeTurnTracker, _ text: String) -> [AdapterEvent] {
  frames(text).flatMap { tracker.translate($0) }
}

private func use(_ id: String, _ name: String, _ input: String, uuid: String = "a") -> String {
  #"{"type":"assistant","uuid":"\#(uuid)-\#(id)","message":{"id":"msg_\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]},"session_id":"s1"}"#
}

private func result(_ id: String, _ text: String, error: Bool = false) -> String {
  #"{"type":"user","uuid":"r-\#(id)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(text)","is_error":\#(error)}]},"session_id":"s1"}"#
}

private let twoTasks = [
  use("toolu_1", "TaskCreate", #"{"subject":"Read","description":"d","activeForm":"Reading"}"#),
  result("toolu_1", "Task #1 created successfully: Read"),
  use("toolu_2", "TaskCreate", #"{"subject":"Write","description":"d","activeForm":"Writing"}"#),
  result("toolu_2", "Task #2 created successfully: Write"),
]

private let updateOne = [
  use("toolu_3", "TaskUpdate", #"{"taskId":"1","status":"in_progress"}"#),
  result("toolu_3", "Updated task #1 status"),
]

private func lists(_ events: [AdapterEvent]) -> [(id: String?, list: TaskList)] {
  events.compactMap { event in
    TaskList(payload: event.payload["item"] ?? .null).map { (event.nativeIds["itemId"], $0) }
  }
}

@Suite struct ClaudeTaskListTrackerTests {
  private func tracker() -> ClaudeTurnTracker {
    var tracker = ClaudeTurnTracker(connectionId: "c1", sessionId: "s1", generation: 2)
    tracker.beginTurn(uuid: "turn-1")
    return tracker
  }

  @Test func aTodoWriteEmitsTheListAndNoToolRow() {
    var t = tracker()
    let events = run(
      &t,
      [
        #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}},"session_id":"s1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"TodoWrite","input":{}}},"session_id":"s1"}"#,
        use(
          "toolu_1", "TodoWrite",
          #"{"todos":[{"content":"Read","status":"in_progress","activeForm":"Reading"}]}"#),
        result("toolu_1", "Todos have been modified successfully"),
      ].joined(separator: "\n"))
    #expect(events.map(\.kind) == [.toolCompleted])
    #expect(events.first?.payload["type"]?.stringValue == "taskList")
    #expect(events.first?.payload["role"]?.stringValue == "tool")
    #expect(events.first?.nativeIds["turnId"] == "turn-1")
    #expect(lists(events).map(\.id) == ["tasks:toolu_1"])
    #expect(lists(events).first?.list.steps == [.init(text: "Read", status: .inProgress)])
  }

  @Test func taskToolsEmitTheListAsItGrows() {
    var t = tracker()
    let events = run(&t, (twoTasks + updateOne).joined(separator: "\n"))
    #expect(events.allSatisfy { $0.payload["type"]?.stringValue == "taskList" })
    #expect(lists(events).map(\.id) == ["tasks:toolu_1", "tasks:toolu_1", "tasks:toolu_1"])
    #expect(lists(events).map(\.list.steps.count) == [1, 2, 2])
    #expect(
      lists(events).last?.list.steps
        == [.init(text: "Read", status: .inProgress), .init(text: "Write", status: .pending)])
  }

  @Test func otherToolsAreUnchanged() {
    var t = tracker()
    let events = run(
      &t, [use("toolu_1", "Bash", #"{"command":"ls"}"#), result("toolu_1", "file")].joined(separator: "\n"))
    #expect(events.map(\.kind) == [.toolStarted, .toolCompleted])
    #expect(events.allSatisfy { $0.payload["type"]?.stringValue == "toolUse" })
  }

  @Test func aSeededTrackerAppliesAnUpdateToAnEarlierTask() {
    var t = ClaudeTurnTracker(connectionId: "c1", sessionId: "s1", generation: 2)
    t.seedTasks(transcriptLines: twoTasks)
    t.beginTurn(uuid: "turn-2")
    let events = run(&t, updateOne.joined(separator: "\n"))
    #expect(lists(events).map(\.id) == ["tasks:toolu_3"])
    #expect(
      lists(events).first?.list.steps
        == [.init(text: "Read", status: .inProgress), .init(text: "Write", status: .pending)])
  }

  @Test func anUnseededTrackerIgnoresAnUpdateToATaskItNeverSaw() {
    var t = tracker()
    #expect(run(&t, updateOne.joined(separator: "\n")).isEmpty)
  }

  @Test func historyFoldsTheSameCallsUnderTheSameIds() {
    var t = tracker()
    let live = lists(run(&t, (twoTasks + updateOne).joined(separator: "\n")))
    let items = ClaudeTurnTracker.snapshotItems(
      transcriptLines: [#"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#] + twoTasks
        + updateOne)
    #expect(items.map(\.type) == ["userMessage", "taskList"])
    #expect(items.last?.nativeItemId == live.last?.id)
    #expect(items.last.flatMap { TaskList(payload: $0.payload) } == live.last?.list)
  }

  /// A turn Claude Code starts itself (a task notification) is never begun by the app: the turn before
  /// it ended, and that is where its list item ends too, as history starts one at the user line.
  @Test func aTurnClaudeCodeStartsItselfGetsItsOwnItem() {
    var t = tracker()
    let done =
      #"{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"num_turns":1,"total_cost_usd":0.01,"result":"ok","session_id":"s1"}"#
    let first = run(
      &t,
      [use("toolu_1", "TodoWrite", #"{"todos":[{"content":"Read","status":"pending"}]}"#), done].joined(
        separator: "\n"))
    let second = run(&t, use("toolu_2", "TodoWrite", #"{"todos":[{"content":"Read","status":"completed"}]}"#))
    #expect(lists(first).map(\.id) == ["tasks:toolu_1"])
    #expect(lists(second).map(\.id) == ["tasks:toolu_2"])
  }

  /// A sub-agent keeps its own list. Its task tools are not the session's, and its lines are not in
  /// the session's transcript, so history never folds them either.
  @Test func aSubAgentsTaskToolsAreNotTheSessionsList() {
    var t = tracker()
    _ = run(&t, twoTasks.joined(separator: "\n"))
    let inner = [
      #"{"type":"assistant","uuid":"s1","parent_tool_use_id":"toolu_agent","message":{"id":"msg_s","role":"assistant","content":[{"type":"tool_use","id":"toolu_s","name":"TodoWrite","input":{"todos":[{"content":"Inner","status":"pending"}]}}]},"session_id":"s1"}"#,
      #"{"type":"user","uuid":"s2","parent_tool_use_id":"toolu_agent","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_s","content":"ok","is_error":false}]},"session_id":"s1"}"#,
    ]
    #expect(lists(run(&t, inner.joined(separator: "\n"))).isEmpty)
    let after = lists(run(&t, updateOne.joined(separator: "\n")))
    #expect(
      after.last?.list.steps
        == [.init(text: "Read", status: .inProgress), .init(text: "Write", status: .pending)])
  }

  /// A summary Claude Code writes when it compacts mid-turn is a user line with text, and not a turn.
  @Test func aCompactionSummaryDoesNotStartANewItem() {
    let items = ClaudeTurnTracker.snapshotItems(
      transcriptLines: [#"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#]
        + twoTasks
        + [
          #"{"type":"user","uuid":"c1","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued."}}"#
        ] + updateOne)
    #expect(items.filter { $0.type == "taskList" }.map(\.nativeItemId) == ["tasks:toolu_1"])
  }

  @Test func historyStartsANewItemAtEachTurn() {
    let items = ClaudeTurnTracker.snapshotItems(
      transcriptLines: [
        #"{"type":"user","uuid":"u1","message":{"role":"user","content":"go"}}"#,
        use("toolu_1", "TodoWrite", #"{"todos":[{"content":"Read","status":"pending"}]}"#),
        result("toolu_1", "ok"),
        #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"more"}]}}"#,
        use("toolu_2", "TodoWrite", #"{"todos":[{"content":"Read","status":"completed"}]}"#),
        result("toolu_2", "ok"),
      ])
    #expect(items.map(\.nativeItemId) == ["u1", "tasks:toolu_1", "u2#0", "tasks:toolu_2"])
    #expect(TaskList(payload: items[1].payload)?.steps == [.init(text: "Read", status: .pending)])
    #expect(TaskList(payload: items[3].payload)?.steps == [.init(text: "Read", status: .completed)])
  }
}
