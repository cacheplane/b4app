import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What a thread draws at dense density, decided without SwiftUI.
@Suite struct DenseTranscriptTests {
  // MARK: fixtures

  private func item(
    _ id: String, turn: String? = "t1", role: DisplayItemRole, type: String, status: String? = nil,
    payload: [String: JSONValue] = [:]
  ) -> DisplayItem {
    var members = payload
    if let status { members["status"] = .string(status) }
    return DisplayItem(
      id: id, threadId: "th", turnId: turn, role: role, type: type, payload: .object(members), sequence: 0,
      provenance: .live)
  }

  private func user(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .user, type: "userMessage")
  }
  private func message(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .assistant, type: "agentMessage")
  }
  private func reasoning(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .assistant, type: "reasoning")
  }
  private func command(
    _ id: String, turn: String? = "t1", status: String = "completed", command: String = "ls"
  ) -> DisplayItem {
    item(
      id, turn: turn, role: .tool, type: "commandExecution", status: status,
      payload: ["command": .string(command)])
  }
  private func toolUse(
    _ id: String, turn: String? = "t1", status: String = "completed", name: String = "Read",
    path: String? = nil
  ) -> DisplayItem {
    var payload: [String: JSONValue] = ["name": .string(name)]
    if let path { payload["path"] = .string(path) }
    return item(id, turn: turn, role: .tool, type: "toolUse", status: status, payload: payload)
  }
  private func tool(
    _ id: String, turn: String? = "t1", type: String = "toolCall", status: String = "completed"
  )
    -> DisplayItem
  {
    item(id, turn: turn, role: .tool, type: type, status: status)
  }
  private func system(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .system, type: "contextCompaction")
  }

  /// Sequence numbers follow the array's order.
  private func numbered(_ items: [DisplayItem]) -> [DisplayItem] {
    items.enumerated().map { index, item in
      var copy = item
      copy.sequence = index + 1
      return copy
    }
  }

  private func turn(
    _ id: String = "t1", _ status: TurnStatus = .terminal, _ outcome: TurnOutcome? = .completed
  ) -> Turn {
    Turn(id: id, threadId: "th", operationId: "op-\(id)", status: status, outcome: outcome)
  }

  private func ids(_ entries: [DenseTranscript.Entry]) -> [String] { entries.map(\.id) }

  private func line(_ entries: [DenseTranscript.Entry], _ group: String = "t1") -> DenseTranscript.StepsLine?
  {
    for case .line(let line) in entries where line.group == group { return line }
    return nil
  }

  private func entries(
    _ items: [DisplayItem], turns: [Turn], open: Set<String> = []
  ) -> [DenseTranscript.Entry] {
    DenseTranscript.entries(items: numbered(items), turns: turns, open: open)
  }

  // MARK: ended turns

  @Test func anEndedTurnIsMessageLineAnswer() throws {
    let result = entries(
      [
        user("u1"), reasoning("r1"), command("c1"), command("c2", status: "failed"), command("c3"),
        message("a1"), toolUse("k1"), message("a2"),
      ], turns: [turn()])
    #expect(ids(result) == ["u1", "steps-t1", "a2"])
    let steps = try #require(line(result))
    #expect(steps.counted == 4)
    #expect(steps.failed == 1)
    #expect(steps.text == "4 steps")
    #expect(steps.failedText == "1 failed")
    #expect(steps.declinedText == nil)
    #expect(steps.action(open: false) == "Show")
    #expect(steps.spoken(open: false) == "4 steps, 1 failed, Show")
    #expect(steps.folded.map(\.id) == ["r1", "c1", "c2", "c3", "a1", "k1"])
  }

  @Test func oneStepIsSingular() throws {
    let result = entries([user("u1"), command("c1"), message("a1")], turns: [turn()])
    #expect(try #require(line(result)).text == "1 step")
  }

  @Test func aDeclinedStepIsCountedApartFromFailed() throws {
    let result = entries(
      [
        user("u1"), command("c1", status: "declined"), command("c2", status: "failed"), command("c3"),
        command("c4"), message("a1"),
      ], turns: [turn()])
    let steps = try #require(line(result))
    #expect(steps.counted == 4)
    #expect(steps.failed == 1)
    #expect(steps.declined == 1)
    #expect(steps.declinedText == "1 declined")
    #expect(steps.spoken(open: false) == "4 steps, 1 failed, 1 declined, Show")
  }

  @Test func planAndCapabilityItemsAreNotSteps() throws {
    let plan = item(
      "p1", role: .tool, type: "plan_update", payload: ["event": .string("plan_update")])
    let items = [
      user("u1"), plan, tool("e1", type: "enteredReviewMode"), toolUse("td", name: "TodoWrite"),
      tool("f1", type: "functionCallOutput"), tool("t-call"),
    ]
    let result = entries(items, turns: [turn()])
    let steps = try #require(line(result))
    #expect(steps.counted == 1)
    #expect(steps.folded.map(\.id) == ["p1", "e1", "td", "f1", "t-call"])
    for type in [
      "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "imageView",
      "toolCall", "toolUse",
    ] {
      #expect(DenseTranscript.isCountedStep(tool("x", type: type)), "\(type)")
    }
    #expect(!DenseTranscript.isCountedStep(item("x", role: .assistant, type: "toolUse")))
  }

  @Test func aTrailingCapabilityItemDoesNotHideTheAnswer() {
    let result = entries(
      [user("u1"), tool("k1"), message("a1"), item("p1", role: .tool, type: "plan_update")],
      turns: [turn()])
    #expect(ids(result) == ["u1", "steps-t1", "a1"])
  }

  @Test func aTurnWithOnlyAnAnswerHasNoLine() {
    #expect(ids(entries([user("u1"), message("a1")], turns: [turn()])) == ["u1", "a1"])
  }

  @Test func reasoningAloneGetsShowWorking() throws {
    let result = entries([user("u1"), reasoning("r1"), message("a1")], turns: [turn()])
    let steps = try #require(line(result))
    #expect(steps.text == nil)
    #expect(steps.action(open: false) == "Show working")
    #expect(steps.action(open: true) == "Hide working")
  }

  @Test func anOpenTurnDrawsEverythingInOrder() throws {
    let result = entries(
      [user("u1"), reasoning("r1"), tool("tool1"), message("a1"), tool("tool2"), message("a2")],
      turns: [turn()], open: ["t1"])
    #expect(ids(result) == ["u1", "steps-t1", "r1", "tool1", "a1", "tool2", "a2"])
    #expect(try #require(line(result)).action(open: true) == "Hide")
  }

  @Test func aFailedTurnWithNoAnswerShowsItsLineAndNote() {
    let result = entries(
      [user("u1"), message("a1"), tool("k1")], turns: [turn("t1", .terminal, .failed)])
    #expect(ids(result) == ["u1", "steps-t1", "note-t1"])
  }

  @Test func aStoppedTurnWithAnAnswerEndsWithItsNote() {
    let result = entries(
      [user("u1"), tool("k1"), message("a1")], turns: [turn("t1", .terminal, .cancelled)])
    #expect(ids(result) == ["u1", "steps-t1", "a1", "note-t1"])
  }

  @Test func aStoppedTurnsUnfinishedStepReadsStopped() throws {
    let items = [user("u1"), tool("k1"), tool("k2", status: "inProgress")]
    let stopped = turn("t1", .terminal, .cancelled)
    let closed = try #require(line(entries(items, turns: [stopped])))
    #expect(closed.counted == 2)
    #expect(!closed.running)
    #expect(closed.text == "2 steps")
    let opened = entries(items, turns: [stopped], open: ["t1"])
    let second = opened.compactMap { entry -> DisplayItem? in
      if case .item(let item) = entry, item.id == "k2" { return item }
      return nil
    }.first
    #expect(second?.payload["status"] == .string("stopped"))
    #expect(second?.id == "k2")
  }

  // MARK: running turns

  @Test func aRunningTurnNamesItsNewestRunningStep() throws {
    let items = [
      user("u1"), tool("k1"), tool("k2"), command("c1", status: "inProgress", command: "swift test"),
      toolUse("k3", status: "inProgress", name: "Read", path: "Package.swift"),
    ]
    let running = turn("t1", .running, nil)
    let both = try #require(line(entries(items, turns: [running])))
    #expect(both.running)
    #expect(both.text == "Read: Package.swift")
    let first = try #require(line(entries(Array(items.dropLast()), turns: [running])))
    #expect(first.text == "swift test")
  }

  @Test func theNameIsTheLabelThenTheCardTitleCutAt120() throws {
    let running = turn("t1", .running, nil)
    func name(_ step: DisplayItem) throws -> String? {
      try #require(line(entries([user("u1"), step], turns: [running]))).text
    }
    let labelled = item(
      "k1", role: .tool, type: "toolCall", status: "inProgress",
      payload: ["name": .string("search"), "label": .string("Searching b4")])
    #expect(try name(labelled) == "Searching b4")
    let long = String(repeating: "x", count: 200)
    let cut = try #require(try name(command("c1", status: "inProgress", command: long)))
    #expect(cut.count == 120)
    #expect(cut.hasSuffix("…"))
    #expect(try name(command("c2", status: "inProgress", command: "echo one\necho two")) == "echo one")
  }

  @Test func aBlankStepNameReadsWorking() throws {
    let running = turn("t1", .running, nil)
    for blank in ["", "\n  second line", "   "] {
      let result = entries(
        [user("u1"), command("c1", status: "inProgress", command: blank)], turns: [running])
      let steps = try #require(line(result))
      #expect(steps.runningName == nil)
      #expect(steps.text == "Working")
    }
  }

  @Test func aRunningTurnBetweenStepsReadsWorking() throws {
    let running = turn("t1", .running, nil)
    let quiet = try #require(line(entries([user("u1"), tool("k1"), tool("k2")], turns: [running])))
    #expect(quiet.text == "Working")
    #expect(quiet.action(open: false) == "Show")
    let failed = try #require(
      line(entries([user("u1"), tool("k1", status: "failed"), tool("k2")], turns: [running])))
    #expect(failed.text == "Working")
    #expect(failed.failedText == "1 failed")
  }

  @Test func aTurnWaitingOnTheUserSaysSo() throws {
    let result = entries(
      [user("u1"), tool("k1", status: "inProgress")], turns: [turn("t1", .waitingForUser, nil)])
    let steps = try #require(line(result))
    #expect(steps.waiting)
    #expect(steps.text == "Waiting for you")
  }

  @Test func aTurnWhoseOutcomeIsUnknownCounts() throws {
    let result = entries(
      [user("u1"), tool("k1", status: "inProgress")], turns: [turn("t1", .reconciling, nil)],
      open: ["t1"])
    let steps = try #require(line(result))
    #expect(!steps.running)
    #expect(steps.text == "1 step")
    #expect(steps.folded.first?.payload["status"] == .string("inProgress"))
    #expect(!ids(result).contains("note-t1"))
  }

  @Test func messagesStayWhileTheTurnRuns() throws {
    let result = entries(
      [user("u1"), message("m1"), tool("k1"), message("m2"), tool("k2", status: "inProgress")],
      turns: [turn("t1", .running, nil)])
    #expect(ids(result) == ["u1", "steps-t1", "m1", "m2"])
    #expect(try #require(line(result)).folded.map(\.id) == ["k1", "k2"])
  }

  @Test func messagesFoldWhenTheTurnEnds() throws {
    let items = [
      user("u1"), message("m1"), tool("k1"), message("m2"), tool("k2"), message("m3"),
    ]
    let result = entries(items, turns: [turn()])
    #expect(ids(result) == ["u1", "steps-t1", "m3"])
    #expect(try #require(line(result)).folded.map(\.id) == ["m1", "k1", "m2", "k2"])
  }

  @Test func aRunningTurnWithNothingYetHasNoLine() {
    let running = turn("t1", .running, nil)
    #expect(ids(entries([user("u1")], turns: [running])) == ["u1"])
    #expect(ids(entries([user("u1"), message("m1")], turns: [running])) == ["u1", "m1"])
  }

  // MARK: grouping

  @Test func aThreadFromHistoryIsGroupedAtUserMessages() throws {
    let items = [
      user("u1", turn: nil), tool("k1", turn: nil), tool("k2", turn: nil), message("m1", turn: nil),
      user("u2", turn: nil), reasoning("r1", turn: nil), message("m2", turn: nil),
      message("m3", turn: nil),
    ]
    let result = entries(items, turns: [])
    #expect(ids(result) == ["u1", "steps-h-u1", "m1", "u2", "steps-h-u2", "m3"])
    #expect(try #require(line(result, "h-u1")).text == "2 steps")
    #expect(try #require(line(result, "h-u2")).text == nil)
    #expect(try #require(line(result, "h-u2")).action(open: false) == "Show working")
  }

  @Test func aTurnlessItemJoinsTheGroupBeforeIt() throws {
    let result = entries(
      [
        user("u1"), tool("k1"), message("a1"), toolUse("k2", turn: nil), message("a2", turn: nil),
      ], turns: [turn()])
    #expect(ids(result) == ["u1", "steps-t1", "a2"])
    let steps = try #require(line(result))
    #expect(steps.counted == 2)
    #expect(steps.folded.map(\.id) == ["k1", "a1", "k2"])
  }

  @Test func turnlessItemsBeforeAnyGroupAreDrawnAsTheyAre() {
    let result = entries(
      [
        item("s0", turn: nil, role: .system, type: "contextCompaction"), tool("k0", turn: nil),
        user("u1"), message("a1"),
      ], turns: [turn()])
    #expect(ids(result) == ["s0", "k0", "u1", "a1"])
  }

  @Test func systemItemsFollowTheirTurnsMessages() {
    let result = entries(
      [user("u1"), tool("k1"), system("s1"), message("a1")], turns: [turn("t1", .terminal, .failed)])
    #expect(ids(result) == ["u1", "steps-t1", "a1", "s1", "note-t1"])
  }

  @Test func twoTurnsEachGetTheirOwnLine() {
    let result = entries(
      [
        user("u1"), tool("k1"), item("x1", turn: nil, role: .tool, type: "toolCall", status: "completed"),
        message("a1"), user("u2", turn: "t2"), tool("k2", turn: "t2"), message("a2", turn: "t2"),
      ], turns: [turn("t1"), turn("t2")])
    #expect(ids(result) == ["u1", "steps-t1", "a1", "u2", "steps-t2", "a2"])
    #expect(Set(ids(result)).count == result.count)
  }

  @Test func aTurnTheListDoesNotKnowIsDrawnAsEnded() throws {
    let result = entries(
      [
        user("u1", turn: "ghost"), tool("k1", turn: "ghost", status: "inProgress"),
        message("a1", turn: "ghost"),
      ],
      turns: [])
    let steps = try #require(line(result, "ghost"))
    #expect(!steps.running)
    #expect(!ids(result).contains("note-ghost"))
  }

  @Test func aTurnWithNoItemsKeepsItsNote() {
    #expect(ids(entries([], turns: [turn("t1", .terminal, .failed)])) == ["note-t1"])
  }

  @Test func everyItemIsDrawnExactlyOnceWhenEverythingIsOpen() {
    let items = [
      system("s0", turn: nil), user("h1", turn: nil), tool("hk", turn: nil), message("hm", turn: nil),
      user("u1", turn: "t1"), tool("k1"), message("a1"), toolUse("late", turn: nil),
      user("u2", turn: "t2"), reasoning("r2", turn: "t2"), tool("k2", turn: "t2", status: "inProgress"),
      message("m2", turn: "t2"), system("s2", turn: "t2"),
    ]
    let turns = [turn("t1", .terminal, .failed), turn("t2", .running, nil)]
    let result = entries(items, turns: turns, open: ["h-h1", "t1", "t2"])
    let drawn = result.compactMap { entry -> String? in
      if case .item(let item) = entry { return item.id }
      return nil
    }
    #expect(drawn.sorted() == items.map(\.id).sorted())
  }

  // MARK: titles

  @Test func theCardTitleIsUnchanged() {
    #expect(DenseTranscript.title(of: command("c", command: "swift test")) == "swift test")
    #expect(DenseTranscript.title(of: item("c", role: .tool, type: "commandExecution")) == "Command")
    let two = item(
      "f", role: .tool, type: "fileChange",
      payload: ["changes": .array([.object(["path": .string("a")]), .object(["path": .string("b")])])])
    #expect(DenseTranscript.title(of: two) == "File change (2 files)")
    let mcp = item(
      "m", role: .tool, type: "mcpToolCall",
      payload: ["server": .string("git"), "tool": .string("log")])
    #expect(DenseTranscript.title(of: mcp) == "git / log")
    #expect(DenseTranscript.title(of: item("w", role: .tool, type: "webSearch")) == "Web search")
    #expect(
      DenseTranscript.title(of: toolUse("k", name: "Read", path: "Package.swift")) == "Read: Package.swift")
    let call = item(
      "t", role: .tool, type: "toolCall",
      payload: ["name": .string("search"), "input": .string("swift")])
    #expect(DenseTranscript.title(of: call) == "search: swift")
    #expect(DenseTranscript.title(of: item("z", role: .tool, type: "somethingNew")) == "somethingNew")
  }
}
