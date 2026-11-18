import Foundation
import Testing
import WorkspaceProtocol

@testable import WorkspaceUI

/// What a thread draws, decided without SwiftUI.
@Suite struct DenseTranscriptTests {
  // MARK: fixtures

  /// When every fixture turn and item was made: an ended turn of them took "1s".
  private static let began = "2026-11-18T10:00:00.000Z"

  private func item(
    _ id: String, turn: String? = "t1", role: DisplayItemRole, type: String, status: String? = nil,
    payload: [String: JSONValue] = [:]
  ) -> DisplayItem {
    var members = payload
    if let status { members["status"] = .string(status) }
    return DisplayItem(
      id: id, threadId: "th", turnId: turn, role: role, type: type, payload: .object(members), sequence: 0,
      provenance: .live, createdAt: Self.began)
  }

  private func user(_ id: String, turn: String? = "t1") -> DisplayItem {
    item(id, turn: turn, role: .user, type: "userMessage")
  }
  private func message(_ id: String, turn: String? = "t1", text: String? = nil) -> DisplayItem {
    item(
      id, turn: turn, role: .assistant, type: "agentMessage",
      payload: ["text": .string(text ?? "Reply \(id).")])
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
    Turn(
      id: id, threadId: "th", operationId: "op-\(id)", status: status, outcome: outcome,
      createdAt: Self.began, updatedAt: Self.began)
  }

  private func ids(_ entries: [DenseTranscript.Entry]) -> [String] { entries.map(\.id) }

  private func line(
    _ entries: [DenseTranscript.Entry], _ group: String = "t1"
  ) -> DenseTranscript.ActivityLine? {
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
    #expect(steps.spoken(open: false) == "4 steps, 1 failed, 1s, Show")
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
    #expect(steps.spoken(open: false) == "4 steps, 1 failed, 1 declined, 1s, Show")
  }

  @Test func planAndCapabilityItemsAreNotSteps() throws {
    let plan = item(
      "p1", role: .tool, type: "plan_update", payload: ["event": .string("plan_update")])
    let working = [
      "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ExitPlanMode", "AskUserQuestion",
    ]
    let items =
      [user("u1"), plan, tool("e1", type: "enteredReviewMode")]
      + working.map { toolUse("td-\($0)", name: $0) }
      + [tool("f1", type: "functionCallOutput"), tool("t-call")]
    let result = entries(items, turns: [turn()])
    let steps = try #require(line(result))
    #expect(steps.counted == 1)
    #expect(steps.folded.map(\.id) == ["p1", "e1"] + working.map { "td-\($0)" } + ["f1", "t-call"])
    for name in working {
      #expect(!DenseTranscript.isCountedStep(toolUse("x", name: name)), "\(name)")
    }
    for type in [
      "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "imageView",
      "toolCall", "toolUse", "collabAgentToolCall", "imageGeneration",
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

  @Test func anEmptyMessageIsNeverTheAnswer() {
    for empty in ["", "  \n "] {
      let result = entries(
        [user("u1"), tool("k1"), message("m1", text: "Done so far."), message("m2", text: empty)],
        turns: [turn("t1", .terminal, .cancelled)])
      #expect(ids(result) == ["u1", "steps-t1", "m1", "note-t1"])
    }
  }

  @Test func aStoppedTurnsUnfinishedStepReadsStopped() throws {
    let items = [user("u1"), tool("k1"), tool("k2", status: "inProgress")]
    let stopped = turn("t1", .terminal, .cancelled)
    let closed = try #require(line(entries(items, turns: [stopped])))
    #expect(closed.counted == 2)
    #expect(closed.state == .ended)
    #expect(closed.text == "2 steps")
    let opened = entries(items, turns: [stopped], open: ["t1"])
    let second = opened.compactMap { entry -> DisplayItem? in
      if case .step(let row) = entry, row.id == "k2" { return row.item }
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
    #expect(both.state == .running)
    #expect(both.text == "Read: Package.swift")
    let first = try #require(line(entries(Array(items.dropLast()), turns: [running])))
    #expect(first.text == "swift test")
  }

  @Test func theNameIsTheLabelThenTheStepTitleCutAt120() throws {
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

  @Test func anUnlabelledCallWithAnObjectInputIsNamedAlone() throws {
    let running = turn("t1", .running, nil)
    func name(_ input: JSONValue) throws -> String? {
      let call = item(
        "k1", role: .tool, type: "toolCall", status: "inProgress",
        payload: ["name": .string("search"), "input": input])
      return try #require(line(entries([user("u1"), call], turns: [running]))).text
    }
    #expect(try name(.object(["query": .string("swift")])) == "search")
    #expect(try name(.string("swift")) == "search: swift")
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
    #expect(steps.state == .waiting)
    #expect(steps.text == "Waiting for you")
  }

  @Test func aTurnWhoseOutcomeIsUnknownCounts() throws {
    let result = entries(
      [user("u1"), tool("k1", status: "inProgress")], turns: [turn("t1", .reconciling, nil)],
      open: ["t1"])
    let steps = try #require(line(result))
    #expect(steps.state == .ended)
    #expect(steps.text == "1 step")
    // Its open step is neither in progress nor stopped: nothing says which.
    #expect(steps.folded.first?.payload["status"] == .string("unknown"))
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

  /// A running turn always has its line, whatever it has: nothing yet, or only a reply.
  @Test func aRunningTurnAlwaysHasItsLine() {
    let running = turn("t1", .running, nil)
    #expect(ids(entries([user("u1")], turns: [running])) == ["u1", "steps-t1"])
    #expect(ids(entries([user("u1"), message("m1")], turns: [running])) == ["u1", "steps-t1", "m1"])
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

  /// Where they stand; the tool is a step row (`StepRowTests`).
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
    #expect(steps.state == .ended)
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
      switch entry {
      case .item(let item): return item.id
      case .step(let row): return row.id
      case .line, .note: return nil
      }
    }
    #expect(drawn.sorted() == items.map(\.id).sorted())
  }

  // MARK: titles

  @Test func theStepTitleIsTheCardsWas() {
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

  // MARK: the line of a running turn

  /// Every running status has the line, marked or not, and no other turn has a running one.
  @Test(arguments: [TurnStatus.submitting, .running, .waitingForUser, .stopping])
  func everyRunningStatusHasAWorkingLine(_ status: TurnStatus) throws {
    let nothing = entries([user("u1")], turns: [turn("t1", status, nil)])
    #expect(ids(nothing) == ["u1", "steps-t1"])
    let bare = try #require(line(nothing))
    #expect(!bare.canOpen)
    #expect(bare.action(open: false) == nil)
    #expect(bare.startedAt == turn("t1").createdAt)
    let stepping = try #require(
      line(
        entries(
          [user("u1"), command("c1", status: "inProgress", command: "swift test")],
          turns: [turn("t1", status, nil)])))
    #expect(stepping.canOpen)
    #expect(stepping.action(open: false) == "Show")
    switch status {
    case .waitingForUser: #expect(stepping.text == "Waiting for you" && !stepping.marked)
    case .stopping: #expect(stepping.text == "Stopping" && stepping.marked)
    default: #expect(stepping.text == "swift test" && stepping.marked)
    }
  }

  /// A running turn with no items at all (begun on another device, its message not here yet) has its
  /// line, after everything, where a turn's note stands when it has no items.
  @Test func aRunningTurnWithNoItemsHasItsLine() throws {
    let result = entries([user("u1"), message("m1")], turns: [turn("t1"), turn("t2", .running, nil)])
    #expect(ids(result) == ["u1", "m1", "steps-t2"])
    let bare = try #require(line(result, "t2"))
    #expect(bare.text == "Working")
    #expect(bare.marked)
    #expect(!bare.canOpen)
  }

  @Test func theLineByTurnStatusAndItems() throws {
    let created = "2026-11-18T10:00:00.000Z"
    func make(_ status: TurnStatus, _ outcome: TurnOutcome?) -> Turn {
      Turn(
        id: "t1", threadId: "th", operationId: "op", status: status, outcome: outcome, createdAt: created,
        updatedAt: "2026-11-18T10:01:12.000Z")
    }
    // A submitted turn.
    let submitted = try #require(line(entries([], turns: [make(.submitting, nil)])))
    #expect(submitted.text == "Working" && submitted.marked && !submitted.canOpen)
    #expect(submitted.startedAt == created && submitted.duration == nil)
    // A streaming reply alone: the line, then the message.
    let streaming = entries([user("u1"), message("m1")], turns: [make(.running, nil)])
    #expect(ids(streaming) == ["u1", "steps-t1", "m1"])
    #expect(try #require(line(streaming)).text == "Working")
    // Waiting, stopping.
    let waiting = try #require(
      line(entries([user("u1"), tool("k1", status: "inProgress")], turns: [make(.waitingForUser, nil)])))
    #expect(waiting.text == "Waiting for you" && !waiting.marked)
    let stopping = try #require(
      line(entries([user("u1"), tool("k1", status: "inProgress")], turns: [make(.stopping, nil)])))
    #expect(stopping.text == "Stopping" && stopping.marked)
    // Ended: 6 steps, 1 failed, 72 s from `createdAt` to `updatedAt`.
    var items = [user("u1")] + (1...5).map { command("c\($0)") } + [command("c6", status: "failed")]
    items.append(message("a1"))
    let ended = try #require(line(entries(items, turns: [make(.terminal, .completed)])))
    #expect(ended.text == "6 steps" && ended.failedText == "1 failed")
    #expect(ended.durationText == "1m 12s" && ended.state == .ended && ended.startedAt == nil)
    #expect(!ended.marked)
    #expect(ended.spoken(open: false) == "6 steps, 1 failed, 1m 12s, Show")
    // Never negative, and none when a time does not parse.
    var backwards = make(.terminal, .completed)
    backwards.updatedAt = "2026-11-17T10:00:00.000Z"
    #expect(try #require(line(entries(items, turns: [backwards]))).durationText == "1s")
    var garbled = make(.terminal, .completed)
    garbled.updatedAt = "yesterday"
    #expect(try #require(line(entries(items, turns: [garbled]))).durationText == nil)
    // Only an answer: no line.
    #expect(line(entries([user("u1"), message("a1")], turns: [make(.terminal, .completed)])) == nil)
    // An unknown outcome has the ended words and no duration.
    let unknown = try #require(line(entries(items, turns: [make(.reconciling, nil)])))
    #expect(unknown.text == "6 steps" && unknown.durationText == nil && unknown.state == .ended)
    // A history group has a count and no duration.
    let history = try #require(
      line(
        entries([user("u1", turn: nil), tool("k1", turn: nil), message("a1", turn: nil)], turns: []), "h-u1"))
    #expect(history.text == "1 step" && history.durationText == nil)
    // Reasoning only: no words, a "Show working" action and no duration.
    let thought = try #require(
      line(entries([user("u1"), reasoning("r1"), message("a1")], turns: [make(.terminal, .completed)])))
    #expect(thought.text == nil && thought.durationText == nil)
    #expect(thought.action(open: false) == "Show working")
    #expect(thought.action(open: true) == "Hide working")
  }

  /// An ended turn has no running line and no mark, whatever its steps say.
  @Test func anEndedTurnHasNoClockOrMark() {
    let ended = [
      turn("t1"), turn("t1", .terminal, .failed), turn("t1", .terminal, .cancelled),
      turn("t1", .reconciling, nil),
    ]
    for turn in ended {
      let result = entries([user("u1"), tool("k1", status: "inProgress")], turns: [turn])
      let steps = line(result)
      #expect(steps?.state == .ended, "\(turn.status)")
      #expect(steps?.marked == false)
      #expect(steps?.startedAt == nil)
    }
    #expect(line(entries([user("u1")], turns: [turn()])) == nil)
    let history = entries([user("u1", turn: nil), tool("k1", turn: nil, status: "inProgress")], turns: [])
    #expect(line(history, "h-u1")?.state == .ended)
  }

  // MARK: settling an ended turn's open steps

  private func status(_ id: String, in entries: [DenseTranscript.Entry]) -> String? {
    for entry in entries {
      switch entry {
      case .item(let item) where item.id == id: return item.payload["status"]?.stringValue
      case .step(let row) where row.id == id: return row.item.payload["status"]?.stringValue
      default: continue
      }
    }
    return nil
  }

  @Test func aFailedOrCompletedTurnsOpenStepIsUnfinishedToo() {
    for outcome in [TurnOutcome.failed, .completed] {
      let result = entries(
        [user("u1"), tool("k1", status: "inProgress")], turns: [turn("t1", .terminal, outcome)],
        open: ["t1"])
      #expect(status("k1", in: result) == "stopped", "\(outcome)")
    }
    #expect(DenseTranscript.statusLabel("stopped") == "Unfinished")
  }

  @Test(arguments: [TurnStatus.submitting, .running, .waitingForUser, .stopping])
  func aRunningTurnsOpenStepStaysInProgress(_ running: TurnStatus) {
    let result = entries(
      [user("u1"), tool("k1", status: "inProgress")], turns: [turn("t1", running, nil)], open: ["t1"])
    #expect(status("k1", in: result) == "inProgress")
  }

  @Test func failedAndDeclinedStepsKeepTheirOutcome() {
    let result = entries(
      [user("u1"), tool("k1", status: "failed"), tool("k2", status: "declined")],
      turns: [turn("t1", .terminal, .failed)], open: ["t1"])
    #expect(status("k1", in: result) == "failed")
    #expect(status("k2", in: result) == "declined")
  }

  /// F13: history rows have no turn. A step the history left open is not drawn as running; one that
  /// follows a running turn's items is.
  @Test func historyStepsSettleByTheGroupTheyFollow() {
    let history = entries(
      [user("u1", turn: nil), tool("k1", turn: nil, status: "inProgress")], turns: [], open: ["h-u1"])
    #expect(status("k1", in: history) == "stopped")
    let live = entries(
      [user("u1"), tool("k1", turn: nil, status: "inProgress")], turns: [turn("t1", .running, nil)],
      open: ["t1"])
    #expect(status("k1", in: live) == "inProgress")
  }

  @Test func theStoredItemIsUntouchedAndOnlyToolsSettle() {
    let open = tool("k1", status: "inProgress")
    let thought = item("r1", role: .assistant, type: "reasoning", status: "inProgress")
    let result = entries(
      [user("u1"), open, thought], turns: [turn("t1", .terminal, .cancelled)], open: ["t1"])
    #expect(open.payload["status"] == .string("inProgress"))
    #expect(status("r1", in: result) == "inProgress")
  }

  /// The note stands after its own turn, not after the thread.
  @Test func aTurnsNoteFollowsItsTurn() {
    let items = [
      user("u1"), tool("k1", status: "inProgress"),
      user("u2", turn: "t2"), tool("k2", turn: "t2"), message("m2", turn: "t2"),
      user("u3", turn: "t3"), tool("k3", turn: "t3", status: "failed"),
    ]
    let turns = [turn("t1", .terminal, .cancelled), turn("t2"), turn("t3", .terminal, .failed)]
    #expect(
      ids(entries(items, turns: turns))
        == ["u1", "steps-t1", "note-t1", "u2", "steps-t2", "m2", "u3", "steps-t3", "note-t3"])
  }

  @Test func theStateWordsAreWordsAndUnknownStatusesAreSpokenAsTheyAre() {
    #expect(DenseTranscript.statusLabel("inProgress") == "Running")
    #expect(DenseTranscript.statusLabel("completed") == "Completed")
    #expect(DenseTranscript.statusLabel("failed") == "Failed")
    #expect(DenseTranscript.statusLabel("declined") == "Declined")
    #expect(DenseTranscript.statusLabel("unknown") == "Unknown")
    #expect(DenseTranscript.statusLabel("somethingNew") == "somethingNew")
  }

  // MARK: the window of latest rows

  private func rows(_ count: Int, usersAt users: Set<Int> = []) -> [DenseTranscript.Entry] {
    (0..<count).map { index in
      .item(users.contains(index) ? user("e\(index)") : message("e\(index)"))
    }
  }

  @Test func aThreadWithinAPageIsDrawnWhole() {
    let all = rows(DenseTranscript.page)
    #expect(DenseTranscript.window(all, shown: DenseTranscript.page) == .init(hidden: 0, entries: all))
    #expect(DenseTranscript.window([], shown: DenseTranscript.page) == .init(hidden: 0, entries: []))
  }

  @Test func aLongerThreadDrawsItsLatestPage() {
    let all = rows(400)
    let window = DenseTranscript.window(all, shown: DenseTranscript.page)
    #expect(window.hidden == 250)
    #expect(window.entries.map(\.id) == all.suffix(150).map(\.id))
    // A page more.
    #expect(DenseTranscript.window(all, shown: 2 * DenseTranscript.page).hidden == 100)
    #expect(DenseTranscript.window(all, shown: 3 * DenseTranscript.page).hidden == 0)
  }

  /// The cut moves back to a user's message that stands just before it, and no further than that.
  @Test func theWindowBeginsAtANearbyUserMessage() {
    let near = DenseTranscript.window(rows(400, usersAt: [100, 240]), shown: DenseTranscript.page)
    #expect(near.hidden == 240)
    #expect(near.entries.first?.id == "e240")
    let onTheCut = DenseTranscript.window(rows(400, usersAt: [250]), shown: DenseTranscript.page)
    #expect(onTheCut.hidden == 250)
    let far = DenseTranscript.window(rows(400, usersAt: [100]), shown: DenseTranscript.page)
    #expect(far.hidden == 250)
  }

  /// Nothing is dropped or drawn twice: what is hidden and what is drawn make the thread.
  @Test func hiddenAndDrawnMakeTheWholeThread() {
    let all = rows(1_000, usersAt: Set(stride(from: 0, to: 1_000, by: 7)))
    for pages in 1...8 {
      let window = DenseTranscript.window(all, shown: pages * DenseTranscript.page)
      #expect(all.prefix(window.hidden).map(\.id) + window.entries.map(\.id) == all.map(\.id))
    }
  }
}
